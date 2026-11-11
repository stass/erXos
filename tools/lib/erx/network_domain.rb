# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'net_device'
require_relative 'net_device_echo_server'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu_gate'
require_relative 'qemu'
require_relative 'release_files'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The network stack in a network domain of its own, root's session using it, on a test
  # manifest (docs/design-network-stack.md, "Who holds the network device"). The development
  # manifest keeps the stack in the system domain; manifest gives the rows that move it:
  #
  # * the domain `network`, a BeamAsm service domain booting the network script
  #   (ProductionImage::DOMAIN_BOOTS) with the stack's arguments, which leave system_args,
  #   under runtime limits that take 128 KiB frames; its row restarts it 0 times, so that
  #   the cell ends it for good with one kill;
  # * the unit `net` held by the network domain, so the system domain holds no network
  #   device;
  # * the services `net` and `network_ctl` of the network domain, and their facets: `net`
  #   to every session of the system principal, `network_ctl` to the system domain;
  # * root's session with erx_net_client in its boot script (SESSION_SCRIPT) and the
  #   client's `grant` key naming erx_net_client_erxos, which reads the session's `net`
  #   facet at each use; the session's lane grows to 64 KiB and its connections by 2;
  # * room for the third domain in the system principal and the machine.
  #
  # The system release still ships the stack for the development manifest and starts it
  # temporary (ReleaseFiles::TEMPORARY); without the stack's arguments it defaults to the
  # runtime erx_net_local, which the erXos build does not ship, so it ends at once on this
  # image, logged as a crash, and the system domain goes on.
  #
  # The image is the medium machine's (MediumBoot::MACHINE), with the release medium, so
  # the storage domain runs as on the development image. The cell boots it with a network
  # device on slirp (QemuPlan::Nic). At the system's Erlang shell it waits for the network
  # domain's DHCP lease, and checks that the system domain's boot arguments give it no
  # network device while the network domain's give it one. Root's session then runs
  # ifconfig, which shows the lease, ping -c 3 to slirp's gateway, and from its Erlang
  # shell a 1 MiB TCP echo through slirp's guest forward. Last, the system's shell kills the
  # network domain's pid and, once the domain is gone, reads the root's pool pages again:
  # each figure (after the lease, after the echo) minus that last one is the domain's
  # footprint as MediumBoot::Footprint counts it, printed in the run's measurements. The
  # echo's figure is exact; the lease's is a lower bound, since root's session grows (its
  # Erlang shell, the echo's bindings) between the lease and the last reading.
  module NetworkDomain
    MACHINE = MediumBoot::MACHINE
    # The network domain's budget while it is measured: generous, so the measurement is
    # not bounded by it (the measurement in docs/design-network-stack.md, "Where C is used, and what is
    # measured").
    MEMORY = 64 << 20
    OUTER = 1 << 20
    MAX_FRAME = 131_072
    LANE = 65_536
    # The stack's arguments, as system_args gives them on the development manifest.
    STACK_ARGS = ' -erx_net interfaces {erx_virtio_net,interfaces,[]} -erx_net runtime erx_net_erxos'
    DOMAIN_ARGS = '-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx'
    CLIENT_GRANT = ' -erx_net_client grant {erx_net_client_erxos,grant,[]}'
    # The session script with the network client, which the development table's lacks.
    SESSION_SCRIPT = ReleaseFiles.domain_boot('session', applications: [*ProductionImage::DOMAIN_BOOTS.fetch('session'),
                                                                        'erx_net_client'])
    ROWS = <<~ROWS
      runtime_limits network
        max_frame #{MAX_FRAME}
        max_message_heap 1048576
        funnel_depth 64
        exports 256
        tmp 0
        overlay 0
        atoms 16384
        foreign_atoms 1024
        processes 4096
      limits network
        memory #{MEMORY}
        outer #{OUTER}
        grant @share.users
        spaces none
        lane #{LANE}
        connections 2
        crash 0
        flags none
        runtime_limits @runtime_limits.network
        peer_held 4096
        peer_held_total 4096
      domain network
        principal @principal.system
        limits @limits.network
        kind service
        flags none
        runtime @artifact.jit
        release @artifact.network
        restarts 0
        restart_period_s 60
        args "#{DOMAIN_ARGS}#{STACK_ARGS}"
      service net
        server @domain.network
        interface net
      facet net
        grantee @session.system
        service @service.net
        operations none
        max_request 64
        in_flight 16
        reductions 100000
        period_ns 1000000000
        max_heap_size 65536
      service network_ctl
        server @domain.network
        interface driver_control
      facet network_ctl
        grantee system
        service @service.network_ctl
        operations none
        max_request 256
        in_flight 1
        reductions 100000
        period_ns 1000000000
        max_heap_size 65536
    ROWS
    # Each edit of the development manifest: a pattern that must match exactly once, and
    # its replacement, given the match.
    EDITS = [
      [/^(  system_args ".*?)#{Regexp.escape(STACK_ARGS)}"$/, ->(m) { "#{m[1]}\"" }],
      [/^(unit net\n  placement "net"\n  holder )system$/, ->(m) { "#{m[1]}@domain.network" }],
      [/^(session system\n(?:  .*\n)*?  args ".*?)( -eval [^ "]+")$/, ->(m) { "#{m[1]}#{CLIENT_GRANT}#{m[2]}" }],
      [/^(limits session\n(?:  .*\n)*?  lane )[0-9]+$/, ->(m) { "#{m[1]}#{LANE}" }],
      [/^(limits session\n(?:  .*\n)*?  connections )([0-9]+)$/, ->(m) { "#{m[1]}#{Integer(m[2], 10) + 2}" }],
      [/^(principal system\n  memory )([0-9]+)$/, ->(m) { "#{m[1]}#{Integer(m[2], 10) + MEMORY + OUTER}" }],
      [/^(  root_memory )([0-9]+)$/, ->(m) { "#{m[1]}#{Integer(m[2], 10) + MEMORY + OUTER}" }],
      [/^(principal system\n(?:  .*\n)*?  domains )([0-9]+)$/, ->(m) { "#{m[1]}#{Integer(m[2], 10) + 1}" }],
      [/^(  max_domains )([0-9]+)$/, ->(m) { "#{m[1]}#{Integer(m[2], 10) + 1}" }]
    ].freeze

    ECHO_BYTES = 1 << 20
    RECV_PIECE = NetDevice::RECV_PIECE
    # Typed at the session's Erlang shell: a connection through slirp's guest forward to
    # the harness's echo server, ECHO_BYTES each way, and whether they came back whole.
    ECHO_LINE = "begin {ok, S} = erx_gen_tcp:connect(#{NetDevice::ECHO_TUPLE}, #{QemuPlan::NIC_ECHO_PORT}, " \
                '[binary, {active, false}], 10000), ' \
                "D = rand:bytes(#{ECHO_BYTES}), ok = erx_gen_tcp:send(S, D), " \
                "E = iolist_to_binary([begin {ok, B} = erx_gen_tcp:recv(S, #{RECV_PIECE}, 10000), B end " \
                "|| _ <- lists:seq(1, #{ECHO_BYTES / RECV_PIECE})]), ok = erx_gen_tcp:close(S), E =:= D end.\r"
    # Typed at the system's Erlang shell, whose bindings carry the prefix Nd: the network
    # domain's node once it is up, its lease, the device records of both domains' boot
    # arguments, and the root's pool pages in use.
    LEASE_LINE = [
      'NdDomains = fun() -> erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv))) end',
      'NdUsed = fun() -> #{attrs := #{used := {_, {_, NdU}}}} = erx_kernel_records:budget(), NdU end',
      'NdIfs = fun(NdN) -> erpc:call(NdN, fun() -> {ok, NdG, _} = erx_net:local_grant(), ' \
      'gen_server:call(NdG, interfaces) end, 5000) end',
      'NdLeased = fun(NdN) -> string:find(lists:flatten(io_lib:format("~0p", [NdIfs(NdN)])), "{10,0,2,15}") =/= nomatch end',
      'NdWait = fun NdW(0) -> timeout; NdW(NdK) -> case catch [NdN || #{name := {erx_ident, <<"network">>}, node := NdN} <- NdDomains()] of ' \
      '[NdN] -> case catch NdLeased(NdN) of true -> NdN; _ -> timer:sleep(500), NdW(NdK - 1) end; ' \
      '_ -> timer:sleep(500), NdW(NdK - 1) end end',
      'NdNode = NdWait(360)',
      '{nd_lease, erx_device_record:find(net, virtio_mmio), ' \
      'case erpc:call(NdNode, erx_device_record, find, [net, virtio_mmio]) of {ok, [_ | _]} -> true; NdR -> NdR end, NdUsed()}'
    ].join(', ') + ".\r"
    ECHOED_LINE = "{nd_echoed, NdUsed()}.\r"
    # Ends the network domain for good: kills its domain pid, which its row restarts 0
    # times, waits until the domain service holds no record of it, then reads the pool
    # pages once its remains are gone.
    END_LINE = [
      '[NdPid] = [NdP || #{name := {erx_ident, <<"network">>}, pid := NdP} <- NdDomains()]',
      'exit(NdPid, kill)',
      'NdEnd = fun NdE(0) -> timeout; NdE(NdK) -> case [NdD || #{name := {erx_ident, <<"network">>}} = NdD <- NdDomains()] of ' \
      '[] -> ended; _ -> timer:sleep(500), NdE(NdK - 1) end end',
      'NdEnded = NdEnd(120)',
      'timer:sleep(5000)',
      '{nd_ended, NdEnded, NdUsed()}'
    ].join(', ') + ".\r"

    PROMPT = SessionDomain::PROMPT

    module_function

    # The development manifest source with the network domain's rows: EDITS, then ROWS.
    def manifest(source)
      EDITS.reduce(source) do |text, (pattern, replace)|
        raise Error, "the manifest does not have exactly one match of #{pattern.source}" unless text.scan(pattern).size == 1

        text.sub(pattern) { replace.call(Regexp.last_match) }
      end + ROWS
    end

    def answer(source) = /\A#{PROMPT}#{source}\r*\n\z/n

    # The production checkpoints to the system's command shell, then the cell; figures
    # collects the pool pages each answer gives.
    def checkpoints(points, figures)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      run = ProductionImage::Run
      menu_left = SessionDomain::MENU_LEFT
      figure = ->(key) { ->(line) { figures[key] = Integer(line[/([0-9]+)\}\r*\n\z/, 1], 10) } }
      [*points,
       SessionDomain.session_shell('root_1-shell', run::CTRL_G),
       { name: 'menu', pattern: run::CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'system-shell', pattern: menu_left, seconds: 30, type: run::ERL_LINE }.freeze,
       run::ERLANG_SHELL.merge(name: 'system-erlang-shell', type: LEASE_LINE).freeze,
       { name: 'lease', pattern: answer('\{nd_lease,\{ok,\[\]\},true,[0-9]+\}'), seconds: 240, verify: figure.call(:lease),
         type: run::CTRL_G }.freeze,
       { name: 'session-menu', pattern: run::CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'session-shell', pattern: menu_left, seconds: 30, type: NetDevice::IFCONFIG_LINE }.freeze,
       line_point('ifconfig-vtnet0', 'vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500'),
       line_point('ifconfig-inet', "\tinet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255", type: NetDevice::PING_LINE),
       line_point('ping-head', 'PING 10.0.2.2 (10.0.2.2): 56 data bytes'),
       line_point('ping-counts', '3 packets transmitted, 3 packets received, 0.0% packet loss', type: run::ERL_LINE),
       run::ERLANG_SHELL.merge(name: 'session-erlang-shell', type: ECHO_LINE).freeze,
       { name: 'tcp-echo', pattern: answer('true'), seconds: 120, type: run::CTRL_G }.freeze,
       { name: 'system-menu', pattern: run::CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'system-again', pattern: menu_left, seconds: 30, type: ECHOED_LINE }.freeze,
       { name: 'echoed', pattern: answer('\{nd_echoed,[0-9]+\}'), seconds: 60, verify: figure.call(:echoed),
         type: END_LINE }.freeze,
       { name: 'ended', pattern: answer('\{nd_ended,ended,[0-9]+\}'), seconds: 120, verify: figure.call(:ended) }.freeze]
    end

    def line_point(name, text, type: nil)
      { name: name, pattern: /\A#{Regexp.escape(text)}\r*\n\z/n, seconds: 60, type: type }.compact.freeze
    end

    # Builds the image once and boots it under HVF with one CPU. Returns
    # { CELL => 'passed' }; any disagreement raises.
    class Run
      CELL = "#{QemuGate::SUITE_ACCELERATOR}-1cpu-network-domain"

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @manifest = NetworkDomain.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)))
        @measurements = []
      end

      # One line with the domain's footprint at each figure, for the gate's output.
      def measurements = @measurements.dup.freeze

      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/network-domain/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest,
                                              domains: [SESSION_SCRIPT])
        { CELL => boot(built) }
      end

      private

      def boot(built)
        accel = QemuGate::SUITE_ACCELERATOR
        echo = NetDevice::EchoServer.new(limit: 2 * ECHO_BYTES).start
        link = NetDevice::Link.new
        nic = QemuPlan::Nic.new(frames_port: link.frames_port, peer_port: link.peer_port, echo_port: echo.port)
        figures = {}
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib)
        Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: 1, image: built.single, memory_mib: MACHINE.memory_mib,
                                                   checkpoints: NetworkDomain.checkpoints(points, figures), nic: nic)
        failed = echo.stop
        raise failed if failed

        record(accel, figures)
        'passed'
      ensure
        echo&.stop
        link&.close
      end

      def record(accel, figures)
        ended = figures.fetch(:ended)
        @measurements << "network_domain: #{accel}, 1 CPU, #{MACHINE.memory_mib} MiB: the network domain's root pool pages " \
                         "after the lease at least #{figures.fetch(:lease) - ended}, after ping and a #{ECHO_BYTES}-byte TCP echo " \
                         "#{figures.fetch(:echoed) - ended} (pages in use with the domain up minus #{ended} once it ended)"
      end
    end
  end
end
