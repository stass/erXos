# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/compiler_rt'

# CompilerRt names its sources by hand from compiler-rt's own lists, so a new pin of
# llvm-project that adds, renames or drops a binary128 helper must change the list.
class CompilerRtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The two half-precision conversions CompilerRt leaves out, and why is in its comment.
  HALF = %w[extendhftf2 trunctfhf2].freeze

  def builtins
    File.join(Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree(Erx::CompilerRt::SOURCE_ID),
              Erx::CompilerRt::BUILTINS)
  end

  # The overflow-trapping ti helpers CompilerRt leaves out.
  TRAPPING = %w[absvti2 addvti3 mulvti3 negvti2 subvti3].freeze

  # One list of compiler-rt's CMakeLists.txt, read as data, by its source names.
  def cmake_list(name)
    body = File.read(File.join(builtins, 'CMakeLists.txt'))[/^set\(#{name}\n(.*?)^\)/m, 1]
    refute_nil body, "CMakeLists.txt sets no #{name}"
    body.split.map { |source| File.basename(source, '.c') }
  end

  def test_binary128_family_is_compiler_rts_own_list
    assert_equal (cmake_list('GENERIC_TF_SOURCES') - HALF).sort, Erx::CompilerRt::BINARY128.sort
  end

  # The 128-bit integer helpers of GENERIC_SOURCES, named for a ti operand or result.
  def test_integer128_family_is_compiler_rts_own_list
    listed = cmake_list('GENERIC_SOURCES').grep(/ti\d?\z|\Afloat(?:un)?ti/).grep_v(/xf/)
    assert_equal (listed - TRAPPING).sort, Erx::CompilerRt::INTEGER128.sort
  end

  def test_every_source_is_in_the_pinned_tree
    missing = Erx::CompilerRt::SOURCES.reject { |name| File.file?(File.join(builtins, name)) }
    assert_empty missing
    assert File.file?(File.join(ROOT, Erx::CompilerRt.notice(root: ROOT, runner: nil)))
  end
end
