# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bounded_file'
require_relative '../conformance'
require_relative '../fiasco'
require_relative '../qemu_gate'

# The kernel interface's conformance roster over the matrix of accelerators
# and CPU counts (tools/lib/erx/conformance.rb, test/conformance/roster.txt).
# A roster whose every case is pending has nothing to boot, so the suite
# reports those cases as pending and starts no guest; once a case is
# declared with `case`, the guest boots in every configuration. A
# configuration the host cannot run is not_run, and the harness's own
# `unsupported` is mapped to it.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    path = File.join(context.root, 'test/conformance/roster.txt')
    roster = Erx::Conformance.roster(Erx::BoundedFile.read(path, maximum: 1 << 20), path: path)
    pending = roster.select(&:pending).to_h { |entry| ["case #{entry.name}", 'pending'] }
    next Erx::QemuGate.result(pending) if roster.all?(&:pending)

    configs = context.accels.product([1, 4]).map { |accel, cpus| Erx::Conformance::Config.new(accel: accel, cpus: cpus) }
    image = Erx::Fiasco.new(root: context.root).image_path
    matrix = Erx::Conformance::Run.new(root: context.root).run(image: image, roster: roster, configs: configs)
    cells = matrix.fetch('configurations').to_h do |entry|
      status = entry.fetch('status')
      [entry.fetch('configuration'), status == 'unsupported' ? 'not_run' : status]
    end
    Erx::QemuGate.result(cells.merge(pending), notes: ["matrix: #{matrix.fetch('matrix')}"])
  end
)
