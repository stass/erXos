# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'set'
require 'json'
require_relative 'bootstrap_memory'
require_relative 'platform'
require_relative 'qemu_remote'
require_relative 'qmp'
require_relative 'qemu_reuse'
require_relative 'runner'

module Erx
  class TranscriptTimeout < Error; end

  module QemuPlan
    # The guest CPU counts a plan accepts.
    CPUS = (1..8)
    # Where QEMU's generic loader puts a board's boot stages, for a board whose firmware QEMU
    # does not run (docs/design-platforms.md, "Bring-up under QEMU"): the boot stub (BL31,
    # where CPU 0 starts), the bootable file, at the address the stub enters, and the device
    # tree, at the address patched into the stub's header.
    Loads = Data.define(:stub, :image, :dtb)
    # Each board's QEMU machine, by its platform record's name (Platform): the -machine
    # value, and the options added under TCG and in deterministic mode. QEMU virt's are
    # GICv3, an MSI controller TCG needs for PCIe, and no random seeds in its device tree.
    # A board with loads boots as its firmware would (loaded_argv); globals are its -global
    # options; card_bus is the SD bus a card plugs into, nil on a board that takes none.
    Machine = Data.define(:base, :tcg_options, :deterministic_options, :loads, :globals, :card_bus) do
      def initialize(base:, tcg_options:, deterministic_options:, loads: nil, globals: [], card_bus: nil)
        super
      end
    end
    MACHINES = {
      'qemu-virt' => Machine.new(base: 'virt-11.1,gic-version=3', tcg_options: %w[msi=gicv2m],
                                 deterministic_options: %w[dtb-randomness=off]),
      # The Raspberry Pi 4's model: BL31 at 0, its link address; the bootable file at
      # 0x200000, where the Pi firmware loads a 64-bit kernel and bootstrap is linked; the
      # tree at 0x8000000, 126 MiB past it (docs/research-rpi4-bl31-qemu.md placed it at
      # 0x3000000, which the image reached). The image's binding limit is lower: the
      # native root is linked at 64 MiB (NativeRoot::DEVELOPMENT_ROOT_MIB), and bootstrap
      # refuses to place it over the archive (kernel/core/boot_place.c, place_overlap). BL31 grows the tree in place by up to 1 MiB (Bl31.patch_stub), and
      # bootstrap holds the tree apart when it places the kernel's images behind the
      # archive (kernel/core/boot_place.c, erx_boot_hold_apart). The GIC with its security
      # extensions is the board's GIC-400.
      'raspi4b' => Machine.new(base: 'raspi4b', tcg_options: [], deterministic_options: [],
                               loads: Loads.new(stub: 0, image: 0x200000, dtb: 0x8000000),
                               globals: %w[arm_gic.has-security-extensions=on],
                               # EMMC2's bus, the first generic-sdhci's; the model's own card holds
                               # the drive id sd0 (docs/research-sdhci-qemu-model.md, findings 1 and 2).
                               card_bus: '/generic-sdhci/sd-bus')
    }.freeze
    # As serial, the guest's serial line on this process's own standard input
    # and output, with QEMU's monitor multiplexed onto it: Ctrl-A C switches
    # between the two and Ctrl-A X quits QEMU. For a person at a terminal,
    # never for a harness, which reads the line from a file.
    CONSOLE = :console
    # As serial, the guest's serial line on QEMU's own standard input and output, for a
    # QEMU on another host whose line ssh carries (QemuRemote); its input comes on
    # standard input too, so the plan takes no serial_input. Also for the boot benchmark
    # (BenchBoot), which reads the line from a pipe to stamp each chunk with the host's clock.
    STDIO = :stdio
    # The kernel command line's word for deterministic mode (docs/design-stopgap.md,
    # "Deterministic mode"). A plan whose line carries it, split on spaces as the guest
    # splits it, runs one CPU under TCG, which instruction counting makes single-threaded.
    # The guest's every input is then the same at each boot: its clock counts the
    # instructions executed (without shift, -icount counts nothing), its real-time clock
    # starts at a fixed date and runs on that clock, and QEMU's device tree carries no
    # random seeds.
    DETERMINISTIC_WORD = 'erx.det=1'
    DETERMINISTIC_ARGUMENTS = %w[-icount shift=0,sleep=off -rtc base=2026-01-01,clock=vm].freeze
    # The most disks a plan attaches; QEMU virt has 32 virtio-mmio slots and the
    # tests need a handful. They fit on the disks' page (NIC_TRANSPORT).
    MAX_DISKS = 4
    # QEMU's virtio-mmio transport offers the legacy interface (version 1) unless
    # told otherwise; the guest's driver supports version 2 only.
    DISK_TRANSPORT_ARGUMENTS = %w[-global virtio-mmio.force-legacy=false].freeze
    # QEMU virt makes 32 virtio-mmio transports, 0x200 bytes apart from 0x0a000000, as
    # buses virtio-mmio-bus.0 to .31 in address order, and hands a device with no bus
    # named the free transport of highest address. The first disk is pinned to bus .31,
    # at 0x0a003e00, which the development manifest names as the block device
    # (config/manifest/qemu-virt-development.txt), and each next disk to the bus below.
    LAST_TRANSPORT = 31
    # The transport the network device sits on: bus .23 at 0x0a002e00, which the development
    # manifest names as the network device (config/platforms/qemu-virt.json). Eight
    # transports share a 4 KiB page, and the transports of a page are one unit, which goes
    # whole to one domain (docs/design-shared-devices.md, "The unit rule"); the disks and
    # the network device go to different domains, so the disks keep the top page, buses
    # .31 to .24, and the network device takes the page below it.
    NIC_TRANSPORT = 23
    # How many virtio-mmio transports share one 4 KiB register page: 0x1000 / 0x200.
    TRANSPORTS_PER_PAGE = 8
    # The display devices' transports: the page below the network device's, buses .15 to
    # .8, at 0x0a001e00 and below. The graphics device is bus .15, the keyboard .14 and the
    # tablet .13, so the three are one unit that goes whole to the display domain and share
    # no register page with the disks or the network device (Display, the unit rule).
    DISPLAY_TRANSPORTS = { gpu: 15, keyboard: 14, tablet: 13 }.freeze
    # One virtio device of a plan on its transport: unit names the domain the device goes
    # to (:disks, :nic or :display), bus its virtio-mmio-bus number, and device the -device
    # value before its bus.
    Placement = Data.define(:unit, :bus, :device)
    # The domain slirp's DHCP server hands the guest in its lease (option 15), which the
    # guest's resolver takes as its search list.
    NIC_DOMAIN = 'erxos.test'

    # The address and port of the guest forward: slirp carries a guest's TCP connection to
    # them to the host's loopback port Nic#echo_port, the one host service the guest reaches.
    # The address is the one slirp gives a guest forward that names none.
    NIC_ECHO_ADDRESS = '10.0.2.4'
    NIC_ECHO_PORT = 7

    # A virtio-net device on QEMU's user networking (slirp), restricted so that nothing the
    # guest sends leaves the host, which serves the guest DHCP, except through one guest
    # forward: a TCP connection to NIC_ECHO_ADDRESS port NIC_ECHO_PORT, which QEMU carries
    # over its one connection, made when it starts, to the harness's server at loopback
    # port echo_port. One hub joins it to a `dgram` backend on loopback, QEMU's end at
    # frames_port and the harness's at peer_port, so the harness exchanges raw Ethernet
    # frames with the guest as one more host on its link.
    Nic = Data.define(:frames_port, :peer_port, :echo_port) do
      def initialize(frames_port:, peer_port:, echo_port:)
        unless [frames_port, peer_port, echo_port].all? { |port| port.is_a?(Integer) && port.between?(1, 65_535) }
          raise Error, 'a network device plan names two loopback UDP ports and a loopback TCP port'
        end

        super
      end
    end
    # A display for the guest: a virtio-gpu, a virtio-keyboard and a virtio-tablet device on
    # their own virtio-mmio transports, and QEMU's machine protocol (QMP) on a UNIX socket at
    # qmp_socket, which the harness reads the screen through (Qmp: screendump). QEMU still
    # shows no window (-display none): its graphics console keeps the guest's picture for
    # screendump. The socket's directory must be the caller's own and owner-only (mode 0700,
    # as OutputDirectory makes it), which the plan checks before QEMU starts, because QMP
    # gives whoever connects the developer's own power over the machine and the host files
    # it writes; QEMU makes the socket itself. The transports are buses
    # of virtio-mmio-bus, three distinct numbers within 0 to 31, by default DISPLAY_TRANSPORTS.
    Display = Data.define(:qmp_socket, :gpu, :keyboard, :tablet) do
      def initialize(qmp_socket:, gpu: DISPLAY_TRANSPORTS.fetch(:gpu), keyboard: DISPLAY_TRANSPORTS.fetch(:keyboard),
                     tablet: DISPLAY_TRANSPORTS.fetch(:tablet))
        buses = [gpu, keyboard, tablet]
        unless buses.all? { |bus| bus.is_a?(Integer) && bus.between?(0, LAST_TRANSPORT) } && buses.uniq.size == buses.size
          raise Error, "display transports are three distinct buses of virtio-mmio-bus.0 to .#{LAST_TRANSPORT}"
        end
        unless qmp_socket.is_a?(String) && qmp_socket.start_with?('/') && qmp_socket.bytesize <= SOCKET_PATH_MAX &&
               !qmp_socket.match?(/[\0,]/)
          raise Error, 'invalid QMP socket path'
        end

        super(qmp_socket: qmp_socket.dup.freeze, gpu: gpu, keyboard: keyboard, tablet: tablet)
      end

      # The display's three devices on their transports, all of the unit :display.
      def placements
        [['virtio-gpu-device', gpu], ['virtio-keyboard-device', keyboard], ['virtio-tablet-device', tablet]]
          .map { |device, bus| Placement.new(unit: :display, bus: bus, device: device) }
      end
    end
    # As hostlink, no host link at all: one serial line, the console's, as on a machine
    # with one UART, such as the website's emulator (docs/design-stopgap.md, "Device paths").
    NO_HOSTLINK = :none
    # The kernel command line's word that asks the root for the host link's device record
    # (docs/design-stopgap.md, "The command line"). A plan puts it first on the line exactly
    # when it gives the guest the host link's serial line, so the record never names a UART
    # the machine lacks; a caller's line that carries it is refused.
    HOSTLINK_WORD = 'erx.hostlink=1'
    # The longest path a UNIX socket takes on macOS, the primary host: sun_path's 104
    # bytes less the NUL.
    SOCKET_PATH_MAX = 103

    # A raw disk image the guest sees as a virtio-blk device on the virtio-mmio
    # bus. Its path is absolute, so QEMU reads it as a file and never as a
    # protocol prefix such as `nbd:`, and holds no comma, which QEMU reads as
    # the end of an option, and no NUL.
    Disk = Data.define(:path) do
      def initialize(path:)
        unless path.is_a?(String) && path.start_with?('/') && !path.match?(/[\0,]/)
          raise Error, 'a disk image path is absolute and holds no comma'
        end

        super(path: path.dup.freeze)
      end
    end

    module_function

    # The guest's RAM in MiB when a plan names none: the platform record's (Platform#memory_mib).
    def memory_of(platform)
      raise Error, 'a QEMU plan is for a Platform' unless platform.is_a?(Platform)

      platform.memory_mib
    end

    def argv(platform:, accel:, image:, serial:, cpus: 1, memory_mib: memory_of(platform),
             program: 'qemu-system-aarch64', initrd: nil, serial_input: nil, command_line: nil, dtb: nil,
             disks: [], hostlink: nil, nic: nil, stub: nil, display: nil, card: nil)
      raise Error, 'accelerator must be tcg or hvf' unless %w[tcg hvf].include?(accel)
      board = machine_of(platform)
      if board.loads
        return loaded_argv(board, accel: accel, image: image, serial: serial, serial_input: serial_input, cpus: cpus, program: program,
                                  stub: stub, dtb: dtb, card: card, refused: { initrd: initrd, command_line: command_line, nic: nic, display: display,
                                                                   disks: disks.empty? ? nil : disks,
                                                                   hostlink: hostlink == NO_HOSTLINK ? nil : :hostlink })
      end
      raise Error, "platform #{platform.name} boots from no stub" if stub
      raise Error, "platform #{platform.name} takes no SD card" if card
      unless cpus.is_a?(Integer) && CPUS.cover?(cpus)
        raise Error, "CPU count must be between #{CPUS.min} and #{CPUS.max}"
      end
      unless memory_mib.is_a?(Integer) && memory_mib.between?(96, 4096)
        raise Error, 'guest memory must be between 96 and 4096 MiB'
      end
      unless disks.is_a?(Array) && disks.size <= MAX_DISKS && disks.all?(Disk)
        raise Error, "disks are up to #{MAX_DISKS} QemuPlan::Disk values"
      end
      raise Error, 'a network device is a QemuPlan::Nic' unless nic.nil? || nic.is_a?(Nic)
      raise Error, 'a display is a QemuPlan::Display' unless display.nil? || display.is_a?(Display)
      devices = placements(disks: disks, nic: nic, display: display)
      check_pages(devices)
      # QEMU listens on the socket as soon as it starts, so its directory is checked before.
      Qmp.check_directory(display.qmp_socket) if display
      words = command_line.to_s.split(/ /)
      raise Error, "the plan adds #{HOSTLINK_WORD} with the host link's serial line" if words.include?(HOSTLINK_WORD)

      deterministic = words.include?(DETERMINISTIC_WORD)
      line = hostlink == NO_HOSTLINK ? command_line : [HOSTLINK_WORD, command_line].reject { |part| part.to_s.empty? }.join(' ')
      if deterministic && (accel != 'tcg' || cpus != 1)
        raise Error, 'deterministic mode runs one CPU under TCG'
      end
      [image, *([CONSOLE, STDIO].include?(serial) ? [] : [serial]), *(dtb ? [dtb] : []), program].each do |value|
        raise Error, 'invalid QEMU path' unless value.is_a?(String) && !value.empty? && !value.include?("\0")
      end

      machine = machine_line(platform, accel: accel, deterministic: deterministic)
      # `-monitor none` turns off only QEMU's default monitor; CONSOLE's
      # `mon:stdio` brings its own, multiplexed onto the serial line.
      [program, '-machine', machine, '-accel', accel,
       '-cpu', accel == 'hvf' ? 'host' : 'cortex-a76',
       '-smp', cpus.to_s, *(deterministic ? DETERMINISTIC_ARGUMENTS : []), '-m', memory_mib.to_s,
       '-display', 'none', '-monitor', 'none', '-nic', 'none',
       *(devices.empty? ? [] : DISK_TRANSPORT_ARGUMENTS), *disk_arguments(disks), *nic_arguments(nic),
       *device_arguments(devices), *qmp_arguments(display),
       '-no-reboot', *serial_arguments(serial, serial_input), *hostlink_arguments(hostlink),
       '-kernel', image,
       *(initrd ? ['-initrd', initrd] : []), *(line ? ['-append', line] : []),
       *(dtb ? ['-dtb', dtb] : [])].freeze
    end

    # The -machine value for platform's board under accel, in deterministic mode or not.
    def machine_line(platform, accel:, deterministic:)
      machine = machine_of(platform)
      [machine.base, *(accel == 'tcg' ? machine.tcg_options : []), *(deterministic ? machine.deterministic_options : [])].join(',')
    end

    def machine_of(platform)
      raise Error, 'a QEMU plan is for a Platform' unless platform.is_a?(Platform)

      MACHINES.fetch(platform.name) { raise Error, "QEMU has no machine for platform #{platform.name}" }
    end

    # A board QEMU starts through its loader (Machine#loads), as its firmware would: under TCG,
    # the model's own RAM and no -kernel, -m or -cpu; the stub, image and device tree where the
    # firmware would put them, the tree carrying the kernel command line; the console on
    # QEMU's second serial port, the first going to the null device; and no host link UART,
    # which the Raspberry Pi 4's model does not have (UART3). refused holds what such a plan
    # cannot take, each nil when the plan does not ask for it.
    def loaded_argv(board, accel:, image:, serial:, serial_input:, cpus:, program:, stub:, dtb:, card:, refused:)
      raise Error, "#{board.base} takes no SD card" if card && board.card_bus.nil?
      raise Error, 'an SD card is a QemuPlan::Disk' unless card.nil? || card.is_a?(Disk)
      raise Error, "#{board.base} runs under TCG alone" unless accel == 'tcg'
      asked = refused.compact.keys
      raise Error, "#{board.base} takes no #{asked.join(', ')}" unless asked.empty?
      raise Error, "CPU count must be between #{CPUS.min} and #{CPUS.max}" unless cpus.is_a?(Integer) && CPUS.cover?(cpus)

      [image, stub, dtb, program].each do |value|
        raise Error, 'invalid QEMU path' unless value.is_a?(String) && !value.empty? && !value.match?(/[\0,]/)
      end
      loads = [[stub, board.loads.stub, ',cpu-num=0'], [image, board.loads.image, ''], [dtb, board.loads.dtb, '']]
      [program, '-machine', board.base, '-accel', accel, '-smp', cpus.to_s,
       *board.globals.flat_map { |global| ['-global', global] },
       '-display', 'none', '-monitor', 'none', '-no-reboot',
       '-serial', 'null', *serial_arguments(serial, serial_input, id: 'console'),
       *loads.flat_map { |file, address, options| ['-device', format('loader,file=%s,addr=0x%x%s', file, address, options)] },
       *card_arguments(card, bus: board.card_bus)].freeze
    end

    # A card on the board's SD bus, its drive with no front end of its own; never the id
    # sd0, which the model's own card holds.
    def card_arguments(card, bus:)
      return [] if card.nil?

      ['-drive', "if=none,id=card0,file=#{card.path},format=raw", '-device', "sd-card,drive=card0,bus=#{bus}"]
    end

    # Each disk is a drive with no front end of its own and the virtio-blk
    # device that serves it, in the order given. Without a disk, nothing, so
    # the transport options reach only plans that have a device to use them.
    def disk_arguments(disks)
      disks.each_with_index.flat_map do |disk, index|
        ['-drive', "file=#{disk.path},format=raw,if=none,id=disk#{index}"]
      end
    end

    # The network device and its backends (Nic), or nothing.
    def nic_arguments(nic)
      return [] if nic.nil?

      loopback = '127.0.0.1'
      ['-netdev', "user,id=nic_user,restrict=on,domainname=#{NIC_DOMAIN}," \
                  "guestfwd=tcp:#{NIC_ECHO_ADDRESS}:#{NIC_ECHO_PORT}-tcp:#{loopback}:#{nic.echo_port}",
       '-netdev', "dgram,id=nic_frames,local.type=inet,local.host=#{loopback},local.port=#{nic.frames_port}," \
                  "remote.type=inet,remote.host=#{loopback},remote.port=#{nic.peer_port}",
       '-netdev', 'hubport,id=nic_hub_user,hubid=0,netdev=nic_user',
       '-netdev', 'hubport,id=nic_hub_frames,hubid=0,netdev=nic_frames',
       '-netdev', 'hubport,id=nic_hub_guest,hubid=0']
    end

    # QMP on the display's socket, or nothing.
    def qmp_arguments(display)
      display ? ['-qmp', "unix:#{display.qmp_socket},server=on,wait=off"] : []
    end

    # Every virtio device of a plan on its transport: the disks from bus .31 down, the
    # network device, the display's three. The -device arguments and the page check both
    # read this one list, so no device reaches QEMU on a bus the check did not see.
    def placements(disks:, nic:, display:)
      [*disks.each_index.map do |index|
         Placement.new(unit: :disks, bus: LAST_TRANSPORT - index, device: "virtio-blk-device,drive=disk#{index}")
       end,
       *(nic ? [Placement.new(unit: :nic, bus: NIC_TRANSPORT, device: 'virtio-net-device,netdev=nic_hub_guest')] : []),
       *(display ? display.placements : [])]
    end

    # One -device for each placement, pinned to its bus.
    def device_arguments(devices)
      devices.flat_map { |placement| ['-device', "#{placement.device},bus=virtio-mmio-bus.#{placement.bus}"] }
    end

    # The unit rule (docs/design-shared-devices.md): the transports of one 4 KiB register
    # page go whole to one domain. Raises when one page holds transports of two units.
    def check_pages(devices)
      shared = devices.group_by { |placement| placement.bus / TRANSPORTS_PER_PAGE }
                      .select { |_page, held| held.map(&:unit).uniq.size > 1 }
      return if shared.empty?

      pages = shared.map do |page, held|
        format('0x%08x (%s)', 0x0a000000 + (page * 0x1000), held.map(&:unit).uniq.join(', '))
      end
      raise Error, "transports of different units share a register page: #{pages.join('; ')}"
    end

    # The second serial line, after the console's, which QEMU virt places at
    # /pl011@9040000, the UART the development manifest names as machine.hostlink
    # (docs/design-live.md, "The host link"). Every plan but one of NO_HOSTLINK has it: on
    # a UNIX socket QEMU listens on, at the path given, without waiting for a client, or on
    # QEMU's null device. The socket's directory must be the caller's own and owner-only
    # (OutputDirectory, mode 0700).
    def hostlink_arguments(path)
      return [] if path == NO_HOSTLINK
      return ['-serial', 'null'] if path.nil?
      raise Error, 'invalid host link socket path' unless path.is_a?(String) && path.start_with?('/') &&
                                                        path.bytesize <= SOCKET_PATH_MAX && !path.match?(/[\0,]/)

      ['-serial', "unix:#{path},server=on,wait=off"]
    end

    # The guest's serial line writes to a file; with serial_input, a path QEMU reads,
    # bytes written there arrive on its receive side, through a chardev of the given id, which
    # must not be QEMU's own name for a serial line before it (serial0 for the first). CONSOLE puts both sides
    # on this terminal instead.
    def serial_arguments(serial, input, id: 'serial0')
      if serial == CONSOLE
        raise Error, 'a console serial line takes no input file' if input

        return ['-serial', 'mon:stdio']
      end
      if serial == STDIO
        raise Error, 'a serial line on standard input takes no input file' if input

        return ['-serial', 'stdio']
      end
      return ['-serial', "file:#{serial}"] unless input
      raise Error, 'invalid QEMU path' unless input.is_a?(String) && !input.empty? && !input.match?(/[\0,]/) && !serial.include?(',')

      ['-chardev', "file,id=#{id},path=#{serial},input-path=#{input}", '-serial', "chardev:#{id}"]
    end

    # The accelerators `qemu-system-aarch64 -accel help` lists: one name per
    # line after its heading. A configuration whose accelerator is absent
    # is unsupported on this host, which the conformance matrix shows as
    # such rather than as a failure or a pass.
    def accelerators(text)
      text.b.lines.map(&:strip).grep(/\A[a-z][a-z0-9_-]{0,31}\z/).to_set.freeze
    end
  end

  # The matcher consumes complete serial lines exactly once. It retains a
  # bounded unfinished line so serial splits cannot lose a checkpoint. A
  # checkpoint may also name a verifier, called with the matching line, which
  # raises Erx::Error when that line's content must fail the boot, and bytes the
  # harness types into the guest's serial line once that line has come.
  class Transcript
    MAX_LINE_BYTES = 65_536
    REQUIRED_KEYS = %i[name pattern seconds].freeze
    OPTIONAL_KEYS = %i[verify type].freeze
    attr_reader :observed

    def initialize(checkpoints:)
      unless checkpoints.is_a?(Array) && !checkpoints.empty? &&
             checkpoints.all? { |point| point.is_a?(Hash) && checkpoint_keys?(point) }
        raise Error, 'invalid transcript checkpoint plan'
      end
      names = checkpoints.map { |point| point.fetch(:name) }
      raise Error, 'duplicate transcript checkpoint name' unless names.uniq == names
      raise Error, 'invalid transcript checkpoint' unless checkpoints.all? { |point| valid_checkpoint?(point) }

      @checkpoints = checkpoints.map(&:dup).each(&:freeze).freeze
      @observed = []
      @pending = ''.b
      @offset = 0
      @checkpoint_started = 0.0
      @typed = ''.b
    end

    # Whether a checkpoint asks the harness to type.
    def types? = @checkpoints.any? { |point| point.key?(:type) }

    # The bytes due since the last call.
    def take_typed
      due = @typed
      @typed = ''.b
      due
    end

    def consume(path, elapsed:)
      check_deadline(elapsed: elapsed)
      if File.file?(path)
        File.open(path, 'rb') do |input|
          input.seek(@offset)
          chunk = input.read(64 * 1024)
          if chunk
            @offset += chunk.bytesize
            @pending << chunk
            consume_lines(elapsed: elapsed)
          end
        end
      end
      done?
    end

    def drain(path, elapsed:)
      while File.file?(path) && @offset < File.size(path) && !done?
        consume(path, elapsed: elapsed)
      end
      check_deadline(elapsed: elapsed)
      done?
    end

    def done?
      @observed.size == @checkpoints.size
    end

    private

    def checkpoint_keys?(point)
      (REQUIRED_KEYS - point.keys).empty? && (point.keys - REQUIRED_KEYS - OPTIONAL_KEYS).empty?
    end

    def valid_checkpoint?(point)
      point.fetch(:name).is_a?(String) && !point.fetch(:name).empty? &&
        point.fetch(:pattern).is_a?(Regexp) &&
        point.fetch(:seconds).is_a?(Integer) && point.fetch(:seconds).positive? &&
        point.fetch(:verify, -> {}).respond_to?(:call) &&
        point.fetch(:type, '').is_a?(String)
    end

    def check_deadline(elapsed:)
      return if done?
      point = @checkpoints.fetch(@observed.size)
      if elapsed - @checkpoint_started >= point.fetch(:seconds)
        raise TranscriptTimeout, "QEMU checkpoint timed out: #{point.fetch(:name)}"
      end
    end

    def consume_lines(elapsed:)
      while (newline = @pending.index("\n"))
        raise Error, 'serial line exceeds transcript bound' if newline > MAX_LINE_BYTES
        line = @pending.slice!(0, newline + 1)
        next if done?
        point = @checkpoints.fetch(@observed.size)
        next unless point.fetch(:pattern).match?(line)

        point[:verify]&.call(line)
        @typed << point.fetch(:type, '').b
        @observed << { 'name' => point.fetch(:name), 'elapsed_seconds' => elapsed }.freeze
        @checkpoint_started = elapsed
      end
      raise Error, 'serial line exceeds transcript bound' if @pending.bytesize > MAX_LINE_BYTES
    end
  end

  class Qemu
    BANNER = [
      { name: 'erxos-art', pattern: %r{/_/\\_\\ \\___/ \|___/\r?\n}n, seconds: 30 }.freeze,
      { name: 'erxos-banner', pattern: /erXos\r?\n/n, seconds: 30 }.freeze,
      { name: 'development-warning', pattern: /development build: trusted code only\r?\n/n,
        seconds: 30 }.freeze
    ].freeze

    # The kernel's line, right after the development warning, for an image whose archive
    # carries ERX_PACK_TEST_CODE (ProductionImage's test entry point).
    TEST_IMAGE_BANNER = { name: 'test-image', pattern: /test image: carries test code\r?\n/n, seconds: 30 }.freeze

    # QEMU's last line on its log when a signal stops it, after its program name:
    # "terminating on signal 15", with "from pid 25655 (<unknown process>)" when the sender is known.
    # QEMU then exits 0. A gtimeout that was itself signalled from outside forwards the signal and
    # passes that 0 on (its own deadline exits 124, which the runner reports as timed out), so the
    # run reads as an exit: only this line says the guest did not end it.
    SIGNAL_STOP_LINE = /^[^:\n]{1,64}: terminating on signal (\d+)(?: from pid (\d+))?/n
    # How much of the end of QEMU's log is searched for that line.
    SIGNAL_STOP_SEARCH_BYTES = 65_536

    # The default guest transcript: bootstrap's memory summary, checked
    # against the RAM QEMU is given, then the kernel banner lines, with a test
    # image's mark when the image is one.
    def self.boot_transcript(memory_mib:, test_image: false)
      raise Error, 'guest memory must be a whole number of MiB' unless memory_mib.is_a?(Integer)

      [BootstrapMemory.checkpoint(ram_bytes: memory_mib << 20), *BANNER, *(test_image ? [TEST_IMAGE_BANNER] : [])].freeze
    end

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   program: 'qemu-system-aarch64', initrd: nil)
      @root = File.expand_path(root)
      @runner = runner
      @program = program
    end

    # With machine_end the guest must end the machine itself: the run lasts
    # until QEMU exits, and a guest still running at the deadline fails it, as
    # does one that exits before its transcript is complete. Otherwise the
    # harness ends the guest at the last checkpoint.
    #
    # With link, a callable, the guest's host link UART is a UNIX socket, hostlink.sock in
    # the run's owner-only directory, and once the transcript is whole link runs in a
    # thread of its own with that path; link_seconds lengthens the run's deadline, which
    # also bounds link. The guest ends when link returns, and an error link raises is the
    # run's, a failure of the socket as an Erx::Error. The report holds link's result under
    # 'link'. The guest, not link, ends a run with machine_end, so the two do not combine.
    # Without link, hostlink is QemuPlan.argv's: nil for QEMU's null device, or
    # QemuPlan::NO_HOSTLINK for a machine with no host link UART.
    #
    # stub, on a board QEMU starts through its loader (QemuPlan::Machine#loads), is the file of
    # its boot stub, BL31 with its header patched (Bl31.patch_stub).
    #
    # display, a QemuPlan::Display, attaches the guest's display devices and QMP on its
    # socket, which a checkpoint's verify may read the screen through (Qmp). Its socket must
    # lie in an owner-only directory the caller made (Qmp.check_directory), such as the run's
    # directory passed as directory. A boot with a display is never reused: what the screen
    # showed is not in its serial log.
    #
    # card, a QemuPlan::Disk, is an SD card on the board's SD bus (QemuPlan::Machine#card_bus),
    # a file the guest writes, so a boot with a card is never reused and never remote.
    #
    # Inside the QEMU gate (QemuReuse.active), a boot that passed before on
    # the same inputs does not start QEMU: its stored serial log is written to
    # the run's serial log and replayed, and the report names it under
    # 'reused_from'.
    #
    # With remote, a QemuRemote::Host, QEMU runs on that host (QemuRemote) and its
    # serial line reaches the run's serial log over ssh. Only a boot that QEMU's inputs
    # alone determine runs there: no disk, SD card, network device or host link session. A host
    # that cannot be reached, or refuses the boot's setup, raises QemuRemote::Unreachable.
    def run(platform:, accel:, image:, cpus: 1, memory_mib: QemuPlan.memory_of(platform), checkpoints: nil, initrd: nil, machine_end: false, directory: nil, command_line: nil,
            dtb: nil, disks: [], link: nil, link_seconds: 0, hostlink: nil, nic: nil, remote: nil, stub: nil, display: nil, card: nil)
      raise Error, 'a run with a host link session ends when the session does, not with machine_end' if link && machine_end
      raise Error, 'a run with a host link session takes no other host link plan' if link && hostlink
      if remote && !reusable?(link: link, nic: nic, disks: disks, card: card, hostlink: hostlink, display: display)
        raise Error, 'a remote boot takes no disk, SD card, network device, display or host link'
      end
      raise Error, 'a remote boot takes no boot stub' if remote && stub

      checkpoints ||= self.class.boot_transcript(memory_mib: memory_mib)
      image = File.expand_path(image)
      raise Error, "guest image does not exist: #{image}" unless File.file?(image)
      matcher = Transcript.new(checkpoints: checkpoints)
      deadline = checkpoints.sum { |point| point.fetch(:seconds) } + link_seconds + 5
      directory ||= File.join(@root, 'build/qemu', "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
      directory = OutputDirectory.prepare(root: @root, path: directory, mode: 0o700)
      serial = File.join(directory, 'serial.log')
      # Emptied before QEMU starts, so the transcript reads this boot's lines alone, never
      # an earlier run's in a directory the caller reuses.
      File.write(serial, '', perm: 0o600)
      socket = link && File.join(directory, 'hostlink.sock')
      keyboard = matcher.types? ? File.join(directory, 'keyboard') : nil
      remote_boot = remote && QemuRemote::Boot.new(host: remote)
      plan = { platform: platform, accel: accel, cpus: cpus, memory_mib: memory_mib, program: remote_boot ? remote.program : @program,
               command_line: command_line }
      argv = if remote_boot
               QemuPlan.argv(**plan, image: remote_boot.path('image'), serial: QemuPlan::STDIO, initrd: initrd && remote_boot.path('initrd'),
                                     dtb: dtb && remote_boot.path('dtb'), hostlink: hostlink)
             else
               QemuPlan.argv(**plan, image: image, serial: serial, serial_input: keyboard, initrd: initrd, dtb: dtb,
                                     disks: disks, hostlink: socket || hostlink, nic: nic, stub: stub, display: display, card: card)
             end
      report = { 'state' => 'running', 'image_sha256' => Digest::SHA256.file(image).hexdigest,
                 'argv' => argv, 'checkpoints' => matcher.observed, 'serial_log' => serial }
      report['remote'] = remote.destination if remote
      reuse = QemuReuse.active
      key = nil
      if reuse && reusable?(link: link, nic: nic, disks: disks, card: card, hostlink: hostlink, display: display)
        key = boot_key(reuse, plan: plan, remote_boot: remote_boot, image_sha256: report.fetch('image_sha256'), typed: matcher.types?, initrd: initrd,
                              dtb: dtb, stub: stub, hostlink: hostlink, checkpoints: checkpoints, machine_end: machine_end)
        stored = stored_boot(reuse, key, report: report, checkpoints: checkpoints, directory: directory) if key
        return stored if stored
      end
      reuse&.ran
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      typing = nil
      session = nil
      begin
        typing = keyboard && open_keyboard(keyboard)
        version = if remote_boot
                    upload_inputs(remote_boot, { 'image' => image, 'initrd' => initrd, 'dtb' => dtb }.compact)
                    remote_step(remote_boot, remote_boot.version_argv, name: 'qemu-version', deadline: 30)
                  else
                    @runner.run([@program, '--version'], name: 'qemu-version', deadline: 10)
                  end
        report['qemu_version'] = File.binread(version.fetch('log')).lines.first.to_s.strip
        guest_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stop_guest = lambda do |_log|
          transcript_whole = matcher.consume(serial, elapsed: elapsed(guest_started))
          typing&.write(matcher.take_typed)
          next transcript_whole && !machine_end unless link

          session ||= start_link(link, socket) if transcript_whole
          !session.nil? && !session.alive?
        end
        record = if remote_boot
                   @runner.run(remote_boot.boot_argv(argv, deadline: deadline), name: "qemu-#{accel}-remote", deadline: deadline,
                                                                                 success: stop_guest, stdin: keyboard, stdout: serial)
                 else
                   @runner.run(argv, name: "qemu-#{accel}", deadline: deadline, success: stop_guest)
                 end
        report['link'] = session.value if session
        matcher.drain(serial, elapsed: elapsed(guest_started))
        raise Error, early_end_message(record.fetch('log')) unless matcher.done?
        report['state'] = 'passed'
        report['elapsed_seconds'] = elapsed(started)
        reuse.hold(key: key, serial: serial, report: report) if key
      rescue CommandError => error
        report['state'] = error.result.fetch('state') == 'timed_out' ? 'timed_out' : 'failed'
        raise
      rescue QemuRemote::Unreachable
        report['state'] = 'not_run'
        raise
      rescue TranscriptTimeout
        report['state'] = 'timed_out'
        raise
      rescue Error
        report['state'] = 'failed'
        raise
      ensure
        session&.kill&.join
        typing&.close
        clean_remote(remote_boot) if remote_boot&.prepared?
        report['state'] = 'cancelled' if report['state'] == 'running'
        report['elapsed_seconds'] = elapsed(started)
        File.write(File.join(directory, 'report.json'), JSON.pretty_generate(report) + "\n")
      end
      report
    end

    private

    # Whether QEMU's inputs alone determine this boot (QemuReuse): no disk the
    # guest may write, no SD card, no network device, no display a checkpoint reads, and
    # no host link a host side serves.
    def reusable?(link:, nic:, disks:, card:, hostlink:, display:)
      link.nil? && nic.nil? && display.nil? && card.nil? && disks.empty? && (hostlink.nil? || hostlink == QemuPlan::NO_HOSTLINK)
    end

    # The boot's key. The keyed plan is the boot's own (plan, as run passes it
    # to QemuPlan.argv) with each input file by its SHA-256 and the run's own
    # paths by fixed names. Nil, so the boot runs, when QEMU, an initrd, a
    # device tree or a boot stub is not a file.
    def boot_key(reuse, plan:, remote_boot:, image_sha256:, typed:, initrd:, dtb:, stub:, hostlink:, checkpoints:, machine_end:)
      qemu = remote_boot ? remote_identity(remote_boot) : QemuReuse.qemu_identity(@program)
      return nil unless qemu && [initrd, dtb, stub].compact.all? { |path| File.file?(path) }

      by_digest = ->(path) { path && "sha256:#{Digest::SHA256.file(path).hexdigest}" }
      keyed = QemuPlan.argv(**plan, image: "sha256:#{image_sha256}", serial: '/serial.log', serial_input: typed ? '/keyboard' : nil,
                                    initrd: by_digest.call(initrd), dtb: by_digest.call(dtb), stub: by_digest.call(stub), hostlink: hostlink)
      QemuReuse.boot_key(plan: keyed, checkpoints: checkpoints, machine_end: machine_end, qemu: qemu, harness: reuse.harness)
    end

    # The report of the stored boot of key, or nil when there is none or its
    # log no longer completes today's transcript and verifiers, which leaves
    # a diagnostic and removes the log written for the replay before QEMU
    # writes the fresh one. A reused report carries the passing run's
    # checkpoints and time and names the stored log under 'reused_from'.
    def stored_boot(reuse, key, report:, checkpoints:, directory:)
      hit = reuse.find(key)
      return nil unless hit

      serial = report.fetch('serial_log')
      File.binwrite(serial, hit.bytes)
      unless Transcript.new(checkpoints: checkpoints).drain(serial, elapsed: 0)
        reuse.diagnose("#{hit.serial} no longer completes the transcript; the boot runs fresh")
        FileUtils.rm_f(serial)
        return nil
      end

      reused = report.merge('state' => 'passed', 'checkpoints' => hit.checkpoints, 'elapsed_seconds' => hit.elapsed_seconds,
                            'reused_from' => hit.serial)
      File.write(File.join(directory, 'report.json'), JSON.pretty_generate(reused) + "\n")
      reuse.reused(key, hit)
      reused
    rescue Error, SystemCallError => e
      reuse.diagnose("#{hit&.serial || key} did not replay (#{e.message}); the boot runs fresh")
      FileUtils.rm_f(report.fetch('serial_log'))
      nil
    end

    # Why QEMU ended before the transcript was whole: a signal its log names, or an exit.
    # Only the signal's and the sender's numbers reach the message. An unreadable log
    # leaves the exit message, so the transcript failure is still the one reported.
    def early_end_message(log)
      stopped = log_tail(log).scan(SIGNAL_STOP_LINE).last
      return 'QEMU exited before completing its transcript' unless stopped

      signal, pid = stopped
      sender = pid ? " from pid #{pid}" : ''
      "QEMU was stopped by signal #{signal}#{sender} before completing its transcript"
    end

    def log_tail(log)
      File.open(log, 'rb') do |file|
        file.seek([file.size - SIGNAL_STOP_SEARCH_BYTES, 0].max)
        file.read.to_s
      end
    rescue SystemCallError
      ''
    end

    # A remote QEMU as reuse keys name it: the host, the program and its SHA-256, so
    # boots on different hosts or QEMUs never share a record.
    def remote_identity(boot)
      log = remote_step(boot, boot.digest_argv, name: 'qemu-remote-digest', deadline: 60).fetch('log')
      digest = File.binread(log, 64)
      raise QemuRemote::Unreachable, "no SHA-256 of the remote QEMU in #{log}" unless digest&.match?(/\A\h{64}\z/)

      "remote #{boot.host.destination} #{boot.host.program} #{digest}"
    end

    # The run directory on the remote host, holding each input file. Once mkdir has
    # made it, the boot is prepared and cleanup removes it; a directory this boot
    # did not make is never removed.
    def upload_inputs(boot, files)
      remote_step(boot, boot.prepare_argv, name: 'qemu-remote-prepare', deadline: 60)
      boot.prepared!
      files.each { |name, local| remote_step(boot, boot.upload_argv(name), name: 'qemu-remote-upload', deadline: 300, stdin: local) }
    end

    # One setup command on the remote host; its failure means the boot cannot start there.
    def remote_step(boot, argv, name:, deadline:, stdin: nil)
      @runner.run(argv, name: name, deadline: deadline, stdin: stdin)
    rescue CommandError => e
      raise QemuRemote::Unreachable, "remote host #{boot.host.destination}: #{e.message}"
    end

    # Ends the boot's remote QEMU and removes its run directory. A failure is reported and
    # not raised, so it never hides the boot's own result; the remote timeout then ends
    # the QEMU, and the directory stays for the next look.
    def clean_remote(boot)
      @runner.run(boot.cleanup_argv, name: 'qemu-remote-cleanup', deadline: 60)
    rescue CommandError => e
      Terminal.puts("remote cleanup of #{boot.host.destination}:#{boot.directory} failed: #{e.message}")
    end

    # The host link session in a thread of its own, its socket's failures as Erx::Error.
    def start_link(link, socket)
      Thread.new do
        link.call(socket)
      rescue SystemCallError, IOError => e
        raise Error, "host link socket #{socket}: #{e.message}"
      end.tap { |thread| thread.report_on_exception = false }
    end

    # A FIFO held open both ways, so QEMU's open of it never blocks and its read never
    # sees an end of file between the bytes the transcript types.
    def open_keyboard(path)
      File.mkfifo(path, 0o600)
      File.open(path, File::RDWR).tap { |keys| keys.sync = true }
    rescue SystemCallError => e
      raise Error, "no FIFO to type through: #{e.message}"
    end

    def elapsed(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
  end
end
