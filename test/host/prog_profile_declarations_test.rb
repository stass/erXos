# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# The frame protocol declarations the generator refuses (docs/design-abi.md#program-protocol):
# each case adds kinds and a frame to a copy of abi/protocols/prog.txt, and validating the
# ABI must fail with the case's message.
class ProgProfileDeclarationsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TABLE = 'abi/protocols/prog.txt'
  ANCHOR = "  frame start to erx_start start\n"
  PROBE = '  frame probe from erx_probe probe'
  NESTED = (2..17).map { |level| "  tuple d#{level} d#{level - 1}" }.join("\n")
  TOTALS = (1..9).map { |n| "  total t#{n} 64\n  text x#{n} max 8 sum t#{n}" }.join("\n")

  CASES = {
    "  tuple d1 fd\n#{NESTED}\n  tuple probe d17" => /kinds nest \d+ deep, past 16/,
    "  tuple probe later\n  tuple later fd" => /unknown kind later/,
    "  union probe\n    case a fd fd\n    case a =b fd" => /two cases are selected by the same arity and leading atoms/,
    "  union probe\n    case a_b fd\n    case a =b" => /two cases share a C name/,
    "  list probe cwd max 2 ascending" => /an ascending list needs an integer or atom key/,
    "  list probe cap max 4" => /a unique kind is never a list's element/,
    "  integer probe u16 in 0 10 refers argv" => /refers names a list whose elements are not tuples/,
    "  integer wide u32 in 0 5000\n  tuple wide_entry wide\n  list wides wide_entry max 4\n  " \
    "integer wide_ref u32 in 0 5000 refers wides\n  tuple probe wides wide_ref" => /ranges over more than 4096 values/,
    "  integer twice u16 in 0 1023 refers fds\n  tuple probe fds fds twice" => /fds can occur twice in one frame/,
    '  integer probe u8 in 5 4' => /MIN above MAX/,
    '  integer probe u8 in 0 256' => /outside 0\.\.255/,
    '  integer probe u16 values 1 1' => /duplicate value/,
    '  text probe max 8 sum nothing' => /sum names no total nothing/,
    "  frame probe2 from erx_prog slot request\n" => /two frames of one direction share a tag and slot form/,
    "  frame probe2 to erx_prog report\n" => /two frames of one direction share a tag and slot form/,
    "  frame probe2 from erx_prog notice\n" => /two frames of one direction share a tag and slot form/,
    '  text probe max 8 length u16' => /describe 9P2000\.L and fail in a frame protocol/,
    "  integer cap2 u64 unique\n  tuple probe cap2" => /a protocol has at most one unique kind/,
    '  text probe max 8 refuse nul slash' => /a frame protocol's text refuses only nul/,
    "  integer probe u16 in 0 1023 refers fds unique\n  tuple probe2 probe\n  frame probe from erx_probe probe2\n" =>
      /a kind is unique or refers, not both/,
    "  union probe\n    case a =b" => /a case without fields has no literal atoms/,
    "  union probe\n    case a writer_state\n  frame probe to erx_probe probe\n" => /union probe's case a holds a capability inside writer_state/,
    "#{TOTALS}\n  tuple probe #{(1..9).map { |n| "x#{n}" }.join(' ')}" => /at most 8 totals/
  }.freeze

  def test_the_unedited_table_is_valid
    Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT))
  end

  def test_malformed_frame_declarations_are_refused
    CASES.each do |addition, message|
      # A case that declares its own frame adds no probe frame.
      lines = addition.end_with?("\n") ? addition : "#{addition}\n#{PROBE}\n"
      error = assert_raises(Erx::Error, addition) { validate_with(lines) }
      assert_match(message, error.message, addition)
    end
  end

  private

  def validate_with(lines)
    Dir.mktmpdir('erx-prog-table-') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      path = File.join(root, TABLE)
      text = File.binread(path)
      raise "no #{ANCHOR.strip} in #{TABLE}" unless text.include?(ANCHOR)

      File.binwrite(path, text.sub(ANCHOR) { "#{lines}#{ANCHOR}" })
      Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    end
  end
end
