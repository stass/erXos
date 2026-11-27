# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'pcie_domain'

module Erx
  # The QEMU harness's fault control (docs/design-recovery.md, "Fault injection and tests",
  # layer 3): the closed set of fault kinds a cell may inject into a running guest, each with
  # its action. A cell declares the faults it injects with its other facts, as
  # [[:unplug, { device: 'usb-stick0' }], [:kill_domain, { domain: 'usb@erxos' }]];
  # Faults.declare checks the declaration whole before QEMU starts and answers a Declaration,
  # from which the boot's needs are derived (needs_qmp?), so nothing is said twice. The cell's
  # steps then inject through an Injector, which refuses a fault the cell did not declare and
  # keeps the list of what it injected for the cell's record.
  #
  # Every action stays inside the guest the cell started: a QMP command to that QEMU, a line
  # typed at that guest's shell, or the end of that QEMU's process. No kind names a host path,
  # host process or host network, and every Fault checks its targets when it is made, so no
  # target reaches a command or a typed line unchecked.
  module Faults
    # A declaration, a target or an injection that the fault control refuses.
    class Refused < Error; end

    # A fault kind: its name, the targets a declaration gives it, its status, and its action.
    # Only a :ready kind may be declared: its action is the tree's own, or the probe has shown
    # it on the pinned QEMU. An :unverified kind rests on QEMU's interface as remembered,
    # until the probe shows it; an :unwritten kind is a relay of our own not yet written.
    Kind = Data.define(:name, :targets, :status, :action)

    # A QEMU device or drive id; a link's target is its NIC's device id.
    QEMU_ID = /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/
    # A domain's node, NAME@HOST, as erx_domain_core names it.
    NODE = /\A[a-z][a-z0-9_]{0,31}@[a-z][a-z0-9.-]{0,63}\z/
    # The form of each target a :ready kind takes.
    TARGETS = { device: QEMU_ID, drive: QEMU_ID, nic: QEMU_ID, domain: NODE }.freeze

    KINDS = [
      # QMP device_del: the device leaves its bus, as a hand pulls it out.
      Kind.new(name: :unplug, targets: %i[device], status: :ready, action: :device_del),
      # QMP eject, forced: the medium leaves its drive; the device stays.
      Kind.new(name: :eject, targets: %i[drive], status: :ready, action: :eject),
      # The domain's ready incarnations killed from the guest's Erlang shell, found as the
      # domain suites find them (PcieDomain::WAIT).
      Kind.new(name: :kill_domain, targets: %i[domain], status: :ready, action: :typed_kill),
      # QEMU's process ended at once, as the block-device suite's power cut ends it.
      Kind.new(name: :power_cut, targets: [], status: :ready, action: :end_machine),
      # A relay the harness owns between a socket chardev and its peer.
      *%i[line_silent line_late line_garbage line_cut].map do |name|
        Kind.new(name: name, targets: %i[chardev], status: :unwritten, action: :relay)
      end,
      # The same relay on a socket or datagram network backend.
      *%i[net_drop net_silent].map { |name| Kind.new(name: name, targets: %i[netdev], status: :unwritten, action: :relay) },
      # QMP set_link on the NIC's device id: the guest sees its carrier go and come back; the
      # probe showed both on QEMU 11.1.3 (Erx::FaultProbe).
      Kind.new(name: :link_down, targets: %i[nic], status: :ready, action: :link_down),
      Kind.new(name: :link_up, targets: %i[nic], status: :ready, action: :link_up),
      # QEMU's blkdebug block driver, its rules set when the drive is created; not probed.
      Kind.new(name: :block_error, targets: %i[drive op nth], status: :unverified, action: :blkdebug),
      # QMP block_set_io_throttle: the probe showed a read held and answered at the lift, but
      # not whether it stays held across the guest's reset of the device.
      Kind.new(name: :block_stall, targets: %i[device], status: :unverified, action: :throttle),
      # QMP chardev-change to a null backend and back: the probe showed it, but the lift's
      # socket is a host path no target form here admits yet.
      Kind.new(name: :chardev_stop, targets: %i[chardev], status: :unverified, action: :chardev)
    ].to_h { |kind| [kind.name, kind] }.freeze

    # One fault: a :ready kind's name and its targets, each a String of its target's form.
    # Its constructor refuses anything else, so every Fault that exists is checked.
    Fault = Data.define(:kind, :target) do
      def initialize(kind:, target:)
        known = KINDS[kind] or raise Refused, "#{kind.inspect} is not a fault kind (#{KINDS.keys.join(', ')})"
        Faults.refuse_unready(known)
        unless target.is_a?(Hash) && target.keys.sort == known.targets.sort
          raise Refused, "#{kind} takes #{known.targets.empty? ? 'no targets' : known.targets.join(', ')}, " \
                         "not #{target.inspect.byteslice(0, 80)}"
        end

        super(kind: kind, target: target.to_h { |key, value| [key, Faults.target_value(kind, key, value)] }.freeze)
      end

      def to_s = [kind, *target.map { |key, value| "#{key}=#{value}" }].join(' ')
    end

    # A cell's checked declaration: its faults, in the cell's order.
    Declaration = Data.define(:faults) do
      # Whether the boot needs a QMP socket for the faults' actions.
      def needs_qmp? = faults.any? { |fault| Faults.action(fault).is_a?(QmpCommand) }
    end

    # What an injection does, a value the effect layer runs: a QMP command by its Erx::Qmp
    # method and arguments, a line typed at the guest's shell, or QEMU's process ended.
    QmpCommand = Data.define(:command, :arguments, :keywords) do
      def initialize(command:, arguments:, keywords: {}) = super
    end
    TypedLine = Data.define(:line)
    EndMachine = Data.define
    # The answer kill_line prints when it killed at least one incarnation.
    KILLED = /\{fault_killed,[1-9][0-9]*\}/

    module_function

    # The declaration of entries, each [kind] or [kind, targets]; refuses an unknown kind, a
    # kind that is not :ready, a missing, extra or malformed target, and a fault declared twice.
    def declare(entries)
      raise Refused, 'a fault declaration is a list of [kind, targets] entries' unless entries.is_a?(Array)

      faults = entries.map do |entry|
        case entry
        in [Symbol => kind] then Fault.new(kind: kind, target: {})
        in [Symbol => kind, Hash => target] then Fault.new(kind: kind, target: target)
        else raise Refused, "a fault is [kind, targets], not #{entry.inspect.byteslice(0, 80)}"
        end
      end
      twice = faults.tally.find { |_fault, count| count > 1 }
      raise Refused, "fault declared twice: #{twice.first}" if twice

      Declaration.new(faults: faults.freeze)
    end

    # The action of fault.
    def action(fault)
      case [KINDS.fetch(fault.kind).action, fault.target]
      in [:device_del, { device: }] then QmpCommand.new(command: :device_del, arguments: [device])
      in [:eject, { drive: }] then QmpCommand.new(command: :eject, arguments: [drive])
      in [:link_down, { nic: }] then QmpCommand.new(command: :set_link, arguments: [nic], keywords: { up: false })
      in [:link_up, { nic: }] then QmpCommand.new(command: :set_link, arguments: [nic], keywords: { up: true })
      in [:typed_kill, { domain: }] then TypedLine.new(line: kill_line(domain))
      in [:end_machine, _] then EndMachine.new
      end
    end

    # The line typed at the guest's Erlang shell that kills every ready incarnation of the
    # domain whose node is domain and prints {fault_killed, N}. It runs in a fun of its own,
    # so it binds nothing in the shell and can be typed again.
    def kill_line(domain)
      "(fun()->#{PcieDomain::WAIT.first}," \
        "io:format(\"~0kp~n\",[{fault_killed,length([exit(P,kill)||\#{pid:=P}<-PcFind('#{domain}')])}]) end)().\r"
    end

    # Refuses a kind that is not :ready, saying why.
    def refuse_unready(kind)
      case kind.status
      in :ready then nil
      in :unverified then raise Refused, "#{kind.name} is unverified: the probe's record does not show all it needs"
      in :unwritten then raise Refused, "#{kind.name} is unwritten: its relay is not written"
      end
    end

    # value as the String a target of kind takes; refuses one not of the target's form.
    def target_value(kind, key, value)
      text = value.to_s if value.is_a?(String) || value.is_a?(Symbol)
      return text.dup.freeze if text && TARGETS.fetch(key).match?(text)

      raise Refused, "#{kind}'s #{key} #{value.inspect.byteslice(0, 80)} is not one it takes"
    end

    # The effect layer: injects a cell's declared faults into the machine it started, through
    # qmp (an Erx::Qmp connected to that QEMU, or nil when the declaration needs none), type
    # (a callable that types a line at the guest's shell and answers the line the guest
    # printed for it) and cut (a callable that ends that QEMU's process at once). It keeps
    # every fault it injected or tried to, in order, for the cell's record.
    class Injector
      attr_reader :injected

      def initialize(declaration, qmp:, type:, cut:)
        raise Refused, 'the declared faults need a QMP connection' if declaration.needs_qmp? && qmp.nil?

        @declaration = declaration
        @qmp = qmp
        @type = type
        @cut = cut
        @injected = []
      end

      # Injects the declared fault of kind with targets; refuses one the cell did not declare.
      def inject(kind, **target)
        fault = Fault.new(kind: kind, target: target)
        raise Refused, "#{fault} is not among the cell's declared faults" unless declared?(fault)

        @injected << fault
        run(fault, Faults.action(fault))
      end

      # The cell's record of its faults: what it injected, one line each.
      def record = @injected.map(&:to_s)

      private

      def declared?(fault) = @declaration.faults.include?(fault)

      # The guest's answer to a typed kill is read only against KILLED, never shown.
      def run(fault, action)
        case action
        in QmpCommand[command:, arguments:, keywords:] then @qmp.public_send(command, *arguments, **keywords)
        in TypedLine[line:]
          answer = @type.call(line)
          raise Refused, "#{fault} killed nothing" unless answer.is_a?(String) && KILLED.match?(answer)

          answer
        in EndMachine then @cut.call
        end
      end
    end
  end
end
