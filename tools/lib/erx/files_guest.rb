# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'rbconfig'
require 'socket'
require_relative 'error'
require_relative 'line_escape'
require_relative 'ninep_client'

module Erx
  # M4's files exit criterion against a booted guest (docs/plan.md, M4: "a file read
  # through `tools/erx files` equals its source on the machine"): the guest boots with an
  # -eval (START) that writes a file of known bytes into /tmp, reads it back and prints
  # its MD5; the host runs `tools/erx files --once` on the guest's host link socket, reads
  # the file through it with NinepClient over 9P2000.L, and compares it byte for byte
  # with the bytes it expects and with the guest's MD5. The guest's host link lists /tmp's
  # tree, `tmp`, among its files trees for this boot (ARGUMENTS), as a development build
  # lists `proc` and `data`.
  module FilesGuest
    SECONDS = 180
    BYTES = 100_000
    # One word each, without spaces or quotes, as the kernel command line carries them.
    START = 'spawn(fun()->P=filename:join([[47],tmp,files_probe]),' \
            'ok=file:write_file(P,[(N*7)rem(256)||N<-lists:seq(1,100000)]),{ok,R}=file:read_file(P),' \
            'io:put_chars([atom_to_list(files_probe_md5),32,binary:encode_hex(erlang:md5(R)),10])end).'
    ARGUMENTS = ['-eval', START, '-erx_hostlink', 'files_trees', '[tmp]'].freeze
    PROBED = /files_probe_md5 (\h{32})/

    module_function

    # The kernel command line words that pass ARGUMENTS to the system domain's runtime.
    def command_line = ARGUMENTS.map { |word| "erx.arg=#{word}" }.join(' ')

    def expected = Array.new(BYTES) { |index| ((index + 1) * 7) % 256 }.pack('C*')

    # Runs the check against the guest whose host link socket is socket and whose console
    # transcript is serial; root is the tree whose tools/erx runs the relay. Returns what
    # was compared.
    def call(socket, root:, build:, serial:)
      guest_md5 = wait_for(serial, PROBED).captures.first.downcase
      listen = File.join(File.dirname(socket), 'files.sock')
      log = File.join(File.dirname(socket), 'files-relay.log')
      relay = Process.spawn(RbConfig.ruby, File.join(root, 'tools/erx'), 'files', '--socket', socket,
                            '--listen', listen, '--build', build, '--once', in: :close, %i[out err] => [log, 'w'])
      begin
        contents = read_through(listen, log)
      ensure
        stop(relay)
      end
      compare(contents, guest_md5)
    end

    def read_through(listen, log)
      limit = now + 60
      sleep(0.1) until File.socket?(listen) || now > limit
      raise Error, "tools/erx files did not listen: #{LineEscape.escape(File.read(log))}" unless File.socket?(listen)

      UNIXSocket.open(listen) do |io|
        client = NinepClient.new(io: io, deadline: 30)
        client.version
        client.read_file('tmp', ['files_probe'])
      end
    end

    def compare(contents, guest_md5)
      raise Error, "read #{contents.bytesize} bytes through tools/erx files, not #{BYTES}" unless contents.bytesize == BYTES
      raise Error, 'the bytes read through tools/erx files are not the bytes the guest wrote' unless contents == expected

      host_md5 = Digest::MD5.hexdigest(contents)
      raise Error, "the guest read MD5 #{guest_md5}, the host #{host_md5}" unless host_md5 == guest_md5

      { bytes: contents.bytesize, md5: host_md5 }
    end

    def stop(pid)
      limit = now + 30
      until now > limit
        return if Process.wait(pid, Process::WNOHANG)

        sleep(0.1)
      end
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ECHILD, Errno::ESRCH
      nil
    end

    # The first match of pattern in the transcript at serial within SECONDS; the transcript
    # is the guest's, so nothing of it is shown unescaped.
    def wait_for(serial, pattern)
      limit = now + SECONDS
      loop do
        text = File.file?(serial) ? File.binread(serial) : ''
        match = pattern.match(text)
        return match if match
        raise Error, "files probe: no line matching #{pattern.source} within #{SECONDS} s" if now >= limit

        sleep(0.2)
      end
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
