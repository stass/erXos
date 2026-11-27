# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/dependencies'

# F2FS's mount, erx_f2fs_mount (docs/design-f2fs.md, "Mount"): its EUnit cases on stock's
# emulator (ERX_ERL and ERX_ERLC), over the fixture volume and every corpus image the fetch
# step provides, then the same cases against a mount with one seeded fault each, which must
# fail the case named for it. A corpus the fetch step has not provided fails the test,
# naming its source.
class ErxF2fsMountTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MOUNT = 'erlang/apps/erx_f2fs/src/erx_f2fs_mount.erl'
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl test/erlang/erx_f2fs_corpus.erl
             test/erlang/erx_f2fs_mount_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')

  Seed = Data.define(:fault, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "the packs compared without wrap-around",
             anchor: "    <<Difference:64/signed>> = <<(A - B):64>>,\n    Difference > 0.",
             replacement: "    A > B.",
             failure: /the_later_pack_wins_under_wrap_around[^\n]*failed/),
    Seed.new(fault: "the partition window check dropped",
             anchor: "        check_partition(Partition, Super),\n", replacement: "",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*partition[^\n]*failed/),
    Seed.new(fault: "the features that extend an inode allowed without EXTRA_ATTR",
             anchor: "    require(Extending =:= [], {superblock, {needs_extra_attr, Extending}}).",
             replacement: "    require(Extending =:= Extending, {superblock, {needs_extra_attr, Extending}}).",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*needs_extra_attr[^\n]*failed/),
    Seed.new(fault: "two logs allowed on one segment",
             anchor: "    require(length(lists:usort(Segments)) =:= length(Segments), {checkpoint, log_segments}).",
             replacement: "    ok.",
             failure: /each_checkpoint_rule_fails_with_its_name[^\n]*log_segments[^\n]*failed/),
    Seed.new(fault: "the cleaner's reserve counted in segments, not sections",
             anchor: 'mode(#{feature := Feature, section_count := Sections}) ->',
             replacement: 'mode(#{feature := Feature, segment_count_main := Sections}) ->',
             failure: /read_only_reasons[^\n]*12 sections of two segments[^\n]*failed/),
    Seed.new(fault: "a refused first copy yielding to the second",
             anchor: "        check_ssa_area(Super),\n        {ok, Super}",
             replacement: "        check_ssa_area(Super),\n        check_features(Super),\n        {ok, Super}",
             failure: /a_valid_first_copy_with_a_refused_feature_fails_the_mount[^\n]*failed/),
    Seed.new(fault: "the last bad copy's failure answered instead of copy 0's",
             anchor: "            [{_Copy, First} | _] = BadCopies,\n",
             replacement: "            {_Copy, First} = lists:last(BadCopies),\n",
             failure: /both_bad_copies_fail_with_the_first_ones_rule[^\n]*failed/),
    Seed.new(fault: "an SSA short of the main area allowed",
             anchor: "    require(Ssa * ?BLOCKS_PER_SEG >= Main, {superblock, ssa_area}).",
             replacement: "    require(Ssa * ?BLOCKS_PER_SEG >= 0, {superblock, ssa_area}).",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*ssa_area[^\n]*failed/),
    Seed.new(fault: "the main area allowed past the partition",
             anchor: "    require(Blocks =< Partition andalso main_end(Super) =< Partition,",
             replacement: "    require(Blocks =< Partition andalso Super =:= Super,",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*partition[^\n]*failed/),
    Seed.new(fault: "a checkpoint area of one segment allowed",
             anchor: "Segments >= ?PACKS", replacement: "Segments >= 1",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*checkpoint_area[^\n]*failed/)
  ].freeze

  def test_eunit_cases_pass
    dependencies = Erx::Dependencies.new(root: ROOT, runner: nil)
    unfetched = dependencies.sources
                            .select { |source| source.key?('decoded_sha256') && source.fetch('id').start_with?('f2fs-') }
                            .map { |source| source.fetch('id') }.reject { |id| dependencies.fetched?(id) }
    assert_empty unfetched, 'corpora not fetched, or fetched for another pin: remove build/third_party/ID ' \
                            'and run `ruby tools/erx fetch --source ID` for each'
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    text = File.read(File.join(ROOT, MOUNT))
    SEEDS.each do |seed|
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ MOUNT => text.sub(seed.anchor, seed.replacement) })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs the EUnit cases against erx and erx_f2fs with the given sources replaced; the
  # output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-f2fs-mount-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS, 'ERX_DEPS_LOCK' => LOCK }, 'gtimeout', '-k', '10', '900',
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_f2fs_mount_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
