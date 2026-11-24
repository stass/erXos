# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'io/wait'
require 'socket'
require_relative 'error'
require_relative 'line_escape'
require_relative 'netboot_entry'
require_relative 'web_http'

module Erx
  # `tools/erx netboot serve`, the boot server of netboot's HTTP form
  # (docs/design-platforms.md, "The HTTP form"; docs/design-bench.md, "The construction:
  # the server hands out a queue"). It answers GET and HEAD of /PREFIX/boot.sig and
  # /PREFIX/boot.img and no other name, so no byte of a request becomes part of a path,
  # and hands out the queue its link names by one rule: the n-th download takes entry n,
  # and every download after the last entry takes the last. A download is a client's
  # boot.sig request and its boot.img request that follows: both files of the entry are
  # opened at the first and the second is answered from what was opened, so a change of
  # the link at any moment gives each download one image with its own signature.
  #
  # Decision is the pure core: the request, the link as found and the state to the action
  # and, through the transitions, the next state. Server is the effects: it reads each
  # connection's request through Web::Http.read, the host tool's bounded and fuzzed
  # reader, opens entries (LinkQueue), writes answers and logs each request with the
  # request's bytes through LineEscape. It answers one connection at a time, so the state
  # has one writer.
  module NetbootServer
    module Decision
      NAMES = [NetbootEntry::SIGNATURE, NetbootEntry::IMAGE].freeze
      # target, the queue the link named at the last download begun; cursor, the entry the
      # next download takes, from 1; download, the one begun, or nil.
      State = Data.define(:target, :cursor, :download)
      # A download begun: the client that asked for the signature, the entry it took and
      # its pair as the effects opened it (opaque here).
      Download = Data.define(:client, :entry, :pair)
      # The link as one request finds it: target, the queue it names, or nil; entries, the
      # queue's entry count (NetbootEntry.entries).
      Served = Data.define(:target, :entries)
      # The actions. Refuse answers status with nothing; Begin opens target's entry and
      # answers its signature, and when body is set (a GET) begins a download; Send answers
      # the download's image, with its bytes when body is set.
      Refuse = Data.define(:status)
      Begin = Data.define(:target, :entry, :body)
      Send = Data.define(:download, :body)
      INITIAL = State.new(target: nil, cursor: 1, download: nil)

      module_function

      # The action for request (a Web::Http::Request) from client, an address, given the
      # link as found (Served) and prefix, the EEPROM's HTTP_PATH. Pure.
      def action(state, request, client:, served:, prefix:)
        name = NAMES.find { |candidate| request.path == "/#{prefix}/#{candidate}" }
        return Refuse.new(status: 404) unless name
        return Refuse.new(status: 405) unless %w[GET HEAD].include?(request.method)

        body = request.method == 'GET'
        if name == NetbootEntry::IMAGE
          download = state.download
          return download&.client == client ? Send.new(download: download, body: body) : Refuse.new(status: 404)
        end
        return Refuse.new(status: 404) if served.target.nil? || served.entries.zero?

        cursor = served.target == state.target ? state.cursor : 1
        Begin.new(target: served.target, entry: [cursor, served.entries].min, body: body)
      end

      # The state after a Begin whose entry the effects opened as pair, or found without
      # a whole pair (nil). A HEAD begins nothing; a GET binds client's download to the
      # entry, or ends the one in progress when the entry has no pair.
      def begun(state, action, client:, pair:)
        return state unless action.body

        download = pair && Download.new(client: client, entry: action.entry, pair: pair)
        State.new(target: action.target, cursor: action.entry, download: download)
      end

      # The state after a Send that went out whole (whole) or not: once an image has gone
      # out whole, the next download takes the next entry.
      def sent(state, action, whole:)
        return state unless action.body && whole

        state.with(cursor: action.download.entry + 1, download: nil)
      end
    end

    # The served link's queues on disk: the link resolved at each request, entries opened
    # as NetbootEntry.open_pair opens them.
    class LinkQueue
      def initialize(link)
        @link = link
      end

      def served
        target = File.realpath(@link)
        return Decision::Served.new(target: nil, entries: 0) unless File.directory?(target)

        Decision::Served.new(target: target, entries: NetbootEntry.entries(target))
      rescue SystemCallError
        Decision::Served.new(target: nil, entries: 0)
      end

      def open(target, entry) = NetbootEntry.open_pair(File.join(target, entry.to_s))
    end

    # The effects around Decision for queue (LinkQueue), answering at /prefix/; log takes
    # one line per request.
    class Server
      # A request's head must come whole within this many seconds, and each part of an
      # answer must be taken within STALL_SECONDS, so a stalled client holds the server for
      # a bounded time.
      HEAD_SECONDS = 10
      STALL_SECONDS = 30
      READ_MAX = 16_384
      CHUNK = 1 << 20
      # The EEPROM's HTTP_PATH: one path segment.
      PREFIX = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
      HEADERS = [%w[Content-Type application/octet-stream], %w[Cache-Control no-store]].freeze

      # An answer not taken within STALL_SECONDS.
      class Stalled < IOError; end

      attr_reader :state

      def initialize(queue:, prefix:, log:)
        raise Error, "netboot serve: #{prefix.inspect} is not one path segment" unless PREFIX.match?(prefix)

        @queue = queue
        @prefix = prefix
        @log = log
        @state = Decision::INITIAL
      end

      # Answers listener's connections one at a time until it is closed.
      def listen(listener)
        loop do
          socket = listener.accept
          begin
            connection(socket)
          ensure
            socket.close
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end

      # Reads one request from socket and answers it.
      def connection(socket)
        client = socket.remote_address.ip_address
        case read_request(socket)
        in nil then nil
        in Web::Http::Refusal => refusal
          write_all(socket, Web::Http.encode(Web::Http.refusal(refusal)))
          @log.call("#{client} refused: #{refusal.reason}")
        in Web::Http::Request => request then answer(request, client: client, out: Writer.new(socket))
        end
      rescue SystemCallError, IOError
        nil
      end

      # Answers request from client on out, which takes write(bytes), and moves the state.
      def answer(request, client:, out:)
        action = Decision.action(@state, request, client: client, served: @queue.served, prefix: @prefix)
        case action
        in Decision::Refuse => refuse then refuse(out, refuse, request: request, client: client)
        in Decision::Begin => start then begin_download(out, start, request: request, client: client)
        in Decision::Send => send then send_image(out, send, request: request, client: client)
        end
      end

      private

      def refuse(out, refuse, request:, client:)
        out.write(Web::Http.head(refuse.status, [], length: 0))
        note(request, client, refuse.status)
      end

      def begin_download(out, start, request:, client:)
        pair = @queue.open(start.target, start.entry)
        before = @state.download
        @state = Decision.begun(@state, start, client: client, pair: pair)
        close(before) unless before.equal?(@state.download)
        close_pair(pair) unless pair.nil? || @state.download&.pair.equal?(pair)
        return refuse(out, Decision::Refuse.new(status: 404), request: request, client: client) unless pair

        out.write(Web::Http.head(200, HEADERS, length: pair.signature.bytesize))
        out.write(pair.signature) if start.body
        note(request, client, 200, "entry #{start.entry}")
      end

      def send_image(out, send, request:, client:)
        image = send.download.pair.image
        size = image.size
        whole = false
        begin
          out.write(Web::Http.head(200, HEADERS, length: size))
          copy(image, out, size) if send.body
          whole = true
        ensure
          @state = Decision.sent(@state, send, whole: whole)
          close(send.download) unless @state.download.equal?(send.download)
          note(request, client, 200, "entry #{send.download.entry}#{whole ? '' : ', cut'}")
        end
      end

      # Writes size bytes of image from its start, in chunks read at their offsets.
      def copy(image, out, size)
        offset = 0
        while offset < size
          chunk = image.pread([CHUNK, size - offset].min, offset)
          out.write(chunk)
          offset += chunk.bytesize
        end
      end

      def close(download) = download && close_pair(download.pair)
      def close_pair(pair) = pair.image.close

      def note(request, client, status, detail = nil)
        @log.call([client, LineEscape.escape(request.method), LineEscape.escape(request.path), status, detail].compact.join(' '))
      end

      # The request at the start of the connection, read through Web::Http.read until it
      # is whole or refused, or nil when the client closes or stalls first.
      def read_request(socket)
        buffer = ''.b
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HEAD_SECONDS
        loop do
          request = Web::Http.read(buffer)
          return request if request

          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil unless left.positive? && socket.wait_readable(left)

          bytes = socket.read_nonblock(READ_MAX, exception: false)
          return nil if bytes.nil?

          buffer << bytes unless bytes == :wait_readable
        end
      end

      def write_all(socket, bytes) = Writer.new(socket).write(bytes)
    end

    # A connection's writer: each write waits at most Server::STALL_SECONDS for the socket
    # to take more, then raises Server::Stalled.
    class Writer
      def initialize(socket)
        @socket = socket
      end

      def write(bytes)
        rest = bytes.b
        until rest.empty?
          written = @socket.write_nonblock(rest, exception: false)
          if written == :wait_writable
            raise Server::Stalled, 'the client took nothing' unless @socket.wait_writable(Server::STALL_SECONDS)
          else
            rest = rest.byteslice(written..)
          end
        end
      end
    end
  end
end
