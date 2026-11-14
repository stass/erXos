# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/fuzz/erx_log_facet'

# Runs test/erlang/erx_log_facet_tests.erl, the EUnit cases of the log facet's request
# decoder (docs/design-log.md, "Verification and testing", facet bounds), compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). Then each
# seeded fault the design names, a bound removed from the decoder, is compiled in place
# of it, and the cases must fail on it, which shows they exercise what they guard.
class ErxLogFacetTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_log_facet_tests.erl].freeze
  CASES = 'erx_log_facet_tests'
  DECODER = 'erlang/apps/erx/src/erx_log_facet.erl'
  ROOT = File.expand_path('../..', __dir__)

  # Each fault: the text of the decoder replaced and its replacement.
  Fault = Data.define(:name, :from, :to)
  FAULTS = [
    Fault.new(name: 'the 16-record bound removed',
              from: 'records([Record | Rest], Count) when Count < ?ERX_LOG_WRITE_MAX ->',
              to: 'records([Record | Rest], Count) when is_integer(Count) ->'),
    Fault.new(name: 'the 16-record bound one record long',
              from: 'records([Record | Rest], Count) when Count < ?ERX_LOG_WRITE_MAX ->',
              to: 'records([Record | Rest], Count) when Count =< ?ERX_LOG_WRITE_MAX ->'),
    Fault.new(name: 'the 4,096-byte text bound removed',
              from: 'when is_binary(Text), byte_size(Text) =< ?ERX_LOG_WRITE_TEXT_MAX ->',
              to: 'when is_binary(Text) ->'),
    Fault.new(name: 'the level check removed',
              from: 'erx_syslog_core:is_level(Level);', to: 'true;')
  ].freeze

  def test_decoder_cases_pass_under_eunit
    Dir.mktmpdir('erx-log-facet-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = eunit(work)
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  def test_each_seeded_fault_is_caught
    text = File.read(File.join(ROOT, DECODER))
    FAULTS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{DECODER}"
      Dir.mktmpdir('erx-log-facet-fault') do |work|
        ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS,
                                  replaced: { DECODER => text.sub(fault.from, fault.to) })
        output, status = eunit(work)
        refute status.success?, "#{fault.name} passed #{CASES}:\n#{output}"
        assert_match(/Failed: [1-9]/, output, fault.name)
      end
    end
  end

  # The fuzz target's seeded faults run only at the milestone gate; their texts are
  # checked here, at every landing, so an edit of the decoder updates them too.
  def test_fuzz_seeds_still_name_the_decoder
    text = File.read(File.join(ROOT, DECODER))
    ErxLogFacetFuzz::SEEDS.each do |fault|
      assert_equal 1, text.scan(fault.from).size, "fuzz seed #{fault.name}: its text must occur once in #{DECODER}"
    end
  end

  private

  def eunit(work)
    Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                    '-eval', "halt(case eunit:test(#{CASES}, []) of ok -> 0; _ -> 1 end)",
                    chdir: work, stdin_data: '')
  end
end
