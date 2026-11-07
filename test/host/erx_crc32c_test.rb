# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../fixtures/generated_tree'

# erx_bytes:crc32c's core (otp/erts/emulator/nifs/erxos/erx_crc32c.c): RFC 3720's values,
# incremental calls against one-shot calls and a bitwise model (test/fixtures/erx_crc32c_harness.c),
# clean under the address and undefined sanitizers, and the fuzz target's seeds catching a
# seeded fault, so its oracle has teeth.
class ErxCrc32cTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  NIFS = File.join(ROOT, 'otp/erts/emulator/nifs/erxos')
  CORE = File.join(NIFS, 'erx_crc32c.c')
  HARNESS = File.join(ROOT, 'test/fixtures/erx_crc32c_harness.c')
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', '-fno-omit-frame-pointer',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # Each mutant changes one expression of the core.
  MUTANTS = {
    'polynomial bit' => ['0x82F63B78u', '0x82F63B79u'],
    'no final inversion' => ['return (~state);', 'return (state);'],
    'no starting inversion' => ['uint32_t state = ~crc;', 'uint32_t state = crc;'],
    'high bit of the starting value dropped' => ['uint32_t state = ~crc;', 'uint32_t state = ~crc & 0x7fffffffu;'],
    'last table entry wrong' => ['ENTRY(15),', 'ENTRY(14),']
  }.freeze

  def test_vectors_composition_and_model
    Dir.mktmpdir('erx-crc32c-') do |directory|
      assert_match(/^erx_crc32c done$/, run_harness(directory, CORE))
    end
  end

  def test_every_mutant_fails_the_harness
    MUTANTS.each do |name, (original, replacement)|
      Dir.mktmpdir('erx-crc32c-mutant-') do |directory|
        output, status = build_and_run(directory, harness_command(directory, mutate(directory, original, replacement)))
        refute status.success?, "mutant survived the harness: #{name}"
        refute_match(/erx_crc32c done/, output)
      end
    end
  end

  def test_the_fuzz_target_declares_this_core_and_its_seeds_pass
    target = Erx::PackFuzz.targets.find { |t| t.kind == 'crc32c' }
    refute_nil target, 'crc32c fuzz target is not declared'
    assert_equal ['otp/erts/emulator/nifs/erxos/erx_crc32c.c'], target.sources
    Dir.mktmpdir('erx-crc32c-fuzz-') do |directory|
      _output, status = run_fuzz(directory, target, CORE)
      assert status.success?
    end
  end

  def test_the_fuzz_target_catches_a_fault_that_only_a_large_starting_value_shows
    target = Erx::PackFuzz.targets.find { |t| t.kind == 'crc32c' }
    original, replacement = MUTANTS.fetch('high bit of the starting value dropped')
    Dir.mktmpdir('erx-crc32c-fuzz-mutant-') do |directory|
      _output, status = run_fuzz(directory, target, mutate(directory, original, replacement))
      refute status.success?, 'the fuzz target did not catch the seeded fault'
    end
  end

  private

  def mutate(directory, original, replacement)
    source = File.read(CORE)
    raise "mutation site is gone: #{original}" unless source.include?(original)

    path = File.join(directory, 'erx_crc32c.c')
    File.write(path, source.sub(original) { replacement })
    path
  end

  def harness_command(directory, core)
    [COMPILER, *FLAGS, '-I', NIFS, HARNESS, core, '-o', File.join(directory, 'harness')]
  end

  def build_and_run(directory, command)
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0' }, File.join(directory, 'harness'), stdin_data: '')
  end

  def run_harness(directory, core)
    output, status = build_and_run(directory, harness_command(directory, core))
    assert status.success?, output
    output
  end

  # Builds the fuzz program with the gate's own command, core standing in for the
  # target's source, and runs it once over the target's seeds.
  def run_fuzz(directory, target, core)
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    assert_includes command, CORE, 'the gate no longer builds the core this test substitutes'
    command = command.map { |argument| argument == CORE ? core : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e({ 'ASAN_OPTIONS' => 'detect_leaks=0', 'UBSAN_OPTIONS' => 'halt_on_error=1' }, program, '-runs=0', corpus,
                    stdin_data: '', chdir: directory)
  end
end
