# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'block_device'
require_relative 'net_device'

module Erx
  # The drivers' domains on QEMU virt: what ends a domain that holds a device, and how it
  # comes back. The storage domain holds the block unit and runs the block driver and
  # littlefs's /data (docs/design-stopgap.md, "littlefs in the storage domain"); a failure
  # of littlefs ends that domain, whose restart gives it the device again and mounts /data
  # afresh.
  #
  # The littlefs restart boots the block device suite's test image (block_device.rb, which
  # builds it with the test module erx_blk_check) on a fresh medium and starts the module's
  # `lfs_restart` entry in the system domain. Its lines, in this order and no others
  # starting with "blk: ", each perhaps opened by the command shell's prompt:
  #
  #   blk: lfs wrote 10000 bytes    at the storage domain's node, /data/restarted written
  #                                 with DATA_BYTES bytes and closed
  #   blk: lfs worker found         the node's littlefs worker, the process the erx_lfs
  #                                 owner links to besides its supervisor, is found,
  #                                 and is killed a moment after this line leaves the node
  #   blk: storage domain ended     the system domain sees storage@erxos go down
  #   blk: storage domain back      the domain's next incarnation runs erx_storage
  #   blk: lfs read back 10000 bytes
  #                                 /data/restarted, read at the new incarnation, holds
  #                                 what was written: the same volume, mounted afresh
  #   blk: done
  #
  # A domain that stays up prints "blk: storage domain did not end" after a minute, one
  # that does not come back "blk: storage domain not back", and a step that fails at the
  # storage node "blk: no driver: REASON" or its own "failed" line.
  #
  # The corrupt volume boots the same image on a fresh medium whose /data a first boot
  # fills (the block device suite's data_write), and whose volume's superblock pair, both
  # copies of the root's metadata pair, the host then inverts. A mount never formats, so
  # each boot of the storage domain fails its mount with eintegrity and ends the domain,
  # and the domain service restarts it until its row's five restarts are spent. The second
  # boot starts the module's `lfs_corrupt` entry in the system domain, which prints
  #
  #   blk: storage domain ended 6 times
  #                                 its first boot and five restarts each ended, as the
  #                                 domain service's death records show
  #   blk: storage domain not restarted
  #                                 no incarnation is live, and none comes for a while
  #   blk: done
  #
  # and the harness then finds the data partition's bytes as the host left them. An
  # incarnation that runs erx_storage, which has mounted /data, prints "blk: storage
  # domain mounted /data after N ends" instead.
  #
  # The network domain holds the unit `net` and runs the network stack, which serves root's
  # session its grant, `net`, and the system domain its driver-control facet, `network_ctl`
  # (docs/design-stopgap.md, the network domain). Its cells boot the development image with
  # a network device, as the network device suite does, and type at the console's shells.
  # The harness plays a host on the guest's link (NetDevice::Link): the guest answering its
  # ARP request and ICMP echo (NetDevice.exchange) shows that the guest's link holds a
  # lease. The system domain's Erlang shell finds the network domain's row by name in the
  # domain service, and reads root's `net` by erpc in root's session (NETWORK_LINE).
  #
  # * network_ctl (control_checkpoints): erx_driver_ctl's restart, stop and start of the
  #   unit `net` each answer ok (CONTROL_LINE). Afterwards the network domain's only ready
  #   row is still the first incarnation, root's `net` is the same pid, and vtnet0's link
  #   supervisor is a new pid (SAME_LINE). Once the link has its lease again, root's
  #   command shell pings slirp's gateway once (PING_ONCE).
  # * exhaustion (exhaust_checkpoints): the system's shell checks that the first
  #   incarnation is still the live one, then spawns a fun in the network domain that kills
  #   the stack's interfaces supervisor. The stack's top supervisor does not survive that
  #   (erx_net_sup, intensity 0), so the permanent erx_net application ends the domain. The
  #   shell then polls (EXHAUST_LINE) until the network domain's only row is a new
  #   incarnation that is ready, the system domain holds a new `network_ctl` and root's
  #   session a new `net`. Once the new incarnation has its lease, root's command shell
  #   pings the gateway, and its Erlang shell connects through slirp's guest forward and
  #   closes the connection.
  #
  # The fun is the harness's own, typed at the system's shell: no image carries a trigger.
  module DriverDomains
    RESTART_ARGUMENTS = ['-pa', BlockDevice::GUEST_PATH, '-run', BlockDevice::GUEST_MODULE, 'lfs_restart'].freeze
    # Seconds the guest has, after its banner, to print "blk: done": the storage domain
    # boots twice, and the kill waits up to a minute for the first to end.
    RESTART_SECONDS = 300
    CORRUPT_ARGUMENTS = ['-pa', BlockDevice::GUEST_PATH, '-run', BlockDevice::GUEST_MODULE, 'lfs_corrupt'].freeze
    # Seconds the corrupt volume's guest has: six boots of the storage domain, each ending
    # at its mount, within the guest's five-minute watch.
    CORRUPT_SECONDS = 360

    # An Erlang expression written over several lines, typed as the shell takes it: one
    # line, each line break with its indentation a single space, the slots filled.
    def self.erlang_line(template, **slots) = "#{format(template, **slots).gsub(/\s*\n\s*/, " ").strip}\r".freeze

    # The network cells' Erlang lines, each written as Erlang and typed as one line
    # (erlang_line). NETWORK_LINE binds, in the system's Erlang shell, the funs Net, the
    # network domain's rows in the domain service, and Link, vtnet0's link supervisor in
    # the network domain as a list; and the first incarnation's id I0 and node N0, root's
    # `net` R0, the system's `network_ctl` C0 and vtnet0's link supervisor L0. Every later
    # system-shell line reads these bindings.
    ROOT_NET = 'erpc:call(root_1@erxos, erx, cap, [net])'
    NETWORK_TEMPLATE = <<~'ERLANG'
      Net = fun() -> [D || #{name := {erx_ident, <<"network">>}} = D <-
                           erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))] end,
      [#{id := I0, node := N0}] = Net(),
      Link = fun() -> [P || {vtnet0, P, _, _} <- erpc:call(N0, supervisor, which_children, [erx_net_interfaces])] end,
      [L0] = Link(), R0 = %<root_net>s, C0 = erx:cap(network_ctl),
      {is_pid(L0), is_pid(R0), is_pid(C0)}.
    ERLANG
    CONTROL_TEMPLATE = <<~'ERLANG'
      {erx_driver_ctl:restart(C0, net), erx_driver_ctl:stop(C0, net), erx_driver_ctl:start(C0, net)}.
    ERLANG
    SAME_TEMPLATE = <<~'ERLANG'
      [L1] = Link(),
      {[I || #{id := I, state := ready} <- Net()] =:= [I0], %<root_net>s =:= R0, is_pid(L1) andalso L1 =/= L0}.
    ERLANG
    # Checks that the first incarnation is still the live one, kills erx_net_interfaces in
    # it, then polls every 500 ms, at most EXHAUST_POLLS times, until the domain's only row
    # is a ready incarnation other than I0 and both facets are pids other than the first.
    EXHAUST_TEMPLATE = <<~'ERLANG'
      [I0] = [Id || #{id := Id, state := ready} <- Net()], C0 = erx:cap(network_ctl), R0 = %<root_net>s,
      ok = erpc:cast(N0, fun() -> exit(whereis(erx_net_interfaces), kill) end),
      (fun Poll(0) -> timeout;
           Poll(K) ->
               case {Net(), erx:cap(network_ctl), %<root_net>s} of
                   {[#{id := NewId, state := ready}], NewCtl, NewNet}
                     when NewId =/= I0, is_pid(NewCtl), NewCtl =/= C0, is_pid(NewNet), NewNet =/= R0 -> restarted;
                   _ -> timer:sleep(500), Poll(K - 1)
               end
       end)(%<polls>d).
    ERLANG
    EXHAUST_POLLS = 400
    NETWORK_LINE = DriverDomains.erlang_line(NETWORK_TEMPLATE, root_net: ROOT_NET)
    CONTROL_LINE = DriverDomains.erlang_line(CONTROL_TEMPLATE)
    SAME_LINE = DriverDomains.erlang_line(SAME_TEMPLATE, root_net: ROOT_NET)
    EXHAUST_LINE = DriverDomains.erlang_line(EXHAUST_TEMPLATE, root_net: ROOT_NET, polls: EXHAUST_POLLS)
    # Longer than the poll, which waits for a whole boot of the network domain.
    EXHAUST_SECONDS = 240
    PING_ONCE = "ping -c 1 10.0.2.2\r"
    PING_ONCE_COUNTS = Regexp.escape('1 packets transmitted, 1 packets received, 0.0% packet loss')
    # From a checkpoint whose verify waits for the lease: that wait and a shell answer.
    AFTER_LEASE_SECONDS = NetDevice::LEASE_SECONDS + NetDevice::REPLY_SECONDS + NetDevice::SHELL_SECONDS
    # The menu's line for root's first session, the first listed, with whatever id it took.
    ROOT_ENTRY = /\A  1[ *] root_1 \(domain [0-9]+\)\r*\n\z/n
    CTRL_G = ProductionImage::Run::CTRL_G

    module_function

    # From the shell that has the line, through the Ctrl-G menu, to the system's shell
    # (key `s`) or root's session (key `1`), then typed; each checkpoint's name starts
    # with the cell's.
    def to_system(cell, typed, seconds: NetDevice::SHELL_SECONDS)
      [{ name: "#{cell}-system-menu", pattern: SessionDomain::CTRL_G_MENU, seconds: seconds, type: 's' }.freeze,
       { name: "#{cell}-system-shell", pattern: SessionDomain::MENU_LEFT, seconds: NetDevice::SHELL_SECONDS,
         type: typed }.freeze]
    end

    def to_root(cell, typed, seconds:)
      [{ name: "#{cell}-root-menu", pattern: SessionDomain::CTRL_G_MENU, seconds: seconds }.freeze,
       { name: "#{cell}-root-entry", pattern: ROOT_ENTRY, seconds: NetDevice::SHELL_SECONDS, type: '1' }.freeze,
       { name: "#{cell}-root-shell", pattern: SessionDomain::MENU_LEFT, seconds: NetDevice::SHELL_SECONDS,
         type: typed }.freeze]
    end

    # The network cells' checkpoints after root's session's banner, whose verify waits for
    # the first lease; lease waits for the next one (NetDevice.exchange).
    def network_checkpoints(lease) = [*control_checkpoints(lease), *exhaust_checkpoints(lease)].freeze

    # From root's command shell to the system's Erlang shell, then network_ctl's cell,
    # ending at root's command shell with Ctrl-G typed.
    def control_checkpoints(lease)
      [*to_system('ctl', ProductionImage::Run::ERL_LINE, seconds: AFTER_LEASE_SECONDS),
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'system-erlang-shell', type: NETWORK_LINE).freeze,
       NetDevice.erl_point('network-found', Regexp.escape('{true,true,true}'), type: CONTROL_LINE),
       NetDevice.erl_point('ctl-restart-stop-start', Regexp.escape('{ok,ok,ok}'), type: SAME_LINE),
       NetDevice.erl_point('ctl-same-incarnation', Regexp.escape('{true,true,true}'), verify: lease, type: CTRL_G),
       *to_root('ctl', PING_ONCE, seconds: AFTER_LEASE_SECONDS),
       NetDevice.shell_point('ctl-ping', PING_ONCE_COUNTS, type: CTRL_G)]
    end

    # From root's command shell back to the system's Erlang shell, then the exhaustion's
    # cell, ending at root's Erlang shell.
    def exhaust_checkpoints(lease)
      [*to_system('exhaust', EXHAUST_LINE),
       NetDevice.erl_point('exhaust-restarted', 'restarted', seconds: EXHAUST_SECONDS, verify: lease, type: CTRL_G),
       *to_root('exhaust', PING_ONCE, seconds: AFTER_LEASE_SECONDS),
       NetDevice.shell_point('exhaust-ping', PING_ONCE_COUNTS, type: ProductionImage::Run::ERL_LINE),
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'root-erlang-shell', type: NetDevice::CONNECT_LINE).freeze,
       NetDevice.erl_point('exhaust-tcp-connect', 'ok', type: NetDevice::CLOSE_LINE),
       NetDevice.erl_point('exhaust-tcp-close', 'ok')]
    end

    def restart_expected_lines
      bytes = BlockDevice::DATA_BYTES
      ["blk: lfs wrote #{bytes} bytes", 'blk: lfs worker found', 'blk: storage domain ended',
       'blk: storage domain back', "blk: lfs read back #{bytes} bytes", 'blk: done']
    end

    def corrupt_expected_lines = ['blk: storage domain ended 6 times', 'blk: storage domain not restarted', 'blk: done']

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @block = BlockDevice::Run.new(root: root, runner: runner, compiler: compiler, linker: linker)
      end

      # Runs the littlefs restart, the corrupt volume and the network cells under each
      # accelerator at one CPU. Returns { "<accelerator>-1cpu" => 'passed' }; any
      # disagreement raises.
      def call(accels:, jobs: 4, build: true)
        image = @block.test_image_for(accels: accels, jobs: jobs, build: build)
        development = development_image
        accels.to_h do |accel|
          ["#{accel}-1cpu", @block.boot_fresh_medium(accel, image, arguments: RESTART_ARGUMENTS,
                                                                   expected: DriverDomains.restart_expected_lines,
                                                                   seconds: RESTART_SECONDS) &&
                                @block.boot_corrupt_medium(accel, image, arguments: CORRUPT_ARGUMENTS,
                                                                         expected: DriverDomains.corrupt_expected_lines,
                                                                         seconds: CORRUPT_SECONDS) &&
                                boot_network(accel, development)]
        end
      end

      private

      # The development image, built as the network device suite builds it, in a directory
      # of this suite's own. The block image's build has built the kernel when asked to.
      def development_image
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        directory = ProductionImage.clear_directory(root: @root,
                                                    path: File.join(@root, 'build/driver-domains/network-image'))
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                       .build(directory: directory).single
      end

      # The network cells in one boot: network_ctl first, whose incarnation must stay, then
      # the exhaustion, which ends it. Returns 'passed'; a missed checkpoint raises.
      def boot_network(accel, image)
        name = "network-#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"
        directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/driver-domains', name),
                                            mode: 0o700)
        link = NetDevice::Link.new
        echo = NetDevice::EchoServer.new(limit: NetDevice::ECHO_LIMIT).start
        nic = QemuPlan::Nic.new(frames_port: link.frames_port, peer_port: link.peer_port, echo_port: echo.port)
        lease = ->(_line) { NetDevice.exchange(link) }
        session = SessionDomain.session_shell('root_1-shell', ProductionImage::Run::CTRL_G).merge(verify: lease).freeze
        checkpoints = [*Qemu.boot_transcript(memory_mib: ProductionImage::MEMORY_MIB), ProductionImage::Run::SLOGAN,
                       ProductionImage::Run::RELEASE_SHELL, session, *DriverDomains.network_checkpoints(lease)]
        Qemu.new(root: @root, runner: @runner).run(accel: accel, image: image, memory_mib: ProductionImage::MEMORY_MIB,
                                                   directory: directory, checkpoints: checkpoints, nic: nic,
                                                   command_line: ProductionImage::Run::COMMAND_LINES[accel])
        failed = echo.stop
        raise failed if failed

        'passed'
      ensure
        echo&.stop
        link&.close
      end
    end
  end
end
