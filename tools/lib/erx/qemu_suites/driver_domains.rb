# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../driver_domains'
require_relative '../qemu_gate'

# The drivers' domains on QEMU virt under HVF (tools/lib/erx/driver_domains.rb, whose header
# defines the lines the guest prints): a littlefs worker killed in the storage domain ends
# that domain, and its restart comes back with /data mounted afresh, the file written before
# the kill read back; and the network domain's driver control restarts, stops and starts
# its link with the domain and root's grant unchanged, while the end of its stack's
# interfaces supervisor ends the domain, whose restart grants root's session and the system
# domain anew, ping and a TCP connect working again. Run raises on the first disagreement,
# which the gate reports as this suite failing. HVF at one CPU is its one cell. Its boots
# carry a disk or a network device, so it does not declare offload. check_qemu builds the
# kernel before any suite runs, so this suite does not.
cells = Erx::QemuGate.suite_cells([1])
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    ran = Erx::DriverDomains::Run.new(root: context.root).call(accels: [Erx::QemuGate::SUITE_ACCELERATOR],
                                                                jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran)
  end
)
