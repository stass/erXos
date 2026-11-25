# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/splash_mark'
require_relative '../../tools/lib/erx/origin'

# The splash's mark generator (tools/lib/erx/splash_mark.rb): the rasteriser
# gives exact coverage bytes for a filled square, a square with a square
# hole under the even-odd rule, and edges that cut pixels in half across
# and down; and the path reader starts a subpath that follows Z at the
# closed subpath's first point, as SVG's closepath says; it refuses a
# coordinate too large for a float and a mark far taller than wide; and the
# generated module declares BSD-2-Clause, the license of the logo bitmap.
class ErxSplashMarkTest < Minitest::Test
  MARK = Erx::SplashMark

  def square(left, top, right, bottom) = [[left, top], [right, top], [right, bottom], [left, bottom]]

  def rows(mask) = mask.pixels.bytes.each_slice(mask.width).to_a

  def test_a_square_covers_every_pixel
    mask = MARK.rasterise([square(0, 0, 1, 1)], width: 3)
    assert_equal [3, 3], [mask.width, mask.height]
    assert_equal [[255] * 3] * 3, rows(mask)
  end

  def test_a_square_inside_a_square_is_a_hole
    mask = MARK.rasterise([square(0, 0, 4, 4), square(1, 1, 3, 3)], width: 4)
    assert_equal [[255, 255, 255, 255], [255, 0, 0, 255], [255, 0, 0, 255], [255, 255, 255, 255]], rows(mask)
  end

  # The second rectangle ends half a pixel into column 2 and half a pixel
  # into row 1: pixels it half covers read 128 (127.5 rounded), the pixel
  # it quarter covers 64 (63.75 rounded).
  def test_an_edge_through_a_pixel_covers_its_share
    mask = MARK.rasterise([square(0, 0, 4, 1), square(0, 1, 2.5, 1.5)], width: 4)
    assert_equal [[255, 255, 255, 255], [128, 128, 64, 0]], rows(mask)
  end

  def test_a_subpath_after_z_starts_at_the_closed_subpaths_first_point
    svg = '<path fill-rule="evenodd" d="M 0 0 L 4 0 L 4 4 Z L 0 4 L 2 2 Z"/>'
    assert_equal [[[0.0, 0.0], [4.0, 0.0], [4.0, 4.0]], [[0.0, 0.0], [0.0, 4.0], [2.0, 2.0]]], MARK.outline(svg)
  end

  def test_a_coordinate_too_large_for_a_float_is_refused
    huge = "1#{'0' * 400}"
    error = assert_raises(MARK::MarkError) { MARK.outline(%(<path fill-rule="evenodd" d="M 0 0 L #{huge} 0 L 0 1 Z"/>)) }
    assert_match(/too large/, error.message)
  end

  def test_a_mark_far_taller_than_wide_is_refused
    assert_raises(MARK::MarkError) { MARK.rasterise([square(0, 0, 1, 5)], width: 2) }
  end

  def test_z_before_a_moveto_is_refused
    assert_raises(MARK::MarkError) { MARK.outline('<path fill-rule="evenodd" d="Z M 0 0 L 1 0 L 1 1 Z"/>') }
  end

  # The image's provenance record resolves a generated source by its own
  # SPDX line, as pack_provenance.rb does for a file outside every import,
  # with no fallback; that header is what licenses the logo bitmap under
  # BSD-2-Clause.
  def test_the_generated_module_declares_bsd_2_clause
    module_text = MARK.erlang(MARK.rasterise([square(0, 0, 1, 1)], width: 2))
    resolved = Erx::Attribution.for_own_file(bytes: module_text)
    assert_equal 'BSD-2-Clause', resolved.fetch('license')
  end
end
