# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../boot_image_check'
require_relative '../qemu_gate'
require_relative '../runner'

# The bootable file in both forms under HVF at each CPU count, one large enough that
# bootstrap moves its archive behind the root, and each
# damage the boot checks claim to catch (tools/lib/erx/boot_image_check.rb).
# BootImageCheck::Run raises on the first disagreement, which the gate reports
# as this suite failing. check_qemu builds the kernel before any suite runs,
# so this suite does not.
# Its multi-CPU cells pass under TCG on a second host, so it declares offload (QemuGate::Suite).
cpus = [1, 4]
accel = Erx::QemuGate::SUITE_ACCELERATOR
Erx::QemuGate.declare_suite(
  cells: [*cpus.map { |count| "#{accel}-#{count}cpu-single" }, "#{accel}-1cpu-two-file", "#{accel}-1cpu-moved", 'damage-cases'],
  offload: true,
  run: lambda do |context|
    runner = Erx::Runner.new(owner_root: context.root, log_dir: File.join(context.root, 'build/logs'))
    check = Erx::BootImageCheck::Run.new(root: context.root, runner: runner, compiler: ENV.fetch('ERX_CLANG', ''),
                                         linker: ENV.fetch('ERX_LLD', ''))
    report = check.call(accels: [accel], cpus: cpus, jobs: context.jobs, build: false, placement: context.placement)
    Erx::QemuGate.result(report.fetch(:good).transform_values { 'passed' }.merge('damage-cases' => 'passed'))
  end
)
