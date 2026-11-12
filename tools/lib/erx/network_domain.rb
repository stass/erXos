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
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The network domain's footprint on the medium machine: the development manifest, whose
  # `network` domain runs the stack (docs/design-network-stack.md, "Who holds the network
  # device"), with one edit, the domain's row restarting it 0 times, so that the cell ends
  # it for good with one kill.
  #
  # The image is the medium machine's (MediumBoot.machine), with the release medium, so
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
  # Erlang shell, the echo's bindings) between the lease and the last reading. The domain
  # runs within the development manifest's budget, so the cell also shows that the budget
  # holds the domain through the echo.
  module NetworkDomain
    # The one edit of the development manifest: a pattern that must match exactly once,
    # and its replacement, given the match.
    EDIT = [/^(domain network\n(?:  .*\n)*?  restarts )[0-9]+$/, ->(m) { "#{m[1]}0" }].freeze

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
      'NdIfs = fun(NdN) -> erpc:call(NdN, erx_net, interfaces, [], 5000) end',
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

    # The development manifest source with EDIT.
    def manifest(source)
      pattern, replace = EDIT
      raise Error, "the manifest does not have exactly one match of #{pattern.source}" unless source.scan(pattern).size == 1

      source.sub(pattern) { replace.call(Regexp.last_match) }
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
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @machine = MediumBoot.machine(platform)
        @manifest = NetworkDomain.manifest(platform.manifest_source(@root))
        @measurements = []
      end

      # One line with the domain's footprint at each figure, for the gate's output.
      def measurements = @measurements.dup.freeze

      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/network-domain/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                     fiasco: fiasco)
                                .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
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
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        Qemu.new(root: @root, runner: @runner).run(platform: @machine.platform, accel: accel, cpus: 1, image: built.single,
                                                   memory_mib: @machine.memory_mib,
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
        @measurements << "network_domain: #{accel}, 1 CPU, #{@machine.memory_mib} MiB: the network domain's root pool pages " \
                         "after the lease at least #{figures.fetch(:lease) - ended}, after ping and a #{ECHO_BYTES}-byte TCP echo " \
                         "#{figures.fetch(:echoed) - ended} (pages in use with the domain up minus #{ended} once it ended)"
      end
    end
  end
end
