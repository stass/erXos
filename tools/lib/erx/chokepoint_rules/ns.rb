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
        Chokepoints::Elsewhere.new(
          name: 'ns-table-writer', rule: "only erx_ns's process writes the namespace's persistent term",
          design: 'docs/design-files.md#building-binding-and-mounting', check: 'NsWriters, in Checks',
          test: 'test/host/ns_writers_test.rb'
        ),
        Chokepoints::Elsewhere.new(
          name: 'cwd-writer', rule: "only prim_file:set_cwd/1 calls the NIF that stores the working directory",
          design: 'docs/design-files.md#erlang-clients-prim_file-and-erx_file_remote', check: 'NsWriters, in Checks',
          test: 'test/host/ns_writers_test.rb'
        )
      ],
      unchecked_objects: %w[liberx/ns.c]
    )
  end
end
