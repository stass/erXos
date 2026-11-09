# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'socket'
require 'tmpdir'
require_relative '../../tools/lib/erx/erlang_apps'

# The network stack on stock OTP against QEMU's user networking
# (docs/design-network-stack.md, "The stack on a development host"): a QEMU that runs no
# machine joins slirp and a dgram backend on one hub; the stack's pipe exchanges frames
# with the dgram backend over UDP on the loopback, and test/erlang/erx_net_slirp_run.erl
# takes a lease, resolves and pings the gateway, and echoes a datagram through slirp off a
# UDP echo server here on the host. Nothing leaves the host: every answer is slirp's or
# the echo server's. Needs qemu-system-aarch64 and ERX_ERL and ERX_ERLC.
class ErxNetSlirpTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APP = File.join(ROOT, 'erlang/apps/erx_net')
  SOURCES = [File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl'),
             *Dir[File.join(APP, 'src', '*.erl')].sort, *Dir[File.join(APP, 'portable', '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_net_slirp_run.erl')].freeze
  DEADLINE = 60
  LOOPBACK = '127.0.0.1'

  def test_lease_arp_ping_and_udp_through_slirp
    Dir.mktmpdir('erx-net-slirp') do |work|
      compile(work)
      with_echo_server do |echo_port|
        qemu_port, stack_port = free_ports(2)
        with_qemu(qemu_port, stack_port) do
          output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE.to_s, ENV.fetch('ERX_ERL'),
                                           '-noshell', '-pa', work, '-run', 'erx_net_slirp_run', 'main',
                                           qemu_port.to_s, stack_port.to_s, echo_port.to_s, stdin_data: '')
          assert status.success?, output
          %w[lease arp ping udp].each { |step| assert_match(/^#{step} ok$/, output) }
        end
      end
    end
  end

  private

  def compile(work)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *Erx::ErlangApps::FLAGS, '-I', File.join(APP, 'include'),
                                     '-pa', work, '-o', work, *SOURCES, stdin_data: '')
    assert status.success?, output
  end

  # Ports free on the loopback now; QEMU and the stack bind them a moment later.
  def free_ports(count)
    sockets = Array.new(count) { UDPSocket.new.tap { |s| s.bind(LOOPBACK, 0) } }
    sockets.map { |s| s.addr[1] }.tap { sockets.each(&:close) }
  end

  def with_echo_server
    server = UDPSocket.new
    server.bind(LOOPBACK, 0)
    thread = Thread.new do
      loop do
        data, (_, port, host) = server.recvfrom(2048)
        server.send(data, 0, host, port)
      end
    end
    yield server.addr[1]
  ensure
    thread&.kill
    server&.close
  end

  def with_qemu(qemu_port, stack_port)
    log = File.open(File.join(Dir.tmpdir, "erx-net-slirp-qemu-#{Process.pid}.log"), 'w')
    pid = Process.spawn('gtimeout', '-k', '10', DEADLINE.to_s, 'qemu-system-aarch64', '-machine', 'none',
                        '-display', 'none', '-monitor', 'none', '-serial', 'none', '-no-reboot',
                        '-netdev', 'user,id=u',
                        '-netdev', "dgram,id=d,local.type=inet,local.host=#{LOOPBACK},local.port=#{qemu_port}," \
                                   "remote.type=inet,remote.host=#{LOOPBACK},remote.port=#{stack_port}",
                        '-netdev', 'hubport,id=p1,hubid=0,netdev=u', '-netdev', 'hubport,id=p2,hubid=0,netdev=d',
                        in: File::NULL, out: log, err: log, pgroup: true)
    sleep 0.5
    yield
  ensure
    if pid
      Process.kill('KILL', -pid) rescue Errno::ESRCH # rubocop:disable Style/RescueModifier
      Process.wait(pid)
    end
    log&.close
  end
end
