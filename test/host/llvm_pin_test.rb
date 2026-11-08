# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/llvm_pin'

# Erx::LlvmPin (tools/lib/erx/llvm_pin.rb): an image builds only with the
# pinned LLVM release; the host-only test gates take any patch release of its
# major.minor.
class LlvmPinTest < Minitest::Test
  def clang(version) = "Homebrew clang version #{version}\n"
  def lld(version) = "Homebrew LLD #{version} (compatible with GNU linkers)\n"

  def test_image_takes_only_the_pin
    assert_equal '23.1.3', Erx::LlvmPin.admit(tool: 'clang', first_line: clang('23.1.3'), purpose: :image)
    assert_equal '23.1.3', Erx::LlvmPin.admit(tool: 'lld', first_line: lld('23.1.3'), purpose: :image)
    %w[23.1.2 23.1.4 23.2.0 22.1.3].each do |version|
      error = assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: 'clang', first_line: clang(version), purpose: :image) }
      assert_equal 'clang does not report the required LLVM 23.1.3 version', error.message
      assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: 'lld', first_line: lld(version), purpose: :image) }
    end
  end

  def test_host_tests_take_a_patch_release_of_the_pin
    assert_equal '23.1.2', Erx::LlvmPin.admit(tool: 'clang', first_line: clang('23.1.2'), purpose: :host_tests)
    assert_equal '23.1.4', Erx::LlvmPin.admit(tool: 'lld', first_line: lld('23.1.4'), purpose: :host_tests)
    assert_equal '23.1.3', Erx::LlvmPin.admit(tool: 'clang', first_line: "clang version 23.1.3\n", purpose: :host_tests)
  end

  def test_host_tests_refuse_another_minor_or_major
    %w[22.1.3 22.9.0 23.2.0 23.0.9 24.1.3 123.1.3].each do |version|
      %w[clang lld].each do |tool|
        line = tool == 'clang' ? clang(version) : lld(version)
        error = assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: tool, first_line: line, purpose: :host_tests) }
        assert_equal "#{tool} does not report an LLVM 23.1.x version", error.message
      end
    end
  end

  def test_unrecognized_lines_tools_and_purposes_are_refused
    ['Apple clang version 23.1.3', 'clang version 23.1', '', "clang version 23.1.3x\n"].each do |line|
      assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: 'clang', first_line: line, purpose: :host_tests) }
    end
    assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: 'gcc', first_line: clang('23.1.3'), purpose: :image) }
    assert_raises(Erx::Error) { Erx::LlvmPin.admit(tool: 'clang', first_line: clang('23.1.3'), purpose: :release) }
  end
end
