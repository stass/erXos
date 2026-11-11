# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsGateTest < Minitest::Test
  include ChokepointsHelper

  WAIT = "\tconst int status = erx_ipc_wait(ERX_WAIT_FOREVER, &tag, label);\n"

  # The gate worker waits in IPC; any other ERTS source, a scheduler's file or a NIF's,
  # is refused, while liberx's own callers and a comment naming the call are not ERTS's waits.
  def test_only_the_gate_worker_waits_in_ipc_in_erts
    gate = [rule('gate-ipc-wait')]
    allowed = {
      Rules::GATE_WORKER => WAIT,
      'liberx/system/dom_apply.c' => WAIT,
      'otp/erts/emulator/sys/erxos/erx_event.c' => "/* erx_ipc_wait is the gate worker's alone. */\n"
    }
    assert_empty evaluate(gate, allowed, imported: ['otp/erts/emulator/sys/erxos/erx_event.c'])
    %w[otp/erts/emulator/sys/erxos/erx_lane_drv.c otp/erts/emulator/beam/erl_process.c
       otp/erts/emulator/nifs/erxos/erx_device_nif.c].each do |path|
      refute_empty evaluate(gate, { path => WAIT }, imported: [path]), "#{path} may wait in IPC"
    end
  end
end
