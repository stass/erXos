# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'socket'
require 'tmpdir'
require 'timeout'
require_relative '../../tools/lib/erx/etf'
require_relative '../../tools/lib/erx/files_relay'
require_relative '../../tools/lib/erx/ninep_client'

# FilesRelay, `tools/erx files`, against a scripted target: the host link's target side
# built from HostlinkFrame's own layers, which answers hellos and hands each files frame's
# body to a block that returns the 9P reply. A NinepClient connects to the relay's socket
# as any 9P2000.L client of the host would.
class FilesRelayTest < Minitest::Test
  Frame = Erx::HostlinkFrame
  HELLO = Erx::Etf::Atom.new(name: 'hello')

  # The target's end of a host link: hello replies and files frames, nothing else.
  class FakeTarget
    attr_reader :received, :sessions

    def initialize(io, &answer)
      @io = io
      @answer = answer
      @deframer = Frame::Deframer.new(:target)
      @receiver = Frame::Receiver.new
      @received = Queue.new
      @sessions = 0
    end

    def run
      loop do
        bytes = @io.readpartial(65_536)
        @deframer.feed(bytes).each { |frame| take(frame) if frame.is_a?(Frame::Frame) }
      end
    rescue EOFError, IOError
      nil
    end

    private

    def take(frame)
      case @receiver.accept(frame)
      in Frame::Hello[message]
        hello(Erx::Etf.decode(message.payload).elements[1])
      in Frame::Taken[taken] if taken.stream == :files
        @received << taken.body
        reply = @answer.call(taken.body)
        @io.write(@sender.frame(:files, reply)) if reply
      else
        nil
      end
    end

    def hello(nonce)
      session = Random.bytes(16)
      reply = Erx::Etf::Tuple.new(elements: [HELLO, nonce, session, 'ab'.b, Erx::Etf::Map.new(pairs: [])])
      @io.write(Frame::Sender.new(Frame::SESSION_ZERO).message(:reply, Erx::Etf.encode(reply), id: 1, target: 0).join)
      @receiver.session = session
      @sender = Frame::Sender.new(session)
      @sessions += 1
    end
  end

  # Rversion for a Tversion, Rlerror EIO (5) for anything else, both under the request's tag.
  ANSWER = lambda do |body|
    tag = body.byteslice(5, 2).unpack1('v')
    if body.getbyte(4) == Erx::NinepClient::TYPES.fetch(:version)
      payload = [8192].pack('V') + [8].pack('v') + '9P2000.L'
      [7 + payload.bytesize, body.getbyte(4) + 1, tag].pack('VCv') + payload
    else
      [11, Erx::NinepClient::RLERROR, tag, 5].pack('VCvV')
    end
  end

  def test_split_keeps_whole_messages_and_the_rest
    one = [7, 100, 1].pack('VCv')
    two = [9, 102, 2].pack('VCv') + 'xy'
    messages, rest = Erx::FilesRelay.split(one + two + two.byteslice(0, 5))
    assert_equal [one, two], messages
    assert_equal two.byteslice(0, 5), rest
    assert_equal [[], 'abc'], Erx::FilesRelay.split('abc')
  end

  def test_split_refuses_sizes_outside_the_stream
    assert_raises(Erx::FilesRelay::Framing) { Erx::FilesRelay.split([6].pack('V') + 'abc') }
    assert_raises(Erx::FilesRelay::Framing) { Erx::FilesRelay.split([8193].pack('V')) }
    assert_equal 1, Erx::FilesRelay.split([8192].pack('V') + ("\0".b * 8188)).first.size
  end

  def test_the_listening_directory_must_be_the_owners_alone
    Dir.mktmpdir do |directory|
      File.chmod(0o755, directory)
      assert_raises(Erx::Error) { Erx::FilesRelay.check_listen_path(File.join(directory, 'files.sock')) }
      File.chmod(0o700, directory)
      File.write(File.join(directory, 'plain'), 'x')
      assert_raises(Erx::Error) { Erx::FilesRelay.check_listen_path(File.join(directory, 'plain')) }
      assert_nil Erx::FilesRelay.check_listen_path(File.join(directory, 'files.sock'))
    end
  end

  def test_a_client_speaks_9p_through_the_relay
    with_relay(connections: 2) do |listen, target|
      UNIXSocket.open(listen) do |io|
        client = Erx::NinepClient.new(io: io, deadline: 10)
        assert_equal 8192, client.version
        error = assert_raises(Erx::NinepClient::Refused) { client.attach(1, 'data') }
        assert_match(/attach: eio/, error.message)
      end
      assert_equal Erx::NinepClient::TYPES.fetch(:version), target.received.pop.getbyte(4)
      assert_equal Erx::NinepClient::TYPES.fetch(:attach), target.received.pop.getbyte(4)
      # A second client gets a session of its own.
      UNIXSocket.open(listen) { |io| Erx::NinepClient.new(io: io, deadline: 10).version }
      assert_equal 2, target.sessions
    end
  end

  def test_an_oversized_message_ends_the_clients_connection
    with_relay(connections: 1) do |listen, target|
      UNIXSocket.open(listen) do |io|
        io.write([8193, 100, 0].pack('VCv'))
        assert io.wait_readable(10), 'the relay neither answered nor closed the connection'
        assert_nil io.read_nonblock(1, exception: false), 'the relay answered instead of closing'
      end
      assert_predicate target.received, :empty?
    end
  end

  def test_a_credit_timeout_ends_only_the_client
    with_relay(connections: 2, deadline: 1) do |listen, target|
      UNIXSocket.open(listen) do |io|
        # Three of the largest messages outrun the session's 16 KiB of credit, which the
        # target never adds to.
        message = [8192, 100, 0].pack('VCv') + ("\0" * (8192 - 7))
        3.times { io.write(message) }
        assert io.wait_readable(10), 'the relay neither answered nor closed the connection'
        Timeout.timeout(10) { io.read }
      end
      # The relay serves the next client, in a session with credit of its own.
      UNIXSocket.open(listen) { |io| assert_equal 8192, Erx::NinepClient.new(io: io, deadline: 10).version }
      assert_equal 2, target.sessions
    end
  end

  def test_a_short_walk_reply_is_refused
    client_io, server_io = UNIXSocket.pair
    server = Thread.new do
      size = server_io.read(4).unpack1('V')
      tag = server_io.read(size - 4).unpack1('x1v')
      server_io.write([8, Erx::NinepClient::TYPES.fetch(:walk) + 1, tag].pack('VCv') + "\1")
    end
    client = Erx::NinepClient.new(io: client_io, deadline: 5)
    error = assert_raises(Erx::NinepClient::Refused) { client.walk(1, 2, ['f']) }
    assert_match(/walk reply/, error.message)
  ensure
    server&.join(5)
    client_io&.close
    server_io&.close
  end

  private

  # A relay on a socket in a fresh owner-only directory, linked to a FakeTarget over a
  # socket pair, serving connections clients; yields the socket's path and the target.
  # deadline bounds each wait of the relay's host link, for credit among others.
  def with_relay(connections:, deadline: 10)
    Dir.mktmpdir('erx-files') do |directory|
      File.chmod(0o700, directory)
      listen = File.join(directory, 'files.sock')
      host, guest = UNIXSocket.pair
      target = FakeTarget.new(guest, &ANSWER)
      target_thread = Thread.new { target.run }
      lines = Queue.new
      relay = Erx::FilesRelay.new(link: Erx::HostlinkClient.new(io: host, deadline: deadline), listen: listen,
                                  out: ->(line) { lines << line })
      relay_thread = Thread.new { relay.serve(connections: connections) }
      lines.pop
      yield listen, target
      relay_thread.join(10)
    ensure
      host&.close
      guest&.close
      target_thread&.join(5)
    end
  end
end
