# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

require 'socket'
require_relative 'boot_record'
require_relative 'bumble'
require_relative 'display_domain'
require_relative 'error'
require_relative 'fiasco'
require_relative 'image_apps'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'pcie_domain'
require_relative 'process_group'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # QEMU virt's Bluetooth suite (docs/design-bluetooth.md, "On QEMU against Bumble"). Its
  # manifest is the development manifest with the Bluetooth domain added (manifest): the
  # line unit, the virtio console of the platform's line row, placed on the system domain,
  # which serves its line tree; the domain's rows; and its one `line` grant, naming that
  # console. The harness serves Bumble's two controllers on loopback ports (Controllers),
  # boots that manifest on MediumBoot's machine with the line's console joined to the first
  # controller's port (QemuPlan::Line), and from the system's Erlang shell, as a person
  # would type it, waits for the Bluetooth domain and then for its controller process's
  # bring-up, whose facts the line prints (line). The bring-up case passes when those facts
  # are a map: every step from the line's reset through the identify answered by Bumble's
  # controller over the console (check_ready).
  module BtDomain
    DOMAIN = 'bt'
    NODE = "#{DOMAIN}@erxos".freeze
    LINE_UNIT = 'line'

    # The domain's memory, 32 MiB, a first figure above the PCIe domain's 25 MiB for an
    # interpreter domain of the same base with erx_bt and crypto loaded; it is not yet
    # measured at rest. Its outer budget is MediumBoot's, 1 MiB, as every service domain's.
    MEMORY = 32 << 20
    # The domain's rows (docs/design-bluetooth.md, "The Bluetooth domain"). Its runtime
    # limits are the PCIe domain's, whose max_frame, 131,072, is the line tree's floor,
    # files_max_frame_min (property 16). Its grant is a share of its own, 50 mcpu on CPU
    # 0, as the PCIe domain's. Its arguments name it, so a scanner tells
    # it from the host. Its release's script starts erx_bt, whose start names the mint of
    # ble, and its -eval starts the rest of the stack once init holds the ready answer's
    # facets, the line grant among them. The service ble, which the domain serves, has
    # no grant here: its row makes the domain service accept the mint the domain names.
    ROWS = <<~ROWS.freeze
      runtime_limits #{DOMAIN}
        max_frame 131072
        max_message_heap 131072
        funnel_depth 64
        exports 256
        tmp 0
        overlay 0
        atoms 16384
        foreign_atoms 1024
        processes 1024
      share #{DOMAIN}
        quota_ns 500000
        period_ns 10000000
        cpuset 1
        capacity_mcpu 50
        capacity_first 0
        slice_us 1000
        grace_us 5
        base 16
        ceiling 31
        flags none
      limits #{DOMAIN}
        memory #{MEMORY}
        outer #{MediumBoot::DOMAIN_OUTER}
        grant @share.#{DOMAIN}
        spaces none
        lane 4096
        connections 1
        crash 0
        flags none
        runtime_limits @runtime_limits.#{DOMAIN}
        band driver
        peer_held 4096
        peer_held_total 4096
      domain #{DOMAIN}
        principal @principal.system
        limits @limits.#{DOMAIN}
        kind service
        flags none
        runtime @artifact.emu
        release @artifact.#{DOMAIN}
        restarts 0
        restart_period_s 600
        args "-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx -erx_bt name \\"erxos-bt\\" -eval ok=erx_bt_top:start_stack()"
      service ble
        server @domain.#{DOMAIN}
        interface ble
    ROWS

    # The echo domain (docs/design-bluetooth.md, "On QEMU against Bumble"): the handler of
    # nus that the serial peer talks to, erx_gatt_echo_test, in a domain of the suite's own,
    # since ble_grant refuses a grant to the system domain (B8). Its boot script, ECHO_BOOT,
    # is MediumBoot's with the client library and the echo, which only a test image carries
    # (ProductionImage#build_test_image).
    #
    # Its grant is a grant of its own from the Bluetooth domain's share record, 50 mcpu on
    # CPU 0: MediumBoot's eighth of a CPU does not fit the system share's reserve beside
    # the medium manifest's other domains (the planner refuses the web domain then), and
    # the suite leaves the media domain out (medium) for the same reason. Its
    # memory is the Bluetooth domain's MEMORY, reused unmeasured. Its arguments are
    # MediumBoot's without the halt, so it stays up.
    #
    # Its one facet is ble for nus. The domain service makes it by introducing the two
    # domains, so the echo's limits allow one connection (the Bluetooth domain's already
    # allow one) and the machine's max_connections grows by ECHO_CONNECTIONS (manifest). The request
    # bound, 1,024 octets, is above the largest request a handler makes, a notify of tx's
    # 244 octets with its term's framing; 16 may be in flight.
    # The connections the echo domain's one facet, ble for nus, adds to the machine's
    # max_connections (manifest).
    ECHO_CONNECTIONS = 1
    ECHO_DOMAIN = 'echo'
    ECHO_NODE = "#{ECHO_DOMAIN}@erxos".freeze
    ECHO_BOOT = ReleaseFiles.domain_boot('gatt_echo', applications: [*MediumBoot::DOMAIN_BOOT.applications, 'erx_bt_client',
                                                                     'erx_gatt_echo_test'], test: true)
    ECHO_ROWS = <<~ROWS.freeze
      limits #{ECHO_DOMAIN}
        memory #{MEMORY}
        outer #{MediumBoot::DOMAIN_OUTER}
        grant @share.#{DOMAIN}
        spaces none
        lane 4096
        connections 1
        crash 0
        flags none
        runtime_limits @runtime_limits.system
        band interactive
        peer_held 4096
        peer_held_total 4096
      domain #{ECHO_DOMAIN}
        principal @principal.system
        limits @limits.#{ECHO_DOMAIN}
        kind service
        flags none
        runtime @artifact.#{ProductionImage::DOMAIN_RUNTIME_ARTIFACT}
        release @artifact.#{ECHO_BOOT.name}
        restarts 0
        restart_period_s 5
        args "#{MediumBoot::UP_ARGS.join(' ')}"
      facet ble
        grantee @domain.#{ECHO_DOMAIN}
        service @service.ble
        operations none
        max_request 1024
        in_flight 16
        reductions 100000
        period_ns 1000000000
        max_heap_size 262144
        parameter services "nus"
    ROWS
    # The line grant (docs/design-bluetooth.md, "The controller's line"): the device the
    # platform's line unit holds, a virtio console, which states no rate or flow, and a
    # files tree's quantities, as the data volume's grants: requests of the floor
    # files_max_frame_min, 16 in flight.
    def self.line_grant(device) = "facet line\n  grantee @domain.#{DOMAIN}\n  service @service.line\n  operations none\n" \
                                  "  max_request 131072\n  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n" \
                                  "  max_heap_size 262144\n  parameter device \"#{device}\"\n"

    # The device of platform's line unit, a Platform of QEMU virt: its one device's path.
    def self.line_device(platform)
      devices = platform.record.fetch('units').select { |unit| unit.fetch('key') == LINE_UNIT }.flat_map { |unit| unit.fetch('devices') }
      raise Error, "the platform's line unit is not one serial device" unless devices.size == 1 && devices.first.fetch('role') == 'serial'

      devices.first.fetch('path')
    end

    # The suite's manifest from the development manifest's text, source, on platform: the
    # cells' medium manifest (medium) with the echo domain's rows (ECHO_ROWS), and room
    # for the echo domain: one more domain of MEMORY in the principal's quota and
    # max_domains, and the ECHO_CONNECTIONS its grant makes in max_connections.
    def self.manifest(source, platform:)
      MediumBoot.grown(medium(source, platform: platform) + ECHO_ROWS, memory: MEMORY + MediumBoot::DOMAIN_OUTER,
                                                                       domains: 1, connections: ECHO_CONNECTIONS)
    end

    # The medium manifest both cells start from, from the development manifest's text,
    # source, on platform: the line unit on the system domain, with root_memory grown by its
    # DMA memory (Manifest::Edit.with_unit), without the media domain, then MediumBoot's
    # medium manifest with the Bluetooth domain's rows (ROWS) and line grant and room for
    # one domain of MEMORY. The echo cell leaves the media domain out for the 50 mcpu its
    # Bluetooth and echo domains' 100 need beside the others (2,325 at most); the app cell
    # starts from the same manifest, so it boots no domain the echo cell leaves out.
    # MediumBoot drops the system principal's session template, as for every medium cell:
    # the shell the line is typed at runs on the console, and the room one more domain
    # gives the principal makes no more sessions that the display's grants would have to
    # fit in its outer budget. The restarts are 0, so a failed bring-up that ends a domain
    # stays ended.
    def self.medium(source, platform:)
      units = platform.record.fetch('units')
      lined = Manifest::Edit.with_unit(Manifest::Edit.without_domain(source, 'media', units: units), LINE_UNIT,
                                       holder: 'system', units: units)
      MediumBoot.manifest(lined, row: ROWS + line_grant(line_device(platform)), domains: 1, domain_memory: MEMORY)
    end
    private_class_method :medium
    # The app cell (docs/design-bluetooth.md, "On QEMU against Bumble", and "Decisions", 7):
    # the installed-app echo of decisions 6 and 7, examples/echo (ImageApps::ECHO), which
    # declares gatt nus, lies in the image's system partition enabled, and answers through
    # its own session's ble grant, which the build derives from the apps row and the
    # domain service narrows to the package's gatt. APP_NAME is its package's name,
    # ADMITTED and ECHOING the lines the system logs at its admission and the app once its
    # handler has attached nus, and APP_SECONDS how long the shell's check waits for both.
    APP_CELL = '-app'
    APP_NAME = 'echo'
    APP_GATT = %w[nus].freeze
    ADMITTED = /packages: admitted #{APP_NAME}\r?\n/n
    ECHOING = /erx_echo: echoing nus/n
    APP_SECONDS = 240

    # The app cell's manifest from the development manifest's text, source, on platform:
    # the cells' medium manifest (medium) without the echo domain's rows, and with the apps
    # row offering ble beside its services and APP_GATT as its gatt (Manifest::Edit.offering),
    # so the one grant of ble for nus is the app template's.
    def self.app_manifest(source, platform:)
      Manifest::Edit.offering(medium(source, platform: platform), service: 'ble', gatt: APP_GATT)
    end

    # The line typed at the Erlang shell, one expression per element: the wait for the
    # domain (PcieDomain::WAIT); BtFacts, run at the domain, its controller process's
    # bring-up facts (erx_bt_hci:facts/0) printed there as a string, or none before the
    # bring-up is ready: the facts' atoms are the Bluetooth domain's, and a frame to the
    # system domain creates no atom, so a term holding one of them arrives as an opaque
    # erx_foreign_reason; then BtReady(Last, K), which runs BtFacts every 100 ms at most
    # K times until it answers a string, and answers it, or {timeout, Last}, the last
    # answer. Every variable of its own starts with Bt, which nothing else the shell runs
    # binds.
    def self.line = [
      *PcieDomain::WAIT,
      "BtDom=PcWait(#{NODE},1200)",
      # BtFacts(): run at the domain, the bring-up's facts as a string, or none.
      'BtFacts=fun()->case erx_bt_hci:facts() of #{ready:=none}->none;' \
      '#{ready:=BtM}->lists:flatten(io_lib:format("~0p",[BtM])) end end',
      # BtReady(Last, K): BtFacts every 100 ms, each call given 1 s, at most K times.
      "BtReady=fun BtR(BtA,0)->{timeout,BtA};BtR(_,BtK)->case catch erpc:call(#{NODE},BtFacts,1000) of " \
      '[$#|_]=BtF->BtF;BtO->timer:sleep(100),BtR(BtO,BtK-1) end end',
      # The answer: the facts, or why none came.
      "io:format(\"~0kp~n\",[{bt_ready,case BtDom of timeout->{no_domain,PcFind(#{NODE})};_->BtReady(none,600) end}])"
    ].join(',').concat(".\r").freeze

    # The line typed once the bring-up answered, in the same shell, whose PcWait and PcFind
    # it reuses: the wait for the echo domain, then BtEcho(K), which asks the echo domain
    # every 100 ms, at most K times, whether its serial handler has attached nus, and
    # answers attached or timeout. The handler, erx_gatt_serial, answers sys:get_state/2
    # only once its init returned, which is after its attach succeeded, so a state means
    # the registry has the handler the peer's writes reach. The question runs at the echo
    # domain and answers a boolean, so no atom of its own crosses back.
    def self.echo_line = [
      "BtEchoDom=PcWait(#{ECHO_NODE},1200)",
      "BtEchoRuns=fun()->case catch sys:get_state(erx_gatt_serial,500) of {'EXIT',_}->false;_->true end end",
      "BtEcho=fun BtE(0)->timeout;BtE(BtK)->case catch erpc:call(#{ECHO_NODE},BtEchoRuns,1000) of " \
      'true->attached;_->timer:sleep(100),BtE(BtK-1) end end',
      "io:format(\"~0kp~n\",[{bt_echo,case BtEchoDom of timeout->{no_domain,PcFind(#{ECHO_NODE})};_->BtEcho(100) end}])"
    ].join(',').concat(".\r").freeze

    # The answers' lines, which the shell's prompt may precede.
    ANSWER = /\A#{PcieDomain::PROMPT}\{bt_ready,/n
    ECHO_ANSWER = /\A#{PcieDomain::PROMPT}\{bt_echo,/n
    # How long the echo line may take: the domain's wait, 1,200 polls of 100 ms, and the
    # handler's 100 polls of at most 1.1 s, so the line answers within it, timeout included.
    ECHO_SECONDS = 240
    # How long the line may take to print its answer: the domain's wait (1,200 polls of
    # 100 ms), its boot, and the bring-up's 600 polls of at most 1.1 s; a bring-up that
    # needs them all fails the checkpoint without the line's own timeout answer.
    READY_SECONDS = 240

    module_function

    # The bring-up case: the answer, its prompt removed, is {bt_ready, Facts} with Facts a
    # map, printed at the Bluetooth domain as a string, or Error naming what came.
    READY_LINE = /\A\{bt_ready,"#\{.*\}"\}\z/n
    def check_ready(text)
      line = text.b.sub(/\A#{PcieDomain::PROMPT}/n, '').strip
      raise Error, "the Bluetooth domain's bring-up answered #{line.inspect}, not its facts" unless READY_LINE.match?(line)
    end

    # The echo case: the answer, its prompt removed, is {bt_echo,attached}, or Error naming
    # what came.
    def check_echo(text)
      line = text.b.sub(/\A#{PcieDomain::PROMPT}/n, '').strip
      raise Error, "the echo domain answered #{line.inspect}, not that its handler attached nus" unless line == '{bt_echo,attached}'
    end

    # The production checkpoints to the command shell, then the Erlang shell, the line and
    # its answer, checked as the bring-up case, then the echo line and its answer, checked
    # as the echo case, after which serial runs the serial row, for at most
    # Serial::SECONDS. points must end at the command shell.
    def checkpoints(points, serial:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: BtDomain.line).freeze,
       { name: 'bt-ready', pattern: ANSWER, seconds: READY_SECONDS, verify: ->(text) { check_ready(text) },
         type: BtDomain.echo_line }.freeze,
       { name: 'bt-serial', pattern: ECHO_ANSWER, seconds: ECHO_SECONDS, verify_seconds: Serial::BOUND_SECONDS,
         verify: lambda { |text|
           check_echo(text)
           serial.call
         } }.freeze].freeze
    end

    # The app cell's checkpoints: the production checkpoints, the last at the command shell,
    # which waits in the serial log at log for the echo's ECHOING line, checks that the
    # system admitted the package (ADMITTED), and then runs the serial row through the app
    # (serial). points must end at the command shell.
    def app_checkpoints(points, log:, serial:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      check = lambda do |_text|
        seen = DisplayDomain.await_log(log, wait_seconds: APP_SECONDS) { |text| text.match?(ECHOING) }
        raise Error, "the #{APP_NAME} app logged no attach of nus within #{APP_SECONDS} s" unless seen.match?(ECHOING)
      raise Error, "the system did not admit the #{APP_NAME} package" unless seen.match?(ADMITTED)

        serial.call
      end
      [*points[0...-1], points.last.merge(verify: check, verify_seconds: APP_SECONDS + Serial::BOUND_SECONDS).freeze].freeze
    end

    # Bumble's apps/controllers.py, unmodified, with its two controllers joined by its local
    # link, each on a TCP server transport bound to 127.0.0.1 (docs/design-bluetooth.md, "On
    # QEMU against Bumble"): the first for erXos's line, the second for a peer. It runs
    # under the runner's deadline tool in a process group of its own, standard input closed,
    # its output and Bumble's debug log, which shows every HCI packet, in log.
    module Controllers
      SCRIPT = 'apps/controllers.py'
      LOG_LEVEL = { 'BUMBLE_LOGLEVEL' => 'DEBUG' }.freeze
      LISTEN_SECONDS = 30
      KILL_AFTER_SECONDS = 10

      Ports = Data.define(:line, :peer)

      module_function

      # Runs the block with the controllers' Ports once both listen, and ends their process
      # group (ProcessGroup.terminate) when it returns or raises. seconds is their deadline,
      # timeout_program the tool that enforces it.
      def serve(environment, log:, seconds:, timeout_program:)
        line, peer = free_ports(2)
        ports = Ports.new(line: line, peer: peer)
        argv = [timeout_program, '-k', KILL_AFTER_SECONDS.to_s, seconds.to_s,
                *environment.argv(File.join(environment.tree, SCRIPT), *[ports.line, ports.peer].map { |port| "tcp-server:127.0.0.1:#{port}" })]
        pid = nil
        # The spawn and the pid's assignment are one step, so an interrupt cannot come between.
        Thread.handle_interrupt(Object => :never) do
          pid = Process.spawn(LOG_LEVEL, *argv, in: File::NULL, %i[out err] => [log, 'w', 0o600], pgroup: true)
        end
        begin
          listening(ports, pid: pid, log: log)
          yield ports
        ensure
          Thread.handle_interrupt(Object => :never) { ProcessGroup.terminate(pid) }
        end
      end

      # count distinct loopback ports the kernel picks, each held until all are picked.
      # Another process may take one between its release and Bumble's bind; Bumble then
      # ends, which listening reports.
      def free_ports(count)
        servers = []
        count.times { servers << TCPServer.new('127.0.0.1', 0) }
        servers.map { |server| server.addr[1] }
      ensure
        servers.each(&:close)
      end

      # Waits until the peer's port accepts a connection, which it closes at once, and the
      # controllers still run. controllers.py opens the line's transport first, so the peer's
      # listening means the line's does; the line's port is never touched, since every
      # connection to a Bumble server transport shares one sink, which a probe's end would
      # clear after QEMU had connected. Refused when the controllers end or LISTEN_SECONDS
      # pass first.
      def listening(ports, pid:, log:)
        limit = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LISTEN_SECONDS
        begin
          Socket.tcp('127.0.0.1', ports.peer, connect_timeout: 1).close
        rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
          ended!(pid, log)
          raise Error, "Bumble's controllers did not listen on #{ports.peer} within #{LISTEN_SECONDS} s; see #{log}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > limit

          sleep(0.2)
          retry
        end
        ended!(pid, log)
      end

      # Refuses controllers that have ended, as they do when another process holds a port.
      def ended!(pid, log)
        raise Error, "Bumble's controllers ended before both their ports listened; see #{log}" if Process.wait(pid, Process::WNOHANG)
      end
    end

    # The serial row (docs/design-bluetooth.md, "On QEMU against Bumble", stage 3):
    # test/bt/peer/serial_peer.py on the controllers' second port, under the runner's
    # deadline tool, standard input closed, its standard output in out and its standard
    # error, where Bumble's warnings go, in log. The row passes when the peer exits 0 having
    # printed its one passing line; check reads at most MAX_OUTPUT bytes of what it printed.
    module Serial
      SCRIPT = 'test/bt/peer/serial_peer.py'
      # The peer's own bounds: its scan, its connection, 64 KiB of writes with response and
      # their drain, with a margin. The checkpoint's verify may take this long.
      SECONDS = 300
      # The longest the row may take: the peer's deadline, its kill's grace and the
      # interpreter's start.
      BOUND_SECONDS = SECONDS + Controllers::KILL_AFTER_SECONDS + 10
      MAX_OUTPUT = 4096
      # The deadline tool's status when the deadline passed (GNU timeout).
      TIMED_OUT = 124
      PASSED = /\Aserial passed [0-9]+ [0-9]+\n\z/

      module_function

      def run(environment, root:, port:, directory:, timeout_program:)
        out = File.join(directory, 'serial-peer.out')
        log = File.join(directory, 'serial-peer.log')
        argv = [timeout_program, '-k', Controllers::KILL_AFTER_SECONDS.to_s, SECONDS.to_s,
                *environment.argv(File.join(root, SCRIPT), "tcp-client:127.0.0.1:#{port}")]
        status = nil
        Thread.handle_interrupt(Object => :never) do
          pid = Process.spawn(*argv, in: File::NULL, out: [out, 'w', 0o600], err: [log, 'w', 0o600], pgroup: true)
          begin
            Thread.handle_interrupt(Object => :immediate) { _, status = Process.wait2(pid) }
          ensure
            ProcessGroup.terminate(pid) unless status
          end
        end
        raise Error, "the serial peer did not end within #{SECONDS} s; see #{log}" if status.exitstatus == TIMED_OUT

        check(File.open(out, 'rb') { |file| file.read(MAX_OUTPUT) }.to_s, log: log)
        raise Error, "the serial peer exited #{status.exitstatus.inspect} after its passing line; see #{log}" unless status.success?
      end

      # The peer's output is its one passing line, or Error with what it printed, escaped,
      # and the log its standard error went to.
      def check(output, log:)
        raise Error, "the serial peer printed #{output.b.inspect}, not its passing line; see #{log}" unless PASSED.match?(output.b)
      end
    end

    # Boots the echo domain's image, then the app cell's medium, each under HVF with one CPU
    # against Bumble's controllers. Returns { "hvf-1cpu" => 'passed', "hvf-1cpu-app" =>
    # 'passed' }; a boot that does not reach the bring-up's facts, the echo's start or the
    # serial row's pass raises.
    class Run
      CELL_CPUS = 1

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        @manifest = BtDomain.manifest(platform.manifest_source(@root), platform: platform)
        @app_manifest = BtDomain.app_manifest(platform.manifest_source(@root), platform: platform)
      end

      # The cells' names: the echo domain's, then the app cell's.
      def self.cells
        cell = "#{QemuCells::LOCAL_ACCELERATOR}-#{CELL_CPUS}cpu"
        [cell, "#{cell}#{APP_CELL}"].freeze
      end

      # Packs the test image, which carries ECHO_BOOT, once, and boots it; then packs the
      # app cell's medium, which carries the echo package, and boots it.
      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        echo_cell, app_cell = Run.cells
        echo_boot(echo_cell, fiasco)
        app_boot(app_cell, fiasco)
        { echo_cell => 'passed', app_cell => 'passed' }
      end

      private

      # The echo domain's cell: one boot of the test image to the command shell, then the
      # lines' answers and the serial row.
      def echo_boot(cell, fiasco)
        image = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bt/image'))
        nothing = ProductionImage::Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
        built = production(fiasco).build_test_image(directory: image, added: nothing, domains: [ECHO_BOOT],
                                                    manifest_source: @manifest)
        directory = cell_directory(cell)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: CELL_CPUS,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                         test_image: true)
        served(directory, ->(serial) { BtDomain.checkpoints(points, serial: serial) }) do |checkpoints, line|
          qemu.run(platform: @machine.platform, accel: QemuCells::LOCAL_ACCELERATOR, cpus: CELL_CPUS, image: built.single,
                   memory_mib: @machine.memory_mib, directory: directory, line: line, checkpoints: checkpoints)
        end
      end

      # The app cell: the echo package (ImageApps::ECHO) packed as the card packs an
      # example and added to a medium of app_manifest, enabled; the harness plays the
      # firmware (MediumBoot.firmware_tree) and boots the medium's committed slot to the
      # command shell, where the echo's line and the serial row are checked
      # (BtDomain.app_checkpoints).
      def app_boot(cell, fiasco)
        directory = cell_directory(cell)
        package = ImageApps.packed(FileUtils.mkdir_p(File.join(directory, 'package')).first, example: ImageApps::ECHO,
                                                                                            root: @root, runner: @runner,
                                                                                            compiler: @compiler, linker: @linker).package
        apps = ImageApps.plan([package], enable: [APP_NAME])
        built, written = production(fiasco).build_medium(directory: File.join(directory, 'image'), manifest_source: @app_manifest,
                                                         apps: apps)
        medium = written.fresh(directory: directory)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        disks = [QemuPlan::Disk.new(path: medium)].freeze
        tree = MediumBoot.firmware_tree(runner: @runner, qemu: @qemu, machine: @machine, image: image, disks: disks,
                                        choice: choice, cpus: CELL_CPUS, directory: directory)
        boot = File.join(directory, 'boot')
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: CELL_CPUS,
                                                         manifest_source: @app_manifest, memory_mib: @machine.memory_mib)
        log = Qemu.serial_log(boot)
        served(directory, ->(serial) { BtDomain.app_checkpoints(points, log: log, serial: serial) }) do |checkpoints, line|
          qemu.run(platform: @machine.platform, accel: QemuCells::LOCAL_ACCELERATOR, cpus: CELL_CPUS, image: image,
                   memory_mib: @machine.memory_mib, directory: boot, dtb: tree, disks: disks, line: line,
                   checkpoints: checkpoints)
        end
      end

      def production(fiasco) = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                                   machine: @machine, fiasco: fiasco)

      def qemu = Qemu.new(root: @root, runner: @runner, program: @qemu)

      # The cell's owner-only directory under build/bt, emptied.
      def cell_directory(cell)
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/bt', cell))
        OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
      end

      # Bumble's controllers served for a boot's length, their log bumble.log in directory
      # beside the peer's, and the block given the checkpoints that points_for answers for
      # the serial row's lambda and the line to join to the first controller. Their deadline
      # outlasts QEMU's, the checkpoints' seconds and the serial row's, by their own wait to
      # listen and a minute for QEMU's start.
      def served(directory, points_for)
        Bumble.use(root: @root, runner: @runner) do |environment|
          serial = nil
          # serial is set below, once the controllers' ports are known, before any checkpoint runs.
          checkpoints = points_for.call(-> { serial.call })
          seconds = checkpoints.sum { |point| point.fetch(:seconds) + point.fetch(:verify_seconds, 0) } +
                    Controllers::LISTEN_SECONDS + 60
          Controllers.serve(environment, log: File.join(directory, 'bumble.log'), seconds: seconds,
                                         timeout_program: @runner.timeout_program) do |ports|
            serial = lambda do
              Serial.run(environment, root: @root, port: ports.peer, directory: directory, timeout_program: @runner.timeout_program)
            end
            yield checkpoints, QemuPlan::Line.new(port: ports.line)
          end
        end
      end
    end
  end
end
