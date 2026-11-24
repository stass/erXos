# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'abi_theme'
require_relative 'bench_measurement'
require_relative 'bench_suite'
require_relative 'bl31'
require_relative 'boot_partition'
require_relative 'board_tree'
require_relative 'generated_abi'
require_relative 'manifest_frontend'
require_relative 'native_bench'
require_relative 'native_root'
require_relative 'output_directory'
require_relative 'pi_medium'
require_relative 'platform'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qmp'
require_relative 'raspi4b_firmware_fb'
require_relative 'runner'
require_relative 'session_domain'
require_relative 'splash_mark'

module Erx
  # The serial shell on QEMU's raspi4b model (docs/plan.md, 1b-I, "QEMU's raspi4b, under
  # TCG, proves stage (a) first"): the Raspberry Pi 4's development image, its bootstrap, BL31
  # and the model's device tree, booted through QEMU's loader (QemuPlan::Machine#loads) at
  # the model's four CPUs.
  #
  # tcg-4cpu: the boot reaches the development banner and the release with one scheduler
  # per CPU, four; root's session takes the mini UART and its command shell starts the Erlang
  # shell, where the person types a sum, a line with a mistake rubbed out, a listing of /data
  # (eio, since no card is on the bus to serve it), an output longer than the mini UART's FIFOs, and
  # a debug log record whose tab and escape the console writes as text; then Ctrl-G's menu
  # gives the system's command shell, whose Erlang shell halts the machine, and BL31's reset
  # ends QEMU under -no-reboot. The model runs no firmware, so this boot's CPU 0 first runs the
  # harness's stand-in for the firmware's framebuffer setup (Raspi4bFirmwareFb), which asks the
  # model's mailbox for a 640x480 screen and writes the answer into the tree's
  # simple-framebuffer node. Once the system's command shell is up, the screen read through QMP
  # must be the splash over the background, since no window ever presents, so at least three
  # quarters of its pixels are the background, the theme's desktop colour in the display's
  # palette, and the splash's mark is drawn in the theme's text colour (await_splash). The
  # serial log must then hold the root's framebuffer line (ROOT_LINE) and each configured
  # domain's line (CONFIGURED_LINES), the display domain's being its driver's framebuffer line,
  # exactly once with no restart of that domain: a driver that ended the domain at each start
  # would log its line again at each restart.
  #
  # Seeded by hand: the stand-in's node naming x8b8g8r8 while the model shows x8r8g8b8 keeps
  # both lines (they name the format the tree gives) but swaps the screen's red and blue, and
  # the run fails at system-shell.
  #
  # tcg-cpu-removed, a seeded fault: the same image on the model's tree with one CPU's node
  # removed reaches the release with three schedulers, so the four of tcg-4cpu are the
  # tree's CPUs and not a constant.
  #
  # tcg-sd-card: the same image with the card it was packed with on EMMC2's bus
  # (QemuPlan::Machine#card_bus), a copy the guest writes, padded to the model's size
  # (QemuPlan.card_copy), since the card ends at its last partition. The storage domain's SD device
  # process (erx_blk_sd, docs/design-storage.md, "The SD host controller") identifies the
  # card only through interrupts of its line, 158, so its line in the kernel log, which
  # names the card's sectors, shows the line fires and the card answered; the block
  # service's partition table and littlefs's mount show reads of many blocks. Before
  # that, root's session writes DATA_FILE under /data, its data facet, and reads it back
  # (DATA_PROBE); after QEMU exits the harness finds the file's bytes in the card file's
  # data partition (check_card_data!), so /data is the card's littlefs volume. The system
  # domain's Erlang shell then probes the storage domain over erpc, as the harness and not
  # as a client (CARD_PROBE): it writes two blocks through erx_blk at PROBE_SECTOR, which
  # no partition holds, and reads them back; after QEMU exits the harness finds the same
  # bytes at that sector of the card's file (check_card_write!).
  #
  # tcg-bench-set: the native nullcall bench's board set (NativeBench::BoardSets,
  # docs/design-bench.md, "The bench image's boot set"), booted from its own kernel8.img
  # and bl31.bin with an entry's command line in the tree's /chosen/bootargs
  # (bench_set_boot). Seeded by hand: the set's kernel8.img made with the main build's
  # first stage shows no banner before the boot's deadline, and a root built with
  # ERX_BENCH_SEED_ASKED_OFF ends with erx: end off, which NativeBench.check_end refuses.
  #
  # Seeded by hand, over a card file: check_card_data! refuses the card as packed, whose
  # data partition holds a fresh volume, so the check reads the bytes from the card and
  # not from anywhere else. A manifest that grants no data facet fails earlier, at
  # data-written: root's /data is then its release's read-only directory, and the write
  # answers erofs.
  #
  # Seeded by hand, in an image of its own: a device process that skips the wait for the
  # buffer's read-ready interrupt before reading a block's words fails identification at
  # the SCR, and the run fails at sd-identified.
  #
  # The other seeded fault the plan names, a driver that drops one received byte, needs an
  # image of its own and is run by hand: a drain that drops `+` makes the shell echo `11.`
  # and answer 11, and the run fails at sum-echo.
  class Raspi4bShell
    PLATFORM = 'raspi4b'
    CPUS = 4
    CELLS = %w[tcg-4cpu tcg-cpu-removed tcg-sd-card tcg-bench-set].freeze
    # The board set tcg-bench-set boots (docs/design-bench.md, "Seeded faults", the
    # board's set), and the name its command line gives the boot.
    BENCH_SET = 'nullcall'
    BENCH_NAME = '0123456789abcdef' * 2
    # The CPU node the seeded tree loses, the last of the model's four.
    REMOVED_CPU = '/cpus/cpu@3'
    # Under TCG a four-CPU boot takes minutes to reach the release.
    RELEASE_SECONDS = 900
    STEP_SECONDS = 180
    SYSTEM_SHELL_KEY = 's'
    HALT = "erlang:halt().\r"
    # The Pi's manifest grants root's session the data facet, mounted at /data. tcg-4cpu
    # boots with no card, so the storage domain has no volume and provides no mint for
    # data, and the session's facet answers eio, never an empty directory
    # (docs/design-files.md, "A facet's mount").
    DATA_LISTING = "file:list_dir(\"/data\").\r"
    # The file root's session writes on the card's volume, and its bytes, which nothing
    # else on the card holds.
    DATA_FILE = '/data/sd-probe'
    DATA_BYTES = 'erXos /data probe: a file on the SD card\'s littlefs volume.'.b.freeze
    # Typed at root's Erlang shell in tcg-sd-card: writes DATA_FILE and reads it back,
    # {ok,true}. A session takes the console only once its files grants have settled
    # (docs/design-system.md, "A session takes the console"), so the first write should
    # succeed; the retry on eio, once a second up to DATA_TRIES times, is defensive only,
    # and any other answer, erofs where no facet is mounted, ends the try.
    DATA_TRIES = 150
    DATA_PROBE = "begin B = <<\"#{DATA_BYTES}\">>, " \
                 "W = fun Try(0) -> timeout; Try(N) -> case file:write_file(\"#{DATA_FILE}\", B) of " \
                 '{error, eio} -> timer:sleep(1000), Try(N - 1); Other -> Other end end, ' \
                 "R = W(#{DATA_TRIES}), {R, file:read_file(\"#{DATA_FILE}\") =:= {ok, B}} end.\r"
    STUB_DIRECTORY = 'build/raspi4b-stub'
    CODEC = ABI::Generated::CODEC
    SECTOR_BYTES = CODEC.constant('mbr_sector_size')
    # The first sector after the boot-selection record's partition, in the 3 MiB before
    # boot A that no partition of abi/medium.txt holds, so the probe's write changes nothing
    # the boot or a file system reads.
    PROBE_SECTOR = CODEC.constant('medium_record_start') + CODEC.constant('medium_record_sectors')
    # Two blocks, so the write and the read back are multi-block transfers.
    PROBE_BYTES = ('erXos SD probe. ' * (2 * 512 / 16)).b.freeze
    # Typed at the system domain's Erlang shell: in the storage domain, the probe's write
    # at PROBE_SECTOR, a flush, and whether reading the two blocks back gives the same
    # bytes: {ok,ok,true}.
    CARD_PROBE = 'begin [N] = [Nd || #{name := {erx_ident, <<"storage">>}, node := Nd} <- ' \
                 'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                 "B = binary:copy(<<\"#{PROBE_BYTES[0, 16]}\">>, #{PROBE_BYTES.bytesize / 16}), " \
                 "erpc:call(N, fun() -> W = erx_blk:write(#{PROBE_SECTOR}, B), F = erx_blk:flush(), " \
                 "{ok, R} = erx_blk:read(#{PROBE_SECTOR}, #{PROBE_BYTES.bytesize / SECTOR_BYTES}), " \
                 "{W, F, R =:= B} end, 30000) end.\r"
    # What the system's command shell types to find a storage line in the kernel log, and
    # the pattern of the storage domain's record holding that line. The storage domain
    # may log the record after the query has run and found nothing (under TCG the boot is
    # slow, and slower while another domain restarts); the console, which writes the
    # kernel log's records live, then writes it after the shell's prompt. So the pattern
    # matches the record wherever it starts on its line, and each step takes it from
    # dmesg's answer or the console's live line, whichever comes first; a second copy is
    # tested against the next step's pattern and ignored. The typed query never matches:
    # its echo holds no record header.
    def self.kernel_log(text) = "dmesg | grep '#{text}'\r"
    def self.kernel_log_line(source) = /#[0-9]+ [0-9]+\.[0-9]{6} debug space [0-9]+: #{source}\r*\n\z/n
    CARD_LINE = 'erx_blk: SD card, '
    CARD_IDENTIFIED = kernel_log_line("#{Regexp.escape(CARD_LINE)}(?:standard|high) capacity, ([0-9]+) sectors, " \
                                      '4-bit bus at [0-9]+ Hz')
    PARTITIONS = 'erx_blk_service: partition table admitted'
    PARTITIONS_ADMITTED = kernel_log_line("#{Regexp.escape(PARTITIONS)}; [0-9]+ windows")
    MOUNTED = 'erx_lfs: volume mounted'
    # The framebuffer tcg-4cpu's stand-in for the firmware asks the model for, as the root reads
    # it from the tree (erx_boot_framebuffer_line) and as the display domain's driver logs it
    # (erx_firmware_fb). The model answers a pitch of four bytes a pixel, no padding.
    FB = Raspi4bFirmwareFb
    FB_STRIDE = FB::WIDTH * 4
    ROOT_LINE = "erx: device tree: #{FB::PARENT}: framebuffer #{FB::WIDTH}x#{FB::HEIGHT} #{FB_STRIDE} #{FB::FORMAT}".freeze
    DRIVER_LINE = "erx_fb: framebuffer #{FB::WIDTH}x#{FB::HEIGHT} stride #{FB_STRIDE} #{FB::FORMAT}".freeze
    # The head of the record the Bluetooth domain's line writer leaves when it ends, up to
    # its pid.
    BT_WRITER_END = 'error: label: {gen_server,terminate}, name: erx_bt_line_tx, process: <'
    # The least share of the screen the background shows under the splash: erx_splash's mark
    # and dots fit in 384 by 189 pixels, under a quarter of FB's 640 by 480, so a screen
    # painted only in part, or in other colours, falls short of it.
    BACKGROUND_SHARE = 3r / 4
    # How long the screen may take to show the splash once the release's shell is up, and
    # how often it is read until then.
    SCREEN_SECONDS = 120
    SCREEN_POLL_SECONDS = 2
    # How long the system's Erlang shell waits, before it halts the machine, for each
    # configured domain's line (CONFIGURED_LINES), and how often it reads the serial log
    # until then: the Bluetooth domain's line comes about 1.5 s after the domain starts,
    # which on a TCG boot can be after the shell is up.
    CONFIGURED_SECONDS = 20
    CONFIGURED_POLL_SECONDS = 1
    # The head of the line the domain service logs when configured domain NAME ends, up to
    # what ended it and what the service does next (erx_domain_srv's log_end). Interpolated
    # as a Regexp into an /x pattern, it keeps its own flags, so its spaces stay literal.
    def self.end_line_head(name) = /erx_domain: configured domain #{Regexp.escape(name)} \(domain \d+\) ended, /n

    # The system domain's line for configured domain NAME ended by a memory fault and
    # restarted.
    def self.memory_fault_restart(name)
      /\d+\.\d{6}\ notice\ domain\ \d+\ principal\ \S+(?:\ dropped\ \d+)?\ system:\ #{end_line_head(name)}
       \{fault,#{ABI::Generated::CODEC.member('fault_kind', 'memory')}\}
       \ at\ pc\ 0x\h+,\ cause\ 0x\h+,\ addr\ 0x\h+;\ restarting\ it\r*$/nx
    end

    # Whether image shows the splash: FB's size, at least BACKGROUND_SHARE of its pixels the
    # background colour, and the mark drawn. The mark's fully covered pixels are drawn in the
    # text colour, so the pixels of that colour number at least half of them and lie within
    # a box of the mark's size; a screen of the background alone, or with text elsewhere,
    # fails. Colours are hex rrggbb.
    def self.splash_shown?(image, background:, text:, mark:)
      return false unless [image.width, image.height] == [FB::WIDTH, FB::HEIGHT]

      colours = colours(image)
      return false unless colours.count(background) >= BACKGROUND_SHARE * colours.size

      inked = colours.each_with_index.filter_map { |colour, i| i if colour == text }
      return false if inked.empty? || inked.size * 2 < mark.pixels.count("\xff".b)

      xs, ys = inked.map { |i| i.divmod(image.width).reverse }.transpose
      xs.max - xs.min < mark.width && ys.max - ys.min < mark.height
    end

    # The image's pixels, each as hex rrggbb, top row first.
    def self.colours(image) = image.pixels.unpack1('H*').scan(/.{6}/)
    # The line each configured domain of the Pi's manifest leaves on the model by the time
    # tcg-4cpu halts. tcg-4cpu boots with no card on EMMC2's bus, so the storage domain's SD
    # device process finds no card and logs a record of its space saying so. The model has
    # no Ethernet (docs/design-platforms.md, "What the model never checks"), so the network
    # domain's first read of GENET's registers takes a memory fault, which ends only that
    # domain, and the domain service logs its end as a line of the system domain's own and
    # restarts it within its intensity (docs/design-system.md, "Boot failure"). The model has
    # no PCIe root complex either, so the PCIe domain's first read of the bridge's registers
    # ends it the same way. Any other fault kind is a bug and fails the run. The line is not
    # anchored at its start: a restart's line can follow other output on the same serial
    # line. A memory fault's line names where it struck (erx_domain_core:fault_where/2), its
    # address always a number. The model has no Bluetooth controller, and the Bluetooth
    # domain's line writer ends with line_write, a record of the domain's space, at its first
    # item, which is always the bring-up's reset (erx_bt_line_tx); why that reset fails on the
    # model is not read, since the record prints only the reason's first element. The domain's
    # groups restart within their intensities and the record repeats
    # (docs/design-bluetooth.md, "Failure handling").
    CONFIGURED_LINES = {
      'storage' => /#{NativeRoot::DOMAIN_RECORD.source}erx_blk: the SD card is not driven: /n,
      'network' => memory_fault_restart('network'),
      'pcie' => memory_fault_restart('pcie'),
      'display' => /#{NativeRoot::DOMAIN_RECORD.source}#{Regexp.escape(DRIVER_LINE)}\r*$/n,
      'bt' => /#{NativeRoot::DOMAIN_RECORD.source}#{Regexp.escape(BT_WRITER_END)}[\d.]+>, reason: line_write/n
    }.freeze
    # The configured domains whose line a boot logs once, since they start once and never end.
    STARTED_ONCE = %w[display].freeze
    # The configured domains that log nothing on the model and must never end: the USB
    # domain waits for the host controller the PCIe domain gives it, which the model, having
    # no PCIe, never gives (docs/design-usb.md).
    IDLE = %w[usb].freeze

    # Configured domain NAME's line of CONFIGURED_LINES; raises for a name with no line
    # there, so a manifest row the suite does not know fails the run rather than pass
    # unchecked. A domain of IDLE has none.
    def self.expected_line(name)
      CONFIGURED_LINES.fetch(name) { raise Error, "raspi4b: configured domain #{name} has no expected line" }
    end

    # The domains of names, which hold no domain of IDLE, whose expected line serial does
    # not hold.
    def self.missing_lines(serial, names:) = names.reject { |name| serial.match?(expected_line(name)) }

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @qemu = qemu
      @platform = Platform.load(root: @root, name: PLATFORM)
      @machine = ProductionImage::Machine.development(@platform)
    end

    # Each cell by name to its report; raises on the first disagreement.
    def call(jobs: 4, build: true)
      inputs = build ? build_inputs(jobs: jobs) : located_inputs
      { 'tcg-4cpu' => screen_boot(inputs),
        'tcg-cpu-removed' => boot(inputs, dtb: removed_cpu_tree(inputs.fetch(:dtb)), points: release_checkpoints(CPUS - 1),
                                          machine_end: false),
        'tcg-sd-card' => card_boot(inputs),
        'tcg-bench-set' => bench_set_boot(jobs: jobs) }
    end

    # The nullcall set as NativeBench::BoardSets lays it out, booted from its own
    # kernel8.img and bl31.bin with the name on its command line: the banner names the
    # set's image, every naming line carries the name, every cell the boot asks for
    # reports between two of them, and the machine ends with a reset. The model's numbers
    # are not recorded, since the model is no environment.
    def bench_set_boot(jobs:)
      laid = NativeBench::BoardSets.new(root: @root, platform: @platform, runner: @runner, compiler: @compiler, linker: @linker)
                                   .call([BENCH_SET], jobs: jobs).fetch(BENCH_SET)
      boot_files = laid.set.files
      inputs = { image: File.join(boot_files, BootPartition::KERNEL), stub: patched_stub(File.join(boot_files, BootPartition::ARMSTUB)) }
      set_line = File.file?(File.join(boot_files, BootPartition::CMDLINE)) ? File.read(File.join(boot_files, BootPartition::CMDLINE)) : nil
      dtb = named_tree(located_dtb, NativeBench.entry_command_line(set_line, BENCH_NAME))
      report = boot(inputs, dtb: dtb, points: bench_checkpoints(laid), machine_end: true)
      check_bench_boot(File.binread(report.fetch(:serial)))
      report
    end

    # From the release to the system's command shell, its kernel log lines for the card,
    # and the probe at its Erlang shell, which then halts the machine. card is the card's
    # file, whose sectors the identification line must name.
    def card_checkpoints(card)
      run = ProductionImage::Run
      shell = run::ERLANG_SHELL.merge(seconds: STEP_SECONDS)
      sectors = lambda do |answer|
        named = Integer(answer[CARD_IDENTIFIED, 1], 10)
        raise Error, "raspi4b: the card's line names #{named} sectors, its file holds #{File.size(card) / SECTOR_BYTES}" unless
          named * SECTOR_BYTES == File.size(card)
      end
      [*release_checkpoints(CPUS),
       point('root_1-shell', line(SessionDomain::SESSION_SHELL_BANNER), type: run::ERL_LINE),
       shell.merge(name: 'root_1-erlang-shell', type: DATA_PROBE).freeze,
       point('data-written', /\A\{ok,true\}\r*\n\z/n, seconds: STEP_SECONDS + DATA_TRIES, type: run::CTRL_G),
       point('ctrl-g-menu', run::CTRL_G_MENU, type: SYSTEM_SHELL_KEY),
       point('system-shell', run::MENU_LEFT, type: self.class.kernel_log(CARD_LINE)),
       point('sd-identified', CARD_IDENTIFIED, verify: sectors, type: self.class.kernel_log(PARTITIONS)),
       point('sd-partitions', PARTITIONS_ADMITTED, type: self.class.kernel_log(MOUNTED)),
       point('sd-mounted', self.class.kernel_log_line(Regexp.escape(MOUNTED)), type: run::ERL_LINE),
       shell.merge(name: 'system-erlang-shell', type: CARD_PROBE).freeze,
       point('sd-probe', /\{ok,ok,true\}\r*\n\z/n, type: HALT)].freeze
    end

    # Each row sends its type: once its pattern has matched, so the next row checks the answer.
    def shell_checkpoints
      shell = ProductionImage::Run::ERLANG_SHELL.merge(seconds: STEP_SECONDS)
      long = ProductionImage::Run::CONSOLE_LONG_BYTES
      [*release_checkpoints(CPUS),
       point('root_1-shell', line(SessionDomain::SESSION_SHELL_BANNER), type: ProductionImage::Run::ERL_LINE),
       shell.merge(name: 'root_1-erlang-shell', type: "1+1.\r").freeze,
       point('sum-echo', /1\+1\.\r*\n\z/n),
       point('sum-answer', /\A2\r*\n\z/n, type: "1+2\x7f3.\r"),
       point('edit-answer', /\A4\r*\n\z/n, type: DATA_LISTING),
       point('data-unserved', /\A\{error,eio\}\r*\n\z/n, type: "io:put_chars(lists:duplicate(#{long},$x)),io:nl().\r"),
       ProductionImage::Run::LONG_OUTPUT.merge(seconds: STEP_SECONDS).freeze,
       point('long-answer', /\Aok\r*\n\z/n, type: ProductionImage::Run::LOG_AFTER_HANDOFF),
       # The record the session logs: the console reads it from the log and writes it.
       point('log-after-handoff', ProductionImage::Run::LOG_AFTER_HANDOFF_RECORD, type: ProductionImage::Run::CTRL_G),
       point('ctrl-g-menu', ProductionImage::Run::CTRL_G_MENU, type: SYSTEM_SHELL_KEY),
       point('system-shell', ProductionImage::Run::MENU_LEFT, type: ProductionImage::Run::ERL_LINE),
       shell.merge(name: 'system-erlang-shell', type: HALT).freeze].freeze
    end

    # The boot to the release and the system's command shell, with one scheduler per CPU.
    def release_checkpoints(cpus)
      [*Qemu.boot_transcript(memory_mib: @machine.memory_mib),
       point('release-slogan', %r{\AErlang/OTP 29 .*\[smp:#{cpus}:#{cpus}\]}n, seconds: RELEASE_SECONDS),
       point('release-shell', ProductionImage::Run::RELEASE_SHELL.fetch(:pattern))].freeze
    end

    private

    # Raises if a configured domain the Pi's manifest names did not start; unless the
    # serial log holds its expected line for each one outside IDLE (expected_line), so
    # a manifest row without its expected line here fails the run; unless each domain of
    # STARTED_ONCE logged its line once and never ended, so one that restarts fails it too;
    # and unless no domain of IDLE ended. The domain service logs a start only when it fails
    # (erx_domain_srv's "did not start"), so a domain of IDLE is known to have started only
    # by that line's absence.
    def check_configured(serial)
      configured_domains.each do |name|
        raise Error, "raspi4b: configured domain #{name} did not start" if
          serial.match?(/erx_domain: configured domain #{Regexp.escape(name)} did not start: /n)
        if IDLE.include?(name)
          raise Error, "raspi4b: configured domain #{name} ended" if serial.match?(self.class.end_line_head(name))

          next
        end
        pattern = self.class.expected_line(name)
        raise Error, "raspi4b: configured domain #{name} left no line matching #{pattern.source}" unless serial.match?(pattern)
        next unless STARTED_ONCE.include?(name)

        count = serial.scan(pattern).size
        raise Error, "raspi4b: configured domain #{name} logged its line #{count} times" unless count == 1
        raise Error, "raspi4b: configured domain #{name} ended" if serial.match?(self.class.end_line_head(name))
      end
    end

    def configured_domains = Manifest::Frontend.read(@platform.manifest_source(@root)).records.fetch('domain', []).map(&:name)

    # Reads the serial log at path until it holds each configured domain's line
    # (missing_lines), or raises naming the domains still missing once CONFIGURED_SECONDS
    # have passed.
    def await_configured(path)
      names = configured_domains - IDLE
      deadline = Qmp.monotonic + CONFIGURED_SECONDS
      until (missing = self.class.missing_lines(File.binread(path), names: names)).empty?
        raise Error, "raspi4b: configured domains #{missing.join(', ')} logged no expected line within #{CONFIGURED_SECONDS} s" if
          Qmp.monotonic > deadline

        sleep CONFIGURED_POLL_SECONDS
      end
    end

    # tcg-4cpu: the shell's boot with the stand-in for the firmware's framebuffer setup
    # (Raspi4bFirmwareFb) and QMP on a socket in the boot's own owner-only directory. Once the
    # system's command shell is up the screen must show the empty layout's background; before
    # the machine halts the serial log must hold each configured domain's line, the display
    # domain's being its driver's framebuffer line; after the run it must hold the root's
    # framebuffer line, and the configured domains must pass check_configured.
    def screen_boot(inputs)
      path = ProductionImage.clear_directory(root: @root, path: File.join(@root, STUB_DIRECTORY, 'tcg-4cpu'))
      directory = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
      built = FB.build(root: @root, runner: @runner, compiler: @compiler, linker: @linker, model: inputs.fetch(:dtb),
                       directory: directory)
      socket = File.join(directory, 'qmp.sock')
      report = boot(inputs, dtb: built.tree, points: screen_checkpoints(directory), machine_end: true, firmware: built.program,
                            display: QemuPlan::Display.new(qmp_socket: socket), directory: directory)
      serial = File.binread(report.fetch(:serial))
      raise Error, "raspi4b: the serial log holds no root line #{ROOT_LINE.inspect}" unless serial.match?(/(?:^|: )#{Regexp.escape(ROOT_LINE)}\r*$/n)

      check_configured(serial)
      report
    end

    # shell_checkpoints, in the boot's directory, with the screen's check when the system's
    # command shell is up and the wait for each configured domain's line before its Erlang
    # shell halts the machine; each verify's bound is its verify_seconds, which the run's
    # deadline adds.
    def screen_checkpoints(directory)
      shell_checkpoints.map do |point|
        case point.fetch(:name)
        when 'system-shell'
          point.merge(verify: ->(_text) { await_splash(File.join(directory, 'qmp.sock')) }, verify_seconds: SCREEN_SECONDS).freeze
        when 'system-erlang-shell'
          point.merge(verify: ->(_text) { await_configured(Qemu.serial_log(directory)) }, verify_seconds: CONFIGURED_SECONDS).freeze
        else point
        end
      end.freeze
    end

    # The display domain of a boot whose tree has no framebuffer node: the root gives it no
    # record, and it logs that it runs without a screen once and never ends.
    NO_SCREEN = /#{NativeRoot::DOMAIN_RECORD.source}erx_fb: no display device record; no screen\r*$/n
    def check_no_screen(serial)
      count = serial.scan(NO_SCREEN).size
      raise Error, "raspi4b: the display domain logged its no-screen line #{count} times, not once" unless count == 1
      raise Error, 'raspi4b: the display domain ended' if serial.match?(self.class.end_line_head('display'))
    end

    # Colour ROLE of abi/theme.txt as hex rrggbb, in the palette the Pi's manifest gives its
    # display.
    def theme_colour(role)
      manifest = Manifest::Frontend.read(@platform.manifest_source(@root))
      palette = manifest.records.fetch('display').first.reference('palette')
      format('%06x', ABI::Theme.read(root: @root).palette(palette).fetch(role))
    end

    # Reads the screen through QMP until it shows the splash (splash_shown?) on the theme's
    # `desktop` colour with its mark in `text`, the mark the build generates from its logo,
    # or raises the last mismatch once SCREEN_SECONDS have passed.
    def await_splash(socket)
      background = theme_colour('desktop')
      text = theme_colour('text')
      mark = SplashMark.mask(root: @root)
      deadline = Qmp.monotonic + SCREEN_SECONDS
      client = Qmp.connect(socket)
      loop do
        image = client.screendump_image(File.join(File.dirname(socket), 'screen.ppm'))
        return if self.class.splash_shown?(image, background:, text:, mark:)
        if Qmp.monotonic > deadline
          commonest = self.class.colours(image).tally.max_by(4) { |_, count| count }
          raise Error, "raspi4b: the screen is not the splash, #{FB::WIDTH}x#{FB::HEIGHT} with #{BACKGROUND_SHARE} " \
                       "of it the background #{background} and the #{mark.width}x#{mark.height} mark in #{text}: " \
                       "it is #{image.width}x#{image.height}, its commonest colours #{commonest.inspect}"
        end

        sleep SCREEN_POLL_SECONDS
      end
    ensure
      client&.close
    end

    def point(name, pattern, type: nil, verify: nil, seconds: STEP_SECONDS)
      { name: name, pattern: pattern, seconds: seconds, **{ type: type, verify: verify }.compact }.freeze
    end

    def line(text) = /\A#{Regexp.escape(text)}\r*\n\z/n

    # The Pi's production image with its boot partition, as `tools/erx pack --medium
    # --platform raspi4b` writes it (ProductionImage.pack_platform), the development card,
    # which carries the kiosk as the published one does but not Doom, so the suite needs
    # no example fetched; booted from the partition's own kernel8.img and bl31.bin, so
    # what the model boots is what the card holds; the model's tree stands in for the one
    # the firmware would make from the partition's tree and overlays.
    def build_inputs(jobs:)
      ProductionImage.pack_platform(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform,
                                    medium: ProductionImage::MediumKind.development, jobs: jobs)
      located_inputs
    end

    def located_inputs
      partition = File.join(@root, ProductionImage.packed_directory(@platform), BootPartition::PARTITION)
      image = File.join(partition, BootPartition::KERNEL)
      bl31 = File.join(partition, BootPartition::ARMSTUB)
      dtb = located_dtb
      [image, bl31, dtb].each { |path| raise Error, "raspi4b: #{path} is not built" unless File.file?(path) }
      card = File.join(@root, ProductionImage.packed_directory(@platform), BootPartition::IMAGE)
      raise Error, "raspi4b: #{card} is not built" unless File.file?(card)

      { image: image, dtb: dtb, stub: patched_stub(bl31), card: card }
    end

    # BL31 with the stub header the firmware would fill: the tree's address and the
    # bootable file's entry, where the loader puts them.
    def patched_stub(bl31)
      loads = QemuPlan::MACHINES.fetch(PLATFORM).loads
      directory = OutputDirectory.prepare(root: @root, path: File.join(@root, STUB_DIRECTORY))
      path = File.join(directory, 'bl31-patched.bin')

      File.binwrite(path, Bl31.patch_stub(File.binread(bl31), dtb: loads.dtb, entry: loads.image))
      path
    end

    # A copy of the model's tree whose /chosen/bootargs is line, as the firmware writes an
    # entry's cmdline.txt there; QEMU's loader path takes no command line of its own.
    def named_tree(model, line)
      path = File.join(OutputDirectory.prepare(root: @root, path: File.join(@root, STUB_DIRECTORY)), 'bench-named.dtb')
      FileUtils.cp(model, path)
      @runner.run(['fdtput', '-p', '-t', 's', path, '/chosen', 'bootargs', line], name: 'raspi4b-bench-bootargs', deadline: 30)
      path
    end

    def located_dtb = File.join(@root, BoardTree::OUTPUT, PLATFORM, 'model.dtb')

    # The bench boot's transcript: the banner, the set's image identity, the root's first
    # naming line, its timing and its end, at the guest's deadline the set's root is built
    # with and the margin.
    def bench_checkpoints(laid)
      image = laid.image
      identity = /\Aerx: boot image build #{image.build_id} index #{image.index_hash} flags 0x#{image.flags.to_s(16)} archive /n
      named = /\Aerx: bench: boot #{BENCH_NAME}\r*\n\z/n
      deadline = laid.deadline_seconds + NativeBench::DEADLINE_MARGIN_SECONDS
      [*Qemu.boot_transcript(memory_mib: @machine.memory_mib),
       point('bench-image-identity', identity),
       point('bench-named', named, seconds: RELEASE_SECONDS),
       point('bench-done', NativeBench::END_LINE, seconds: deadline)].freeze
    end

    # Raises unless the bench boot of serial named no setup failure, ended with a reset
    # at its done, kept its naming and reported every cell it asks for.
    def check_bench_boot(serial)
      NativeBench.judge(serial)
      NativeBench.check_end(serial)
      deadline = NativeBench.timed_out(serial)
      raise Error, "raspi4b: the bench boot did not finish: #{deadline}" if deadline

      misnamed = NativeBench.misnamed_lines(serial, name: BENCH_NAME)
      raise Error, "raspi4b: the bench boot's #{misnamed.size} lines break its naming, first #{misnamed.first.dump[0, 200]}" unless misnamed.empty?

      asked = NativeBench.asked(BenchSuite.benchmark(BENCH_SET), cpus: CPUS)
      lines = NativeBench.guest_lines(serial)
      unreported = BenchMeasurement.boot(lines, asked, timed_out: false).fetch(:cells).reject { |cell| BenchMeasurement::GUEST_STATUSES.include?(cell.status) }
      raise Error, "raspi4b: the bench boot did not report #{unreported.map(&:operation).uniq.join(', ')}" unless unreported.empty?
    end

    def removed_cpu_tree(model)
      path = File.join(OutputDirectory.prepare(root: @root, path: File.join(@root, STUB_DIRECTORY)), 'cpu-removed.dtb')
      FileUtils.cp(model, path)
      @runner.run(['fdtput', '-r', path, REMOVED_CPU], name: 'raspi4b-cpu-removed', deadline: 30)
      path
    end

    # QEMU's loader refuses overlapping files, so each file must end before the next one's
    # address; bootstrap itself holds the tree apart (kernel/core/boot_place.c,
    # erx_boot_hold_apart).
    def check_loads(inputs)
      loads = QemuPlan::MACHINES.fetch(PLATFORM).loads
      [[:stub, loads.stub, loads.image], [:image, loads.image, loads.dtb]].each do |name, at, limit|
        size = File.size(inputs.fetch(name))
        raise Error, "raspi4b: the #{name}, #{size} bytes at 0x#{at.to_s(16)}, reaches 0x#{limit.to_s(16)}" if at + size > limit
      end
    end

    # A copy of the packed card, since the guest writes it, padded to the model's size
    # (QemuPlan.card_copy) and booted on the model's tree; the copy must then hold the
    # probe's bytes.
    def card_boot(inputs)
      card = File.join(OutputDirectory.prepare(root: @root, path: File.join(@root, STUB_DIRECTORY)), BootPartition::IMAGE)
      QemuPlan.card_copy(inputs.fetch(:card), to: card)
      report = boot(inputs, dtb: inputs.fetch(:dtb), points: card_checkpoints(card), machine_end: true, disks: [QemuPlan::Disk.new(path: card)])
      check_no_screen(File.binread(report.fetch(:serial)))
      check_card_data!(card)
      check_card_write!(card)
      report
    end

    # Raises unless the card file's data partition, from its first sector to its last
    # (MediumImage::PACKED_DATA_SECTORS), holds DATA_BYTES. A file that small is inline in its directory's metadata, so
    # its bytes lie in one block; each read overlaps the next by DATA_BYTES less one byte,
    # so bytes across two reads are found too.
    def check_card_data!(card)
      start = CODEC.constant('medium_data_start') * SECTOR_BYTES
      finish = start + (MediumImage::PACKED_DATA_SECTORS * SECTOR_BYTES)
      chunk = 1 << 22
      overlap = DATA_BYTES.bytesize - 1
      found = File.open(card, 'rb') do |file|
        (start...finish).step(chunk).any? { |at| file.pread([chunk + overlap, finish - at].min, at).include?(DATA_BYTES) }
      end
      raise Error, "raspi4b: the card's data partition does not hold #{DATA_FILE}'s bytes after the run" unless found
    end

    def check_card_write!(card)
      found = File.open(card, 'rb') { |file| file.pread(PROBE_BYTES.bytesize, PROBE_SECTOR * SECTOR_BYTES) }
      raise Error, "raspi4b: the card's sector #{PROBE_SECTOR} does not hold the probe's bytes after the run" unless found == PROBE_BYTES
    end

    def boot(inputs, dtb:, points:, machine_end:, disks: [], firmware: nil, display: nil, directory: nil)
      check_loads(inputs)
      report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                   .run(platform: @platform, accel: 'tcg', cpus: CPUS, image: inputs.fetch(:image), stub: inputs.fetch(:stub), dtb: dtb,
                        memory_mib: @machine.memory_mib, hostlink: QemuPlan::NO_HOSTLINK, checkpoints: points, machine_end: machine_end,
                        disks: disks, firmware: firmware, display: display, directory: directory)
      { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze
    end
  end
end
