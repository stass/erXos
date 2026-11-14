# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the log service's EUnit cases (docs/design-log.md, "Verification and testing"):
# test/erlang/erx_syslog_tests.erl, the service with stand-ins for its take, clock and
# consumers, and test/erlang/erx_console_handoff_tests.erl, the service and the system
# console together, the ring's handoff and the console's lines. Both are compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), with
# test/fixtures/erx_log_standin.erl in place of erx_log, whose NIF stock cannot load.
# Then each seeded fault the design names is compiled in place of its module, and the
# cases must fail on it, which shows they exercise what they guard.
class ErxSyslogTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_syslog_tests.erl test/erlang/erx_console_handoff_tests.erl].freeze
  CASES = %w[erx_syslog_tests erx_console_handoff_tests].freeze
  ERX_LOG = 'erlang/apps/erx/src/erx_log.erl'
  STANDIN = File.read(File.join(ROOT, 'test/fixtures/erx_log_standin.erl')).freeze

  # Each fault: the module it is planted in, the text replaced and its replacement.
  Fault = Data.define(:name, :module, :from, :to)
  CORE = 'erlang/apps/erx/src/erx_syslog_core.erl'
  FAULTS = [
    Fault.new(name: 'a facet that forwards another source', module: 'erlang/apps/erx/src/erx_log_facet.erl',
              from: '{forward, Service, {write, Grantee, Records}, State}',
              to: '{forward, Service, {write, 1, Records}, State}'),
    Fault.new(name: 'a record charged its text alone', module: CORE,
              from: '{ok, Line, byte_size(Line) + 1};', to: '{ok, Line, byte_size(Text)};'),
    Fault.new(name: 'an unbounded backlog', module: CORE,
              from: 'when Bytes =< ?BACKLOG_BYTES ->', to: 'when Bytes >= 0 ->'),
    Fault.new(name: 'a batch sent without a request', module: CORE,
              from: "{{send, Requester, missed(Now, System, Backlog) ++ Batch},\n     #backlog{}};",
              to: "{{send, Requester, missed(Now, System, Backlog) ++ Batch},\n     #backlog{waiting = {waiting, Requester}}};"),
    Fault.new(name: "a store's batch sent before it is due", module: CORE,
              from: 'Bytes >= ?STORE_BATCH_BYTES orelse Now - Oldest >= ?STORE_WAIT_NS', to: 'Oldest >= 0'),
    Fault.new(name: 'a restart that says start', module: 'erlang/apps/erx/src/erx_syslog.erl',
              from: '<<"erx_syslog: restarted">>;', to: '<<"erx_syslog: start">>;'),
    Fault.new(name: "the escape removed from line/5's text", module: CORE,
              from: 'erx_text:escape_line(Name), <<": ">>, erx_text:escape_line(Text)]',
              to: 'erx_text:escape_line(Name), <<": ">>, Text]'),
    Fault.new(name: 'a console that takes the ring', module: 'erlang/apps/erx/src/erx_console.erl',
              from: "log_ask() ->\n    {asked, erx_syslog:next(console)}.",
              to: "log_ask() ->\n    _ = erx_log:take(),\n    {asked, erx_syslog:next(console)}.")
  ].freeze

  def test_service_cases_pass_under_eunit
    Dir.mktmpdir('erx-syslog-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { ERX_LOG => STANDIN })
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = File.read(File.join(ROOT, fault.module))
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{fault.module}"
      Dir.mktmpdir('erx-syslog-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { ERX_LOG => STANDIN, fault.module => text.sub(fault.from, fault.to) })
        output, status = eunit(work)
        refute status.success?, "#{fault.name}: the cases passed with it:\n#{output}"
      end
    end
  end

  private

  def eunit(work)
    eval = "halt(case eunit:test([#{CASES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)."
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', eval, chdir: work, stdin_data: '')
  end
end
