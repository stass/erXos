# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'securerandom'
require_relative 'error'
require_relative 'etf'
require_relative 'hostlink_frame'
require_relative 'line_escape'

module Erx
  # The host's end of a host link session (docs/design-live.md, "The host link"), over
  # one byte stream: QEMU's UNIX socket for the guest's second UART, or a board's serial
  # line. It opens a session with a hello, sends calls within the target's credit and
  # waits for their replies; HostlinkFrame's layers own the wire, and Etf decodes what
  # the target sends, which is untrusted: a reply reaches the caller as Etf values, and
  # a caller that shows one shows it through the line escape.
  #
  # The client keeps the design's rules for the host: it counts every byte it sends
  # from its hello's first byte and sends only within credit (HostlinkFrame::Credit);
  # between a hello and its reply it sends nothing but repeats of that hello, each only
  # after waiting for the reply. A caller that sends calls without awaiting them keeps
  # at most 64 outstanding, the target's window. It is not thread-safe: one thread
  # drives a session.
  class HostlinkClient
    # The target answered outside the protocol, or for another build.
    class Refused < Error; end
    # A deadline passed with no answer; the outcome of an unanswered call is unknown.
    class Timeout < Error; end

    READ_MAX = 65_536
    HELLO = Etf::Atom.new(name: 'hello')

    # What a hello reply says about the session it opened.
    Session = Data.define(:id, :build, :versions)

    # bytes_sent counts every byte written to the link since the client was made.
    attr_reader :session, :bytes_sent

    # io is the link; expected_build, when given, is the boot image's build identifier
    # in hexadecimal, and a target of another build is refused; deadline is the seconds
    # any one wait lasts.
    def initialize(io:, expected_build: nil, deadline: 30, hello_wait: 2)
      @io = io
      @expected_build = expected_build&.b
      @deadline = deadline
      @hello_wait = hello_wait
      @deframer = HostlinkFrame::Deframer.new(:host)
      @receiver = HostlinkFrame::Receiver.new
      @session = nil
      @replies = {}
      @bytes_sent = 0
    end

    # Opens a session, replacing any the target holds, and returns it.
    def hello(nonce: SecureRandom.bytes(16))
      wire = HostlinkFrame::Sender.new(HostlinkFrame::SESSION_ZERO)
                                  .message(:call, Etf.encode(Etf::Tuple.new(elements: [HELLO, nonce.b])), id: 1, target: 0)
      @credit = HostlinkFrame::Credit.new
      @receiver.session = nil
      @replies.clear
      reply = wait_until(@deadline) do
        transmit(wire)
        wait_hello(nonce, @hello_wait)
      end
      open_session(reply)
    end

    # Sends a call of term to target and returns the decoded reply.
    def call(term, target: 0)
      id = next_id
      send_call(term, id: id, target: target)
      await(id)
    end

    # Sends one call under an identifier the caller chose, as a retry of a call whose
    # reply was lost sends the same identifier again.
    def send_call(term, id:, target: 0)
      raise Error, 'no host link session: send a hello first' unless @session

      transmit(@sender.message(:call, Etf.encode(term), id: id, target: target))
    end

    # The decoded reply to the call id, waiting at most deadline seconds.
    def await(id, deadline: @deadline)
      wait_until(deadline) do
        pump(0.05)
        @replies.delete(id)
      end
    end

    # The next call identifier of the session; identifiers grow within a session.
    def next_id = (@last_id += 1)

    # The deframer's and receiver's counts of what they discarded.
    def counts = { deframer: @deframer.counts.dup, receiver: @receiver.counts.dup }

    # A decoded term as Erlang prints it, every atom and binary through the line escape,
    # so no byte the target chose reaches a terminal raw.
    def self.show(term)
      case term
      in Etf::Atom[name] then LineEscape.escape(name)
      in String then "<<\"#{LineEscape.escape(term)}\">>"
      in Integer | Float then term.to_s
      in Etf::Tuple[elements] then "{#{elements.map { |element| show(element) }.join(',')}}"
      in Array then "[#{term.map { |element| show(element) }.join(',')}]"
      in Etf::Map[pairs] then '#{' + "#{pairs.map { |key, value| "#{show(key)} => #{show(value)}" }.join(',')}}"
      else "<#{term.class.name.split('::').last.downcase}>"
      end
    end

    private

    def open_session(reply)
      _hello, _nonce, id, build, versions = reply.elements
      raise Refused, "the target's build #{HostlinkClient.show(build)} is not #{@expected_build}" if
        @expected_build && build != @expected_build

      @receiver.session = id
      @sender = HostlinkFrame::Sender.new(id)
      @last_id = 0
      @session = Session.new(id: id, build: build, versions: versions)
    end

    # Waits the whole of seconds for the reply to the hello of nonce, taking every frame
    # that arrives meanwhile, so a stale reply, to an earlier hello, does not cut the wait
    # short and bring the next repeat early; nil when none came.
    def wait_hello(nonce, seconds)
      limit = now + seconds
      reply = nil
      while reply.nil? && now < limit
        @hello_reply = nil
        pump(0.05)
        reply = @hello_reply if answers_hello?(@hello_reply, nonce)
      end
      return nil unless reply

      elements = reply.elements
      raise Refused, 'a hello reply with a session identifier that is not 16 bytes, not all zero' unless
        elements[2].is_a?(String) && elements[2].bytesize == 16 && elements[2] != HostlinkFrame::SESSION_ZERO

      reply
    end

    def answers_hello?(reply, nonce)
      reply.is_a?(Etf::Tuple) && reply.elements.size == 5 && reply.elements[0] == HELLO && reply.elements[1] == nonce.b
    end

    # Writes frames, each once the credit allows it, reading grants while it waits.
    def transmit(frames)
      frames.each do |bytes|
        wait_until(@deadline) do
          next true if @credit.allows?(bytes.bytesize)

          pump(0.05)
          false
        end
        @credit.spend(bytes.bytesize)
        @io.write(bytes)
        @bytes_sent += bytes.bytesize
      end
      @io.flush
    end

    # Reads what the link has within seconds and takes each frame it completes.
    def pump(seconds)
      return true unless @io.wait_readable(seconds)

      bytes = @io.read_nonblock(READ_MAX, exception: false)
      raise Refused, 'the host link closed' if bytes.nil?
      return true if bytes == :wait_readable

      @deframer.feed(bytes).each { |frame| take(frame) if frame.is_a?(HostlinkFrame::Frame) }
      true
    end

    def take(frame)
      case @receiver.accept(frame)
      in HostlinkFrame::Hello[message] if message.kind == :reply
        @hello_reply = decode(message.payload)
      in HostlinkFrame::Message => message if message.kind == :reply
        @replies[message.id] = decode(message.payload)
      in HostlinkFrame::Taken[frame] if frame.stream == :credit
        @credit.grant(frame)
      else
        nil
      end
    end

    def decode(payload)
      Etf.decode(payload)
    rescue Etf::Error => e
      raise Refused, "the target sent a payload outside the host grammar: #{e.message}"
    end

    def wait_until(seconds)
      limit = now + seconds
      loop do
        result = yield
        return result if result
        raise Timeout, "no answer from the host link within #{seconds} s" if now >= limit
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
