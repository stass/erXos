# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    IMAGE_PLAN = 'liberx/image_plan.c'
    # The generated reader that defines and declares the decoder, and the
    # header of the layout's offsets, under the paths the rules read the
    # generated tree at.
    IMAGE_DECODER = %w[liberx/generated/abi_reader.c include/erx/abi_reader.h include/erx/abi.h fuzz/generated/abi.c].freeze

    declare_group(
      rules: [
        # The executable-header rule's twin for the archive's own format: an
        # image entry is loaded by the plan erx_image_plan makes of it, and the
        # boot image validator (kernel/core/pack.c) checks its layout over that
        # same plan, so a segment rule is written once and no other code turns
        # a manifest's segments into a load.
        Chokepoints::Forbidden.new(
          name: 'image-manifest-reader',
          rule: "only erx_image_plan (#{IMAGE_PLAN}) reads an image manifest's segments",
          design: 'docs/design.md#chokepoint-checks',
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, 'otp/erts/emulator/nifs/erxos/**/*']),
          pattern: /\b(?:erx_image_segment_decode|ERX_IMAGE_SEGMENT_OFF_\w+)\b/,
          sites: [IMAGE_PLAN, *IMAGE_DECODER].map { |path| Chokepoints::Site.new(glob: path) },
          seed: { 'liberx/backend/fiasco/service_task.c' =>
                    "(void)erx_image_segment_decode(image + ERX_IMAGE_MANIFEST_SIZE, ERX_IMAGE_SEGMENT_SIZE, &segment);\n" }
        )
      ],
      unchecked_objects: [IMAGE_PLAN]
    )
  end
end
