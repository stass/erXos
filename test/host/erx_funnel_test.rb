# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/funnel_wire'

# Judges liberx/erx_funnel.c through its host driver,
# test/fixtures/funnel_driver.c: the frame header's lengths; one control
# term of every operation accepted, with what it names, and each refused
# with another arity, an element of another kind or range, a payload it
# does not take, or an option list of another shape; the control term held
# to erx_etf's system grammar, semantic stage and ERX_FUNNEL_CTL_DEPTH; and
# the payload's pass held to the receiver's grammar and limits. Agreement
# with ERTS is test/integration/erx_funnel_oracle_test.rb's.
class ErxFunnelTest < Minitest::Test
  include FunnelWire

  # The ABI's limits, read from abi/erx_abi.txt.
  LIMITS = File.foreach(File.expand_path('../../abi/erx_abi.txt', __dir__)).filter_map do |line|
    line.match(/\Alimit (\w+) u32 (\d+)$/)&.captures
  end.to_h.transform_values { |value| Integer(value, 10) }.freeze
  CTL_MAX = LIMITS.fetch('ctl_max')
  FRAME_MAX = LIMITS.fetch('frame_max')

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-funnel-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported erx_funnel test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = FunnelDriver.new(root: @root, runner: @runner, directory: @directory, flags: flags)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def header(frame_len, ctl_len, payload_len) = "header #{frame_len} #{[ctl_len, payload_len].pack('VV').unpack1('H*')}"
  def control(bytes, payload_len = 0) = "control #{payload_len} #{bytes.unpack1('H*')}"
  def payload(bytes, system: 0, depth: 8, words: 1000) = "payload #{system} #{depth} #{words} #{bytes.unpack1('H*')}"
  def answers(cases) = cases.keys.zip(@driver.check(cases.values.map(&:first)))

  def test_the_header_adds_up_to_the_frame
    cases = {
      'control only' => [header(8 + 2, 2, 0), 'ok 2 0'], 'both terms' => [header(8 + 40 + 9, 40, 9), 'ok 40 9'],
      'largest control' => [header(8 + CTL_MAX, CTL_MAX, 0), "ok #{CTL_MAX} 0"],
      'largest frame' => [header(FRAME_MAX, 2, FRAME_MAX - 10), "ok 2 #{FRAME_MAX - 10}"],
      'control too short' => [header(8 + 1, 1, 0), 'ctl_len'],
      'control too long' => [header(8 + CTL_MAX + 1, CTL_MAX + 1, 0), 'ctl_len'],
      'frame shorter than its terms' => [header(8 + 10, 4, 7), 'header'],
      'frame longer than its terms' => [header(8 + 12, 4, 7), 'header'],
      'lengths that wrap 32 bits' => [header(16, CTL_MAX, 0x1_0000_0000 - CTL_MAX), 'header'],
      'frame shorter than a header' => [header(7, 2, 0), 'header'],
      'frame past ERX_FRAME_MAX' => [header(FRAME_MAX + 1, 2, FRAME_MAX - 9), 'header']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer, name }
  end

  def test_every_operation_is_accepted_with_what_it_names
    ops = every_operation
    answers = @driver.check(ops.values.map { |bytes, payload| control(bytes, payload ? 9 : 0) })
    ops.keys.zip(answers).each do |name, answer|
      number = ops.fetch(name).first.getbyte(4)
      assert_match(/\Aok \{#{number},/, answer, name)
    end
    pid = ->(node, id, creation) { "{pid,<<#{node.bytes.join(',')}>>,#{id},0,#{creation}}" }
    ref = "{ref,<<#{'system@erxos'.bytes.join(',')}>>,1,[1,2,3,4]}"
    from = pid.call('web@erxos', 5, 3)
    to = pid.call('system@erxos', 9, 1)
    named = ops.keys.zip(answers).to_h
    assert_equal "ok {19,#{from},#{to},#{ref}}", named.fetch('MONITOR_P')
    assert_equal "ok {29,#{ref},#{from},#{to},{<<109>>,<<102>>,2},options}", named.fetch('SPAWN_REQUEST')
    assert_equal "ok {31,#{ref},#{to},1,<<98,97,100,97,114,103>>}", named.fetch('SPAWN_REPLY error')
    assert_equal "ok {36,70000,#{from},#{to}}", named.fetch('UNLINK_ID_ACK')
  end

  def test_a_payload_comes_exactly_with_the_operations_that_take_one
    cases = every_operation.to_h do |name, (bytes, payload)|
      [name, [control(bytes, payload ? 0 : 9), 'payload term_ok']]
    end
    answers(cases).each { |name, answer| assert_equal 'payload ok', answer, name }
  end

  def test_another_arity_or_an_operation_outside_the_grammar_is_refused
    cases = {
      'LINK with 2' => [control(ctl(op(1), from)), 'arity ok'],
      'LINK with 4' => [control(ctl(op(1), from, to, to)), 'arity ok'],
      'SPAWN_REQUEST with 7' => [control(ctl(op(29), reference, from, to, mfa, nil_, nil_), 9), 'arity ok'],
      'SEND' => [control(ctl(op(2), atom(''), to), 9), 'op ok'], 'EXIT' => [control(ctl(op(3), from, to, nil_)), 'op ok'],
      'REG_SEND' => [control(ctl(op(6), from, atom(''), atom('n')), 9), 'op ok'],
      'SEND_SENDER_TT' => [control(ctl(op(23), from, to, nil_), 9), 'op ok'],
      'ALTACT_SIG_SEND' => [control(ctl(op(37), small(0), from, to), 9), 'op ok'],
      'operation -1' => [control(ctl(int(-1), from, to)), 'op ok'],
      'operation as a big' => [control(ctl(small_big(0, [22, 0, 0, 0, 0, 0, 0, 0, 1]), from, to), 9), 'op ok'],
      'operation as an atom' => [control(ctl(atom('link'), from, to)), 'op ok'],
      'empty tuple' => [control("\x83".b + tuple), 'op ok'],
      'a list' => [control("\x83".b + list([op(1), from, to])), 'op ok']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer, name }
  end

  def test_elements_of_another_kind_or_range_are_refused
    max_id = small_big(0, [0xff] * 8)
    cases = {
      'atom for FromPid' => [control(ctl(op(1), atom('a'), to)), 'field'],
      'name for ToProc' => [control(ctl(op(19), from, atom('name'), reference)), 'field'],
      'name for FromProc' => [control(ctl(op(28), atom('name'), to, reference), 9), 'field'],
      'pid for Ref' => [control(ctl(op(20), from, to, from)), 'field'],
      'pid for Alias' => [control(ctl(op(33), from, to), 9), 'field'],
      'unlink id 0' => [control(ctl(op(35), small(0), from, to)), 'field'],
      'unlink id -1' => [control(ctl(op(35), int(-1), from, to)), 'field'],
      'unlink id 2^64' => [control(ctl(op(35), small_big(0, [0] * 8 + [1]), from, to)), 'field'],
      'unlink id 2^64 - 1' => [control(ctl(op(35), max_id, from, to)), 'ok'],
      'unlink id with high zeros' => [control(ctl(op(36), small_big(0, [0xff] * 8 + [0, 0]), from, to)), 'ok'],
      'unlink id negative big' => [control(ctl(op(35), small_big(1, [0xff] * 8), from, to)), 'field'],
      'MFA of 2' => [control(ctl(op(29), reference, from, to, tuple(atom('m'), atom('f')), nil_), 9), 'field'],
      'arity 2^59' => [control(ctl(op(29), reference, from, to, tuple(atom('m'), atom('f'), small_big(0, [0] * 7 + [8])),
                                nil_), 9), 'field'],
      'arity 2^59 - 1' => [control(ctl(op(29), reference, from, to,
                                       tuple(atom('m'), atom('f'), small_big(0, [0xff] * 7 + [7])), nil_), 9), 'ok'],
      'arity -2^59' => [control(ctl(op(29), reference, from, to, tuple(atom('m'), atom('f'),
                                                                       small_big(1, [0] * 7 + [8])), nil_), 9), 'ok'],
      'module as a binary' => [control(ctl(op(29), reference, from, to, tuple(binary('m'), atom('f'), small(0)), nil_), 9),
                               'field'],
      'flags 2^27' => [control(ctl(op(31), reference, to, int(1 << 27), from)), 'field'],
      'flags 2^27 - 1' => [control(ctl(op(31), reference, to, int((1 << 27) - 1), from)), 'ok'],
      'flags -1' => [control(ctl(op(31), reference, to, int(-1), from)), 'field'],
      'result an integer' => [control(ctl(op(31), reference, to, small(0), small(1))), 'field'],
      'request id a pid' => [control(ctl(op(29), from, from, to, mfa, nil_), 9), 'field']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer.split.first, name }
  end

  def test_spawn_options_are_a_proper_list_of_atoms_and_pairs
    request = ->(opts) { control(ctl(op(29), reference, from, to, mfa, opts), 9) }
    cases = {
      'none' => [request.call(nil_), 'ok'], 'empty string' => [request.call(string('')), 'ok'],
      'every shape' => [request.call(options), 'ok'],
      'split across tails' => [request.call(list([atom('link')], list([atom('monitor')], string('')))), 'ok'],
      'big value' => [request.call(list([tuple(atom('min_heap_size'), small_big(0, [1] * 9))])), 'ok'],
      'improper' => [request.call(list([atom('link')], atom('tail'))), 'option'],
      'a string' => [request.call(string('ab')), 'option'], 'an atom' => [request.call(atom('link')), 'option'],
      'pid option' => [request.call(list([from])), 'option'],
      'pid value' => [request.call(list([tuple(atom('reply_tag'), from)])), 'option'],
      'reference value' => [request.call(list([tuple(atom('reply_tag'), reference)])), 'option'],
      'tuple value' => [request.call(list([tuple(atom('a'), tuple)])), 'option'],
      'integer key' => [request.call(list([tuple(small(1), atom('a'))])), 'option'],
      'triple' => [request.call(list([tuple(atom('a'), atom('b'), atom('c'))])), 'option'],
      'map with a pid' => [request.call(list([tuple(atom('max_heap_size'), map([atom('size'), from]))])), 'option'],
      'map with a tuple key' => [request.call(list([tuple(atom('m'), map([tuple, small(1)]))])), 'option']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer.split.first, name }
  end

  def test_the_control_term_is_held_to_erx_etf_system_grammar_and_depth
    bytes, = every_operation.fetch('LINK')
    deep = list([list([list([atom('a')])])])
    cases = {
      'pid off the host' => [control(ctl(op(1), pid('web@elsewhere'), to)), 'term node'],
      'fun in a control term' => [control(ctl(op(1), from, to, fun)), 'term tag'],
      'export in a control term' => [control(ctl(op(1), from, export)), 'term tag'],
      'repeated map key' => [control(ctl(op(29), reference, from, to, mfa,
                                         list([tuple(atom('h'), map([atom('size'), small(1)],
                                                                    [atom('size'), small_big(0, [1])]))])), 9),
                             'term map_key'],
      'nested past the depth' => [control(ctl(op(29), reference, from, to, mfa, deep), 9), 'term depth'],
      'reference of 3 words' => [control(ctl(op(20), from, to, ref('system@erxos', 1, [1, 2, 3]))), 'term ref_len'],
      'trailing byte' => [control("#{bytes}\x6a"), 'term trailing'],
      'cut short' => [control(bytes.byteslice(0, bytes.bytesize - 1)), 'term truncated'],
      'no version byte' => [control(bytes.byteslice(1..)), 'term version'],
      'past ERX_CTL_MAX' => [control(ctl(op(29), reference, from, to, mfa, list([atom('a' * 200)] * 21)), 9),
                             'ctl_len ok']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer, name }
  end

  def test_the_payload_pass_keeps_the_receiver_grammar_and_limits
    ten_words = "\x83".b + tuple(*Array.new(9) { nil_ })
    cases = {
      'domain takes a fun' => [payload("\x83".b + fun), 'accepted 6'],
      'system refuses a fun' => [payload("\x83".b + fun, system: 1), 'malformed tag'],
      'repeated map key, which the receiver judges' => [payload("\x83".b + map([small(1), nil_], [int(1), nil_])),
                                                        'accepted 8'],
      'at the word limit' => [payload(ten_words, words: 10), 'accepted 10'],
      'past the word limit' => [payload(ten_words, words: 9), 'over words'],
      'past the depth' => [payload("\x83".b + list([list([list([nil_])])]), depth: 2), 'over depth'],
      'within the depth' => [payload("\x83".b + list([list([nil_])]), depth: 2), 'accepted 4'],
      'off the host' => [payload("\x83".b + pid('web@elsewhere')), 'malformed node'],
      'trailing byte' => [payload("#{ten_words}\x6a"), 'malformed trailing']
    }
    answers(cases).each { |name, answer| assert_equal cases.fetch(name).last, answer, name }
  end
end
