# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/run_pack'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/sanitizer_environment'

# The erx_prog fuzz target (tools/fuzz/erx_prog_fuzz.c), whose oracle restates which
# descriptors the start-up plan of liberx/program/startup.c sets up: built with the
# gate's own command, its seeds pass over the plan as it is, and they fail when the
# plan and the oracle disagree on a descriptor kind a seed holds (null, tty, dup and
# a pipe's two ends).
class ErxProgFuzzTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  PLAN = File.join(ROOT, 'liberx/program/startup.c')
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  # A line of the plan and what replaces it.
  Mutation = Data.define(:original, :replacement)

  # Without its pipe read case, the plan refuses the read end the "pipes" seed holds.
  READ_END_REFUSED = Mutation.new(original: "\t\tcase ERX_PROG_DESCRIPTOR_PIPE_READ:\n", replacement: '')

  def test_the_seeds_pass_over_the_plan
    Dir.mktmpdir('erx-prog-fuzz-') do |directory|
      output, status = run_fuzz(directory, PLAN)
      assert status.success?, output
    end
  end

  def test_the_seeds_catch_a_plan_that_refuses_a_pipe_end
    Dir.mktmpdir('erx-prog-fuzz-mutant-') do |directory|
      output, status = run_fuzz(directory, mutate(directory, READ_END_REFUSED))
      refute status.success?, 'the fuzz target did not catch a plan that refuses a pipe read end'
      assert_match(/deadly signal/, output, 'the fuzz program failed for another reason')
      # libFuzzer writes the input it stopped on into its working directory.
      crashes = Dir.glob(File.join(directory, 'crash-*')).map { |path| File.binread(path) }
      assert_equal [target.seeds.fetch('pipes')], crashes, 'the fuzz program failed on a seed other than "pipes"'
    end
  end

  private

  def target = Erx::PackFuzz.targets.find { |candidate| candidate.kind == 'erx_prog' }

  def mutate(directory, mutation)
    source = File.read(PLAN)
    raise "mutation site is gone: #{mutation.original.inspect}" unless source.include?(mutation.original)

    path = File.join(directory, 'startup.c')
    File.write(path, source.sub(mutation.original) { mutation.replacement })
    path
  end

  # Builds the fuzz program with the gate's own command, plan standing in for
  # liberx/program/startup.c, and runs it once over the target's seeds.  The
  # copy includes its header by its path from the root, so it builds anywhere.
  def run_fuzz(directory, plan)
    refute_nil target, 'erx_prog fuzz target is not declared'
    corpus = File.join(directory, 'corpus')
    FileUtils.mkdir_p(corpus)
    target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(directory, 'fuzz')
    command = Erx::PackFuzz.compile_command(target, root: ROOT, compiler: COMPILER, program: program)
    assert_includes command, PLAN, 'the gate no longer builds the plan this test substitutes'
    command = command.map { |argument| argument == PLAN ? plan : argument }
    output, status = Open3.capture2e(*command, stdin_data: '')
    assert status.success?, output
    Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), program, '-runs=0',
                    corpus, stdin_data: '', chdir: directory)
  end
end
