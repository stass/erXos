# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'

# The FAT server's read path (docs/design-storage.md, "Removable media: FAT"):
# test/erlang/erx_fat_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies) over the FAT16 and FAT32 volumes fsimg, the server's oracle,
# writes of FatVolumes' tree, against erx_fat as it is and against each seeded fault
# below, where the named case must fail.
class ErxFatTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_fat; the case named in caught_by must fail, or
  # time out where the fault makes a walk endless.
  FAULTS = [
    Fault.new(name: 'a cluster seen twice in a chain not checked',
              from: "exact_chain(_Fat, Cluster, _Left, Seen, _Got) when is_map_key(Cluster, Seen) ->\n    " \
                    "fail(does_not_read);\n",
              to: '', caught_by: 'a_chain_that_loops_is_refused_test'),
    Fault.new(name: "a directory's chain followed past the clusters its entries fill",
              from: "        _Next when Taken =:= Max -> fail(does_not_read);\n", to: '',
              caught_by: 'a_directory_chain_that_loops_is_refused_test'),
    Fault.new(name: "a link's range not checked",
              from: 'when is_integer(Cluster), Cluster >= 2, Cluster < Clusters + 2 ->',
              to: 'when is_integer(Cluster), Clusters > 0 ->',
              caught_by: 'a_link_out_of_the_data_area_or_free_is_refused_test'),
    Fault.new(name: 'a forbidden name served',
              from: 'byte_size(Name) =< 255 -> erx_fat_name:valid(Name);', to: 'byte_size(Name) =< 255 -> Name;',
              caught_by: 'a_name_the_specification_forbids_is_never_listed_test'),
    Fault.new(name: 'a label holding a control shown',
              from: 'andalso not lists:any(fun(C) -> C < 16#20 end, unicode:characters_to_list(Text))', to: '',
              caught_by: 'a_label_holding_a_control_is_not_shown_test'),
    Fault.new(name: 'a FAT too small for its clusters admitted',
              from: 'andalso FatSectors * ?SECTOR >= (Clusters + 2) * (Type div 8)', to: '',
              caught_by: 'a_boot_sector_the_server_does_not_admit_is_refused_test'),
    Fault.new(name: 'a FAT32 volume of a later version or past the largest count of clusters admitted',
              from: '             andalso (Type =:= 16 orelse (Version =:= ?VERSION_32 andalso Clusters =< ?CLUSTERS_MAX_32))),',
              to: '             andalso (Type =:= 16 orelse Version + Clusters >= 0)),',
              caught_by: 'fat32s_version_and_largest_count_of_clusters_are_checked_test'),
    Fault.new(name: 'an FSInfo sector outside the reserved area written',
              from: 'fsinfo = case FsInfo of N when N >= 1, N < Reserved -> N; _ -> none end,',
              to: 'fsinfo = case FsInfo of N when N < 16#ffff -> N; _ -> none end,',
              caught_by: 'an_fsinfo_sector_outside_the_reserved_area_is_none_test'),
    Fault.new(name: 'the slack of the last cluster answered',
              from: 'binary:copy(binary:part(Data, Offset - Skip * Bytes, End - Offset))',
              to: 'binary:part(Data, Offset - Skip * Bytes, byte_size(Data) - (Offset - Skip * Bytes))',
              caught_by: 'a_file_reads_whole_across_its_chain_and_no_further_test'),
    Fault.new(name: "the check's double-link test removed",
              from: '{to, Next} -> mark(Linked, Next) andalso fail(tree);', to: '{to, Next} -> mark(Linked, Next), ok;',
              caught_by: 'a_cluster_linked_to_twice_is_a_tree_finding_test'),
    Fault.new(name: 'an entry of no value the specification gives passed',
              from: 'invalid -> fail(tree);', to: 'invalid -> ok;',
              caught_by: 'an_entry_of_no_value_the_specification_gives_is_a_tree_finding_test'),
    Fault.new(name: 'a first cluster outside the volume passed',
              from: 'First >= 2 andalso First < Clusters + 2 orelse fail(tree),', to: 'Clusters > 0,',
              caught_by: 'a_first_cluster_outside_the_volume_is_a_tree_finding_test'),
    Fault.new(name: 'a first cluster linked to passed',
              from: 'marked(Linked, First) andalso fail(tree),', to: 'marked(Linked, First),',
              caught_by: 'a_first_cluster_linked_to_is_a_tree_finding_test'),
    Fault.new(name: 'a first cluster named twice passed',
              from: 'mark(Named, First) andalso fail(tree).', to: 'mark(Named, First), ok.',
              caught_by: 'a_first_cluster_named_twice_is_a_tree_finding_test'),
    Fault.new(name: "a `.` naming another directory passed",
              from: '{?DOT, _} -> (Index =:= 0 andalso First =:= Dir) orelse fail(tree), Acc#{dot := true};',
              to: '{?DOT, _} -> Acc#{dot := true};',
              caught_by: 'a_dot_entry_naming_another_directory_is_a_tree_finding_test'),
    Fault.new(name: "a `..` naming another directory passed",
              from: '{?DOTDOT, _} -> (Index =:= 1 andalso First =:= Parent) orelse fail(tree), Acc#{dotdot := true};',
              to: '{?DOTDOT, _} -> Acc#{dotdot := true};',
              caught_by: 'a_dot_entry_naming_another_directory_is_a_tree_finding_test'),
    Fault.new(name: 'a subdirectory without its dot entries passed',
              from: 'Dir =:= root orelse (Dot andalso DotDot) orelse fail(tree),', to: '_ = {Dot, DotDot},',
              caught_by: 'a_subdirectory_without_its_dot_entries_is_a_tree_finding_test'),
    Fault.new(name: 'a reached cluster whose entry is free or bad passed',
              from: 'Held andalso lists:member(entry_kind(Fat, Value), [free, bad]) andalso fail(tree).',
              to: 'Held andalso entry_kind(Fat, Value) =:= never andalso fail(tree).',
              caught_by: 'a_reached_cluster_whose_entry_is_free_or_bad_is_a_tree_finding_test'),
    Fault.new(name: 'a volume past the checked count read',
              from: 'check(#fat{clusters = Clusters}, _ReadRun, _Max) when Clusters > ?CHECKED_CLUSTERS_MAX ->',
              to: 'check(#fat{clusters = Clusters}, _ReadRun, _Max) when Clusters < 0 ->',
              caught_by: 'a_volume_past_the_checked_count_is_too_large_and_unread_test')
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-fat-images').tap do |directory|
      FatVolumes.write(directory, root: ROOT)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_fat_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the server as core_text, and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-fat-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images },
                      'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_fat_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
