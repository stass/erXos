# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the virtio-blk device process's deadline cases (test/erlang/erx_blk_virtio_tests.erl)
# over a device the test plays (test/erlang/stand_in/erx_device.erl), compiled from source
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). erx_blk_virtio is
# compiled with its wait limit and in-flight bound shortened, and the cases are given the
# same values, so a case waits a fraction of a second. Then each seeded fault is compiled
# in place of the module, and the cases must fail on it.
class ErxBlkVirtioTest < Minitest::Test
  APPLICATIONS = %w[erx erx_blk].freeze
  TESTS = %w[test/erlang/stand_in/erx_device.erl test/erlang/stand_in/erx_irq_line.erl
             test/erlang/erx_blk_virtio_tests.erl].freeze
  DRIVER = 'erlang/apps/erx_blk/src/erx_blk_virtio.erl'
  ROOT = File.expand_path('../..', __dir__)
  # erx_log's NIF does not load on stock's emulator; its stand-in keeps nothing.
  LOG = 'erlang/apps/erx/src/erx_log.erl'
  LOG_STAND_IN = File.read(File.join(ROOT, 'test/fixtures/erx_log_standin.erl')).freeze
  WAIT_LIMIT_MS = 100
  IN_FLIGHT_MS = 300
  # The bounds' definitions in the driver, each replaced by its shortened value.
  BOUNDS = {
    '-define(WAIT_LIMIT_MS, ?ERX_BLK_WAIT_LIMIT_MS).' => "-define(WAIT_LIMIT_MS, #{WAIT_LIMIT_MS}).",
    '-define(IN_FLIGHT_MS, ?ERX_BLK_IN_FLIGHT_MS).' => "-define(IN_FLIGHT_MS, #{IN_FLIGHT_MS})."
  }.freeze

  Fault = Data.define(:name, :from, :to)
  FAULTS = [
    Fault.new(name: 'no in-flight deadline',
              from: '[Posted + ?IN_FLIGHT_MS || {_From, _Request, Posted} <- maps:values(Pending)]',
              to: '[]'),
    Fault.new(name: 'wait limit unchecked',
              from: 'fun({_From, _Op, Accepted}) -> Now - Accepted >= ?WAIT_LIMIT_MS end',
              to: 'fun({_From, _Op, Accepted}) -> Now - Accepted >= ?WAIT_LIMIT_MS * 1000 end')
  ].freeze

  def test_deadline_cases_pass_under_eunit
    output, status = run_cases(shortened)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_is_caught
    FAULTS.each do |fault|
      text = shortened
      assert_equal 1, text.scan(fault.from).size, "#{fault.name}: its text must occur once in #{DRIVER}"
      output, status = run_cases(text.sub(fault.from, fault.to))
      refute status.success?, "#{fault.name} passed:\n#{output}"
      assert_match(/Failed: [1-9]/, output, fault.name)
    end
  end

  private

  def shortened
    BOUNDS.reduce(File.read(File.join(ROOT, DRIVER))) do |text, (from, to)|
      assert_equal 1, text.scan(from).size, "#{from} must occur once in #{DRIVER}"
      text.sub(from, to)
    end
  end

  def run_cases(driver)
    Dir.mktmpdir('erx-blk-virtio-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { DRIVER => driver, LOG => LOG_STAND_IN },
                                defines: ["SHORT_WAIT_LIMIT_MS=#{WAIT_LIMIT_MS}", "SHORT_IN_FLIGHT_MS=#{IN_FLIGHT_MS}"])
      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_blk_virtio_tests, []) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
