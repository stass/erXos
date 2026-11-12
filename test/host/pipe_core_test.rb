# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/sanitizer_environment'
require_relative '../fixtures/generated_tree'

# The pipe core's writer and reader steps (liberx/erx_pipe_core.c) through every
# interleaving of test/fixtures/pipe_explore.c, a model of one pipe with one write end and
# one read end under delayed stores (docs/design-pipes.md, "The pipe core"). Every scenario
# runs to its end under the address and undefined sanitizers with the landing gate's write
# lengths, or with ERX_PIPE_EXPLORE=full the milestone gate's, as tools/erx check-fuzz runs
# it. Each seeded fault of the steps must fail the property named beside it.
class PipeCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/erx_pipe_core.c'
  SOURCES = ['liberx/erx_pipe_check.c', 'test/fixtures/pipe_explore.c'].freeze
  SANITIZED = ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  SCENARIOS = %w[flow partial nonblock writer-dies reader-closes reader-dies hostile-writer hostile-reader].freeze
  DEPTH = ENV['ERX_PIPE_EXPLORE'] == 'full' ? 'deep' : 'landing'

  def test_every_interleaving_keeps_the_invariants
    with_explorer(File.join(ROOT, CORE), SANITIZED) do |explorer|
      SCENARIOS.each do |scenario|
        output, status = Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER),
                                         explorer, scenario, DEPTH, stdin_data: '')
        assert status.success?, "#{scenario}: #{output}"
        assert_match(/^pipe_explore #{scenario} states \d+ depth \d+$/, output)
        puts output.lines.grep(/^pipe_explore /).join
      end
    end
  end

  # A seeded fault of the steps, the scenario and property that must catch it, and the
  # edit that plants it.
  MUTANTS = {
    "the writer's fence after publishing need removed" =>
      ['flow', 'PI7', "\tcase W_ARMED:\n\t\tw->phase = W_SIDE;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\tcase W_ARMED:\n\t\tw->phase = W_SIDE;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the writer's fence after publishing wpos removed" =>
      ['flow', 'PI7', "\t\tw->phase = W_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\t\tw->phase = W_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the reader's fence after publishing wake removed" =>
      ['flow', 'PI7', "\t\tr->phase = R_PICK;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\t\tr->phase = R_PICK;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the reader's fence after advancing rpos removed" =>
      ['flow', 'PI7', "\t\tr->phase = R_NEED;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\t\tr->phase = R_NEED;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    # The model's records all span two grains, so room is off by one at a record's edge.
    'room that refuses an exact fit (off by one)' =>
      ['flow', 'PI7', 'erx_ring_room(w->size, w->wpos, in->value) >= span',
       'erx_ring_room(w->size, w->wpos, in->value) > span'],
    'room counted one record too many' =>
      ['flow', 'PI5', 'erx_ring_room(w->size, w->wpos, in->value) >= span',
       'erx_ring_room(w->size, w->wpos, in->value) + 2 * PIPE_GRAIN >= span'],
    'a reader that advances rpos before its copy' =>
      ['flow', 'PI5', "\tact = pipe_lane_act(ERX_PIPE_OP_STORE_CUR, r->cur);\n\tact.n = r->cur_off + r->claim;",
       "\tact = pipe_lane_act(r->cur_off + r->claim == r->cur_len ?\n\t    ERX_PIPE_OP_STORE_RPOS : " \
       "ERX_PIPE_OP_STORE_CUR, r->cur);\n\tact.value = r->cur_pos + erx_ring_span(r->cur_len);\n" \
       "\tact.n = r->cur_off + r->claim;"],
    'a writer that publishes before its payload' =>
      ['flow', 'PI5', "\t\treturn (pipe_write_rec(w));\n\tcase W_WRITTEN:\n\t\tw->phase = W_PUBLISHED;\n" \
                      "\t\treturn (pipe_publish(w));",
       "\t\treturn (pipe_publish(w));\n\tcase W_WRITTEN:\n\t\tw->phase = W_PUBLISHED;\n" \
       "\t\treturn (pipe_write_rec(w));"],
    'a reader that takes bytes past the published wpos' =>
      ['flow', 'PI5', "\t\t    lane->batch[lane->nbatches - 1].end : lane->rpos;\n\t\treturn (pipe_lane_wpos(r));",
       "\t\t    lane->batch[lane->nbatches - 1].end + PIPE_GRAIN : lane->rpos + PIPE_GRAIN;\n" \
       "\t\treturn (pipe_lane_wpos(r));"],
    'the end of the stream before the gone lane is drained' =>
      ['writer-dies', 'PI2', 'if (lane->ring == ERX_PIPE_RING_LIVE ||', 'if (false ||'],
    "a writer that skips the ring on its call's last record" =>
      ['flow', 'PI7', 'if (in->value != 0 && pipe_crossed(old, w->wpos, w->wake))',
       'if (in->value != 0 && pipe_crossed(old, w->wpos, w->wake) && w->done != w->len)'],
    'a lane counted drained while its writer is open' =>
      ['flow', 'PI2', "\tif (lane->gone) {\n\t\tlane->ring = ERX_PIPE_RING_DRAINED;",
       "\tif (true) {\n\t\tlane->ring = ERX_PIPE_RING_DRAINED;"],
    'EPIPE while a read end remains' =>
      ['flow', 'PI3', 'if (w->lost || w->readers == 0)', 'if (w->lost || w->readers <= 1)']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, CORE))
    Dir.mktmpdir('erx-pipe-core-mutant-') do |directory|
      MUTANTS.each do |name, (scenario, property, original, replacement)|
        assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place of the core"
        path = File.join(directory, "#{name.tr(' ', '-').delete("'")}.c")
        File.write(path, source.sub(original, replacement))
        with_explorer(path, ['-O2']) do |explorer|
          output, status = Open3.capture2e(explorer, scenario, 'landing', stdin_data: '')
          refute status.success?, "seeded fault not caught: #{name}"
          assert_match(/^FAIL #{property}:/, output, "seeded fault not caught by #{property}: #{name}")
        end
      end
    end
  end

  private

  def with_explorer(core, options)
    Dir.mktmpdir('erx-pipe-core-') do |directory|
      binary = File.join(directory, 'pipe_explore')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *options, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'liberx'),
                                       core, *SOURCES.map { |source| File.join(ROOT, source) },
                                       '-o', binary, stdin_data: '')
      assert status.success?, output
      yield binary
    end
  end
end
