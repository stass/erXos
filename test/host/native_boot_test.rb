# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/native_boot'

# What the gate's native_boot suite judges a transcript by. The boots themselves
# run under `tools/erx check-qemu`; here is what each root line means for an
# image, without a guest.
class NativeBootTest < Minitest::Test
  M = Erx::NativeBoot
  BUILT = Struct.new(:build_id, :index_hash).new('b0a36f6eb31731fa', 'dc9c' * 16)
  GOOD = "erx: root task: build b0a36f6eb31731fa index #{'dc9c' * 16} entries 6\r\n".b

  def verifier = M.checkpoints(BUILT).last.fetch(:verify)

  def test_the_root_line_of_this_image_passes
    assert_match M.root_line(BUILT), GOOD
    verifier.call(GOOD)
  end

  def test_a_root_line_of_another_build_fails
    other = GOOD.sub('b0a36f6eb31731fa', 'b0a36f6eb31731fb')
    error = assert_raises(Erx::Error) { verifier.call(other) }
    assert_match(/not this image/, error.message)
  end

  def test_a_root_line_of_another_index_fails
    assert_raises(Erx::Error) { verifier.call(GOOD.sub('dc9c', 'dc9d')) }
  end

  # A root that refused still opens its line the same way, so the refusal's
  # reason reaches the report instead of a deadline.
  def test_a_refusal_fails_at_once_and_names_its_reason
    refusal = "erx: root task refused the boot: record_extent\r\n".b
    assert_match M.checkpoints(BUILT).last.fetch(:pattern), refusal
    error = assert_raises(Erx::Error) { verifier.call(refusal) }
    assert_includes error.message, 'record_extent'
  end

  def test_the_root_line_comes_after_the_banner
    assert_equal %w[bootstrap-memory erxos-art erxos-banner development-warning root-task],
                 M.checkpoints(BUILT).map { |point| point.fetch(:name) }
  end

  def test_a_root_needs_both_tools_named
    [['', 'ld.lld'], ['clang', '']].each do |compiler, linker|
      assert_raises(Erx::Error) do
        Erx::NativeRoot.new(root: Dir.pwd, runner: Object.new, compiler: compiler, linker: linker, fiasco: Object.new)
      end
    end
  end
end
