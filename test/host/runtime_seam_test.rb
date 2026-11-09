# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
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

  def test_an_own_list_binds_its_one_object
    imports = { 'only_erx_stdio_nif' => %w[poll], 'common' => %w[read] }
    own = Erx::RuntimeSeam.check(undefined_by_object: { 'x/erx_stdio_nif.o' => %w[poll read] }, inside: [], imports: imports)
    assert_empty own.violations
    assert_empty own.unused
    other = Erx::RuntimeSeam.check(undefined_by_object: { 'x/sys.o' => %w[poll read] }, inside: [], imports: imports)
    assert_equal %w[poll], other.violations.map(&:name)
  end

  # Only the NIF of erx_watchdog may pet: the real list names the pet in that object's own section.
  def test_only_the_watchdog_nif_may_pet
    imports = Seam.parse_imports(File.read(File.expand_path("../../otp/#{Seam::IMPORTS_FILE}", __dir__)))
    pet = %w[erx_watchdog_pet]
    allowed = Seam.check(undefined_by_object: { "x/erx_watchdog_nif.o" => pet }, inside: [], imports: imports)
    assert_empty allowed.violations
    other = Seam.check(undefined_by_object: { "x/erx_stdio_nif.o" => pet, "x/sys.o" => pet }, inside: [], imports: imports)
    assert_equal %w[x/erx_stdio_nif.o x/sys.o], other.violations.map(&:object)
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
      File.write(imports, "[liberx]\nerx_call\n[libc]\nmalloc\n")
      # The second object stands for a link that brought in what no listed object shows.
      report = Seam.check_objects(objects: [liberx], executable: object, liberx: liberx, imports_path: imports)
      assert_equal [Seam::Violation.new(object: object, name: 'fork')], report.violations
      report = Seam.check_objects(objects: [object], executable: liberx, liberx: liberx, imports_path: imports)
      assert_equal [Seam::Violation.new(object: object, name: 'fork')], report.violations
    end
  end

  # A name liberx defines and the list leaves out fails the hosted check, as does a name
  # only the native build's section lists.
  def test_a_real_object_calling_what_only_liberx_defines_fails
    skip 'nm reads Mach-O objects only on a macOS host' unless RUBY_PLATFORM.include?('darwin')

    Dir.mktmpdir('erx-seam-') do |directory|
      source = File.join(directory, 'calls.c')
      File.write(source, "extern int erx_internal(void);\nextern int erx_call(void);\nextern int musl_only(void);\n" \
                         "int f(void) { return erx_internal() + erx_call() + musl_only(); }\n")
      object = File.join(directory, 'calls.o')
      liberx = File.join(directory, 'liberx.o')
      File.write("#{source}.liberx.c", "int erx_internal(void) { return 0; }\nint erx_call(void) { return 0; }\n")
      assert system('clang', '-c', source, '-o', object), 'clang compiles the seeded object'
      assert system('clang', '-c', "#{source}.liberx.c", '-o', liberx), 'clang compiles the seeded liberx'
      imports = File.join(directory, 'imports.txt')
      File.write(imports, "[liberx]\nerx_call\n[musl]\nmusl_only\n")
      report = Seam.check_objects(objects: [object], executable: liberx, liberx: liberx, imports_path: imports)
      assert_equal %w[erx_internal musl_only], report.violations.map(&:name).sort
    end
  end

  # What the check reads as ERTS holds its objects and libraries, and never liberx: were it
  # read, each of liberx's names would count as inside.
  def test_the_objects_of_either_target_leave_liberx_out
    Dir.mktmpdir('erx-seam-') do |directory|
      %w[aarch64-hosted-erxos aarch64-unknown-erxos].each do |target|
        emulator = File.join(directory, target, 'obj')
        output = Erx::Runtime::Output.new(root: File.join(directory, target), beam: nil, objects: emulator,
                                          liberx: File.join(directory, target, 'liberxroot.a'), archive: nil)
        files = [*Seam.libraries(output, target: target), File.join(emulator, 'sys.o'), output.liberx]
        files.each do |file|
          FileUtils.mkdir_p(File.dirname(file))
          FileUtils.touch(file)
        end
        assert_equal (files - [output.liberx]).sort, Seam.objects(output, target: target)
      end
    end
  end

  # An ERTS object calling a name the Fiasco backend defines fails the native check: nothing
  # of liberx is read, so only the list can admit it. A listed liberx call passes, and
  # [libsystem] admits nothing here. The hosted-only lists, the hosted liberx calls and the
  # hosted console's own, count as unused nowhere here.
  def test_a_native_object_calling_a_backend_internal_name_fails
    compiler = ENV.fetch('ERX_CLANG', nil)
    skip 'the native check needs ERX_CLANG and its llvm-nm' if compiler.nil? || compiler.empty?

    Dir.mktmpdir('erx-seam-') do |directory|
      source = File.join(directory, 'calls.c')
      File.write(source, "extern int erx_fiasco_console_write(void);\nextern int erx_clock_ns(void);\n" \
                         "int f(void) { return erx_fiasco_console_write() + erx_clock_ns(); }\n")
      object = File.join(directory, 'calls.o')
      assert system(compiler, '--target=aarch64-none-elf', '-c', source, '-o', object), 'clang compiles the seeded object'
      report = Seam.check_elf_objects(objects: [object], imports_text: "[liberx]\nerx_clock_ns unused_call\n[libsystem]\nerx_fiasco_console_write\n" \
                                                                   "[liberx_hosted]\nhosted_liberx_call\n[only_erx_stdio_nif]\nhosted_only_call\n",
                                      nm: File.join(File.dirname(compiler), 'llvm-nm'))
      assert_equal [Seam::Violation.new(object: object, name: 'erx_fiasco_console_write')], report.violations
      assert_equal %w[unused_call], report.unused
    end
  end

  # The BeamAsm flavour's check: a name the C++ runtime's archive defines is inside, and
  # [beamasm] joins the list; without the runtime that section is neither used nor unused.
  def test_the_beamasm_check_admits_the_cxx_runtime_and_its_own_section
    compiler = ENV.fetch('ERX_CLANG', nil)
    skip 'the native check needs ERX_CLANG and its llvm-nm' if compiler.nil? || compiler.empty?

    Dir.mktmpdir('erx-seam-') do |directory|
      object = compile(compiler, directory, 'calls', "extern int _Znwm(void);\nextern int mprotect(void);\n" \
                                                     "int f(void) { return _Znwm() + mprotect(); }\n")
      runtime = compile(compiler, directory, 'runtime', "int _Znwm(void) { return 0; }\n")
      nm = File.join(File.dirname(compiler), 'llvm-nm')
      text = "[iso_c]\nmemcpy\n[beamasm]\nmprotect\n"
      report = Seam.check_elf_objects(objects: [object], imports_text: text, nm: nm, cxx_runtime: [runtime])
      assert_empty report.violations
      assert_equal %w[memcpy], report.unused
      report = Seam.check_elf_objects(objects: [object], imports_text: text, nm: nm)
      assert_equal %w[_Znwm mprotect], report.violations.map(&:name).sort
      assert_equal %w[memcpy], report.unused
    end
  end

  private

  def compile(compiler, directory, name, text)
    source = File.join(directory, "#{name}.c")
    File.write(source, text)
    object = File.join(directory, "#{name}.o")
    assert system(compiler, '--target=aarch64-none-elf', '-c', source, '-o', object), "clang compiles #{name}.c"
    object
  end
end
