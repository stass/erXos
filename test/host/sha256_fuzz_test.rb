# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The SHA-256 fuzz target (tools/fuzz/sha256_fuzz.c), whose oracle is a
# model written from FIPS 180-4 beside the cut-into-pieces check: built with
# the gate's own command, its seeds pass over the core as imported, and they
# catch seeded faults that every way of cutting a message repeats, which the
# cuts alone cannot see.
class Sha256FuzzTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = File.join(ROOT, 'kernel/crypto/sha2/sha256c.c')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # Each changes one constant of the core, so every digest is wrong the same
  # way however the message is cut.
  MUTANTS = {
    'first initial word' => ['ctx->state[0] = 0x6A09E667;', 'ctx->state[0] = 0x6A09E666;'],
    'last round constant' => ['0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2',
                              '0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f3']
  }.freeze

  def test_the_seeds_pass_over_the_core
    Dir.mktmpdir('erx-sha256-fuzz-') do |directory|
      output, status = run_fuzz(directory, CORE)
      assert status.success?, output
    end
  end

  def test_the_seeds_catch_faults_that_every_cut_repeats
    MUTANTS.each do |name, (original, replacement)|
      Dir.mktmpdir('erx-sha256-fuzz-mutant-') do |directory|
        output, status = run_fuzz(directory, mutate(directory, original, replacement))
        refute status.success?, "the fuzz target did not catch the seeded fault: #{name}"
        assert_match(/deadly signal/, output, "the fuzz program failed for another reason: #{name}")
      end
    end
  end

  private

  def target = Erx::PackFuzz.targets.find { |candidate| candidate.kind == 'sha256' }

  def mutate(directory, original, replacement)
    source = File.read(CORE)
    raise "mutation site is gone: #{original}" unless source.include?(original)

    path = File.join(directory, 'sha256c.c')
    File.write(path, source.sub(original) { replacement })
    FileUtils.cp(File.join(File.dirname(CORE), 'sha256.h'), directory)
    path
  end

  # Builds the fuzz program with the gate's own command, core standing in for
  # the target's source, and runs it once over the target's seeds.
  def run_fuzz(directory, core)
    refute_nil target, 'sha256 fuzz target is not declared'
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    assert_includes command, CORE, 'the gate no longer builds the core this test substitutes'
    command = command.map { |argument| argument == CORE ? core : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, '-runs=0',
                    corpus, stdin_data: '', chdir: directory)
  end
end
