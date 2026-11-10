# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../net_device'
require_relative '../qemu_gate'

# The network stack on QEMU virt under HVF: the development image boots with a
# virtio-net device on QEMU's user networking, the system domain's erx_net takes a DHCP
# lease from slirp, and the guest answers the harness's ARP request and ICMP echo
# request, and its Erlang shell opens TCP connections through slirp
# (tools/lib/erx/net_device.rb, whose header defines the exchange). HVF at one
# CPU is its one cell. check_qemu builds the kernel before any suite runs, so this
# suite does not.
cells = Erx::QemuGate.suite_cells([1])
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    run = Erx::NetDevice::Run.new(root: context.root)
    results = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], jobs: context.jobs, build: false)
    run.measurements.each { |line| Erx::Terminal.puts(line) }
    Erx::QemuGate.result(results, notes: run.notes)
  end
)
