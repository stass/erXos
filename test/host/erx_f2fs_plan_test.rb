# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# F2FS's volume state and checkpoint plan, erx_f2fs_core's state and erx_f2fs_plan
# (docs/design-f2fs.md, "The volume state", "Checkpoints" and "Read-write mounts: the mount
# checkpoint"): their EUnit cases on stock's emulator (ERX_ERL and ERX_ERLC) over the fresh
# volumes and the corpus images the fetch step put under build/third_party, then the same
# cases against a tree with one seeded fault each, which must fail the case named for it.
class ErxF2fsPlanTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_f2fs/src/erx_f2fs_core.erl'
  PLAN = 'erlang/apps/erx_f2fs/src/erx_f2fs_plan.erl'
  REQUEST = 'erlang/apps/erx_f2fs/src/erx_f2fs_request.erl'
  TESTS = %w[test/erlang/erx_f2fs_plan_tests.erl test/erlang/erx_f2fs_corpus.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')
  FAILED = /failed/

  Seed = Data.define(:fault, :file, :anchor, :replacement, :case_name)

  SEEDS = [
    Seed.new(fault: 'a section added to the free set before its commit', file: CORE,
             anchor: "        true -> valid_bit(State, Address, 0, none);\n",
             replacement: '        true -> #state{volume = #{superblock := #{main_blkaddr := M, segs_per_sec := SS}}} = ' \
                          "S1 = valid_bit(State, Address, 0, none),\n" \
                          '                S1#state{free = ordsets:add_element((Address - M) div ' \
                          "?BLOCKS_PER_SEG div SS, S1#state.free)};\n",
             case_name: 'a_dirty_dentry_block_goes_to_the_warm_data_log_test'),
    Seed.new(fault: "the checkpoint's last block written before its tables' flush", file: PLAN,
             anchor: '        {ok, [Phase1, [{Last, Copy}]], ',
             replacement: '        {ok, [lists:keysort(1, [{Last, Copy} | Phase1])], ',
             case_name: 'set_node_keeps_every_count_a_node_is_in_test_'),
    Seed.new(fault: 'set_node not counting i_blocks', file: CORE,
             anchor: '                    _ -> count(State2, Ino, Delta, Counts)',
             replacement: '                    _ -> count(State2, none, Delta, Counts)',
             case_name: 'set_node_keeps_every_count_a_node_is_in_test_'),
    Seed.new(fault: 'a mount resuming within only the committed segment', file: CORE,
             anchor: '            || K <- lists:seq(0, S - 1),',
             replacement: '            || K <- [Segno rem S],',
             case_name: 'a_log_resumes_past_the_durable_blocks_of_its_whole_section_test'),
    Seed.new(fault: "an old block's valid bit cleared without its summary's confirmation", file: CORE,
             anchor: '                Cleared = case not real(Old) orelse confirms(State, Old, Owner, Index, Blocks) of',
             replacement: '                Cleared = case not real(Old) orelse is_boolean(confirms(State, Old, Owner, Index, Blocks)) of',
             case_name: 'set_slot_clears_only_what_the_summary_confirms_test_'),
    Seed.new(fault: 'a write admitted one block past the space the volume offers', file: CORE,
             anchor: '    case After > max(Before, erx_f2fs_mount:offered(Volume)) of',
             replacement: '    case After > max(Before, erx_f2fs_mount:offered(Volume)) + 1 of',
             case_name: 'a_write_stays_within_the_space_the_volume_offers_test_'),
    Seed.new(fault: 'a volume past its space refused a rewrite', file: CORE,
             anchor: '    case After > max(Before, erx_f2fs_mount:offered(Volume)) of',
             replacement: '    case After > max(Before - Before, erx_f2fs_mount:offered(Volume)) of',
             case_name: 'a_write_stays_within_the_space_the_volume_offers_test_'),
    Seed.new(fault: "an epoch let one node past the walk's bound", file: CORE,
             anchor: 'map_size(Nodes) + map_size(Dentries) =< erx_f2fs_mount:walk_blocks().',
             replacement: 'map_size(Nodes) + map_size(Dentries) =< erx_f2fs_mount:walk_blocks() + 1.',
             case_name: 'the_room_rule_bounds_the_epoch_by_the_walk_test'),
    Seed.new(fault: "an epoch's charge leaving out its dentry blocks", file: CORE,
             anchor: 'map_size(Nodes) + map_size(Dentries) =< erx_f2fs_mount:walk_blocks().',
             replacement: 'map_size(Nodes) + 0 * map_size(Dentries) =< erx_f2fs_mount:walk_blocks().',
             case_name: 'the_room_rule_bounds_the_epoch_by_the_walk_test'),
    Seed.new(fault: "a read-write volume's statfs counting the last checkpoint's blocks", file: REQUEST,
             anchor: 'true -> {erx_f2fs_mount:offered(Volume), maps:get(counts, Volume)};',
             replacement: 'true -> {erx_f2fs_mount:offered(Volume), Header};',
             case_name: 'set_slot_clears_only_what_the_summary_confirms_test_')
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      text = File.read(File.join(ROOT, seed.file))
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ seed.file => text.sub(seed.anchor) { seed.replacement } }, only: seed.case_name)
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match FAILED, output, seed.fault
    end
  end

  private

  # Runs the EUnit cases against erx and erx_f2fs with the given sources replaced; the
  # output and status.
  def eunit(replaced, only: nil)
    Dir.mktmpdir('erx-f2fs-plan-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS, replaced: replaced)
      spec = ErlangBuild.eunit_spec(TESTS.take(1), only)
      Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS, 'ERX_DEPS_LOCK' => LOCK }, 'gtimeout', '-k', '10', '900',
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval', ErlangBuild.eunit_eval(spec),
                      chdir: work, stdin_data: '')
    end
  end
end
