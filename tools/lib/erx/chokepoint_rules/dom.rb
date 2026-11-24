# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The domain library's pure core, whose origin constructors alone build
    # a creation origin, and the host driver and fuzz target that judge them.
    DOM_CORE = 'liberx/system/dom_core.c'
    # The domain library's core after creation, which plans connections and
    # ends domains and calls neither erx_dom_plan_configured nor
    # erx_dom_plan_partial.
    DOM_LIFE = 'liberx/system/dom_life.c'
    # The domain library's apply phase, which applies the plans the library's
    # entries make and calls neither manifest entry, and its firmware entries.
    DOM_APPLY = 'liberx/system/dom_apply.c'
    # The library at boot and manifest startup: the one caller on the target of
    # erx_dom_plan_configured.
    DOM_BOOT = 'liberx/system/dom_boot.c'
    DOM_BOOT_VIEW = 'liberx/system/dom_boot_view.c'
    # The reader of a domain's crash area, which calls no planning entry.
    DOM_DUMP = 'liberx/system/dom_dump.c'
    # The library where none is built: the refusing stub a runtime without it links.
    DOM_NONE = 'liberx/system/dom_lib_none.c'
    # The library's one install (A7) and the domain service's NIF module, which
    # call neither entry; the NIF reaches only erx_dom_lib_*.
    DOM_INSTALL_FILES = %w[liberx/system/dom_install.c liberx/system/dom_install.h].freeze
    DOM_NIF = 'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c'
    DOM_HEADER = 'include/erx/dom.h'
    DOM_LIB_HEADER = 'include/erx/dom_lib.h'
    DOM_APPLY_HEADER = 'liberx/system/dom_apply.h'
    DOM_DRIVER = 'test/fixtures/dom_core_driver.c'
    # The host driver of the core after creation, whose records carry the
    # origins a device give is placed by.
    DOM_LIFE_DRIVER = 'test/fixtures/dom_life_driver.c'
    DOM_FUZZ = 'tools/fuzz/dom_core_fuzz.c'
    # The manifest check's host run of the configured entry over each configured
    # domain's row (docs/design-system.md, "The manifest", property 12). It builds
    # only for the host, so it is no caller on the target.
    DOM_HOST_PLANNER = 'tools/host/dom_plan.c'
    # The pure half of the apply phase: the arguments a creation writes into its boot page.
    DOM_ARGS = 'liberx/system/dom_args.c'
    DOM_ARGS_HEADER = 'liberx/system/dom_args.h'
    # The erXos NIFs inside OTP's tree, where the domain library's NIF lives.
    ERXOS_NIFS = 'otp/erts/emulator/nifs/erxos/**/*'

    declare_group(
      unchecked_objects: [DOM_CORE, DOM_LIFE, DOM_APPLY, DOM_APPLY_HEADER, DOM_ARGS, DOM_ARGS_HEADER, DOM_BOOT, DOM_BOOT_VIEW, DOM_DUMP, DOM_NONE, *DOM_INSTALL_FILES],
      rules: [
        # A creation origin is authority provenance: the planning entries
        # build every specification, origin included, inside the core, so
        # no caller hands the planner an origin. This keeps the origin
        # kinds out of every other file, so no file builds one to store or
        # compare as if it were the library's. The driver names them to
        # forge an origin in a request, which the entry must overwrite, the
        # life driver to give its records the origins a device give is
        # placed by, and the fuzz target to check each plan carries its
        # entry's origin.
        Chokepoints::Forbidden.new(
          name: 'dom-origin-constructors',
          rule: "only #{DOM_CORE}'s origin constructors build a domain's creation origin: no other file names " \
                'the origin kinds',
          design: 'docs/design-system.md#the-domain-library',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\bERX_DOM_(?:REQUEST|CONFIGURED|PARTIAL_BOOT|SESSION)\b/,
          sites: [DOM_CORE, DOM_HEADER, DOM_DRIVER, DOM_LIFE_DRIVER, DOM_FUZZ].map do |path|
            Chokepoints::Site.new(glob: path)
          end,
          seed: { 'liberx/system/dom_apply.c' => "spec.origin = (erx_dom_origin_t){ ERX_DOM_CONFIGURED, row };\n",
                  'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' => "origin.kind = ERX_DOM_REQUEST;\n" }
        ),
        # A numeric index a requester supplies never selects manifest
        # authority: only manifest startup and restart call the configured
        # entry (docs/design-system.md, "The domain library"). On the host,
        # the manifest check plans each configured row too, and the driver
        # and fuzz target judge the entry.
        Chokepoints::Forbidden.new(
          name: 'dom-manifest-entries',
          rule: "only manifest startup and restart (#{DOM_BOOT}, and the domain service through #{DOM_NIF}) " \
                'call erx_dom_plan_configured or its applying entry erx_dom_lib_configured; no domain facet ' \
                'reaches either',
          design: 'docs/design-system.md#the-domain-library',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\berx_dom_(?:plan|lib)_configured\b/,
          # The NIF's configured entry is the one way from Erlang to it, and it
          # refuses every caller but the library's registered process, the
          # domain service. dom_lib_none.c is the refusing stub of a runtime with no library, and the
          # native_domain guest is a test root that stands in for manifest startup on its configured row.
          sites: [DOM_BOOT, DOM_LIB_HEADER, DOM_CORE, DOM_HEADER, DOM_DRIVER, DOM_FUZZ, DOM_HOST_PLANNER, DOM_NIF,
                  DOM_NONE, 'test/guest/native_domain/guest.c'].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/system/dom_apply.c' => "status = erx_dom_plan_configured(&view, id, row, &plan);\n",
                  'liberx/system/dom_life.c' => "status = erx_dom_lib_configured(lib, id, row, &created);\n" }
        ),
        # A session is made only from a template the view holds, and only the
        # domain service makes one, through its NIF entry, which refuses every
        # other caller; the backend's refusing stub names the entry too. The
        # manifest check plans root's console session and each enabled start row's
        # session, never applying them.
        Chokepoints::Forbidden.new(
          name: 'dom-session-entries',
          rule: "only the domain service, through #{DOM_NIF}, calls erx_dom_lib_session or erx_dom_lib_app_session, and only #{DOM_BOOT} " \
                'calls erx_dom_plan_session or erx_dom_plan_app_session, beside the manifest check\'s host planner, the host driver and the fuzz target; ' \
                'no domain facet reaches either',
          design: 'docs/design-domains.md#principals-sessions-and-quotas',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\berx_dom_(?:plan|lib)_(?:app_)?session\b/,
          sites: [DOM_BOOT, DOM_LIB_HEADER, DOM_CORE, DOM_HEADER, DOM_NIF, DOM_HOST_PLANNER,
                  DOM_NONE, 'test/fixtures/dom_core_driver.c', 'tools/fuzz/dom_core_fuzz.c']
                 .map { |site| Chokepoints::Site.new(glob: site) },
          seed: { 'liberx/system/dom_life.c' => "status = erx_dom_lib_session(lib, id, 0, \"x\", 1, pid, &created);\n" }
        ),
        # The apply phase runs a plan only from the library's own entries,
        # which planned it: no other file names erx_dom_lib_apply, so no
        # caller applies a plan it built itself.
        Chokepoints::Forbidden.new(
          name: 'dom-apply-private',
          rule: "only the library's own entries (#{DOM_APPLY}, #{DOM_BOOT}) apply a plan with erx_dom_lib_apply",
          design: 'docs/design-system.md#the-domain-library',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\berx_dom_lib_apply\b/,
          sites: [DOM_APPLY, DOM_APPLY_HEADER, DOM_BOOT].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' => "status = erx_dom_lib_apply(lib, &plan, &created);\n" }
        ),
        # A firmware request's tag and argument are the manifest's (docs/design-fiasco.md,
        # "The firmware request"): the backend's form takes its row as a value, so only the
        # library's firmware entries, which resolve the row from the view's allow-list, call it. The others
        # name it to declare it, define it on the Fiasco root, and refuse it hosted.
        Chokepoints::Forbidden.new(
          name: 'dom-firmware-entry',
          rule: "only the domain library's firmware entries (#{DOM_APPLY}) make a firmware request with " \
                'erx_firmware_request_row',
          design: 'docs/design-fiasco.md#the-firmware-request',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\berx_firmware_request_row\b/,
          sites: [DOM_APPLY, 'liberx/backend/api.h', 'liberx/backend/fiasco/vc_mbox.c', 'liberx/backend/hosted/refused.c']
                 .map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' => "status = erx_firmware_request_row(row, answer, &length);\n",
                  'liberx/system/dom_boot_view.c' => "status = erx_firmware_request_row(row, answer, &length);\n" }
        ),
        # The root's partial-boot entry is the only caller the partial entry
        # may have, and it does not exist yet: nothing calls it but its
        # definition, its declaration, the driver and the fuzz target. Its
        # first caller replaces this rule with one that allows that entry.
        Chokepoints::Forbidden.new(
          name: 'dom-partial-entry-uncalled',
          rule: 'no file calls erx_dom_plan_partial until the root partial-boot entry lands',
          design: 'docs/design-system.md#the-domain-library',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, ERXOS_NIFS]),
          pattern: /\berx_dom_plan_partial\b/,
          sites: [DOM_CORE, DOM_HEADER, DOM_DRIVER, DOM_FUZZ].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/system/dom_boot.c' => "status = erx_dom_plan_partial(&lib->view, id, row, &plan);\n",
                  'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' =>
                    "status = erx_dom_plan_partial(&view, id, row, &plan);\n" }
        )
      ]
    )
  end
end
