# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'error'
require_relative 'qemu_gate'
require_relative 'runner'
require_relative 'source_revision'

module Erx
  # One boot of the landing matrix recorded (docs/design-bench.md, "The gates", "The
  # record"): the boot's guest lines judged against what it asked, as a record of the
  # environment it ran in, the subject it ran and the host's load around it, which
  # BenchRecord.write adds to the history unless the boot was replayed from the gate's
  # store. Each landing boot's runner gives the boot itself (NativeBench::Run,
  # XdomainBench::Run): a callable that boots its image and answers what it measured.
  class BenchLanding
    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')))
      @root = File.expand_path(root)
      @runner = runner
    end

    # Boots boot (a BenchSuite::Boot) through the block, which takes the accelerator and
    # answers the boot's measured map (its serial log, guest lines, image SHA-256,
    # flags, compiler, workloads' SHA-256, QEMU version and the stored log a replayed
    # boot came from), and judges its lines against asked. Answers the record, the run
    # directory written (nil for a replayed boot) and the refused lines' reasons.
    # memory_mib is the machine's.
    def call(asked, boot:, memory_mib:, history:)
      accel = boot.kind.delete_prefix('qemu-')
      revision = revision()
      model = sysctl('hw.model')
      date = Time.now.utc
      before = QemuGate.one_minute_load
      measured = yield(accel)
      after = QemuGate.one_minute_load
      answer = BenchMeasurement.boot(measured.fetch(:lines), asked)
      record = BenchRecord::Record.new(
        environment: environment(boot, accel: accel, model: model, memory_mib: memory_mib, measured: measured),
        subject: subject(revision, measured),
        run: BenchRecord::Run.new(date: date, started_by: 'landing', load: before && after && [before, after],
                                  host_cpus: Etc.nprocessors, reused_from: measured.fetch(:reused_from)),
        clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells)
      )
      written = unless record.run.replayed?
                  BenchRecord.write(record, history: history, erxos_root: @root, boots: [{ serial: measured.fetch(:serial) }])
                end
      { record: record, written: written, refused: answer.fetch(:refused) }
    end

    private

    def environment(boot, accel:, model:, memory_mib:, measured:)
      BenchRecord::Environment.new(
        kind: boot.kind, model: model, cpus: boot.cpus, system: nil,
        details: { 'memory_mib' => memory_mib, 'accelerator' => accel, 'machine' => 'virt',
                   'qemu' => measured.fetch(:qemu_version), 'host_os' => RbConfig::CONFIG['host_os'] }.compact
      )
    end

    def revision
      SourceRevision.read(root: @root, runner: @runner) ||
        raise(Error, "bench: #{@root} is not a git checkout, so a record has no revision")
    end

    def subject(revision, measured)
      BenchRecord::Subject.new(revision: revision.commit, dirty: revision.dirty,
                               details: measured.slice(:image_sha256, :flags, :compiler, :workloads).transform_keys(&:to_s))
    end

    def sysctl(name)
      result = @runner.run(['sysctl', '-n', name], name: "bench-sysctl-#{name.tr('.', '-')}", deadline: 10)
      File.binread(result.fetch('log'), 4096).strip
    end
  end
end
