# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'pcie_domain'

module Erx
  # The QEMU harness's fault control (docs/design-recovery.md, "Fault injection and tests",
  # layer 3): the closed set of fault kinds a cell may inject into a running guest, each with
  # its action. A cell declares the faults it injects with its other facts, as
  # [[:unplug, device: 'usb-stick0'], [:kill_domain, domain: 'usb']]; Faults.declare checks
  # the declaration whole before QEMU starts and answers a Declaration, from which the boot's
  # needs are derived (needs_qmp?), so nothing is said twice. The cell's steps then inject
  # through an Injector, which refuses a fault the cell did not declare and keeps the list of
  # what it injected for the cell's record.
  #
  # Every action stays inside the guest the cell started: a QMP command to that QEMU, a line
  # typed at that guest's shell, or the end of that QEMU's process. No kind names a host path,
  # host process or host network, and every target is a short name of the cell's own, checked
  # against NAME before it reaches a command or a typed line.
  module Faults
    # A declaration, a target or an injection that the fault control refuses.
    class Refused < Error; end

    # A fault kind: its name, the targets a declaration gives it (each a key of TARGETS), its
    # status, and its action, a key of ACTIONS. Only a :ready kind may be declared: its
    # action is the tree's own, or the probe has shown it on the pinned QEMU. An :unverified
    # kind rests on QEMU's interface as remembered, until the probe shows it; an :unwritten
    # kind is a relay of our own not yet written.
    Kind = Data.define(:name, :targets, :status, :action)
    STATUSES = %i[ready unverified unwritten].freeze

    # A target's name: a QEMU device, drive or netdev id, or a domain's node name.
    NAME = /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/
    A_NAME = ->(value) { (value.is_a?(String) || value.is_a?(Symbol)) && NAME.match?(value.to_s) }
    # Whether a value is one each target takes.
    TARGETS = {
      device: A_NAME, drive: A_NAME, netdev: A_NAME, chardev: A_NAME, domain: A_NAME,
      op: ->(value) { %i[read write flush].include?(value) },
      nth: ->(value) { value.is_a?(Integer) && value.between?(1, 1_000_000) }
    }.freeze

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
      # QMP set_link.
      Kind.new(name: :link_down, targets: %i[netdev], status: :unverified, action: :set_link),
      Kind.new(name: :link_up, targets: %i[netdev], status: :unverified, action: :set_link),
      # QEMU's blkdebug block driver, its rules set when the drive is created.
      Kind.new(name: :block_error, targets: %i[drive op nth], status: :unverified, action: :blkdebug),
      Kind.new(name: :block_stall, targets: %i[drive], status: :unverified, action: :blkdebug),
      # QMP's chardev change or removal.
      Kind.new(name: :chardev_stop, targets: %i[chardev], status: :unverified, action: :chardev)
    ].to_h { |kind| [kind.name, kind] }.freeze

    # The actions a :ready kind may have, and whether each speaks QMP.
    QMP_ACTIONS = %i[device_del eject].freeze

    # One declared fault: its kind's name and its targets, a frozen Hash.
    Fault = Data.define(:kind, :target) do
      def to_s = [kind, *target.map { |key, value| "#{key}=#{value}" }].join(' ')
    end

    # A cell's checked declaration: its faults, in the cell's order.
    Declaration = Data.define(:faults) do
      # Whether the boot needs a QMP socket for the faults' actions.
      def needs_qmp? = faults.any? { |fault| QMP_ACTIONS.include?(KINDS.fetch(fault.kind).action) }
    end

    # What an injection does, a value the effect layer runs: a QMP command by its Erx::Qmp
    # method and arguments, a line typed at the guest's shell, or QEMU's process ended.
    QmpCommand = Data.define(:method, :arguments)
    TypedLine = Data.define(:line)
    EndMachine = Data.define

    module_function

    # The declaration of entries, each [kind, **targets]; refuses an unknown kind, a kind
    # that is not :ready, a missing, extra or malformed target, and a fault declared twice.
    def declare(entries)
      raise Refused, 'a fault declaration is a list of [kind, targets] entries' unless entries.is_a?(Array)

      faults = entries.map { |entry| fault(entry) }
      twice = faults.tally.select { |_fault, count| count > 1 }.keys
      raise Refused, "fault declared twice: #{twice.first}" unless twice.empty?

      Declaration.new(faults: faults.freeze)
    end

    # The action of fault, one the declaration holds.
    def action(fault)
      case [KINDS.fetch(fault.kind).action, fault.target]
      in [:device_del, { device: }] then QmpCommand.new(method: :device_del, arguments: [device.to_s])
      in [:eject, { drive: }] then QmpCommand.new(method: :eject, arguments: [drive.to_s])
      in [:typed_kill, { domain: }] then TypedLine.new(line: kill_line(domain))
      in [:end_machine, _] then EndMachine.new
      end
    end

    # The line typed at the guest's Erlang shell that kills every ready incarnation of the
    # domain whose node is domain and prints {fault_killed, N}. Its variables start with Fk,
    # beside PcieDomain::WAIT's Pc, which nothing else the shell runs binds.
    def kill_line(domain)
      [*PcieDomain::WAIT,
       "FkKilled=[exit(FkP,kill)||\#{pid:=FkP}<-PcFind('#{domain}')]",
       'io:format("~0kp~n",[{fault_killed,length(FkKilled)}])'].join(',').concat(".\r")
    end

    def fault(entry)
      kind_name, target = entry_parts(entry)
      kind = KINDS[kind_name] or raise Refused, "#{kind_name.inspect} is not a fault kind (#{KINDS.keys.join(', ')})"
      unless kind.status == :ready
        raise Refused, "#{kind_name} is #{kind.status}: the probe has not shown it on the pinned QEMU" if kind.status == :unverified

        raise Refused, "#{kind_name} is #{kind.status}: its relay is not written"
      end
      unless target.keys.sort == kind.targets.sort
        raise Refused, "#{kind_name} takes #{kind.targets.empty? ? 'no targets' : kind.targets.join(', ')}, " \
                       "not #{target.keys.join(', ')}"
      end

      target.each { |key, value| check_target(kind_name, key, value) }
      Fault.new(kind: kind_name, target: target.dup.freeze)
    end

    def entry_parts(entry)
      case entry
      in [Symbol => kind] then [kind, {}]
      in [Symbol => kind, Hash => target] then [kind, target]
      else raise Refused, "a fault is [kind, targets], not #{entry.inspect.byteslice(0, 80)}"
      end
    end

    def check_target(kind_name, key, value)
      return if TARGETS.fetch(key).call(value)

      raise Refused, "#{kind_name}'s #{key} #{value.inspect.byteslice(0, 80)} is not one it takes"
    end

    private_class_method :fault, :entry_parts, :check_target

    # The effect layer: injects a cell's declared faults into the machine it started, through
    # qmp (an Erx::Qmp connected to that QEMU, or nil when the declaration needs none), type
    # (a callable that types a line at the guest's shell) and cut (a callable that ends that
    # QEMU's process at once). It keeps what it injected, in order, for the cell's record.
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
        raise Refused, "#{fault} is not among the cell's declared faults" unless @declaration.faults.include?(fault)

        result = run(Faults.action(fault))
        @injected << fault
        result
      end

      # The cell's record of its faults: what it injected, one line each.
      def record = @injected.map(&:to_s)

      private

      def run(action)
        case action
        in QmpCommand[method:, arguments:] then @qmp.public_send(method, *arguments)
        in TypedLine[line:] then @type.call(line)
        in EndMachine then @cut.call
        end
      end
    end
  end
end
