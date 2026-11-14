# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # erx_memdraw, the display domain's pixel primitives (docs/design-display.md,
    # G2 and Chokepoints): erXos's own sources, its copy of libmemdraw, and the
    # host harnesses in test/display, which drive erx_memdraw and the 9front build.
    MEMDRAW_SCOPE = Chokepoints::Scope.new(own: true, extra: ['display/libmemdraw/**/*'])
    MEMDRAW_HARNESSES = Chokepoints::Site.new(glob: 'test/display/**/*')

    declare_group(
      rules: [
        # memimagedraw walks the rectangles it is given, so every draw, a
        # client's d and each draw a shape breaks into, takes them from
        # erx_draw_clip: erx_memdraw_draw and memdraw, the shapes' one way to
        # draw, are its only callers, and nothing else makes an erx_clip_t.
        Chokepoints::Forbidden.new(
          name: 'memdraw-clip',
          rule: 'only erx_memdraw_draw and memdraw (display/memdraw/erx_memdraw.c) call memimagedraw, ' \
                'with the rectangles erx_draw_clip computed',
          design: 'docs/design-display.md#chokepoints',
          scope: MEMDRAW_SCOPE,
          pattern: /\b(?:memimagedraw|erx_clip_t)\b/,
          sites: [*%w[display/libmemdraw/draw.c display/libmemdraw/memdraw.h display/memdraw/erx_draw_clip.c
                      display/memdraw/erx_memdraw.c].map { |path| Chokepoints::Site.new(glob: path) },
                  MEMDRAW_HARNESSES],
          seed: { 'display/libmemdraw/line.c' => "memimagedraw(dst, src, memopaque, &clip, op);\n" }
        ),
        # Pixel memory is reached only by the functions that walk a rectangle
        # one of the checkers produced: libmemdraw's draw.c under
        # memimagedraw (erx_draw_clip), load.c, unload.c and cload.c (a
        # rectangle erx_memdraw's rows_of checked inside the image),
        # alloc.c's allocation and fill (the whole image, which badrect
        # admitted), and erx_memdraw's snapshot (a whole image); and the area NIF's zero/3
        # stores zero over a range of whole pages that erx_area_range_ok checked. The shapes
        # draw only through memdraw.
        Chokepoints::Forbidden.new(
          name: 'memdraw-pixels',
          rule: 'only libmemdraw\'s draw, load, unload, cload and alloc and erx_memdraw\'s snapshot touch pixel memory, ' \
                'and erx_area:zero/3 stores zero over a checked range of whole pages',
          design: 'docs/design-display.md#chokepoints',
          scope: MEMDRAW_SCOPE,
          pattern: /\b(?:bdata|byteaddr|wordaddr)\b/,
          sites: %w[draw.c load.c unload.c cload.c alloc.c badrect.c memdraw.h]
                   .map { |name| Chokepoints::Site.new(glob: "display/libmemdraw/#{name}") } +
                 [Chokepoints::Site.new(glob: 'display/memdraw/erx_memdraw.c')],
          seed: { 'display/libmemdraw/fillpoly.c' => "*byteaddr(dst, Pt(x, y)) = 0;\n" }
        ),
        # An image a term can reach is freed by its resource's destructor
        # (image_dtor) alone, when no term refers to it; the NIF's test-only
        # cload frees the image it made itself.
        Chokepoints::Forbidden.new(
          name: 'memdraw-free',
          rule: 'only the NIF (display/memdraw/erx_memdraw_nif.c) frees an erx_memdraw image',
          design: 'docs/design-display.md#chokepoints',
          scope: MEMDRAW_SCOPE,
          pattern: /\berx_memdraw_free\b/,
          sites: [*%w[display/memdraw/erx_memdraw_nif.c display/memdraw/erx_memdraw.h display/memdraw/erx_memdraw.c]
                   .map { |path| Chokepoints::Site.new(glob: path) }, MEMDRAW_HARNESSES],
          seed: { 'display/memdraw/erx_draw_clip.c' => "erx_memdraw_free(image);\n" }
        ),
        # A firmware framebuffer is device memory, which takes only aligned
        # accesses, so erx_memdraw's store/4 (erx_memdraw_nif.c) writes it
        # alone, through erx_fb_store's aligned 32-bit stores after its
        # layout and rectangles are checked whole. The device NIF maps it and
        # hands out its view (erx_framebuffer.h); nothing else names the view,
        # the mapping or the store.
        Chokepoints::Forbidden.new(
          name: 'memdraw-framebuffer',
          rule: 'only erx_memdraw\'s store (display/memdraw/erx_memdraw_nif.c, through erx_fb_store) ' \
                'writes a firmware framebuffer',
          design: 'docs/design-display.md#chokepoints',
          scope: MEMDRAW_SCOPE,
          pattern: /\b(?:erx_framebuffer|erx_framebuffer_view|erx_device_framebuffer_memory|erx_fb_store)\b/,
          sites: [*%w[display/memdraw/erx_fb_store.c display/memdraw/erx_fb_store.h display/memdraw/erx_memdraw_nif.c
                      otp/erts/emulator/nifs/erxos/erx_framebuffer.h otp/erts/emulator/nifs/erxos/erx_device_nif.c
                      otp/erts/emulator/nifs/erxos/erx_device.c otp/erts/emulator/nifs/erxos/erx_device.h
                      test/fixtures/fb_store_driver.c].map { |path| Chokepoints::Site.new(glob: path) },
                  MEMDRAW_HARNESSES],
          seed: { 'display/memdraw/erx_draw_clip.c' => "(void)erx_fb_store(&src, &dst, &geometry, &r, 1);\n" }
        )
      ]
    )
  end
end
