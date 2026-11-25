# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'socket'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/xdomain_bench'

# The xdomain guest as Linux's Erlang guest runs it (docs/design-bench.md, "Linux's
# Erlang guest", "Verification"), on two nodes of the host's stock OTP 29.1.2: an echo
# node whose erx_xdomain_bench:serve/1 registers the echo, and a client node whose
# erx_bench_hist:main/1 prints the oracle's identity line and the cells' lines, which
# the xdomain boot's judge accepts in clock monotonic. An echo node with another cookie
# refuses the connection, so xdomain-pingpong fails while local-rtt is measured: the
# cross cell went to the other OS process over distribution.
class XdomainStockNodesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FLAVOUR = 'jit'
  MODULES = %w[erx_bench_hist erx_xdomain_bench].freeze
  ECHO = 'bench_echo@127.0.0.1'
  CLIENT = 'bench_client@127.0.0.1'
  ECHO_NAME = 'erx_xdomain_echo'
  # How long the client may take: the echo node's start, the calibration and the cells.
  CLIENT_SECONDS = 120

  def setup
    skip "the #{FLAVOUR} oracle is not built here (make oracle-bootstrap)" unless
      File.directory?(File.join(ROOT, "build/oracle/#{FLAVOUR}/install"))
    @directory = Dir.mktmpdir('erx-xdomain-stock-')
    # A port of its own for epmd, so the test neither meets nor leaves a node in the
    # host's epmd.
    @env = { 'ERL_EPMD_PORT' => TCPServer.open('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } }.to_s }
    @echo = nil
  end

  def teardown
    stop_echo
    @epmd && system(@env, @epmd, '-kill', out: File::NULL, err: File::NULL)
    @directory && FileUtils.remove_entry(@directory)
  end

  def test_the_client_measures_both_cells_against_the_echo_node
    lines = client(echo_cookie: 'bench')
    assert_equal "ERX_ORACLE 29.1.2 #{FLAVOUR}", lines.first
    answer = judged(lines)
    assert_empty answer.fetch(:refused)
    assert_equal 'monotonic', answer.fetch(:clock).fetch('clock')
    assert_equal({ 'local-rtt' => 'measured', 'xdomain-pingpong' => 'measured' }, statuses(answer))
  end

  def test_an_echo_node_with_another_cookie_fails_only_the_cross_cell
    answer = judged(client(echo_cookie: 'other'))
    assert_empty answer.fetch(:refused)
    assert_equal({ 'local-rtt' => 'measured', 'xdomain-pingpong' => 'failed' }, statuses(answer))
    pingpong = answer.fetch(:cells).find { |cell| cell.operation == 'xdomain-pingpong' }
    assert_equal 'the echo node refused the connection or has no echo registered', pingpong.reason
  end

  private

  def asked = Erx::XdomainBench.asked(Erx::BenchSuite.booted('xdomain').select { |declared| declared.name == 'xdomain' })
                                .with(clock: 'monotonic')

  def judged(lines) = Erx::BenchMeasurement.boot(lines.grep(Erx::NativeBench::GUEST_LINE), asked)

  def statuses(answer) = answer.fetch(:cells).to_h { |cell| [cell.operation, cell.status] }

  # The client node's standard output, its lines, against an echo node started with
  # echo_cookie; the client's cookie is bench. The echo node starts epmd on the test's
  # port; the client waits for the echo it is given, as Linux's guest starts both.
  def client(echo_cookie:)
    beams = compiled
    @echo = spawn(@env, @erl, '-noshell', '-name', ECHO, '-setcookie', echo_cookie, '-pa', beams,
                  '-eval', "erx_xdomain_bench:serve(#{ECHO_NAME})",
                  in: File::NULL, out: File.join(@directory, 'echo.log'), err: %i[child out], pgroup: true)
    wanted = asked.benchmarks.first
    profile = wanted.profiles.fetch('local-rtt')
    guests = "[{erx_xdomain_bench,\#{warmup=>#{profile.warmup},samples=>#{profile.samples},bytes=>64," \
             "echo=>{#{ECHO_NAME},'#{ECHO}'}}}]"
    output, status = Open3.capture2(@env, 'gtimeout', '-k', '10', CLIENT_SECONDS.to_s, @erl, '-noshell', '-name', CLIENT,
                                    '-setcookie', 'bench', '-pa', beams, '-eval', "erx_bench_hist:main(#{guests})",
                                    stdin_data: '')
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  def stop_echo
    return unless @echo

    Process.kill('KILL', -@echo)
    Process.wait(@echo)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # The bench modules compiled by the oracle's erlc into a directory of their own.
  def compiled
    directory = File.join(@directory, 'beams').tap { |path| FileUtils.mkdir_p(path) }
    sources = MODULES.map { |name| File.join(ROOT, 'bench', "#{name}.erl") }
    Erx::Oracle.new(root: ROOT).with_runtime(FLAVOUR) do |runtime|
      _, status = Open3.capture2e(runtime.fetch('erlc'), '+warnings_as_errors', '-o', directory, *sources, stdin_data: '')
      assert status.success?, 'the bench modules do not compile'
      @erl = runtime.fetch('erl')
      @epmd = File.join(File.dirname(runtime.fetch('erlc')), 'epmd')
    end
    directory
  end
end
