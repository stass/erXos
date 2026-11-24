# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require_relative 'display_domain'
require_relative 'image_apps'
require_relative 'medium_boot'
require_relative 'screen_reference'
require_relative 'source_revision'

module Erx
  # The offline kiosk as an image package (docs/design-packaging.md, Verification): the
  # production image of the record's own machine (ProductionImage::Machine.development), with the board's own manifest, carries
  # examples/dashboard packed as the Raspberry Pi 4's card packs it
  # (ImageApps.packed_kiosk), enabled, so the package lies at apps/dashboard.app of the
  # slot's system partition and its `package` row binds its header's SHA-256. The harness
  # plays the firmware (MediumBoot.firmware_tree, the dump carrying the boot's virtio-gpu
  # and input devices) and boots the medium with a display under HVF. Once the command
  # shell is up:
  #
  # * the storage domain served the system tree (SERVED), the system admitted the
  #   package (ADMITTED), the app's session mounted /app (MOUNTED), and the dashboard
  #   logged the minute of the first screen it showed (SHOWN), at or past the build date,
  #   where the clock service started the clock, so the calendar it reads is the wall clock;
  # * the screen read through QMP equals the dashboard as the host's erx-lvgl draws it
  #   with every quote's first round failed for OFFLINE_REASON (DashboardScreen) at
  #   that minute or the next, since the guest's clock is not pinned and a minute may turn before the screen is read.
  #
  # The seeded fault, the altered cell, flips a bit of the package header's root_hash, the
  # root of the image's hash tree, and binds the package row to the altered header's
  # SHA-256, so admission takes it as the image's own and the build's file check
  # (AppPack.describe) never sees it; the session's /app mount then refuses the image
  # (UNVERIFIED), no /app is mounted and the dashboard shows nothing.
  #
  # The quotes cell (examples/dashboard/README.md, "The QEMU cell") boots the same package on a
  # test image whose trust store adds the root of an offline HTTPS fixture
  # (QuotesFixture, a test medium's roots: ProductionImage::MediumKind.test), with a network device on
  # restricted user networking whose one guest forward, for erx_quotes_table's address
  # and port 443, relays each connection to the fixture (QemuPlan::Relay). The fixture
  # answers sol's first request with a body too big for erx_quotes, then every pair
  # with its price, so the serial line shows `quotes: sol no_data -- too_big`, a bound
  # only httpc's erXos edit gives on the target, then every quote fresh at the
  # fixture's price. Seeded: a store that trusts another root than the fixture's
  # (Run#call's trusted false) must show every quote `no_data -- certificate`.
  #
  # The front cell (docs/design-display.md, Verification, "A front window") boots the same
  # package on a test image that adds FRONT_PROGRAM, a stand-in for Doom
  # (test/guest/programs/frontfill.c), to the domain release, under the development
  # manifest, whose display_root row grants root's session the display with front. Once
  # the dashboard is shown as in the first cell, the harness types FRONT_START at the
  # console's rc: the program opens /dev/draw, so its handler opens it a window on root's
  # front grant, which the single policy shows over the dashboard, and it fills the window
  # with a new color every frame. Two screenshots FRONT_GAP_SECONDS apart must each differ
  # from the dashboard's frame before the program and from its next minute's, and from
  # each other. Then rc's `kill %1` ends the program, and the screen must again be the
  # dashboard's frame from before it or, if the minute turned meanwhile, the next
  # minute's: the offline dashboard draws the same frame throughout a minute. Seeded:
  # root's row without front (Run#call's front false), under which the program's window
  # is never shown, the screen stays the dashboard's and the cell fails.
  module Kiosk
    NAME = 'dashboard'
    SERVED = /erx_storage_system: serving the system tree/n
    ADMITTED = /packages: admitted dashboard\r?\n/n
    MOUNTED = /erx_app: mounted \/app/n
    SHOWN = /erx_dashboard: shown ([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2})\r?\n/n
    # The mount's refusal of an image whose first block does not match its root hash:
    # erx_verity answers eio for the reader's first read, which erx_erofs reports.
    UNVERIFIED = /erx_ns: image: erofs: blocks 0\+1 failed to read/n
    # How long the altered cell watches after the refusal for a mount or a screen.
    SETTLE_SECONDS = 15
    # Why each quote's first fetch fails in the kiosk boot, which has no network device,
    # so the dashboard shows that reason's words beside every quote: the connect finds no
    # route, which erx_quotes_http names connect ("cannot connect").
    OFFLINE_REASON = :connect
    ALTERED = '-altered'
    QUOTES = '-quotes'
    # The guest's virtual network, covering erx_quotes_table's address, which the guest
    # forward takes, and the port its URLs name.
    QUOTES_NETWORK = '104.16.0.0/16'
    QUOTES_ADDRESS = '104.16.14.28'
    QUOTES_PORT = 443
    # The fixture's answers: sol's first too big, every other its price.
    QUOTES_ANSWERS = { 'sol' => %i[too_big body] }.freeze
    QUOTES_TOO_BIG = 'quotes: sol no_data -- too_big'
    QUOTE_LINE = /quotes: [^\r\n]*/n
    # How long the harness waits after the command shell for every quote's lines: the
    # first round, sol's retry after its failure and the TLS handshakes of each.
    QUOTES_SECONDS = 240
    # The fixture's source, which writes the test root and so is its receipt's source.
    FIXTURE = 'test/fixtures/quotes_fixture.rb'
    # The minute Run#call draws before the boots, to build and compile the renderer.
    WARM_MINUTE = [[1970, 1, 1], [0, 0, 0]].freeze
    # How long the harness waits after the command shell for the dashboard's line, and
    # for the altered package's refusal.
    SHOWN_SECONDS = 120
    REFUSED_SECONDS = 60
    # Each of the host's drawings at the shell, warm (Run#call draws once before the
    # boots, so the first boot's minute is not spent compiling the renderer).
    DRAW_SECONDS = 60
    FRONT = '-front'
    # The front cell's program and its source, which rc at the console starts as job 1 and
    # kills by that number; the program's line once it has drawn its first frame, and the
    # console's echo of the kill, which rc runs as the line ends.
    FRONT_PROGRAM = 'frontfill'
    FRONT_SOURCE = 'test/guest/programs/frontfill.c'
    FRONT_START = "#{FRONT_PROGRAM} &\r".freeze
    FRONT_DRAWING = /frontfill: drawing\r?\n/n
    FRONT_KILL = "kill %1\r"
    FRONT_KILLED = /kill %1\r*\n/n
    # The root row whose front parameter the seeded front cell takes out.
    FRONT_GRANT = 'facet display_root'
    # How far apart the program's two screenshots are; how long the harness waits for the
    # program's line, for the screen to leave the dashboard, and after the kill for the
    # dashboard again.
    FRONT_GAP_SECONDS = 1
    FRONT_LINE_SECONDS = 60
    FRONT_WAIT_SECONDS = 30
    module_function

    # The package at path with one bit of its header's root_hash flipped, written into
    # directory, as an ImageApps::Package whose sha256 is the altered header's.
    def altered(package, directory:)
      fields = AppPackage.codec.schema.types.fetch('erx_pkg_header').fields.to_h { |field| [field.name.to_s, field.offset] }
      bytes = File.binread(package.path).b
      header_length = bytes.byteslice(fields.fetch('header_length'), 4).unpack1('V')
      at = fields.fetch('root_hash')
      bytes.setbyte(at, bytes.getbyte(at) ^ 0x01)
      path = File.join(directory, File.basename(package.path))
      File.binwrite(path, bytes)
      ImageApps::Package.new(path: path, name: package.name, memory: package.memory, license: package.license, gatt: package.gatt,
                             sha256: Digest::SHA256.digest(bytes.byteslice(0, header_length)))
    end

    # The wall-clock minute the dashboard's SHOWN line names, last in log, and the count - 1
    # minutes after it, each as the [[year, month, day], [hour, minute, 0]] DashboardScreen
    # draws.
    def shown_minutes(log, count: 2)
      first = shown_time(log)
      Array.new(count) { |index| first + (60 * index) }.map { |time| [[time.year, time.month, time.day], [time.hour, time.min, 0]] }
    end

    # The name of the reference check_shown writes for the index-th minute shown_minutes names.
    def minute_name(index) = "#{NAME}-#{index}"

    # The wall-clock minute the dashboard's SHOWN line names, last in log, as a UTC Time.
    def shown_time(log)
      fields = log.scan(SHOWN).last
      raise Error, 'the dashboard logged no shown line' unless fields

      Time.utc(*fields.map { |field| Integer(field, 10) })
    end

    # Refuses a shown minute before the minute of build_date, the image's commit time: the
    # clock service starts a clock no device set at that date (docs/design-time.md, "The
    # approximate start"), so an earlier minute is a calendar that does not read the wall
    # clock.
    def check_build_date(log, build_date:)
      shown = shown_time(log)
      return if shown >= build_date - build_date.sec

      raise Error, "the dashboard showed #{shown.strftime('%F %R')}, before the build date " \
                   "#{build_date.strftime('%F %R')}"
    end

    # The checks of the package's boot once the dashboard logged SHOWN, against the serial
    # log at serial: its lines and its minute against build_date, then the screen against
    # the dashboard drawn at the shown minute or the next, since a minute may turn before
    # the screen is read, each written as a reference into directory with ahead more
    # minutes drawn after them, so a caller has the matched minute's successors too.
    # Answers the name of the reference the screen matched.
    def check_shown(serial:, socket:, directory:, draw:, build_date:, ahead: 0)
      log = DisplayDomain.await_log(serial, wait_seconds: SHOWN_SECONDS) { |text| text.match?(SHOWN) }
      { SERVED => 'the storage domain served no system tree', ADMITTED => 'the system did not admit the package',
        MOUNTED => "the app's session mounted no /app" }.each do |line, failure|
        raise Error, failure unless log.match?(line)
      end
      check_build_date(log, build_date: build_date)
      names = shown_minutes(log, count: 2 + ahead).each_with_index.map do |minute, index|
        minute_name(index).tap { |name| ScreenReference.write(directory, name, draw.call(minute)) }
      end
      DisplayDomain.await_screen(socket: socket, references: directory, names: names.take(2))
    end

    # The points of a cell that checks its boot at the command shell alone: shell, the
    # production checkpoints' last, verified by the block.
    def at_shell(shell, &check) = [shell.merge(verify: ->(_text) { check.call }).freeze]

    # The front cell's points from the command shell on, over the serial log at serial,
    # the QMP socket and the cell's directory. At the shell: the dashboard as check_shown
    # finds it, with the minute after the one it matched drawn, then FRONT_START typed. At
    # the program's first frame: its two screenshots (check_front) against the reference
    # the dashboard matched and its next minute's, then FRONT_KILL typed. At the kill's
    # echo: the screen is one of those two again, within FRONT_WAIT_SECONDS. dashboard,
    # those two references' names, is set by the first verify and read by the later two,
    # which the checkpoints run after it.
    def front_points(shell, serial:, socket:, directory:, draw:, build_date:)
      dashboard = nil
      shown = lambda do |_text|
        before = check_shown(serial: serial, socket: socket, directory: directory, draw: draw, build_date: build_date,
                             ahead: 1)
        index = Array.new(2) { |each| minute_name(each) }.index(before)
        dashboard = [before, minute_name(index + 1)]
      end
      drawing = ->(_text) { check_front(socket: socket, references: directory, dashboard: dashboard) }
      killed = lambda do |_text|
        DisplayDomain.await_screen(socket: socket, references: directory, names: dashboard, wait_seconds: FRONT_WAIT_SECONDS)
      end
      [shell.merge(verify: shown, type: FRONT_START).freeze,
       { name: 'front-drawing', pattern: FRONT_DRAWING, verify: drawing, type: FRONT_KILL,
         seconds: FRONT_LINE_SECONDS + FRONT_WAIT_SECONDS + FRONT_GAP_SECONDS }.freeze,
       { name: 'front-killed', pattern: FRONT_KILLED, verify: killed, seconds: FRONT_LINE_SECONDS + FRONT_WAIT_SECONDS }.freeze]
    end

    # The checks of the front program's screen through the QMP socket: a screenshot that
    # is none of the dashboard references in references, within FRONT_WAIT_SECONDS, and a
    # second one FRONT_GAP_SECONDS later that is none of them either and differs from the
    # first, so the program's window is shown and its frames reach the screen. Each
    # screenshot is kept in the socket's directory as front-0.ppm and front-1.ppm.
    def check_front(socket:, references:, dashboard:)
      wanted = dashboard.map { |name| ScreenReference.load(references, name) }
      shown = ->(image) { wanted.any? { |reference| ScreenReference.matches?(image, reference) } }
      client = Qmp.connect(socket)
      screen = ->(index) { client.screendump_image(File.join(File.dirname(socket), "front-#{index}.ppm")) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FRONT_WAIT_SECONDS
      first = screen.call(0)
      while shown.call(first)
        raise Error, "the program's window was not shown: the screen stayed the dashboard's for #{FRONT_WAIT_SECONDS} s" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep DisplayDomain::POLL_SECONDS
        first = screen.call(0)
      end
      sleep FRONT_GAP_SECONDS
      second = screen.call(1)
      raise Error, "the screen was the dashboard's again #{FRONT_GAP_SECONDS} s after the program's frame" if shown.call(second)
      raise Error, "the program's screen did not change in #{FRONT_GAP_SECONDS} s (digest #{first.digest})" if
        second.digest == first.digest
    ensure
      client&.close
    end

    # The checks of the quotes cell's boot once the command shell is up: the serial log at
    # serial shows each of lines (QuotesFixture.fresh_lines and QUOTES_TOO_BIG) within
    # QUOTES_SECONDS; a failure names the lines missing and the last quotes lines seen.
    def check_quotes(serial:, lines:)
      log = DisplayDomain.await_log(serial, wait_seconds: QUOTES_SECONDS) { |text| lines.all? { |line| text.include?(line) } }
      missing = lines.reject { |line| log.include?(line) }
      return if missing.empty?

      raise Error, "the quotes showed no #{missing.join('; ')}; last: #{log.scan(QUOTE_LINE).last(6).join('; ')}"
    end

    # The checks of the altered package's boot: admitted by its row, refused at the mount,
    # and nothing of the app ran. An altered image mounted or shown is the failure the cell
    # exists for, a hash check that let a changed image through, and its message says so
    # whenever the log shows it, before any other.
    def check_altered(serial:)
      log = DisplayDomain.await_log(serial, wait_seconds: REFUSED_SECONDS) { |text| text.match?(UNVERIFIED) }
      if log.match?(UNVERIFIED)
        log = DisplayDomain.await_log(serial, wait_seconds: SETTLE_SECONDS) { |text| text.match?(MOUNTED) || text.match?(SHOWN) }
      end
      raise Error, "the altered image's hash check let it through: its session mounted /app" if log.match?(MOUNTED)
      raise Error, "the altered image's hash check let it through: it showed the dashboard" if log.match?(SHOWN)
      raise Error, 'the system did not admit the altered package by its row' unless log.match?(ADMITTED)
      raise Error, 'the altered image was not refused at its mount' unless log.match?(UNVERIFIED)
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        # The kiosk boots the board's own manifest, so its machine is the record's own.
        @machine = ProductionImage::Machine.development(platform)
        @manifest = platform.manifest_source(@root)
        @notes = []
      end

      # Why each failed cell failed.
      def notes = @notes.dup.freeze

      # Packs the package once (ImageApps.packed_kiosk), then an image of it and one of its
      # altered copy, and boots each at one CPU, the altered cell whatever the first found,
      # then the quotes cell and the front cell. Returns { "hvf-1cpu" => 'passed',
      # "hvf-1cpu-altered" => 'passed', "hvf-1cpu-quotes" => 'passed', "hvf-1cpu-front" =>
      # 'passed' }, a cell that failed 'failed' with its reason in notes. trusted false seeds
      # the quotes cell: its store trusts another root; front false seeds the front cell:
      # root's display grant has no front.
      def call(jobs: 4, build: true, trusted: true, front: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        work = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/kiosk'))
        kiosk_directory, altered_directory = %w[kiosk altered].map { |name| FileUtils.mkdir_p(File.join(work, name)).first }
        kiosk = ImageApps.packed_kiosk(kiosk_directory, root: @root, runner: @runner, compiler: @compiler, linker: @linker)
        package = kiosk.package
        draw = drawing(app: kiosk.app, sdk: kiosk.sdk)
        draw.call(WARM_MINUTE)
        shown = { 'hvf-1cpu' => package, "hvf-1cpu#{ALTERED}" => Kiosk.altered(package, directory: altered_directory) }
                .to_h { |cell, packed| [cell, status(cell) { shown_boot(cell, packed, fiasco, work, draw: draw) }] }
        quotes, fronted = [QUOTES, FRONT].map { |suffix| "hvf-1cpu#{suffix}" }
        shown.merge(quotes => status(quotes) { quotes_boot(quotes, package, fiasco, work, trusted: trusted) },
                    fronted => status(fronted) { front_boot(fronted, package, fiasco, work, draw: draw, front: front) })
      end

      private

      # 'passed' once the cell's block returns; 'failed' when it raises, its reason noted.
      def status(cell)
        yield
        'passed'
      rescue Error => e
        @notes << "#{cell}: #{e.message}"
        'failed'
      end

      # The dashboard's boot: its screen and its minute against the build date, or for the
      # altered cell its refusal.
      def shown_boot(cell, package, fiasco, work, draw:)
        build_date = self.build_date
        boot(cell, package, fiasco, work) do |shell, serial, socket, directory|
          Kiosk.at_shell(shell) do
            if cell.end_with?(ALTERED)
              Kiosk.check_altered(serial: serial)
            else
              Kiosk.check_shown(serial: serial, socket: socket, directory: directory, draw: draw, build_date: build_date)
            end
          end
        end
      end

      # The image's commit time, which the dashboard's minute must not precede.
      def build_date
        revision = SourceRevision.read(root: @root, runner: @runner)
        raise Error, 'the kiosk cell needs a git checkout: its clock check reads the build date' unless revision

        revision.committed_at
      end

      # The front cell's boot, its image adding FRONT_PROGRAM (front_program), its points
      # Kiosk.front_points; front false boots it under root's display grant without front.
      def front_boot(cell, package, fiasco, work, draw:, front:)
        build_date = self.build_date
        manifest = front ? @manifest : Manifest::Edit.without_parameter(@manifest, record: FRONT_GRANT, key: 'front')
        kind = ProductionImage::MediumKind.test(test_programs: front_program(fiasco))
        boot(cell, package, fiasco, work, manifest: manifest, kind: kind) do |shell, serial, socket, directory|
          Kiosk.front_points(shell, serial: serial, socket: socket, directory: directory, draw: draw, build_date: build_date)
        end
      end

      # FRONT_PROGRAM linked over musl's libc.a, the one the runtime images link, as a
      # release file of the session's, as the display domain suite adds its probe
      # (DisplayDomain::Run#probe).
      def front_program(fiasco)
        Generated.ensure(root: @root)
        libc = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco,
                                 platform: @machine.platform).build.libc
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                                fiasco: fiasco)
        program = native.build_task_receipted(name: FRONT_PROGRAM, sources: [*NativeRoot::PROGRAM, FRONT_SOURCE],
                                              directory: File.join(@root, 'build/kiosk', FRONT_PROGRAM),
                                              archives: [libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)])
        codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
        ProductionImage::Added.new(entries: [ProductionImage.program_entry(FRONT_PROGRAM, program, codec: codec)].freeze,
                                   inputs: program.fetch(:inputs), imports: {}.freeze)
      end

      # The quotes cell's boot against the fixture, its root in the image's store unless
      # trusted is false, when the store takes another root in its place. The fixture is
      # loaded here, when the cell runs, so loading the suite loads no test code.
      def quotes_boot(cell, package, fiasco, work, trusted:)
        require_relative File.join('../../..', FIXTURE)
        roots = FileUtils.mkdir_p(File.join(work, "#{cell}-roots")).first
        context = QuotesFixture.chain(File.join(roots, 'fixture.pem'))
        QuotesFixture.chain(File.join(roots, 'other.pem')) unless trusted
        server = QuotesFixture::Server.new(context: context, answers: QUOTES_ANSWERS)
        begin
          relay = QemuPlan::Relay.new(network: QUOTES_NETWORK, address: QUOTES_ADDRESS, port: QUOTES_PORT, relay_port: server.start.port)
          root = TrustStore::TestRoot.new(path: File.join(roots, trusted ? 'fixture.pem' : 'other.pem'), source: File.join(@root, FIXTURE))
          kind = ProductionImage::MediumKind.test(test_roots: [root])
          boot(cell, package, fiasco, work, kind: kind, nic: relay) do |shell, serial, _socket, _directory|
            Kiosk.at_shell(shell) do
              Kiosk.check_quotes(serial: serial, lines: trusted ? [QUOTES_TOO_BIG, *QuotesFixture.fresh_lines] : QuotesFixture.refused_lines)
            end
          end
        rescue Error => e
          raise Error, "#{e.message} (fixture requests: #{server.requests})"
        ensure
          server.stop
        end
      end

      # Boots package on the image's release medium at one CPU under HVF, built from
      # manifest, with nic when given, as a medium of kind (ProductionImage::MediumKind):
      # the development medium, or a test medium whose trust store adds its roots or whose
      # domain release adds its programs. The block is given the command shell's
      # checkpoint, its wait raised for the longest cell's checks, with the serial log's
      # path, the QMP socket and the cell's directory, and answers the points from the
      # shell on.
      def boot(cell, package, fiasco, work, manifest: @manifest, kind: ProductionImage::MediumKind.development, nic: nil, &points)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(work, cell))
        production = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                         fiasco: fiasco)
        apps = ImageApps.plan([package], enable: [NAME], signers: [], local: false)
        built, written = production.build_medium(directory: File.join(directory, 'image'), manifest_source: manifest, apps: apps,
                                                 kind: kind)
        medium = written.fresh(directory: directory)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        socket = File.join(directory, 'qmp.sock')
        display = QemuPlan::Display.new(qmp_socket: socket)
        disks = [QemuPlan::Disk.new(path: medium)]
        tree = MediumBoot.firmware_tree(runner: @runner, qemu: @qemu, machine: @machine, image: image, disks: disks,
                                        display: display, choice: choice, cpus: 1, directory: directory)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: 'hvf', cpus: 1, image: image, memory_mib: @machine.memory_mib,
                 directory: File.join(directory, 'boot'), display: display, dtb: tree, disks: disks, nic: nic,
                 checkpoints: checkpoints(built, choice, manifest: manifest) { |shell| points.call(shell, File.join(directory, 'boot', 'serial.log'), socket, directory) })
      end

      # The production checkpoints of manifest, a test image's when built is one, with the
      # boot value's after the image's identity, and from the command shell on the points
      # the block answers for the shell's checkpoint, its wait raised for the longest cell's
      # checks there.
      def checkpoints(built, choice, manifest:)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                  manifest_source: manifest, memory_mib: @machine.memory_mib,
                                                  test_image: built.test_code)
        at = points.index { |point| point.fetch(:name) == 'image-identity' }
        raise Error, 'the production checkpoints name no image-identity' unless at
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

        shell = points.last
        waits = [SHOWN_SECONDS + (DRAW_SECONDS * 3) + DisplayDomain::WAIT_SECONDS,
                 REFUSED_SECONDS + SETTLE_SECONDS, QUOTES_SECONDS]
        [*points[0..at], MediumBoot.boot_value_checkpoint(choice), *points[(at + 1)...-1],
         *yield(shell.merge(seconds: shell.fetch(:seconds) + waits.max).freeze)]
      end

      # The dashboard at app as a function from a minute to the picture the host's
      # erx-lvgl draws of it over sdk, on the SDK's emulator (DashboardScreen). The fixture
      # is loaded here, when the cell runs, so loading the suite loads no test code.
      def drawing(app:, sdk:)
        require_relative '../../../test/fixtures/dashboard_screen'
        ->(minute) { DashboardScreen.picture(minute, app: app, sdk: sdk, runner: @runner, reason: OFFLINE_REASON) }
      end
    end
  end
end
