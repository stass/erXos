# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'ns-result-writes',
          rule: 'only erx_ns_resolve writes a resolved path, so a path reaches a provider only through it',
          design: 'docs/design-files.md#invariants',
          scope: Chokepoints::Scope.new(own: true, extra: ['otp/erts/emulator/nifs/erxos/**/*']),
          pattern: /\bres_(?:mount|nnames|names_length|path_length|names|path)\b\s*(?:\[[^\]]*\]\s*)?(?:[-+*\/|&^]?=(?!=)|\+\+|--)/,
          sites: [Chokepoints::Site.new(glob: 'liberx/ns.c')],
          seed: { 'liberx/seeded.c' => "void f(erx_ns_result_t *out) { out->res_names_length = 0; }\n",
                  'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(erx_ns_result_t *out) { out->res_path[0] = 0; }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'erts-reads-no-index',
          rule: 'ERTS learns the release only from erx_release_entry, so the index can stay unmapped behind it',
          design: 'docs/design-runtime.md#files',
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/erts/emulator/nifs/erxos/**/*', 'otp/erts/emulator/sys/erxos/**/*']),
          pattern: /\berx_pack_\w+/,
          seed: { 'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(void) { erx_pack_entry_at(0, 0, 0); }\n" }
        )
      ],
      unchecked_objects: %w[liberx/backend/hosted/release.c liberx/backend/hosted/release.h liberx/ns.c
                            liberx/release.c liberx/release_fs.c]
    )
  end
end
