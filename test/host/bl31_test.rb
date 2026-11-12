# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bl31'

# The stub header Erx::Bl31.patch_stub fills for the QEMU model, as the Pi firmware does:
# BL31 reads the device tree's address and the kernel's entry from it only once the
# magic is cleared, so a word in the wrong place boots the kernel without its tree.
class Bl31Test < Minitest::Test
  DTB = 0x3000000
  ENTRY = 0x200000

  # A stand-in for bl31.bin: code bytes, then the unfilled header at 0xf0, then more code.
  def image
    header = [Erx::Bl31::STUB_MAGIC, 0, 0, 0].pack('L<4')
    ("\xAA".b * 0xf0) + header + ("\x55".b * 0x100)
  end

  def test_fills_the_header_as_the_firmware_does
    original = image
    patched = Erx::Bl31.patch_stub(original, dtb: DTB, entry: ENTRY)
    magic, version, dtb, entry = patched.byteslice(0xf0, 16).unpack('L<4')
    assert_equal [0, 0], [magic, version]
    assert_equal DTB, dtb, 'dtb_ptr32 is the word at 0xf8'
    assert_equal ENTRY, entry, 'kernel_entry32 is the word at 0xfc'
    assert_equal original.byteslice(0, 0xf0), patched.byteslice(0, 0xf0)
    assert_equal original.byteslice(0x100..), patched.byteslice(0x100..)
    assert_equal image, original, 'the input is not changed'
  end

  def test_refuses_an_image_that_is_not_an_unfilled_stub
    filled = Erx::Bl31.patch_stub(image, dtb: DTB, entry: ENTRY)
    assert_raises(Erx::Error) { Erx::Bl31.patch_stub(filled, dtb: DTB, entry: ENTRY) }
    assert_raises(Erx::Error) { Erx::Bl31.patch_stub(image.byteslice(0, 0xf8), dtb: DTB, entry: ENTRY) }
  end

  def test_refuses_addresses_the_header_or_bl31_cannot_use
    [{ dtb: 0, entry: ENTRY }, { dtb: 1 << 32, entry: ENTRY }, { dtb: DTB + 4, entry: ENTRY },
     { dtb: DTB, entry: 0x80000 - 4 }, { dtb: DTB, entry: ENTRY + 2 }, { dtb: DTB, entry: nil },
     { dtb: 0x10000, entry: ENTRY }, { dtb: ENTRY - 0x1000, entry: ENTRY }].each do |addresses|
      assert_raises(Erx::Error, addresses.inspect) { Erx::Bl31.patch_stub(image, **addresses) }
    end
  end
end
