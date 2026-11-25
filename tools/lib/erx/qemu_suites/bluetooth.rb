# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bt_domain'
require_relative '../qemu_gate'

# The Bluetooth domain on QEMU virt under HVF against Bumble's controllers
# (tools/lib/erx/bt_domain.rb): the suite's own manifest (BtDomain.manifest) boots with the
# line's virtio console joined to a Bumble controller, and the Bluetooth domain's bring-up
# answers its facts, the echo domain echoes the serial row, and the app cell's echo
# package, an installed app holding its own ble grant, echoes it too, and the bleuart
# cell gives a peer root's shell over nus and takes nus out of the advertising data when
# bleuart stops. One CPU: the
# line's traffic is the bring-up's few commands. Its boot
# needs the controllers on this host's loopback, so it does not declare offload, and a
# boot with a line is never reused. check_qemu builds the kernel before any suite runs,
# so this suite does not.
Erx::QemuGate.declare_suite(
  cells: Erx::BtDomain::Run.cells,
  run: lambda do |context|
    Erx::QemuGate.result(Erx::BtDomain::Run.new(root: context.root).call(jobs: context.jobs, build: false))
  end
)
