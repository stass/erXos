# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'securerandom'
require 'socket'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/bench_suite'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/xdomain_bench'

# The xdomain guest as Linux's Erlang guest runs it (docs/design-bench.md, "Linux's
# Erlang guest", "Verification"), on two nodes of the host's stock OTP 29.1.2 beside
# an epmd of their own, as the guest starts them: an echo node whose
# erx_xdomain_bench:serve/1 registers the echo, and a client node whose
# erx_bench_hist:main/1 prints the oracle's identity line and the cells' lines, which
# the xdomain boot's judge accepts in clock monotonic. An echo node with another cookie
# refuses the connection, so xdomain-pingpong fails while local-rtt is measured: the
# cross cell went to the other OS process over distribution.
#
# Every node and epmd listens on the IPv4 loopback alone, the cookies are drawn per
# run, and each process runs under a deadline and is stopped before its test ends.
class XdomainStockNodesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # Host tests hold the jit oracle's lock while they run (Runtime::HOST_OTP_FLAVOUR), so
  # the stock nodes run on the emu oracle; the cells' protocol does not depend on it.
  FLAVOUR = 'emu'
  MODULES = %w[erx_bench_hist erx_xdomain_bench].freeze
  ECHO = 'bench_echo@127.0.0.1'
  CLIENT = 'bench_client@127.0.0.1'
  ECHO_NAME = 'erx_xdomain_echo'
  LOOPBACK = '127.0.0.1'
  # The deadlines of the client (the calibration and the cells), of the echo node and
  # epmd, which outlive it, and of epmd's start.
  CLIENT_SECONDS = 120
  SERVER_SECONDS = 180
  EPMD_START_SECONDS = 10

  Runtime = Data.define(:erl, :epmd, :beams)

  def setup
    skip "the #{FLAVOUR} oracle is not built here (make oracle-bootstrap)" unless
      File.directory?(File.join(ROOT, "build/oracle/#{FLAVOUR}/install"))
    @directory = Dir.mktmpdir('erx-xdomain-stock-')
    @env = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERL_EPMD_PORT' => free_port.to_s, 'ERL_EPMD_ADDRESS' => LOOPBACK)
  end

  def teardown = @directory && FileUtils.remove_entry(@directory)

  def test_the_client_measures_both_cells_against_the_echo_node
    cookie = SecureRandom.hex(16)
    lines = with_echo(cookie: cookie) { |runtime| client(runtime, cookie: cookie) }
    assert_equal "ERX_ORACLE 29.1.2 #{FLAVOUR}", lines.first
    answer = judged(lines)
    assert_empty answer.fetch(:refused)
    assert_equal 'monotonic', answer.fetch(:clock).fetch('clock')
    assert_equal({ 'local-rtt' => 'measured', 'xdomain-pingpong' => 'measured' }, statuses(answer))
  end

  def test_an_echo_node_with_another_cookie_fails_only_the_cross_cell
    lines = with_echo(cookie: SecureRandom.hex(16)) { |runtime| client(runtime, cookie: SecureRandom.hex(16)) }
    answer = judged(lines)
    assert_empty answer.fetch(:refused)
    assert_equal({ 'local-rtt' => 'measured', 'xdomain-pingpong' => 'failed' }, statuses(answer))
    pingpong = answer.fetch(:cells).find { |cell| cell.operation == 'xdomain-pingpong' }
    assert_equal 'the echo node refused or did not answer the connection', pingpong.reason
    assert_match(/bench_client@127\.0\.0\.1.*rejected/, File.read(File.join(@directory, 'echo.log')),
                 'the echo node did not see the client and refuse it')
  end

  private

  def asked = Erx::XdomainBench.asked(Erx::BenchSuite.booted('xdomain').select { |declared| declared.name == 'xdomain' })
                                .with(clock: 'monotonic')

  def judged(lines) = Erx::BenchMeasurement.boot(lines.grep(Erx::NativeBench::GUEST_LINE), asked)

  def statuses(answer) = answer.fetch(:cells).to_h { |cell| [cell.operation, cell.status] }

  # The answer of the block, given the runtime, while epmd and an echo node started
  # with cookie run; both are stopped however the block ends.
  def with_echo(cookie:)
    runtime = compiled
    epmd = start(runtime.epmd, '-address', LOOPBACK, log: 'epmd.log')
    epmd_ready(runtime)
    echo = start(*node(runtime, ECHO, cookie), '-eval', "erx_xdomain_bench:serve(#{ECHO_NAME})", log: 'echo.log')
    yield runtime
  ensure
    [echo, epmd].compact.each { |pid| stop(pid) }
  end

  # The client node's standard output, its lines; the client waits for the echo it is
  # given, as Linux's guest starts both nodes at once.
  def client(runtime, cookie:)
    guests = Erx::XdomainBench.guests(asked, echo: "{#{ECHO_NAME},'#{ECHO}'}")
    output, status = Open3.capture2(@env, 'gtimeout', '-k', '10', CLIENT_SECONDS.to_s, *node(runtime, CLIENT, cookie),
                                    '-eval', "erx_bench_hist:main(#{guests})", stdin_data: '')
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  # A node's command line: on the loopback alone, with the epmd the test started.
  def node(runtime, name, cookie)
    [runtime.erl, '-noshell', '-boot', 'no_dot_erlang', '-name', name, '-setcookie', cookie, '-start_epmd', 'false',
     '-kernel', 'inet_dist_use_interface', '{127,0,0,1}', '-pa', runtime.beams]
  end

  def start(*command, log:)
    spawn(@env, 'gtimeout', '-k', '10', SERVER_SECONDS.to_s, *command,
          in: File::NULL, out: File.join(@directory, log), err: %i[child out])
  end

  # gtimeout passes the signal on to the process it runs.
  def stop(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # epmd runs in the foreground here, so the nodes may start once it answers.
  def epmd_ready(runtime)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + EPMD_START_SECONDS
    until system(@env, runtime.epmd, '-names', out: File::NULL, err: File::NULL)
      flunk 'epmd did not start' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def free_port = TCPServer.open(LOOPBACK, 0).then { |server| server.addr[1].tap { server.close } }

  # The oracle's programs and the bench modules compiled by its erlc into a directory
  # of their own.
  def compiled
    beams = File.join(@directory, 'beams').tap { |path| FileUtils.mkdir_p(path) }
    sources = MODULES.map { |name| File.join(ROOT, 'bench', "#{name}.erl") }
    runtime = nil
    Erx::Oracle.new(root: ROOT).with_runtime(FLAVOUR) do |oracle|
      erlc = oracle.fetch('erlc')
      _, status = Open3.capture2e(@env, erlc, '+warnings_as_errors', '-o', beams, *sources, stdin_data: '')
      assert status.success?, 'the bench modules do not compile'
      runtime = Runtime.new(erl: oracle.fetch('erl'), epmd: File.join(File.dirname(erlc), 'epmd'), beams: beams)
    end
    runtime
  end
end
