# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/dependencies'

# F2FS's node tree, read, erx_f2fs_core (docs/design-f2fs.md, "Inodes"): its EUnit cases on
# stock's emulator (ERX_ERL and ERX_ERLC), over a file of the fixture volume and every corpus
# image the fetch step provides, then the same cases with one seeded fault each in the core or
# the codec's node decoders, which must fail the case named for it.
class ErxF2fsCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_f2fs/src/erx_f2fs_core.erl'
  CODEC = 'erlang/apps/erx_f2fs/src/erx_f2fs_codec.erl'
  TESTS = %w[test/erlang/erx_f2fs_codec_tests.erl test/erlang/erx_f2fs_corpus.erl
             test/erlang/erx_f2fs_mount_tests.erl test/erlang/erx_f2fs_core_tests.erl].freeze
  CORPUS = File.join(ROOT, 'build/third_party')
  LOCK = File.join(ROOT, 'deps.lock')

  Seed = Data.define(:fault, :source, :anchor, :replacement, :failure)

  SEEDS = [
    Seed.new(fault: "a node footer's nid not compared with the nid asked for", source: CODEC,
             anchor: '    require(FooterNid =:= Nid andalso FooterIno =:= Ino andalso',
             replacement: '    require(is_integer(FooterNid + Nid) andalso FooterIno =:= Ino andalso',
             failure: /\(a direct node naming another nid\)[^\n]*failed/),
    Seed.new(fault: "a node footer's node offset not compared with the node's place", source: CODEC,
             anchor: '                Flag bsr ?ERX_F2FS_NODE_MARK_BITS =:= Offset,',
             replacement: '                is_integer(Flag + Offset),',
             failure: /\(an indirect node naming itself\)[^\n]*failed/),
    Seed.new(fault: "a file block at a tree's span taken as an index past its node's slots", source: CORE,
             anchor: '        Span when Block < Span -> {Tree, path(Depth, Offset, Block)};',
             replacement: '        Span when Block =< Span -> {Tree, path(Depth, Offset, Block)};',
             failure: /each_block_maps_through_its_node[^\n]*failed/),
    Seed.new(fault: "the inline xattr words left in an inode's address array", source: CODEC,
             anchor: '    Count = ?ERX_F2FS_ADDRS_PER_INODE - ExtraWords - XattrWords,',
             replacement: '    Count = ?ERX_F2FS_ADDRS_PER_INODE - ExtraWords - 0 * XattrWords,',
             failure: /inline_xattrs_end_the_address_array_early[^\n]*failed/),
    Seed.new(fault: 'a hole read as block 0', source: CORE,
             anchor: '                            Address =/= ?ERX_F2FS_NULL_ADDR, Address =/= ?ERX_F2FS_NEW_ADDR]).',
             replacement: '                            Address =/= ?ERX_F2FS_NEW_ADDR]).',
             failure: /a_read_gives_data_holes_and_new_addr_as_zeros[^\n]*failed/),
    Seed.new(fault: "a long name's hash state not carried from one 16-byte chunk to the next", source: CODEC,
             anchor: '        _ -> hash_chunks(Rest, State)',
             replacement: '        _ -> hash_chunks(Rest, {16#67452301, 16#efcdab89})',
             failure: /corpus_directories_list_and_look_up_as_linux_wrote[^\n]*failed/),
    Seed.new(fault: 'a lookup that stops one level early', source: CORE,
             anchor: 'buckets(N, Depth, _Level, _Start, _Hash, _End) when N >= Depth ->',
             replacement: 'buckets(N, Depth, _Level, _Start, _Hash, _End) when N >= Depth - 1 ->',
             failure: /each_name_is_found_in_its_bucket[^\n]*failed/),
    Seed.new(fault: 'a readdir stepping over a run of holes a block at a time', source: CORE,
             anchor: '    case length(lists:takewhile(fun empty_slot/1, Slots)) of',
             replacement: '    case min(1, length(lists:takewhile(fun empty_slot/1, Slots))) of',
             failure: /a_readdir_over_holes_is_one_step_a_run[^\n]*failed/),
    Seed.new(fault: "a readdir stepping over a node id 0's span a block at a time", source: CORE,
             anchor: '    {{empty, rest(Path)}, Nodes};',
             replacement: '    {{empty, 1}, Nodes};',
             failure: /a_readdir_over_holes_is_one_step_a_run[^\n]*failed/),
    Seed.new(fault: "a name holding '/' accepted", source: CODEC,
             anchor: '            require(binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch, name),',
             replacement: '            require(binary:match(Name, [<<0>>]) =:= nomatch, name),',
             failure: /each_directory_refusal_names_its_rule[^\n]*failed/)
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
    texts = [CORE, CODEC].to_h { |path| [path, File.read(File.join(ROOT, path))] }
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
    Dir.mktmpdir('erx-f2fs-core-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_f2fs], tests: TESTS, replaced: replaced)
      Open3.capture2e({ 'ERX_F2FS_CORPUS' => CORPUS, 'ERX_DEPS_LOCK' => LOCK }, 'gtimeout', '-k', '10', '900',
                      ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_f2fs_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
