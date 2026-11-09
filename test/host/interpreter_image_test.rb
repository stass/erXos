# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/interpreter_image'

# The build check that the interpreter image links no BeamAsm, asmjit, libc++ or libc++abi
# symbol (docs/design-runtime.md, R10): its reading of names, and a seeded asmjit object
# linked into a program, which the check refuses where the same program without it passes.
class InterpreterImageTest < Minitest::Test
  # A member function of asmjit's BaseEmitter, mangled as clang mangles it.
  ASMJIT_NAME = '_ZN6asmjit10_abi_1_1311BaseEmitter4emitEv'

  def setup
    @compiler = ENV.fetch('ERX_CLANG', '')
    @linker = ENV.fetch('ERX_LLD', '')
    @directory = File.realpath(Dir.mktmpdir('erx-interpreter-image-test-'))
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_each_family_is_named_by_its_own_symbols
    names = [ASMJIT_NAME, 'beamasm_init', '_ZN19BeamGlobalAssembler4emitEv', '_ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backEOi',
             '__gxx_personality_v0', '_ZTIN10__cxxabiv117__class_type_infoE', '__cxa_throw', 'erl_start', 'memcpy']
    assert_equal({ 'BeamAsm' => %w[_ZN19BeamGlobalAssembler4emitEv beamasm_init], 'asmjit' => [ASMJIT_NAME],
                   'libc++' => %w[_ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backEOi],
                   'C++' => %w[_ZTIN10__cxxabiv117__class_type_infoE __cxa_throw __gxx_personality_v0] },
                 Erx::InterpreterImage.foreign_symbols(names))
  end

  # What C++ built without exceptions or RTTI still brings: its own mangled names and the
  # runtime's operator new and delete, casts and globals.
  def test_any_cxx_name_is_refused
    names = %w[_Znwm _ZdlPv _ZN2L47Kobject16__Kobject_typeid2_mE __dynamic_cast __cxa_get_globals]
    assert_equal({ 'C++' => names.sort }, Erx::InterpreterImage.foreign_symbols(names))
  end

  # musl defines the two __cxa_ names for atexit, so a C program holds them with no C++.
  # etp_beamasm is a C flag of ERTS's debugger support, in the interpreter's build too.
  def test_musl_and_erts_c_names_are_not_foreign
    assert_empty Erx::InterpreterImage.foreign_symbols(%w[__cxa_atexit __cxa_finalize etp_beamasm erl_start])
  end

  def test_a_seeded_asmjit_object_fails_the_check
    tools!
    seeded = program(seeded: true)
    error = assert_raises(Erx::Error) { Erx::InterpreterImage.check(program: seeded, nm: nm, runner: @runner) }
    assert_includes error.message, "asmjit: #{ASMJIT_NAME}"
  end

  def test_the_program_without_the_seed_passes
    tools!
    Erx::InterpreterImage.check(program: program(seeded: false), nm: nm, runner: @runner)
  end

  # A stripped program lists nothing, which would pass as clean, so the check needs ERTS's entry.
  def test_a_program_without_the_runtime_entry_is_refused
    tools!
    other = program(seeded: false, entry: 'other_start')
    error = assert_raises(Erx::Error) { Erx::InterpreterImage.check(program: other, nm: nm, runner: @runner) }
    assert_includes error.message, 'erl_start'
  end

  # The BeamAsm image's own check: a link without asmjit is no BeamAsm image, and one
  # with BeamAsm's and asmjit's names passes.
  def test_the_beamasm_image_must_link_beamasm_and_asmjit
    tools!
    error = assert_raises(Erx::Error) do
      Erx::InterpreterImage.check_beamasm(program: program(seeded: false), nm: nm, runner: @runner)
    end
    assert_includes error.message, 'links no BeamAsm and no asmjit'
    jit = program(seeded: true, extra: "void beamasm_init(void) { }\n")
    Erx::InterpreterImage.check_beamasm(program: jit, nm: nm, runner: @runner)
  end

  private

  def tools!
    skip 'ERX_CLANG and ERX_LLD are not set: the check needs the LLVM clang, ld.lld and llvm-nm' if @compiler.empty? || @linker.empty?
  end

  def nm = File.join(File.dirname(@compiler), 'llvm-nm')

  # A freestanding AArch64 program of entry, with the seeded asmjit object linked in or not.
  def program(seeded:, entry: 'erl_start', extra: '')
    sources = { 'main' => "void #{entry}(void) { for (;;) { } }\n#{extra}" }
    sources['seed'] = "void #{ASMJIT_NAME}(void) { }\n" if seeded
    objects = sources.map do |name, text|
      source = File.join(@directory, "#{name}.c")
      File.write(source, text)
      object = File.join(@directory, "#{name}.o")
      @runner.run([@compiler, '--target=aarch64-none-elf', '-std=c17', '-ffreestanding', '-c', source, '-o', object],
                  name: "interpreter-image-#{name}", deadline: 60)
      object
    end
    output = File.join(@directory, seeded ? 'seeded' : 'clean')
    @runner.run([@linker, '-e', entry, '-o', output, *objects], name: 'interpreter-image-link', deadline: 60)
    output
  end
end
