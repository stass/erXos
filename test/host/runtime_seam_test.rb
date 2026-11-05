# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runtime_seam'

# The name check of `make check-runtime-seam`: what it refuses, on a list and on a
# real compiled object.
class RuntimeSeamTest < Minitest::Test
  Seam = Erx::RuntimeSeam

  def test_the_list_is_names_in_sections
    parsed = Seam.parse_imports("# comment\n[libc]\nmalloc # why\nfree realloc\n\n[macos]\nopendir$INODE64\n")
    assert_equal({ 'libc' => %w[malloc free realloc], 'macos' => ['opendir$INODE64'] }, parsed)
  end

  def test_a_malformed_list_does_not_load
    { "malloc\n" => /before any section/, "[a]\nnot-a-name\n" => /not a name/, "[a]\n[a]\n" => /opened twice/ }
      .each { |text, pattern| assert_match(pattern, assert_raises(Erx::Error) { Seam.parse_imports(text) }.message) }
  end

  def test_nm_output_loses_the_mach_o_underscore_and_file_headers
    assert_equal %w[malloc __error], Seam.symbol_names("sys.o:\n_malloc\n___error\n\n_malloc\n")
  end

  def test_a_name_off_the_list_fails_naming_the_object
    report = Seam.check(undefined_by_object: { 'sys.o' => %w[open malloc erx_clock_ns internal] },
                        inside: %w[erx_clock_ns internal], imports: { 'libc' => %w[malloc] })
    assert_equal [Seam::Violation.new(object: 'sys.o', name: 'open')], report.violations
  end

  def test_a_listed_name_nobody_imports_is_reported_so_the_list_can_shrink
    report = Seam.check(undefined_by_object: { 'sys.o' => %w[malloc] }, inside: [],
                        imports: { 'libc' => %w[malloc free] })
    assert_empty report.violations
    assert_equal %w[free], report.unused
  end

  # A call to `fork` in a real object fails the check, and a call to liberx does not.
  def test_a_real_object_calling_fork_fails
    skip 'nm reads Mach-O objects only on a macOS host' unless RUBY_PLATFORM.include?('darwin')

    Dir.mktmpdir('erx-seam-') do |directory|
      source = File.join(directory, 'calls.c')
      File.write(source, "extern int fork(void);\nextern int erx_call(void);\nint f(void) { return fork() + erx_call(); }\n")
      object = File.join(directory, 'calls.o')
      liberx = File.join(directory, 'liberx.o')
      File.write("#{source}.liberx.c", "int erx_call(void) { return 0; }\n")
      assert system('clang', '-c', source, '-o', object), 'clang compiles the seeded object'
      assert system('clang', '-c', "#{source}.liberx.c", '-o', liberx), 'clang compiles the seeded liberx'
      imports = File.join(directory, 'imports.txt')
      File.write(imports, "[libc]\nmalloc\n")
      # The second object stands for a link that brought in what no listed object shows.
      report = Seam.check_objects(objects: [liberx], executable: object, liberx: liberx, imports_path: imports)
      assert_equal [Seam::Violation.new(object: object, name: 'fork')], report.violations
      report = Seam.check_objects(objects: [object], executable: liberx, liberx: liberx, imports_path: imports)
      assert_equal [Seam::Violation.new(object: object, name: 'fork')], report.violations
    end
  end
end
