# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/libcxx'

# BeamAsm's C++ runtime is configured without exceptions, RTTI or localisation
# (docs/design-runtime.md, "BeamAsm"), static only, with musl's pthreads, for the
# compiler and headers ERTS's native build uses.
class LibcxxTest < Minitest::Test
  FLAGS = %w[--target=aarch64-none-elf -nostdinc -isystem /sysroot/include].freeze

  def arguments
    Erx::Libcxx.cache_arguments(compiler: '/llvm/bin/clang', target_flags: FLAGS, install: '/out/install')
               .to_h { |argument| argument.delete_prefix('-D').split('=', 2) }
  end

  def test_the_design_properties_are_switched_off_in_both_libraries
    %w[LIBCXX_ENABLE_EXCEPTIONS LIBCXXABI_ENABLE_EXCEPTIONS LIBCXX_ENABLE_RTTI LIBCXX_ENABLE_LOCALIZATION
       LIBCXX_ENABLE_SHARED LIBCXXABI_ENABLE_SHARED].each { |name| assert_equal 'OFF', arguments.fetch(name), name }
    assert_equal 'libcxx;libcxxabi', arguments.fetch('LLVM_ENABLE_RUNTIMES')
    assert_equal 'ON', arguments.fetch('LIBCXX_HAS_PTHREAD_API')
  end

# tools/erx resolves ERX_CLANG to its real path, which Homebrew's LLVM gives as
# clang-23; the C++ driver is clang++ beside it, not that name with ++ appended.
def test_a_versioned_compiler_finds_clang_plus_plus_beside_it
  versioned = Erx::Libcxx.cache_arguments(compiler: '/llvm/bin/clang-23', target_flags: FLAGS, install: '/out/install')
                         .to_h { |argument| argument.delete_prefix('-D').split('=', 2) }
  assert_equal '/llvm/bin/clang-23', versioned.fetch('CMAKE_C_COMPILER')
  assert_equal '/llvm/bin/clang++', versioned.fetch('CMAKE_CXX_COMPILER')
end

  def test_the_compilers_and_flags_are_the_native_builds
    assert_equal '/llvm/bin/clang', arguments.fetch('CMAKE_C_COMPILER')
    assert_equal '/llvm/bin/clang++', arguments.fetch('CMAKE_CXX_COMPILER')
    assert_equal '/llvm/bin/llvm-ar', arguments.fetch('CMAKE_AR')
    assert_equal FLAGS.join(' '), arguments.fetch('CMAKE_C_FLAGS')
    assert_equal FLAGS.join(' '), arguments.fetch('CMAKE_CXX_FLAGS')
    assert_equal '/out/install', arguments.fetch('CMAKE_INSTALL_PREFIX')
  end
end
