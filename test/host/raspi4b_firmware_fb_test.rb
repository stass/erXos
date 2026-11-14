# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/raspi4b_firmware_fb'

# The raspi4b suite's stand-in for the firmware's framebuffer setup: the program writes the
# model's answer at the addresses cell_addresses finds, so a placeholder found at the wrong
# place, or twice, would have it write over another property of the tree.
class Raspi4bFirmwareFbTest < Minitest::Test
  FB = Erx::Raspi4bFirmwareFb
  LOAD = 0x8000000

  # A stand-in for the tree's bytes: each placeholder's cells at a known 4-byte offset.
  def tree
    bytes = ("\x00".b * 64) + FB::PLACEHOLDERS.fetch(:reg).pack('N*') + ("\x11".b * 4) +
            FB::PLACEHOLDERS.fetch(:width).pack('N') + FB::PLACEHOLDERS.fetch(:height).pack('N')
    bytes + ("\x22".b * 8) + FB::PLACEHOLDERS.fetch(:stride).pack('N')
  end

  def test_finds_each_placeholder_where_the_tree_holds_it
    assert_equal({ reg: LOAD + 64, width: LOAD + 80, height: LOAD + 84, stride: LOAD + 96 },
                 FB.cell_addresses(tree, load: LOAD))
  end

  def test_refuses_a_placeholder_missing_repeated_or_off_a_cell
    stride = FB::PLACEHOLDERS.fetch(:stride).pack('N')
    { 'no stride' => tree.sub(stride, "\x00".b * 4), 'twice' => tree + stride, 'off a cell' => tree.sub(stride, "\x00#{stride}".b) }
      .each do |name, bytes|
      assert_raises(Erx::Error, name) { FB.cell_addresses(bytes, load: LOAD) }
    end
  end

  def test_passes_the_screen_and_the_cells_to_the_program
    defines = FB.defines({ reg: 0x8000260, width: 0x8000250, height: 0x8000240, stride: 0x8000230 })
    assert_includes defines, '-DFB_REG_CELLS=0x8000260u'
    assert_includes defines, '-DFB_STRIDE_CELL=0x8000230u'
    assert_includes defines, format('-DFB_WIDTH=0x%xu', FB::WIDTH)
    assert_includes defines, format('-DFB_ORDER=0x%xu', FB::ORDER)
  end

  # The node the root reads: simple-framebuffer under /chosen, reg's three cells as /chosen's
  # sizes say, and the format the model shows.
  def test_writes_the_node_the_root_reads
    edits = FB.node_edits('/t/fb.dtb')
    assert(edits.all? { |edit| edit.include?('/t/fb.dtb') })
    assert_includes edits, ['-t', 's', '/t/fb.dtb', '/chosen/framebuffer', 'compatible', 'simple-framebuffer']
    assert_includes edits, ['-t', 's', '/t/fb.dtb', '/chosen/framebuffer', 'format', 'x8r8g8b8']
    assert_includes edits, ['-t', 'u', '/t/fb.dtb', '/chosen', '#address-cells', '2']
    assert_equal 3, edits.find { |edit| edit[4] == 'reg' }.drop(5).size
  end
end
