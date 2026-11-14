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
require_relative 'session_domain'
require_relative 'net_device_echo_server'
require_relative 'net_device_name_server'

module Erx
  # The network stack end to end on QEMU virt: the development image boots with a
  # virtio-net device on QEMU's user networking (QemuPlan::Nic), the network domain's
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
  # The exchange runs as the verifier of the banner of root's session's command shell,
  # which takes the line once the console has logged root in, so QEMU runs throughout and
  # the run's deadline covers it. The harness then plays a name server on the link
  # (NameServer) and types at that shell (shell_checkpoints):
  # `ifconfig`, which must show vtnet0 up with the link-layer address that answered ARP
  # and slirp's lease; `ping -c 3` to slirp's gateway, which must show three replies and
  # FreeBSD's statistics with no loss; `host www HOST_IP`, which must find www in the
  # lease's domain, NIC_DOMAIN, slirp's option 15, with its address and IPv6 address;
  # `host nonexistent HOST_IP`, which must be NXDOMAIN; `host ADDRESS HOST_IP`, which
  # must give the pointer back; and, in the Erlang shell, the node, which must be root's
  # session's, and inet_db's name servers and
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
  # MD5 of what it took must equal the guest's of what it sent; and one to the gateway,
  # 10.0.2.2, at the echo server's own host port. An unrestricted slirp would carry that
  # one to the host's loopback, where the echo server listens, and connect; slirp in
  # restricted mode must refuse it, since the guest reaches the host only through the
  # forward.
  #
  # The reverse case follows: the Erlang shell listens with gen_tcp, whose backend on
  # erXos is erx_gen_tcp by default, on QemuPlan::NIC_LISTEN_PORT and spawns an acceptor
  # that echoes what it reads until the peer's end, then closes and tells the shell how
  # many bytes it echoed. The harness connects to slirp's host forward to that port
  # (listener_exchange), sends LISTEN_BYTES random bytes and shuts its sending side; the
  # same bytes must come back, then the guest's FIN, and the shell must show the
  # acceptor's count and its close's `ok`.
  #
  # Every request above that needs the network (ifconfig's interfaces, ping's echo
  # socket, the resolver's and the TCP connect) reaches the stack only as a call of the
  # session's grant, its `net` facet, admitted by erx_net_admit
  # (docs/design-network-stack.md, "The grant's contract"). The Erlang shell then makes a
  # call of the grant that is no operation of it, which must be refused with
  # {error, badarg}. The line then goes to the system domain's command shell, which holds
  # no `net` facet: its ifconfig, ping and host must each be refused with `no_facet`. Its
  # Erlang shell, last, probes the network domain over erpc, as the harness and not as a
  # client (system_checkpoints): vtnet0 must have merged the echo's bursts into units at
  # least once, and the network domain's one grant, the session's, must count that one
  # refusal and nothing left out, so no call of the steps before was refused or dropped.
  #
  # The suite boots twice under each accelerator. The stock boot takes the tree QEMU
  # writes, which marks the network device's transport dma-coherent, and the root's line
  # for that node must say `coherent 1`. The non-coherent boot takes the same tree with
  # the mark removed from that node (ProductionImage.seed_noncoherent), the paired boot of
  # docs/design-device-tree.md ("The live tree on QEMU"): the line must say `coherent 0`,
  # so the device's record is not coherent and its queues issue the cache maintenance of
  # docs/design-device-dma.md, and every step above must still pass, since maintenance
  # changes nothing on QEMU's coherent DMA. That boot is the one that runs the maintenance
  # instructions in user mode on a booted guest.
  module NetDevice
    GUEST_IP = [10, 0, 2, 15].freeze
    HOST_IP = [10, 0, 2, 100].freeze
    HOST_MAC = [0x02, 0, 0, 0, 0, 0x01].freeze
    BROADCAST = [0xff] * 6
    ETHERTYPE_ARP = 0x0806
    ETHERTYPE_IP = 0x0800
    # From the session shell's banner: the network domain boots beside root's session and
    # takes its lease meanwhile.
    LEASE_SECONDS = 180
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
    RESOLVER_LINE = "{node(), inet_db:res_option(nameservers), inet_db:res_option(search)}.\r"
    # The shell's node, root's session's, and what inet_db holds once the lease is loaded:
    # no name server, which a restricted slirp does not offer, and NIC_DOMAIN.
    RESOLVER_ANSWER = "{root_1@erxos,[],[\"#{QemuPlan::NIC_DOMAIN}\"]}".freeze
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
    # The listener lines, whose shell bindings are L, the listening socket, and Shell, the
    # shell's pid. ACCEPT_LINE spawns the acceptor, which owns the connection it accepts,
    # echoes each recv's bytes back until the peer's end, closes, and sends the shell
    # {echoed, Bytes, Close}; ECHOED_LINE takes that message. Its accept and send matches
    # are tagged, so the crash report of an acceptor that fails names the call. LISTEN_BYTES
    # fits the loopback socket's and slirp's buffers, so the harness sends it whole before
    # it reads.
    LISTEN_BYTES = 16_384
    LISTEN_LINE = "{ok, L} = gen_tcp:listen(#{QemuPlan::NIC_LISTEN_PORT}, [binary, {active, false}]), ok.\r".freeze
    ACCEPT_LINE = 'Shell = self(), _ = spawn(fun() -> ' \
                  "{accept, {ok, A}} = {accept, gen_tcp:accept(L, #{TCP_RECV_MS})}, " \
                  "Echo = fun Loop(N) -> case gen_tcp:recv(A, 0, #{TCP_RECV_MS}) of " \
                  '{ok, B} -> {send, ok} = {send, gen_tcp:send(A, B)}, Loop(N + byte_size(B)); ' \
                  '{error, closed} -> N end end, ' \
                  "Echoed = Echo(0), Shell ! {echoed, Echoed, gen_tcp:close(A)} end), ok.\r".freeze
    ECHOED_LINE = "receive {echoed, _, _} = Msg -> Msg after #{TCP_RECV_MS} -> timeout end.\r".freeze
    # The acceptor's answer when the exchange passed.
    ACCEPTED = "{echoed,#{LISTEN_BYTES},ok}".freeze
    # The longest listener_exchange takes: its connect, and its write and read.
    HOST_FORWARD_SECONDS = REPLY_SECONDS + 2 * TCP_SECONDS
    # A call of the session's grant, its `net` facet, that is no operation of it.
    GRANT_LINE = "gen_server:call(erx:cap(net), no_operation, infinity).\r"
    # Typed at the system domain's Erlang shell: in the network domain, whether vtnet0's
    # interface merged any of the bursts the echo came back in, its count of merged units
    # (docs/design-network-fastpath.md, "The merge, before classification"), and the counts
    # of the domain's one grant, the session's; and the coherent value of each of the
    # domain's network records that has DMA memory, the value erx_virtio_net opens the
    # device with: {Merged, Refused, LeftOut, [Coherent]}.
    PROBE_LINE = 'begin [N] = [Nd || #{name := {erx_ident, <<"network">>}, node := Nd} <- ' \
                 'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                 'erpc:call(N, fun() -> {ok, #{pid := If}} = erx_net_tables:interface(vtnet0), ' \
                 '{ok, C} = erx_net_if:admin(If, counters), ' \
                 '[G] = [P || {_, P, _, _} <- supervisor:which_children(erx_net_grants)], ' \
                 'Counts = erx_net_grant:counts(G), {ok, Specs} = erx_device_record:find(net, virtio_net), ' \
                 '{maps:get(units, C, 0) > 0, maps:get(refused, Counts), maps:get(unknown, Counts), ' \
                 "[Co || \#{memory := _, coherent := Co} <- Specs]} end, 10000) end.\r"
    # The one edit of the development manifest: the network row runs BeamAsm, as a
    # service domain does by default (docs/design-runtime.md, "BeamAsm"), so the TCP
    # line times the stack on the runtime a throughput figure assumes; the development
    # manifest runs it on the interpreter for a faster boot.
    BEAMASM_EDIT = /^(domain network\n(?:  .*\n)*?  runtime )@artifact\.emu$/
    # A tree the suite boots on: its cell's suffix, and whether the network device's
    # record is coherent on it. The coherent tree is QEMU's own; the other is QEMU's with
    # the device's transport not marked dma-coherent (Run#noncoherent_tree).
    Tree = Data.define(:suffix, :coherent)
    TREES = { stock: Tree.new(suffix: '', coherent: true), noncoherent: Tree.new(suffix: '-noncoherent', coherent: false) }.freeze

    module_function

    # The suite's cell that boots under accel on the tree named tree, a key of TREES.
    def cell(accel, tree) = "#{accel}-1cpu#{TREES.fetch(tree).suffix}"

    # The device-tree path of the network row the harness's virtio-net device sits on: the
    # one device of the platform record's unit `net`.
    def nic_node(platform)
      unit = platform.record.fetch('units').find { |entry| entry['key'] == 'net' }
      devices = unit&.fetch('devices')
      raise Error, "#{platform.record_path} has no unit net with one device" unless devices&.size == 1

      devices.first.fetch('path')
    end

    # The root's line for the network device's tree facts (docs/design-device-tree.md,
    # "Facts into records"): QEMU's tree gives every transport the whole bus range and no
    # address, so only the coherent value differs between the stock tree and the seeded one.
    def tree_checkpoint(node, coherent:)
      line = "erx: device tree: #{node}: coherent #{coherent ? 1 : 0} range 0x0 0x0 0xffffffffffffffff mac absent"
      { name: 'nic-device-tree', pattern: /\A#{Regexp.escape(line)}\r*\n\z/n, seconds: SHELL_SECONDS }.freeze
    end

    # The development manifest source with BEAMASM_EDIT, which must match exactly once.
    def manifest(source)
      raise Error, "the manifest does not have exactly one match of #{BEAMASM_EDIT.source}" unless source.scan(BEAMASM_EDIT).size == 1

      source.sub(BEAMASM_EDIT) { "#{Regexp.last_match(1)}@artifact.jit" }
    end

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
    # caller's verify_digest checks against the echo server's; the refusal of the
    # connection to the gateway at refused_port; then the listener's lines, the acceptor's
    # spawn verified by the harness's exchange through the host forward at forward_port
    # (listener_exchange), and the acceptor's count and close, whose checkpoint has the
    # exchange's time as well. The exchange's failure is raised at that checkpoint, once
    # the shell has answered for the acceptor, so the serial log holds the guest's side
    # of it too: the acceptor's answer, or after its crash report ECHOED_LINE's timeout.
    def tcp_checkpoints(refused_port:, verify_digest:, forward_port:)
      echoed = lambda do |line|
        raise Error, "the #{TCP_BYTES} bytes the guest read back over TCP differ from those it sent" if line.include?('false')
      end
      failed = nil
      host_forward = lambda do |_line|
        NetDevice.listener_exchange(forward_port)
      rescue Error => e
        failed = e
      end
      accepted = lambda do |line|
        raise failed if failed
        raise Error, "the guest's acceptor did not answer {echoed,#{LISTEN_BYTES},ok}; see the serial log" unless line.include?(ACCEPTED)
      end
      [erl_point('tcp-connect', 'ok', type: DATA_LINE),
       erl_point('tcp-data', TCP_BYTES.to_s, type: ECHO_LINE),
       erl_point('tcp-echo', '(?:true|false)', seconds: TCP_SECONDS, verify: echoed, type: DIGEST_LINE),
       erl_point('tcp-digest', '\{[0-9]+,<<"[0-9A-F]{32}">>\}', verify: verify_digest, type: CLOSE_LINE),
       erl_point('tcp-close', 'ok', type: refused_line(refused_port)),
       erl_point('tcp-refused', Regexp.escape('{error,econnrefused}'), type: LISTEN_LINE),
       erl_point('tcp-listen', 'ok', type: ACCEPT_LINE),
       erl_point('tcp-host-forward', 'ok', verify: host_forward, type: ECHOED_LINE),
       erl_point('tcp-accepted', '(?:\{echoed,[^\r\n]*\}|timeout)', seconds: HOST_FORWARD_SECONDS + SHELL_SECONDS,
                                                                    verify: accepted, type: GRANT_LINE),
       erl_point('grant-refusal', Regexp.escape('{error,badarg}'), type: ProductionImage::Run::CTRL_G)].freeze
    end

    # The host's end of the listener case: connects to slirp's host forward at the
    # loopback port port, sends LISTEN_BYTES random bytes and shuts its sending side, then
    # reads the echo until the guest's FIN (read_echo). What came back must be the bytes
    # sent. Each write and read waits at most TCP_SECONDS, and the whole read as long.
    def listener_exchange(port)
      sent = Random.bytes(LISTEN_BYTES)
      echoed = Socket.tcp('127.0.0.1', port, connect_timeout: REPLY_SECONDS) do |socket|
        socket.timeout = TCP_SECONDS
        socket.write(sent)
        socket.close_write
        read_echo(socket)
      end
      raise Error, "the #{LISTEN_BYTES} bytes the guest's listener echoed differ from those sent" unless echoed == sent
    rescue IOError, SystemCallError => e
      raise Error, "the host forward to the guest's listener failed: #{e.message}"
    end

    # The guest listener's echo from socket, up to its FIN: LISTEN_BYTES bytes within
    # TCP_SECONDS, or an Erx::Error that says how many came. The guest is the code under
    # test, so reading stops at the first byte past LISTEN_BYTES.
    def read_echo(socket)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TCP_SECONDS
      data = +''.b
      loop do
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless left.positive? && socket.wait_readable(left)
          raise Error, "the guest's listener did not close in #{TCP_SECONDS} s, after #{data.bytesize} bytes"
        end

        data << socket.readpartial(LISTEN_BYTES + 1 - data.bytesize)
        raise Error, "the guest's listener echoed more than the #{LISTEN_BYTES} bytes sent" if data.bytesize > LISTEN_BYTES
      end
    rescue EOFError
      return data if data.bytesize == LISTEN_BYTES

      raise Error, "the guest's listener echoed #{data.bytesize} bytes, not the #{LISTEN_BYTES} sent, then closed"
    end

    # A loopback TCP port free now, for QEMU's host forward to listen on. It is free only
    # until something else binds it; one that does fails the run, since the listener's
    # count must then still come from the guest's acceptor (tcp-accepted).
    def free_tcp_port
      probe = TCPServer.new('127.0.0.1', 0)
      probe.addr[1]
    ensure
      probe&.close
    end

    # The probe's answer: one merge at least, the one refusal, nothing left out, and one
    # device with DMA memory, whose record carries coherent.
    def probe_answer(coherent:) = "{true,1,0,[#{coherent}]}"

    # From the Ctrl-G menu to the system domain's command shell, whose ifconfig, ping and
    # host are refused for want of the `net` facet, then the probe at its Erlang shell.
    def system_checkpoints(coherent:)
      run = ProductionImage::Run
      [{ name: 'system-menu', pattern: run::CTRL_G_MENU, seconds: SHELL_SECONDS, type: 's' }.freeze,
       { name: 'system-shell', pattern: SessionDomain::MENU_LEFT, seconds: SHELL_SECONDS, type: IFCONFIG_LINE }.freeze,
       shell_point('system-ifconfig', Regexp.escape('ifconfig: no_facet'), type: PING_LINE),
       shell_point('system-ping', Regexp.escape('ping: no_facet'), type: HOST_LINE),
       shell_point('system-host', Regexp.escape('host: no_facet'), type: run::ERL_LINE),
       run::ERLANG_SHELL.merge(name: 'system-erlang-shell', type: PROBE_LINE).freeze,
       erl_point('network-probe', Regexp.escape(probe_answer(coherent: coherent)))].freeze
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
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @notes = []
        @measurements = []
      end

      # Boots the development image, its network row on BeamAsm (manifest), with a network
      # device under each accelerator on each of trees (TREES) and runs the exchange from
      # root's session. Returns { "<accelerator>-1cpu<tree suffix>" => 'passed' }; a guest
      # that misses a step raises.
      def call(accels:, trees: TREES.keys, jobs: 4, build: true)
        raise Error, 'the network device suite runs under tcg or hvf' unless accels.all? { |accel| %w[tcg hvf].include?(accel) }
        raise Error, "the network device suite boots on the trees #{TREES.keys.join(', ')}" unless (trees - TREES.keys).empty?

        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/net-device/image'))
        manifest = NetDevice.manifest(@platform.manifest_source(@root))
        image = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                    machine: ProductionImage::Machine.development(@platform), fiasco: fiasco)
                               .build(directory: directory, manifest_source: manifest).single
        accels.product(trees).to_h { |accel, tree| [NetDevice.cell(accel, tree), boot(accel, image, TREES.fetch(tree))] }
      end

      def notes = @notes.dup.freeze

      # One line per boot with the TCP transfer's time and rate, for the gate's output
      # only: no check reads them.
      def measurements = @measurements.dup.freeze

      private

      def boot(accel, image, tree)
        directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/net-device',
                                                                          "#{accel}#{tree.suffix}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"),
                                            mode: 0o700)
        node = NetDevice.nic_node(@platform)
        command_line = ProductionImage::Run::COMMAND_LINES[accel]
        dtb = tree.coherent ? nil : noncoherent_tree(accel: accel, image: image, node: node, command_line: command_line, directory: directory)
        link = Link.new
        server = NameServer.new(link)
        echo = EchoServer.new(limit: ECHO_LIMIT).start
        forward_port = NetDevice.free_tcp_port
        nic = QemuPlan::Nic.new(frames_port: link.frames_port, peer_port: link.peer_port, echo_port: echo.port,
                                forward_port: forward_port)
        answered = nil
        transfer_ms = nil
        verify_digest = ->(line) { transfer_ms = NetDevice.check_echo!(line, echo.received) }
        exchange = lambda do |_line|
          answered = NetDevice.exchange(link)
          server.start
        end
        session = SessionDomain.session_shell('root_1-shell', IFCONFIG_LINE).merge(verify: exchange).freeze
        checkpoints = [*Qemu.boot_transcript(memory_mib: @platform.memory_mib), NetDevice.tree_checkpoint(node, coherent: tree.coherent),
                       ProductionImage::Run::SLOGAN,
                       ProductionImage::Run::RELEASE_SHELL, session,
                       *NetDevice.shell_checkpoints(-> { answered.fetch(:mac) }),
                       *NetDevice.tcp_checkpoints(refused_port: echo.port, verify_digest: verify_digest, forward_port: forward_port),
                       *NetDevice.system_checkpoints(coherent: tree.coherent)]
        Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, image: image, memory_mib: @platform.memory_mib,
                                                   directory: directory, checkpoints: checkpoints, nic: nic, dtb: dtb,
                                                   command_line: command_line)
        failed = server.stop || echo.stop
        raise failed if failed

        @notes << "#{accel}, #{tree.coherent ? 'stock' : 'non-coherent'} tree: the root's line and the network domain's record said #{node} is #{tree.coherent ? '' : 'not '}coherent; " \
                  "the guest at #{GUEST_IP.join('.')} (#{answered.fetch(:mac)}) answered ARP and ICMP echo, " \
                  'and its shell showed vtnet0 with the lease, pinged 10.0.2.2 three times and resolved www ' \
                  "in the lease's domain through the name server at #{SERVER}, with random query IDs; " \
                  "its Erlang shell sent #{TCP_BYTES} bytes over TCP to the echo server and read them back, " \
                  "and was refused the host's loopback; it listened on #{QemuPlan::NIC_LISTEN_PORT} and its acceptor " \
                  "echoed #{LISTEN_BYTES} bytes the harness sent through slirp's host forward, then closed after the " \
                  "harness's FIN; the session's grant admitted every call " \
                  'of these and refused one that is no operation; the system shell was refused ifconfig, ping and host'
        @measurements << "net_device: #{accel}, 1 CPU, #{tree.coherent ? 'stock' : 'non-coherent'} tree: TCP from the guest's Erlang shell through slirp's guest forward " \
                         "to the harness's echo server: #{TCP_BYTES} bytes each way in #{transfer_ms} ms " \
                         "(#{rate(transfer_ms)} each way), from the start of the send to the last byte back"
        'passed'
      ensure
        echo&.stop
        server&.stop
        link&.close
      end

      # QEMU's tree for this boot's machine, without the network device's dma-coherent mark,
      # in the boot's directory. The dump's plan has no network device: a guest forward
      # connects to the harness's echo server when QEMU starts, and the device adds no node,
      # since QEMU's tree lists every virtio-mmio transport whether a device sits on it or not.
      def noncoherent_tree(accel:, image:, node:, command_line:, directory:)
        argv = QemuPlan.argv(platform: @platform, accel: accel, image: File.expand_path(image), serial: '/dev/null',
                             memory_mib: @platform.memory_mib, command_line: command_line)
        ProductionImage.seeded_tree(runner: @runner, argv: argv, path: File.join(directory, 'noncoherent.dtb')) do |listing|
          ProductionImage.seed_noncoherent(listing, node: node)
        end
      end

      def rate(ms) = ms.positive? ? format('%.1f MiB/s', TCP_BYTES * 1000.0 / ms / (1 << 20)) : 'too fast to rate'
    end
  end
end
