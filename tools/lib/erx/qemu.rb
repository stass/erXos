# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'ipaddr'
require 'set'
require 'json'
require_relative 'bootstrap_memory'
require_relative 'generated_abi'
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
      # 0x3000000, which the image reached), so the bootable file holds up to 126 MiB, which
      # the image build checks (ProductionImage::Machine#check_single_file). The native root
      # at 64 MiB (NativeRoot::DEVELOPMENT_ROOT_MIB) does not bound it: bootstrap moves an
      # archive the root lands on behind the root (kernel/core/boot_place.c,
      # erx_boot_place_archive). BL31 grows the tree in place by up to 1 MiB
      # (Bl31.patch_stub), and bootstrap holds the tree apart from every placement, the
      # moved archive's included (kernel/core/boot_place.c, erx_boot_hold_apart). The GIC with its security
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
    # As serial, the guest's serial line on QEMU's own standard input and output, for the
    # boot benchmark (BenchBoot), which reads the line from a pipe to stamp each chunk with
    # the host's clock; its input comes on standard input too, so the plan takes no serial_input.
    STDIO = :stdio
    # The kernel command line's word for deterministic mode (docs/design-fiasco.md,
    # "Deterministic mode"). A plan whose line carries it, split on spaces as the guest
    # splits it, runs one CPU under TCG, which instruction counting makes single-threaded.
    # The guest's every input is then the same at each boot: its clock counts the
    # instructions executed (without shift, -icount counts nothing), its real-time clock
    # starts at a fixed date and runs on that clock, and QEMU's device tree carries no
    # random seeds.
    DETERMINISTIC_WORD = 'erx.det=1'
    DETERMINISTIC_ARGUMENTS = %w[-icount shift=0,sleep=off -rtc base=2026-01-01,clock=vm].freeze
    # The most disks a plan attaches; QEMU virt has 32 virtio-mmio slots and the
    # tests need a handful. They fit on the block unit's register page.
    MAX_DISKS = 4
    # QEMU's virtio-mmio transport offers the legacy interface (version 1) unless
    # told otherwise; the guest's driver supports version 2 only.
    DISK_TRANSPORT_ARGUMENTS = %w[-global virtio-mmio.force-legacy=false].freeze
    # QEMU virt's virtio-mmio transports (QEMU's hw/arm/virt.c): register windows
    # VIRTIO_MMIO_STRIDE bytes apart from VIRTIO_MMIO_BASE, as buses virtio-mmio-bus.0, .1
    # and on in address order. QEMU hands a device with no bus named the free transport of
    # highest address, so the plan pins each device to the bus of the transport the platform
    # record names for it (config/platforms/qemu-virt.json): the block unit's for the first
    # disk and the transport below for each next, the net unit's for the network device,
    # the display unit's for the display's three and the line unit's for the line. Each
    # unit holds its transports' 4 KiB register pages whole (docs/design-shared-devices.md,
    # "The unit rule"), which check_pages confirms of a plan.
    VIRTIO_MMIO_BASE = 0x0a000000
    VIRTIO_MMIO_STRIDE = 0x200
    # The register page the unit rule divides transports by, and how many share one.
    REGISTER_PAGE = 0x1000
    TRANSPORTS_PER_PAGE = REGISTER_PAGE / VIRTIO_MMIO_STRIDE
    # QEMU's ids of the line's virtio-serial device and of its chardev (Line).
    LINE_SERIAL_ID = 'line_serial'
    LINE_CHARDEV_ID = 'line'
    # One virtio device of a plan on its transport: unit names the domain the device goes
    # to, by the platform record's unit key ('block', 'net', 'display' or 'line'), bus its virtio-mmio-bus number, and device the
    # -device value before its bus.
    Placement = Data.define(:unit, :bus, :device)
    # The Bluetooth controller's line, not a serial line or the kernel command line
    # (docs/design-bluetooth.md, "The line on QEMU `virt`"):
    # a virtio console on the line unit's transport whose port 0 is a socket chardev that connects to
    # a controller listening on the development host's loopback at port, the harness's
    # Bumble controller. QEMU connects when it starts, so the controller listens first.
    # The chardev never listens itself (server=off) and names only 127.0.0.1, so no other
    # host reaches the guest's line through it.
    Line = Data.define(:port) do
      # The chardev, and port 0 of the console on it, on the virtio-serial device's own bus,
      # LINE_SERIAL_ID.0. They follow the device's -device (QemuPlan.placements), since QEMU
      # creates the port on a bus the device has already made.
      def arguments = ['-chardev', "socket,id=#{LINE_CHARDEV_ID},host=127.0.0.1,port=#{port},server=off",
                       '-device', "virtconsole,chardev=#{LINE_CHARDEV_ID},bus=#{LINE_SERIAL_ID}.0,nr=0"]
    end
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
    # port echo_port. A plan with a forward (Forward) has one host forward as well: QEMU
    # listens on its loopback port and carries each connection to it to the guest's port;
    # restricted mode leaves the forward alone, since it does not affect forwarding rules
    # (QEMU's invocation documentation, `-netdev user`). One hub joins it to a `dgram`
    # backend on loopback, QEMU's end at frames_port and the harness's at peer_port, so
    # the harness exchanges raw Ethernet frames with the guest as one more host on its link.
    Nic = Data.define(:frames_port, :peer_port, :echo_port, :forward) do
      def initialize(frames_port:, peer_port:, echo_port:, forward: nil)
        unless [frames_port, peer_port, echo_port].all? { |port| port.is_a?(Integer) && port.between?(1, 65_535) }
          raise Error, 'a network device plan names two loopback UDP ports and a loopback TCP port'
        end
        raise Error, 'a network device plan forwards through a QemuPlan::Forward' unless forward.nil? || forward.is_a?(Forward)

        super
      end
    end
    # The host forward of a Nic: slirp carries each connection to the host's loopback
    # port host to port guest of the address slirp's DHCP server gives first, 10.0.2.15,
    # the one a forward that names no guest address goes to (QEMU's invocation
    # documentation, `-netdev user`) and the guest's lease (NetDevice::GUEST_IP). The
    # guest's port is above 1023, so the default ports limit of a grant takes it.
    Forward = Data.define(:host, :guest) do
      def initialize(host:, guest:)
        raise Error, 'a host forward is from a loopback port to a guest port above 1023' unless
          host.is_a?(Integer) && host.between?(1, 65_535) && guest.is_a?(Integer) && guest.between?(1024, 65_535)

        super
      end
    end
    # A virtio-net device on restricted QEMU user networking whose virtual network,
    # network (an IPv4 CIDR), covers address, so that slirp takes a guest forward for it
    # (libslirp 4.9.7 src/slirp.c:1584) and answers the guest's ARP for it (:1241). Its one
    # guest forward is QEMU's `cmd:` form: each TCP connection the guest opens to address
    # port port starts `nc 127.0.0.1 relay_port`, with the connection as its standard
    # input and output and its arguments split without a shell (src/misc.c:212-248), so
    # the connection reaches the harness's server at that loopback port. Nothing else the
    # guest sends leaves the host (the dashboard example's README, "The QEMU cell").
    Relay = Data.define(:network, :address, :port, :relay_port) do
      def initialize(network:, address:, port:, relay_port:)
        range = IPAddr.new(network)
        unless range.ipv4? && network.include?('/') && address.match?(/\A[0-9.]+\z/) && range.include?(IPAddr.new(address)) &&
               [port, relay_port].all? { |number| number.is_a?(Integer) && number.between?(1, 65_535) }
          raise Error, 'a relay forwards an address inside its IPv4 network and a port to a loopback port'
        end

        super(network: network.dup.freeze, address: address.dup.freeze, port: port, relay_port: relay_port)
      rescue IPAddr::Error
        raise Error, 'a relay names an IPv4 network and an address'
      end
    end
    # A virtio-net device on QEMU's user networking as a person boots a medium (README,
    # "Getting started"): unrestricted, so the guest reaches the host's network through slirp
    # as any QEMU guest does, with one host forward (Forward) from a loopback port to the
    # guest's, and nothing of Nic's echo server or frame link.
    UserNet = Data.define(:forward) do
      def initialize(forward:)
        raise Error, 'a user network forwards through a QemuPlan::Forward' unless forward.is_a?(Forward)

        super
      end
    end
    # A Display's qmp_socket for a display in QEMU's window, which has no QMP socket.
    WINDOW = :window
    # A display for the guest: a virtio-gpu, a virtio-keyboard and a virtio-tablet device on
    # their own virtio-mmio transports, and either QEMU's machine protocol (QMP) on a UNIX
    # socket at qmp_socket, which the harness reads the screen through (Qmp: screendump),
    # with no window (-display none), its graphics console keeping the guest's picture for
    # screendump; or, with qmp_socket WINDOW (Display.window), QEMU's own window on the host
    # (-display default), for a person at the screen. The socket's directory must be the caller's own and owner-only (mode 0700,
    # as OutputDirectory makes it), which the plan checks before QEMU starts, because QMP
    # gives whoever connects the developer's own power over the machine and the host files
    # it writes; QEMU makes the socket itself. The devices' transports are the platform
    # record's display unit's (QemuPlan.display_devices).
    Display = Data.define(:qmp_socket) do
      def initialize(qmp_socket:)
        unless qmp_socket == WINDOW || (qmp_socket.is_a?(String) && qmp_socket.start_with?('/') &&
                                        qmp_socket.bytesize <= SOCKET_PATH_MAX && !qmp_socket.match?(/[\0,]/))
          raise Error, 'invalid QMP socket path'
        end

        super(qmp_socket: qmp_socket == WINDOW ? WINDOW : qmp_socket.dup.freeze)
      end

      # The display in QEMU's own window, with no QMP socket.
      def self.window = new(qmp_socket: WINDOW)

      def window? = qmp_socket == WINDOW
    end
    # PCIe functions on QEMU virt's host bridge, for the pcie suite (docs/design-pcie.md, "The
    # `pcie` QEMU suite"): functions maps a slot of bus 0, 1 to 31 (slot 0 is the host
    # bridge's own function), to the device of PCIE_DEVICES QEMU attaches there; and QMP on a
    # UNIX socket at qmp_socket, through which the harness reads what QEMU itself holds of
    # each function (Qmp#pci_functions).
    # The socket's directory is checked as a Display's is. A plan takes a display or PCIe
    # functions, not both, so QEMU has one QMP socket.
    Pcie = Data.define(:qmp_socket, :functions, :usb) do
      def initialize(qmp_socket:, functions:, usb: [])
        unless qmp_socket.is_a?(String) && qmp_socket.start_with?('/') && qmp_socket.bytesize <= SOCKET_PATH_MAX &&
               !qmp_socket.match?(/[\0,]/)
          raise Error, 'invalid QMP socket path'
        end
        valid = functions.is_a?(Hash) && !functions.empty? &&
                functions.all? { |slot, device| slot.is_a?(Integer) && slot.between?(1, 31) && PCIE_DEVICES.include?(device) }
        raise Error, "PCIe functions are slots 1 to 31, each one of #{PCIE_DEVICES.join(', ')}" unless valid
        unless usb.is_a?(Array) && usb.all? { |device| USB_DEVICES.include?(device) || device.is_a?(Disk) } &&
               (usb.empty? || functions.size == 1)
          raise Error, "USB devices are each one of #{USB_DEVICES.join(', ')} or a disk, on a plan's one controller"
        end

        super(qmp_socket: qmp_socket.dup.freeze, functions: functions.dup.freeze, usb: usb.dup.freeze)
      end

      # One -device for each function, at its slot of the host bridge's bus, named by its slot,
      # then one for each USB device on the controller's bus, `<id>.0` in QEMU's naming
      # (docs/system/devices/usb.rst). A disk on the bus is a removable usb-storage stick over
      # its raw image, its drive with no front end of its own; the n-th stick is named
      # QemuPlan.usb_stick_id(n), which QMP's device_del takes, and its drive that name with
      # `drive` after it, which QMP's eject takes.
      def arguments
        controllers = functions.sort.flat_map { |slot, device| ['-device', "#{device},addr=#{slot},id=pcie#{slot}"] }
        bus = "pcie#{functions.keys.first}.0"
        numbers = usb.grep(Disk).each_with_index.to_h { |disk, number| [disk.object_id, number] }
        controllers + usb.flat_map do |device|
          case device
          in Disk
            id = QemuPlan.usb_stick_id(numbers.fetch(device.object_id))
            ['-drive', "if=none,id=#{id}drive,file=#{device.path},format=raw",
             '-device', "usb-storage,bus=#{bus},drive=#{id}drive,removable=on,id=#{id}"]
          in String then ['-device', "#{device},bus=#{bus}"]
          end
        end
      end
    end
    # The PCIe devices a plan may attach.
    PCIE_DEVICES = %w[qemu-xhci].freeze
    # The USB devices a plan may attach to its controller.
    USB_DEVICES = %w[usb-kbd].freeze
    # As hostlink, no host link at all: one serial line, the console's, as on a machine
    # with one UART, such as the website's emulator (docs/design-fiasco.md, "Device paths").
    NO_HOSTLINK = :none
    # The kernel command line's word that asks the root for the host link's device record
    # (docs/design-fiasco.md, "The command line"). A plan puts it first on the line exactly
    # when it gives the guest the host link's serial line, so the record never names a UART
    # the machine lacks; a caller's line that carries it is refused.
    HOSTLINK_WORD = 'erx.hostlink=1'
    # The longest path a UNIX socket takes on macOS, the primary host: sun_path's 104
    # bytes less the NUL.
    SOCKET_PATH_MAX = 103

    # A raw disk image the guest writes. The board attaches it where its storage goes: a
    # virtio-blk device on QEMU virt's virtio-mmio bus, or the card on a board's SD bus
    # (Machine#card_bus), which takes one. Its path is absolute, so QEMU reads it as a
    # file and never as a protocol prefix such as `nbd:`, and holds no comma, which QEMU
    # reads as the end of an option, and no NUL.
    Disk = Data.define(:path) do
      def initialize(path:)
        unless path.is_a?(String) && path.start_with?('/') && !path.match?(/[\0,]/)
          raise Error, 'a disk image path is absolute and holds no comma'
        end

        super(path: path.dup.freeze)
      end
    end
    # The sizes QEMU's SD card model is given: it takes an image of a power-of-two size up
    # to 2 GiB, a standard-capacity card, and of a multiple of 512 KiB above, a
    # high-capacity one (docs/research-sdhci-qemu-model.md); the harness gives it 2 GiB for
    # a card that fits and 4 GiB for a larger one (docs/design-platforms.md, "The model's SD
    # controller").
    CARD_BYTES = [1 << 31, 1 << 32].freeze

    module_function

    # The QEMU id of a plan's stick number, the first usbstick0 (Pcie#arguments). Pure.
    def usb_stick_id(number) = "usbstick#{number}"

    # The size QEMU's model is given for a card of bytes: the smallest of CARD_BYTES that
    # holds it. Pure.
    def card_bytes(bytes)
      size = CARD_BYTES.find { |candidate| bytes <= candidate }
      raise Error, "a card of #{bytes} bytes is larger than QEMU's SD model is given, #{CARD_BYTES.last} bytes" unless size

      size
    end

    # Copies the card at from to a new file at to, the copy a guest boots and writes,
    # padded with zeros to the model's size (card_bytes). A card ends at its last partition,
    # so a writer copies no more than it holds; the model alone wants it longer, so the
    # harness's copy, and nothing else, is padded. Returns to.
    def card_copy(from, to:)
      bytes = card_bytes(File.size(from))
      FileUtils.cp(from, to)
      File.truncate(to, bytes)
      to
    end

    # The guest's RAM in MiB when a plan names none: the platform record's (Platform#memory_mib).
    def memory_of(platform)
      raise Error, 'a QEMU plan is for a Platform' unless platform.is_a?(Platform)

      platform.memory_mib
    end

    def argv(platform:, accel:, image:, serial:, cpus: 1, memory_mib: memory_of(platform),
             program: 'qemu-system-aarch64', initrd: nil, serial_input: nil, command_line: nil, dtb: nil,
             disks: [], hostlink: nil, nic: nil, stub: nil, firmware: nil, display: nil, pcie: nil, line: nil,
             virtualization: false)
      raise Error, 'accelerator must be tcg or hvf' unless %w[tcg hvf].include?(accel)
      raise Error, 'virtualization is true or false' unless [true, false].include?(virtualization)
      board = machine_of(platform)
      raise Error, 'PCIe functions are a QemuPlan::Pcie' unless pcie.nil? || pcie.is_a?(Pcie)
      raise Error, 'a plan takes a display or PCIe functions, not both' if display && pcie
      if board.loads
        raise Error, "#{board.base} takes no PCIe functions" if pcie
        raise Error, "#{board.base} is not entered at the hypervisor's level" if virtualization

        return loaded_argv(board, accel: accel, image: image, serial: serial, serial_input: serial_input, cpus: cpus, program: program,
                                  stub: stub, firmware: firmware, dtb: dtb, disks: disks, display: display, refused: { initrd: initrd, command_line: command_line, nic: nic, line: line,
                                                                                 hostlink: hostlink == NO_HOSTLINK ? nil : :hostlink })
      end
      raise Error, "platform #{platform.name} boots from no stub" if stub || firmware
      unless cpus.is_a?(Integer) && CPUS.cover?(cpus)
        raise Error, "CPU count must be between #{CPUS.min} and #{CPUS.max}"
      end
      unless memory_mib.is_a?(Integer) && memory_mib.between?(96, 4096)
        raise Error, 'guest memory must be between 96 and 4096 MiB'
      end
      unless disks.is_a?(Array) && disks.size <= MAX_DISKS && disks.all?(Disk)
        raise Error, "disks are up to #{MAX_DISKS} QemuPlan::Disk values"
      end
      raise Error, 'a network device is a QemuPlan::Nic, Relay or UserNet' unless [NilClass, Nic, Relay, UserNet].include?(nic.class)
      raise Error, 'a display is a QemuPlan::Display' unless display.nil? || display.is_a?(Display)
      raise Error, 'a line is a QemuPlan::Line' unless line.nil? || line.is_a?(Line)
      devices = placements(platform, disks: disks, nic: nic, display: display, line: line)
      check_pages(devices)
      # QEMU listens on the socket as soon as it starts, so its directory is checked before.
      Qmp.check_directory(display.qmp_socket) if display && !display.window?
      Qmp.check_directory(pcie.qmp_socket) if pcie
      words = command_line.to_s.split(/ /)
      raise Error, "the plan adds #{HOSTLINK_WORD} with the host link's serial line" if words.include?(HOSTLINK_WORD)

      deterministic = words.include?(DETERMINISTIC_WORD)
      kernel_line = hostlink == NO_HOSTLINK ? command_line : [HOSTLINK_WORD, command_line].reject { |part| part.to_s.empty? }.join(' ')
      if deterministic && (accel != 'tcg' || cpus != 1)
        raise Error, 'deterministic mode runs one CPU under TCG'
      end
      [image, *([CONSOLE, STDIO].include?(serial) ? [] : [serial]), *(dtb ? [dtb] : []), program].each do |value|
        raise Error, 'invalid QEMU path' unless value.is_a?(String) && !value.empty? && !value.include?("\0")
      end

      machine = machine_line(platform, accel: accel, deterministic: deterministic, virtualization: virtualization)
      # `-monitor none` turns off only QEMU's default monitor; CONSOLE's
      # `mon:stdio` brings its own, multiplexed onto the serial line.
      [program, '-machine', machine, '-accel', accel,
       '-cpu', accel == 'hvf' ? 'host' : 'cortex-a76',
       '-smp', cpus.to_s, *(deterministic ? DETERMINISTIC_ARGUMENTS : []), '-m', memory_mib.to_s,
       '-display', display&.window? ? 'default' : 'none', '-monitor', 'none', '-nic', 'none',
       *(devices.empty? ? [] : DISK_TRANSPORT_ARGUMENTS), *disk_arguments(disks), *nic_arguments(nic),
       *device_arguments(devices), *line&.arguments, *qmp_arguments(qmp_socket(display) || pcie&.qmp_socket),
       *pcie&.arguments,
       '-no-reboot', *serial_arguments(serial, serial_input), *hostlink_arguments(hostlink),
       '-kernel', image,
       *(initrd ? ['-initrd', initrd] : []), *(kernel_line ? ['-append', kernel_line] : []),
       *(dtb ? ['-dtb', dtb] : [])].freeze
    end

    # The -machine value for platform's board under accel, in deterministic mode or not,
    # and with the guest entered at the hypervisor's level (QEMU's virtualization=on) for a
    # guest that needs it (GenodeBuild::MACHINE).
    def machine_line(platform, accel:, deterministic:, virtualization: false)
      machine = machine_of(platform)
      [machine.base, *(accel == 'tcg' ? machine.tcg_options : []), *(deterministic ? machine.deterministic_options : []),
       *(virtualization ? ['virtualization=on'] : [])].join(',')
    end

    def machine_of(platform)
      raise Error, 'a QEMU plan is for a Platform' unless platform.is_a?(Platform)

      MACHINES.fetch(platform.name) { raise Error, "QEMU has no machine for platform #{platform.name}" }
    end

    # A board QEMU starts through its loader (Machine#loads), as its firmware would: under TCG,
    # the model's own RAM and no -kernel, -m or -cpu; the stub, image and device tree where the
    # firmware would put them, the tree carrying the kernel command line; the console on
    # QEMU's second serial port, the first going to the null device; and no host link UART,
    # which the Raspberry Pi 4's model does not have (UART3). A disk is the card on the
    # board's SD bus, which takes one. A display is QMP on its socket alone: the board's own
    # framebuffer is the screen, and the record's display unit is not used. firmware, a
    # test harness's ELF such as the raspi4b suite's firmware framebuffer stand-in
    # (Raspi4bFirmwareFb), is where CPU 0 starts instead of the stub, which it enters when done.
    # refused holds what such a plan cannot take, each nil when the plan does not ask for it.
    def loaded_argv(board, accel:, image:, serial:, serial_input:, cpus:, program:, stub:, firmware:, dtb:, disks:, display:, refused:)
      raise Error, 'disks are QemuPlan::Disk values' unless disks.is_a?(Array) && disks.all?(Disk)
      raise Error, "#{board.base} takes no disk" unless disks.empty? || board.card_bus
      raise Error, "#{board.base} takes one disk, its SD card" if disks.size > 1
      raise Error, "#{board.base} runs under TCG alone" unless accel == 'tcg'
      asked = refused.compact.keys
      raise Error, "#{board.base} takes no #{asked.join(', ')}" unless asked.empty?
      raise Error, "CPU count must be between #{CPUS.min} and #{CPUS.max}" unless cpus.is_a?(Integer) && CPUS.cover?(cpus)

      raise Error, 'a display is a QemuPlan::Display' unless display.nil? || display.is_a?(Display)

      [image, stub, dtb, program, *firmware].each do |value|
        raise Error, 'invalid QEMU path' unless value.is_a?(String) && !value.empty? && !value.match?(/[\0,]/)
      end
      Qmp.check_directory(display.qmp_socket) if display
      # The ELF the loader takes with cpu-num, at its own addresses, starting CPU 0 at its entry.
      first = firmware ? [[firmware, nil, ',cpu-num=0']] : []
      loads = [*first, [stub, board.loads.stub, firmware ? '' : ',cpu-num=0'], [image, board.loads.image, ''], [dtb, board.loads.dtb, '']]
      [program, '-machine', board.base, '-accel', accel, '-smp', cpus.to_s,
       *board.globals.flat_map { |global| ['-global', global] },
       '-display', 'none', '-monitor', 'none', '-no-reboot',
       '-serial', 'null', *serial_arguments(serial, serial_input, id: 'console'),
       *loads.flat_map { |file, address, options| ['-device', "loader,file=#{file}#{address && format(',addr=0x%x', address)}#{options}"] },
       *card_arguments(disks.first, bus: board.card_bus), *qmp_arguments(qmp_socket(display))].freeze
    end

    # A disk as the card on the board's SD bus, its drive with no front end of its own, or
    # nothing without one; never the id sd0, which the model's own card holds.
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

    # The network device's backends (Nic, Relay or UserNet), or nothing.
    def nic_arguments(nic)
      case nic
      in nil then []
      in Relay then relay_arguments(nic)
      in UserNet then ['-netdev', "user,id=nic_user,hostfwd=tcp:127.0.0.1:#{nic.forward.host}-:#{nic.forward.guest}"]
      in Nic then link_arguments(nic)
      end
    end

    # A Relay's user networking, with its one `cmd:` guest forward, on the hub the device
    # joins.
    def relay_arguments(relay)
      ['-netdev', "user,id=nic_user,restrict=on,net=#{relay.network}," \
                  "guestfwd=tcp:#{relay.address}:#{relay.port}-cmd:nc 127.0.0.1 #{relay.relay_port}",
       '-netdev', 'hubport,id=nic_hub_user,hubid=0,netdev=nic_user',
       '-netdev', 'hubport,id=nic_hub_guest,hubid=0']
    end

    # A Nic's user networking and its frames link to the harness, on one hub.
    def link_arguments(nic)
      loopback = '127.0.0.1'
      host_forward = nic.forward ? ",hostfwd=tcp:#{loopback}:#{nic.forward.host}-:#{nic.forward.guest}" : ''
      ['-netdev', "user,id=nic_user,restrict=on,domainname=#{NIC_DOMAIN}," \
                  "guestfwd=tcp:#{NIC_ECHO_ADDRESS}:#{NIC_ECHO_PORT}-tcp:#{loopback}:#{nic.echo_port}#{host_forward}",
       '-netdev', "dgram,id=nic_frames,local.type=inet,local.host=#{loopback},local.port=#{nic.frames_port}," \
                  "remote.type=inet,remote.host=#{loopback},remote.port=#{nic.peer_port}",
       '-netdev', 'hubport,id=nic_hub_user,hubid=0,netdev=nic_user',
       '-netdev', 'hubport,id=nic_hub_frames,hubid=0,netdev=nic_frames',
       '-netdev', 'hubport,id=nic_hub_guest,hubid=0']
    end

    # The backend the guest's network device joins: Nic's hub port, or UserNet's user network itself.
    def nic_guest_netdev(nic) = nic.is_a?(UserNet) ? 'nic_user' : 'nic_hub_guest'

    # The display's QMP socket: nil with no display, or one in a window.
    def qmp_socket(display) = display && !display.window? ? display.qmp_socket : nil

    # QMP on socket, or nothing when it is nil.
    def qmp_arguments(socket)
      socket ? ['-qmp', "unix:#{socket},server=on,wait=off"] : []
    end

    # Every virtio device of a plan on the transport platform's record names for it: the
    # disks from the block unit's down, the network device, the display's three and the
    # line's console. The -device arguments and the page check both read this one list, so
    # no device reaches QEMU on a bus the check did not see.
    def placements(platform, disks:, nic:, display:, line:)
      first_disk = disks.empty? ? nil : transport_of(platform, key: 'block', role: 'block')
      [*disks.each_index.map do |index|
         Placement.new(unit: 'block', bus: first_disk - index, device: "virtio-blk-device,drive=disk#{index}")
       end,
       *(nic ? [Placement.new(unit: 'net', bus: transport_of(platform, key: 'net', role: 'network'),
                              device: "virtio-net-device,netdev=#{nic_guest_netdev(nic)}")] : []),
       *(display ? display_placements(platform) : []),
       *(line ? [Placement.new(unit: 'line', bus: transport_of(platform, key: 'line', role: 'serial'),
                               device: "virtio-serial-device,id=#{LINE_SERIAL_ID}")] : [])]
    end

    # The bus of the one device of role in platform's unit key.
    def transport_of(platform, key:, role:) = transport_bus(unit_devices(platform, key, role: role, count: 1).first)

    # The display's three devices, all in the display unit, by the role the harness gives
    # each: the unit's gpu device, and of its two input devices the keyboard at the higher
    # address and the tablet below it.
    def display_placements(platform)
      keyboard, tablet = unit_devices(platform, 'display', role: 'input', count: 2)
      gpu = unit_devices(platform, 'display', role: 'gpu', count: 1).first
      [['virtio-gpu-device', gpu], ['virtio-keyboard-device', keyboard], ['virtio-tablet-device', tablet]].map do |device, held|
        Placement.new(unit: 'display', bus: transport_bus(held), device: device)
      end
    end

    # The count devices of role in platform's unit key, highest address first, or Error.
    def unit_devices(platform, key, role:, count:)
      unit = platform.record.fetch('units').find { |candidate| candidate.fetch('key') == key }
      devices = unit ? unit.fetch('devices').select { |device| device.fetch('role') == role } : []
      unless devices.size == count
        raise Error, "platform #{platform.name}'s #{key} unit has #{devices.size} #{role} devices, not #{count}"
      end

      devices.sort_by { |device| -device.fetch('base') }
    end

    # The virtio-mmio-bus number of the transport whose register window is device's.
    def transport_bus(device) = (device.fetch('base') - VIRTIO_MMIO_BASE) / VIRTIO_MMIO_STRIDE
    private_class_method :transport_of, :display_placements, :transport_bus

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
        format('0x%08x (%s)', VIRTIO_MMIO_BASE + (page * REGISTER_PAGE), held.map(&:unit).uniq.join(', '))
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
  # raises Erx::Error when that line's content must fail the boot, with, as
  # verify_seconds, the longest it may spend, which the run's deadline adds
  # since no checkpoint's own time counts it; and bytes the harness types into
  # the guest's serial line once that line has come.
  #
  # The console writes a log line whole wherever it lands, in the middle of a
  # program's line too (docs/design-live.md, "Log lines and program output"). So
  # the matcher reads a line that ends in a log line as two: the log line is a
  # line of its own, and the bytes before it, the head, go back in front of the
  # unread bytes to join what is written after the log line. Checkpoints then see
  # the program's lines as if no log line had been written, and each log line
  # whole from its start, however many land and wherever. A line that carries
  # Fiasco's warning that a call overwrote an unanswered caller's reply fails the
  # boot (REPLY_OVERWRITTEN).
  class Transcript
    MAX_LINE_BYTES = 65_536
    # A log line as the console writes it, at the end of a line: a kernel record,
    # "#SEQ SECONDS.MICROSECONDS LEVEL TEXT" (kernel/core/log.c), or a domain's,
    # "SECONDS.MICROSECONDS LEVEL domain ID principal P NAME: TEXT" (erx_syslog_core).
    LOG_LINE_END = /(?:\#[0-9]+ [0-9]+\.[0-9]{6} [a-z]+ |[0-9]+\.[0-9]{6} [a-z]+ domain [0-9]+ principal )[^\n]*\n\z/n
    # Fiasco warns this way (fiasco/kernel/src/kern/receiver.cpp, set_reply_cap) when a
    # thread receives a call while its reply slot still holds an earlier caller. The
    # root's service does so only once its table of faults is full
    # (liberx/backend/fiasco/reply_slots.h). Until the console's driver takes the UART the
    # warning goes to it raw from a newline, splitting whatever line it lands in where no
    # checkpoint can rejoin it; from then on it arrives as a kernel record, its text
    # escaped (docs/design-fiasco.md, "The kernel's lines"). The pattern is not anchored,
    # so it finds the warning in either form.
    REPLY_OVERWRITTEN = /Application bug: reply capability overwritten!/n
    REQUIRED_KEYS = %i[name pattern seconds].freeze
    OPTIONAL_KEYS = %i[verify verify_seconds type].freeze
    TTY_MAX_INPUT = ABI::Generated.constant('tty_max_input')
    attr_reader :observed

    def initialize(checkpoints:)
      unless checkpoints.is_a?(Array) && !checkpoints.empty? &&
             checkpoints.all? { |point| point.is_a?(Hash) && checkpoint_keys?(point) }
        raise Error, 'invalid transcript checkpoint plan'
      end
      names = checkpoints.map { |point| point.fetch(:name) }
      raise Error, 'duplicate transcript checkpoint name' unless names.uniq == names
      raise Error, 'invalid transcript checkpoint' unless checkpoints.all? { |point| valid_checkpoint?(point) }

      checkpoints.each { |point| check_typed_room(point) }
      @checkpoints = checkpoints.map(&:dup).each(&:freeze).freeze
      @observed = []
      @pending = ''.b
      # The bytes at the front of @pending that are a head already searched for a log line.
      @head_bytes = 0
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

    # What one checkpoint types reaches the guest's console at once, ahead of whoever reads
    # it, and may all wait there unread in a tty, which holds at most TTY_MAX_INPUT bytes,
    # a cooked line's last one kept for its end, and drops the rest (erx_tty). A string
    # that could not fit is refused before the boot, not lost in it; the bound kept is one
    # byte short of the tty's, so it holds whether or not the string ends a line.
    def check_typed_room(point)
      typed = point.fetch(:type, '').bytesize
      return if typed < TTY_MAX_INPUT

      raise Error, "checkpoint #{point.fetch(:name)} types #{typed} bytes at once, and the console's tty holds fewer than " \
                   "#{TTY_MAX_INPUT} unread (tty_max_input); type it in parts the reader takes one at a time"
    end

    def checkpoint_keys?(point)
      (REQUIRED_KEYS - point.keys).empty? && (point.keys - REQUIRED_KEYS - OPTIONAL_KEYS).empty?
    end

    def valid_checkpoint?(point)
      point.fetch(:name).is_a?(String) && !point.fetch(:name).empty? &&
        point.fetch(:pattern).is_a?(Regexp) &&
        point.fetch(:seconds).is_a?(Integer) && point.fetch(:seconds).positive? &&
        point.fetch(:verify, -> {}).respond_to?(:call) &&
        point.fetch(:type, '').is_a?(String) &&
        point.fetch(:verify_seconds, 1).is_a?(Integer) && point.fetch(:verify_seconds, 1).positive?
    end

    # The log line that line ends in, with its head put back in front of @pending, or
    # line itself when it ends in none. The search starts past the head line carries
    # from an earlier split, which holds no log line, so a long head that many log
    # lines interrupt is searched once.
    def log_line_alone(line)
      start = @head_bytes
      @head_bytes = 0
      log_line = LOG_LINE_END.match(line, start)
      return line if log_line.nil? || log_line.pre_match.empty?

      @pending.prepend(log_line.pre_match)
      @head_bytes = log_line.pre_match.bytesize
      log_line[0]
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
        raise Error, "the kernel warned that a call overwrote an unanswered caller's reply" if REPLY_OVERWRITTEN.match?(line)
        next if done?
        line = log_line_alone(line)
        point = @checkpoints.fetch(@observed.size)
        next unless point.fetch(:pattern).match?(line)

        # The next point is due from when the verify returned, however long it read.
        verified = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        point[:verify]&.call(line)
        elapsed += Process.clock_gettime(Process::CLOCK_MONOTONIC) - verified
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

    # The serial log of a boot run in directory, which a checkpoint's verify may read while
    # the guest runs.
    def self.serial_log(directory) = File.join(directory, 'serial.log')

    # remote_clock is the clock a remote boot waits on (QemuRemote::Clock).
    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   program: 'qemu-system-aarch64', initrd: nil, remote_clock: QemuRemote::Clock)
      @root = File.expand_path(root)
      @runner = runner
      @program = program
      @remote_clock = remote_clock
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
    # its boot stub, BL31 with its header patched (Bl31.patch_stub). firmware, on such a board,
    # is a test harness's ELF where CPU 0 starts before the stub (QemuPlan.loaded_argv); a boot
    # with one is never reused and never remote.
    #
    # display, a QemuPlan::Display, attaches the guest's display devices and QMP on its
    # socket, which a checkpoint's verify may read the screen through (Qmp). Its socket must
    # lie in an owner-only directory the caller made (Qmp.check_directory), such as the run's
    # directory passed as directory. A boot with a display is never reused: what the screen
    # showed is not in its serial log.
    #
    # line, a QemuPlan::Line, joins the Bluetooth controller's line to a controller the
    # caller serves on a loopback TCP port, which must listen before the run starts. A boot
    # with a line is never reused, since that controller's answers are not QEMU's inputs,
    # and never remote, since the remote host cannot reach the port.
    #
    # Inside the QEMU gate (QemuReuse.active), a boot that passed before on
    # the same inputs does not start QEMU: its stored serial log is written to
    # the run's serial log and replayed, and the report names it under
    # 'reused_from'.
    #
    # With remote, a QemuRemote::Host, QEMU runs on that host (QemuRemote::Run), detached
    # from ssh, and short polls copy its serial line into the run's serial log, which the
    # transcript judges by the times that host wrote each byte. Only a boot
    # that QEMU's inputs alone determine runs there: no disk, network device or host link
    # session. A host that cannot be reached, refuses the boot's setup, or is lost for good
    # during the boot raises QemuRemote::Unreachable.
    def run(platform:, accel:, image:, cpus: 1, memory_mib: QemuPlan.memory_of(platform), checkpoints: nil, initrd: nil, machine_end: false, directory: nil, command_line: nil,
            dtb: nil, disks: [], link: nil, link_seconds: 0, hostlink: nil, nic: nil, remote: nil, stub: nil, firmware: nil, display: nil,
            pcie: nil, line: nil, virtualization: false)
      # Every input of this run by its parameter's name, from this class's own signature,
      # read before the body reassigns any.
      inputs = Qemu.instance_method(:run).parameters.to_h { |_, name| [name, binding.local_variable_get(name)] }
      host = self.class.host_inputs(inputs)
      raise Error, 'a run with a host link session ends when the session does, not with machine_end' if link && machine_end
      raise Error, 'a run with a host link session takes no other host link plan' if link && hostlink
      raise Error, "a remote boot takes no #{host.join(', ')}" if remote && !host.empty?
      raise Error, 'a remote boot takes no boot stub' if remote && stub

      checkpoints ||= self.class.boot_transcript(memory_mib: memory_mib)
      image = File.expand_path(image)
      raise Error, "guest image does not exist: #{image}" unless File.file?(image)
      matcher = Transcript.new(checkpoints: checkpoints)
      deadline = checkpoints.sum { |point| point.fetch(:seconds) + point.fetch(:verify_seconds, 0) } + link_seconds + 5
      directory ||= File.join(@root, 'build/qemu', "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
      directory = OutputDirectory.prepare(root: @root, path: directory, mode: 0o700)
      serial = Qemu.serial_log(directory)
      # Emptied before QEMU starts, so the transcript reads this boot's lines alone, never
      # an earlier run's in a directory the caller reuses.
      File.write(serial, '', perm: 0o600)
      socket = link && File.join(directory, 'hostlink.sock')
      keyboard = matcher.types? ? File.join(directory, 'keyboard') : nil
      remote_run = remote && QemuRemote::Run.new(boot: QemuRemote::Boot.new(host: remote), runner: @runner, clock: @remote_clock,
                                                 directory: directory)
      remote_boot = remote_run&.boot
      plan = { platform: platform, accel: accel, cpus: cpus, memory_mib: memory_mib, program: remote_boot ? remote.program : @program,
               command_line: command_line, virtualization: virtualization }
      argv = if remote_boot
               QemuPlan.argv(**plan, image: remote_boot.path('image'), serial: remote_boot.serial, serial_input: remote_boot.keyboard,
                                     initrd: initrd && remote_boot.path('initrd'), dtb: dtb && remote_boot.path('dtb'), hostlink: hostlink)
             else
               QemuPlan.argv(**plan, image: image, serial: serial, serial_input: keyboard, initrd: initrd, dtb: dtb,
                                     disks: disks, hostlink: socket || hostlink, nic: nic, stub: stub, firmware: firmware, display: display,
                                     pcie: pcie, line: line)
             end
      report = { 'state' => 'running', 'image_sha256' => Digest::SHA256.file(image).hexdigest,
                 'argv' => argv, 'checkpoints' => matcher.observed, 'serial_log' => serial }
      report['remote'] = remote.destination if remote
      reuse = QemuReuse.active
      key = nil
      if reuse && host.empty?
        key = boot_key(reuse, plan: plan, remote_run: remote_run, image_sha256: report.fetch('image_sha256'), typed: matcher.types?, initrd: initrd,
                              dtb: dtb, stub: stub, hostlink: hostlink, checkpoints: checkpoints, machine_end: machine_end)
        stored = stored_boot(reuse, key, report: report, checkpoints: checkpoints, directory: directory) if key
        return stored if stored
      end
      reuse&.ran
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      typing = nil
      session = nil
      begin
        typing = keyboard && (remote_run ? remote_run.keyboard : open_keyboard(keyboard))
        version = if remote_run
                    remote_run.upload({ 'image' => image, 'initrd' => initrd, 'dtb' => dtb }.compact)
                    remote_run.version
                  else
                    @runner.run([@program, '--version'], name: 'qemu-version', deadline: 10)
                  end
        report['qemu_version'] = File.binread(version.fetch('log')).lines.first.to_s.strip
        guest_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        # guest_seconds is how long the guest had run when the serial log held what it holds.
        stop_guest = lambda do |guest_seconds|
          transcript_whole = matcher.consume(serial, elapsed: guest_seconds)
          typing&.write(matcher.take_typed)
          next transcript_whole && !machine_end unless link

          session ||= start_link(link, socket) if transcript_whole
          !session.nil? && !session.alive?
        end
        record = if remote_run
                   remote_run.run(argv, deadline: deadline, serial: serial, stop: stop_guest)
                 else
                   @runner.run(argv, name: "qemu-#{accel}", deadline: deadline, success: ->(_log) { stop_guest.call(elapsed(guest_started)) })
                 end
        report['link'] = session.value if session
        # A remote boot's log was judged on the remote host's clock, up to its last sample.
        matcher.drain(serial, elapsed: remote_run ? remote_run.guest_seconds.to_i : elapsed(guest_started))
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
        remote_run.cleanup if remote_run&.prepared?
        report['state'] = 'cancelled' if report['state'] == 'running'
        report['elapsed_seconds'] = elapsed(started)
        File.write(File.join(directory, 'report.json'), JSON.pretty_generate(report) + "\n")
      end
      report
    end

    # The inputs of #run that QEMU's inputs alone determine, by parameter name, each with
    # the values it may take in a boot QemuReuse may reuse or run remotely: each is in the
    # boot's key (boot_key) or touches no guest input (directory, the run's own output, and
    # link_seconds, its deadline). The host link is QEMU's null device or none, never a
    # socket a host side serves. Every other input is the host's: a disk the guest may
    # write, a network device, a display a checkpoint reads, a line whose controller
    # answers from the host, a host link session, PCIe functions, test firmware, and any
    # input added to #run until it is listed here.
    DETERMINED_INPUTS = {
      platform: :any, accel: :any, image: :any, cpus: :any, memory_mib: :any, checkpoints: :any, initrd: :any,
      machine_end: :any, directory: :any, command_line: :any, dtb: :any, link_seconds: :any, remote: :any, stub: :any,
      virtualization: :any,
      hostlink: [QemuPlan::NO_HOSTLINK]
    }.freeze

    # The names of the inputs, a run's parameters by name, that the host gives this boot:
    # each one given (not nil, nor an empty list of disks) that DETERMINED_INPUTS does not list with
    # its value. A boot with none is QemuReuse's to reuse and may run remotely.
    def self.host_inputs(inputs) = inputs.reject { |name, value| absent?(value) || determined?(name, value) }.keys

    def self.absent?(value) = value.nil? || value == []

    def self.determined?(name, value)
      allowed = DETERMINED_INPUTS.fetch(name, [])
      allowed == :any || allowed.include?(value)
    end
    private_class_method :absent?, :determined?

    private

    # The boot's key. The keyed plan is the boot's own (plan, as run passes it
    # to QemuPlan.argv) with each input file by its SHA-256 and the run's own
    # paths by fixed names. Nil, so the boot runs, when QEMU, an initrd, a
    # device tree or a boot stub is not a file.
    def boot_key(reuse, plan:, remote_run:, image_sha256:, typed:, initrd:, dtb:, stub:, hostlink:, checkpoints:, machine_end:)
      qemu = remote_run ? remote_run.identity : QemuReuse.qemu_identity(@program)
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
