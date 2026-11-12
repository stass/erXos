# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bl31'
require_relative 'boot_partition'
require_relative 'board_tree'
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
  # shell, where the person types a sum, a line with a mistake rubbed out, an output longer
  # than the mini UART's FIFOs, and a debug log record whose tab and escape the console
  # writes as text; then Ctrl-G's menu gives the system's command shell, whose Erlang shell
  # halts the machine, and BL31's reset ends QEMU under -no-reboot.
  #
  # tcg-cpu-removed, a seeded fault: the same image on the model's tree with one CPU's node
  # removed reaches the release with three schedulers, so the four of tcg-4cpu are the
  # tree's CPUs and not a constant.
  #
  # The other seeded fault the plan names, a driver that drops one received byte, needs an
  # image of its own and is run by hand: a drain that drops `+` makes the shell echo `11.`
  # and answer 11, and the run fails at sum-echo.
  class Raspi4bShell
    PLATFORM = 'raspi4b'
    CPUS = 4
    CELLS = %w[tcg-4cpu tcg-cpu-removed].freeze
    # The CPU node the seeded tree loses, the last of the model's four.
    REMOVED_CPU = '/cpus/cpu@3'
    # Under TCG a four-CPU boot takes minutes to reach the release.
    RELEASE_SECONDS = 900
    STEP_SECONDS = 180
    PROMPT = SessionDomain::PROMPT
    SYSTEM_SHELL_KEY = 's'
    HALT = "erlang:halt().\r"
    STUB_DIRECTORY = 'build/raspi4b-stub'

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
                                          machine_end: false) }
    end

    def shell_checkpoints
      shell = ProductionImage::Run::ERLANG_SHELL.merge(seconds: STEP_SECONDS)
      long = ProductionImage::Run::CONSOLE_LONG_BYTES
      [*release_checkpoints(CPUS),
       point('root_1-shell', line(SessionDomain::SESSION_SHELL_BANNER), type: ProductionImage::Run::ERL_LINE),
       shell.merge(name: 'root_1-erlang-shell', type: "1+1.\r").freeze,
       point('sum-echo', /1\+1\.\r*\n\z/n),
       point('sum-answer', /\A2\r*\n\z/n, type: "1+2\x7f3.\r"),
       point('edit-answer', /\A4\r*\n\z/n, type: "io:put_chars(lists:duplicate(#{long},$x)),io:nl().\r"),
       point('long-output', /x{#{long}}/n),
       point('long-answer', /\Aok\r*\n\z/n, type: ProductionImage::Run::LOG_AFTER_HANDOFF),
       # The record the session logs reaches the console through the log, which writes it
       # escaped: the tab and the escape byte as text, never as the bytes themselves.
       point('log-after-handoff', /\A#{PROMPT}#[0-9]+ [0-9]+\.[0-9]+ [a-z]+ .*after\\x09handoff\\x1B\[1m\r*\n\z/n,
             type: ProductionImage::Run::CTRL_G),
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

    def point(name, pattern, type: nil, seconds: STEP_SECONDS)
      { name: name, pattern: pattern, seconds: seconds, **{ type: type }.compact }.freeze
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
      { image: image, dtb: dtb, stub: patched_stub(bl31) }
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

    # QEMU's loader refuses overlapping files, and bootstrap would write over a tree just past
    # its image, so each file must end before the next one's address.
    def check_loads(inputs)
      loads = QemuPlan::MACHINES.fetch(PLATFORM).loads
      [[:stub, loads.stub, loads.image], [:image, loads.image, loads.dtb]].each do |name, at, limit|
        size = File.size(inputs.fetch(name))
        raise Error, "raspi4b: the #{name}, #{size} bytes at 0x#{at.to_s(16)}, reaches 0x#{limit.to_s(16)}" if at + size > limit
      end
    end

    def boot(inputs, dtb:, points:, machine_end:)
      check_loads(inputs)
      report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                   .run(platform: @platform, accel: 'tcg', cpus: CPUS, image: inputs.fetch(:image), stub: inputs.fetch(:stub), dtb: dtb,
                        memory_mib: @machine.memory_mib, hostlink: QemuPlan::NO_HOSTLINK, checkpoints: points, machine_end: machine_end)
      { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze
    end
  end
end
