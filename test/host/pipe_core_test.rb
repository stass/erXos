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
# interleaving of test/fixtures/pipe_explore.c, a model of one pipe under delayed stores
# (docs/design-pipes.md, "The pipe core"): one write end and one read end, two write ends
# merged by one read end, on a clock that advances at every reading or one that may repeat
# a reading, or one write end read by two co-readers, and one end called by
# two threads at once. Every scenario
# runs to its end under the address and undefined sanitizers with the landing gate's write
# lengths, or with ERX_PIPE_EXPLORE=full the milestone gate's, as tools/erx check-fuzz runs
# it. Each seeded fault of the steps, or of the pipe server as the model plays it, must fail
# the property named beside it.
class PipeCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/erx_pipe_core.c'
  CHECK = 'liberx/erx_pipe_check.c'
  SANITIZED = ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined'].freeze
  FLAGS = ['-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic'].freeze
  COMPILER = ENV.fetch('ERX_CLANG', 'clang')
  EXPLORER = 'test/fixtures/pipe_explore.c'
  FULL = ENV['ERX_PIPE_EXPLORE'] == 'full'
  DEPTH = FULL ? 'deep' : 'landing'
  # The landing gate explores the small shapes; the milestone gate adds the large ones, whose
  # seeded faults the landing gate still catches at landing lengths.
  SMALL = %w[flow partial nonblock writer-dies reader-closes reader-dies lost join merge coread
             coread-dies-empty coread-lost-dies rcalls wcalls wpoll rpoll hostile-writer hostile-reader
             hostile-coreader hostile-wcalls].freeze
  LARGE = %w[merge-join merge-repeat coread-dies coread-lost].freeze
  SCENARIOS = FULL ? LARGE + SMALL : SMALL
  # Scenarios explored at once: each runs alone in one process.
  PARALLEL = 8

  def test_every_interleaving_keeps_the_invariants
    with_explorer({}, SANITIZED) do |explorer|
      in_parallel(SCENARIOS) do |scenario|
        [scenario, *Open3.capture2e(Erx::SanitizerEnvironment.call(compiler: COMPILER),
                                    explorer, scenario, DEPTH, stdin_data: '')]
      end.each do |scenario, output, status|
        assert status.success?, "#{scenario}: #{output}"
        assert_match(/^pipe_explore #{scenario} states \d+ depth \d+$/, output)
        puts output.lines.grep(/^pipe_explore /).join
      end
    end
  end

  # A seeded fault of the steps, the scenario and property that must catch it, and the
  # edit that plants it in the core; a fault planted elsewhere names its file first.
  MUTANTS = {
    "the writer's fence after publishing need removed" =>
      ['flow', 'PI7', "\tcase W_ARMED:\n\t\tw->phase = W_SIDE;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\tcase W_ARMED:\n\t\tw->phase = W_SIDE;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the writer's fence after publishing wpos removed" =>
      ['flow', 'PI7', "\t\tw->phase = W_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\t\tw->phase = W_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the reader's fence after publishing wake removed" =>
      ['flow', 'PI7', "\tr->phase = ARM_FENCED;\n\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\tr->phase = ARM_FENCED;\n\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    "the reader's fence after advancing rpos removed" =>
      ['flow', 'PI7', "\t\tr->phase = FINISH_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));",
       "\t\tr->phase = FINISH_FENCED;\n\t\treturn (pipe_act(ERX_PIPE_OP_CLOCK));"],
    # The model's records all span two grains, so room is off by one at a record's edge.
    'room that refuses an exact fit (off by one)' =>
      ['flow', 'PI7', '} else if (room >= span) {',
       '} else if (room > span) {'],
    'room counted one record too many' =>
      ['flow', 'PI5', '} else if (room >= span) {',
       '} else if (room + 2 * PIPE_GRAIN >= span) {'],
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
      ['flow', 'PI5', "\t\t    lane->batch[lane->nbatches - 1].end : lane->rpos;\n\t\treturn (pipe_rlook_wpos(r));",
       "\t\t    lane->batch[lane->nbatches - 1].end + PIPE_GRAIN : lane->rpos + PIPE_GRAIN;\n" \
       "\t\treturn (pipe_rlook_wpos(r));"],
    'the end of the stream before the gone lane is drained' =>
      ['writer-dies', 'PI2', 'if (r->lanes[i].ring == ERX_PIPE_RING_LIVE)', 'if (false)'],
    "a writer that skips the ring on its call's last record" =>
      ['flow', 'PI7', 'if (in->value != 0 && pipe_crossed(old, w->wpos, w->wake))',
       'if (in->value != 0 && pipe_crossed(old, w->wpos, w->wake) && w->done != w->len)'],
    'a lane counted drained while its writer is open' =>
      ['flow', 'PI2', "\tif (r->gone) {\n\t\tlane->ring = ERX_PIPE_RING_DRAINED;",
       "\tif (true) {\n\t\tlane->ring = ERX_PIPE_RING_DRAINED;"],
    'EPIPE while a read end remains' =>
      ['flow', 'PI3', '(w->lost || w->readers == 0) && !w->poll', '(w->lost || w->readers <= 1) && !w->poll'],
    # A poll answers without copying (docs/design-pipes.md, "Readiness"): writable only with room
    # for a whole chunk, and when nothing is ready, only after publishing what rings it.
    'a poll reports room for less than a chunk' =>
      ['wpoll', 'POLL', 'if (room >= erx_ring_span(chunk))', 'if (room >= erx_ring_span(chunk) / 2)'],
    'a write poll waits without publishing its need' =>
      ['wpoll', 'PI7', 'if (pipe_wmay_wait(w, need, in->value))',
       'if (w->poll || pipe_wmay_wait(w, need, in->value))'],
    'a read poll waits without arming' =>
      ['rpoll', 'PI7', "\tif (r->published)\n", "\tif (r->published || r->poll)\n"],
    'a read that armed and then found bytes keeps its sleepers bits' =>
      ['flow', 'PI7', 'if (r->armed && r->after != R_AFTER_DATA)', 'if (false)'],
    'a read of 0 bytes that leaves the sleepers bits of a wait it gives up' =>
      ['flow', 'PI7', "\t\treturn (pipe_rreleased(r));\n\t}\n\tr->phase = LOCK_TRIED;",
       "\t\treturn (pipe_done(0));\n\t}\n\tr->phase = LOCK_TRIED;"],
    "a read that copied bytes waits for a join's report" =>
      ['join', 'PI5', 'if (after != R_AFTER_DONE && r->done > 0) {', 'if (false) {'],
    'a reader that ignores wends' =>
      ['merge-join', 'PI6', 'if (in->value > r->known)', 'if (false)'],
    # Holds the window between COPY_WENDS and its step, in which a join's report can land.
    'a reader that fails on a lane taken up after its wends copy' =>
      ['merge-join', 'PI2', "\t\tif (in->value > r->known)\n\t\t\treturn (pipe_rrelease_begin(r, R_AFTER_REPORT, 0));",
       "\t\tif (r->nlanes > in->value)\n\t\t\treturn (pipe_done(-EIO));\n\t\tif (in->value > r->known)\n\t\t\treturn (pipe_rrelease_begin(r, R_AFTER_REPORT, 0));"],
    'the merge taking the largest order key' =>
      ['merge', 'PI6', 'a->key < best->key ||', 'a->key > best->key ||'],
    'the merge picking from the first look alone' =>
      ['merge', 'PI6', "\t\tr->phase = LOOK_WENDS;\n\t\treturn (pipe_act(ERX_PIPE_OP_COPY_WENDS));",
       "\t\tr->second = true;\n\t\treturn (pipe_rlooked(r));"],
    'a write that returns before the clock has passed its publication' =>
      ['merge-repeat', 'PI6', "\tif (w->done > 0) {\n\t\tw->outcome = outcome;", "\tif (false) {\n\t\tw->outcome = outcome;"],
    'a batch marked with the clock of the copy that opened it' =>
      ['merge', 'PI6', 'mark = lane->looked ? lane->look : 0;', 'mark = r->clock;'],
    'a co-reader that releases the lock without clearing its owner' =>
      ['coread', 'PI7', "\tr->phase = RELEASE_STORED;\n\treturn (pipe_act(ERX_PIPE_OP_RELEASE_LOCK));",
       "\tr->phase = RELEASE_STORED;\n\treturn (pipe_act(ERX_PIPE_OP_FENCE));"],
    'a co-reader that waits for the lock without its waiters bit' =>
      ['coread', 'PI7', "\t\tr->phase = LOCK_WAITER_SET;\n\t\treturn (pipe_act(ERX_PIPE_OP_SET_WAITER));",
       "\t\tr->phase = LOCK_WAITER_SET;\n\t\treturn (pipe_act(ERX_PIPE_OP_FENCE));"],
    'the retire row read as none' =>
      ['coread-dies', 'PI5', "\tcase ERX_PIPE_SETTLE_RETIRE:\n\t\tpipe_make_current",
       "\tcase ERX_PIPE_SETTLE_RETIRE:\n\t\tbreak;\n\t\tpipe_make_current"],
    'the finished row read as a retire' =>
      ['coread-dies', 'PI5', "\t\treturn (ERX_PIPE_SETTLE_FINISHED);", "\t\treturn (ERX_PIPE_SETTLE_RETIRE);", CHECK],
    'a continued record read from its start' =>
      ['coread', 'PI5', "\t\tpipe_make_current(r, at, copy.cur_pos, copy.len,\n\t\t    copy.cur_off);\n\t\treturn (pipe_rcopy_begin(r));",
       "\t\tpipe_make_current(r, at, copy.cur_pos, copy.len,\n\t\t    0);\n\t\treturn (pipe_rcopy_begin(r));"],
    'a lost pipe read on' =>
      ['lost', 'PI7', 'if (r->len == 0 || r->lost) {', 'if (r->len == 0) {'],
    'a pipe server that forgets to tell one reader of a gone writer' =>
      ['coread', 'PI7', "\tfor (r = 0; r < sc->nr; r++)\n\t\tif (alive(&wd->r[r]))",
       "\tfor (r = 0; r < sc->nr - 1; r++)\n\t\tif (alive(&wd->r[r]))", EXPLORER],
    'a co-reader that keeps its waiters bit once it holds the lock' =>
      ['coread', 'PI7', "\tif (r->waiting)\n\t\treturn (pipe_rclear_waiter(r, LOCK_TAKEN));",
       "\tif (false)\n\t\treturn (pipe_rclear_waiter(r, LOCK_TAKEN));"],
    'a read of a lost pipe that waits for the reader lock a dead co-reader holds' =>
      ['coread-lost-dies', 'PI7', 'if (r->len == 0 || r->lost) {', 'if (r->len == 0) {'],
    # Two calls on one read end: one clears the sleepers bits the other waits on.
    "a read that clears the sleepers bits without waking the end's other calls" =>
      ['rcalls', 'PI7', "\tr->armed = false;\n\tr->wake_local = true;", "\tr->armed = false;"],
    "liberx's read that ignores wake_local" =>
      ['rcalls', 'PI7', "\tif (local)\n\t\twake_asleep(p);", "\tif (local && writer)\n\t\twake_asleep(p);", EXPLORER],
    # Two calls on one write end: one replaces the need the other waits on.
    "a write that replaces a published need without waking the end's other calls" =>
      ['wcalls', 'PI7', "\t\tif (w->armed)\n\t\t\tw->wake_local = true;\n", ''],
    "liberx's write that ignores wake_local" =>
      ['wcalls', 'PI7', "\tif (local)\n\t\twake_asleep(p);", "\tif (local && !writer)\n\t\twake_asleep(p);", EXPLORER],
    "write calls that always store their need, waking each other for ever" =>
      ['wcalls', 'PI4', 'return (w->armed && need >= w->need && rpos < w->need);', 'return (w->armed && need >= w->need && rpos < w->need && w->len == 0);'],
    "write calls that take an rpos the room check refused for a crossing" =>
      ['hostile-wcalls', 'PI4', "\tif (w->published || rpos >= need)", "\tif (w->published)"]
  }.freeze

  def test_seeded_faults_are_caught
    Dir.mktmpdir('erx-pipe-core-mutant-') do |directory|
      in_parallel(MUTANTS.to_a) do |name, (scenario, property, original, replacement, file)|
        file ||= CORE
        source = File.read(File.join(ROOT, file))
        path = File.join(directory, "#{name.tr(' ', '-').delete("'")}.c")
        File.write(path, source.sub(original, replacement))
        [name, property, source.scan(original).size,
         *with_explorer({ file => path }, ['-O2']) { |explorer| Open3.capture2e(explorer, scenario, 'landing', stdin_data: '') }]
      end.each do |name, property, places, output, status|
        assert_equal 1, places, "mutant #{name} must edit exactly one place"
        refute status.success?, "seeded fault not caught: #{name}"
        assert_match(/^FAIL #{property}:/, output, "seeded fault not caught by #{property}: #{name}")
      end
    end
  end

  private

  # The block's results over items, PARALLEL of them running at once, in the items' order.
  def in_parallel(items, &block)
    items.each_slice(PARALLEL).flat_map do |slice|
      slice.map { |item| Thread.new { block.call(item) } }.map(&:value)
    end
  end

  # Builds the explorer from the core, the checks and the model, each from the tree unless
  # replaced names a mutant's copy in its place.
  def with_explorer(replaced, options)
    sources = [CORE, CHECK, EXPLORER].map { |source| replaced.fetch(source, File.join(ROOT, source)) }
    Dir.mktmpdir('erx-pipe-core-') do |directory|
      binary = File.join(directory, 'pipe_explore')
      output, status = Open3.capture2e(COMPILER, *FLAGS, *options, *Erx::Generated.include_flags(root: ROOT),
                                       '-I', File.join(ROOT, 'include'), '-I', File.join(ROOT, 'liberx'),
                                       *sources, '-o', binary, stdin_data: '')
      assert status.success?, output
      yield binary
    end
  end
end
