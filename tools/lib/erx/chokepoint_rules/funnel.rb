# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # ERTS's distribution input, matched as the whole line that names it so
    # each stock site below can permit its own lines and no new one.
    NET_MESSAGE = /.*\berts_net_message\b.*/
    # The lane driver, whose drain hands ERTS a frame only when
    # erx_funnel_check returned it for delivery.
    LANE_DRIVER = 'otp/erts/emulator/sys/erxos/erx_lane_drv.c'
    # Stock ERTS's own lines: the declaration and the definition. Its two
    # stock carriers, a port driver's output to a distribution port (io.c)
    # and dist_ctrl_put_data (dist.c), refuse for every entry.
    NET_MESSAGE_STOCK = {
      'otp/erts/emulator/beam/global.h' => /\Aextern int erts_net_message\(Port \*prt,\s*\z/,
      'otp/erts/emulator/beam/dist.c' => /\Aint erts_net_message\(Port \*prt,\s*\z/
    }.freeze

    declare_group(
      # The grammar is pure, with no private header: include/erx/funnel.h is
      # its whole interface.
      unchecked_objects: %w[liberx/erx_funnel.c],
      rules: [
        # D3 and R6: only the funnel hands a frame from another domain to a
        # runtime. ERTS's distribution input is erts_net_message, and only
        # the lane driver may call it, with what erx_funnel_check returned;
        # this text rule keeps every other file of erXos's own C, the
        # inherited OTP and musl off it. That the drain calls it only with a
        # delivered frame is the drain's own test's.
        Chokepoints::Forbidden.new(
          name: 'funnel-net-message',
          rule: "only #{LANE_DRIVER}, whose drain hands ERTS a frame only when erx_funnel_check returned it for " \
                'delivery, calls erts_net_message, ERTS distribution input, besides stock lines listed (D3, R6)',
          design: 'docs/design-domains.md#the-funnel',
          scope: Chokepoints::Scope.new(own: true, extra: %w[otp/**/* musl/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: NET_MESSAGE,
          sites: [Chokepoints::Site.new(glob: LANE_DRIVER),
                  *NET_MESSAGE_STOCK.map { |path, line| Chokepoints::Site.new(glob: path, permits: line) }],
          seed: { 'liberx/erx_funnel.c' => "int f(void) { return erts_net_message(0, 0, 0, 0, 0, 0, 0, 0); }\n",
                  'otp/erts/emulator/beam/erl_proc_sig_queue.c' =>
                    "    (void) erts_net_message(NULL, dep, conn_id, NULL, 0, bin, data, size);\n",
                  'otp/erts/emulator/beam/dist.c' =>
                    "    erts_net_message(prt, dep, conn_id, hbuf, hlen, bin, buf, len);\n" }
        )
      ]
    )
  end
end
