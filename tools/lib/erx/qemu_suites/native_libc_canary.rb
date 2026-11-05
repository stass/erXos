# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../libc_test'
require_relative '../qemu_gate'

# A small set of musl's libc-test programs, each a task, under each accelerator and CPU
# count (Erx::LibcTest::CANARY). The whole suite is tools/erx check-libc-test, whose
# results are data. Run raises on the first disagreement, which the gate reports as this
# suite failing. An accelerator the host lacks leaves its cells not_run. check_qemu builds
# the kernel before any suite runs, so this suite does not.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    cpus = [1, 4]
    run = Erx::LibcTest::Run.new(root: context.root)
    ran = context.runnable.product(cpus).to_h do |accel, count|
      outcome = run.call(accel: accel, cpus: count, jobs: context.jobs, build: false, only: Erx::LibcTest::CANARY)
      problems = Erx::LibcTest.canary_problems(totals: outcome.fetch(:totals), pool_leaks: outcome.fetch(:pool_leaks_in_boots))
      raise Erx::Error, "libc-test canary, #{accel} at #{count} CPUs: #{problems.join('; ')}; see #{outcome.fetch(:report)}" unless problems.empty?

      ["#{accel}-#{count}cpu", 'passed']
    end
    skipped = context.missing.product(cpus).to_h { |accel, count| ["#{accel}-#{count}cpu", 'not_run'] }
    notes = context.missing.map { |accel| "#{accel} is not offered by this host's QEMU" }
    Erx::QemuGate.result(ran.merge(skipped), notes: notes)
  end
)
