# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'

# The FAT checker (docs/design-fsck-fat.md, "Host tests"):
# test/erlang/erx_fat_check_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) over the volumes erx_fat_damage lays out in memory and
# the FAT16 and FAT32 volumes fsimg writes of FatVolumes' tree, against
# erx_fat_check as it is and against each seeded fault below, each of which removes
# one finding, refusal or bound: the case named in caught_by must fail.
class ErxFatCheckTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_check.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_damage.erl test/erlang/erx_fat_check_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  FAULTS = [
    Fault.new(name: "an unadmitted boot sector refused instead of fatal",
              from: "admitted({error, {not_its_volume, Why}}) -> answer({fatal, {boot_sector, Why}});",
              to: "admitted({error, {not_its_volume, _Why}}) -> answer({refused, sector_size});",
              caught_by: "(finding boot_sector)"),
    Fault.new(name: "FAT12 taken as a malformed boot sector",
              from: "admitted({error, {not_its_volume, fat12}}) -> answer({refused, fat12});\n",
              to: "",
              caught_by: "(refusal fat12)"),
    Fault.new(name: "other sector sizes taken as a malformed boot sector",
              from: "admitted({error, {not_its_volume, sector_size}}) -> answer({refused, sector_size});\n",
              to: "",
              caught_by: "(refusal sector_size)"),
    Fault.new(name: "mirroring off checked",
              from: "Mirrored orelse answer({refused, not_mirrored}),",
              to: "Mirrored orelse true,",
              caught_by: "(refusal not_mirrored)"),
    Fault.new(name: "a bad FSInfo signature passed over",
              from: "unsigned -> finding(St, fsinfo_signature);",
              to: "unsigned -> St;",
              caught_by: "(finding fsinfo_signature)"),
    Fault.new(name: "any FAT header taken as clean",
              from: "header(_Type, _Media, _Head) -> odd.",
              to: "header(_Type, _Media, _Head) -> clean.",
              caught_by: "(finding fat_header)"),
    Fault.new(name: "the dirty flag dropped",
              from: "dirty(St = #st{dirty = Dirty}) -> found_if(Dirty, dirty, St).",
              to: "dirty(St = #st{dirty = Dirty}) -> found_if(Dirty andalso false, dirty, St).",
              caught_by: "(finding dirty)"),
    Fault.new(name: "a link out of range kept",
              from: "            linked(finding(St, {out_of_range_link, Cluster, Value}), Cluster, mask(St#st.type));",
              to: "            St;",
              caught_by: "(finding out_of_range_link)"),
    Fault.new(name: "a cluster linked to twice kept",
              from: "                true -> linked(finding(St, {crossed, Cluster, Next}), Cluster, mask(St#st.type))",
              to: "                true -> St",
              caught_by: "(finding crossed)"),
    Fault.new(name: "a FAT32 root linked to walked",
              from: "marked(Cleared, Root) andalso answer({fatal, root_not_chain}),",
              to: "marked(Cleared, Root) andalso true,",
              caught_by: "(fatal root_not_chain)"),
    Fault.new(name: "a chain into a free cluster kept whole",
              from: "{Links, linked(finding(St1, {chain_end, Head, Marked}), Previous, mask(St1#st.type))}",
              to: "{Links + 1, St1}",
              caught_by: "(finding chain_end)"),
    Fault.new(name: "entries after an end marker passed over",
              from: "    slot(finding(St, {entries_after_end, path(Path)}), D\#{empty := false}, Path, Bytes, Entry);",
              to: "    slot(St, D\#{empty := false}, Path, Bytes, Entry);",
              caught_by: "(finding entries_after_end)"),
    Fault.new(name: "an invalid run before a short entry passed over",
              from: "St1 = found_if(Invalid orelse (Valid andalso not Named), {invalid_long, path(Path, Name)}, St),",
              to: "St1 = found_if(Invalid andalso Named andalso false, {invalid_long, path(Path, Name)}, St),",
              caught_by: "(finding invalid_long)"),
    Fault.new(name: "a run open at the end passed over",
              from: "true -> {finding(St, {invalid_long_at_end, path(Path)}), Kids};",
              to: "true -> {St, Kids};",
              caught_by: "(finding invalid_long_at_end)"),
    Fault.new(name: "a run before a label passed over",
              from: "{found_if(Valid orelse Invalid, invalid_long_label, St), D\#{valid := false, invalid := false}};",
              to: "{found_if(Valid andalso Invalid andalso false, invalid_long_label, St), D\#{valid := false, invalid := false}};",
              caught_by: "(finding invalid_long_label)"),
    Fault.new(name: "order number 0 passed over",
              from: "{finding(St, invalid_long_name), invalidated(D1\#{lidx := 0})};",
              to: "{St, invalidated(D1\#{lidx := 0})};",
              caught_by: "(finding invalid_long_name)"),
    Fault.new(name: "a name past the buffer passed over",
              from: "{St1, D2} = invalid_if(not Fits, long_name_too_long, St, D1),",
              to: "{St1, D2} = invalid_if(not Fits andalso false, long_name_too_long, St, D1),",
              caught_by: "(finding long_name_too_long)"),
    Fault.new(name: "a long entry's cluster field not read",
              from: "{St2, D3} = invalid_if(Cluster =/= 0, long_cluster, St1, D2),",
              to: "{St2, D3} = invalid_if(Cluster =/= Cluster, long_cluster, St1, D2),",
              caught_by: "(finding long_cluster)"),
    Fault.new(name: "a first cluster out of range taken as claimed",
              from: "false -> {start_out_of_range, path(Path, Name), Head};",
              to: "false -> {not_new_chain, path(Path, Name)};",
              caught_by: "(finding start_out_of_range)"),
    Fault.new(name: "a claimed first cluster passed",
              from: "case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not starts_chain(St, Head) of",
              to: "case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not valid(St, Head) of",
              caught_by: "(finding not_new_chain)"),
    Fault.new(name: "a directory named twice walked twice",
              from: "            descend(released(finding(St, {not_new_chain, path([Child | Path])}), Child), Path);",
              to: "            descend(released(St, Child), Path);",
              caught_by: "(finding not_new_chain of a directory named twice)"),
    Fault.new(name: "a directory's size passed over",
              from: "directory_entry(found_if(Size =/= 0, {dir_size, path(Path, Name)}, St), D, Path, Name, Short11, Head);",
              to: "directory_entry(found_if(Size =/= 0 andalso false, {dir_size, path(Path, Name)}, St), D, Path, Name, Short11, Head);",
              caught_by: "(finding dir_size)"),
    Fault.new(name: "a wrong `.' passed over",
              from: "?DOT -> {found_if(Head =/= Here, {dot_cluster, path(Path)}, St), D};",
              to: "?DOT -> {found_if(Head =/= Here andalso false, {dot_cluster, path(Path)}, St), D};",
              caught_by: "(finding dot_cluster)"),
    Fault.new(name: "a non-zero `..' under the root passed over",
              from: "found_if(Head =/= 0, {dotdot_nonzero, path(Path)}, St);",
              to: "found_if(Head =/= 0 andalso false, {dotdot_nonzero, path(Path)}, St);",
              caught_by: "(finding dotdot_nonzero)"),
    Fault.new(name: "a wrong `..' passed over",
              from: "found_if(Head =/= Parent, {dotdot_cluster, path(Path)}, St).",
              to: "found_if(Head =/= Parent andalso false, {dotdot_cluster, path(Path)}, St).",
              caught_by: "(finding dotdot_cluster)"),
    Fault.new(name: "a `.' outside the first two slots passed over",
              from: "        ?DOT when Up =/= [], Slot =/= 0 -> {finding(St, {dot_out_of_place, dot, path(Path)}), D};\n",
              to: "",
              caught_by: "(finding dot_out_of_place)"),
    Fault.new(name: "a subdirectory's `.' not read",
              from: "DotOk = dot_entry(Dot, ?DOT),",
              to: "DotOk = dot_entry(Dot, ?DOT) orelse true,",
              caught_by: "(finding incorrect_dot)"),
    Fault.new(name: "a subdirectory's `..' not read",
              from: "DotDotOk = dot_entry(DotDot, ?DOTDOT),",
              to: "DotDotOk = dot_entry(DotDot, ?DOTDOT) orelse true,",
              caught_by: "(finding incorrect_dotdot)"),
    Fault.new(name: "an empty file naming no cluster passed",
              from: "finding(St, {invalid_cluster, Shown(), Size, Head});",
              to: "St;",
              caught_by: "(finding invalid_cluster)"),
    Fault.new(name: "a size past the chain passed",
              from: "Physical < Size -> finding(St, {size_too_large, Path(), Size, Physical});",
              to: "Physical < Size -> St;",
              caught_by: "(finding size_too_large)"),
    Fault.new(name: "clusters past the size passed",
              from: "Physical - Size >= ClusterBytes -> trimmed(finding(St, {too_many_clusters, Path()}), Head, Size);",
              to: "Physical - Size >= ClusterBytes -> trimmed(St, Head, Size);",
              caught_by: "(finding too_many_clusters)"),
    Fault.new(name: "a lost chain passed over",
              from: "{Count, St1} -> finding(St1, {lost_chain, Head, Count})",
              to: "{_Count, St1} -> St1",
              caught_by: "(finding lost_chain)"),
    Fault.new(name: "a loop of lost clusters passed over",
              from: "lost(linked(finding(St, {lost_loop, Lowest}), Cluster, mask(St#st.type)), Lowest);",
              to: "lost(linked(St, Cluster, mask(St#st.type)), Lowest);",
              caught_by: "(finding lost_loop)"),
    Fault.new(name: "a wrong free count passed",
              from: "St1 = found_if(Hint =/= ?UNKNOWN andalso Hint =/= Free, {fsinfo_free, Hint, Free}, St),",
              to: "St1 = found_if(Hint =/= ?UNKNOWN andalso Hint =/= Free andalso false, {fsinfo_free, Hint, Free}, St),",
              caught_by: "(finding fsinfo_free)"),
    Fault.new(name: "a next-free hint out of range passed",
              from: "Next >= Clusters + 2 -> finding(St1, {fsinfo_next, Next, invalid});",
              to: "Next >= Clusters + 2 -> St1;",
              caught_by: "(finding fsinfo_next)"),
    Fault.new(name: "a next-free hint at an allocated cluster passed",
              from: "found_if(Value =/= 0, {fsinfo_next, Next, not_free}, St2)",
              to: "found_if(Value =/= Value, {fsinfo_next, Next, not_free}, St2)",
              caught_by: "(finding fsinfo_next not free)"),
    Fault.new(name: "the copies not compared",
              from: "Differs = binary:part(Theirs, 0, byte_size(Used)) =/= Used,",
              to: "Differs = binary:part(Theirs, 0, byte_size(Used)) =:= <<1>>,",
              caught_by: "(finding fat_copy_differs)"),
    Fault.new(name: "the cluster bound removed",
              from: "Clusters =< erx_fat:checked_clusters_max() orelse answer({refused, {bound, clusters}}),",
              to: "Clusters > 0 orelse answer({refused, {bound, clusters}}),",
              caught_by: "too_many_clusters_are_refused_before_the_fat_is_read_test"),
    Fault.new(name: "the directories bound removed",
              from: "Bytes =< ?HELD_BYTES_MAX orelse answer({refused, {bound, directories}}),",
              to: "Bytes > 0 orelse answer({refused, {bound, directories}}),",
              caught_by: "too_many_directories_are_refused_test_"),
    Fault.new(name: "the edits bound removed",
              from: "is_map_key(Cluster, Links) orelse map_size(Links) < ?EDITS_MAX orelse answer({refused, {bound, edits}}),",
              to: "is_map_key(Cluster, Links) orelse map_size(Links) >= 0 orelse answer({refused, {bound, edits}}),",
              caught_by: "too_many_edits_are_refused_test_"),
    Fault.new(name: "the findings bound removed",
              from: "Total =< ?HELD_BYTES_MAX orelse answer({refused, {bound, findings}}),",
              to: "Total > 0 orelse answer({refused, {bound, findings}}),",
              caught_by: "too_many_findings_are_refused_test_"),
    Fault.new(name: "a path's bound removed",
              from: "shown([Name | Up], Acc, Bytes) when Bytes + 1 + byte_size(Name) =< ?PATH_BYTES_MAX ->",
              to: "shown([Name | Up], Acc, Bytes) when Bytes + 1 + byte_size(Name) =< 1 bsl 30 ->",
              caught_by: "a_deep_path_keeps_its_last_bytes_test"),
    Fault.new(name: "admission given more than the file's sectors",
              from: "Fat = admitted(erx_fat:admission(Read, Sectors)),",
              to: "Fat = admitted(erx_fat:admission(Read, Sectors + 1000000)),",
              caught_by: "a_volume_longer_than_its_file_is_refused_reading_only_the_boot_sector_test")
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-fat-check-images').tap do |directory|
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
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # Compiles the checker as core_text, with erx_fat and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-fat-check-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images }, 'gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_fat_check_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
