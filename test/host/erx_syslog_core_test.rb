# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_syslog_core_tests.erl, the EUnit cases of the log service's pure
# core (docs/design-log.md, "Verification and testing": the escape in
# erx_syslog_core:line/5 and the rate table), compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies) over the line escape's vectors. Then
# each seeded fault the design names is compiled in place of the core, and the cases
# must fail on it, which shows they exercise what they guard.
class ErxSyslogCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_syslog_core_tests.erl].freeze
  CASES = 'erx_syslog_core_tests'
  VECTORS = File.join(ROOT, 'test/fixtures/line_escape_vectors.json')
  CORE = 'erlang/apps/erx/src/erx_syslog_core.erl'

  # Each fault: the text of the core replaced and its replacement.
  Fault = Data.define(:name, :from, :to)
  FAULTS = [
    Fault.new(name: "the escape removed from line/5's text",
              from: 'erx_text:escape_line(Name), <<": ">>, erx_text:escape_line(Text)]',
              to: 'erx_text:escape_line(Name), <<": ">>, Text]'),
    Fault.new(name: "the escape removed from line/5's name",
              from: 'erx_text:escape_line(Name), <<": ">>, erx_text:escape_line(Text)]',
              to: 'Name, <<": ">>, erx_text:escape_line(Text)]'),
    Fault.new(name: 'a record charged its text alone',
              from: '{ok, Line, byte_size(Line) + 1};', to: '{ok, Line, byte_size(Text)};'),
    Fault.new(name: 'an entry kept across the turn',
              from: '{Lines, new(Now)};', to: '{Lines, {Now div ?NS_PER_S, Domains}};'),
    Fault.new(name: 'a turn within the second',
              from: 'Now div ?NS_PER_S > Second ->', to: 'Now div ?NS_PER_S >= Second ->'),
    Fault.new(name: 'the rate one byte short',
              from: 'Charged + Cost =< ?ERX_LOG_RATE_BYTES ->', to: 'Charged + Cost < ?ERX_LOG_RATE_BYTES ->'),
    Fault.new(name: 'drops lines in the map\'s order',
              from: '<- lists:sort(maps:to_list(Domains)),', to: '<- maps:to_list(Domains),')
  ].freeze

  def test_core_cases_pass_under_eunit
    Dir.mktmpdir('erx-syslog-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    text = File.read(File.join(ROOT, CORE))
    FAULTS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{CORE}"
      Dir.mktmpdir('erx-syslog-core-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { CORE => text.sub(fault.from, fault.to) })
        output, status = eunit(work)
        refute status.success?, "#{fault.name} passed #{CASES}:\n#{output}"
        assert_match(/Failed: [1-9]/, output, fault.name)
      end
    end
  end

  private

  def eunit(work)
    Open3.capture2e({ 'ERX_TEXT_VECTORS' => VECTORS },
                    'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', "halt(case eunit:test(#{CASES}, []) of ok -> 0; _ -> 1 end)",
                    chdir: work, stdin_data: '')
  end
end
