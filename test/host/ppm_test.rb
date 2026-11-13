# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/screen_reference'

# The decoder of a screendump (Ppm) reads bytes made from a surface whose size the guest
# chose, so its malformed cases are the point: each is refused with a typed error and none
# sizes anything from an unchecked field. The reference check is the one place a screen
# equals a checked-in digest.
class PpmTest < Minitest::Test
  REFERENCES = File.expand_path('../display/reference', __dir__)
  PIXELS = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c".b.freeze

  def ppm(header = "P6\n2 2\n255\n", body = PIXELS) = header.b + body

  def test_rows_come_top_to_bottom_as_rgb888
    image = Erx::Ppm.decode(ppm)
    assert_equal [2, 2], [image.width, image.height]
    assert_equal ["\x01\x02\x03\x04\x05\x06".b, "\x07\x08\x09\x0a\x0b\x0c".b], image.rows
    assert_equal "\x07\x08\x09\x0a\x0b\x0c".b, image.row(1)
    assert_raises(Erx::Ppm::FormatError) { image.row(2) }
  end

  def test_comments_and_any_white_space_in_the_header_are_read
    image = Erx::Ppm.decode(ppm("P6 # made by QEMU\n2\t2\r\n# more\n255\n"))
    assert_equal PIXELS, image.pixels
  end

  def test_the_digest_covers_the_size_and_the_pixels_not_the_encoding
    assert_equal Erx::Ppm.decode(ppm).digest, Erx::Ppm.decode(ppm("P6 #c\n2 2 255 ")).digest
    refute_equal Erx::Ppm.decode(ppm).digest, Erx::Ppm.decode(ppm("P6\n4 1\n255\n")).digest
    assert_equal Erx::Ppm.decode(ppm).digest, Erx::Ppm.decode(Erx::Ppm.decode(ppm).to_ppm).digest
  end

  def test_malformed_pictures_are_refused
    {
      'not P6' => ppm("P3\n2 2\n255\n"),
      'empty' => '',
      'magic only' => 'P6',
      'maxval 65535' => ppm("P6\n2 2\n65535\n"),
      'zero width' => ppm("P6\n0 2\n255\n", ''),
      'zero height' => ppm("P6\n2 0\n255\n", ''),
      'negative width' => ppm("P6\n-2 2\n255\n"),
      'missing number' => ppm("P6\n2\n255\n"),
      'word for a number' => ppm("P6\ntwo 2\n255\n"),
      'number too long' => ppm("P6\n#{'1' * 9} 2\n255\n"),
      'over the size limit' => ppm("P6\n4097 4096\n255\n", ''),
      'a size that would overflow a narrow integer' => ppm("P6\n99999999 99999999\n255\n", ''),
      'no white space after maxval' => ppm("P6\n2 2\n255", PIXELS),
      'truncated pixels' => ppm("P6\n2 2\n255\n", PIXELS.byteslice(0, 11)),
      'trailing bytes' => ppm("P6\n2 2\n255\n", "#{PIXELS}\x00".b),
      'unterminated comment' => "P6 # #{'x' * 400}",
      'header past the limit' => "P6#{' ' * 300}2 2 255\n#{PIXELS}",
      'NUL in a number' => ppm("P6\n2\x002\n255\n")
    }.each do |name, bytes|
      assert_raises(Erx::Ppm::FormatError, name) { Erx::Ppm.decode(bytes) }
    end
    assert_raises(Erx::Ppm::FormatError) { Erx::Ppm.decode(nil) }
  end

  # Mutations of a good picture either decode to a picture whose size matches its pixels or
  # raise FormatError; nothing else escapes and nothing is read past the bytes.
  def test_mutated_pictures_never_escape_as_anything_but_a_format_error
    random = Random.new(7)
    seed = ppm("P6\n2 2\n255\n")
    5000.times do
      bytes = seed.dup
      random.rand(1..4).times do
        case random.rand(3)
        when 0 then bytes = bytes.byteslice(0, random.rand(0..bytes.bytesize))
        when 1 then bytes << random.bytes(random.rand(1..8))
        else bytes.setbyte(random.rand(bytes.bytesize), random.rand(256)) unless bytes.empty?
        end
      end
      image = Erx::Ppm.decode(bytes)
      assert_equal image.width * image.height * 3, image.pixels.bytesize
    rescue Erx::Ppm::FormatError
      nil
    end
  end

  def test_a_file_is_read_as_a_regular_file_and_never_through_a_link
    Dir.mktmpdir('erx-ppm-') do |directory|
      path = File.join(directory, 'screen.ppm')
      File.binwrite(path, ppm)
      assert_equal PIXELS, Erx::Ppm.read_file(path).pixels
      link = File.join(directory, 'link.ppm')
      File.symlink(path, link)
      assert_raises(Erx::Ppm::FormatError) { Erx::Ppm.read_file(link) }
      assert_raises(Erx::Ppm::FormatError) { Erx::Ppm.read_file(File.join(directory, 'absent.ppm')) }
      assert_raises(Erx::Ppm::FormatError) { Erx::Ppm.read_file(directory) }
    end
  end

  def test_the_checked_in_reference_picture_is_the_picture_its_digest_names
    reference = Erx::ScreenReference.load(REFERENCES, 'no-gpu-driver')
    picture = Erx::ScreenReference.picture(reference)
    assert_equal reference.digest, picture.digest
    assert_equal [reference.width, reference.height], [picture.width, picture.height]
    assert_operator File.size(reference.picture_path), :<, 16_384
  end

  def test_a_screen_equal_to_the_reference_passes_and_any_other_names_both_digests
    reference = Erx::ScreenReference.load(REFERENCES, 'no-gpu-driver')
    picture = Erx::ScreenReference.picture(reference)
    assert_nil Erx::ScreenReference.check(picture, directory: REFERENCES, name: 'no-gpu-driver')
    changed = picture.pixels.dup
    changed.setbyte(0, changed.getbyte(0) ^ 1)
    other = Erx::Ppm::Image.new(width: picture.width, height: picture.height, pixels: changed)
    error = assert_raises(Erx::ScreenReference::Mismatch) do
      Erx::ScreenReference.check(other, directory: REFERENCES, name: 'no-gpu-driver')
    end
    assert_includes error.message, other.digest
    assert_includes error.message, reference.digest
    assert_includes error.message, 'no-gpu-driver.ppm.gz'
  end

  def test_a_malformed_digest_file_or_name_is_refused
    Dir.mktmpdir('erx-ref-') do |directory|
      ['', "#{'0' * 63} 2x2\n", "#{'g' * 64} 2x2\n", "#{'0' * 64} 2x2", "#{'0' * 64}  2x2\n", "#{'0' * 64} 0x2\n",
       "#{'0' * 64} 2x2\nextra\n"].each do |text|
        File.write(File.join(directory, 'bad.sha256'), text)
        assert_raises(Erx::Error, text) { Erx::ScreenReference.load(directory, 'bad') }
      end
      assert_raises(Erx::Error) { Erx::ScreenReference.load(directory, '../bad') }
      assert_raises(Erx::Error) { Erx::ScreenReference.load(directory, 'absent') }
    end
  end
end
