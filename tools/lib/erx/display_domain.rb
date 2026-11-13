# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'manifest_text'
require_relative 'ppm'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'qmp'
require_relative 'release_files'
require_relative 'runner'
require_relative 'screen_reference'

module Erx
  # The display domain and a client's window on QEMU virt (docs/design-display.md,
  # Verification, "Drivers", and "Erlang clients"): a test image (it carries the client's
  # test-only application) boots on MediumBoot's machine with a manifest of the suite's
  # own, the site manifest with a display domain that holds the platform's display unit
  # (manifest), a virtio-gpu attached and QMP on an owner-only socket in the run's
  # directory. The development manifest places no display unit (TODO.md, the display
  # domain's rows), so this boot is the suite's alone. The virtio-gpu driver brings the
  # device up and erx_screen fills the empty layout's background. The start row client
  # names the display, so once its server has settled the row's keeper starts the
  # display's session, whose release (BOOT) runs erx_pattern_test: it opens a window
  # with erx_win:open/2, which the single policy places over the whole screen, fills it
  # with erx_pattern_test:pattern/0 and presents it. Once the command shell is up, the
  # harness reads the screen through QMP's screendump until its decoded pixels equal the
  # reference picture's, the pattern over the whole display
  # (test/display/reference/display-pattern.sha256), or the wait runs out, and the cell
  # fails naming both digests. Then the driver's lines in the serial log must be one
  # bring-up and nothing else (check_driver_lines), so a driver that failed a flush and
  # was restarted before the picture came does not pass.
  #
  # A driver that sets no scanout leaves QEMU's own picture of an inactive display; a
  # frame never flushed leaves the device's resource black; a session that never starts,
  # or a window never presented, leaves the background; a wrong colour or channel order,
  # in the client, the window's buffer or the driver, gives another digest. Each fails
  # the cell. A domain that ends after the picture came is not seen: QEMU keeps the last
  # scanout.
  module DisplayDomain
    REFERENCES = 'test/display/reference'
    PATTERN = 'display-pattern'
    # The boot script of the client's session template: the client release's applications
    # (ReleaseFiles::RELEASE_SCRIPTS, client), the command shell and erx_session, which
    # the template's -eval starts, and the test-only client, erx_pattern_test.
    CLIENT_SCRIPT = ReleaseFiles::RELEASE_SCRIPTS.fetch('client')
    CLIENT_APPLICATIONS = [*CLIENT_SCRIPT, 'erx_shell', 'erx_session', 'erx_pattern_test'].freeze
    BOOT = ReleaseFiles.domain_boot('pattern', applications: CLIENT_APPLICATIONS, test: true)
    # The keyboard and tablet stay off the display's register page: the display domain's
    # window is the gpu's whole page, and the domain library checks a page's sharing only
    # among the platform record's devices (TODO.md, security residuals), so the input
    # devices sit on the page of the spare unit, which this manifest does not place.
    DISPLAY_BUSES = { gpu: QemuPlan::DISPLAY_TRANSPORTS.fetch(:gpu), keyboard: 6, tablet: 5 }.freeze
    # How long the harness reads the screen after the shell's banner before it fails, and
    # how often.
    WAIT_SECONDS = 90
    POLL_SECONDS = 0.5
    # The display domain's own budget. The gpu's DMA memory is not in it: the domain
    # library charges a device's memory to the system's budget (dom_life.c,
    # ERX_DOM_STEP_CONTIGUOUS), so root_memory grows by it (manifest).
    MEMORY = 24 << 20
    UNIT_KEY = 'display'
    # The display's client (docs/design-display.md, "A display's session"): principal
    # client, whose session template is granted the display's window tree, service
    # screen, with a pixel area of PIXELS bytes, enough for a 1920 by 1080 screen of
    # 32-bit pixels (8,294,400 bytes). Its domains quota, CLIENT_SESSIONS, is how many
    # sessions of the template can live at once, each a grant the display pays for.
    PIXELS = 8 << 20
    CLIENT_SESSIONS = 1
    LANE = 4096
    # The display domain's outer budget: MediumBoot's, and property 18's sum on top
    # (docs/design-system.md, "The manifest", property 18): for each of the client's
    # sessions, its pixel area and the side the display reads for it, its own lane.
    OUTER = MediumBoot::DOMAIN_OUTER + CLIENT_SESSIONS * (PIXELS + LANE)
    # The client's principal holds one session of the site manifest's session limits,
    # its memory and its outer budget, on the users share.
    CLIENT_MEMORY = (36 << 20) + MediumBoot::DOMAIN_OUTER
    # The display domain: MediumBoot's eighth of a CPU, which the site manifest's free
    # 250 mcpu of the system share's reserve holds, and the display boot script on the
    # interpreter, as a node over the erx carrier, with no restart, in a runtime limits
    # profile of its own: storage's figures, with no /tmp. It serves screen, of the
    # windows interface, with its display record, and has room for a connection to each
    # of the client's sessions.
    ROW = MediumBoot::EIGHTH_SHARE +
          "runtime_limits display\n  max_frame 131072\n  max_message_heap 131072\n  funnel_depth 64\n" \
          "  exports 256\n  tmp 0\n  overlay 0\n  atoms 16384\n  foreign_atoms 1024\n  processes 1024\n" +
          "limits display\n  memory #{MEMORY}\n  outer #{OUTER}\n  grant @share.eighth\n" \
          "  spaces none\n  lane #{LANE}\n  connections #{CLIENT_SESSIONS}\n  crash 0\n  flags none\n" \
          "  runtime_limits @runtime_limits.display\n  peer_held 4096\n  peer_held_total 4096\n" \
          "domain display\n  principal @principal.system\n  limits @limits.display\n  kind service\n  flags none\n" \
          "  runtime @artifact.#{ProductionImage::DOMAIN_RUNTIME_ARTIFACT}\n" \
          "  release @artifact.#{ProductionImage.domain_boot('display').name}\n" \
          "  restarts 0\n  restart_period_s 5\n  args \"#{MediumBoot::UP_ARGS.join(' ')}\"\n" \
          "service screen\n  server @domain.display\n  interface windows\n" \
          "display screen\n  policy single\n  idle_dim_s 0\n  idle_off_s 0\n"
    # The client: its principal and session template, whose release is BOOT's, the
    # session's grant of screen, and its start row, enabled, which names screen as the
    # session's display, so the session the row keeps is the display's.
    CLIENT = "principal client\n  memory #{CLIENT_MEMORY}\n  grant @share.users\n  domains #{CLIENT_SESSIONS}\n" \
             "  names 1\n  default_limits @limits.native\n  ceiling_limits @limits.native\n" \
             "session client\n  limits @limits.session\n  runtime @artifact.emu\n  release @artifact.#{BOOT.name}\n" \
             "  args \"-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx " \
             "-eval ok=application:start(erx_session)\"\n" \
             "facet screen\n  grantee @session.client\n  service @service.screen\n  operations none\n" \
             "  max_request 131072\n  in_flight 16\n  reductions 100000\n  period_ns 1000000000\n" \
             "  max_heap_size 262144\n  parameter pixels #{PIXELS}\n" \
             "start client\n  enable YES\n  display @service.screen\n"
    UNIT = "unit #{UNIT_KEY}\n  placement \"#{UNIT_KEY}\"\n  holder @domain.display\n"

    module_function

    # The manifest: the site manifest (MediumBoot.manifest) with ROW and room for its one
    # domain, whose outer budget is OUTER, not MediumBoot's, the display unit placed on
    # it, CLIENT, root_memory grown by the unit's DMA memory as the platform record gives
    # it and by the client principal's memory, and max_domains and max_connections each
    # by the client's sessions: the principals' domains quotas sum within max_domains, and
    # each session has its connection to the display.
    def manifest(source, platform:)
      text = MediumBoot.manifest(source, row: ROW, domains: 1, domain_memory: MEMORY + OUTER - MediumBoot::DOMAIN_OUTER)
      ManifestText.grow(text, { %w[machine root_memory] => dma_memory(platform) + CLIENT_MEMORY,
                                %w[machine max_domains] => CLIENT_SESSIONS,
                                %w[machine max_connections] => CLIENT_SESSIONS }) + UNIT + CLIENT
    end

    # The DMA memory of the platform's display unit's devices, in bytes.
    def dma_memory(platform)
      unit = platform.record.fetch('units').find { |row| row.fetch('key') == UNIT_KEY }
      raise Error, "the #{platform.name} platform has no #{UNIT_KEY} unit" unless unit

      unit.fetch('devices').sum { |device| device.fetch('dma_memory') }
    end

    # The screen read through the QMP socket until it equals the reference called name in
    # references, or until wait_seconds have passed, which raises the last mismatch.
    def await_screen(socket:, references:, name:, wait_seconds: WAIT_SECONDS)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      client = Qmp.connect(socket)
      dump = File.join(File.dirname(socket), 'screen.ppm')
      loop do
        image = client.screendump_image(dump)
        begin
          return ScreenReference.check(image, directory: references, name: name)
        rescue ScreenReference::Mismatch
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
        sleep POLL_SECONDS
      end
    ensure
      client&.close
    end

    # The driver's lines of a boot's serial log: one bring-up, "erx_fb: scanout 0 at WxH",
    # and no other, or Error naming them.
    DRIVER_LINE = /erx_fb: [^\r\n]*/n
    BRING_UP = /\Aerx_fb: scanout 0 at [0-9]+x[0-9]+\z/n
    def check_driver_lines(log)
      lines = log.b.scan(DRIVER_LINE)
      return if lines.size == 1 && BRING_UP.match?(lines.first)

      raise Error, "the display driver logged #{lines.size} lines, not one bring-up: #{lines.first(4).inspect}"
    end

    # The client's outcome lines of a boot's serial log (erx_pattern_test:show/0): one
    # "presented" and no other, or Error naming them, so a client that failed, or whose
    # session was started again before the picture came, does not pass, and a failing
    # cell says what the client reported.
    CLIENT_LINE = /erx_pattern_test: (?!started)[^\r\n]*/n
    PRESENTED = 'erx_pattern_test: presented'
    def check_client_lines(log)
      lines = log.b.scan(CLIENT_LINE)
      return if lines == [PRESENTED]

      raise Error, "the client logged #{lines.size} outcomes, not one presented: #{lines.first(4).inspect}"
    end

    # The serial log at serial once it holds a client's outcome line, or once wait_seconds
    # have passed: the client logs its outcome after the display answers its present,
    # which may reach the log after the screen shows the picture.
    CLIENT_WAIT_SECONDS = 15
    def await_client_line(serial, wait_seconds: CLIENT_WAIT_SECONDS)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      loop do
        log = File.binread(serial)
        return log if log.b.match?(CLIENT_LINE) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep POLL_SECONDS
      end
    end

    # The production checkpoints to the command shell, whose banner starts the screen's
    # reads, then the driver's and the client's lines of the serial log at serial. points
    # must end at the command shell.
    def checkpoints(points, socket:, references:, serial:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell = points.last
      screen = lambda do |_text|
        await_screen(socket: socket, references: references, name: PATTERN)
        log = await_client_line(serial)
        check_driver_lines(log)
        check_client_lines(log)
      end
      [*points[0...-1], shell.merge(seconds: shell.fetch(:seconds) + WAIT_SECONDS + CLIENT_WAIT_SECONDS + 15,
                                           verify: screen).freeze].freeze
    end

    # Boots the image under HVF at each CPU count, where placement puts each cell.
    # Returns { "<accel>-<n>cpu" => 'passed' }; any disagreement raises.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        @manifest = DisplayDomain.manifest(platform.site_manifest_source(@root), platform: platform)
      end

      # Packs the test image, which carries the client's boot script (BOOT), once, then boots
      # it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/display-domain/image'))
        nothing = ProductionImage::Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
        built = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                    fiasco: fiasco)
                               .build_test_image(directory: directory, added: nothing, machine: @machine, domains: [BOOT],
                                                 manifest_source: @manifest)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", show(accel, count, remote, built)]
        end
      end

      private

      # One boot to the command shell, then the screen's reads. The run's directory is made
      # afresh and owner-only here, so the QMP socket QEMU creates in it and the dumps beside
      # it are the harness's alone. A remote placement reaches Qemu#run, which refuses a
      # boot with a display there.
      def show(accel, count, remote, built)
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/display-domain', "#{accel}-#{count}cpu"))
        boot = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
        socket = File.join(boot, 'qmp.sock')
        display = QemuPlan::Display.new(qmp_socket: socket, **DISPLAY_BUSES)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                         test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, directory: boot, display: display,
                 checkpoints: DisplayDomain.checkpoints(points, socket: socket, references: File.join(@root, REFERENCES),
                                                        serial: File.join(boot, 'serial.log')))
        'passed'
      end
    end
  end
end
