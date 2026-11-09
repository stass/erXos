# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

class ChokepointsMemdrawTest < Minitest::Test
  include ChokepointsHelper

  LIBMEMDRAW = 'display/libmemdraw'

  # A draw outside the two funnels, an erx_clip_t not from erx_draw_clip, a
  # shape that writes pixels itself and a free outside the NIF are refused,
  # in erXos's own code and in its copy of libmemdraw alike.
  def test_only_the_listed_functions_draw_touch_pixels_and_free
    rules = %w[memdraw-clip memdraw-pixels memdraw-free].map { |name| rule(name) }
    imported = ["#{LIBMEMDRAW}/draw.c", "#{LIBMEMDRAW}/line.c", "#{LIBMEMDRAW}/fillpoly.c", "#{LIBMEMDRAW}/arc.c"]
    allowed = {
      'display/memdraw/erx_memdraw.c' => "erx_clip_t clip;\nmemimagedraw(dst, src, mask, &clip, op);\n" \
                                         "memmove(copy->data->bdata, image->data->bdata, n);\nerx_memdraw_free(i);\n",
      "#{LIBMEMDRAW}/draw.c" => "memimagedraw(Memimage *dst, Memimage *src, Memimage *mask, const erx_clip_t *clip, int op)\n" \
                                "p = byteaddr(dst, r.min);\n",
      "#{LIBMEMDRAW}/arc.c" => "memdraw(mask, rect, figure, rect.min, wedge, rect.min, S);\n",
      'display/memdraw/erx_memdraw_nif.c' => "erx_memdraw_free(res->image);\n"
    }
    assert_empty evaluate(rules, allowed, imported: imported)
    refused = {
      "#{LIBMEMDRAW}/line.c" => "memimagedraw(dst, src, memopaque, &clip, op);\n",
      "#{LIBMEMDRAW}/arc.c" => "erx_clip_t forged = { rect, rect, rect };\n",
      "#{LIBMEMDRAW}/fillpoly.c" => "*byteaddr(dst, Pt(x, y)) = 0;\n",
      'display/memdraw/erx_memdraw_nif.c' => "uchar *p = image->data->bdata;\n",
      'display/memdraw/erx_draw_clip.c' => "erx_memdraw_free(image);\n"
    }
    found = refused.map { |path, text| evaluate(rules, { path => text }, imported: imported).map(&:rule) }
    assert_equal [['memdraw-clip'], ['memdraw-clip'], ['memdraw-pixels'], ['memdraw-pixels'], ['memdraw-free']], found
  end
end
