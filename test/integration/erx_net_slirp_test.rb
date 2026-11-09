# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'socket'
require 'tmpdir'
require_relative '../../tools/lib/erx/erlang_apps'
require_relative '../../tools/lib/erx/erx_net_host'

# The network stack on stock OTP against QEMU's user networking
# (docs/design-network-stack.md, "The stack on a development host"): a QEMU that runs no
# machine joins slirp and a dgram backend on one hub; the stack's pipe exchanges frames
# with the dgram backend over UDP on the loopback, and test/erlang/erx_net_slirp_run.erl
# takes a lease, resolves and pings the gateway, echoes a datagram through slirp off a UDP
# echo server here on the host, and connects through slirp to a TCP echo server here: 1 MiB
# both ways in passive mode, 64 KiB in active mode closed from both ends, and a connect to
# a port nobody listens on, which slirp's RST refuses; then two reads compared with stock
# gen_tcp on the host's own stack against the same echo server: recv/3 of the whole
# receive buffer, and a fixed-length recv at the server's close. Nothing leaves the host:
# every answer is slirp's or an echo server's. The stack is laid out as a user's build lays it
# out, its per-byte primitives the portable erx_bytes over the C library c_src builds
# (Erx::ErxNetHost), so the transfer's time is the stack's own. Needs qemu-system-aarch64,
# a C compiler and ERX_ERL and ERX_ERLC.
class ErxNetSlirpTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APP = File.join(ROOT, 'erlang/apps/erx_net')
  SOURCES = [*Dir[File.join(APP, 'src', '*.erl')].sort, *Dir[File.join(APP, 'portable', '*.erl')].sort,
             *Dir[File.join(ROOT, 'erlang/apps/erx_net_client/src', '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_net_slirp_run.erl')].freeze
  DEADLINE = 60
  LOOPBACK = '127.0.0.1'

  def test_lease_arp_ping_udp_and_tcp_through_slirp
    Dir.mktmpdir('erx-net-slirp') do |work|
      ebin = compile(work)
      with_echo_server do |echo_port|
        with_tcp_echo_server do |tcp_port|
          qemu_port, stack_port = free_ports(2)
          with_qemu(qemu_port, stack_port) do
            output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE.to_s, ENV.fetch('ERX_ERL'),
                                             '-noshell', '-pa', ebin, '-run', 'erx_net_slirp_run', 'main',
                                             qemu_port.to_s, stack_port.to_s, echo_port.to_s, tcp_port.to_s,
                                             closed_tcp_port.to_s, stdin_data: '')
            assert status.success?, output
            %w[lease arp ping udp tcp_passive tcp_active tcp_refused tcp_whole_buffer tcp_short_tail].each do |step|
              assert_match(/^#{step} ok$/, output)
            end
            puts output.scan(/^tcp_\w+_ms .*$/)
          end
        end
      end
    end
  end

  private

  # erx_net in work with its library, and the stack's modules and the run in its ebin; the ebin.
  def compile(work)
    ebin = Erx::ErxNetHost.lay_out(work, erl: ENV.fetch('ERX_ERL'))
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *Erx::ErlangApps::FLAGS, '-I', File.join(APP, 'include'),
                                     '-pa', ebin, '-o', ebin, *SOURCES, stdin_data: '')
    assert status.success?, output
    ebin
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

  # Echoes each connection's bytes until its EOF, then closes it.
  def with_tcp_echo_server
    server = TCPServer.new(LOOPBACK, 0)
    thread = Thread.new do
      loop do
        Thread.new(server.accept) do |client|
          loop { client.write(client.readpartial(65_536)) }
        rescue EOFError, IOError, SystemCallError
          nil
        ensure
          client.close
        end
      end
    end
    yield server.addr[1]
  ensure
    thread&.kill
    server&.close
  end

  # A TCP port nobody listens on.
  def closed_tcp_port
    TCPServer.new(LOOPBACK, 0).then { |server| server.addr[1].tap { server.close } }
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
