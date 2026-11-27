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
  CORE = 'erlang/apps/erx_f2fs/src/erx_f2fs_core.erl'
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl test/erlang/erx_f2fs_corpus.erl
             test/erlang/erx_f2fs_mount_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')

  # A seeded fault in the mount, or in erx_f2fs_core, whose NAT lookup the root's read uses.
  Seed = Data.define(:fault, :anchor, :replacement, :failure, :source) do
    def initialize(source: MOUNT, **fields) = super
  end

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
             anchor: "    require(length(lists:usort(Segments)) =:= length(Segments), {checkpoint, log_segments}),\n",
             replacement: "",
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
             anchor: "    require(Blocks =< Partition andalso erx_f2fs_codec:main_end(Super) =< Partition,",
             replacement: "    require(Blocks =< Partition andalso Super =:= Super,",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*partition[^\n]*failed/),
    Seed.new(fault: "a checkpoint area of one segment allowed",
             anchor: "Segments >= ?PACKS", replacement: "Segments >= 1",
             failure: /each_superblock_rule_fails_with_its_name[^\n]*checkpoint_area[^\n]*failed/),
    Seed.new(fault: "a SIT journal entry for a segment past the main area",
             anchor: "    require(lists:all(fun(Segment) -> Segment < Main end, Segments), {sit, journal_segno}),\n",
             replacement: "",
             failure: /\(a SIT journal segment past the main area\)[^\n]*failed/),
    Seed.new(fault: "a NAT entry's node allowed outside the main area", source: CORE,
             anchor: "    require(valid_block(Volume, Address), {nat, block_addr}),",
             replacement: "    ok,",
             failure: /\(the root's node outside the main area\)[^\n]*failed/),
    Seed.new(fault: "a NAT entry's node allowed at a block the SIT holds free", source: CORE,
             anchor: "(Address - Main) rem ?BLOCKS_PER_SEG) =:= 1;",
             replacement: "(Address - Main) rem ?BLOCKS_PER_SEG) >= 0;",
             failure: /\(the root's node at a block the SIT holds free\)[^\n]*failed/),
    Seed.new(fault: "normal summaries found from the pack's start alone",
             anchor: "                false -> DataBlocks =:= ?LOGS_PER_KIND",
             replacement: "                false -> DataBlocks >= ?LOGS_PER_KIND",
             failure: /\(normal summaries not ending at the node summaries\)[^\n]*failed/),
    Seed.new(fault: "the node segments' valid blocks not counted against valid_node_count",
             anchor: "                                Type >= ?ERX_F2FS_LOG_HOT_NODE]) =:= Nodes,",
             replacement: "                                Type >= ?ERX_F2FS_LOG_HOT_NODE]) >= Nodes,",
             failure: /\(node blocks the checkpoint does not count\)[^\n]*failed/),
    Seed.new(fault: "an LFS log's blocks after its next left unchecked",
             anchor: "Later =:= <<0:(bit_size(Later))>>", replacement: "Later =:= Later",
             failure: /\(an LFS log with a block in use after its next\)[^\n]*failed/),
    Seed.new(fault: "the SIT admitted only after it is read",
             anchor: "        admit_sit(Super, Allowance),\n", replacement: "",
             failure: /the_sit_is_admitted_before_it_is_read[^\n]*failed/),
    Seed.new(fault: "a table block always read from copy 0",
             anchor: "    [First + Index + erx_f2fs_codec:bit(Bitmap, Index) * table_blocks(Segments)",
             replacement: "    [First + Index + 0 * table_blocks(Segments)",
             failure: /the_fixture_mounts_read_write_from_pack_1[^\n]*failed/),
    Seed.new(fault: "the NAT's copy 1 placed a whole interleave further", source: CORE,
             anchor: "    First + Index div ?BLOCKS_PER_SEG * 2 * ?BLOCKS_PER_SEG + Index rem ?BLOCKS_PER_SEG +\n" \
                     "        erx_f2fs_codec:bit(Bitmap, Index) * ?BLOCKS_PER_SEG.",
             replacement: "    First + Index + erx_f2fs_codec:bit(Bitmap, Index) * 2 * ?BLOCKS_PER_SEG.",
             failure: /the_fixture_mounts_read_write_from_pack_1[^\n]*failed/),
    Seed.new(fault: "the compact form allowed the normal form's three blocks",
             anchor: "DataBlocks < ?LOGS_PER_KIND;", replacement: "DataBlocks =< ?LOGS_PER_KIND;",
             failure: /\(a compact form of three blocks\)[^\n]*failed/),
    Seed.new(fault: "a chain's footer compared without the checkpoint's CRC",
             anchor: "                   true -> Version bor (Crc bsl 32);",
             replacement: "                   true -> Version;",
             failure: /\(the version and CRC under CRC_RECOVERY\)[^\n]*failed/)
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
    texts = [MOUNT, CORE].to_h { |path| [path, File.read(File.join(ROOT, path))] }
    SEEDS.each do |seed|
      text = texts.fetch(seed.source)
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ seed.source => text.sub(seed.anchor, seed.replacement) })
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
