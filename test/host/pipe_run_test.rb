# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pipe core's effects on real pages (liberx/erx_pipe_run.c), which a program's pipe
# ends and the session's pipe NIF share, through test/fixtures/pipe_run_harness.c under the
# address and undefined sanitizers: bytes pass, a 4,096-byte record arrives whole, an empty
# read waits with its sleeper bit published and is rung, a full ring waits and is rung, a
# gone writer's lane drains once and then reads as the end, EPIPE and EIO, a hostile
# record breaks its lane, a read that copied a record before a write end joined returns it
# rather than wait, and a read end that takes an index clears that index's bits. Each
# seeded fault of the runner must fail the case named beside it.
class PipeRunTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  RUN = 'liberx/erx_pipe_run.c'
  SOURCES = ['liberx/erx_pipe_core.c', 'liberx/erx_pipe_check.c', 'test/fixtures/pipe_run_harness.c'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_runs_pass_bytes_and_wake
    output, status = build_and_run(File.join(ROOT, RUN))
    assert status.success?, output
    assert_match(/^pipe_run done$/, output)
  end

  # A seeded fault of the runner, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'the readers a write crossed are not rung' =>
      ['empty reader rung', "for (bits = a->value; bits != 0; bits &= bits - 1)\n",
       "for (bits = 0; bits != 0; bits &= bits - 1)\n"],
    "a write's wait for the clock that stops on an equal reading" =>
      ['clock passes the stamp', 'fx->clock(fx->ctx) <= from;)', 'fx->clock(fx->ctx) < from;)'],
    'the write position is never published' =>
      ['bytes read', 'return (erx_lane_hdr_wpos_store(map->hdr, a->value));', 'return (true);'],
    'a drained lane is not reported' =>
      ['gone drained once', "\t\tfx->drained(fx->ctx, a->lane);\n", ''],
    'a taken index keeps the bits its last holder left' =>
      ['take clears bits', 'keep = ~(UINT64_C(1) << rix);', 'keep = ~UINT64_C(0);'],
    'a read runs with an index rtake never gave' =>
      ['untaken read refused', 'if (!r->taken || r->rix >= ERX_PIPE_READERS_MAX)',
       'if (r->rix >= ERX_PIPE_READERS_MAX)']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, RUN))
    Dir.mktmpdir('erx-pipe-run-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the runner"
        path = File.join(directory, "#{name.tr(' ', '-')}.c")
        File.write(path, source.sub(original, replacement))
        output, status = build_and_run(path)
        refute status.success?, "seeded fault not caught: #{name}"
        assert_includes output.lines.map(&:chomp), "FAIL #{expected}", "seeded fault not caught by its case: #{name}"
      end
    end
  end

  private

  def build_and_run(runner)
    Dir.mktmpdir('erx-pipe-run-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'liberx'),
                                       runner, *SOURCES.map { |source| File.join(ROOT, source) },
                                       '-o', binary, stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
