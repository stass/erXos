# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bl31'
require_relative 'boot_partition'
require_relative 'board_tree'
require_relative 'generated_abi'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The serial shell on QEMU's raspi4b model (docs/plan.md, 1b-I, "QEMU's raspi4b, under
  # TCG, proves stage (a) first"): the Raspberry Pi 4's development image, its bootstrap, BL31
  # and the model's device tree, booted through QEMU's loader (QemuPlan::Machine#loads) at
  # the model's four CPUs.
  #
  # tcg-4cpu: the boot reaches the development banner and the release with one scheduler
  # per CPU, four; root's session takes the mini UART and its command shell starts the Erlang
  # shell, where the person types a sum, a line with a mistake rubbed out, a listing of /data
  # (empty, since nothing is mounted there), an output longer than the mini UART's FIFOs, and
  # a debug log record whose tab and escape the console writes as text; then Ctrl-G's menu
  # gives the system's command shell, whose Erlang shell halts the machine, and BL31's reset
  # ends QEMU under -no-reboot.
  #
  # tcg-cpu-removed, a seeded fault: the same image on the model's tree with one CPU's node
  # removed reaches the release with three schedulers, so the four of tcg-4cpu are the
  # tree's CPUs and not a constant.
  #
  # tcg-sd-card: the same image with the card it was packed with on EMMC2's bus
  # (QemuPlan::Machine#card_bus), a copy the guest writes. The storage domain's SD device
  # process (erx_blk_sd, docs/design-storage.md, "The SD host controller") identifies the
  # card only through interrupts of its line, 158, so its line in the kernel log, which
  # names the card's sectors, shows the line fires and the card answered; the block
  # service's partition table and littlefs's mount show reads of many blocks. The system
  # domain's Erlang shell then probes the storage domain over erpc, as the harness and not
  # as a client (CARD_PROBE): it writes two blocks through erx_blk at PROBE_SECTOR, which
  # no partition holds, and reads them back; after QEMU exits the harness finds the same
  # bytes at that sector of the card's file (check_card_write!).
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
    CELLS = %w[tcg-4cpu tcg-cpu-removed tcg-sd-card].freeze
    # The CPU node the seeded tree loses, the last of the model's four.
    REMOVED_CPU = '/cpus/cpu@3'
    # Under TCG a four-CPU boot takes minutes to reach the release.
    RELEASE_SECONDS = 900
    STEP_SECONDS = 180
    SYSTEM_SHELL_KEY = 's'
    HALT = "erlang:halt().\r"
    # The Pi's manifest grants root's session no data facet, so nothing is mounted at /data
    # and the path is the session release's own empty directory (docs/design-files.md, "A
    # facet's mount").
    DATA_LISTING = "file:list_dir(\"/data\").\r"
    STUB_DIRECTORY = 'build/raspi4b-stub'
    CODEC = ABI::Generated::CODEC
    SECTOR_BYTES = CODEC.constant('mbr_sector_size')
    # The first sector after the boot-selection record's partition, in the 3 MiB before
    # slot A that no partition of abi/medium.txt holds, so the probe's write changes nothing
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
    # the line dmesg writes for it.
    def self.kernel_log(text) = "dmesg | grep '#{text}'\r"
    def self.kernel_log_line(source) = /\A#[0-9]+ [0-9]+\.[0-9]{6} debug space [0-9]+: #{source}\r*\n\z/n
    CARD_LINE = 'erx_blk: SD card, '
    CARD_IDENTIFIED = kernel_log_line("#{Regexp.escape(CARD_LINE)}(?:standard|high) capacity, ([0-9]+) sectors, " \
                                      '4-bit bus at [0-9]+ Hz')
    PARTITIONS = 'erx_blk_service: partition table admitted'
    PARTITIONS_ADMITTED = kernel_log_line("#{Regexp.escape(PARTITIONS)}; [0-9]+ windows")
    MOUNTED = 'erx_lfs: volume mounted'

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
      { 'tcg-4cpu' => boot(inputs, dtb: inputs.fetch(:dtb), points: shell_checkpoints, machine_end: true),
        'tcg-cpu-removed' => boot(inputs, dtb: removed_cpu_tree(inputs.fetch(:dtb)), points: release_checkpoints(CPUS - 1),
                                          machine_end: false),
        'tcg-sd-card' => card_boot(inputs) }
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
       shell.merge(name: 'root_1-erlang-shell', type: run::CTRL_G).freeze,
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
       point('data-empty', /\A\{ok,\[\]\}\r*\n\z/n, type: "io:put_chars(lists:duplicate(#{long},$x)),io:nl().\r"),
       point('long-output', /x{#{long}}/n),
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

    def point(name, pattern, type: nil, verify: nil, seconds: STEP_SECONDS)
      { name: name, pattern: pattern, seconds: seconds, **{ type: type, verify: verify }.compact }.freeze
    end

    def line(text) = /\A#{Regexp.escape(text)}\r*\n\z/n

    # The Pi's production image with its boot partition, as `tools/erx pack --medium
    # --platform raspi4b` writes it (ProductionImage.pack_platform), booted from the
    # partition's own kernel8.img and bl31.bin, so what the model boots is what the card
    # holds; the model's tree stands in for the one the firmware would make from the
    # partition's tree and overlays.
    def build_inputs(jobs:)
      ProductionImage.pack_platform(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform,
                                    medium: true, jobs: jobs)
      located_inputs
    end

    def located_inputs
      partition = File.join(@root, ProductionImage.packed_directory(@platform), BootPartition::PARTITION)
      image = File.join(partition, BootPartition::KERNEL)
      bl31 = File.join(partition, BootPartition::ARMSTUB)
      dtb = File.join(@root, BoardTree::OUTPUT, PLATFORM, 'model.dtb')
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

    # A copy of the packed card, since the guest writes it, booted on the model's tree; the
    # copy must then hold the probe's bytes.
    def card_boot(inputs)
      card = File.join(OutputDirectory.prepare(root: @root, path: File.join(@root, STUB_DIRECTORY)), BootPartition::IMAGE)
      FileUtils.cp(inputs.fetch(:card), card)
      report = boot(inputs, dtb: inputs.fetch(:dtb), points: card_checkpoints(card), machine_end: true, disks: [QemuPlan::Disk.new(path: card)])
      check_card_write!(card)
      report
    end

    def check_card_write!(card)
      found = File.open(card, 'rb') { |file| file.pread(PROBE_BYTES.bytesize, PROBE_SECTOR * SECTOR_BYTES) }
      raise Error, "raspi4b: the card's sector #{PROBE_SECTOR} does not hold the probe's bytes after the run" unless found == PROBE_BYTES
    end

    def boot(inputs, dtb:, points:, machine_end:, disks: [])
      check_loads(inputs)
      report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                   .run(platform: @platform, accel: 'tcg', cpus: CPUS, image: inputs.fetch(:image), stub: inputs.fetch(:stub), dtb: dtb,
                        memory_mib: @machine.memory_mib, hostlink: QemuPlan::NO_HOSTLINK, checkpoints: points, machine_end: machine_end,
                        disks: disks)
      { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze
    end
  end
end
