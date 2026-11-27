# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/dependencies'

# The read-only F2FS volume, erx_f2fs_volume, and its erx_fs callback module erx_f2fs
# (docs/design-f2fs.md, "One process owns a volume"): its EUnit cases on stock's emulator
# (ERX_ERL and ERX_ERLC), over a real erx_blk_window and every corpus image the fetch step
# provides, then the same cases with one seeded fault each, which must fail the case named
# for it.
class ErxF2fsVolumeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  VOLUME = 'erlang/apps/erx_f2fs/src/erx_f2fs_volume.erl'
  REQUEST = 'erlang/apps/erx_f2fs/src/erx_f2fs_request.erl'
  CORE = 'erlang/apps/erx_f2fs/src/erx_f2fs_core.erl'
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl test/erlang/erx_f2fs_corpus.erl
             test/erlang/erx_f2fs_mount_tests.erl test/erlang/erx_f2fs_core_tests.erl
             test/erlang/erx_f2fs_listing.erl test/erlang/erx_f2fs_volume_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')

  Seed = Data.define(:fault, :source, :anchor, :replacement, :failure)

  # The verdict of the case named Name, after whatever log lines it writes (a crash report
  # spans many), before the next case's line.
  def self.case_failed(name) = /#{name}[^\n]*?\.\.\.(?:(?!\n  erx_f2fs_volume_tests: ).)*?\*failed\*/m
  # The corpus case's verdict, after the log lines (a header and a message each) its
  # trees write.
  CORPUS_CASE_FAILED = /corpus_trees_list_through_the_volume_as_through_the_core_test_\/0-fun-\d+-\.\.\.(?:=ERROR REPORT[^\n]*\n[^\n]*\n)*\*failed\*/

  # The read-write case's verdict.
  WRITE_CASE_FAILED = case_failed('a_write_survives_fsync_unmount_and_every_cut')

  SEEDS = [
    Seed.new(fault: 'the cache never evicting', source: VOLUME,
             anchor: 'when map_size(Blocks) > Limit ->',
             replacement: 'when map_size(Blocks) < 0 ->',
             failure: CORPUS_CASE_FAILED),
    Seed.new(fault: 'an open for truncation admitted', source: REQUEST,
             anchor: '    Truncate = Flags band ?ERX_P9_O_TRUNC =/= 0,',
             replacement: '    Truncate = false,',
             failure: /every_mutation_answers_erofs[^\n]*failed/),
    Seed.new(fault: "a readdir's core calls bounded by the volume's blocks, not the directory's",
             source: REQUEST,
             anchor: '    case Call =< (2 * min(Held, User) + 5) div 8 + 1 of',
             replacement: '    case Call =< (2 * max(Held, User) + 5) div 8 + 1 of',
             failure: /a_readdir_is_bounded_by_the_blocks_its_directory_holds[^\n]*failed/),
    Seed.new(fault: "an entry's qid read from the inode its \".\" slot names", source: REQUEST,
             anchor: '               <<".">> -> Dir;',
             replacement: '               <<".">> -> Ino;',
             failure: /a_readdir_reads_on_through_the_core_calls[^\n]*failed/),
    Seed.new(fault: 'a run of blocks one block longer than the window carries', source: VOLUME,
             anchor: 'runs(First, Count, [Next | Rest], Max) when Next =:= First + Count, Count < Max ->',
             replacement: 'runs(First, Count, [Next | Rest], Max) when Next =:= First + Count, Count =< Max ->',
             failure: CORPUS_CASE_FAILED),
    Seed.new(fault: 'a written block kept out of the cache', source: VOLUME,
             anchor: 'Cached = lists:foldl(fun({Address, Block}, Acc) -> Acc#{Address => Block} end, Blocks, Writes),',
             replacement: 'Cached = lists:foldl(fun({_Address, _Block}, Acc) -> Acc end, Blocks, Writes),',
             failure: case_failed('writes_read_back_across_checkpoints')),
    Seed.new(fault: "a read judging an owner without the state's summaries", source: CORE,
             anchor: '    Volume#{dirty => Nodes, held => Summaries, counts => Counts}.',
             replacement: '    Volume#{dirty => Nodes, held => maps:without(maps:keys(Summaries), Summaries), counts => Counts}.',
             failure: WRITE_CASE_FAILED),
    Seed.new(fault: "a read taking a dirty node's committed block", source: CORE,
             anchor: 'node_block(#{superblock := Super, dirty := Dirty}, Nid, Ino, _Blocks) when is_map_key(Nid, Dirty) ->',
             replacement: 'node_block(#{superblock := Super, dirty := Dirty}, Nid, Ino, _Blocks) when is_map_key(Nid, Dirty), false ->',
             failure: WRITE_CASE_FAILED),
    Seed.new(fault: "a checkpoint's phases written without the flush between them", source: VOLUME,
             anchor: 'fun(Phase, {ok, S}) -> flushed(written(Phase, S));',
             replacement: 'fun(Phase, {ok, S}) -> written(Phase, S);',
             failure: WRITE_CASE_FAILED),
    Seed.new(fault: "a write's first block merged over zeros, not the old bytes", source: REQUEST,
             anchor: 'Merged = <<(binary:part(Head, 0, Lead))/binary, Bytes/binary,',
             replacement: 'Merged = <<0:(Lead * 8), Bytes/binary,',
             failure: case_failed('writes_read_back_across_checkpoints')),
    Seed.new(fault: 'an open for appending admitted', source: REQUEST,
             anchor: '{true, _, _, ok} when Flags band (?ERX_P9_O_TRUNC bor ?ERX_P9_O_APPEND) =/= 0 ->',
             replacement: '{true, _, _, ok} when Flags band ?ERX_P9_O_TRUNC =/= 0 ->',
             failure: case_failed('a_read_write_volume_refuses_appends_truncation_and_gaps')),
    Seed.new(fault: "a write admitted past the size's block", source: REQUEST,
             anchor: 'ok ?= supported(not is_map_key(inline_data, Inode) andalso First =< Size div ?BLOCK_SIZE),',
             replacement: 'ok ?= supported(not is_map_key(inline_data, Inode)),',
             failure: case_failed('a_read_write_volume_refuses_appends_truncation_and_gaps')),
    Seed.new(fault: 'a write admitted to inline data', source: REQUEST,
             anchor: 'ok ?= supported(not is_map_key(inline_data, Inode) andalso First',
             replacement: 'ok ?= supported(First',
             failure: case_failed('a_write_refuses_a_slot_no_node_holds_and_inline_data')),
    Seed.new(fault: 'a write admitted to a block no node holds', source: REQUEST,
             anchor: '{ok, none} -> {reply, {error, enotsup}};',
             replacement: '{ok, none} -> mapped(Volume, Inode, Range, Blocks);',
             failure: case_failed('a_write_refuses_a_slot_no_node_holds_and_inline_data')),
    Seed.new(fault: "a write's last block merged over the medium's bytes past the size", source: REQUEST,
             anchor: '{ok, Bytes} ?= erx_f2fs_core:read(Volume, Inode, Block * ?BLOCK_SIZE, ?BLOCK_SIZE, Blocks),',
             replacement: '{ok, Bytes} ?= erx_f2fs_core:read(Volume, Inode#{i_size := (Block + 1) * ?BLOCK_SIZE}, ' \
                          'Block * ?BLOCK_SIZE, ?BLOCK_SIZE, Blocks),',
             failure: case_failed('a_write_reads_zeros_past_the_size_and_is_cut_at_64_blocks')),
    Seed.new(fault: 'a write taking 65 blocks', source: REQUEST,
             anchor: '-define(WRITE_BLOCKS, 64).',
             replacement: '-define(WRITE_BLOCKS, 65).',
             failure: case_failed('a_write_reads_zeros_past_the_size_and_is_cut_at_64_blocks')),
    Seed.new(fault: 'a failed write leaving the volume running', source: VOLUME,
             anchor: "        {error, eio} ->\n            {ended, {error, eio}, State}\n",
             replacement: "        {error, eio} ->\n            {{error, eio}, State}\n",
             failure: case_failed('a_failed_write_or_flush_ends_the_volume_with_eio')),
    Seed.new(fault: "a failed fsync's checkpoint leaving the volume running", source: VOLUME,
             anchor: "        {ok, Committed} -> {ok, Committed};\n        {error, eio} -> {ended, {error, eio}, State}",
             replacement: "        {ok, Committed} -> {ok, Committed};\n        {error, eio} -> {{error, eio}, State}",
             failure: case_failed('a_failed_write_or_flush_ends_the_volume_with_eio')),
    Seed.new(fault: 'a handle answering an access it was not opened for', source: REQUEST,
             anchor: 'opened_for({Nid, Access}, Need) when Access =:= Need; Access =:= read_write -> {ok, Nid};',
             replacement: 'opened_for({Nid, _Access}, _Need) when is_integer(Nid) -> {ok, Nid};',
             failure: case_failed('a_handle_answers_its_access_and_a_write_open_needs_the_owners_bits')),
    Seed.new(fault: "an open for writing admitted without the owner's bits", source: REQUEST,
             anchor: 'erx_fs:open_permitted(Mode, Access, Truncate)',
             replacement: 'erx_fs:open_permitted(Mode, read, false)',
             failure: case_failed('a_handle_answers_its_access_and_a_write_open_needs_the_owners_bits')),
    Seed.new(fault: "an open to read admitted without the owner's read bit", source: REQUEST,
             anchor: 'erx_fs:open_permitted(Mode, Access, Truncate)',
             replacement: 'erx_fs:open_permitted(Mode bor 8#400, Access, Truncate)',
             failure: case_failed('an_open_to_read_needs_the_owners_read_bit')),
    Seed.new(fault: "a read-write volume's statfs counting the checkpoint's user blocks", source: REQUEST,
             anchor: 'true -> {erx_f2fs_mount:offered(Volume), maps:get(counts, Volume)};',
             replacement: 'true -> {User, maps:get(counts, Volume)};',
             failure: case_failed('statfs_counts_the_space_a_read_write_volume_offers'))
  ].freeze

  def test_eunit_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    SEEDS.each do |seed|
      text = File.read(File.join(ROOT, seed.source))
      assert_equal 1, text.scan(seed.anchor).size, "the seed no longer applies: #{seed.fault}"
      output, status = eunit({ seed.source => text.sub(seed.anchor, seed.replacement) })
      refute status.success?, "#{seed.fault} passed:\n#{output}"
      assert_match seed.failure, output, seed.fault
    end
  end

  private

  # Runs the EUnit cases against erx, erx_files, erx_blk and erx_f2fs with the given sources
  # replaced; the output and status.
  def eunit(replaced)
    Dir.mktmpdir('erx-f2fs-volume-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_files erx_blk erx_f2fs], tests: TESTS,
                                replaced: replaced)
      Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS, 'ERX_DEPS_LOCK' => LOCK }, 'gtimeout', '-k', '10', '900',
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_f2fs_volume_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
