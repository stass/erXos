# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The domain library's pure core, whose origin constructors alone build
    # a creation origin, and the host driver and fuzz target that judge them.
    DOM_CORE = 'liberx/system/dom_core.c'
    DOM_HEADER = 'include/erx/dom.h'
    DOM_DRIVER = 'test/fixtures/dom_core_driver.c'
    DOM_FUZZ = 'tools/fuzz/dom_core_fuzz.c'
    # The erXos NIFs inside OTP's tree, where the domain library's NIF lives.
    ERXOS_NIFS = 'otp/erts/emulator/nifs/erxos/**/*'

    declare_group(
      unchecked_objects: [DOM_CORE],
      rules: [
        # A creation origin is authority provenance: the planning entries
        # build every specification, origin included, inside the core, so
        # no caller hands the planner an origin. This keeps the origin
        # kinds out of every other file, so no file builds one to store or
        # compare as if it were the library's. The driver names them to
        # forge an origin in a request, which the entry must overwrite, and
        # the fuzz target to check each plan carries its entry's origin.
        Chokepoints::Forbidden.new(
          name: 'dom-origin-constructors',
          rule: "only #{DOM_CORE}'s origin constructors build a domain's creation origin: no other file names " \
                'the origin kinds',
          design: 'docs/design-system.md#the-domain-library',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\bERX_DOM_(?:REQUEST|CONFIGURED|PARTIAL_BOOT)\b/,
          sites: [DOM_CORE, DOM_HEADER, DOM_DRIVER, DOM_FUZZ].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/system/dom_apply.c' => "spec.origin = (erx_dom_origin_t){ ERX_DOM_CONFIGURED, row };\n",
                  'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' => "origin.kind = ERX_DOM_REQUEST;\n" }
        ),
        # A numeric index a requester supplies never selects manifest
        # authority: only manifest startup and restart call the configured
        # entry and only the root's partial-boot entry the partial one
        # (docs/design-system.md, "The domain library"). Its check lands
        # with the first caller, the library's apply and NIF.
        Chokepoints::Pending.new(
          name: 'dom-manifest-entries',
          rule: 'only manifest startup and restart call erx_dom_plan_configured, and only the root partial-boot ' \
                'entry calls erx_dom_plan_partial; no domain facet reaches either',
          design: 'docs/design-system.md#the-domain-library',
          awaits: ['liberx/system/**/*', 'otp/erts/emulator/nifs/erxos/erx_domain_lib*'],
          existing: [DOM_CORE],
          reason: "the entries' callers land with the domain library's apply and NIF"
        )
      ]
    )
  end
end
