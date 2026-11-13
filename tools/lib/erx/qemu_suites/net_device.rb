# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../net_device'
require_relative '../network_domain'
require_relative '../qemu_gate'

# The network stack on QEMU virt under HVF: the development image boots with a
# virtio-net device on QEMU's user networking, the network domain's erx_net takes a
# DHCP lease from slirp, the guest answers the harness's ARP request and ICMP echo
# request, and root's session's Erlang shell opens TCP connections through slirp
# (tools/lib/erx/net_device.rb, whose header defines the exchange), at one CPU. Its
# second cell, also at one CPU, measures the network domain's footprint on the
# development manifest with the domain's restarts at 0 (tools/lib/erx/network_domain.rb).
# The noncoherent cell boots the first cell's image on QEMU's tree with the network
# device's transport not marked dma-coherent, so its queues run the cache maintenance
# (Erx::NetDevice::TREES). check_qemu builds the kernel before any suite runs, so this
# suite does not.
cells = [*Erx::NetDevice::TREES.keys.map { |tree| Erx::NetDevice.cell(Erx::QemuGate::SUITE_ACCELERATOR, tree) }, Erx::NetworkDomain::Run::CELL]
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    run = Erx::NetDevice::Run.new(root: context.root)
    results = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], jobs: context.jobs, build: false)
    domain = Erx::NetworkDomain::Run.new(root: context.root)
    results = results.merge(domain.call(jobs: context.jobs, build: false))
    [*run.measurements, *domain.measurements].each { |line| Erx::Terminal.puts(line) }
    Erx::QemuGate.result(results, notes: run.notes)
  end
)
