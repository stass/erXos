# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'
require_relative '../../tools/lib/erx/fsimg'

# Runs test/erlang/erx_media_volume_tests.erl and erx_media_tree_tests.erl, the EUnit
# cases of a medium's supervisor, reader and volume processes and of the media tree, against erx_media compiled from source on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the FAT16 and FAT32
# volumes fsimg makes (FatVolumes), and seeds the faults docs/design-drives.md's host
# tests name for them.
class ErxMediaVolumeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  MODULES = %w[erx_media_volume_tests erx_media_tree_tests erx_media_volume_write_tests].freeze
  # Helpers the suites call: fsimg's verify and its port.
  HELPERS = %w[erx_fat_alloc_tests erx_ram_window].freeze
  # The suites.
  TESTS = (MODULES + HELPERS).map { |name| "test/erlang/#{name}.erl" }.freeze
  MEDIUM = 'erlang/apps/erx_media/src/erx_media_medium.erl'
  VOLUME = 'erlang/apps/erx_media/src/erx_media_volume.erl'
  PLAN = 'erlang/apps/erx_fat/src/erx_fat_plan.erl'
  DRIVE = 'erlang/apps/erx_media/src/erx_media_drive.erl'
  TREE = 'erlang/apps/erx_media/src/erx_media_tree.erl'
  FAT = 'erlang/apps/erx_fat/src/erx_fat.erl'

  Fault = Data.define(:name, :path, :from, :to, :caught_by)

  # Each fault replaces one passage of a module; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'max_heap_size given media_volume_bytes as words unconverted', path: MEDIUM,
              from: '?ERX_MEDIA_VOLUME_BYTES div erlang:system_info(wordsize)', to: '?ERX_MEDIA_VOLUME_BYTES',
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: 'a volume started as a permanent child', path: MEDIUM,
              from: 'start => {erx_media_volume, start_link, [Proxy, Volume]}, restart => temporary}',
              to: 'start => {erx_media_volume, start_link, [Proxy, Volume]}, restart => permanent}',
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: "a volume's sectors read from the medium's start", path: VOLUME,
              from: '{ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, Count});',
              to: '{ok, _Lba} -> erx_media_medium:window(Proxy, {read, First, Count});',
              caught_by: 'each_volume_reads_at_its_own_place_test'),
    Fault.new(name: 'a failed flush taken as a medium that cannot flush', path: VOLUME,
              from: 'flushed({error, enotsup}, _Own) -> {ro, flush};',
              to: 'flushed({error, _}, _Own) -> {ro, flush};',
              caught_by: 'a_flush_decides_between_rw_ro_and_none_test'),
    Fault.new(name: 'the also condition removed', path: VOLUME,
              from: '{true, [Name | _]} -> {ro, {also, Name}};', to: '{true, [_Name | _]} -> flushed(Flush(), Own);',
              caught_by: 'the_rule_names_its_first_failing_condition_test'),
    Fault.new(name: 'a read-only mount not logged', path: VOLUME,
              from: 'log_mount(Volume, Outcome, erlang:monotonic_time(millisecond) - Started),',
              to: 'log_mount(Volume, Outcome#{mount := rw}, erlang:monotonic_time(millisecond) - Started),',
              caught_by: 'a_dirty_fat_volume_mounts_read_only_test'),
    Fault.new(name: "a read-only volume's status without its reason", path: TREE,
              from: 'Reason <- [erx_media_volume:ro_reason(Shown)], Reason =/= none]',
              to: 'Reason <- [erx_media_volume:ro_reason(Shown)], Reason =:= x]',
              caught_by: 'status_names_why_a_volume_is_read_only_test'),
    Fault.new(name: "the proxy's end leaving the medium's supervisor running", path: DRIVE,
              from: "    stop(Sup),\n    Held\#{table := Table", to: "    _ = Sup,\n    Held\#{table := Table",
              caught_by: 'the_drive_mounts_its_medium_at_the_ask_and_ends_it_with_its_proxy_test'),

    Fault.new(name: "status's values written without the field escape", path: TREE,
              from: 'erx_text:escape_field(iolist_to_binary(text(Value)))', to: 'iolist_to_binary(text(Value))',
              caught_by: 'status_escapes_what_the_medium_supplies_test'),
    Fault.new(name: 'the clean bit set in the FAT the server reads before its copies',
              path: 'erlang/apps/erx_fat/src/erx_fat_alloc.erl',
              from: '[{clean_mirrors, Mirrors}, {clean, Read}]', to: '[{clean, Read}, {clean_mirrors, Mirrors}]',
              caught_by: 'every_cut_of_a_removal_leaves_a_tree_that_reads_test_/0-fun-1- (fat16.img)'),
    Fault.new(name: "a failed volume's end not logged", path: VOLUME,
              from: 'logger:notice("erx_media: volume s~b ended: its commit failed: ~s", [Number, erx_report:reason_name(Why)]);',
              to: '_ = {Number, Why}, ok;',
              caught_by: 'a_commit_that_cannot_read_ends_the_volume_test'),
    Fault.new(name: 'a rename between two volumes taken as one within a volume', path: TREE,
              from: '_NewName, _Fs) when From =/= To ->', to: '_NewName, _Fs) when From =:= To ->',
              caught_by: 'exdev_is_decided_before_any_volume_is_asked_test'),
    Fault.new(name: "a qid path without its volume's mount number", path: VOLUME,
              from: '{(Mount bsl ?NODE_BITS) bor Next, State#{next := Next + 1}};',
              to: '{Next, State#{next := Next + 1}};',
              caught_by: 'two_mounts_are_distinct_test'),
    Fault.new(name: 'a request admitted after the finish', path: VOLUME,
              from: "handle_call(_Request, _From, \#{finished := true} = State) ->\n    {reply, {error, eio}, State};\n",
              to: '',
              caught_by: 'the_finish_answers_what_came_before_and_refuses_what_comes_after_test'),
    Fault.new(name: "an eject that leaves the medium's supervisor running", path: DRIVE,
              from: "    stop(Sup),\n    Held\#{table := Table", to: "    _ = Sup,\n    Held\#{table := Table",
              caught_by: 'eject_finishes_every_volume_then_ends_the_medium_test'),
    Fault.new(name: 'a waiting read admitted after the finish', path: VOLUME,
              from: "handle_info(?ERX_FS_WAIT({_Grant, Alias}, _Request), \#{finished := true} = State) ->\n" \
                    "    Alias ! ?ERX_FS_ANSWER(Alias, {error, eio}),\n    {noreply, State};\n",
              to: '',
              caught_by: 'the_finish_answers_what_came_before_and_refuses_what_comes_after_test'),
    Fault.new(name: "a step's flush dropped", path: PLAN,
              from: "            case Flush() of\n",
              to: "            case erlang:phash2(Flush) >= 0 andalso ok of\n",
              caught_by: 'round_trip_test_/0-fun-1- (fat16.img)'),
    Fault.new(name: 'the ownership check skipped at a writable mount', path: VOLUME,
              from: 'ok -> checked(Fat, Proxy, Volume)',
              to: 'ok -> erx_fat_alloc:writable(erx_fat:info(Fat))',
              caught_by: 'a_crossed_chain_mounts_read_only_test'),
    Fault.new(name: "the ownership check's stack filled past its places", path: FAT,
              from: 'pushed(_Dir, _Parent, #{depth := Depth}) when Depth >= ?CHECK_PENDING_MAX ->',
              to: 'pushed(_Dir, _Parent, #{depth := Depth}) when Depth > ?CHECK_PENDING_MAX ->',
              caught_by: 'fat32_volumes_are_checked_within_the_memory_bound_test_/0-fun-2- (one past a full stack)'),
    # A FAT pass that lists each sector's entries and every sector's index over the whole FAT.
    Fault.new(name: "the ownership check's FAT pass building lists over the whole FAT", path: FAT,
              from: "fat_pass(Fat = #fat{clusters = Clusters}, Runs, Fun) ->\n    fat_pass(Fat, Runs, Fun, 2, Clusters + 2).",
              to: "fat_pass(Fat = #fat{read = Read, type = Type, fat_start = Start, clusters = Clusters}, Runs, Fun) ->\n" \
                  "    PerSector = ?SECTOR * 8 div Type,\n" \
                  "    lists:foreach(fun(Index) ->\n" \
                  "                          Values = [Entry band mask(Type) || <<Entry:Type/little>> <= " \
                  "sector(Read, Start + Index)],\n" \
                  "                          [Fun(Cluster, Value) || {Cluster, Value} <- " \
                  "lists:enumerate(Index * PerSector, Values),\n" \
                  "                                                  Cluster >= 2, Cluster < Clusters + 2]\n" \
                  "                  end, lists:seq(0, (Clusters + 1) div PerSector)),\n" \
                  '    fat_pass(Fat, Runs, Fun, Clusters + 2, Clusters + 2).',
              caught_by: 'fat32_volumes_are_checked_within_the_memory_bound_test_/0-fun-2- (8 GB)'),
    # A FAT pass that reads a sector a request: one round trip per FAT sector.
    Fault.new(name: "the ownership check's FAT pass reading a sector at a time", path: FAT,
              from: '    Count = min(Max, Last - Index + 1),',
              to: '    Count = min(Max, 1),',
              caught_by: 'the_fat_is_read_in_runs_test_/0-fun-4-'),
    # A directory walk that lists the sectors of its whole chain before it reads an entry.
    Fault.new(name: "a directory's chain listed whole before it is read", path: FAT,
              from: '    links_fold(Fat, data_cluster(Clusters, First), 1, Max, Fun, Acc).',
              to: "    {Listed, Total} = links_fold(Fat, data_cluster(Clusters, First), 1, Max,\n" \
                  "                                 fun(Sector, Entries, L) -> [{Sector, Entries} | L] end, []),\n" \
                  "    {lists:foldl(fun({Sector, Entries}, A) -> Fun(Sector, Entries, A) end, Acc, " \
                  "lists:reverse(Listed)), Total}.",
              caught_by: 'the_largest_directory_is_walked_within_the_memory_bound_test_/0-fun-5-'),
    Fault.new(name: "a removed file's key kept", path: VOLUME,
              from: 'State#{places := Rest, nodes := Nodes#{Path := {removed, Node, Holders}}};',
              to: 'State#{places := Places, nodes := Nodes#{Path := {removed, Node, Holders}}};',
              caught_by: 'a_removed_file_lives_by_its_fids_test'),
    Fault.new(name: "a removed file's chain released while fids name it", path: VOLUME,
              from: 'State#{places := Rest, nodes := Nodes#{Path := {removed, Node, Holders}}};',
              to: 'released(Node, State#{places := Rest, nodes := Nodes#{Path := {removed, Node, Holders}}});',
              caught_by: 'a_removed_file_lives_by_its_fids_test')
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-media-volume-images').tap do |directory|
      FatVolumes.write(directory, root: ROOT)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.path))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.path => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_media_\w+_tests: ).)*?\*failed\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the applications with the replaced module texts, and the suite, and runs it.
  def eunit(replaced)
    Dir.mktmpdir('erx-media-volume-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images, 'ERX_FSIMG' => Erx::Fsimg.locate(root: ROOT) },
                      'gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{MODULES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
