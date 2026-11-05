# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The erx_fs grant and the domain's file version counter: test/erlang/erx_fs_tests.erl and
# erx_fs_version_tests.erl run on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies) against the sources as they are, and against each seeded fault of
# docs/design-files.md#verification-and-testing, where the named test must fail.
class ErxFsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[
    erlang/apps/erx/src/generated/erx_9p_grammar.erl
    erlang/apps/erx_files/src/erx_fs_grant.erl
    erlang/apps/erx_files/src/erx_fs.erl
    erlang/apps/erx_files/src/erx_fs_version.erl
  ].freeze
  TESTS = %w[
    test/erlang/erx_fs_test_tree.erl
    test/erlang/erx_fs_stale_tree.erl
    test/erlang/erx_fs_tests.erl
    test/erlang/erx_fs_version_tests.erl
  ].freeze
  GRANT = 'erlang/apps/erx_files/src/erx_fs_grant.erl'
  GRAMMAR = 'erlang/apps/erx/src/generated/erx_9p_grammar.erl'
  VERSION = 'erlang/apps/erx_files/src/erx_fs_version.erl'

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  # Each fault replaces one passage of one source; the test named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a walk of .. at the root asks the tree', file: GRANT,
              from: "walk_step(<<\"..\">>, [_] = Root, _) ->\n    {ok, Root};",
              to: "walk_step(<<\"..\">>, [{Dir, _, _}] = Root, #grant{module = M, fs = T}) ->\n" \
                  "    {ok, _, Qid} = M:walk(Dir, <<\"..\">>, T),\n    {ok, [{Dir, Qid, root} | Root]};",
              caught_by: 'dotdot_stays_at_the_root_test'),
    Fault.new(name: 'a walk continues past a link', file: GRANT,
              from: 'when Type band ?QTDIR =:= 0 ->', to: 'when Type band ?QTDIR =:= -1 ->',
              caught_by: 'walk_through_a_link_stops_at_it_test'),
    Fault.new(name: "a reply goes to another domain's alias", file: GRANT,
              from: "        {ok, Alias, _, _} when node(Alias) =/= Client ->\n            drop;\n",
              to: '', caught_by: 'replies_go_only_to_the_client_domain_test'),
    Fault.new(name: 'an owner of another domain is admitted', file: GRANT,
              from: 'when node(Owner) =/= Client ->', to: "when node(Owner) =/= Client, Client =:= 'none@none' ->",
              caught_by: 'owner_outside_the_domain_is_refused_test'),
    Fault.new(name: 'a fid in use is made again', file: GRANT,
              from: 'is_map_key(Fid, Fids) -> {error, einval};', to: 'is_map_key(Fid, Fids), Fid < 0 -> {error, einval};',
              caught_by: 'fid_in_use_is_refused_test'),
    Fault.new(name: 'the pool admits one fid more', file: GRANT,
              from: 'map_size(Fids) >= Pool -> {error, emfile};', to: 'map_size(Fids) > Pool -> {error, emfile};',
              caught_by: 'fid_flood_stops_at_the_pool_test'),
    Fault.new(name: "an owner's monitor stays after its last fid", file: GRANT,
              from: "                         effects = [{demonitor, Ref} | Effects]};",
              to: "                         effects = element(2, {Ref, Effects})};",
              caught_by: 'monitor_is_removed_at_the_last_fid_test'),
    Fault.new(name: 'an ended owner stays known, so its later fids go unmonitored', file: GRANT,
              from: 'drain(lists:foldl(fun end_fid/2, Grant, maps:keys(Fids)));',
              to: '{Effects, Ended} = drain(lists:foldl(fun end_fid/2, Grant, maps:keys(Fids))),' \
                  "\n            {Effects, Ended#grant{owners = (Ended#grant.owners)\#{Owner => " \
                  '#owner{monitor = Ref, fids = #{}}}}};',
              caught_by: 'ended_owner_leaves_no_fid_test'),
    Fault.new(name: 'a walk that stops keeps its new fid', file: GRANT,
              from: "walked(_, _, _, {stopped, Qids, _}, Grant) ->\n    {{ok, lists:reverse(Qids)}, Grant};",
              to: "walked(Owner, _, NewFid, {stopped, Qids, _}, Grant) ->\n" \
                  "    {{ok, lists:reverse(Qids)}, add_fid(NewFid, Owner, [{1, {16#80, 0, 1}, root}], Grant)};",
              caught_by: 'fid_table_model_test_'),
    Fault.new(name: 'the in-flight bound admits one more', file: GRANT,
              from: 'when InFlight >= ?IN_FLIGHT_MAX ->', to: 'when InFlight > ?IN_FLIGHT_MAX ->',
              caught_by: 'in_flight_bound_test'),
    Fault.new(name: 'an rx grant writes', file: GRANT,
              from: 'case Rights =:= rw orelse', to: 'case Rights =/= ro orelse',
              caught_by: 'read_only_grants_refuse_every_writing_operation_test_'),
    Fault.new(name: 'lcreate loses its writing mark', file: GRAMMAR,
              from: "writes({lcreate, _, _, _, _, _}) ->\n    true;",
              to: "writes({lcreate, _, _, _, _, _}) ->\n    false;",
              caught_by: 'lcreate_is_refused_whatever_its_flags_test'),
    Fault.new(name: 'a refused remove keeps its fid', file: GRANT,
              from: 'refused_remove({remove, Fid}, Grant) -> end_fid_if_held(Fid, Grant);',
              to: 'refused_remove({remove, Fid}, Grant) -> element(1, {Grant, fun end_fid_if_held/2, Fid});',
              caught_by: 'refused_remove_still_clunks_its_fid_test'),
    Fault.new(name: 'the version counter wraps', file: VERSION,
              from: "draw(_, ?LAST) ->\n    {error, eio};",
              to: "draw(Counter, ?LAST) ->\n    {ok, atomics:add_get(Counter, 1, 1)};",
            caught_by: 'the_last_value_is_drawn_once_then_refused_test'),
    Fault.new(name: 'lcreate answers eexist without O_EXCL', file: GRANT,
              from: 'What = {file, Mode band 8#7777, Flags},',
              to: 'What = {file, Mode band 8#7777, Flags bor 8#200},',
              caught_by: 'two_openers_of_one_new_name_both_succeed_test'),
    Fault.new(name: 'lcreate drops O_EXCL', file: GRANT,
              from: 'What = {file, Mode band 8#7777, Flags},',
              to: 'What = {file, Mode band 8#7777, Flags band bnot 8#200},',
              caught_by: 'lcreate_with_exclusive_answers_eexist_test'),
    Fault.new(name: 'a write answers the offset it was sent at', file: GRANT,
              from: '        {ok, Count, At} -> {ok, Count, At};',
              to: '        {ok, Count, _} -> {ok, Count, Offset};',
              caught_by: 'append_answers_order_two_appenders_test'),
    Fault.new(name: 'a write answers its count and offset swapped', file: GRANT,
              from: '        {ok, Count, At} -> {ok, Count, At};',
              to: '        {ok, Count, At} -> {ok, At, Count};',
              caught_by: 'write_answers_where_it_wrote_test'),
    Fault.new(name: "a size change through an open goes by the node's permission", file: GRANT,
              from: '        #{Fid := #fid{open = {open, Node, Handle}}} -> {{to_file, Node, {setattr,',
              to: '        #{Fid := #fid{open = {open, Node, Handle}}} when Node =:= none -> {{to_file, Node, {setattr,',
              caught_by: 'truncate_through_a_read_only_open_is_refused_test'),
    Fault.new(name: "an ended fid keeps its file open", file: GRANT,
              from: '#grant{effects = Effects} = Grant1 = released(Open, Grant#grant{fids = Fids1}),',
              to: '#grant{effects = Effects} = Grant1 = element(3, {fun released/2, Open, Grant#grant{fids = Fids1}}),',
              caught_by: 'owner_end_clunks_its_open_fids_test'),
    Fault.new(name: 'a listing is not fitted to its count', file: GRANT,
              from: '{ok, Entries} -> fit_listing(Entries, Count);',
              to: '{ok, Entries} -> element(2, {fun fit_listing/2, {ok, Entries}});',
              caught_by: 'readdir_over_an_open_directory_test'),
    Fault.new(name: 'a walk starts from an opened fid', file: GRANT,
              from: "        \#{Fid := #fid{open = {open, _, _}}} ->\n            {{error, einval}, Grant};\n" \
                    '        #{Fid := #fid{path = Path}} ->',
              to: "        \#{Fid := #fid{open = {open, _, _}}} when Fid < 0 ->\n            {{error, einval}, Grant};\n" \
                  '        #{Fid := #fid{path = Path}} ->',
              caught_by: 'readdir_over_an_open_directory_test'),
    Fault.new(name: 'remove takes whatever its name names now', file: GRANT,
              from: 'change(unlink, [Dir, Name, {node, Node}], Grant)',
              to: 'change(unlink, [Dir, Name, element(1, {any, Node})], Grant)',
              caught_by: 'remove_after_a_rename_leaves_the_new_name_test'),
    Fault.new(name: 'an alias in flight takes a second request', file: GRANT,
              from: "  when is_map_key(Alias, Pending) ->\n    finish(Alias, Request, {error, einval}",
              to: "  when is_map_key(Alias, Pending), Alias =:= none ->\n    finish(Alias, Request, {error, einval}",
              caught_by: 'an_alias_in_flight_takes_no_second_request_test'),
    Fault.new(name: 'a file answer is taken whatever its tag', file: GRANT,
              from: '#{Alias := #pending{by = Tag}} when is_reference(Tag) -> complete(Alias, Reply, Grant);',
              to: '#{Alias := #pending{}} when is_reference(Tag) -> complete(Alias, Reply, Grant);',
              caught_by: 'file_owner_answers_through_its_tag_test'),
    Fault.new(name: "a directory's make answering a next state is taken for a file's", file: GRANT,
              from: 'changed(make, Other) -> failed(Other);',
              to: "changed(make, {ok, Node, Qid, _}) -> {ok, Node, Qid};\nchanged(make, Other) -> failed(Other);",
              caught_by: 'answers_with_a_state_are_eio_in_the_grant_test'),
    Fault.new(name: 'a malformed answer crashes the grant', file: GRANT,
              from: 'failed(_) -> {error, eio}.',
              to: 'failed(Other) when element(1, Other) =:= error -> {error, eio}.',
              caught_by: 'answers_with_a_state_are_eio_in_the_grant_test'),
    Fault.new(name: 'a reply the grammar rejects keeps the grant its operation built', file: GRANT,
              from: 'false -> {{error, eio}, refused_remove(Request, Before)}',
              to: 'false -> {{error, eio}, refused_remove(Request, element(1, {Built, Before}))}',
              caught_by: 'malformed_qids_change_nothing_test'),
    Fault.new(name: "a rejected reply undoes a remove's clunk", file: GRANT,
              from: 'false -> {{error, eio}, refused_remove(Request, Before)}',
              to: 'false -> {{error, eio}, element(2, {fun refused_remove/2, Before})}',
              caught_by: 'rejected_remove_still_clunks_its_fid_test'),
    Fault.new(name: "a rejected lcreate leaves the tree's handle open", file: GRANT,
              from: "                            _ = Module:clunk(Handle, Fs),\n" \
                    '                            {{error, eio}, Grant}',
              to: '                            {{error, eio}, element(2, {Handle, Grant})}',
              caught_by: 'malformed_qids_leave_the_grant_serving_test'),
    Fault.new(name: 'a listing with an improper tail crashes the file process', file: GRANT,
              from: '    case entries(Entries) of',
              to: '    case is_list(Entries) andalso lists:all(fun(Entry) -> entries([Entry]) end, Entries) of',
              caught_by: 'improper_listing_is_eio_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(fault.file => original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose line for one test: its name, then its verdict on the same line.
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
    end
  end

  private

  # Compiles the sources, with any replaced by the given text, and runs both suites.
  def eunit(replaced)
    Dir.mktmpdir('erx-fs-test') do |work|
      paths = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      compile(work, paths)
      compile(work, TESTS.map { |test| File.join(ROOT, test) })
      # A grant a seeded fault crashes would print a crash report into the middle of
      # EUnit's line for its test; the logger stays quiet so each verdict keeps its line.
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'logger:set_primary_config(level, none), ' \
                      'halt(case eunit:test([erx_fs_tests, erx_fs_version_tests], [verbose]) ' \
                      'of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  def compile(work, paths)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work, '-o', work, *paths,
                                     stdin_data: '')
    assert status.success?, output
  end
end
