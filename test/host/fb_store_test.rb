# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# The firmware framebuffer's copy, display/memdraw/erx_fb_store.c (docs/design-display.md,
# "The display device"), driven by test/fixtures/fb_store_driver.c under ASan and UBSan:
# strides wider than a row, a framebuffer at an offset in its page, 16-, 24- and 32-bit
# rows widened to whole words, rectangles at the edges, and refused layouts and rectangles
# that write nothing. Each seeded fault in SEEDS removes one check, and the driver must
# then fail.
class FbStoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  STORE = 'display/memdraw/erx_fb_store.c'
  DRIVER = 'test/fixtures/fb_store_driver.c'
  SEEDS = {
    'rectangle past the width' => ['(uint32_t)r.x1 <= geometry->width &&', ''],
    'stride below a row' => ['side->stride >= row &&', ''],
    'length short of the last row' => ['&& last <= side->bytes', '']
  }.freeze

  def setup = @directory = Dir.mktmpdir('erx-fb-store-')

  def teardown = FileUtils.remove_entry(@directory)

  def test_copies_and_refuses
    output, status = Open3.capture2e(build(File.join(ROOT, STORE), 'driver'))
    assert status.success?, output
    assert_equal "ok\n", output
  end

  def test_each_seed_fails_the_driver
    SEEDS.each do |name, (from, to)|
      text = File.read(File.join(ROOT, STORE))
      assert_includes text, from, name
      seeded = File.join(@directory, "seeded-#{name.tr(' ', '-')}.c")
      File.write(seeded, text.sub(from, to))
      _output, status = Open3.capture2e(build(seeded, name.tr(' ', '-')))
      refute status.success?, "#{name}: the driver passed on the seeded copy"
    end
  end

  private

  def build(store, name)
    output = File.join(@directory, name)
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
                                  '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                                  '-I', File.join(ROOT, 'display/memdraw'), store, File.join(ROOT, DRIVER),
                                  '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end
end
