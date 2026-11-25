# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/erx_login_facet'

# Runs test/erlang/erx_login_core_tests.erl, the login service's core against
# docs/design-login.md's table of a row's states, and test/erlang/erx_login_tests.erl,
# the service behind it with stand-ins for the domain service and the checker, and
# test/erlang/erx_login_facet_tests.erl, a real login facet in front of the service, on
# stock's emulator (ERX_ERL and ERX_ERLC). Then each seeded fault of the design's
# "Verification" table, applied to a copy of its module, must fail the case named for it.
class ErxLoginTest < Minitest::Test
  APPLICATIONS = %w[erx erx_domain].freeze
  TESTS = %w[test/erlang/erx_login_core_tests.erl test/erlang/erx_login_tests.erl
             test/erlang/erx_login_facet_tests.erl].freeze
  MODULES = %w[erx_login_core_tests erx_login_tests erx_login_facet_tests].freeze
  HOST_BYTES = { 'erlang/apps/erx/src/erx_bytes.erl' => 'test/erlang/host_bytes/erx_bytes.erl' }.freeze
  DEADLINE_SECONDS = '300'
  CORE = 'erlang/apps/erx_domain/src/erx_login_core.erl'
  SERVICE = 'erlang/apps/erx_domain/src/erx_login.erl'
  FACET = 'erlang/apps/erx_domain/src/erx_login_facet.erl'
  BEHAVIOUR = 'erlang/apps/erx/src/erx_facet.erl'
  SUPERVISOR = 'erlang/apps/erx_domain/src/erx_domain_sup.erl'

  Seed = Data.define(:fault, :path, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a pending row that admits a second login_passphrase',
             path: CORE, anchor: 'when State =:= pending; State =:= logged_in ->',
             replacement: 'when State =:= logged_in ->',
             catching_case: 'checking_from_none x login_passphrase'),
    Seed.new(fault: "a key match that keeps the row's way back to its cookie", path: CORE,
             anchor: 'Row#{phase := starting, step := Step, back := none}', replacement: 'Row#{phase := starting, step := Step}',
             catching_case: 'a_key_match_retires_the_cookie_test'),
    Seed.new(fault: 'the bound compared with >', path: CORE, anchor: 'Held when Held < Logins ->',
             replacement: 'Held when Held =< Logins ->', catching_case: 'the_logins_th_row_is_taken_and_the_next_refused_test'),
    Seed.new(fault: 'the stop removed, so a session runs with no line', path: SERVICE,
             anchor: "    ok = Domain:stop(Session, shutdown),\n", replacement: '',
             catching_case: 'a_refused_mint_stops_the_session_it_started_test_'),
    Seed.new(fault: 'a missing checker read as a match', path: SERVICE,
             anchor: 'core({answer, Step, unavailable}, S)', replacement: 'core({answer, Step, {match, 42}}, S)',
             catching_case: 'with_no_checker_a_passphrase_login_answers_unavailable_test_'),
    Seed.new(fault: 'the sensitive flag removed', path: SERVICE,
             anchor: "    process_flag(sensitive, true),\n    true = register", replacement: '    true = register',
             catching_case: 'the_service_s_queue_is_hidden_test_'),
    Seed.new(fault: 'the status view removed', path: SERVICE,
             anchor: 'erx_report:status(Status, #{state => fun view/1})', replacement: 'Status',
             catching_case: 'a_crash_holding_a_passphrase_logs_none_of_it_test_'),
    Seed.new(fault: "the facet's sensitive flag removed", path: FACET,
             anchor: "    process_flag(sensitive, true),\n    Line = line(Text),", replacement: '    Line = line(Text),',
             catching_case: 'the_facet_s_queue_is_hidden_test_'),
    Seed.new(fault: 'the holder dropped from the terminal', path: FACET,
             anchor: 'logins => Logins, holder => Holder}', replacement: 'logins => Logins, holder => <<>>}',
             catching_case: 'the_terminal_is_the_grant_s_holder_test_'),
    Seed.new(fault: "the facet's cut reason removed", path: BEHAVIOUR,
             anchor: 'exit(erx_report:reason_name(Reason)).', replacement: 'exit(Reason).',
             catching_case: 'another_front_end_sees_no_passphrase_test_'),
    Seed.new(fault: "erx:call_from/3's domain check removed", path: BEHAVIOUR,
             anchor: 'erx:call_from(Grantee, From, fun Exports:owner/1) of',
             replacement: '(erx:call_from(Grantee, From, fun Exports:owner/1) orelse true) of',
             catching_case: 'a_forged_caller_reaches_no_row_test_'),
    Seed.new(fault: "the supervisor's intensity left at OTP's default", path: SUPERVISOR,
             anchor: 'intensity => Permanent, period => ?PERIOD_S}', replacement: 'period => ?PERIOD_S}',
             catching_case: 'each_permanent_child_restarts_once_within_the_period_test'),
    Seed.new(fault: 'a user name checked by a rule of its own that admits any name', path: FACET,
             anchor: 'case erx_ident:new(User) of', replacement: 'case erx_ident:new(<<"a">>) of',
             catching_case: 'a_user_name_is_a_system_identifier_test'),
    Seed.new(fault: "root_line's caller named as the opening, so the line outlives the grant", path: CORE,
             anchor: '{mint, Step, Line, {console, Console}, Grantee, Facet}',
             replacement: '{mint, Step, Line, {console, Console}, Grantee, Owner}',
             catching_case: 'root_line_mints_the_console_s_session_with_the_facet_as_opening_test'),
    Seed.new(fault: "a failed root_line mint taken as a login's, which stops the console's session", path: CORE,
             anchor: 'Stop = [{stop, Session} || #{session := Session} <- [Row]],',
             replacement: 'Stop = [{stop, maps:get(session, Row, console)}],',
             catching_case: 'root_minting answered')
  ].freeze

  def test_the_cases_pass
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
      # A generated case names itself before *failed*; a fixture case, after it, in the
      # failure's location.
      name = Regexp.escape(seed.catching_case)
      assert_match(/#{name}[^\n]*\*failed\*|\*failed\*\s*\nin function [^\n]*#{name}/, output, seed.fault)
    end
  end

  def test_fuzz_seeds_still_name_the_facet
    text = File.read(File.join(ErlangBuild::ROOT, ErxLoginFacetFuzz::FACET))
    ErxLoginFacetFuzz::SEEDS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "fuzz seed #{fault.name}: its text must occur once"
    end
  end

  private

  def run_cases(replaced)
    stand_ins = HOST_BYTES.transform_values { |path| File.binread(File.join(ErlangBuild::ROOT, path)) }
    Dir.mktmpdir('erx-login-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: stand_ins.merge(replaced))
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-kernel', 'logger', '[{handler, default, undefined}]',
                      '-eval', "halt(case eunit:test([#{MODULES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)",
                      chdir: work, stdin_data: '')
    end
  end
end
