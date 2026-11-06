# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../libc_test'
require_relative '../qemu_gate'

# A small set of musl's libc-test programs, each a task, under HVF at each CPU count
# (Erx::LibcTest::CANARY). The whole suite is tools/erx check-libc-test, whose results
# are data. Run raises on the first disagreement, which the gate reports as this suite
# failing. check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    run = Erx::LibcTest::Run.new(root: context.root)
    accel = Erx::QemuGate::SUITE_ACCELERATOR
    Erx::QemuGate.result(cpus.to_h do |count|
      outcome = run.call(accel: accel, cpus: count, jobs: context.jobs, build: false, only: Erx::LibcTest::CANARY)
      problems = Erx::LibcTest.canary_problems(outcome)
      unless problems.empty?
        raise Erx::Error, "libc-test canary, #{accel} at #{count} CPUs: #{problems.join('; ')}; see #{outcome.fetch(:report)}"
      end

      ["#{accel}-#{count}cpu", 'passed']
    end)
  end
)
