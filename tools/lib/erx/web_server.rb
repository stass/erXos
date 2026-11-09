# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'securerandom'
require 'socket'
require_relative 'error'
require_relative 'etf'
require_relative 'generated_abi'
require_relative 'hostlink_client'
require_relative 'web_http'
require_relative 'web_inventory'
require_relative 'web_socket'

module Erx
  module Web
    # The host link's `web` facet, the machine's end of every WebSocket
    # (docs/design-web.md, "The host tool's front end", Relaying). Each WebSocket is a
    # number the server chose: connect, data for each whole message, and close are calls
    # on the facet; the machine casts Delivered bytes and Ended connections back. The
    # relay reads none of the protocol's messages. A call that fails or times out, or a
    # link that breaks, raises Down and drops the facet; open makes a session and a facet
    # again.
    class Relay
      class Down < Error; end

      # Bytes the machine sent for connection number, untrusted, to go out as one frame.
      Delivered = Data.define(:number, :bytes)
      # The machine ended connection number.
      Ended = Data.define(:number)

      OK = Etf::Atom.new(name: 'ok')
      HOST_CAP = Etf::Atom.new(name: '$host_cap')
      OPEN_WEB = Etf::Tuple.new(elements: [Etf::Atom.new(name: 'open'), Etf::Atom.new(name: 'web')])
      WEB = Etf::Atom.new(name: 'web')
      WEB_CLOSED = Etf::Atom.new(name: 'web_closed')
      LINK_FAILURES = [HostlinkClient::Timeout, HostlinkClient::Refused, HostlinkFrame::NoCredit, IOError,
                       SystemCallError].freeze

      # link is a HostlinkClient on the machine's host link.
      def initialize(link:)
        @link = link
        @facet = nil
      end

      def open? = !@facet.nil?

      # A fresh session, which ends any the machine held for an earlier start, and the
      # web facet in it; Down when the machine offers none.
      def open
        @facet = nil
        reply = guard { @link.hello && @link.call(OPEN_WEB) }
        raise Down, "the machine offers no web facet: it answered #{HostlinkClient.show(reply)}" unless
          reply in Etf::Tuple[[OK, Etf::Tuple[[HOST_CAP, Integer => facet]]]]

        @facet = facet
      end

      # Whether the machine took connection number.
      def connect(number) = call(:connect, number) == OK

      # Whether the machine took one whole message of connection number.
      def data(number, bytes) = call(:data, number, bytes.b) == OK

      def close(number)
        call(:close, number)
        nil
      end

      # What the machine sent since the last look, within seconds: Delivered and Ended,
      # each for the facet; a cast of any other shape or target is dropped.
      def messages(seconds = 0)
        return [] unless open?

        guard { @link.take_casts(seconds) }.filter_map do |target, term|
          next unless target == @facet

          case term
          in Etf::Tuple[[WEB, Integer => number, String => bytes]] then Delivered.new(number, bytes)
          in Etf::Tuple[[WEB_CLOSED, Integer => number, _]] then Ended.new(number)
          else nil
          end
        end
      end

      def io = @link.io

      private

      def call(name, *arguments)
        raise Down, 'the web facet is not open' unless open?

        guard { @link.call(Etf::Tuple.new(elements: [Etf::Atom.new(name: name.to_s), *arguments]), target: @facet) }
      end

      def guard
        yield
      rescue *LINK_FAILURES => e
        @facet = nil
        raise Down, "the host link failed: #{e.message}"
      end
    end

    # The loopback server: one thread, one IO.select loop over the listening socket, the
    # connections and the host link. A connection is an HTTP request until its answer is
    # written, or a WebSocket once the gate and the machine took its upgrade. Decisions
    # are Http's, the Gate's and the Deframer's; this class reads, writes, keeps the
    # deadlines and the bounds, and closes.
    class Server
      LOOPBACK = '127.0.0.1'
      CONNECTIONS_MAX = 16
      SOCKETS_MAX = 4
      READ_MAX = 65_536
      # The bytes waiting for a browser before its WebSocket closes: twice what the
      # connection core can have in flight for it, one update for each of 16 views.
      OUTPUT_MAX = 2 << 20
      # The seconds a closing connection has to take its last bytes.
      FLUSH_SECONDS = 1

      # request is the seconds a request has to arrive and its answer to go out; ping and
      # idle the WebSocket's ping interval and the silence that closes it.
      Timing = Data.define(:request, :ping, :idle)
      TIMING = Timing.new(request: 10, ping: ABI::Generated::CODEC.constant('web_ping_ms') / 1000.0,
                          idle: ABI::Generated::CODEC.constant('web_idle_ms') / 1000.0)

      # A browser's connection: its socket, the bytes waiting for it, and when it must be
      # done. A closing peer is closed once its bytes are out or its deadline passes.
      class Peer
        attr_reader :io, :deadline

        def initialize(io, deadline)
          @io = io
          @deadline = deadline
          @out = ''.b
          @closing = false
        end

        def write(bytes) = @out << bytes.b

        def pending = @out.bytesize

        def writing? = !@out.empty?

        def closing? = @closing

        def finish(deadline)
          @closing = true
          @deadline = [@deadline, deadline].compact.min
        end

        def done? = @closing && @out.empty?

        def expired?(now) = @deadline && now >= @deadline

        # Writes what the socket takes now; false when the browser has gone.
        def flush
          written = @io.write_nonblock(@out, exception: false)
          @out = @out.byteslice(written..) if written.is_a?(Integer)
          true
        rescue SystemCallError, IOError
          false
        end
      end

      # An HTTP request being read, then its answer being written.
      class HttpPeer < Peer
        attr_reader :buffer

        def initialize(io, deadline)
          super
          @buffer = ''.b
        end
      end

      # A WebSocket: its number on the facet, its deframer and its clocks.
      class SocketPeer < Peer
        attr_reader :number, :deframer
        attr_accessor :heard, :pinged

        def initialize(io, number:, now:)
          super(io, nil)
          @number = number
          @deframer = Socket::Deframer.new
          @heard = now
          @pinged = now
        end
      end

      attr_reader :port

      # relay is the machine's end, open or not; inventory the client's files; port 0
      # takes any free port; out prints a line, and no line it is given holds a secret.
      def initialize(relay:, inventory:, out:, port: 0, timing: TIMING, random: SecureRandom)
        @listener = TCPServer.new(LOOPBACK, port)
        @port = @listener.local_address.ip_port
        @gate = Gate.new(authority: "#{LOOPBACK}:#{@port}", token: random.hex(16), cookie: random.hex(16),
                         inventory: inventory)
        @relay = relay
        @out = out
        @timing = timing
        @peers = []
        @numbers = 0
        @wake, @waker = IO.pipe
        @stopping = false
      end

      # The one URL a browser may start from.
      def url = "http://#{@gate.authority}/?token=#{@gate.token}"

      # Serves until stop.
      def serve
        step until @stopping
      ensure
        shutdown
      end

      # Ends serve from another thread or a signal handler.
      def stop
        @stopping = true
        @waker.write_nonblock('.', exception: false)
      end

      private

      # One turn: what the browsers sent is taken first, so the casts the calls it made
      # collected are delivered in the same turn; the bytes both produced are then written,
      # and the clocks run last, on the turn's state.
      def step
        readers = [@wake, *@peers.reject(&:closing?).map(&:io)]
        readers << @listener if @peers.size < CONNECTIONS_MAX
        readers << @relay.io if @relay.open?
        ready, writable, = IO.select(readers, @peers.select(&:writing?).map(&:io), nil, wait_seconds)
        @wake.read_nonblock(64, exception: false) if ready&.include?(@wake)
        accept if ready&.include?(@listener)
        @peers.select { |peer| ready&.include?(peer.io) }.each { |peer| readable(peer) }
        deliver
        @peers.select { |peer| writable&.include?(peer.io) }.each { |peer| gone(peer) unless peer.flush }
        tick(now)
      end

      def wait_seconds
        open = @peers.grep(SocketPeer).reject(&:closing?)
        deadlines = @peers.filter_map(&:deadline) +
                    open.flat_map { |socket| [socket.pinged + @timing.ping, socket.heard + @timing.idle] }
        return 1.0 if deadlines.empty?

        (deadlines.min - now).clamp(0.0, 1.0)
      end

      def accept
        io = @listener.accept_nonblock(exception: false)
        @peers << HttpPeer.new(io, now + @timing.request) unless io == :wait_readable
      rescue SystemCallError
        # A connection that was reset before it was taken.
        nil
      end

      def readable(peer)
        bytes = peer.io.read_nonblock(READ_MAX, exception: false)
        return if bytes == :wait_readable
        return gone(peer) if bytes.nil?

        peer.is_a?(SocketPeer) ? frames(peer, bytes) : request(peer, bytes)
      rescue SystemCallError, IOError
        gone(peer)
      end

      # Reads a request until its head is whole, then answers it.
      def request(peer, bytes)
        peer.buffer << bytes
        case Http.read(peer.buffer)
        in nil then nil
        in Http::Refusal => refusal then respond(peer, Http.refusal(refusal))
        in Http::Request => request then answer(peer, request)
        end
      end

      def answer(peer, request)
        case @gate.answer(request)
        in Http::Refusal => refusal then respond(peer, Http.refusal(refusal))
        in Http::Response => response then respond(peer, response)
        in Gate::Upgrade => upgrade then upgrade(peer, upgrade)
        end
      end

      def respond(peer, response)
        peer.write(Http.encode(response))
        peer.finish(peer.deadline)
      end

      # Takes the upgrade once the machine took the connection; until then nothing is
      # sent, so a browser that gets 101 has a connection on the machine.
      def upgrade(peer, upgrade)
        return respond(peer, Http.refusal(Http::Refusal.new(503, 'four WebSockets are open'))) if
          @peers.grep(SocketPeer).size >= SOCKETS_MAX

        @relay.open unless @relay.open?
        number = (@numbers += 1)
        return respond(peer, Http.refusal(Http::Refusal.new(503, 'the machine refused the connection'))) unless
          @relay.connect(number)

        socket = SocketPeer.new(peer.io, number: number, now: now)
        @peers[@peers.index(peer)] = socket
        socket.write(Http.encode(Http.switching(upgrade.accept)))
        frames(socket, upgrade.rest) unless upgrade.rest.empty?
      rescue Relay::Down => e
        link_down(e)
        respond(peer, Http.refusal(Http::Refusal.new(503, 'the host link is down')))
      end

      def frames(socket, bytes)
        socket.heard = now
        socket.deframer.feed(bytes).each do |event|
          break if socket.closing?

          case event
          in Socket::Message[bytes] then end_socket(socket, Socket::INTERNAL) unless @relay.data(socket.number, bytes)
          in Socket::Ping if socket.pending > OUTPUT_MAX then end_socket(socket, Socket::INTERNAL)
          in Socket::Ping[payload] then socket.write(Socket.pong(payload))
          in Socket::Pong then nil
          in Socket::Closed[code] then end_socket(socket, code || Socket::NORMAL)
          in Socket::Failed[code, _] then end_socket(socket, code)
          end
        end
      rescue Relay::Down => e
        link_down(e)
      end

      # Hands each frame the machine sent to its WebSocket; one past the message bound,
      # or one that would leave more than OUTPUT_MAX waiting, ends it.
      def deliver
        @relay.messages.each do |message|
          socket = @peers.grep(SocketPeer).find { |peer| peer.number == message.number && !peer.closing? }
          next unless socket

          case message
          in Relay::Ended then close_socket(socket, Socket::NORMAL)
          in Relay::Delivered[_, bytes] if bytes.bytesize > Socket::MESSAGE_MAX || socket.pending > OUTPUT_MAX
            end_socket(socket, Socket::INTERNAL)
          in Relay::Delivered[_, bytes] then socket.write(Socket.binary(bytes))
          end
        end
      rescue Relay::Down => e
        link_down(e)
      end

      def tick(time)
        @peers.grep(SocketPeer).reject(&:closing?).each do |socket|
          next end_socket(socket, Socket::GOING_AWAY) if time - socket.heard >= @timing.idle
          next unless time - socket.pinged >= @timing.ping

          socket.write(Socket.ping)
          socket.pinged = time
        end
        @peers.select { |peer| peer.done? || peer.expired?(time) }.each { |peer| drop(peer) }
      end

      # Closes a WebSocket the browser or the front end ended, and tells the machine.
      def end_socket(socket, code)
        close_socket(socket, code)
        @relay.close(socket.number)
      rescue Relay::Down => e
        link_down(e)
      end

      # Sends the close frame; the socket closes once it is out.
      def close_socket(socket, code)
        socket.write(Socket.close(code))
        socket.finish(now + FLUSH_SECONDS)
      end

      # The browser went away: a WebSocket's connection ends on the machine too, unless
      # it was closing, when the machine was told already or ended it itself.
      def gone(peer)
        drop(peer)
        @relay.close(peer.number) if peer.is_a?(SocketPeer) && !peer.closing? && @relay.open?
      rescue Relay::Down => e
        link_down(e)
      end

      # Every WebSocket closes with 1011 and its client reconnects; the next upgrade
      # opens the host link's session again.
      def link_down(error)
        @out.call("web: #{error.message}; every WebSocket closes")
        @peers.grep(SocketPeer).reject(&:closing?).each { |socket| close_socket(socket, Socket::INTERNAL) }
      end

      def drop(peer)
        @peers.delete(peer)
        peer.io.close unless peer.io.closed?
      end

      def shutdown
        @peers.grep(SocketPeer).reject(&:closing?).each do |socket|
          socket.write(Socket.close(Socket::GOING_AWAY))
          socket.flush
          @relay.close(socket.number) if @relay.open?
        rescue Relay::Down, SystemCallError, IOError
          nil
        end
        @peers.each { |peer| peer.io.close unless peer.io.closed? }
        @peers.clear
        [@listener, @wake, @waker].each(&:close)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
