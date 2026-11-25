# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require 'rbconfig'
require_relative 'bench_record'
require_relative 'error'
require_relative 'host_os'
require_relative 'source_revision'

module Erx
  # A system's guest and the record of one of its boots (docs/design-bench.md, "Other
  # systems in QEMU under HVF"). A guest is how one system boots for one landing boot
  # of a benchmark and how its lines come back as cells; every system's boot then
  # becomes a record the same way, in its own environment, so the record format is the
  # one view across them.
  #
  # A guest answers:
  #   system          the system it runs, one of BenchRecord::SYSTEMS
  #   boot            the landing boot whose cells it runs (BenchSuite::BOOTS)
  #   forms(cpus)     the CPU counts it boots in, given the landing boot's
  #   offers?(name)   whether it runs the cells at that profile form (landing, full)
  #   call(benchmark, cells:, cpus:, accel:)
  #                   one boot of those cells at cpus CPUs, as a Booted
  # erXos's native bench image is the first (NativeBench::Guest).
  module BenchSystem
    # What one boot of a guest gives back: the clock group and cells its lines were
    # judged to (clock nil for a guest whose program prints only means), the reasons of
    # the lines refused, the environment and subject facts only the guest knows (its
    # memory and QEMU's version; its image, flags and pins), the boot logs to keep as
    # BenchRecord.write takes them, and the stored log a replayed boot came from.
    Booted = Data.define(:clock, :cells, :refused, :environment, :subject, :logs, :reused_from)

    # Where a session's boots run, read once: the environment kind, the host's model and
    # CPU count, and the harness's source revision, which every system's record keeps.
    Host = Data.define(:kind, :model, :cpus, :revision, :dirty)

    # One boot's record, with what its lines refused and the logs to keep beside it.
    Recorded = Data.define(:record, :refused, :logs)

    module_function

    # The host this session runs on, read through runner: its model, its CPU count and
    # the revision of the tree at root.
    def host(kind:, root:, runner:)
      revision = SourceRevision.read(root: root, runner: runner) ||
                 raise(Error, "bench: #{root} is not a git checkout, so a record has no revision")
      Host.new(kind: kind, model: host_model(runner), cpus: Etc.nprocessors, revision: revision.commit,
               dirty: revision.dirty)
    end

    LINUX_MODELS = %w[/sys/class/dmi/id/product_name /proc/device-tree/model].freeze

    # The host's hardware model as BenchRecord::MODEL spells it: sysctl hw.model on macOS
    # and FreeBSD, the firmware's product name on Linux, unknown elsewhere.
    def host_model(runner)
      named = if HostOs::MACOS || HostOs::FREEBSD
                result = runner.run(%w[sysctl -n hw.model], name: 'bench-sysctl-hw-model', deadline: 10)
                File.binread(result.fetch('log'), 4096)
              else
                LINUX_MODELS.find { |path| File.file?(path) }&.then { |path| File.binread(path, 4096) }
              end
      model = named.to_s.strip.gsub(/[^A-Za-z0-9.,_-]+/, '-').delete_prefix('-')[0, 64]
      model.match?(BenchRecord::MODEL) ? model : 'unknown'
    end

    # One boot of guest for cells at cpus CPUs on host, the host's one-minute load read
    # by load before and after it: the record of the boot, started by started_by.
    def boot(guest, benchmark, cells:, cpus:, host:, started_by:, load:)
      date = Time.now.utc
      before = load.call
      booted = guest.call(benchmark, cells: cells, cpus: cpus, accel: host.kind.delete_prefix('qemu-'))
      after = load.call
      Recorded.new(record: record(booted, system: guest.system, cpus: cpus, host: host, date: date, started_by: started_by,
                                          load: before && after && [before, after]),
                   refused: booted.refused, logs: booted.logs)
    end

    # The record of a boot: its environment is the host's kind and model at cpus CPUs
    # running system, with the accelerator and the host's operating system beside the
    # guest's own facts; its subject is the harness's revision with the guest's facts.
    def record(booted, system:, cpus:, host:, date:, started_by:, load:)
      details = { 'accelerator' => host.kind.delete_prefix('qemu-'), 'host_os' => RbConfig::CONFIG['host_os'] }
      BenchRecord::Record.new(
        environment: BenchRecord::Environment.new(kind: host.kind, model: host.model, cpus: cpus, system: system,
                                                  details: details.merge(booted.environment)),
        subject: BenchRecord::Subject.new(revision: host.revision, dirty: host.dirty, details: booted.subject),
        run: BenchRecord::Run.new(date: date, started_by: started_by, load: load, host_cpus: host.cpus,
                                  reused_from: booted.reused_from),
        clock: booted.clock, cells: booted.cells
      )
    end
  end
end
