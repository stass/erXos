# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../fixtures/generated_tree'

class AbiCallsTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-abi-calls-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'), timeout_program: 'gtimeout')
    @compiler = ENV.fetch('ERX_CLANG', 'clang')
    @flags = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
              *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'), '-I', @root]
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && @directory && File.directory?(@directory)
  end

  def run_command(arguments, name:)
    @runner.run(arguments, name: name, deadline: 60)
  rescue Erx::CommandError => error
    flunk(File.binread(error.result.fetch('log')))
  end

  def test_kernel_shape_decoder_under_sanitizers
    output = File.join(@directory, 'call-probe')
    run_command([@compiler, *@flags, '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                 Erx::Generated.path('kernel/generated/abi_decode.c', root: @root),
                 File.join(@root, 'test/fixtures/abi_call_probe.c'), '-o', output], name: 'compile-call-probe')
    record = run_command([output], name: 'call-probe')
    assert_equal "call shape checks passed\n", File.binread(record.fetch('log'))
  end

  def test_generated_atomic_accessors_under_thread_sanitizer
    output = File.join(@directory, 'atomic-probe')
    run_command([@compiler, *@flags, '-fsanitize=thread', '-fno-omit-frame-pointer', '-pthread',
                 File.join(@root, 'test/fixtures/abi_atomic_probe.c'), '-o', output], name: 'compile-atomic-probe')
    record = run_command([output], name: 'atomic-probe')
    assert_equal "atomic accessor checks passed\n", File.binread(record.fetch('log'))
  end

  def test_native_trap_and_note_compile_for_target
    %w[build/gen/liberx/backend/erx/arch/aarch64/generated/calls.c test/fixtures/abi_note_probe.c].each_with_index do |path, index|
      record = run_command([@compiler, *@flags, '--target=aarch64-none-elf', '-ffreestanding',
                            '-c', File.join(@root, path), '-o', File.join(@directory, "target#{index}.o")],
                           name: "target#{index}")
      assert_equal 0, record.fetch('exit_status')
    end
  end

  def test_result_registers_need_not_also_be_argument_registers
    source = Erx::ABI::Sources.read(root: @root)
    declarations = source.declarations.flat_map do |declaration|
      if declaration.kind == 'reg' && declaration.args.first == 'args'
        Erx::ABI::Syntax.parse("reg args x3,x4,x5,x6,x7,x9\n", path: declaration.line.path)
      else
        [declaration]
      end
    end
    schema = Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: declarations, inputs: source.inputs))
    headers = { 'include/erx/abi.h' => Erx::ABI::CEmitter.header(schema),
                'liberx/generated/calls.h' => Erx::ABI::CEmitter.call_header(schema),
                'calls.c' => Erx::ABI::CallEmitter.trap_source(schema) }
    headers.each do |path, bytes|
      destination = File.join(@directory, path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, bytes)
    end
    record = run_command([@compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                          '--target=aarch64-none-elf', '-ffreestanding', '-I', File.join(@directory, 'include'),
                          '-I', @directory, '-c', File.join(@directory, 'calls.c'),
                          '-o', File.join(@directory, 'distinct-results.o')], name: 'distinct-results')
    assert_equal 0, record.fetch('exit_status')
  end

  def test_backend_wrappers_compile_without_implementing_authority
    %w[fiasco hosted].each do |backend|
      path = Erx::Generated.path("liberx/backend/#{backend}/generated/calls.c", root: @root)
      record = run_command([@compiler, *@flags, '-c', path,
                            '-o', File.join(@directory, "#{backend}.o")], name: backend)
      assert_equal 0, record.fetch('exit_status')
    end
  end

  def test_foreign_elf_facts_match_pinned_musl
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @root))
    declarations = ["#include <stddef.h>", '#include "erx/abi.h"', '#include "musl/include/elf.h"']
    { 'erx_elf64_ehdr' => 'Elf64_Ehdr', 'erx_elf64_phdr' => 'Elf64_Phdr',
      'erx_elf64_nhdr' => 'Elf64_Nhdr', 'erx_elf64_dyn' => 'Elf64_Dyn' }.each do |name, foreign|
      type = schema.types.fetch(name)
      declarations << "_Static_assert(sizeof(#{name}_t) == sizeof(#{foreign}), \"#{name} size\");"
      type.fields.each do |field|
        member = field.name == 'd_value' ? 'd_un' : field.name
        declarations << "_Static_assert(offsetof(#{name}_t, #{field.name}) == offsetof(#{foreign}, #{member}), \"#{name}.#{field.name}\");"
      end
    end
    overrides = { 'elf_class64' => 'ELFCLASS64', 'elf_data_lsb' => 'ELFDATA2LSB',
                  'elf_version_current' => 'EV_CURRENT', 'elf_osabi_none' => 'ELFOSABI_NONE' }
    schema.constants.each_key do |name|
      next unless name.start_with?('elf_') && name != 'elf_segments_max'
      foreign = overrides.fetch(name) { name.delete_prefix('elf_').upcase }
      declarations << "_Static_assert(#{Erx::ABI::Names.macro(name)} == #{foreign}, \"#{name}\");"
    end
    declarations << '_Static_assert(ERX_ARCH_ELF_MACHINE == EM_AARCH64, "machine");'
    source = File.join(@directory, 'elf-oracle.c')
    File.write(source, declarations.join("\n") + "\n")
    record = run_command([@compiler, *@flags, '-c', source, '-o', File.join(@directory, 'elf-oracle.o')], name: 'elf-oracle')
    assert_equal 0, record.fetch('exit_status')
  end

  # The marshalling fixture's schema with the shipped AArch64 binding, its
  # outputs written beneath the scratch directory as the tree lays them out.
  def marshal_outputs
    sources = { 'abi/erx_abi.txt' => File.join(@root, 'test/fixtures/abi_call_marshal.txt'),
                'abi/arch/aarch64.txt' => File.join(@root, 'abi/arch/aarch64.txt') }
    texts = sources.transform_values { |path| File.binread(path).freeze }
    declarations = texts.flat_map { |path, text| Erx::ABI::Syntax.parse(text, path: path) }
    schema = Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: declarations.freeze,
                                                            inputs: texts.freeze))
    outputs = Erx::ABI::CallEmitter.outputs(schema).merge(
      'include/erx/abi.h' => Erx::ABI::CEmitter.header(schema),
      'liberx/generated/calls.h' => Erx::ABI::CEmitter.call_header(schema)
    )
    outputs.each do |path, bytes|
      destination = File.join(@directory, path)
      FileUtils.mkdir_p(File.dirname(destination))
      File.write(destination, bytes)
    end
    outputs
  end

  def marshal_flags
    ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
     '-I', File.join(@directory, 'include'), '-I', @directory, *Erx::Generated.include_flags(root: @root),
     '-I', File.join(@root, 'include')]
  end

  def test_call_marshalling_under_sanitizers
    marshal_outputs
    output = File.join(@directory, 'marshal-probe')
    run_command([@compiler, *marshal_flags, '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                 '-fno-omit-frame-pointer', '-I', File.join(@directory, 'kernel/generated'),
                 File.join(@directory, 'kernel/generated/abi_decode.c'),
                 File.join(@root, 'test/fixtures/abi_call_marshal_probe.c'), '-o', output], name: 'compile-marshal-probe')
    record = run_command([output], name: 'marshal-probe')
    assert_equal "call marshalling checks passed\n", File.binread(record.fetch('log'))
  end

  # The admission core over the fixture's generated plans: lookups and
  # existence locks in the design's order, and every failure path ending
  # with no lock held.
  def test_admission_order_and_release_under_sanitizers
    marshal_outputs
    output = File.join(@directory, 'admit-probe')
    run_command([@compiler, *marshal_flags, '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                 '-fno-omit-frame-pointer', '-I', File.join(@directory, 'kernel/generated'),
                 File.join(@directory, 'kernel/generated/abi_decode.c'),
                 File.join(@root, 'kernel/core/admit.c'),
                 File.join(@root, 'test/fixtures/abi_admit_probe.c'), '-o', output], name: 'compile-admit-probe')
    record = run_command([output], name: 'admit-probe')
    assert_equal "admission checks passed\n", File.binread(record.fetch('log'))
  end

  # The root slots and their kinds' rights, as docs/design-abi.md
  # ("Numeric assignment and versions") and docs/design-kernel.md
  # ("Rights") give them, against the shipped generated header.
  def test_root_capabilities_match_the_design_tables
    output = File.join(@directory, 'root-probe')
    run_command([@compiler, *@flags, '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                 File.join(@root, 'test/fixtures/abi_root_probe.c'), '-o', output], name: 'compile-root-probe')
    record = run_command([output], name: 'root-probe')
    assert_equal "root capability checks passed\n", File.binread(record.fetch('log'))
  end

  # A generated decoder would copy the secret into a frame its reader cannot
  # zero, so the device-secret page has none in any language.
  def test_no_decoder_copies_the_device_secret
    %w[liberx/generated/abi_reader.c include/erx/abi_reader.h].each do |path|
      refute_includes File.read(Erx::Generated.path(path, root: @root)), 'erx_device_secret_page', path
    end
  end

  def test_marshalled_wrappers_compile_for_every_backend
    marshal_outputs
    run_command([@compiler, *marshal_flags, '--target=aarch64-none-elf', '-ffreestanding', '-c',
                 File.join(@directory, 'liberx/backend/erx/arch/aarch64/generated/calls.c'),
                 '-o', File.join(@directory, 'marshal-trap.o')], name: 'marshal-trap')
    %w[fiasco hosted].each do |backend|
      run_command([@compiler, *marshal_flags, '-c',
                   File.join(@directory, "liberx/backend/#{backend}/generated/calls.c"),
                   '-o', File.join(@directory, "marshal-#{backend}.o")], name: "marshal-#{backend}")
    end
  end

  # The decoder reaches the user-writable UTCB only through the one load of
  # each word it copies; every decision reads the copy.
  def test_decoder_reads_each_utcb_word_through_one_load
    decoder = marshal_outputs.fetch('kernel/generated/abi_decode.c')
    body = decoder[/^erx_sys_decode_shape\(.*?^\{\n(.*?)^\}\n/m, 1]
    uses = body.lines.map(&:strip).grep(/\butcb\b/)
    assert_equal ['if (utcb == NULL)', 'if (!erx_utcb_mr_load(utcb, 0, &words[0]))',
                  'if (utcb == NULL)', 'if (!erx_utcb_mr_load(utcb, 2 + index, &words[index]))',
                  'if (!erx_utcb_mr_load(utcb, 6, &words[4]))'], uses
    # The plan copies capability values from the decoded shape alone.
    plan = decoder[/^erx_sys_admit_plan\(.*?^\{\n(.*?)^\}\n/m, 1]
    assert_empty plan.lines.grep(/\butcb\b|\bregisters\b/)
  end

  def test_fixed_byte_strings_do_not_form_c_trigraphs
    declarations = Erx::ABI::Syntax.parse("abi 1\nbytes trigraph 3 value 3f3f2f\n")
    schema = Erx::ABI::Model.validate(Erx::ABI::SourceSet.new(declarations: declarations, inputs: {}))
    File.write(File.join(@directory, 'trigraph.h'), Erx::ABI::CEmitter.header(schema))
    source = File.join(@directory, 'trigraph.c')
    File.write(source, "#include \"trigraph.h\"\n_Static_assert(sizeof(ERX_TRIGRAPH_STRING) == 4, \"fixed bytes\");\n")
    record = run_command([@compiler, *@flags, '-trigraphs', '-c', source,
                          '-o', File.join(@directory, 'trigraph.o')], name: 'trigraph')
    assert_equal 0, record.fetch('exit_status')
  end
end
