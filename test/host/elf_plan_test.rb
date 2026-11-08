# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/elf_fixture'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/json_input'
require_relative '../fixtures/generated_tree'

class ElfPlanTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-elf-plan-')
    @root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @planner = File.join(@directory, 'elf-plan')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported ELF-test sanitizer' unless (sanitizers - %w[address undefined]).empty?
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'),
                 File.join(@root, 'liberx/elf_plan.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'tools/host/input.c'),
                 File.join(@root, 'tools/host/elf_plan.c'), '-o', @planner],
                name: 'compile-elf', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def plan(bytes, budget: 16 * 1024 * 1024)
    path = File.join(@directory, 'input.elf')
    File.binwrite(path, bytes)
    record = @runner.run([@planner, path, budget.to_s], name: 'plan-elf', deadline: 30)
    [record.fetch('exit_status'), File.read(record.fetch('log'))]
  rescue Erx::CommandError => error
    [error.result.fetch('exit_status'), File.read(error.result.fetch('log'))]
  end

  def reject(bytes, reason, **options)
    status, output = plan(bytes, **options)
    assert_equal 1, status, output
    assert_match(/error #{Regexp.escape(reason)} /, output)
  end

  def test_named_pipe_is_refused_without_waiting_for_a_writer
    path = File.join(@directory, "input.pipe")
    @runner.run(["mkfifo", path], name: "make-pipe", deadline: 5)
    error = assert_raises(Erx::CommandError) do
      # A planner that waited for a writer would wait forever, so any deadline tells; this one
      # leaves room for the first run of a freshly built sanitized binary on a loaded host.
      @runner.run([@planner, path, "8192"], name: "plan-pipe", deadline: 10)
    end
    assert_equal "failed", error.result.fetch("state")
    assert_equal 1, error.result.fetch("exit_status")
  end

  def test_independent_static_image
    status, output = plan(ElfFixture.valid)
    assert_equal 0, status, output
    value = Erx::JsonInput.parse(output)
    assert_equal 0x10000, value.fetch('fixed_base')
    assert_equal 1024, value.fetch('entry')
    assert_equal 64, value.fetch('phdr_offset')
    assert_equal 8192, value.fetch('output_size')
  end

  def test_dynamic_alignment_preserves_leading_residue
    bytes = ElfFixture.valid(dynamic: true, origin: 0x11000,
                             source_offset: 4096, alignment: 65536)
    status, output = plan(bytes)
    assert_equal 0, status, output
    value = Erx::JsonInput.parse(output)
    assert_equal 0x10000, value.fetch('virtual_origin')
    assert_equal 65536, value.fetch('base_alignment')
    assert_equal 4096, value.fetch('loads').first.fetch('mem_offset')
    assert_equal 8192, value.fetch('span')
  end

  def test_missing_duplicate_and_wrong_version_notes_are_refused
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 64 + 56, 0, width: 4)
    reject(bytes, 'missing_abi_note')
    duplicate = ElfFixture.program(type: 4, offset: 512, address: 0x10200, file_size: 24)
    reject(ElfFixture.valid(extra: [duplicate]), 'duplicate_abi_note')
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 532, 2, width: 4)
    reject(bytes, 'abi_version')
  end

  def test_truncated_note_and_overflowing_load_are_refused
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 64 + 56 + 32, 23)
    reject(bytes, 'note_extent')
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 64 + 40, 0xffffffffffffffff)
    reject(bytes, 'load_protection_or_size')
  end

  def test_interpreter_and_dynamic_dependencies_are_refused
    interpreter = ElfFixture.program(type: 3, offset: 2048, address: 0x10800, file_size: 16)
    reject(ElfFixture.valid(extra: [interpreter]), 'interpreter')
    dynamic = ElfFixture.program(type: 2, offset: 2048, address: 0x10800, file_size: 16, alignment: 8)
    bytes = ElfFixture.valid(extra: [dynamic])
    ElfFixture.integer(bytes, 2048, 1)
    reject(bytes, 'dynamic_dependency')
  end

  def test_overlapping_metadata_work_is_bounded_by_source_bytes
    unknown = ElfFixture.program(type: 4, offset: 1024, address: 0x10400, file_size: 1200)
    reject(ElfFixture.valid(extra: [unknown] * 4), 'metadata_work')
  end

  def test_dynamic_file_and_virtual_views_must_agree
    dynamic = ElfFixture.program(type: 2, offset: 2048, address: 0x10900, file_size: 16, alignment: 8)
    reject(ElfFixture.valid(extra: [dynamic]), 'dynamic_mapping')
  end

  def test_tls_template_sizes_and_alignment_are_checked
    tls = ElfFixture.program(type: 7, offset: 2304, address: 0x10900,
                             file_size: 32, memory_size: 16, alignment: 16)
    reject(ElfFixture.valid(extra: [tls]), 'tls_range')
  end

  def test_tls_template_alignment_is_checked
    tls = ElfFixture.program(type: 7, offset: 2304, address: 0x10900,
                             file_size: 16, memory_size: 32, alignment: 3)
    reject(ElfFixture.valid(extra: [tls]), 'tls_alignment')
  end

  def test_expanded_readonly_tail_respects_output_budget
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 64 + 40, 8192)
    reject(bytes, 'output_budget', budget: 8192)
  end

  def test_unaligned_load_and_nonexecutable_entry_are_refused
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 64 + 16, 0x10001)
    reject(bytes, 'load_alignment')
    bytes = ElfFixture.valid
    ElfFixture.integer(bytes, 24, 0x12000)
    reject(bytes, 'entry_not_executable')
  end
end
