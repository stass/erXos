# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pipe's checks of what it copies from shared pages (liberx/erx_pipe_check.c), the one
# shared-page copy (include/erx/shm.h) and the doorbell label helper (include/erx/pipe.h),
# through test/fixtures/pipe_check_harness.c, which walks every boundary of the checks of
# docs/design-pipes.md ("The ring", "The lock page") under the address and undefined
# sanitizers. Each seeded fault of the checks must fail the case named beside it.
class PipeCheckTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CHECK = 'liberx/erx_pipe_check.c'
  HARNESS = 'test/fixtures/pipe_check_harness.c'
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
           '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')

  def test_checks_hold_at_every_boundary
    output, status = build_and_run(File.join(ROOT, CHECK))
    assert status.success?, output
    assert_match(/^pipe_check done$/, output)
  end

  # A seeded fault of the checks, the case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a data record of PIPE_BUF + 1 bytes accepted' =>
      ['ring data past pipe_buf', 'len <= ERX_PIPE_BUF)', 'len <= ERX_PIPE_BUF + 1)'],
    'wpos - rpos <= size dropped' =>
      ['ring wpos ahead', 'if (copy->wpos - copy->rpos > size)', 'if (size == 0)'],
    'a record that fills what is published refused (off by one)' =>
      ['ring record fills what is published', 'erx_ring_span(copy->len) > copy->wpos - copy->rpos',
       'erx_ring_span(copy->len) >= copy->wpos - copy->rpos'],
    'a record header that straddles the area end accepted' =>
      ['ring header straddles the end', 'if (!pipe_aligned(copy->rpos) || !pipe_aligned(copy->wpos))',
       'if (!pipe_aligned(copy->wpos))'],
    'the frame kind admitted by the pipe check' =>
      ['ring frame kind', 'switch (copy->kind) {', "switch (copy->kind == 1u ? ERX_REC_DATA : copy->kind) {"],
    'the owner bound at 65' =>
      ['owner past last', 'owner > ERX_PIPE_READERS_MAX', 'owner > ERX_PIPE_READERS_MAX + 1'],
    'the producer drops its size bound' =>
      ['room rpos behind the area', 'wpos - rpos > size || ', '']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, CHECK))
    Dir.mktmpdir('erx-pipe-check-mutant-') do |directory|
      MUTANTS.each do |name, (expected, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the check"
        path = File.join(directory, "#{name.tr(' ', '-').delete('<=+()')}.c")
        File.write(path, source.sub(original, replacement))
        output, status = build_and_run(path)
        refute status.success?, "seeded fault not caught: #{name}"
        assert_includes output.lines.map(&:chomp), "FAIL #{expected}", "seeded fault not caught by its case: #{name}"
      end
    end
  end

  private

  def build_and_run(check)
    Dir.mktmpdir('erx-pipe-check-') do |directory|
      binary = File.join(directory, 'harness')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'liberx'),
                                       check, File.join(ROOT, HARNESS), '-o', binary, stdin_data: '')
      assert status.success?, output
      Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER), binary, stdin_data: '')
    end
  end
end
