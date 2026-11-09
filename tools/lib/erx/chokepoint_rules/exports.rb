# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The export table's one file, whose holders_put is the one insert into
    # a name's holders.
    EXPORTS = 'otp/erts/emulator/sys/erxos/erx_exports.c'
    # A line that names the insert, matched whole so each permitted line
    # below is that line and no other.
    HOLDERS_PUT = /.*\bholders_put\(.*/
    # The definition and the three writers' calls (R7), each with the mode
    # its writer must use: handing a name out adds send only where the
    # peer holds nothing, a spawn adds every right of a child, and an
    # explicit export sets exactly what its owner named.
    HOLDERS_PUT_SITES = Regexp.union(
      /\Aholders_put\(erx_exports_t \*set, uint32_t peer, uint8_t rights, put_mode_t mode\)\z/,
      /\A\t\t\(void\)holders_put\(&p->erx_exports, peer, ERX_RIGHT_SEND, PUT_IF_NONE\);\z/,
      /\A\t\t\(void\)holders_put\(&child->erx_exports, peer, ERX_RIGHT_SEND \| ERX_RIGHT_LINK \| ERX_RIGHT_EXIT,\z/,
      /\A\treturn \(holders_put\(set, peer, rights, PUT_EXACT\)\);\z/
    )

    declare_group(
      rules: [
        # R7: the export table is written at exactly three sites, each an
        # act of the name's owner. ERTS has no call graph in the kernel
        # cores' trees, so this is a text rule over erXos's own C and the
        # inherited OTP and musl: only the four lines above name the
        # insert, so a fourth writer, or a writer whose mode changes (an
        # encode that would widen what a peer holds), fails the build. It
        # cannot tell a fourth call that copies one of those lines verbatim
        # in erx_exports.c, nor a write through the record's fields that
        # skips the insert; both stay inside the one file, which its review
        # and the export-table tests read.
        Chokepoints::Forbidden.new(
          name: 'exports-writers',
          rule: "only #{EXPORTS}'s three writers, erx_exports_hand_out, erx_exports_spawned and exports_set, " \
                'call holders_put, the one insert into a name\'s holders, each with its own mode (R7)',
          design: 'docs/design-domains.md#exports',
          scope: Chokepoints::Scope.new(own: true, extra: %w[otp/**/* musl/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: HOLDERS_PUT,
          sites: [Chokepoints::Site.new(glob: EXPORTS, permits: HOLDERS_PUT_SITES)],
          seed: { EXPORTS => "\t(void)holders_put(&domain_exports, peer, ERX_RIGHT_SPAWN, PUT_WIDEN);\n",
                  'otp/erts/emulator/beam/dist.c' =>
                    "    (void)holders_put(&p->erx_exports, peer, ERX_RIGHT_SEND, PUT_IF_NONE);\n",
                  'otp/erts/emulator/beam/external.c' =>
                    "\t\t(void)holders_put(&p->erx_exports, peer, ERX_RIGHT_SEND, PUT_EXACT);\n" }
        )
      ]
    )
  end
end
