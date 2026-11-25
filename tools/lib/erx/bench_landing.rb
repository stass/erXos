# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'bench_system'
require_relative 'qemu_gate'
require_relative 'runner'

module Erx
  # One erXos boot of the landing matrix recorded (docs/design-bench.md, "The gates",
  # "The record"): the boot's guest lines judged against what it asked, as erXos's
  # record (BenchSystem.record) of the host it ran on and the host's load around it,
  # which BenchRecord.write adds to the history unless the boot was replayed from the
  # gate's store. Each landing boot's runner gives the boot itself (NativeBench::Run,
  # XdomainBench::Run): a callable that boots its image and answers what it measured.
  class BenchLanding
    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')))
      @root = File.expand_path(root)
      @runner = runner
    end

    # What an erXos boot gives back as a system's guest (BenchSystem::Booted): measured
    # is the boot's map (its serial log, image SHA-256, flags, compiler, workloads'
    # SHA-256, QEMU version and the stored log a replayed boot came from), answer its
    # lines judged (BenchMeasurement.boot), memory_mib the machine's.
    def self.booted(measured, answer, memory_mib:)
      BenchSystem::Booted.new(
        clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
        environment: { 'memory_mib' => memory_mib, 'machine' => 'virt', 'qemu' => measured.fetch(:qemu_version) }.compact,
        subject: measured.slice(:image_sha256, :flags, :compiler, :workloads).transform_keys(&:to_s),
        logs: [{ serial: measured.fetch(:serial) }], reused_from: measured.fetch(:reused_from)
      )
    end

    # Boots boot (a BenchSuite::Boot) through the block, which takes the accelerator and
    # answers the boot's measured map (as booted takes it, with the checkpoint timeout
    # that ended a boot early), and judges its lines against asked: a cell a timed-out
    # boot did not report is timed_out. Answers the record, the run directory written
    # (nil for a replayed boot), the refused lines' reasons and the timeout.
    def call(asked, boot:, memory_mib:, history:)
      host = BenchSystem.host(kind: boot.kind, root: @root, runner: @runner)
      date = Time.now.utc
      before = QemuGate.one_minute_load
      measured = yield(boot.kind.delete_prefix('qemu-'))
      after = QemuGate.one_minute_load
      timed_out = measured.fetch(:timed_out, nil)
      answer = BenchMeasurement.boot(measured.fetch(:lines), asked, timed_out: !timed_out.nil?)
      booted = BenchLanding.booted(measured, answer, memory_mib: memory_mib)
      record = BenchSystem.record(booted, system: 'erxos', cpus: boot.cpus, host: host, date: date,
                                          started_by: 'landing', load: before && after && [before, after])
      written = (BenchRecord.write(record, history: history, erxos_root: @root, boots: booted.logs) unless record.run.replayed?)
      { record: record, written: written, refused: booted.refused, timed_out: timed_out }
    end
  end
end
