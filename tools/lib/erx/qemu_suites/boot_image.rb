# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../boot_image_check'
require_relative '../qemu_gate'
require_relative '../runner'

# The bootable file in both forms under each accelerator and CPU count, and each
# damage the boot checks claim to catch (tools/lib/erx/boot_image_check.rb).
# BootImageCheck::Run raises on the first disagreement, which the gate reports
# as this suite failing. An accelerator the host lacks leaves its cells not_run.
# check_qemu builds the kernel before any suite runs, so this suite does not.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    cpus = [1, 4]
    ran = if context.runnable.empty?
            {}
          else
            runner = Erx::Runner.new(owner_root: context.root, log_dir: File.join(context.root, 'build/logs'))
            report = Erx::BootImageCheck::Run.new(root: context.root, runner: runner, compiler: ENV.fetch('ERX_CLANG', ''),
                                                  linker: ENV.fetch('ERX_LLD', ''))
                                             .call(accels: context.runnable, cpus: cpus, jobs: context.jobs, build: false)
            report.fetch(:good).transform_values { 'passed' }.merge('damage-cases' => 'passed')
          end
    skipped = context.missing.product(cpus).to_h { |accel, count| ["#{accel}-#{count}cpu", 'not_run'] }
    notes = context.missing.map { |accel| "#{accel} is not offered by this host's QEMU" }
    Erx::QemuGate.result(ran.merge(skipped), notes: notes)
  end
)
