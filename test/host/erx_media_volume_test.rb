# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'

# Runs test/erlang/erx_media_volume_tests.erl and erx_media_tree_tests.erl, the EUnit
# cases of a medium's supervisor, reader and volume processes and of the media tree, against erx_media compiled from source on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the FAT16 and FAT32
# volumes fsimg makes (FatVolumes), and seeds the faults docs/design-drives.md's host
# tests name for them.
class ErxMediaVolumeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_fat erx_media].freeze
  MODULES = %w[erx_media_volume_tests erx_media_tree_tests].freeze
  # The suites.
  TESTS = MODULES.map { |name| "test/erlang/#{name}.erl" }.freeze
  MEDIUM = 'erlang/apps/erx_media/src/erx_media_medium.erl'
  VOLUME = 'erlang/apps/erx_media/src/erx_media_volume.erl'
  DRIVE = 'erlang/apps/erx_media/src/erx_media_drive.erl'
  TREE = 'erlang/apps/erx_media/src/erx_media_tree.erl'

  Fault = Data.define(:name, :path, :from, :to, :caught_by)

  # Each fault replaces one passage of a module; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'max_heap_size given media_volume_bytes as words unconverted', path: MEDIUM,
              from: '?ERX_MEDIA_VOLUME_BYTES div erlang:system_info(wordsize)', to: '?ERX_MEDIA_VOLUME_BYTES',
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: 'a volume started as a permanent child', path: MEDIUM,
              from: "start => {erx_media_volume, start_link, [Proxy, Volume]},\n             restart => temporary}",
              to: "start => {erx_media_volume, start_link, [Proxy, Volume]},\n             restart => permanent}",
              caught_by: 'each_volume_runs_under_its_memory_bound_and_ends_alone_test'),
    Fault.new(name: "a volume's sectors read from the medium's start", path: VOLUME,
              from: '{ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, 1});',
              to: '{ok, _Lba} -> erx_media_medium:window(Proxy, {read, Sector, 1});',
              caught_by: 'each_volume_reads_at_its_own_place_test'),
    Fault.new(name: 'a failed flush taken as a medium that cannot flush', path: VOLUME,
              from: 'flushed({error, enotsup}, _Clean, _Writes) -> {ro, flush};',
              to: 'flushed({error, _}, _Clean, _Writes) -> {ro, flush};',
              caught_by: 'a_flush_decides_between_rw_ro_and_none_test'),
    Fault.new(name: 'the also condition removed', path: VOLUME,
              from: '{true, [Name | _]} -> {ro, {also, Name}};', to: '{true, [_Name | _]} -> flushed(Flush(), Clean, false);',
              caught_by: 'the_rule_names_its_first_failing_condition_test'),
    Fault.new(name: 'msdosfs taken as written though erx_fat has no write path', path: VOLUME,
              from: '-define(WRITE_PATHS, []).', to: '-define(WRITE_PATHS, [msdosfs]).',
              caught_by: 'a_clean_fat_stick_mounts_read_only_for_want_of_a_write_path_test'),
    Fault.new(name: 'a read-only mount not logged', path: VOLUME,
              from: '            log_read_only(Volume, Outcome),', to: '            log_read_only(Volume, Outcome#{mount := rw}),',
              caught_by: 'a_clean_fat_stick_mounts_read_only_for_want_of_a_write_path_test'),
    Fault.new(name: "a read-only volume's status without its reason", path: TREE,
              from: 'Reason <- [erx_media_volume:ro_reason(Shown)], Reason =/= none]',
              to: 'Reason <- [erx_media_volume:ro_reason(Shown)], Reason =:= x]',
              caught_by: 'status_names_why_a_volume_is_read_only_test'),
    Fault.new(name: "the proxy's end leaving the medium's supervisor running", path: DRIVE,
              from: "    stop(Sup),\n    {noreply, State\#{medium := none}};", to: "    _ = Sup,\n    {noreply, State\#{medium := none}};",
              caught_by: 'the_drive_mounts_its_medium_at_the_ask_and_ends_it_with_its_proxy_test'),
    Fault.new(name: "an idle medium's supervisor left running", path: DRIVE,
              from: '_Idle -> stop(Sup), none', to: '_Idle -> none',
              caught_by: 'a_refused_table_leaves_the_medium_idle_with_no_supervisor_test'),
    Fault.new(name: "status's values written without the field escape", path: TREE,
              from: 'erx_text:escape_field(iolist_to_binary(text(Value)))', to: 'iolist_to_binary(text(Value))',
              caught_by: 'status_escapes_what_the_medium_supplies_test'),
    Fault.new(name: 'a rename between two volumes taken as one within a volume', path: TREE,
              from: '_NewName, _Fs) when From =/= To ->', to: '_NewName, _Fs) when From =:= To ->',
              caught_by: 'exdev_is_decided_before_any_volume_is_asked_test'),
    Fault.new(name: "a qid path without its volume's mount number", path: VOLUME,
              from: "\#{Key := Number} ->\n            {ok, (Mount bsl ?NODE_BITS) bor Number, State};",
              to: "\#{Key := Number} ->\n            {ok, Number, State};",
              caught_by: 'two_mounts_are_distinct_test'),
    Fault.new(name: 'a request admitted after the finish', path: VOLUME,
              from: "handle_call(_Request, _From, \#{finished := true} = State) ->\n    {reply, {error, eio}, State};\n",
              to: '',
              caught_by: 'the_finish_answers_what_came_before_and_refuses_what_comes_after_test'),
    Fault.new(name: "an eject that leaves the medium's supervisor running", path: DRIVE,
              from: "    Answer = finish(Volumes),\n    stop(Sup),\n", to: "    Answer = finish(Volumes),\n",
              caught_by: 'eject_finishes_every_volume_then_ends_the_medium_test'),
    Fault.new(name: 'a waiting read admitted after the finish', path: VOLUME,
              from: "handle_info(?ERX_FS_WAIT({_Grant, Alias}, _Request), \#{finished := true} = State) ->\n" \
                    "    Alias ! ?ERX_FS_ANSWER(Alias, {error, eio}),\n    {noreply, State};\n",
              to: '',
              caught_by: 'the_finish_answers_what_came_before_and_refuses_what_comes_after_test')
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
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images },
                      'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      "halt(case eunit:test([#{MODULES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
