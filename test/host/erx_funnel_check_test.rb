# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/funnel_wire'

# Judges erx_funnel_check, liberx/erx_funnel.c's whole judgment of a frame,
# through test/fixtures/funnel_driver.c's check request, on a lane from
# web@erxos (domain 3) to system@erxos (domain 1): the verdict table row by
# row, each operation with and without the right it needs, toward a dead
# target and over a limit; authority decided before limits; the sender and
# target rules, the latter bounding the receiver's own pids to ERTS's
# internal range; the payload's version byte, discard mode and the
# target's request limit; and the export table asked once, about the
# operation's target, or not at all.
class ErxFunnelCheckTest < Minitest::Test
  include FunnelWire

  SEND = 1
  LINK = 2
  EXIT = 4
  SPAWN = 8
  ALL = 0x1f

  # The verdict table of design-domains.md ("Frames" and "The funnel", step
  # 7): the right each operation needs, the name it is asked about, and the
  # action when unauthorised, toward a dead target and over a limit (nil
  # where the operation cannot have that cause).
  Row = Data.define(:right, :asked, :unauthorised, :dead, :over)
  TABLE = {
    'SEND_SENDER' => Row.new(SEND, 'pid:9', 'drop', 'drop', 'drop'),
    'ALIAS_SEND' => Row.new(SEND, 'alias:1', 'drop', 'drop', 'drop'),
    'LINK' => Row.new(LINK, 'pid:9', 'deliver_if_linked', 'answer_noproc', nil),
    'UNLINK_ID' => Row.new(0, '-', nil, 'drop', nil),
    'UNLINK_ID_ACK' => Row.new(0, '-', nil, 'drop', nil),
    'MONITOR_P' => Row.new(SEND, 'pid:9', 'answer_noproc', 'answer_noproc', nil),
    'DEMONITOR_P' => Row.new(0, '-', nil, 'drop', nil),
    'PAYLOAD_MONITOR_P_EXIT' => Row.new(0, '-', nil, 'drop', 'too_large'),
    'PAYLOAD_EXIT' => Row.new(0, '-', nil, 'drop', 'too_large'),
    'PAYLOAD_EXIT2' => Row.new(EXIT, 'pid:9', 'drop', 'drop', 'too_large'),
    'GROUP_LEADER' => Row.new(EXIT, 'pid:9', 'drop', 'drop', nil),
    'SPAWN_REQUEST' => Row.new(SPAWN, 'domain', 'answer_spawn', nil, 'answer_spawn'),
    'SPAWN_REPLY' => Row.new(0, '-', nil, 'drop', nil),
    'SPAWN_REPLY error' => Row.new(0, '-', nil, 'drop', nil)
  }.freeze

  PAYLOAD = "\x83".b + EtfWire.list([EtfWire.atom('hello')])
  # A payload whose second byte is a tag outside the grammar.
  BAD_PAYLOAD = "\x83\x01".b
  WORDS = 1 << 20
  # The operations whose reference is the sender's own, and one such.
  SENDS_REFERENCE = %w[MONITOR_P DEMONITOR_P SPAWN_REQUEST].freeze
  SENDER_REF = EtfWire.ref('web@erxos', 3, [1, 2, 3, 4])

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-funnel-check-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported erx_funnel test sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @driver = FunnelDriver.new(root: @root, runner: @runner, directory: @directory, flags: flags)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def test_every_operation_with_its_right_is_delivered_and_asks_about_its_target
    rows = TABLE.map do |name, row|
      ["#{name} #{row.asked}", check(*frame_of(name), rights: row.right)]
    end
    expected = TABLE.map { |name, row| ["#{name} #{row.asked}", "deliver accepted ok #{row.asked}"] }
    assert_equal expected, rows.map { |label, answer| [label, answer.sub(/ \d+\z/, '')] }
  end

  def test_without_its_right_an_operation_takes_the_unauthorised_column
    TABLE.reject { |_, row| row.right.zero? }.each do |name, row|
      answer = check(*frame_of(name), rights: ALL & ~row.right)
      assert_equal "#{row.unauthorised} unauthorised ok #{row.asked} 0", answer, name
    end
  end

  def test_a_target_of_an_ended_domain_takes_the_dead_column_without_asking
    old = EtfWire.pid('system@erxos', 9, 0, 2)
    old_ref = EtfWire.ref('system@erxos', 2, [1, 2, 3, 4])
    TABLE.reject { |name, _| name == 'SPAWN_REQUEST' }.each do |name, row|
      control, payload = frame_of(name, to: old, receiver_ref: old_ref)
      assert_equal "#{row.dead} dead ok - 0", check(control, payload, rights: ALL), name
    end
  end

  def test_an_authorised_payload_over_a_limit_takes_the_over_column
    TABLE.select { |_, row| row.over }.each do |name, row|
      control, payload = frame_of(name)
      assert_equal "#{row.over} over_limit ok #{row.asked} 0", check(control, payload, rights: ALL, words: 0), name
      held = 8 + control.bytesize + 1
      assert_equal "#{row.over} over_limit ok #{row.asked} 0",
                   check(control, payload, rights: ALL, held: held), "#{name} discarded"
    end
  end

  def test_the_target_request_limit_lowers_only_a_message_word_limit
    control, payload = frame_of('SEND_SENDER')
    assert_equal 'drop over_limit ok pid:9 0', check(control, payload, rights: SEND, request_words: 1)
    assert_equal 'drop over_limit ok alias:1 0', check(*frame_of('ALIAS_SEND'), rights: SEND, request_words: 1)
    assert_match(/\Adeliver accepted ok pid:9 \d+\z/, check(*frame_of('PAYLOAD_EXIT2'), rights: EXIT, request_words: 1))
    assert_match(/\Adeliver accepted ok domain \d+\z/, check(*frame_of('SPAWN_REQUEST'), rights: SPAWN, request_words: 1))
    assert_match(/\Adeliver accepted ok pid:9 \d+\z/, check(control, payload, rights: SEND, request_words: WORDS))
  end

  def test_authority_comes_before_limits_and_the_payload_pass
    control, = frame_of('PAYLOAD_EXIT2')
    assert_equal 'drop unauthorised ok pid:9 0', check(control, BAD_PAYLOAD, rights: SEND)
    assert_equal 'drop unauthorised ok pid:9 0', check(control, PAYLOAD, rights: SEND, words: 0)
    assert_equal 'malformed malformed payload_term pid:9 0', check(control, BAD_PAYLOAD, rights: EXIT)
  end

  def test_the_version_byte_is_judged_before_authority_and_in_discard_mode
    control, = frame_of('SEND_SENDER')
    bad = "\x82".b + PAYLOAD.byteslice(1..)
    assert_equal 'malformed malformed version - 0', check(control, bad, rights: 0)
    assert_equal 'malformed malformed version - 0', check(control, bad, rights: ALL, held: 8 + control.bytesize + 1)
  end

  def test_a_link_without_the_link_right_is_left_to_the_target_process
    control, = frame_of('LINK')
    assert_equal 'deliver_if_linked unauthorised ok pid:9 0', check(control, '', rights: SEND | EXIT)
    assert_equal 'deliver accepted ok pid:9 0', check(control, '', rights: LINK)
  end

  def test_the_sender_rule_holds_every_pid_and_reference_of_the_sender_to_the_lane
    other_id = EtfWire.pid('web@erxos', 5, 0, 4)
    other_node = EtfWire.pid('db@erxos', 5, 0, 3)
    {
      'SEND_SENDER' => ctl(op(22), other_id, to), 'LINK' => ctl(op(1), other_node, to),
      'GROUP_LEADER' => ctl(op(7), other_id, to),
      'MONITOR_P' => ctl(op(19), from, to, reference),
      'DEMONITOR_P' => ctl(op(20), from, to, EtfWire.ref('web@erxos', 4, [1, 2, 3, 4])),
      'SPAWN_REQUEST' => ctl(op(29), reference, from, to, mfa, options),
      'SPAWN_REPLY' => ctl(op(31), reference, to, EtfWire.small(0), other_id),
      'PAYLOAD_MONITOR_P_EXIT' => ctl(op(28), other_node, to, reference)
    }.each do |name, control|
      payload = FunnelWire.every_operation.fetch(name).last ? PAYLOAD : ''
      assert_equal 'malformed malformed sender - 0', check(control, payload, rights: ALL), name
    end
    assert_equal 'deliver accepted ok pid:9 0', check(ctl(op(19), from, to, SENDER_REF), '', rights: ALL)
    # A spawn request's group leader is data, as a pid in a payload is.
    leader = EtfWire.pid('db@erxos', 7, 0, 9)
    assert_match(/\Adeliver accepted ok domain \d+\z/,
                 check(ctl(op(29), SENDER_REF, from, leader, mfa, options), PAYLOAD, rights: SPAWN))
  end

  def test_the_target_rule_names_the_receiver_and_bounds_its_own_pids_and_references
    web_pid = EtfWire.pid('web@erxos', 9, 0, 1)
    assert_equal 'malformed malformed target - 0', check(ctl(op(1), from, web_pid), '', rights: ALL)
    assert_equal 'malformed malformed target - 0',
                 check(ctl(op(33), from, EtfWire.ref('web@erxos', 1, [1, 2, 3, 4])), PAYLOAD, rights: ALL)
    highest = EtfWire.pid('system@erxos', (1 << 28) - 1, 0xffff_ffff, 1)
    assert_equal "deliver accepted ok pid:#{(1 << 28) - 1} 0", check(ctl(op(1), from, highest), '', rights: ALL)
    past = EtfWire.pid('system@erxos', 1 << 28, 0, 1)
    assert_equal 'malformed malformed target - 0', check(ctl(op(1), from, past), '', rights: ALL)
    # Past the range, a pid of an ended domain is only dead, as ERTS reads it.
    assert_equal 'answer_noproc dead ok - 0',
                 check(ctl(op(1), from, EtfWire.pid('system@erxos', 1 << 28, 0, 2)), '', rights: ALL)
    in_range = EtfWire.ref('system@erxos', 1, [(1 << 18) - 1, 2, 3, 4])
    assert_match(/\Adeliver accepted ok alias:#{(1 << 18) - 1} \d+\z/,
                 check(ctl(op(33), from, in_range), PAYLOAD, rights: SEND))
    # Edit 17 makes all four words of the receiver's references random.
    random = EtfWire.ref('system@erxos', 1, [0xffff_ffff, 2, 3, 4])
    assert_match(/\Adeliver accepted ok alias:4294967295 \d+\z/, check(ctl(op(33), from, random), PAYLOAD, rights: SEND))
    assert_equal 'deliver accepted ok - 0', check(ctl(op(31), random, to, EtfWire.small(0), from), '', rights: 0)
    # The receiver's reference alone dead makes the frame dead; a name of
    # another node outweighs a dead one.
    old_ref = EtfWire.ref('system@erxos', 2, [1, 2, 3, 4])
    assert_equal 'drop dead ok - 0', check(ctl(op(28), from, to, old_ref), PAYLOAD, rights: ALL)
    assert_equal 'drop dead ok - 0', check(ctl(op(31), old_ref, to, EtfWire.small(0), from), '', rights: ALL)
    assert_equal 'malformed malformed target - 0',
                 check(ctl(op(28), from, EtfWire.pid('system@erxos', 9, 0, 2),
                           EtfWire.ref('web@erxos', 1, [1, 2, 3, 4])), PAYLOAD, rights: ALL)
  end

  def test_a_frame_the_caller_held_too_little_of_is_refused
    control, = frame_of('SEND_SENDER')
    assert_equal 'malformed malformed held - 0', check(control, PAYLOAD, rights: ALL, held: 8 + control.bytesize)
    assert_equal 'malformed malformed held - 0', check(control, PAYLOAD, rights: ALL, held: 4)
    assert_equal 'malformed malformed header - 0', check_raw("\x01\x00\x00\x00".b, rights: ALL)
  end

  def test_refusals_of_the_grammar_stay_malformed
    assert_equal 'malformed malformed op - 0', check(ctl(op(2), from, to), '', rights: ALL)
    assert_equal 'malformed malformed payload - 0', check(ctl(op(1), from, to), PAYLOAD, rights: ALL)
  end

  private

  # The control term of the named operation, with its target pid and the
  # receiver's reference replaced when given, and its payload.
  # FunnelWire writes every reference at the receiver, so the sender's own
  # are rewritten at the sender.
  def frame_of(name, to: nil, receiver_ref: nil)
    control, with_payload = FunnelWire.every_operation.fetch(name)
    sends_reference = SENDS_REFERENCE.include?(name)
    control = control.b
    control = control.gsub(FunnelWire.reference) { SENDER_REF } if sends_reference
    control = control.gsub(FunnelWire.to) { to } if to
    control = control.gsub(FunnelWire.reference) { receiver_ref } if receiver_ref && !sends_reference
    [control, with_payload ? PAYLOAD : ''.b]
  end

  def check(control, payload, rights:, request_words: 0, held: nil, words: WORDS)
    body = [control.bytesize, payload.bytesize].pack('VV') + control + payload
    check_raw(body, rights: rights, request_words: request_words, held: held, words: words)
  end

  def check_raw(body, rights:, request_words: 0, held: nil, words: WORDS)
    @driver.check(["check #{rights} #{request_words} #{held || '-'} #{words} #{body.unpack1('H*')}"]).first
  end
end
