# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'socket'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'
require_relative 'net_device_echo_server'
require_relative 'net_device_name_server'

module Erx
  # The network stack end to end on QEMU virt: the development image boots with a
  # virtio-net device on QEMU's user networking (QemuPlan::Nic), the system domain's
  # erx_net drives it through erx_virtio_net and takes a DHCP lease from slirp, and the
  # harness, one more host on the guest's link through the hub's `dgram` port, asks it
  # for its address with ARP and pings it. The guest must answer both:
  #
  # * ARP: a request for GUEST_IP from HOST_MAC and HOST_IP, sent every ARP_RETRY
  #   seconds until a reply that gives GUEST_IP's link-layer address to HOST_MAC comes,
  #   for at most LEASE_SECONDS, which is how long the lease may take after the boot's
  #   last line;
  # * ICMP: an echo request to that address, answered by an echo reply from GUEST_IP
  #   with the request's identifier, sequence number and data, within REPLY_SECONDS.
  #
  # The exchange runs as the verifier of the command shell's banner, the boot's last
  # line, so QEMU runs throughout and the run's deadline covers it. The harness then plays
  # a name server on the link (NameServer) and types at that shell (shell_checkpoints):
  # `ifconfig`, which must show vtnet0 up with the link-layer address that answered ARP
  # and slirp's lease; `ping -c 3` to slirp's gateway, which must show three replies and
  # FreeBSD's statistics with no loss; `host www HOST_IP`, which must find www in the
  # lease's domain, NIC_DOMAIN, slirp's option 15, with its address and IPv6 address;
  # `host nonexistent HOST_IP`, which must be NXDOMAIN; `host ADDRESS HOST_IP`, which
  # must give the pointer back; and, in the Erlang shell, inet_db's name servers and
  # search list, which must be the lease's: none, since slirp in restricted mode, which
  # keeps the guest's traffic on the host, leaves the router and name server options out
  # of its lease, and NIC_DOMAIN (that a lease's name servers reach inet_db is
  # erx_net_dns_tests' case on the host); and four query IDs inet_db draws in a row,
  # which must not each follow the one before, as a counter's do. Every frame the harness
  # reads is parsed with bounds checks, since the guest is the code under test; a frame
  # that is not the awaited answer, slirp's included, is skipped.
  #
  # Last, the Erlang shell opens TCP connections with erx_gen_tcp (tcp_checkpoints): one
  # through slirp's guest forward to the harness's echo server (EchoServer), over which
  # it sends TCP_BYTES random bytes and must read the same bytes back, while the server's
  # MD5 of what it took must equal the guest's of what it sent, and whose echo, coming back
  # in bursts, the interface must have merged into units at least once; and one to the gateway,
  # 10.0.2.2, at the echo server's own host port. An unrestricted slirp would carry that
  # one to the host's loopback, where the echo server listens, and connect; slirp in
  # restricted mode must refuse it, since the guest reaches the host only through the
  # forward.
  module NetDevice
    GUEST_IP = [10, 0, 2, 15].freeze
    HOST_IP = [10, 0, 2, 100].freeze
    HOST_MAC = [0x02, 0, 0, 0, 0, 0x01].freeze
    BROADCAST = [0xff] * 6
    ETHERTYPE_ARP = 0x0806
    ETHERTYPE_IP = 0x0800
    LEASE_SECONDS = 60
    REPLY_SECONDS = 5
    ARP_RETRY = 0.5
    PING_ID = 0xe1
    PING_SEQ = 1
    PING_DATA = 'erxos net-device ping'.b
    FRAME_BYTES = 2048
    SERIAL_BYTES = 1 << 20
    # Each shell line's answer comes within this; the first after the exchange has the
    # exchange's time as well.
    SHELL_SECONDS = 30
    IFCONFIG_LINE = "ifconfig\r"
    PING_LINE = "ping -c 3 10.0.2.2\r"
    MS = '[0-9]+\.[0-9]{3}'
    SERVER = HOST_IP.join('.')
    HOST_LINE = "host www #{SERVER}\r".freeze
    MISSING_LINE = "host nonexistent #{SERVER}\r".freeze
    POINTER_LINE = "host 192.0.2.10 #{SERVER}\r".freeze
    RESOLVER_LINE = "{inet_db:res_option(nameservers), inet_db:res_option(search)}.\r"
    # What inet_db holds once the lease is loaded: no name server, which a restricted
    # slirp does not offer, and NIC_DOMAIN.
    RESOLVER_ANSWER = "{[],[\"#{QemuPlan::NIC_DOMAIN}\"]}".freeze
    # Four query IDs inet_db draws in a row, which must not be a counter's run.
    IDS_LINE = "list_to_tuple([inet_db:res_option(next_id) || _ <- lists:seq(1, 4)]).\r"
    # The Erlang shell's prompt, which may open the line its answer is on.
    ERL_PROMPT = '(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?'
    # The TCP lines, whose shell bindings are: S, a connection through the guest forward;
    # D, TCP_BYTES random bytes; R, a fun that receives RECV_PIECE bytes from S within
    # TCP_RECV_MS or raises; E, what came back; T, the milliseconds from the start of the
    # send to the last byte received. ECHO_LINE does the whole exchange in one expression,
    # so T holds no serial round trip.
    #
    # TCP_BYTES is four times the connection's receive buffer: while the shell sits in its
    # send, the guest reads nothing, so its receive window closes and must open again for
    # the echo to finish. Each recv asks for at most that buffer, 64 KiB, since
    # erx_tcp_conn answers {error, enomem} beyond it where stock gen_tcp takes up to 64 MiB
    # (TODO.md).
    TCP_BYTES = 262_144
    RECV_PIECE = 65_536
    TCP_RECV_MS = 10_000
    # Longer than the four recvs' timeouts, so a recv that times out shows as its error.
    TCP_SECONDS = 60
    # What the echo server takes before it fails the run: more than TCP_BYTES, so a guest
    # that sends too much is told so by the byte count check, not by the server.
    ECHO_LIMIT = 4 * TCP_BYTES
    ECHO_TUPLE = "{#{QemuPlan::NIC_ECHO_ADDRESS.tr('.', ',')}}".freeze
    CONNECT_LINE = "{ok, S} = erx_gen_tcp:connect(#{ECHO_TUPLE}, #{QemuPlan::NIC_ECHO_PORT}, " \
                   "[binary, {active, false}], 10000), ok.\r".freeze
    DATA_LINE = "D = rand:bytes(#{TCP_BYTES}), " \
                "R = fun() -> {ok, B} = erx_gen_tcp:recv(S, #{RECV_PIECE}, #{TCP_RECV_MS}), B end, byte_size(D).\r".freeze
    ECHO_LINE = "T0 = erlang:monotonic_time(millisecond), ok = erx_gen_tcp:send(S, D), " \
                "E = iolist_to_binary([R() || _ <- lists:seq(1, #{TCP_BYTES / RECV_PIECE})]), " \
                "T = erlang:monotonic_time(millisecond) - T0, E =:= D.\r".freeze
    DIGEST_LINE = "{T, binary:encode_hex(erlang:md5(D))}.\r"
    CLOSE_LINE = "erx_gen_tcp:close(S).\r"
    # Whether vtnet0's interface merged any of the bursts the echo came back in: its count of
    # merged units (docs/design-network-fastpath.md, "The merge, before classification").
    MERGED_LINE = 'begin {ok, #{pid := If}} = erx_net_tables:interface(vtnet0), ' \
                  "{ok, C} = erx_net_if:admin(If, counters), maps:get(units, C, 0) > 0 end.\r"

    module_function

    # What the shell shows after the exchange, whose result mac reads the guest's
    # link-layer address from: ifconfig's lines for vtnet0, in FreeBSD's layout with the
    # lease's address, netmask and broadcast; ping's to slirp's gateway, where only the
    # TTLs and times may vary; then the resolver's. Lines between, such as the echo of
    # each typed line, are passed over.
    def shell_checkpoints(mac)
      ether = lambda do |line|
        raise Error, "ifconfig showed #{line.inspect}, not #{mac.call}, which answered ARP" unless line.match?(/\A\tether #{mac.call}\r*\n\z/n)
      end
      [shell_point('ifconfig-vtnet0', Regexp.escape('vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500'),
                   seconds: LEASE_SECONDS + REPLY_SECONDS + SHELL_SECONDS),
       shell_point('ifconfig-ether', '\tether [0-9a-f]{2}(?::[0-9a-f]{2}){5}', verify: ether),
       shell_point('ifconfig-inet', Regexp.escape("\tinet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255")),
       shell_point('ifconfig-status', Regexp.escape("\tstatus: active"), type: PING_LINE),
       shell_point('ping-head', Regexp.escape('PING 10.0.2.2 (10.0.2.2): 56 data bytes')),
       *(0..2).map { |seq| shell_point("ping-reply-#{seq}", "64 bytes from 10\\.0\\.2\\.2: icmp_seq=#{seq} ttl=[0-9]+ time=#{MS} ms") },
       shell_point('ping-statistics', Regexp.escape('--- 10.0.2.2 ping statistics ---')),
       shell_point('ping-counts', Regexp.escape('3 packets transmitted, 3 packets received, 0.0% packet loss')),
       shell_point('ping-round-trip', "round-trip min/avg/max/stddev = #{MS}/#{MS}/#{MS}/#{MS} ms", type: HOST_LINE),
       *resolver_checkpoints].freeze
    end

    # What the resolver lines show: each `host` answer, in FreeBSD's lines, and inet_db's
    # resolver settings in the Erlang shell.
    def resolver_checkpoints
      name = "www.#{QemuPlan::NIC_DOMAIN}"
      [shell_point('host-server', Regexp.escape('Using domain server:')),
       shell_point('host-server-name', Regexp.escape("Name: #{SERVER}")),
       shell_point('host-server-address', Regexp.escape("Address: #{SERVER}#53")),
       shell_point('host-address', Regexp.escape("#{name} has address 192.0.2.10")),
       shell_point('host-address6', Regexp.escape("#{name} has IPv6 address 2001:db8::10"), type: MISSING_LINE),
       shell_point('host-nxdomain', Regexp.escape('Host nonexistent not found: 3(NXDOMAIN)'), type: POINTER_LINE),
       shell_point('host-pointer', Regexp.escape("10.2.0.192.in-addr.arpa domain name pointer #{name}."),
                   type: ProductionImage::Run::ERL_LINE),
       ProductionImage::Run::ERLANG_SHELL.merge(type: RESOLVER_LINE).freeze,
       erl_point('resolver-config', Regexp.escape(RESOLVER_ANSWER), type: IDS_LINE),
       erl_point('query-ids', '\{[0-9]+,[0-9]+,[0-9]+,[0-9]+\}', verify: method(:random_ids!), type: CONNECT_LINE)]
    end

    # The gateway at a host port: the echo server's, which listens on the host's loopback.
    def refused_line(port) = "erx_gen_tcp:connect({10,0,2,2}, #{port}, [binary], 10000).\r"

    # What the TCP lines show in the Erlang shell: each step's answer; the comparison of
    # what came back with what was sent, which must be true; T and D's MD5, which the
    # caller's verify_digest checks against the echo server's; and the refusal of the
    # connection to the gateway at refused_port.
    def tcp_checkpoints(refused_port:, verify_digest:)
      echoed = lambda do |line|
        raise Error, "the #{TCP_BYTES} bytes the guest read back over TCP differ from those it sent" if line.include?('false')
      end
      [erl_point('tcp-connect', 'ok', type: DATA_LINE),
       erl_point('tcp-data', TCP_BYTES.to_s, type: ECHO_LINE),
       erl_point('tcp-echo', '(?:true|false)', seconds: TCP_SECONDS, verify: echoed, type: DIGEST_LINE),
       erl_point('tcp-digest', '\{[0-9]+,<<"[0-9A-F]{32}">>\}', verify: verify_digest, type: MERGED_LINE),
       erl_point('tcp-merged', 'true', type: CLOSE_LINE),
       erl_point('tcp-close', 'ok', type: refused_line(refused_port)),
       erl_point('tcp-refused', Regexp.escape('{error,econnrefused}'))].freeze
    end

    # Checks the tcp-digest line against what the echo server took, received
    # (EchoServer#received): TCP_BYTES bytes whose MD5 is the one the guest gives of what
    # it sent. Returns the line's T, the transfer's milliseconds.
    def check_echo!(line, received)
      ms, md5 = line.match(/\{([0-9]+),<<"([0-9A-F]{32})">>\}/n).captures
      raise Error, "the echo server took #{received.fetch(:bytes)} bytes, not #{TCP_BYTES}" unless received.fetch(:bytes) == TCP_BYTES
      raise Error, "the guest sent bytes of MD5 #{md5}, the echo server took bytes of MD5 #{received.fetch(:md5)}" unless md5 == received.fetch(:md5)

      Integer(ms, 10)
    end

    # Refuses four query IDs that each follow the one before, as inet_db's counter's do:
    # IDs an off-path host can guess (RFC 5452).
    def random_ids!(line)
      ids = line.scan(/[0-9]+/).last(4).map(&:to_i)
      steps = ids.each_cons(2).map { |a, b| (b - a) % 0x10000 }
      raise Error, "inet_db's query IDs #{ids.join(', ')} are a counter's" if steps.all?(1)
    end

    # A checkpoint for one whole line the shell writes, matched by the pattern source.
    def shell_point(name, source, seconds: SHELL_SECONDS, type: nil, verify: nil)
      { name: name, pattern: /\A#{source}\r*\n\z/n, seconds: seconds, **{ type: type, verify: verify }.compact }.freeze
    end

    # A checkpoint for the Erlang shell's answer, alone on its line or after the prompt.
    def erl_point(name, source, **options) = shell_point(name, "#{ERL_PROMPT}#{source}", **options)

    def arp_request
      ethernet(BROADCAST, ETHERTYPE_ARP,
               [1, ETHERTYPE_IP, 6, 4, 1].pack('nnCCn') + bytes(HOST_MAC) + bytes(HOST_IP) +
               bytes([0] * 6) + bytes(GUEST_IP))
    end

    # The guest's link-layer address from an ARP reply to the harness, or nil.
    def arp_answer(frame)
      return nil unless frame.bytesize >= 42 && frame.unpack1('@12n') == ETHERTYPE_ARP

      _htype, _ptype, _hlen, _plen, op = frame.unpack('@14nnCCn')
      sender, sender_ip, target, target_ip = frame.unpack('@22a6a4a6a4')
      return nil unless op == 2 && sender_ip == bytes(GUEST_IP) && target == bytes(HOST_MAC) && target_ip == bytes(HOST_IP)

      sender
    end

    def echo_request(guest_mac)
      icmp = with_checksum([8, 0, 0, PING_ID, PING_SEQ].pack('CCnnn') + PING_DATA, at: 2)
      header = [0x45, 0, 20 + icmp.bytesize, 0, 0, 64, 1, 0].pack('CCnnnCCn') + bytes(HOST_IP) + bytes(GUEST_IP)
      ethernet(guest_mac.bytes, ETHERTYPE_IP, with_checksum(header, at: 10) + icmp)
    end

    # Whether a frame is the guest's echo reply to echo_request.
    def echo_answer?(frame)
      return false unless frame.bytesize >= 34 && frame.unpack1('@12n') == ETHERTYPE_IP

      version_ihl, total, protocol, source, destination = frame.unpack('@14C@16n@23C@26a4a4')
      header = (version_ihl & 0x0f) * 4
      return false unless version_ihl >> 4 == 4 && header >= 20 && protocol == 1 && total >= header + 8 &&
                          frame.bytesize >= 14 + total && source == bytes(GUEST_IP) && destination == bytes(HOST_IP)

      icmp = frame.byteslice(14 + header, total - header)
      type, code, _sum, id, seq = icmp.unpack('CCnnn')
      type.zero? && code.zero? && id == PING_ID && seq == PING_SEQ && icmp.byteslice(8..) == PING_DATA
    end

    def ethernet(destination, type, payload) = bytes(destination) + bytes(HOST_MAC) + [type].pack('n') + payload

    def bytes(list) = list.pack('C*')

    # The Internet checksum (RFC 1071) of data, written big-endian at offset at.
    def with_checksum(data, at:)
      words = (data.bytesize.odd? ? data + "\0".b : data).unpack('n*')
      sum = words.sum
      sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
      data.dup.tap { |out| out[at, 2] = [~sum & 0xffff].pack('n') }
    end

    # The harness's end of the hub: a loopback UDP socket QEMU's dgram backend sends to.
    class Link
      def initialize
        @socket = UDPSocket.new
        @socket.bind('127.0.0.1', 0)
        @frames_port = free_port
      end

      attr_reader :frames_port

      def peer_port = @socket.addr[1]

      def close = @socket.close

      def send(frame) = @socket.send(frame, 0, '127.0.0.1', @frames_port)

      # The first frame for which block answers non-nil within seconds, else nil.
      def await(seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if left <= 0
          next unless @socket.wait_readable(left)

          frame, = @socket.recvfrom(NetDevice::FRAME_BYTES)
          found = yield frame.b
          return found if found
        end
      end

      private

      def free_port
        probe = UDPSocket.new
        probe.bind('127.0.0.1', 0)
        probe.addr[1]
      ensure
        probe&.close
      end
    end

    # The ARP and ICMP exchange; raises Erx::Error naming the step the guest missed.
    def exchange(link)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LEASE_SECONDS
      guest_mac = nil
      while guest_mac.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        link.send(arp_request)
        guest_mac = link.await(ARP_RETRY) { |frame| arp_answer(frame) }
      end
      raise Error, "the guest answered no ARP request for #{GUEST_IP.join('.')} in #{LEASE_SECONDS} s" unless guest_mac

      link.send(echo_request(guest_mac))
      raise Error, 'the guest answered no ICMP echo request' unless link.await(REPLY_SECONDS) { |frame| echo_answer?(frame) }

      { mac: guest_mac.unpack('C*').map { |byte| format('%02x', byte) }.join(':') }
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @notes = []
        @measurements = []
      end

      # Boots the development image with a network device under each accelerator and
      # runs the exchange. Returns { "<accelerator>-1cpu" => 'passed' }; a guest that
      # misses a step raises.
      def call(accels:, jobs: 4, build: true)
        raise Error, 'the network device suite runs under tcg or hvf' unless accels.all? { |accel| %w[tcg hvf].include?(accel) }

        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/net-device/image'))
        image = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                               .build(directory: directory, manifest_source: ProductionImage.sessionless_manifest(@root)).single
        accels.to_h { |accel| ["#{accel}-1cpu", boot(accel, image)] }
      end

      def notes = @notes.dup.freeze

      # One line per boot with the TCP transfer's time and rate, for the gate's output
      # only: no check reads them.
      def measurements = @measurements.dup.freeze

      private

      def boot(accel, image)
        directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/net-device',
                                                                          "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"),
                                            mode: 0o700)
        link = Link.new
        server = NameServer.new(link)
        echo = EchoServer.new(limit: ECHO_LIMIT).start
        nic = QemuPlan::Nic.new(frames_port: link.frames_port, peer_port: link.peer_port, echo_port: echo.port)
        answered = nil
        transfer_ms = nil
        verify_digest = ->(line) { transfer_ms = NetDevice.check_echo!(line, echo.received) }
        exchange = lambda do |_line|
          answered = NetDevice.exchange(link)
          server.start
        end
        shell = ProductionImage::Run::RELEASE_SHELL.merge(verify: exchange, type: IFCONFIG_LINE).freeze
        checkpoints = [*Qemu.boot_transcript(memory_mib: ProductionImage::MEMORY_MIB), ProductionImage::Run::SLOGAN, shell,
                       *NetDevice.shell_checkpoints(-> { answered.fetch(:mac) }),
                       *NetDevice.tcp_checkpoints(refused_port: echo.port, verify_digest: verify_digest)]
        Qemu.new(root: @root, runner: @runner).run(accel: accel, image: image, memory_mib: ProductionImage::MEMORY_MIB,
                                                   directory: directory, checkpoints: checkpoints, nic: nic,
                                                   command_line: ProductionImage::Run::COMMAND_LINES[accel])
        failed = server.stop || echo.stop
        raise failed if failed

        @notes << "#{accel}: the guest at #{GUEST_IP.join('.')} (#{answered.fetch(:mac)}) answered ARP and ICMP echo, " \
                  'and its shell showed vtnet0 with the lease, pinged 10.0.2.2 three times and resolved www ' \
                  "in the lease's domain through the name server at #{SERVER}, with random query IDs; " \
                  "its Erlang shell sent #{TCP_BYTES} bytes over TCP to the echo server and read them back, " \
                  "and was refused the host's loopback"
        @measurements << "net_device: #{accel}, 1 CPU: TCP from the guest's Erlang shell through slirp's guest forward " \
                         "to the harness's echo server: #{TCP_BYTES} bytes each way in #{transfer_ms} ms " \
                         "(#{rate(transfer_ms)} each way), from the start of the send to the last byte back"
        'passed'
      ensure
        echo&.stop
        server&.stop
        link&.close
      end

      def rate(ms) = ms.positive? ? format('%.1f MiB/s', TCP_BYTES * 1000.0 / ms / (1 << 20)) : 'too fast to rate'
    end
  end
end
