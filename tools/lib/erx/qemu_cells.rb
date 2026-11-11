# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'qemu_remote'
require_relative 'runner'

module Erx
  # Where and in what order a suite's cells boot (docs/design-build.md,
  # "Placing cells"). A cell is one boot configuration: an accelerator, a CPU
  # count, and the host QEMU runs on, nil for this one. Outside the QEMU gate
  # every cell boots here, one after another (HERE). The gate places each
  # suite before it runs (QemuCells.placement): its cells boot side by side
  # when this host has the idle cores for all of them, and at the landing
  # gate, when asked for and while this host is busy, a suite that declares
  # offload sends its multi-CPU cells to a remote host under TCG.
  module QemuCells
    # The accelerator every suite cell runs under here, and the one a moved
    # cell runs under there: the remote host is not this host's architecture.
    LOCAL_ACCELERATOR = 'hvf'
    REMOTE_ACCELERATOR = 'tcg'

    # A cell's name is its accelerator and CPU count, so a report never names
    # HVF for a TCG boot, nor TCG for an HVF one.
    Cell = Data.define(:accel, :cpus, :remote) do
      def initialize(accel:, cpus:, remote: nil)
        raise Error, 'a cell runs here or on a QemuRemote::Host' unless remote.nil? || remote.is_a?(QemuRemote::Host)

        super
      end

      def name = "#{accel}-#{cpus}cpu"
    end

    # A suite cell's name as Cell#name spells it.
    CELL_NAME = /\A(?<accel>[a-z]+)-(?<cpus>[1-9])cpu\z/
    # A declared cell's name: a cell's, with the case it boots after it, if any.
    CELL_CASE_NAME = /\A(?<accel>[a-z]+)-(?<cpus>[1-9])cpu(?<case>-[a-z0-9-]+)?\z/

    # One suite's placement: the remote host its multi-CPU cells move to, or
    # nil, and whether the cells that stay here boot side by side.
    Placement = Data.define(:remote, :side_by_side) do
      # The cells of each accelerator at each CPU count, in that order, each
      # where this placement puts it.
      def cells(accels:, cpus:)
        accels.product(cpus).map { |accel, count| QemuCells.place(Cell.new(accel: accel, cpus: count), remote) }
      end

      # Boots each cell through the block, called with the cell's accelerator,
      # CPU count and remote host (nil for here), which returns the cell's
      # [name, value]; returns those pairs as a Hash. The cells that stay here
      # form one lane, or one lane each when side by side, and the remote
      # cells one more; QemuCells.lanes runs the lanes at once.
      def each(accels:, cpus:, &block)
        remote_cells, here = cells(accels: accels, cpus: cpus).partition(&:remote)
        local_lanes = side_by_side ? here.map { |cell| [cell] } : [here]
        QemuCells.lanes([*local_lanes, remote_cells].reject(&:empty?)) do |cell|
          block.call(cell.accel, cell.cpus, cell.remote)
        end.to_h
      end
    end

    # Every cell here, one after another: the placement of every run outside
    # the gate, and of the gate's suites on a host with no cores to spare.
    HERE = Placement.new(remote: nil, side_by_side: false)

    module_function

    # The one placement rule: with a remote host, a cell of the local
    # accelerator at more than one CPU runs there under REMOTE_ACCELERATOR.
    def place(cell, remote)
      return cell unless remote && cell.accel == LOCAL_ACCELERATOR && cell.cpus > 1

      cell.with(accel: REMOTE_ACCELERATOR, remote: remote)
    end

    # The name a suite's declared cell reports under remote. A cell's name may
    # carry the case it boots after it (boot_image's hvf-4cpu-single), which
    # moves with the cell; a name that is not a cell's (a conformance case, a
    # smoke cell) is unchanged.
    def placed_name(name, remote)
      match = CELL_CASE_NAME.match(name)
      return name unless match

      place(Cell.new(accel: match[:accel], cpus: Integer(match[:cpus], 10)), remote).name + match[:case].to_s
    end

    # A suite's placement, from this host's state as the gate reads it before
    # the suite runs. remote is the host the gate was given, or nil; offload
    # is whether the suite declares that its multi-CPU cells may move there
    # (QemuGate::Suite).
    # They move only when this host is busy: its one-minute load average is
    # at least busy_load. The cells that stay here boot side by side when
    # their guest CPUs fit in the cores the load leaves idle.
    def placement(cells:, remote:, offload:, load:, busy_load:, cores:)
      moved = remote && offload && load >= busy_load ? remote : nil
      here = cells.filter_map { |name| CELL_NAME.match(placed_name(name, moved)) }
                  .select { |match| match[:accel] == LOCAL_ACCELERATOR }
      guest_cpus = here.sum { |match| Integer(match[:cpus], 10) }
      Placement.new(remote: moved, side_by_side: here.size > 1 && load + guest_cpus <= cores)
    end

    # Runs each lane's cells in order, the first lane in this thread and each
    # other in a thread of its own, and returns the block's results, lane by
    # lane. A remote cell whose host cannot be reached is left out with a line
    # saying so, which the gate reports as a cell not run. When any lane
    # fails, the lanes still running are stopped, which ends their boots
    # (Qemu#run cleans up as it unwinds), and the first error seen, the first
    # lane's before the others' in order, is the one raised.
    def lanes(lanes, &block)
      first, *rest = lanes
      threads = rest.map { |lane| Thread.new { lane_results(lane, &block) }.tap { |thread| thread.report_on_exception = false } }
      lane_results(first || [], &block) + threads.flat_map(&:value)
    rescue Exception # an interrupt, too, must stop the lanes before it propagates
      stop(threads || [])
      raise
    end

    def lane_results(lane, &block)
      lane.filter_map do |cell|
        block.call(cell)
      rescue QemuRemote::Unreachable => e
        Terminal.puts("#{cell.name}: not run: #{e.message}")
        nil
      end
    end
    private_class_method :lane_results

    # Stops the threads and waits for each to finish unwinding. Their own
    # errors are dropped: the error that stopped them is the one reported.
    def stop(threads)
      threads.each(&:kill).each do |thread|
        thread.join
      rescue Exception # a stopped lane's own error, whatever it is, gives way to the one that stopped it
        nil
      end
    end
    private_class_method :stop
  end
end
