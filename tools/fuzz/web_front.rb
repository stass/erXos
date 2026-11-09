#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/error'
require_relative '../lib/erx/web_http'
require_relative '../lib/erx/web_socket'

# The fuzz target of the host tool's HTTP and WebSocket reader, Erx::Web's Http, Gate
# and Socket::Deframer (docs/design-web.md, "Verification and testing"), over random
# bytes and mutations of seeds.
#
# A request must read the same whether its bytes come whole or one at a time; the
# reader may wait only while what it holds is within its bounds; and the gate's answer
# must be a file of the inventory, a refusal or an upgrade, never holding the token, and
# an upgrade only for a request this file's own check finds authorized. Frames fed in
# random pieces must give the events of this file's reference deframer, which reads the
# whole input by offsets, and the deframer must never hold more than its bound.
#
# Each run also feeds the seeds to two faulty copies and requires the exercise to fail
# on them: a deframer without the length check before reading, on a declared
# 2^40-byte frame, and a gate without its Origin check, on a foreign page's upgrade.
module Erx
  module WebFrontFuzz
    Http = Web::Http
    WS = Web::Socket
    TOKEN = '0123456789abcdef0123456789abcdef'
    COOKIE = 'fedcba9876543210fedcba9876543210'
    AUTHORITY = '127.0.0.1:8080'
    INVENTORY = Web::Inventory.new([['index.html', '<!doctype html>'], ['app.js', 'go()'], ['notices.txt', 'MIT']])
    FILES = INVENTORY.paths.map { |path| INVENTORY.file("/#{path}").bytes }.freeze
    # Room for a seed at every bound: a whole message and its frame's header.
    MAX_INPUT = 70_000
    # The most the reader may hold while it waits for a request's head.
    WAIT_MAX = Http::LINE_MAX + 2 + Http::HEADERS_MAX + 4
    STATUSES = [200, 303, 400, 403, 405, 414].freeze

    UPGRADE = { 'Host' => AUTHORITY, 'Origin' => "http://#{AUTHORITY}", 'Cookie' => "erx_web_8080=#{COOKIE}",
                'Upgrade' => 'websocket', 'Connection' => 'Upgrade', 'Sec-WebSocket-Key' => 'dGhlIHNhbXBsZSBub25jZQ==',
                'Sec-WebSocket-Version' => '13' }.freeze
    STEERING = ["\r\n", "\r\n\r\n", ' ', ':', '?', '/', 'token=', TOKEN, COOKIE, 'erx_web_8080=', "\x00", "\xff", "\n",
                'Host: ', AUTHORITY, 'GET', 'ws', ';', ','].map(&:b).freeze

    module_function

    def head(line, headers) = ([line, *headers.map { |name, value| "#{name}: #{value}" }].join("\r\n") + "\r\n\r\n").b

    def request_seeds
      [head('GET / HTTP/1.1', 'Host' => AUTHORITY), head("GET /proc/x?token=#{TOKEN} HTTP/1.1", 'Host' => AUTHORITY),
       head('GET /ws HTTP/1.1', UPGRADE), head('GET /ws HTTP/1.1', UPGRADE.merge('Origin' => 'http://evil.example')),
       head('GET /app.js HTTP/1.1', 'Host' => AUTHORITY, 'Cookie' => "a=b; erx_web_8080=#{COOKIE}"),
       head('POST / HTTP/1.1', 'Host' => AUTHORITY, 'Content-Length' => '3') + 'abc', *bound_seeds]
    end

    # Requests at the reader's bounds, a byte either side: request lines of LINE_MAX - 1
    # to LINE_MAX + 2 bytes, fields of HEADERS_MAX - 3 to HEADERS_MAX + 3 bytes, whole or
    # without their end, and a head that never ends, past what the reader may wait on.
    def bound_seeds
      lines = (-1..2).map { |delta| head("GET /#{'a' * (Http::LINE_MAX + delta - 14)} HTTP/1.1", 'Host' => AUTHORITY) }
      # From the line's CRLF: 2 + the field's name, colon and space (3) + value + CRLF (2).
      fields = (-3..3).map do |delta|
        head('GET / HTTP/1.1', 'X' => 'y' * (Http::HEADERS_MAX + delta - 7)).then { |bytes| [bytes, bytes.byteslice(0...-1)] }
      end
      [*lines, *fields.flatten, "GET / HTTP/1.1\r\nX: #{'y' * WAIT_MAX}".b]
    end

    # A masked frame of opcode and payload.
    def frame(opcode, payload, final: true, mask: "\x11\x22\x33\x44".b)
      size = payload.bytesize
      length = size < 126 ? [0x80 | size].pack('C') : [0x80 | 126, size].pack('Cn')
      [(final ? 0x80 : 0) | opcode].pack('C') + length + mask + WS.unmask(payload.b, mask)
    end

    # The design's seeded fault for the deframer first.
    LONG_FRAME = ([0x82, 0x80 | 127, 1 << 40].pack('CCQ>') + "\0\0\0\0").freeze

    def frame_seeds
      [LONG_FRAME, frame(2, 'hello') + frame(9, 'p') + frame(8, [1000].pack('n')),
       frame(2, 'ab', final: false) + frame(10, '') + frame(0, 'cd'), frame(1, 'text'), frame(2, 'x' * 300),
       [0x82, 0x80 | 126, 70_000 & 0xffff].pack('CCn') + "\0\0\0\0",
       # A message of MESSAGE_MAX bytes and one of a byte more, in two frames; a frame that
       # declares a byte more, with its payload.
       frame(2, 'x' * 40_000, final: false) + frame(0, 'y' * (WS::MESSAGE_MAX - 40_000)),
       frame(2, 'x' * 40_000, final: false) + frame(0, 'y' * (WS::MESSAGE_MAX - 39_999)),
       [0x82, 0x80 | 127, WS::MESSAGE_MAX + 1].pack('CCQ>') + "\0\0\0\0" + ('z' * (WS::MESSAGE_MAX + 1))]
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..6).times do
        position = result.empty? ? 0 : random.rand(result.bytesize + 1)
        case random.rand(5)
        when 0 then result.insert(position, STEERING.sample(random: random))
        when 1 then result = result.byteslice(0, position) + (result.byteslice(position + random.rand(1..8)..) || ''.b)
        when 2 then result.setbyte(position, random.rand(256)) if position < result.bytesize
        when 3 then result.insert(position, random.bytes(random.rand(1..8)))
        # A long run, to carry a small input to a bound.
        else result.insert(position, STEERING.sample(random: random) * random.rand(1..4096))
        end
      end
      result.byteslice(0, MAX_INPUT)
    end

    def random_bytes(random) = Array.new(random.rand(0..64)) { random.rand(256) }.pack('C*')

    def pieces(bytes, random)
      cuts = Array.new(random.rand(0..4)) { random.rand(bytes.bytesize + 1) }.sort.uniq
      [0, *cuts, bytes.bytesize].each_cons(2).map { |from, to| bytes.byteslice(from, to - from) }
    end

    # The reader and the gate on one input.
    def exercise_request(bytes, random, gate:)
      whole = Http.read(bytes)
      held = ''.b
      pieced = pieces(bytes, random).lazy.map { |piece| Http.read(held << piece) }.find { |result| !result.nil? }
      shown = bytes.unpack1('H*')
      raise Error, "request #{shown} reads differently in pieces" unless same_read?(pieced, whole)
      raise Error, "request #{shown}: the reader waits holding #{bytes.bytesize} bytes" if
        whole.nil? && bytes.bytesize > WAIT_MAX
      return unless whole

      check_answer(whole, whole.is_a?(Http::Request) ? gate.answer(whole) : whole, shown)
    end

    # Pieces end at the first prefix that completes the head; its rest may be shorter.
    def same_read?(pieced, whole)
      return pieced == whole unless pieced.is_a?(Http::Request) && whole.is_a?(Http::Request)

      pieced.with(rest: ''.b) == whole.with(rest: ''.b)
    end

    def check_answer(request, answer, shown)
      case answer
      in Web::Gate::Upgrade
        raise Error, "request #{shown} upgraded without the cookie, the Host and the Origin" unless authorized?(request)
      in Http::Refusal | Http::Response
        response = answer.is_a?(Http::Refusal) ? Http.refusal(answer) : answer
        raise Error, "request #{shown} answered #{response.status}" unless STATUSES.include?(response.status)
        raise Error, "request #{shown} answered something not a file or a refusal" unless
          response.status != 200 || FILES.include?(response.body)
        encoded = Http.encode(response)
        # The 303 names the request's own path, which a sender that knew the token may
        # have spelled it in.
        raise Error, "request #{shown}: the token is in the answer" if
          encoded.include?(TOKEN) && !(request.is_a?(Http::Request) && request.path.include?(TOKEN))
        raise Error, "request #{shown}: a header holds a line break" if
          encoded.split("\r\n\r\n", 2).first.split("\r\n").any? { |line| line.match?(/[\r\n]/) }
      end
    end

    # This file's own reading of W4, apart from the Gate's.
    def authorized?(request)
      headers = request.headers
      headers['host'] == AUTHORITY && headers['origin'] == "http://#{AUTHORITY}" &&
        headers['cookie'].to_s.split(';').map(&:strip).include?("erx_web_8080=#{COOKIE}") && request.path == '/ws' &&
        request.query.nil?
    end

    # The deframer, fed in random pieces, against the reference on the whole input.
    def exercise_frames(bytes, random, deframer: WS::Deframer.new)
      events = pieces(bytes, random).flat_map do |piece|
        deframer.feed(piece).tap do
          raise Error, "frames #{bytes.unpack1('H*')}: the deframer holds #{deframer.held} bytes" if
            deframer.held > WS::HELD_MAX
        end
      end
      # A failure's text is the deframer's own; its code is what the RFC fixes.
      events = events.map { |event| event.is_a?(WS::Failed) ? event.with(why: '') : event }
      raise Error, "frames #{bytes.unpack1('H*')} disagree with the reference" unless events == reference(bytes)
    end

    # RFC 6455's frames read by offsets over the whole input, to the first close or
    # failure, with the deframer's rules in the same order: the first two bytes, then
    # the length, then the payload.
    def reference(bytes)
      events = []
      offset = 0
      message = nil
      while bytes.bytesize - offset >= 2
        first = bytes.getbyte(offset)
        second = bytes.getbyte(offset + 1)
        opcode = first & 0x0f
        fin = first >= 0x80
        failure = if (first & 0x70) != 0 || second < 0x80 || ![0, 1, 2, 8, 9, 10].include?(opcode)
                    WS::PROTOCOL_ERROR
                  end
        return events << WS::Failed.new(failure, '') if failure

        extended = { 126 => 2, 127 => 8 }.fetch(second & 0x7f, 0)
        break if bytes.bytesize - offset < 6 + extended

        length = extended.zero? ? second & 0x7f : bytes.byteslice(offset + 2, extended).unpack1(extended == 2 ? 'n' : 'Q>')
        code = header_failure(opcode, fin, extended, length, message)
        return events << WS::Failed.new(code, '') if code

        start = offset + 6 + extended
        break if bytes.bytesize < start + length

        mask = bytes.byteslice(start - 4, 4).bytes
        payload = bytes.byteslice(start, length).bytes.each_with_index.map { |byte, index| byte ^ mask[index % 4] }.pack('C*')
        offset = start + length
        case opcode
        when 9 then events << WS::Ping.new(payload)
        when 10 then events << WS::Pong.new(payload)
        when 8 then return events << close_event(payload)
        else
          message = (message || ''.b) + payload
          next unless fin

          events << WS::Message.new(message)
          message = nil
        end
      end
      events
    end

    def header_failure(opcode, fin, extended, length, message)
      if (extended == 2 && length < 126) || (extended == 8 && length < 65_536) then WS::PROTOCOL_ERROR
      elsif opcode >= 8 then fin && length <= 125 ? nil : WS::PROTOCOL_ERROR
      elsif opcode == 1 then WS::UNSUPPORTED
      elsif (opcode.zero? && message.nil?) || (opcode == 2 && message) then WS::PROTOCOL_ERROR
      elsif (message&.bytesize || 0) + length > WS::MESSAGE_MAX then WS::TOO_BIG
      end
    end

    def close_event(payload)
      return WS::Closed.new(nil) if payload.empty?
      return WS::Failed.new(WS::PROTOCOL_ERROR, '') if payload.bytesize == 1

      code = payload.unpack1('n')
      return WS::Failed.new(WS::PROTOCOL_ERROR, '') unless [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011].include?(code) ||
                                                           code.between?(3000, 4999)
      return WS::Failed.new(WS::NOT_UTF8, '') unless payload.byteslice(2..).force_encoding(Encoding::UTF_8).valid_encoding?

      WS::Closed.new(code)
    end

    def gate(kind = Web::Gate) = kind.new(authority: AUTHORITY, token: TOKEN, cookie: COOKIE, inventory: INVENTORY)

    # The faulty copies the exercise must catch.
    UNBOUNDED = Class.new(WS::Deframer) { def fits?(_length) = true }
    NO_ORIGIN = Class.new(Web::Gate) { def origin?(_request) = true }

    def check_seeded_faults(random)
      faults = { 'a deframer without the length check' => -> { exercise_frames(LONG_FRAME, random, deframer: UNBOUNDED.new) },
                 'a gate without the Origin check' => -> { request_seeds.each { |seed| exercise_request(seed, random, gate: gate(NO_ORIGIN)) } } }
      faults.each do |fault, exercise|
        caught = begin
          exercise.call
          false
        rescue Error
          true
        end
        raise Error, "#{fault} passed the fuzz target" unless caught
      end
    end

    # A seed to mutate: the large ones, at the bounds, at the end of each list, one time in
    # eight, so a short budget still covers many small inputs.
    def pick(seeds, random)
      small = seeds.reject { |bytes| bytes.bytesize > 4096 }
      (random.rand(8).zero? ? seeds - small : small).sample(random: random)
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      requests = request_seeds
      frames = frame_seeds
      requests.each { |bytes| exercise_request(bytes, random, gate: gate) }
      frames.each { |bytes| exercise_frames(bytes, random) }
      check_seeded_faults(random)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = requests.size + frames.size
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        if random.rand(2).zero?
          exercise_request(random.rand(4).zero? ? random_bytes(random) : mutate(pick(requests, random), random),
                           random, gate: gate)
        else
          exercise_frames(random.rand(4).zero? ? random_bytes(random) : mutate(pick(frames, random), random), random)
        end
        count += 1
      end
      count
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1 }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  puts "web front end: #{Erx::WebFrontFuzz.run(**options)} inputs, and two faulty copies caught"
end
