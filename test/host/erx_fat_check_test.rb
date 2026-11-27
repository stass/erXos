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
# one finding, refusal, bound or rule of writing a repair (a fault of more than one
# passage changes each): the case named in caught_by must fail. A fault runs the one case
# or generator that catches it (ErlangBuild.eunit_spec), not both modules: the cut
# repairs take nearly all of a whole run, so each fault whose caught_by is a title of the
# finding table names in runs the generator it fails in, FINDINGS or CUTS.
class ErxFatCheckTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_check.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_damage.erl test/erlang/erx_fat_check_tests.erl
             test/erlang/erx_fat_repair_tests.erl].freeze

  FINDINGS = 'each_finding_test_'
  CUTS = 'a_cut_repair_loses_nothing_test_'

  # runs, the case or generator eunit runs, is caught_by itself when that names a case.
  Fault = Data.define(:name, :from, :to, :caught_by, :runs) do
    def initialize(caught_by:, runs: caught_by, **fields) = super
  end

  FAULTS = [
    Fault.new(name: "the steps' images computed from the medium before the first write",
              from: "    Writer = \#{read => Read, write => Write, flush => Flush},",
              to: "    Before = \#{S => element(2, Read(S)) || Step := Edits <- Steps, Step =/= fsinfo, S := _ <- Edits},\n    Writer = \#{read => fun(S) when is_map_key(S, Before) -> {ok, map_get(S, Before)}; (S) -> Read(S) end, write => Write, flush => Flush},",
              caught_by: "each_step_is_computed_at_its_turn_test"),
    Fault.new(name: "the fsinfo step writing the signatures alone",
              from: "{fsinfo, {FsInfo, 16#1e4}, <<16#61417272:32/little, ?UNKNOWN:32, ?UNKNOWN:32>>},",
              to: "{fsinfo, {FsInfo, 16#1e4}, <<16#61417272:32/little>>},",
              caught_by: "each_step_is_computed_at_its_turn_test"),
    Fault.new(name: "the dirty step left out",
              from: "        planned(erx_fat_alloc:dirty(Alloc()), Writer),\n",
              to: "",
              runs: CUTS,
              caught_by: "(finding dir_size)"),
    Fault.new(name: "the cuts written before the names they free are removed",
              from: "-define(EDIT_STEPS, [preparation, cutting, publication, fsinfo]).",
              to: "-define(EDIT_STEPS, [cutting, preparation, publication, fsinfo]).",
              runs: CUTS,
              caught_by: "(finding not_new_chain at a trimmed tail)"),
    Fault.new(name: "lost chains named before their old names are removed",
              from: "-define(EDIT_STEPS, [preparation, cutting, publication, fsinfo]).",
              to: "-define(EDIT_STEPS, [publication, preparation, cutting, fsinfo]).",
              runs: CUTS,
              caught_by: "(finding incorrect_dot)"),
    Fault.new(name: "a file's tail freed instead of cut",
              from: "            St3 = linked(St2, Last, mask(St2#st.type)),",
              to: "            St3 = linked(linked(St2, Last, mask(St2#st.type)), Tail, 0),",
              runs: FINDINGS,
              caught_by: "(finding too_many_clusters)"),
    Fault.new(name: "the final check skipped, with a row the final check stands behind removed",
              from: ["        ?DOT when Up =/= [], Slot =/= 0 -> {deleted(finding(St, {dot_out_of_place, dot, path(Path)}), Places), D};\n", "accepted({read_only, Why}) -> answer({refused, {not_writable, Why}});"],
              to: ["", "accepted({read_only, _Why}) -> ok;"],
              caught_by: "a_second_dot_is_repaired_test"),
    Fault.new(name: "a new last part not ending the open run",
              from: "                    Last -> opened(invalidated(St, D), Check);",
              to: "                    Last -> opened({St, D}, Check);",
              runs: FINDINGS,
              caught_by: "(finding invalid_long of an orphan run)"),
    Fault.new(name: "a trimmed tail left for a later entry to take",
              from: "            unreached(St3#st{tails = [Tail | St3#st.tails]}, Tail);",
              to: "            unmark(St3#st.cleared, Tail),\n            unreached(St3, Tail);",
              runs: FINDINGS,
              caught_by: "(finding not_new_chain at a trimmed tail)"),
    Fault.new(name: "the value below the bad mark taken as reserved",
              from: "    Bad = mask(Type) - 8,",
              to: "    Bad = mask(Type) - 9,",
              runs: FINDINGS,
              caught_by: "(finding out_of_range_link below the bad mark)"),
    Fault.new(name: "an unadmitted FAT32 root not fatal",
              from: "admitted({error, does_not_read}) -> answer({fatal, {boot_sector, root}});\n",
              to: "",
              runs: FINDINGS,
              caught_by: "(fatal boot_sector root)"),
    Fault.new(name: "an unadmitted boot sector refused instead of fatal",
              from: "admitted({error, {not_its_volume, Why}}) -> answer({fatal, {boot_sector, Why}});",
              to: "admitted({error, {not_its_volume, _Why}}) -> answer({refused, sector_size});",
              runs: FINDINGS,
              caught_by: "(finding boot_sector)"),
    Fault.new(name: "FAT12 taken as a malformed boot sector",
              from: "admitted({error, {not_its_volume, fat12}}) -> answer({refused, fat12});\n",
              to: "",
              runs: FINDINGS,
              caught_by: "(refusal fat12)"),
    Fault.new(name: "other sector sizes taken as a malformed boot sector",
              from: "admitted({error, {not_its_volume, sector_size}}) -> answer({refused, sector_size});\n",
              to: "",
              runs: FINDINGS,
              caught_by: "(refusal sector_size)"),
    Fault.new(name: "mirroring off checked",
              from: "Mirrored orelse answer({refused, not_mirrored}),",
              to: "Mirrored orelse true,",
              runs: FINDINGS,
              caught_by: "(refusal not_mirrored)"),
    Fault.new(name: "a bad FSInfo signature passed over",
              from: "unsigned -> finding(St, fsinfo_signature);",
              to: "unsigned -> St;",
              runs: FINDINGS,
              caught_by: "(finding fsinfo_signature)"),
    Fault.new(name: "any FAT header taken as clean",
              from: "header(_Type, _Media, _Head) -> odd.",
              to: "header(_Type, _Media, _Head) -> clean.",
              runs: FINDINGS,
              caught_by: "(finding fat_header)"),
    Fault.new(name: "the dirty flag dropped",
              from: "dirty(St = #st{dirty = Dirty}) -> found_if(Dirty, dirty, St).",
              to: "dirty(St = #st{dirty = Dirty}) -> found_if(Dirty andalso false, dirty, St).",
              runs: FINDINGS,
              caught_by: "(finding dirty)"),
    Fault.new(name: "a link out of range kept",
              from: "            linked(finding(St, {out_of_range_link, Cluster, Value}), Cluster, mask(St#st.type));",
              to: "            St;",
              runs: FINDINGS,
              caught_by: "(finding out_of_range_link)"),
    Fault.new(name: "a cluster linked to twice kept",
              from: "                true -> linked(finding(St, {crossed, Cluster, Next}), Cluster, mask(St#st.type))",
              to: "                true -> St",
              runs: FINDINGS,
              caught_by: "(finding crossed)"),
    Fault.new(name: "a FAT32 root linked to walked",
              from: "marked(Cleared, Root) andalso answer({fatal, root_not_chain}),",
              to: "marked(Cleared, Root) andalso true,",
              runs: FINDINGS,
              caught_by: "(fatal root_not_chain)"),
    Fault.new(name: "a chain into a free cluster kept whole",
              from: "{Links, linked(finding(St1, {chain_end, Head, Marked}), Previous, mask(St1#st.type))}",
              to: "{Links + 1, St1}",
              runs: FINDINGS,
              caught_by: "(finding chain_end)"),
    Fault.new(name: "entries after an end marker passed over",
              from: "                      end, finding(St, {entries_after_end, path(Path)}), Ends),",
              to: "                      end, St, Ends),",
              runs: FINDINGS,
              caught_by: "(finding entries_after_end)"),
    Fault.new(name: "an invalid run before a short entry passed over",
              from: "St1 = found_if(Invalid orelse (Run =/= none andalso not Named), {invalid_long, path(Path, Name)}, St),",
              to: "St1 = found_if(Invalid andalso Named andalso false, {invalid_long, path(Path, Name)}, St),",
              runs: FINDINGS,
              caught_by: "(finding invalid_long)"),
    Fault.new(name: "a run open at the end passed over",
              from: "true -> {deleted(finding(St, {invalid_long_at_end, path(Path)}), Run), Kids};",
              to: "true -> {deleted(St, Run), Kids};",
              runs: FINDINGS,
              caught_by: "(finding invalid_long_at_end)"),
    Fault.new(name: "a run before a label passed over",
              from: "{deleted(found_if(Run =/= none orelse Invalid, invalid_long_label, St), Run), Reset};",
              to: "{deleted(found_if(false, invalid_long_label, St), Run), Reset};",
              runs: FINDINGS,
              caught_by: "(finding invalid_long_label)"),
    Fault.new(name: "order number 0 passed over",
              from: "{St3, D3} = invalidated(finding(St2, invalid_long_name), D2),",
              to: "{St3, D3} = invalidated(St2, D2),",
              runs: FINDINGS,
              caught_by: "(finding invalid_long_name)"),
    Fault.new(name: "a name past the buffer passed over",
              from: "{St3, D3} = invalid_if(not Fits, long_name_too_long, St2, D2),",
              to: "{St3, D3} = invalid_if(not Fits andalso false, long_name_too_long, St2, D2),",
              runs: FINDINGS,
              caught_by: "(finding long_name_too_long)"),
    Fault.new(name: "a long entry's cluster field not read",
              from: "{St4, D4} = invalid_if(Cluster =/= 0, long_cluster, St3, D3),",
              to: "{St4, D4} = invalid_if(Cluster =/= Cluster, long_cluster, St3, D3),",
              runs: FINDINGS,
              caught_by: "(finding long_cluster)"),
    Fault.new(name: "a first cluster out of range taken as claimed",
              from: "false -> {start_out_of_range, path(Path, Name), Head};",
              to: "false -> {not_new_chain, path(Path, Name)};",
              runs: FINDINGS,
              caught_by: "(finding start_out_of_range)"),
    Fault.new(name: "a claimed first cluster passed",
              from: "case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not starts_chain(St, Head) of",
              to: "case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not valid(St, Head) of",
              runs: FINDINGS,
              caught_by: "(finding not_new_chain)"),
    Fault.new(name: "a directory named twice passed over",
              from: "            St1 = deleted(finding(St, {not_new_chain, path([Child | Path])}),",
              to: "            St1 = deleted(St,",
              runs: FINDINGS,
              caught_by: "(finding not_new_chain of a directory named twice)"),
    Fault.new(name: "a directory's size passed over",
              from: "                      _ -> size_set(finding(St, {dir_size, path(Path, Name)}), Place, 0)",
              to: "                      _ -> size_set(St, Place, 0)",
              runs: FINDINGS,
              caught_by: "(finding dir_size)"),
    Fault.new(name: "a wrong `.' passed over",
              from: "        ?DOT when Head =/= Here -> {first_set(finding(St, {dot_cluster, path(Path)}), Step, Place, Here), D};\n",
              to: "",
              runs: FINDINGS,
              caught_by: "(finding dot_cluster)"),
    Fault.new(name: "a non-zero `..' under the root passed over",
              from: "    first_set(finding(St, {dotdot_nonzero, path(Path)}), Step, Place, 0);",
              to: "    first_set(St, Step, Place, 0);",
              runs: FINDINGS,
              caught_by: "(finding dotdot_nonzero)"),
    Fault.new(name: "a wrong `..' passed over",
              from: "    first_set(finding(St, {dotdot_cluster, path(Path)}), Step, Place, Parent);",
              to: "    first_set(St, Step, Place, Parent);",
              runs: FINDINGS,
              caught_by: "(finding dotdot_cluster)"),
    Fault.new(name: "a `.' outside the first two slots passed over",
              from: "        ?DOT when Up =/= [], Slot =/= 0 -> {deleted(finding(St, {dot_out_of_place, dot, path(Path)}), Places), D};\n",
              to: "",
              runs: FINDINGS,
              caught_by: "(finding dot_out_of_place)"),
    Fault.new(name: "a subdirectory's `.' not read",
              from: "DotOk = dot_entry(Dot, ?DOT),",
              to: "DotOk = dot_entry(Dot, ?DOT) orelse true,",
              runs: FINDINGS,
              caught_by: "(finding incorrect_dot)"),
    Fault.new(name: "a subdirectory's `..' not read",
              from: "DotDotOk = dot_entry(DotDot, ?DOTDOT),",
              to: "DotDotOk = dot_entry(DotDot, ?DOTDOT) orelse true,",
              runs: FINDINGS,
              caught_by: "(finding incorrect_dotdot)"),
    Fault.new(name: "an empty file naming no cluster passed",
              from: "                    emptied(finding(St, {invalid_cluster, Shown(), Size, Head}), Place);",
              to: "                    emptied(St, Place);",
              runs: FINDINGS,
              caught_by: "(finding invalid_cluster)"),
    Fault.new(name: "a size past the chain passed",
              from: "Physical < Size -> size_set(finding(St, {size_too_large, Path(), Size, Physical}), Place, Physical);",
              to: "Physical < Size -> size_set(St, Place, Physical);",
              runs: FINDINGS,
              caught_by: "(finding size_too_large)"),
    Fault.new(name: "clusters past the size passed",
              from: "Physical - Size >= ClusterBytes -> trimmed(finding(St, {too_many_clusters, Path()}), Place, Head, Size);",
              to: "Physical - Size >= ClusterBytes -> trimmed(St, Place, Head, Size);",
              runs: FINDINGS,
              caught_by: "(finding too_many_clusters)"),
    Fault.new(name: "a lost chain passed over",
              from: "        {Count, St1} -> named(St1, Head, Count)",
              to: "        {_Count, St1} -> St1",
              runs: FINDINGS,
              caught_by: "(finding lost_chain)"),
    Fault.new(name: "a loop of lost clusters passed over",
              from: "lost(linked(finding(St, {lost_loop, Lowest}), Cluster, mask(St#st.type)), Lowest);",
              to: "lost(linked(St, Cluster, mask(St#st.type)), Lowest);",
              runs: FINDINGS,
              caught_by: "(finding lost_loop)"),
    Fault.new(name: "a wrong free count passed",
              from: "St1 = found_if(Hint =/= ?UNKNOWN andalso Hint =/= Free, {fsinfo_free, Hint, Free}, St),",
              to: "St1 = found_if(Hint =/= ?UNKNOWN andalso Hint =/= Free andalso false, {fsinfo_free, Hint, Free}, St),",
              runs: FINDINGS,
              caught_by: "(finding fsinfo_free)"),
    Fault.new(name: "a next-free hint out of range passed",
              from: "Next >= Clusters + 2 -> finding(St1, {fsinfo_next, Next, invalid});",
              to: "Next >= Clusters + 2 -> St1;",
              runs: FINDINGS,
              caught_by: "(finding fsinfo_next)"),
    Fault.new(name: "a next-free hint at an allocated cluster passed",
              from: "found_if(Value =/= 0, {fsinfo_next, Next, not_free}, St2)",
              to: "found_if(Value =/= Value, {fsinfo_next, Next, not_free}, St2)",
              runs: FINDINGS,
              caught_by: "(finding fsinfo_next not free)"),
    Fault.new(name: "the copies not compared",
              from: "Differs = binary:part(Theirs, 0, byte_size(Used)) =/= Used,",
              to: "Differs = binary:part(Theirs, 0, byte_size(Used)) =:= <<1>>,",
              runs: FINDINGS,
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
              from: "    is_map_key(Cluster, Links) orelse map_size(Links) + Count < ?EDITS_MAX orelse answer({refused, {bound, edits}}),",
              to: "    is_map_key(Cluster, Links) orelse map_size(Links) + Count >= 0 orelse answer({refused, {bound, edits}}),",
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
    output, status = eunit(File.read(File.join(ROOT, CORE)), ErlangBuild.eunit_spec(TESTS))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      seeded = Array(fault.from).zip(Array(fault.to)).reduce(original) do |text, (from, to)|
        assert_equal 1, text.scan(from).size, "#{fault.name}: passage not found once"
        text.sub(from) { to }
      end
      output, status = eunit(seeded, ErlangBuild.eunit_spec(TESTS, fault.runs))
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # Compiles the checker as core_text, with erx_fat and the suite, and runs spec (what
  # eunit:test/2 takes, as ErlangBuild.eunit_spec gives it).
  def eunit(core_text, spec)
    Dir.mktmpdir('erx-fat-check-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e({ 'ERX_FAT_IMAGES' => self.class.images }, 'gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'),
                      '-noshell', '-pa', work,
                      '-eval', ErlangBuild.eunit_eval(spec),
                      chdir: work, stdin_data: '')
    end
  end
end
