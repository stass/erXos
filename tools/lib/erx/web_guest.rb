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
  # answered with the welcome and then the machine's record. On the same socket, as a
  # browser that followed links would, the open of /proc/processes, root's session's own
  # processes, is answered with their listing, a page of 1,000 pids when the session holds
  # the idle processes of the GW measurement's fixture, and the open of another domain's
  # path ends `scope` (docs/design-web.md, "Views on the line"). HostlinkGuest.machine_record
  # checks the same open of the machine straight over the host link; run it first, so root
  # is logged in and the open is not ended.
  module WebGuest
    # The seconds tools/erx web has to print its URL, each HTTP exchange has, and the
    # front end has to end on TERM.
    STEP_SECONDS = 30
    # The worst case of call: the URL, the three HTTP exchanges, the stop, and the
    # WebSocket's six waits of HostlinkGuest::WEB_SECONDS each: the upgrade, the welcome,
    # the machine's record, the two path views' answers and the process's record.
    SECONDS = (STEP_SECONDS * 5) + (HostlinkGuest::WEB_SECONDS * 6)
    PRINTED = %r{^web: open (http://127\.0\.0\.1:\d+/\?token=\h+)$}
    SCRIPT = %r{<script type="module" src="(/client-\h+\.js)">}
    # The idle processes root's session holds for the GW measurement's fixture: more than
    # the inspector's page holds, so the listing of its processes is a partial page, cut
    # at this many entries or at inspect_reply_max encoded bytes of their records,
    # whichever comes first (erx_inspector:page_add/2).
    IDLE_PROCESSES = 1000

    module_function

    # The web protocol's messages of the path views, little-endian as abi/protocols/web.txt
    # lays them out (HostlinkGuest's OPEN_MACHINE and MACHINE_UPDATE show the layout): a
    # union's tag is one byte, a list's count, a view and a text's length four.
    OPEN = 2
    UPDATE = 2
    ENDED = 3
    TARGET_PATH = 1
    BODY_RECORD = 1
    DATUM_TEXT = 2
    DATUM_ATOM = 3
    CHILDREN_PARTIAL = 2

    def u32(value) = [value].pack('V')
    def tag(value) = [value].pack('C')
    def text(value) = (u32(value.bytesize) + value).b

    # A browser's open of view on the path of the /proc entry names names.
    def open_path(view, names) = (tag(OPEN) + u32(view) + tag(TARGET_PATH) + u32(names.size) + names.map { text(_1) }.join).b

    # The start of the update of view carrying the record of the path of names and of
    # kind: its path as text data, then its kind's name.
    def record_update(view, names, kind)
      (tag(UPDATE) + u32(view) + tag(BODY_RECORD) + u32(names.size) + names.map { tag(DATUM_TEXT) + text(_1) }.join +
       text(kind)).b
    end

    # The start of the update of view that answers the open of /proc/processes, through
    # its partial page's tag: the listing's id, the atom `processes` and no attributes.
    def processes_update(view)
      (record_update(view, ['processes'], 'listing') + tag(DATUM_ATOM) + text('processes') + u32(0) +
       tag(CHILDREN_PARTIAL)).b
    end

    # Whether update answers the open of /proc/processes in view with a partial page of
    # the idle processes, at most IDLE_PROCESSES children, the first of them text.
    def processes_page?(update, view)
      at = processes_update(view).bytesize
      update.start_with?(processes_update(view)) && update.byteslice(at, 4).unpack1('V').to_i.between?(1, IDLE_PROCESSES) &&
        update.byteslice(at + 4, 1) == tag(DATUM_TEXT)
    end

    # A view's end, `scope`.
    def ended_scope(view) = (tag(ENDED) + u32(view) + text('scope')).b

    # Runs the visit against the guest whose host link socket is socket; root is the tree
    # whose tools/erx serves its build/web, build the boot image's build identifier in
    # hexadecimal or nil for any, web_hash the web protocol's (HostlinkGuest.web_hash),
    # foreign the id of a domain that does not exist, whose path answers `scope` at root's
    # scope `all` as a path outside a scope does. The front end's
    # output goes to web-front-end.log beside the socket. Returns the machine's update's
    # first bytes in hexadecimal.
    def call(socket, root:, build:, web_hash:, foreign:)
      log = File.join(File.dirname(socket), 'web-front-end.log')
      front_end = Process.spawn(RbConfig.ruby, File.join(root, 'tools/erx'), 'web', '--socket', socket,
                                *(build ? ['--build', build] : []), in: :close, %i[out err] => [log, 'w'])
      begin
        update = visit(URI(printed_url(log)), web_hash, foreign, log)
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

    def visit(url, hash, foreign, log)
      Net::HTTP.start(url.host, url.port, open_timeout: STEP_SECONDS, read_timeout: STEP_SECONDS) do |http|
        cookie = login(http, url, log)
        page = fetch(http, '/', cookie, log)
        script = page.body.to_s[SCRIPT, 1] || fail_with(log, 'the page names no client script')
        fetch(http, script, cookie, log)
        machine_record(url, cookie, hash, foreign, log)
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
    # WEB_SECONDS of the message before it, and then the path views (path_views).
    def machine_record(url, cookie, hash, foreign, log)
      TCPSocket.open(url.host, url.port) do |io|
        frames = upgrade(io, url, cookie, log)
        io.write(browser_frame(HostlinkGuest.hello(hash)) + browser_frame(HostlinkGuest::OPEN_MACHINE))
        welcome = frames.binary('the welcome')
        fail_with(log, "the welcome is #{welcome.unpack1('H*')}") unless welcome.getbyte(0) == HostlinkGuest::WELCOME
        update = frames.binary("the machine's record")
        fail_with(log, "the machine's record is #{update.unpack1('H*')}") unless
          update.start_with?(HostlinkGuest::MACHINE_UPDATE)
        path_views(io, frames, foreign, log)
        update
      end
    end

    # The upgrade of /ws on io, a connection to the front end at url, with the cookie
    # and the server's origin; the front end's frames once it has answered 101.
    def upgrade(io, url, cookie, log)
      authority = "#{url.host}:#{url.port}"
      io.write("GET /ws HTTP/1.1\r\nHost: #{authority}\r\nOrigin: http://#{authority}\r\nCookie: #{cookie}\r\n" \
               "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" \
               "Sec-WebSocket-Key: #{[SecureRandom.bytes(16)].pack('m0')}\r\n\r\n")
      frames = ServerFrames.new(io, log: log)
      status = frames.head.lines.first.to_s.strip
      fail_with(log, "the upgrade answered #{status.inspect}") unless status.start_with?('HTTP/1.1 101 ')
      frames
    end

    # Views 2, 3 and 4, opened together: root's session's processes, answered with their
    # listing; /proc/kernel, a machine-wide path only scope `all` reaches, answered with
    # its listing; and the record of domain foreign, which ends `scope`. Their answers
    # come in any order. Then view 5 on the first listed process, as its link names it,
    # which is answered with that process's record. A connection's view numbers only
    # grow (erx_web_conn), so the views open in the order of their numbers.
    def path_views(io, frames, foreign, log)
      io.write([open_path(2, ['processes']), open_path(3, ['kernel']), open_path(4, ['domains', foreign.to_s])]
                 .map { browser_frame(_1) }.join)
      answers = Array.new(3) { frames.binary('the path views') }.to_h { |answer| [answer.byteslice(1, 4).unpack1('V'), answer] }
      processes = answers.fetch(2) { fail_with(log, "view 2 was not answered: #{answers.keys}") }
      fail_with(log, "the session's processes are #{processes.byteslice(0, 96).unpack1('H*')}") unless
        processes_page?(processes, 2)
      fail_with(log, "/proc/kernel's record is #{answers[3].to_s.byteslice(0, 96).unpack1('H*')}") unless
        answers[3].to_s.start_with?(record_update(3, ['kernel'], 'listing'))
      fail_with(log, "domain #{foreign}'s record is #{answers[4].to_s.unpack1('H*')}") unless answers[4] == ended_scope(4)
      process_view(io, frames, first_child(processes), log)
    end

    # The text of the first child of the processes listing's update, past the page's
    # count and the child's tag (processes_page?).
    def first_child(update)
      at = processes_update(2).bytesize + 5
      update.byteslice(at + 4, update.byteslice(at, 4).unpack1('V')).to_s
    end

    def process_view(io, frames, pid, log)
      io.write(browser_frame(open_path(5, ['processes', pid])))
      process = frames.binary("process #{LineEscape.escape(pid)}")
      fail_with(log, "process #{LineEscape.escape(pid)}'s record is #{process.byteslice(0, 96).unpack1('H*')}") unless
        process.start_with?(record_update(5, ['processes', pid], 'process'))
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
