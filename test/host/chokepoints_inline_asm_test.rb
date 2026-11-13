# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The inline-asm group's own cases: the asm keyword in any spelling, in the kernel or in
# user-mode C, is caught outside the listed files, and upstream OTP's own assembly is not
# erXos's to list.
class ChokepointsInlineAsmTest < Minitest::Test
  include ChokepointsHelper

  SPELLINGS = ['__asm__ volatile("isb")', '__asm volatile("isb")', 'asm volatile("isb")'].freeze

  def found(path, text) = evaluate([rule('inline-asm')], { path => text })

  def test_every_spelling_fails_outside_the_listed_files
    %w[kernel/core/x.c liberx/x.c otp/erts/emulator/nifs/erxos/erx_device.c
       otp/erts/emulator/sys/erxos/x.c erlang/apps/erx_net/c_src/x.c].each do |path|
      SPELLINGS.each { |spelling| refute_empty found(path, "void f(void) { #{spelling}; }\n"), "#{path}: #{spelling}" }
    end
  end

  def test_a_listed_file_and_upstream_otp_pass
    text = "void f(void) { __asm__ volatile(\"dsb sy\" ::: \"memory\"); }\n"
    assert_empty found('otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c', text)
    assert_empty found('liberx/backend/fiasco/arch/aarch64/cache.c', text)
    assert_empty evaluate([rule('inline-asm')], { 'otp/erts/include/internal/ethr_atomic.h' => text },
                          imported: ['otp/erts/include/internal/ethr_atomic.h'])
  end

  # A word that only contains the keyword is not it.
  def test_an_identifier_containing_asm_passes
    assert_empty found('liberx/x.c', "int erx_asm_count, asmx, x_asm;\n")
  end
end
