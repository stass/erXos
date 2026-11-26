# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bt_registry_tests.erl, the cases of the registry's core,
# erx_gatt_registry, and of its process, erx_gatt_srv, over stand-in links and handlers,
# compiled from source on stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault,
# applied to a copy of its module, must fail the case named for it.
class ErxBtRegistryTest < Minitest::Test
  APPLICATIONS = %w[erx_bt].freeze
  TESTS = %w[test/erlang/erx_bt_registry_tests.erl].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_bt/src/erx_gatt_registry.erl'
  SRV = 'erlang/apps/erx_bt/src/erx_gatt_srv.erl'

  Seed = Data.define(:fault, :path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: "the join's address copied into the connected event",
             path: CORE, anchor: '      | connected_events(Conn, Security, Core)],',
             replacement: '      | [{event, H, {connected, Conn, Security#{address => Address}}} ' \
                          '|| H <- lists:usort(maps:values(Core#core.handlers))]],',
             catching_case: 'connected_holds_the_level_and_bond'),
    Seed.new(fault: "the link's MTU dropped from the replay",
             path: CORE, anchor: ' ++ [{mtu, Conn, Mtu} || New, Mtu =/= none] ++',
             replacement: ' ++ [] ++',
             catching_case: 'attach_replays_a_connected_link'),
    Seed.new(fault: "the advertised set told at an attach only, so a handler's end leaves its UUID advertised",
             path: CORE, anchor: '            {advertising(Core, Next), Next}',
             replacement: '            {[], Next}',
             catching_case: 'advertised_follows_the_handlers'),
    Seed.new(fault: "a service's values set and sent by any process, not only its handler",
             path: CORE, anchor: '        #{Service := Caller} -> ok;',
             replacement: '        #{Service := _} -> ok;',
             catching_case: 'set_notify_and_indicate_only_from_the_handler'),
    Seed.new(fault: 'an answer taken from any handler, not only the one its write went to',
             path: CORE, anchor: '        #{Req := {Caller, Link, Ref}} ->',
             replacement: '        #{Req := {_, Link, Ref}} ->',
             catching_case: 'an answer is taken once, from its handler'),
    Seed.new(fault: "a link's end leaving its writes, so a late answer goes to a dead link",
             path: CORE, anchor: 'writes = without_link(Pid, Writes)}};',
             replacement: 'writes = Writes}};',
             catching_case: 'every_sequence_of_four_keeps_the_model'),
    Seed.new(fault: "a link's new write leaving its earlier one, so the writes grow and a late answer is taken",
             path: CORE, anchor: '    Writes = without_link(Link, Core#core.writes),',
             replacement: '    Writes = Core#core.writes,',
             catching_case: 'every_sequence_of_four_keeps_the_model'),
    Seed.new(fault: 'a handler of two services hearing a link event twice',
             path: CORE, anchor: '[{event, Handler, Event} || Handler <- lists:usort(maps:values(Handlers))]',
             replacement: '[{event, Handler, Event} || Handler <- maps:values(Handlers)]',
             catching_case: 'every_sequence_of_four_keeps_the_model'),
    Seed.new(fault: 'a join answering values older than the last set',
             path: CORE, anchor: '{reply, From, #{table => Core#core.table, values => Core#core.values}}',
             replacement: '{reply, From, #{table => Core#core.table, values => #{}}}',
             catching_case: 'a join racing sets misses none'),
    Seed.new(fault: 'a set not passed on to the joined links',
             path: CORE, anchor: '{to_link, Link, {set, Key, Value}} || Link := _',
             replacement: '{to_link, Link, {set, Key, Value}} || false, Link := _',
             catching_case: 'a join racing sets misses none'),
    Seed.new(fault: "a notification whose link ended left unanswered, so its caller waits",
             path: SRV, anchor: '            gen_server:reply(From, {error, gone}),',
             replacement: '            _ = From,',
             catching_case: 'a link ending mid-notification answers gone')
  ].freeze

  def test_registry_cases_pass_under_eunit
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      source = File.binread(File.join(ErlangBuild::ROOT, seed.path))
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ seed.path => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}(?:(?!erx_bt_registry_tests: ).)*?\*failed\*/m,
                   output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-bt-registry-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', 'halt(case eunit:test([erx_bt_registry_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
