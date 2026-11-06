# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_qemu'

# The host side of a QEMU oracle run that needs no guest: what ended the
# run, the files the run left, and where stock's files came from.
class OracleQemuTest < Minitest::Test
  # Stands in for Qemu: writes what Qemu#run would leave in its directory,
  # then raises `error` if it has one.
  class FakeQemu
    def initialize(error: nil, checkpoints: [], serial: nil, report: true)
      @error = error
      @checkpoints = checkpoints
      @serial = serial
      @report = report
    end

    def run(directory:, **)
      FileUtils.mkdir_p(directory)
      log = File.join(directory, 'serial.log')
      File.binwrite(log, @serial) if @serial
      if @report
        File.write(File.join(directory, 'report.json'),
                   JSON.generate('state' => 'x', 'checkpoints' => @checkpoints, 'serial_log' => log,
                                 'elapsed_seconds' => 3.5))
      end
      raise @error if @error
    end
  end

  BOOTED = [{ 'name' => 'bootstrap-memory', 'elapsed_seconds' => 0.1 }].freeze

  def setup
    @directory = Dir.mktmpdir('oracle-qemu-test')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def command_error(state) = Erx::CommandError.new('state' => state, 'log' => '/logs/qemu-tcg.log')

  def guest(qemu) = Erx::OracleQemu.boot_guest(qemu, directory: File.join(@directory, 'guest'), accel: 'tcg')

  def test_a_run_that_reaches_its_result_succeeded
    run = guest(FakeQemu.new(checkpoints: BOOTED, serial: "erx-oracle-result ok\n"))
    assert_equal Erx::OracleQemu::GuestState.new(name: 'succeeded', message: nil), run.state
    assert_equal "erx-oracle-result ok\n", run.serial
    assert_in_delta 3.5, run.record.fetch('elapsed_seconds')
  end

  def test_a_checkpoint_or_command_deadline_is_timed_out
    [Erx::TranscriptTimeout.new('QEMU checkpoint timed out: oracle-result'), command_error('timed_out')].each do |error|
      assert_equal 'timed_out', guest(FakeQemu.new(error: error, checkpoints: BOOTED, serial: '')).state.name
    end
  end

  def test_a_guest_that_ended_after_booting_failed
    [command_error('failed'), Erx::Error.new('QEMU exited before completing its transcript')].each do |error|
      state = guest(FakeQemu.new(error: error, checkpoints: BOOTED, serial: "panic\n")).state
      assert_equal 'failed', state.name
      assert_equal error.message, state.message
    end
  end

  # QEMU that ends before the guest prints a line, as it does on a host
  # without HVF, is the host's failure, not erXos's.
  def test_qemu_ending_before_the_guest_printed_is_qemu_failed_with_its_reason
    state = guest(FakeQemu.new(error: command_error('failed'), serial: '')).state
    assert_equal 'qemu_failed', state.name
    assert_includes state.message, '/logs/qemu-tcg.log'
  end

  def test_an_interrupted_run_is_cancelled
    assert_equal 'cancelled', guest(FakeQemu.new(error: command_error('cancelled'), checkpoints: BOOTED)).state.name
  end

  def test_a_host_failure_before_the_boot_leaves_no_record_and_no_serial
    run = guest(FakeQemu.new(error: Erx::Error.new('guest image does not exist: /x'), report: false))
    assert_equal Erx::OracleQemu::GuestState.new(name: 'host_failed', message: 'guest image does not exist: /x'),
                 run.state
    assert_equal({}, run.record)
    assert_equal '', run.serial
  end

  def test_a_missing_serial_log_reads_as_no_output
    run = guest(FakeQemu.new(error: command_error('failed'), checkpoints: BOOTED))
    assert_equal '', run.serial
  end

  def test_a_host_state_shows_its_reason_and_leaves_open_cases_unknown
    events = File.join(@directory, 'events.jsonl')
    File.write(events, '')
    side = Erx::OracleComparison.side(events: events, command_state: 'qemu_failed', detail: 'command failed; log: q')
    assert_equal 'qemu_failed: command failed; log: q', side.state
    assert_equal 'crashed', Erx::OracleComparison.side(events: events, command_state: 'failed').state
  end

  def stock_tree(files)
    source = File.join(@directory, 'source')
    files.each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(source, path)))
      File.write(File.join(source, path), '')
    end
    source
  end

  def test_stock_sources_are_the_module_source_the_app_src_and_the_appup_src
    source = stock_tree(%w[lib/sasl/src/alarm_handler.erl lib/sasl/src/sasl.app.src lib/sasl/src/sasl.appup.src
                           lib/sasl/doc/x.txt])
    { 'ebin/alarm_handler.beam' => 'src/alarm_handler.erl', 'ebin/sasl.app' => 'src/sasl.app.src',
      'ebin/sasl.appup' => 'src/sasl.appup.src', 'doc/x.txt' => 'doc/x.txt' }.each do |installed, expected|
      assert_equal File.join(source, 'lib/sasl', expected), Erx::OracleQemu.stock_source(source, 'sasl', installed)
    end
  end

  # A module name is case-sensitive though the host's file system may not be: common_test
  # has src/ct_suite.erl and test/ct_SUITE.erl, and only the first is ct_suite's source.
  def test_a_module_source_matches_its_name_case_sensitively
    source = stock_tree(%w[lib/common_test/src/ct_suite.erl lib/common_test/test/ct_SUITE.erl])
    assert_equal File.join(source, 'lib/common_test/src/ct_suite.erl'),
                 Erx::OracleQemu.stock_source(source, 'common_test', 'ebin/ct_suite.beam')
    assert_equal File.join(source, 'lib/common_test/test/ct_SUITE.erl'),
                 Erx::OracleQemu.stock_source(source, 'common_test', 'ebin/ct_SUITE.beam')
  end

  # tools ships emacs/tags.erl, editor support make never compiles, beside src/tags.erl.
  def test_an_applications_emacs_directory_holds_no_module_source
    source = stock_tree(%w[lib/tools/src/tags.erl lib/tools/emacs/tags.erl])
    assert_equal File.join(source, 'lib/tools/src/tags.erl'),
                 Erx::OracleQemu.stock_source(source, 'tools', 'ebin/tags.beam')
  end

  def test_a_stock_file_with_no_source_or_two_module_sources_is_refused
    source = stock_tree(%w[lib/sasl/src/twice.erl lib/sasl/test/twice.erl])
    error = assert_raises(Erx::Error) { Erx::OracleQemu.stock_source(source, 'sasl', 'ebin/twice.beam') }
    assert_match(/has 2 sources for ebin\/twice\.beam/, error.message)
    error = assert_raises(Erx::Error) { Erx::OracleQemu.stock_source(source, 'sasl', 'ebin/sasl.appup') }
    assert_match(/no source for ebin\/sasl\.appup/, error.message)
  end

  def test_a_stand_in_names_its_erxos_source
    source = stock_tree(%w[lib/common_test/src/ct.erl])
    plan = Erx::OracleQemu.stock_plan('common_test', installed: '/tree/lib/common_test', root: '/root', source: source,
                                                     files: %w[ebin/ct.beam priv/jquery-latest.js])
    assert_equal [File.join(source, 'lib/common_test/src/ct.erl'), "/root/#{Erx::OracleQemu::JQUERY}"],
                 plan.map(&:source)
    assert_equal %w[/tree/lib/common_test/ebin/ct.beam /tree/lib/common_test/priv/jquery-latest.js], plan.map(&:path)
  end
end
