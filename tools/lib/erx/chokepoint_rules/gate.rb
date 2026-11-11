# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The gate worker, ERTS's one thread that waits in IPC.
    GATE_WORKER = 'otp/erts/emulator/sys/erxos/erx_gate.c'

    declare_group(
      rules: [
        # R3: no executor waits outside its domain. ERTS waits on the
        # domain's fault gate only in the gate worker, a worker thread; a
        # wait anywhere else in ERTS, a scheduler's or a NIF's, could hold
        # an executor in IPC and would take records the worker owns.
        Chokepoints::Forbidden.new(
          name: 'gate-ipc-wait',
          rule: "only #{GATE_WORKER}, the gate worker, calls erx_ipc_wait in ERTS (R3)",
          design: 'docs/design-runtime.md#the-event-table',
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /.*\berx_ipc_wait\b.*/,
          sites: [Chokepoints::Site.new(glob: GATE_WORKER)],
          seed: { 'otp/erts/emulator/sys/erxos/erx_event.c' =>
                    "\tstatus = erx_ipc_wait(ERX_WAIT_FOREVER, &tag, &label);\n",
                  'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' =>
                    "\t(void)erx_ipc_wait(0, &tag, &label);\n" }
        )
      ]
    )
  end
end
