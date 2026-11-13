# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/hostlink_frame'
require_relative '../fixtures/erlang_build'

# The host link's frame layer on both sides (docs/design-live.md, "Host link frames"): the
# Ruby layer, tools/lib/erx/hostlink_frame.rb, against the shared vectors of
# test/fixtures/hostlink_frames.txt and in its own cases; the Erlang layer,
# erx_hostlink_frame and erx_hostlink_stream, against the same vectors under EUnit
# (test/erlang/erx_hostlink_frame_tests.erl); and a cross test in which Ruby frames, Erlang
# deframes and answers, and Ruby deframes the answers. The Erlang side runs on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies) with
# test/erlang/host_bytes/erx_bytes.erl standing in for the CRC BIF.
class HostlinkFrameTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  F = Erx::HostlinkFrame
  VECTORS = File.join(ROOT, 'test/fixtures/hostlink_frames.txt')
  APPLICATIONS = %w[erx erx_hostlink].freeze
  # The stand-in for erx's erx_bytes, whose CRC BIF is a NIF: compiled after the applications, it
  # replaces their erx_bytes.
  BYTES_STAND_IN = 'test/erlang/host_bytes/erx_bytes.erl'
  SESSION = (0..15).to_a.pack('C*').freeze

  def bytes(hex) = hex == '-' ? ''.b : [hex].pack('H*')

  def vectors = File.readlines(VECTORS, chomp: true).reject { |line| line.start_with?('#') }.map(&:split)

  def expected(results)
    return [] if results == 'none'

    results.split(',').map do |item|
      case item.split(':', -1)
      in ['discard', reason] then F::Discard.new(reason.to_sym)
      in ['frame', stream, session, seq, target, body]
        F::Frame.new(stream: stream.to_sym, session: bytes(session), seq: Integer(seq), target: Integer(target),
                     body: bytes(body))
      end
    end
  end

  def test_shared_vectors
    vectors.each do |kind, name, *rest|
      case [kind, *rest]
      in ['cobs', decoded, encoded]
        assert_equal bytes(encoded), F.cobs_encode(bytes(decoded)), name
        assert_equal bytes(decoded), F.cobs_decode(bytes(encoded)), name
      in ['cobs_bad', encoded] then assert_nil F.cobs_decode(bytes(encoded)), name
      in ['crc', data, crc] then assert_equal Integer(crc, 16), F.crc32c(bytes(data)), name
      in ['feed', side, results, hex] then check_feed(name, side.to_sym, expected(results), bytes(hex))
      end
    end
  end

  def check_feed(name, side, results, wire)
    assert_equal results, F::Deframer.new(side).feed(wire), name
    deframer = F::Deframer.new(side)
    assert_equal results, wire.each_char.flat_map { |byte| deframer.feed(byte) }, "#{name} byte by byte"
    assert_equal wire, F.encode(results.first), name if results.size == 1 && results.first.is_a?(F::Frame) &&
                                                        !wire.start_with?("\0")
  end

  def test_deframer_counts_discards
    deframer = F::Deframer.new(:target)
    deframer.feed("\x05\x11\x22\0\x05\x11\0\x01\0".b)
    assert_equal({ cobs: 2, short: 1 }, deframer.counts)
  end

  def test_encode_refuses_a_long_body
    assert_raises(F::EncodeError) do
      F.encode(F::Frame.new(stream: :files, session: SESSION, seq: 0, target: 0, body: "\x01" * (F::BODY_MAX + 1)))
    end
  end

  def frames(wire) = wire.flat_map { |bytes| F::Deframer.new(:host).feed(bytes) }

  def receiver
    F::Receiver.new.tap { |receiver| receiver.session = SESSION }
  end

  def test_reassembles_a_reply_of_many_pieces
    payload = (0...40_000).map { |index| index % 256 }.pack('C*')
    pieces = frames(F::Sender.new(SESSION).message(:reply, payload, id: 5, target: 2))
    assert_equal 5, pieces.size
    receiver = receiver()
    results = pieces.map { |frame| receiver.accept(frame) }
    assert_equal [:pending] * 4, results.first(4)
    assert_equal F::Message.new(kind: :reply, id: 5, target: 2, session: SESSION, payload: payload), results.last
    assert_equal 0, receiver.held
  end

  def test_gap_refusal_and_session_filter
    sender = F::Sender.new(SESSION)
    first, _lost = frames(sender.message(:reply, 'a' * 9000, id: 1, target: 0))
    after = frames(sender.message(:reply, 'b', id: 2, target: 0)).first
    receiver = receiver()
    assert_equal :pending, receiver.accept(first)
    assert_equal 9000, receiver.held
    assert_equal 'b', receiver.accept(after).payload
    assert_equal({ gap: 1 }, receiver.counts)

    big = frames(F::Sender.new(SESSION).message(:reply, 'c' * 9000, id: 3, target: 0))
    refusing = receiver()
    assert_equal [F::Refused, :skipped], big.map { |frame| refusing.accept(frame, room: 100) }
                                            .map { |result| result.is_a?(Symbol) ? result : result.class }

    hello = frames(F::Sender.new(F::SESSION_ZERO).message(:call, 'n' * 16, id: 1, target: 0)).first
    assert_equal 'n' * 16, receiver.accept(hello).message.payload
    assert_equal 'n' * 16, receiver.accept(hello, room: 0).message.payload, 'a hello is not held to room'
    stray = frames([F::Sender.new("\x09".b * 16).frame(:terminal, 'x')]).first
    assert_equal F::Discard.new(:session), receiver.accept(stray)
  end

  # A frame whose seq is below the one expected is a repeat: it is discarded and leaves
  # the message under way alone.
  def test_a_repeated_frame_is_discarded
    first, last = frames(F::Sender.new(SESSION).message(:reply, 'r' * 9000, id: 1, target: 0))
    receiver = receiver()
    assert_equal [:pending, F::Discard.new(:seq)], [first, first].map { |frame| receiver.accept(frame) }
    assert_equal 'r' * 9000, receiver.accept(last).payload
    assert_equal({ seq: 1 }, receiver.counts)
  end

  # Every piece but the last is a whole PIECE_MAX bytes: an empty or short piece with MORE
  # set is refused, and so is a last piece that runs past the total, so a message has as
  # many pieces as its total says.
  def test_short_pieces_with_more_are_refused
    header = ->(more, total) { [1, more, 0, total, 1].pack('CCvVQ<') }
    empty = F::Frame.new(stream: :control, session: SESSION, seq: 0, target: 0, body: header.call(1, 2))
    receiver = receiver()
    assert_equal [F::Discard.new(:pieces)] * 2, [empty, empty.with(seq: 1)].map { |frame| receiver.accept(frame) }
    assert_equal 0, receiver.held
    short = empty.with(body: header.call(1, 9000) + ('s' * 100))
    assert_equal F::Discard.new(:pieces), receiver().accept(short)
    full = empty.with(body: header.call(1, 9000) + ('f' * F::PIECE_MAX))
    long_last = empty.with(seq: 1, body: header.call(0, 9000) + ('l' * (9000 - F::PIECE_MAX + 1)))
    receiver = receiver()
    assert_equal [:pending, F::Discard.new(:pieces)], [full, long_last].map { |frame| receiver.accept(frame) }
    assert_equal 0, receiver.held
  end

  def test_sender_stops_before_wrapping
    sender = F::Sender.new(SESSION)
    sender.instance_variable_set(:@next, F::U32_MAX)
    assert_equal F::U32_MAX, frames([sender.frame(:terminal, '')]).first.seq
    assert_raises(F::Exhausted) { sender.frame(:terminal, '') }
  end

  def test_credit
    credit = F::Credit.new
    credit.spend(F::CREDIT_INITIAL - 10)
    refute credit.allows?(11)
    assert_raises(F::NoCredit) { credit.spend(11) }
    grant = ->(total) { credit.grant(F::Frame.new(stream: :credit, session: SESSION, seq: 0, target: total, body: ''.b)) }
    grant.call(4096)
    assert_equal 4106, credit.available
    grant.call(12_288) # a grant of 8,192 between them was lost
    assert_equal 12_298, credit.available
    grant.call(12_288)
    assert_equal 12_298, credit.available
    refute grant.call(4096), 'a stale grant would add almost 4 GiB'
    refute grant.call(F::CREDIT_INITIAL), 'a grant of more than was sent'
    assert_equal 12_298, credit.available
  end

  def test_erlang_layer_passes_the_vectors_under_eunit
    Dir.mktmpdir('erx-hostlink-frame-test') do |work|
      compile(work, 'test/erlang/erx_hostlink_frame_tests.erl')
      output, status = erl(work, '-eval', 'halt(case eunit:test(erx_hostlink_frame_tests) of ok -> 0; _ -> 1 end).')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # Ruby frames a hello and a session's messages and frames, with damaged bytes between
  # them; Erlang deframes them in random pieces and answers; Ruby deframes the answers.
  def test_cross_ruby_frames_erlang_deframes_and_back
    calls = [0, 1, F::PIECE_MAX, F::PIECE_MAX + 1, 40_000].map { |size| (0...size).map { rand(256) }.pack('C*') }
    hello = F::Sender.new(F::SESSION_ZERO).message(:cast, SESSION, id: 0, target: 0).join
    sender = F::Sender.new(SESSION)
    wire = calls.each_with_index.map do |payload, index|
      sender.message(:call, payload, id: index + 1, target: 7).join + "\x05\x11\0".b +
        sender.frame(:terminal, "key #{index}") + sender.frame(:files, "\0\x019p")
    end
    input = hello + wire.join + sender.message(:cast, 'bye', id: 0, target: 0).join

    answers = Dir.mktmpdir('erx-hostlink-cross') do |work|
      compile(work, 'test/erlang/erx_hostlink_cross.erl')
      File.binwrite(File.join(work, 'in'), input)
      output, status = erl(work, '-run', 'erx_hostlink_cross', 'run', 'in', 'out', '7', '-s', 'init', 'stop')
      assert status.success?, output
      assert_match(/cross: frame #\{cobs => 5\} stream #\{\}/, output)
      File.binread(File.join(work, 'out'))
    end

    receiver = receiver()
    taken = F::Deframer.new(:host).feed(answers).map { |frame| receiver.accept(frame) }
    assert_empty receiver.counts
    replies = taken.grep(F::Message)
    assert_equal calls, replies.select { |message| message.kind == :reply }.map(&:payload)
    assert_equal (1..calls.size).to_a, replies.select { |message| message.kind == :reply }.map(&:id)
    assert_equal ['bye'], replies.select { |message| message.kind == :cast }.map(&:payload)
    echoed = taken.grep(F::Taken).map(&:frame)
    assert_equal calls.size.times.flat_map { |index| ["key #{index}", "\0\x019p"] },
                 echoed.reject { |frame| frame.stream == :credit }.map(&:body)
    # The last grant, after the flush, is all the target consumed after the hello's piece.
    granted = echoed.select { |frame| frame.stream == :credit }.last.target
    assert_operator granted, :<=, input.bytesize - hello.bytesize + 300
    assert_operator granted, :>, input.bytesize - hello.bytesize - 300
  end

  private

  def compile(work, test) = ErlangBuild.compile(work, applications: APPLICATIONS, tests: [BYTES_STAND_IN, test])

  def erl(work, *arguments)
    Open3.capture2e({ 'ERX_HOSTLINK_VECTORS' => VECTORS }, 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'),
                    '-noshell', '-pa', work, *arguments, chdir: work, stdin_data: '')
  end
end
