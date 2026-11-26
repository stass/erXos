# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_store_tests.erl, the cases of the Bluetooth store: erx_bt_state's
# layout, erx_bt_state_file and erx_bt_store against a scripted backend, compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC) with erx_bytes's host stand-in. Then
# each seeded fault of docs/design-bluetooth.md, "Host tests of the cores", and of the
# store's own checks, applied to a copy of its module, must fail the case named for it.
class ErxBtStoreTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_store_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  STATE = 'erlang/apps/erx_bt/src/erx_bt_state.erl'
  STORE = 'erlang/apps/erx_bt/src/erx_bt_store.erl'
  STATE_FILE = 'erlang/apps/erx_bt/src/erx_bt_state_file.erl'

  Seed = Data.define(:fault, :module_path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the bond count read without its bound',
             module_path: STATE,
             anchor: 'Count =< ?ERX_BT_BONDS_MAX orelse refuse({too_many_bonds, Count}),',
             replacement: '',
             catching_case: 'state_refuses_oversized_count_test'),
    Seed.new(fault: 'unavailable read as none, so a pairing overwrites the stored bonds',
             module_path: STORE,
             anchor: "_Unavailable ->\n            {{error, store_unavailable}, Store}",
             replacement: "_Unavailable ->\n            {{ok, none}, Store}",
             catching_case: 'start_unreadable_refuses_changes_until_forget_all_test_'),
    Seed.new(fault: 'the pre-put state kept after an unconfirmed put, so the failed pairing\'s bond is lost',
             module_path: STORE,
             anchor: 'unconfirmed(Store) -> Store#store{known = {unknown, put}, reason = store_unavailable}.',
             replacement: 'unconfirmed(Store) -> Store.',
             catching_case: 'unconfirmed_put_reads_before_the_next_change_test'),
    Seed.new(fault: 'the backend called with no deadline',
             module_path: STORE,
             anchor: 'after Timeout ->',
             replacement: 'after infinity ->',
             catching_case: 'backend_that_never_answers_test_'),
    Seed.new(fault: "the store taking a link's pid only at keep",
             module_path: STORE,
             anchor: '{reply, resolved(Bond), watch(Link, Id, Store)}',
             replacement: '{reply, resolved(Bond), Store}',
             catching_case: 'forget_ends_the_links_of_that_bond_test'),
    Seed.new(fault: "forget matching a bond's octets alone, so a random and a public bond of the same octets go together",
             module_path: STORE,
             anchor: 'case [Bond || #{Key := Other} = Bond <- Bonds, Other =/= Target] of',
             replacement: 'case [Bond || #{Key := Other} = Bond <- Bonds, Key =:= id andalso Other =/= Target ' \
                          'orelse Key =:= identity andalso element(2, Other) =/= element(2, Target)] of',
             catching_case: 'forget_matches_the_whole_identity_test'),
    Seed.new(fault: 'resolve answering the bond with its IRK',
             module_path: STORE,
             anchor: '{reply, resolved(Bond), watch(Link, Id, Store)}',
             replacement: '{reply, Bond, watch(Link, Id, Store)}',
             catching_case: 'resolve_answers_one_bond_without_any_irk_test'),
    Seed.new(fault: 'an all-zero IRK resolving the addresses made with it',
             module_path: STORE,
             anchor: 'Irk =/= <<0:128>> andalso crypto:hash_equals',
             replacement: 'true andalso crypto:hash_equals',
             catching_case: 'resolve_answers_one_bond_without_any_irk_test'),
    Seed.new(fault: 'the raw state shown in the status',
             module_path: STORE,
             anchor: 'store_facts(#store{} = Store) -> facts(Store);',
             replacement: 'store_facts(#store{} = Store) -> Store;',
             catching_case: 'no_key_in_status_or_crash_test'),
    Seed.new(fault: 'a keep refused without telling the window',
             module_path: STORE,
             anchor: "{erx_bt_fs, node()} ! {outcome, Link, Tag, Outcome},",
             replacement: "element(1, Answer) =:= ok andalso ({erx_bt_fs, node()} ! {outcome, Link, Tag, Outcome}),",
             catching_case: 'explored_store_table_test_'),
    Seed.new(fault: 'forget all refused while the start left the store unknown',
             module_path: STORE,
             anchor: "call({forget, all}, _From, Store) ->\n    {Answer, Next} = forget_all(Store),",
             replacement: "call({forget, all}, _From, Store) ->\n    {Answer, Next} = case Store#store.known of " \
                          "read -> forget_all(Store); _ -> {{error, eio}, Store} end,",
             catching_case: 'explored_store_table_test_'),
    Seed.new(fault: 'a failed forget all after the start leaving the store to read the old bonds under a new address',
             module_path: STORE,
             anchor: '{unconfirmed, Unconfirmed} when Known =:= {unknown, start} -> {{error, eio}, Unconfirmed};',
             replacement: '',
             catching_case: 'failed_forget_all_after_an_unread_start_changes_nothing_test'),
    Seed.new(fault: 'resolve refused while a put is unconfirmed, so kept bonds stop working on a trial boot',
             module_path: STORE,
             anchor: 'call({resolve, Address}, {Link, _}, #store{bonds = Bonds} = Store) ->',
             replacement: 'call({resolve, Address}, {Link, _}, #store{known = read, bonds = Bonds} = Store) ->',
             catching_case: 'kept_bonds_resolve_after_an_unconfirmed_put_test'),
    Seed.new(fault: 'the development file read at its lowest generation, so a late put wins',
             module_path: STATE_FILE,
             anchor: 'newest(filename:join(Dir, name(state, lists:max(Kept))), Highest)',
             replacement: 'newest(filename:join(Dir, name(state, lists:min(Kept))), Highest)',
             catching_case: 'late_put_never_brings_back_a_forgotten_bond_test_'),
    Seed.new(fault: 'an unconfirmed put not counted, so the next put reuses its generation',
             module_path: STORE,
             anchor: '{Answer, Store#store{generation = Generation}}.',
             replacement: '{Answer, case Answer of ok -> Store#store{generation = Generation}; _ -> Store end}.',
             catching_case: 'late_put_never_brings_back_a_forgotten_bond_test_'),
    Seed.new(fault: 'a .new name not counted, so a put may still land above the generation read',
             module_path: STATE_FILE,
             anchor: 'Highest = lists:max([0 | [N || {_, N} <- Named]]),',
             replacement: 'Highest = lists:max([0 | [N || {state, N} <- Named]]),',
             catching_case: 'state_file_test'),
    Seed.new(fault: 'the directory synced after the deletions, so a deletion may reach the medium before the rename',
             module_path: STATE_FILE,
             anchor: "        ok ?= sync_dir(Dir),\n        delete_below(Dir, Generation)\n",
             replacement: "        ok ?= delete_below(Dir, Generation),\n        sync_dir(Dir)\n",
             catching_case: 'state_file_syncs_directory_after_rename_test'),
    Seed.new(fault: 'a failed put\'s .new file left behind',
             module_path: STATE_FILE,
             anchor: '            _ = file:delete(New),',
             replacement: '',
             catching_case: 'state_file_step_failing_under_the_store_test'),
    Seed.new(fault: 'the file not narrowed to 0600, so the umask decides who reads the keys',
             module_path: STATE_FILE,
             anchor: '                      ok ?= kept_modes(file:change_mode(Path, 8#600)),',
             replacement: '',
             catching_case: 'state_file_modes_test'),
    Seed.new(fault: 'forget all put without reading, below a generation the start could not read',
             module_path: STORE,
             anchor: "    case read(Store) of\n        {{error, store_unavailable}, _} ->",
             replacement: "    case {ok, Store} of\n        {{error, store_unavailable}, _} ->",
             catching_case: 'start_unreadable_refuses_changes_until_forget_all_test_'),
    Seed.new(fault: "a stored bond's random identity read without the static form",
             module_path: STATE,
             anchor: 'error -> refuse(identity)',
             replacement: 'error -> {random, Octets}',
             catching_case: 'state_refuses_malformed_fields_test'),
    Seed.new(fault: "erXos's stored address read without the static form",
             module_path: STATE,
             anchor: 'erx_smp_crypto:static_random(Address) orelse refuse(address),',
             replacement: '',
             catching_case: 'state_refuses_malformed_fields_test'),
    Seed.new(fault: "the decoder's check for a shared id dropped",
             module_path: STATE,
             anchor: '    distinct([Id || #{id := Id} <- Bonds]) orelse refuse(duplicate_id),',
             replacement: '',
             catching_case: 'state_refuses_a_shared_id_test'),
    Seed.new(fault: "the id taken from the count of bonds kept, so the bond after a lost state gets the first bond's id",
             module_path: STORE,
             anchor: '    <<_:128>> = Drawn = Draw(),',
             replacement: '    <<_:128>> = Drawn = <<(length(Bonds) + 1):128>>,',
             catching_case: 'bond_id_owes_nothing_to_a_lost_state_test'),
    Seed.new(fault: 'the id computed from the address, so the second pairing of one address gets the first id',
             module_path: STORE,
             anchor: 'admit(Bond#{id => fresh_id(Draw, Bonds)}, Bonds)',
             replacement: 'admit(Bond#{id => binary:encode_hex(<<0:80, (element(2, Identity))/binary>>, lowercase)}, Bonds)',
             catching_case: 'bond_id_is_drawn_at_keep_test'),
    Seed.new(fault: 'the redraw dropped, so two kept bonds share an id, which the next encode refuses',
             module_path: STORE,
             anchor: '        true -> fresh_id(Draw, Bonds);',
             replacement: '        true -> Id;',
             catching_case: 'bond_id_drawn_again_on_a_clash_test'),
    Seed.new(fault: 'the bonds compared by their octets alone, so the second identity of one address fails already_bonded',
             module_path: STORE,
             anchor: '    case lists:any(fun(#{identity := Kept}) -> Kept =:= Identity end, Bonds) of',
             replacement: '    case lists:any(fun(#{identity := {_, Kept}}) -> Kept =:= element(2, Identity) end, Bonds) of',
             catching_case: 'two_identities_of_one_address_test')
  ].freeze

  def test_store_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.module_path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.module_path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*?\.\.\.(?:(?!erx_bt_store_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, seed.fault)
    end
  end

  private

  # The modules, erx_bytes's stand-in and the replaced ones in place of the application's
  # own, then the cases.
  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-store-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test([erx_bt_store_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
