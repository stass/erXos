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

  # The generated reads, as make check scans them under the path they mirror,
  # pass both rules: their header is the one place their instructions are.
  def test_the_generated_reads_pass_both_rules
    root = File.expand_path('../..', __dir__)
    files = Erx::SysregHeaders.generation(root: root).files
    assert_empty evaluate([rule('inline-asm'), rule('sysreg-read')], files)
  end

  # The generated header is a site of inline-asm, so the instructions it
  # holds are what the generator writes: a register read and its barrier.
  def test_the_generated_reads_hold_only_reads_and_barriers
    reads = Erx::SysregHeaders.generation(root: File.expand_path('../..', __dir__)).files.fetch(Erx::SysregHeaders::READS)
    statements = reads.lines.grep(Rules::ASM_KEYWORD).map(&:strip)
    refute_empty statements
    allowed = /\A__asm__ volatile\("(?:mrs %0, S[0-3]_[0-7]_C\d+_C\d+_[0-7]" : "=r"\(value\)|isb" ::: "memory")\);\z/
    statements.each { |statement| assert_match allowed, statement }
  end

  # A read outside the listed files is refused, whether it calls a generated
  # read, includes their header to reach one through a macro, or holds its
  # instruction itself, in the kernel, beside the generated header or in
  # user mode.
  def test_a_read_outside_the_listed_files_fails
    call = "unsigned long f(void) { return erx_sysreg_id_aa64pfr0_el1_read(); }\n"
    %w[kernel/core/x.c kernel/arch/aarch64/x.c include/erx/arch/aarch64/cpu_id.h liberx/x.c].each do |path|
      refute_empty evaluate([rule('sysreg-read')], { path => call }), path
    end
    pasted = "#include \"erx/arch/aarch64/sysreg.h\"\n#define RD(r) erx_sysreg_##r##_read()\n" \
             "unsigned long f(void) { return RD(midr_el1); }\n"
    %w[kernel/core/x.c liberx/x.c otp/erts/emulator/nifs/erxos/x.c].each do |path|
      refute_empty evaluate([rule('sysreg-read')], { path => pasted }), path
    end
    mrs = "static inline unsigned long f(void) { unsigned long v; __asm__ volatile(\"mrs %0, midr_el1\" : \"=r\"(v)); return v; }\n"
    %w[include/erx/arch/aarch64/sysreg_fields.h include/erx/arch/aarch64/x.h kernel/arch/aarch64/cpu_id.c].each do |path|
      refute_empty found(path, mrs), path
    end
  end

  # A word that only contains the keyword is not it.
  def test_an_identifier_containing_asm_passes
    assert_empty found('liberx/x.c', "int erx_asm_count, asmx, x_asm;\n")
  end
end
