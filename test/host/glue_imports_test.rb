# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/glue_imports'

# The check that keeps the stopgap's glue from reaching a Fiasco internal not
# on its allowlist, fed the seeded violations the design names.
class GlueImportsTest < Minitest::Test
  M = Erx::GlueImports
  ENTRIES = M.parse("# comment\n\nprintf console erx_probe.cpp\n_ZN5Timer6clockEv clock erx_syscall.cpp\n")

  def test_a_listed_symbol_passes
    assert_empty M.violations(entries: ENTRIES, undefined: { 'erx_probe.cpp' => ['printf'],
                                                             'erx_syscall.cpp' => ['_ZN5Timer6clockEv'] })
  end

  def test_the_cores_interface_needs_no_entry
    assert_empty M.violations(entries: [], undefined: { 'erx_syscall.cpp' => ['erx_dispatch'] })
  end

  def test_the_raw_allocator_is_refused
    refused = M.violations(entries: [], undefined: { 'erx_syscall.cpp' => ['_ZN9Kmem_alloc5allocEm'] })
    assert_equal ['erx_syscall.cpp: _ZN9Kmem_alloc5allocEm is not in erx_glue_imports.txt'], refused
  end

  def test_a_symbol_listed_for_another_file_is_refused
    refused = M.violations(entries: ENTRIES, undefined: { 'erx_probe.cpp' => %w[printf _ZN5Timer6clockEv],
                                                          'erx_syscall.cpp' => ['_ZN5Timer6clockEv'] })
    assert_equal ['erx_probe.cpp: _ZN5Timer6clockEv is not in erx_glue_imports.txt'], refused
  end

  def test_an_entry_nothing_references_is_refused
    refused = M.violations(entries: ENTRIES, undefined: { 'erx_probe.cpp' => ['printf'], 'erx_syscall.cpp' => [] })
    assert_equal ['erx_syscall.cpp: _ZN5Timer6clockEv is listed in erx_glue_imports.txt and no longer referenced'],
                 refused
  end

  def test_a_malformed_line_is_refused
    error = assert_raises(Erx::Error) { M.parse("printf console\n") }
    assert_includes error.message, ':1'
  end

  def test_nm_output_is_read_as_undefined_symbols
    assert_equal %w[printf erx_dispatch], M.undefined_symbols(<<~LISTING)
      erx_syscall.o:
                       U printf
      0000000000000000 T _ZN11Erx_syscall5enterEP10Trap_state
                       U erx_dispatch
                       U printf
    LISTING
  end
end
