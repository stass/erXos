# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_record'
require_relative 'bl31'
require_relative 'board_record'
require_relative 'board_run'
require_relative 'boot_partition'
require_relative 'build_kind'
require_relative 'dependencies'
require_relative 'error'
require_relative 'linux_guest'
require_relative 'netboot'
require_relative 'peer_bench'

module Erx
  # Linux's bench set for the Raspberry Pi 4 (docs/design-bench.md, "Linux on the same
  # board"): the vendor's stock kernel, its device tree and an initramfs of Linux's guest
  # (LinuxGuest, its /init built for the board), laid out as a boot set the board walk
  # (BoardRun) queues and walks as it does erXos's, and whose log BoardRecord reads.
  #
  # The set is the boot partition erXos's bench sets are (BootPartition), with the same
  # pinned firmware, the same BL31 and the same config.txt, written for no overlay since
  # the vendor's tree carries none of erXos's, plus one line that loads the initramfs.
  # Its kernel, device tree and the kernel's license come from Linux's own lock
  # (bench/linux/deps.lock), pinned at the firmware's commit; its cmdline.txt holds the
  # kernel's console and the program's arguments after "--", to which the netboot entry
  # appends the boot name /init takes off again. Its build record names Linux under
  # inputs, which is what makes BoardRecord record the set as Linux's.
  module LinuxBoard
    ENVIRONMENT = BenchRecord::Environment.new(kind: 'pi4', model: nil, cpus: BoardRecord::CPUS, system: 'linux',
                                               details: {}).name
    KERNEL = 'rpi-kernel8'
    TREE = 'rpi-kernel8-dtb'
    LICENSE = 'rpi-kernel8-license'
    INITRAMFS = 'initramfs.cpio'
    # Where the firmware loads the initramfs: 256 MiB, above the kernel the firmware
    # decompresses at kernel_address and far below the device tree. The firmware's own
    # placement, followkernel, puts it just after the device tree, which BL31 opens out in
    # place to Bl31::DTB_WINDOW to add its PSCI nodes, overwriting the archive's start.
    INITRAMFS_ADDRESS = 0x1000_0000
    # Where the sets are laid out.
    OUTPUT = 'build/linux-board'
    # The mini UART the firmware's enable_uart sets up, which the vendor's tree names
    # ttyS0; quiet, so the kernel's device messages do not land inside the program's BENCH
    # lines, as they did while USB and the card were probed; the performance governor, so
    # the CPUs hold the configured frequency (docs/design-bench.md, "Other systems on the
    # same Raspberry Pi 4"); and an immediate restart on a panic, so a failed boot returns
    # the board to the queue's next entry.
    COMMAND_LINE = 'console=ttyS0,115200 quiet cpufreq.default_governor=performance panic=-1'

    module_function

    # Whether Linux on the board runs benchmark name: erx_peer_bench has its counterpart
    # in a boot Linux's guest runs (LinuxGuest::BOOTS).
    def runs?(name) = LinuxGuest::BOOTS.include?(PeerBench::BOOTS[name])

    # The kernel command line of a run of benchmark name on the board's CPUs.
    def command_line(name)
      [COMMAND_LINE, "maxcpus=#{BoardRecord::CPUS}", '--', *PeerBench.arguments(name, cpus: BoardRecord::CPUS)].join(' ')
    end

    # The set's layout, each name to its source path or BootPartition::Text; linux maps
    # the lock's ids to their fetched paths, firmware each firmware file's name to its
    # path. Pure.
    def plan(platform:, name:, linux:, initramfs:, bl31:, bl31_license:, firmware:)
      own = { BootPartition::KERNEL => linux.fetch(KERNEL), BootPartition::ARMSTUB => bl31,
              BootPartition::ARMSTUB_LICENSE => bl31_license,
              BootPartition::CONFIG => config(platform),
              BootPartition::CMDLINE => BootPartition::Text.new(command_line(name)),
              File.basename(linux.fetch(TREE)) => linux.fetch(TREE),
              File.basename(linux.fetch(LICENSE)) => linux.fetch(LICENSE), INITRAMFS => initramfs }
      clash = own.keys & firmware.keys
      raise Error, "linux board: the firmware's #{clash.join(', ')} would replace a file of the set" unless clash.empty?

      own.merge(firmware)
    end

    # config.txt: erXos's bench sets' own for platform, for no overlay, and the firmware's
    # initramfs line, which loads INITRAMFS at INITRAMFS_ADDRESS and names it in the tree.
    def config(platform)
      BootPartition::ConfigPlan.new(platform: platform, overlays: [], build_kind: BuildKind::DEVELOPMENT,
                                    initramfs: BootPartition::Initramfs.new(file: INITRAMFS, address: INITRAMFS_ADDRESS))
    end

    # Lays the set of a run of benchmark name out into directory, an empty directory under
    # root, with its build record (BootPartition.write_set), which states what its
    # config.txt sets as erXos's sets' do: Linux's lock fetched, the
    # initramfs built, BL31 built and the firmware as deps.lock pins it. Answers the walk's
    # subject of it (BoardRun::Subject): no banner names Linux's boot, and the walk waits
    # for its end as long as /init waits for the program.
    def lay_out(root:, runner:, platform:, name:, directory:, compiler:, linker:, revision:)
      raise Error, "linux board: Linux's guest runs no counterpart of #{name}" unless runs?(name)
      lock = LinuxGuest.lock(root: root, runner: runner)
      built = LinuxGuest.build(root: root, runner: runner, board: true)
      pinned = BootPartition::FIRMWARE.map { |id| Dependencies.new(root: root, runner: runner).archive_for(id) }
      plan = plan(platform: platform, name: name, initramfs: built.fetch(:initrd),
                  linux: [KERNEL, TREE, LICENSE].to_h { |id| [id, lock.fetched_file(id)] },
                  firmware: pinned.to_h { |source, path| [source.fetch('filename'), path] },
                  bl31: Bl31.ensure(root: root, runner: runner, compiler: compiler, linker: linker),
                  bl31_license: Bl31.license(root: root, runner: runner))
      linux = built.fetch(:subject).merge('kernel' => LinuxGuest.pin_of(lock, KERNEL), 'tree' => LinuxGuest.pin_of(lock, TREE),
                                          'command_line' => command_line(name))
      record = { 'source' => (revision && { 'commit' => revision.commit, 'dirty' => revision.dirty }),
                 'inputs' => { 'platform' => platform.name, 'firmware' => pinned.map(&:first),
                               'bl31' => Bl31.record(root: root, compiler: compiler, linker: linker),
                               'linux' => linux } }
      written = BootPartition.write_set(root: root, directory: directory, plan: plan, record: record)
      BoardRun::Subject.new(set: Netboot.boot_set(File.dirname(written.record), record: BootPartition::SET_RECORD),
                            record: written.record, identity: nil, deadline_seconds: LinuxGuest::DEADLINE_SECONDS,
                            root_flags: nil)
    end
  end
end
