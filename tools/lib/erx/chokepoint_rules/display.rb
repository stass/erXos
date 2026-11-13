# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    DISPLAY_DESIGN = 'docs/design-display.md'
    DISPLAY_REQUESTS = "(?:#{%w[flush_request power_request].map { |name| ErlangText::ATOM.call(name) }.join('|')})"
    ERX_DISPLAY = ErlangText::ATOM.call('erx_display')

    # The display's Erlang rules.
    declare_group(
      rules: [
        # erx_screen is the one sender of frames, so the driver reads the
        # screen image only while erx_screen, which writes nothing during a
        # frame, holds one out. Both requests are functions of the behaviour
        # module, which build the one term a driver's handle_call/3 answers.
        # Refused outside erx_screen: either name after erx_display and a
        # colon or a comma (a remote call, a fun, an apply, a {Module,
        # Function} pair); either called through a variable or macro module,
        # since erx_display alone defines them; an apply whose function is
        # either; an import from erx_display; and a macro defined as
        # erx_display or either name. Strings are blanked, since a doc string
        # may name either. erx_display's own definitions name no module and
        # pass; a message built by hand and sent to the driver is the
        # driver's review's to catch.
        Chokepoints::ErlangForbidden.new(
          name: 'display-driver-callers', rule: 'only erx_screen calls erx_display:flush_request/3 and ' \
                                                'erx_display:power_request/2, the display driver\'s flush and power requests',
          design: "#{DISPLAY_DESIGN}#chokepoints", strings: :blanked,
          pattern: /
              #{ERX_DISPLAY}\s*[:,]\s*#{DISPLAY_REQUESTS}
            | (?:#{ErlangText::INDIRECT})\s*:\s*#{DISPLAY_REQUESTS}
            | #{ErlangText::ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{DISPLAY_REQUESTS}
            | -\s*import\s*\(\s*#{ERX_DISPLAY}
            | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*(?:#{ERX_DISPLAY}|#{DISPLAY_REQUESTS})\s*\)
          /x,
          sites: ['erlang/apps/erx_display/src/erx_screen.erl'],
          seed: { 'erlang/apps/erx_display/src/seeded.erl' => "f(D) -> gen_server:call(D, erx_display:power_request(D, on)).\n",
                  'erlang/apps/erx_win/src/seeded.erl' => "f(M, D) -> M:flush_request(D, a, b).\n" }
        )
      ]
    )
  end
end
