# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'net/http'
require 'rbconfig'
require 'securerandom'
require 'socket'
require_relative 'error'
require_relative 'hostlink_guest'
require_relative 'line_escape'

module Erx
  # A browser's visit to a booted guest through the host tool's own front end
  # (docs/design-web.md, "The host tool's front end"): tools/erx web runs on the guest's
  # host link socket, and the check does what a browser does with the URL it prints. The
  # URL answers 303 with the session cookie; with the cookie, the page and the client's
  # script it names answer 200; the upgrade of /ws with the cookie and the server's
  # origin answers 101; and hello and the open of view 1 on the machine's path, sent
  # together as the client's connection core sends them (web/src/connection.ts), are
  # answered with the welcome and then the machine's record. HostlinkGuest.machine_record
  # checks the same open straight over the host link; run it first, so root is logged in
  # and the open is not ended.
  module WebGuest
    # The seconds tools/erx web has to print its URL, each HTTP exchange has, and the
    # front end has to end on TERM.
    STEP_SECONDS = 30
    # The worst case of call: the URL, the three HTTP exchanges, the WebSocket's messages
    # (HostlinkGuest::WEB_SECONDS) and the stop.
    SECONDS = (STEP_SECONDS * 5) + HostlinkGuest::WEB_SECONDS
    PRINTED = %r{^web: open (http://127\.0\.0\.1:\d+/\?token=\h+)$}
    SCRIPT = %r{<script type="module" src="(/client-\h+\.js)">}

    module_function

    # Runs the visit against the guest whose host link socket is socket; root is the tree
    # whose tools/erx serves its build/web, build the boot image's build identifier in
    # hexadecimal or nil for any, web_hash the web protocol's (HostlinkGuest.web_hash). The front end's
    # output goes to web-front-end.log beside the socket. Returns the update's first bytes
    # in hexadecimal.
    def call(socket, root:, build:, web_hash:)
      log = File.join(File.dirname(socket), 'web-front-end.log')
      front_end = Process.spawn(RbConfig.ruby, File.join(root, 'tools/erx'), 'web', '--socket', socket,
                                *(build ? ['--build', build] : []), in: :close, %i[out err] => [log, 'w'])
      begin
        update = visit(URI(printed_url(log)), web_hash, log)
      ensure
        stop(front_end)
      end
      update.byteslice(0, HostlinkGuest::MACHINE_UPDATE.bytesize).unpack1('H*')
    end

    def printed_url(log)
      limit = now + STEP_SECONDS
      loop do
        url = File.file?(log) && File.binread(log)[PRINTED, 1]
        return url if url

        fail_with(log, "printed no URL in #{STEP_SECONDS} s") if now >= limit
        sleep(0.1)
      end
    end

    def visit(url, hash, log)
      Net::HTTP.start(url.host, url.port, open_timeout: STEP_SECONDS, read_timeout: STEP_SECONDS) do |http|
        cookie = login(http, url, log)
        page = fetch(http, '/', cookie, log)
        script = page.body.to_s[SCRIPT, 1] || fail_with(log, 'the page names no client script')
        fetch(http, script, cookie, log)
        machine_record(url, cookie, hash, log)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SystemCallError => e
      fail_with(log, "HTTP to #{url.host}:#{url.port}: #{e.message}")
    end

    # The printed URL's 303 and the cookie it sets.
    def login(http, url, log)
      answer = http.get(url.request_uri)
      cookie = answer['set-cookie'].to_s.split(';').first
      fail_with(log, "the printed URL answered #{answer.code}, not 303 with a cookie") unless answer.code == '303' && cookie
      cookie
    end

    def fetch(http, path, cookie, log)
      answer = http.get(path, 'Cookie' => cookie)
      fail_with(log, "#{path} answered #{answer.code}") unless answer.code == '200'
      answer
    end

    # The WebSocket's upgrade, then the welcome and the machine's record, each within
    # WEB_SECONDS of the message before it.
    def machine_record(url, cookie, hash, log)
      authority = "#{url.host}:#{url.port}"
      TCPSocket.open(url.host, url.port) do |io|
        io.write("GET /ws HTTP/1.1\r\nHost: #{authority}\r\nOrigin: http://#{authority}\r\nCookie: #{cookie}\r\n" \
                 "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" \
                 "Sec-WebSocket-Key: #{[SecureRandom.bytes(16)].pack('m0')}\r\n\r\n")
        frames = ServerFrames.new(io, log: log)
        status = frames.head.lines.first.to_s.strip
        fail_with(log, "the upgrade answered #{status.inspect}") unless status.start_with?('HTTP/1.1 101 ')

        io.write(browser_frame(HostlinkGuest.hello(hash)) + browser_frame(HostlinkGuest::OPEN_MACHINE))
        welcome = frames.binary('the welcome')
        fail_with(log, "the welcome is #{welcome.unpack1('H*')}") unless welcome.getbyte(0) == HostlinkGuest::WELCOME
        update = frames.binary("the machine's record")
        fail_with(log, "the machine's record is #{update.unpack1('H*')}") unless
          update.start_with?(HostlinkGuest::MACHINE_UPDATE)
        update
      end
    end

    # A browser's binary frame: final and masked (RFC 6455 section 5.3), with the 7-bit
    # length, which the check's few messages fit.
    def browser_frame(payload)
      raise Error, "web front end: a #{payload.bytesize}-byte message needs an extended length" if payload.bytesize > 125

      mask = SecureRandom.bytes(4)
      masked = payload.bytes.each_with_index.map { |byte, at| byte ^ mask.getbyte(at % 4) }.pack('C*')
      [0x82, 0x80 | payload.bytesize].pack('CC') + mask + masked
    end

    # The front end ends on TERM; one still running after STEP_SECONDS is killed.
    def stop(pid)
      Process.kill('TERM', pid)
      limit = now + STEP_SECONDS
      until now > limit
        return if Process.wait(pid, Process::WNOHANG)

        sleep(0.1)
      end
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end

    # Raises what went wrong, followed by the last 4 KiB the front end printed, escaped.
    def fail_with(log, what)
      printed = File.file?(log) ? File.binread(log) : ''
      printed = printed.byteslice([printed.bytesize - 4096, 0].max..)
      raise Error, "web front end: #{what}; tools/erx web printed: #{LineEscape.escape(printed)}"
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # The front end's side of one WebSocket as a browser reads it: the upgrade's head,
    # then unmasked frames, whole in one read or several. The head and each message
    # have WEB_SECONDS.
    class ServerFrames
      BINARY = 2
      CLOSE = 8

      def initialize(io, log:)
        @io = io
        @log = log
        @buffer = ''.b
      end

      def head
        limit = WebGuest.now + HostlinkGuest::WEB_SECONDS
        fill('the upgrade', limit) until (ends = @buffer.index("\r\n\r\n"))
        @buffer.slice!(0, ends + 4)
      end

      # The next binary message's payload; a ping is passed over, a close fails.
      def binary(what)
        limit = WebGuest.now + HostlinkGuest::WEB_SECONDS
        loop do
          opcode, payload = frame(what, limit)
          WebGuest.fail_with(@log, "#{what}: the front end closed the WebSocket") if opcode == CLOSE
          return payload if opcode == BINARY
        end
      end

      private

      def frame(what, limit)
        loop do
          length, offset = header
          if offset && @buffer.bytesize >= offset + length
            opcode = @buffer.getbyte(0) & 0x0f
            payload = @buffer.byteslice(offset, length)
            @buffer = @buffer.byteslice((offset + length)..)
            return [opcode, payload]
          end
          fill(what, limit)
        end
      end

      # The payload's length and where it starts; no offset while the header is not
      # whole yet.
      def header
        return [0, nil] if @buffer.bytesize < 2

        case @buffer.getbyte(1) & 0x7f
        in 126 then @buffer.bytesize >= 4 ? [@buffer.byteslice(2, 2).unpack1('n'), 4] : [0, nil]
        in 127 then @buffer.bytesize >= 10 ? [@buffer.byteslice(2, 8).unpack1('Q>'), 10] : [0, nil]
        in short then [short, 2]
        end
      end

      def fill(what, limit)
        left = limit - WebGuest.now
        WebGuest.fail_with(@log, "#{what}: nothing came in #{HostlinkGuest::WEB_SECONDS} s") unless
          left.positive? && @io.wait_readable(left)

        bytes = @io.read_nonblock(65_536, exception: false)
        WebGuest.fail_with(@log, "#{what}: the front end closed the connection") if bytes.nil?
        @buffer << bytes if bytes.is_a?(String)
      end
    end
  end
end
