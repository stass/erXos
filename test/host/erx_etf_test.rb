# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/etf_wire'

# Judges liberx/erx_etf.c through its host driver, test/fixtures/etf_driver.c:
# every kind of the grammar accepted with the words ERTS's size pass counts
# for it; every tag outside the grammar, every field out of range and every
# prefix of a term refused; map keys equal under =:= refused in whatever
# encodings, and keys that only look alike accepted; the depth, word and
# scratch limits at their bounds; and the writer's refusals. Agreement with
# stock OTP is test/integration/erx_etf_oracle_test.rb's.
class ErxEtfTest < Minitest::Test
  include EtfWire

  # One of each kind, and the words ERTS's size pass counts for it.
  KINDS = {
    'small integer' => [EtfWire.small(5), 0], 'integer' => [EtfWire.int(-70_000), 0],
    'small big' => [EtfWire.small_big(0, [1] * 9), 3], 'large big' => [EtfWire.large_big(1, [1] * 9), 4],
    'big that fits' => [EtfWire.small_big(1, [5]), 2], 'float' => [EtfWire.float(1.5), 2],
    'atom' => [EtfWire.atom('ok'), 0], 'long atom' => [EtfWire.long_atom("\u00e9" * 255), 0],
    'empty binary' => [EtfWire.binary(''), 2], 'heap binary' => [EtfWire.binary('a' * 64), 10],
    'refc binary' => [EtfWire.binary('a' * 65), 8], 'bitstring' => [EtfWire.bits("\xff", 3), 3],
    'empty tuple' => [EtfWire.tuple, 0], 'tuple' => [EtfWire.tuple(EtfWire.small(1)), 2],
    'large tuple' => [EtfWire.large_tuple(EtfWire.small(1), EtfWire.nil_), 3], 'nil' => [EtfWire.nil_, 0],
    'string' => [EtfWire.string('ab'), 4], 'list' => [EtfWire.list([EtfWire.small(1)]), 2],
    'improper list' => [EtfWire.list([EtfWire.small(1)], EtfWire.atom('t')), 2],
    'empty map' => [EtfWire.map, 3], 'map' => [EtfWire.map([EtfWire.atom('k'), EtfWire.nil_]), 6],
    'hash map' => [EtfWire.map(*Array.new(33) { |key| [EtfWire.int(key), EtfWire.nil_] }), 125],
    'pid' => [EtfWire.pid('web@erxos'), 4], 'reference' => [EtfWire.ref('web@erxos'), 6],
    'fun' => [EtfWire.fun(free: [EtfWire.small(1)]), 7], 'export' => [EtfWire.export, 0],
    'record' => [EtfWire.record([EtfWire.atom('a'), EtfWire.atom('b')], [EtfWire.small(1), EtfWire.nil_]), 15],
    'empty record' => [EtfWire.record([], [], flags: 0), 8]
  }.freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-etf-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported erx_etf test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = EtfDriver.new(root: @root, runner: @runner, directory: @directory, flags: flags)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_every_kind_is_accepted_with_the_words_erts_counts
    answers = check(KINDS.values.map { |bytes, _| term(bytes) })
    KINDS.zip(answers).each do |(name, (_, words)), answer|
      assert_equal "accepted #{words}", answer.split[0, 2].join(' '), name
    end
    copies = answers.map { |answer| [answer.split.fetch(2)].pack('H*') }
    assert(check(copies.map { |bytes| term(bytes[1..]) }).all? { |answer| answer.start_with?('accepted ') })
  end

  def test_each_grammar_refuses_the_kinds_it_leaves_out
    fun, export, pid, ref = [EtfWire.fun, EtfWire.export, EtfWire.pid('web@erxos'), EtfWire.ref('web@erxos')]
    { 'd' => [], 's' => [fun, export], 'h' => [fun, export, pid, ref] }.each do |grammar, refused|
      answers = check([fun, export, pid, ref].map { |bytes| term(bytes, grammar: grammar) })
      [fun, export, pid, ref].zip(answers).each do |bytes, answer|
        expected = refused.include?(bytes) ? 'malformed tag 1' : 'accepted'
        assert answer.start_with?(expected), "#{grammar}: #{answer}"
      end
    end
  end

  def test_every_prefix_of_a_term_is_truncated_and_bytes_after_it_trailing
    whole = tuple(*KINDS.values.map(&:first))
    prefixes = (0...whole.bytesize).map { |length| term(whole.byteslice(0, length)) }
    assert(check(prefixes).all? { |answer| answer.start_with?('malformed truncated ') })
    assert_equal ["malformed trailing #{whole.bytesize + 1}", 'malformed version 0', 'malformed version 0'],
                 check([term(whole + "\x00"), raw("\x82".b + whole), raw('')])
  end

  def test_tags_outside_the_grammar_are_refused
    # FLOAT, ATOM, SMALL_ATOM, PID, NEW_PORT, PORT, V4_PORT, REFERENCE,
    # NEW_REFERENCE, FUN, COMPRESSED, LOCAL, ATOM_CACHE_REF, DIST_HEADER.
    tags = [99, 100, 115, 103, 89, 102, 120, 101, 114, 117, 80, 121, 82, 68, 0, 255]
    answers = check(tags.map { |tag| term([tag, 0, 1, 97, 0, 0, 0, 0, 0, 0].pack('C*')) })
    assert_equal ['malformed tag 1'] * tags.size, answers
    # A pid's node in ATOM_EXT, which ERTS reads but the grammar leaves out.
    assert_equal ['malformed tag 1'], check([term("\x58\x64\x00\x01a#{"\x00" * 12}")])
  end

  def test_fields_out_of_range_are_refused
    cases = {
      atom("\xc0\x80") => 'atom', atom("\xed\xa0\x80") => 'atom', atom("\xff") => 'atom', atom("\xe2\x82") => 'atom',
      atom("\xf4\x90\x80\x80") => 'atom', long_atom('a' * 256) => 'atom', [118, 1021].pack('Cn') => 'atom',
      [70, Float::INFINITY].pack('CG') => 'float', [70, 0x7ff8000000000000].pack('CQ>') => 'float',
      [77, 1, 0, 0xff].pack('CNCC') => 'bits', [77, 1, 9, 0xff].pack('CNCC') => 'bits', [77, 0, 8].pack('CNC') => 'bits',
      [111, (65_535 * 8) + 1, 0].pack('CNC') => 'big', [105, 1 << 24].pack('CN') => 'arity',
      [116, 1 << 31].pack('CN') => 'arity', [67, 65_536, 0].pack('CNC') => 'arity',
      record([], [], flags: 2) => 'record', [90, 3].pack('Cn') => 'ref_len', [90, 5].pack('Cn') => 'ref_len'
    }
    assert_refusals(cases)
  end

  def test_node_names_are_identifiers_at_the_host
    good = ['web@erxos', 'w_b-9@erxos', "#{'a' * 63}@erxos", '0@erxos']
    bad = ['web', 'Web@erxos', '.web@erxos', 'a.b@erxos', "#{'a' * 64}@erxos", 'web@erxos2', 'web@', '@erxos', 'w b@erxos',
           'web@erxos@erxos', 'web@ERXOS']
    answers = check((good + bad).flat_map { |node| [term(pid(node)), term(ref(node))] })
    assert(answers.first(good.size * 2).all? { |answer| answer.start_with?('accepted ') })
    assert_equal ['malformed node 1'] * (bad.size * 2), answers.drop(good.size * 2)
  end

  def test_fun_export_and_record_fields_have_their_kinds
    big59 = small_big(0, [0, 0, 0, 0, 0, 0, 0, 8]) # 2**59, one past ERTS's small integers
    accepted = [fun(old_index: small_big(0, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 7]), old_uniq: int(-1)),
                export(atom('m'), atom('f'), small(255)), export(atom('m'), atom('f'), small_big(0, [5])),
                fun(free: Array.new(255) { nil_ })]
    assert(check(accepted.map { |bytes| term(bytes) }).all? { |answer| answer.start_with?('accepted ') })
    assert_refusals(
      fun(free: Array.new(256) { nil_ }) => 'fun', fun(module_name: small(1)) => 'fun', fun(old_index: big59) => 'fun',
      fun(old_uniq: atom('u')) => 'fun', fun(creator: atom('p')) => 'fun', fun(old_index: tuple) => 'fun',
      export(atom('m'), atom('f'), int(256)) => 'fun', export(atom('m'), atom('f'), int(-1)) => 'fun',
      export(atom('m'), atom('f'), atom('a')) => 'fun', export(small(1)) => 'fun',
      record([atom('f'), atom('f')], [small(1), small(2)]) => 'record',
      record([atom('f')], [small(1)], module_name: small(1)) => 'record',
      record([atom('f'), tuple], [small(1), small(2)]) => 'record'
    )
  end

  def test_containers_too_long_for_the_input_are_truncated_before_their_words_count
    assert_equal ['malformed truncated 1'] * 4,
                 check([[108, 0xffff_ffff, 106].pack('CNC'), [105, 0xff_ffff, 106].pack('CNC'),
                        [116, 10, 97, 1, 97].pack('CNC*'), [67, 65_535, 0].pack('CNC')].map { |bytes| term(bytes) })
  end

  # Pairs of keys equal under =:=, in different encodings.
  EQUAL_KEYS = [
    [EtfWire.small(1), EtfWire.int(1)], [EtfWire.small(1), EtfWire.small_big(0, [1])], [EtfWire.int(1), EtfWire.large_big(0, [1, 0, 0])],
    [EtfWire.small(0), EtfWire.small_big(1, [0, 0])], [EtfWire.int(-5), EtfWire.small_big(9, [5])],
    [EtfWire.small_big(0, [1] * 9), EtfWire.large_big(0, [1] * 9 + [0])], [EtfWire.atom('a'), EtfWire.long_atom('a')],
    [EtfWire.string('ab'), EtfWire.list([EtfWire.small(97), EtfWire.small(98)])],
    [EtfWire.string('ab'), EtfWire.list([EtfWire.small(97)], EtfWire.string('b'))],
    [EtfWire.list([EtfWire.small(97), EtfWire.small(98)]), EtfWire.list([EtfWire.small(97)], EtfWire.list([EtfWire.small(98)]))],
    [EtfWire.list([EtfWire.int(97)]), EtfWire.list([], EtfWire.list([EtfWire.small(97)], EtfWire.string('')))],
    [EtfWire.nil_, EtfWire.string('')], [EtfWire.nil_, EtfWire.list([])], [EtfWire.atom('t'), EtfWire.list([], EtfWire.atom('t'))],
    [EtfWire.list([EtfWire.small(1)], EtfWire.atom('t')), EtfWire.list([EtfWire.small(1)], EtfWire.list([], EtfWire.atom('t')))],
    [EtfWire.tuple(EtfWire.small(1)), EtfWire.list([], EtfWire.tuple(EtfWire.int(1)))],
    [EtfWire.binary("\x01\x02"), EtfWire.bits("\x01\x02", 8)], [EtfWire.bits("\x80", 1), EtfWire.bits("\xff", 1)],
    [EtfWire.tuple(EtfWire.small(1)), EtfWire.large_tuple(EtfWire.int(1))],
    [EtfWire.map([EtfWire.atom('a'), EtfWire.small(1)], [EtfWire.atom('b'), EtfWire.small(2)]),
     EtfWire.map([EtfWire.atom('b'), EtfWire.int(2)], [EtfWire.atom('a'), EtfWire.small(1)])],
    [EtfWire.tuple(EtfWire.map([EtfWire.small(1), EtfWire.map([EtfWire.atom('x'), EtfWire.nil_], [EtfWire.atom('y'), EtfWire.nil_])])),
     EtfWire.tuple(EtfWire.map([EtfWire.int(1), EtfWire.map([EtfWire.atom('y'), EtfWire.string('')], [EtfWire.atom('x'), EtfWire.nil_])]))],
    [EtfWire.fun, EtfWire.fun(old_index: EtfWire.small(9), old_uniq: EtfWire.int(-3), creator: EtfWire.pid('other@erxos'))],
    [EtfWire.fun(free: [EtfWire.small(1)]), EtfWire.fun(free: [EtfWire.int(1)])],
    [EtfWire.export, EtfWire.export(EtfWire.long_atom('m'), EtfWire.atom('f'), EtfWire.int(1))],
    [EtfWire.pid('web@erxos'), EtfWire.pid('web@erxos')], [EtfWire.ref('web@erxos'), EtfWire.ref('web@erxos')],
    [EtfWire.record([EtfWire.atom('a')], [EtfWire.small(1)]), EtfWire.record([EtfWire.long_atom('a')], [EtfWire.int(1)])]
  ].freeze

  # Pairs of keys that look alike and are not equal under =:=.
  DIFFERENT_KEYS = [
    [EtfWire.small(1), EtfWire.float(1.0)], [EtfWire.float(0.0), EtfWire.float(-0.0)], [EtfWire.binary("\x01"), EtfWire.bits("\x01", 7)],
    [EtfWire.bits("\x80", 1), EtfWire.bits("\x80", 2)], [EtfWire.atom('a'), EtfWire.binary('a')], [EtfWire.atom('a'), EtfWire.string('a')],
    [EtfWire.binary('a'), EtfWire.string('a')], [EtfWire.tuple(EtfWire.small(1)), EtfWire.list([EtfWire.small(1)])],
    [EtfWire.tuple, EtfWire.map], [EtfWire.nil_, EtfWire.tuple], [EtfWire.list([EtfWire.small(1)]), EtfWire.list([EtfWire.small(1)], EtfWire.small(1))],
    [EtfWire.list([EtfWire.small(1)], EtfWire.list([EtfWire.small(2)], EtfWire.atom('t'))),
     EtfWire.list([EtfWire.small(1), EtfWire.small(2)])],
    [EtfWire.record([EtfWire.atom('a'), EtfWire.atom('b')], [EtfWire.small(1), EtfWire.small(2)]),
     EtfWire.record([EtfWire.atom('b'), EtfWire.atom('a')], [EtfWire.small(2), EtfWire.small(1)])],
    [EtfWire.record([], []), EtfWire.record([], [], flags: 0)], [EtfWire.fun, EtfWire.fun(uniq: "\x02" * 16)],
    [EtfWire.fun, EtfWire.fun(index: 1)], [EtfWire.fun, EtfWire.fun(arity: 1)], [EtfWire.fun, EtfWire.fun(module_name: EtfWire.atom('n'))],
    [EtfWire.fun(free: [EtfWire.small(1)]), EtfWire.fun(free: [EtfWire.small(2)])],
    [EtfWire.pid('web@erxos'), EtfWire.pid('web@erxos', 1, 0, 8)], [EtfWire.pid('web@erxos'), EtfWire.pid('web2@erxos')],
    [EtfWire.ref('web@erxos'), EtfWire.ref('web@erxos', 7, [1, 2, 3, 5])], [EtfWire.export, EtfWire.export(EtfWire.atom('m'),
                                                                                              EtfWire.atom('f'), EtfWire.small(2))],
    [EtfWire.map([EtfWire.small(1), EtfWire.small(2)]), EtfWire.map([EtfWire.small(2), EtfWire.small(1)])],
    [EtfWire.small_big(0, [1] * 9), EtfWire.small_big(1, [1] * 9)]
  ].freeze

  def test_map_keys_equal_under_exact_equality_are_refused_whatever_their_encoding
    pairs = EQUAL_KEYS.map { |one, other| term(map([one, small(1)], [other, small(2)])) }
    assert_equal(EQUAL_KEYS.each_index.map { |index| [index, 'malformed map_key'] },
                 check(pairs).each_with_index.map { |answer, index| [index, answer.split[0, 2].join(' ')] })
    # The funnel's structural pass, without accept, does not look.
    assert(check(pairs.map { |line| line.sub(/\Ad 1/, 'd 0') }).all? { |answer| answer.start_with?('accepted ') })
    # Nested anywhere, inside a key or not, and past 32 keys.
    nested = EQUAL_KEYS.map do |one, other|
      term(tuple(map([tuple(map([one, nil_], [other, nil_])), nil_])))
    end
    assert(check(nested).all? { |answer| answer.start_with?('malformed map_key ') })
    large = Array.new(40) { |key| [int(key), nil_] }
    assert_equal ['accepted 152', 'malformed map_key'],
                 check([term(map(*large)), term(map(*large, [small_big(0, [39]), nil_]))]).map { |answer| answer.split[0, 2].join(' ') }
  end

  def test_keys_that_only_look_alike_are_accepted
    pairs = DIFFERENT_KEYS.map { |one, other| term(map([one, small(1)], [other, small(2)])) }
    check(pairs).each_with_index { |answer, index| assert answer.start_with?('accepted '), "#{index}: #{answer}" }
  end

  def test_depth_counts_frames_and_a_last_element_frees_its_frame
    left = ->(depth) { depth.times.reduce(atom('x')) { |inner, _| tuple(inner, atom('a')) } }
    right = ->(depth) { depth.times.reduce(atom('x')) { |inner, _| tuple(atom('a'), inner) } }
    tails = ->(depth) { depth.times.reduce(nil_) { |inner, _| list([small(1)], inner.start_with?("\x6a") ? inner : tuple(inner)) } }
    answers = check([term(left.call(64)), term(left.call(65)), term(right.call(10_000), depth: 2),
                     term(right.call(10_000), accept: 0, depth: 1), term(tails.call(5000), depth: 2),
                     term(map([atom('k'), right.call(10_000)]), depth: 2), term(map([right.call(65), nil_])),
                     term(map([right.call(65), nil_]), accept: 0), term(atom('x'), depth: 0), term(tuple, depth: 0),
                     term(tuple(nil_), depth: 0)])
    # Inside a map key every container keeps its frame, with accept or not.
    assert_equal ['accepted', 'over depth', 'accepted', 'accepted', 'accepted', 'accepted', 'over depth', 'over depth',
                  'accepted', 'accepted', 'over depth'], answers.map { |answer| verdict(answer) }
  end

  def test_the_word_limit_holds_at_its_bound
    answers = check([term(tuple(small(1), small(2), small(3)), words: 4), term(tuple(small(1), small(2), small(3)), words: 3),
                     term(binary('a' * 65), words: 8), term(binary('a' * 65), words: 7)])
    assert_equal ['accepted 4', 'over words', 'accepted 8', 'over words'], answers.map { |answer| answer.split[0, 2].join(' ') }
  end

  def test_scratch_too_small_is_over_a_limit_and_never_overrun
    # Two frames take 112 bytes; the inner map, a key, keeps 2 pairs of 32
    # bytes until it ends, and only then the outer map its key's 16. malloc
    # aligns the scratch, so the check pads nothing.
    keyed = map([map([small(1), nil_], [small(2), nil_]), nil_])
    answers = check(["scratch 0 #{term(nil_, depth: 0)}", "scratch 0 #{term(tuple(nil_), depth: 1)}",
                     "scratch #{112 + 63} #{term(keyed, depth: 2)}", "scratch #{112 + 64} #{term(keyed, depth: 2)}"])
    assert_equal ['accepted', 'over scratch', 'over scratch', 'accepted'], answers.map { |answer| verdict(answer) }
  end

  def test_the_writer_refuses_what_no_term_can_hold
    assert_equal ['writer 14'], check(['writer'])
  end

  private

  def term(bytes, grammar: 'd', accept: 1, depth: 64, words: 1_000_000) = "#{grammar} #{accept} #{depth} #{words} #{hex("\x83".b + bytes.b)}"
  def raw(bytes) = "d 1 64 1000000 #{hex(bytes.b)}"
  def hex(bytes) = bytes.unpack1('H*')
  # "accepted", or the refusal and its reason.
  def verdict(answer) = answer.split.first(answer.start_with?('accepted') ? 1 : 2).join(' ')

  def assert_refusals(cases)
    answers = check(cases.keys.map { |bytes| term(bytes) })
    cases.zip(answers).each do |(bytes, reason), answer|
      assert_equal "malformed #{reason}", answer.split[0, 2].join(' '), hex(bytes)[0, 60]
    end
  end

  def check(requests) = @driver.check(requests)
end
