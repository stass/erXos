# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'erts-reads-no-index',
          rule: 'ERTS learns the release only from erx_release_entry, so the index can stay unmapped behind it',
          design: 'docs/design-runtime.md#files',
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/erts/emulator/nifs/erxos/**/*', 'otp/erts/emulator/sys/erxos/**/*']),
          pattern: /\berx_pack_\w+/,
          seed: { 'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(void) { erx_pack_entry_at(0, 0, 0); }\n" }
        )
      ],
      unchecked_objects: %w[liberx/release.c liberx/release_fs.c]
    )
  end
end
