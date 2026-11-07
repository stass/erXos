# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'socket'
require 'tmpdir'
require_relative 'code_load'
require_relative 'code_watch'
require_relative 'error'
require_relative 'hostlink_client'

module Erx
  # The host tool's code commands (docs/design-live.md, "Code from the host"):
  #
  #   tools/erx load --socket PATH [--build HEX] [--domain ID] FILE...
  #   tools/erx watch --socket PATH [--build HEX] [--domain ID] [--interval S] DIR
  #
  # load sends FILEs, each a compiled MODULE.beam or an Erlang source it compiles first, as
  # one batch; watch compiles and loads each source of DIR that changes. PATH is the UNIX
  # socket QEMU serves the guest's host link UART on (QemuPlan); HEX, when given, is the
  # build identifier the guest's hello must report. The code service loads only into the
  # system domain, so --domain takes only its id, 4.
  module CodeCommands
    SYSTEM_DOMAIN = 4

    # How a command reaches the guest: socket and build, as the options gave them.
    Target = Data.define(:socket, :build)

    module_function

    # Runs load with arguments; returns the exit status. connect yields a HostlinkClient
    # with an open session for a Target; compile is an ErlangCompile; out prints a line.
    def load(arguments, connect:, compile:, out:)
      target, rest = options(arguments.dup, 'load')
      raise OptionParser::InvalidArgument, 'load names at least one FILE' if rest.empty?

      Dir.mktmpdir('erx-load') do |output|
        beams = rest.map { |file| file.end_with?('.erl') ? compile.call(file, output: output) : file }
        out.call(install(target, beams, connect: connect))
      end
      0
    end

    # Runs watch with arguments until it is stopped, or for rounds scans.
    def watch(arguments, connect:, compile:, out:, sleep: Kernel.method(:sleep), rounds: nil)
      interval = 0.5
      target, rest = options(arguments.dup, 'watch') do |flags|
        flags.on('--interval SECONDS', Float) { |value| interval = value }
      end
      raise OptionParser::InvalidArgument, 'watch names one DIR' unless rest.size == 1
      raise OptionParser::InvalidArgument, '--interval is a positive number of seconds' unless interval.positive?

      CodeWatch.new(compile: compile, load: ->(beams) { install(target, beams, connect: connect) },
                    out: out, interval: interval, sleep: sleep).call(rest.first, rounds: rounds)
      0
    end

    # Loads the module files beams as one batch in a session of their own, so a guest that
    # restarted between two loads of a watch is met with a new hello, though what earlier
    # loads installed is not sent again (TODO.md). Returns the line that reports it.
    def install(target, beams, connect:)
      blobs = beams.map { |path| CodeLoad::Blob.from_file(path) }
      result = connect.call(target) do |client|
        CodeLoad.install(client, facet: CodeLoad.open_install(client), blobs: blobs)
      end
      "loaded #{result.loaded.join(' ')} (sent #{result.sent.size} of #{blobs.size} modules)"
    end

    # The connection the tool uses: QEMU's UNIX socket, a hello, and the session to the block.
    def connect_socket(target)
      UNIXSocket.open(target.socket) do |io|
        client = HostlinkClient.new(io: io, expected_build: target.build)
        client.hello
        yield client
      end
    rescue SystemCallError, IOError => e
      raise Error, "host link socket #{target.socket}: #{e.message}"
    end

    def options(arguments, command)
      socket = nil
      build = nil
      domain = SYSTEM_DOMAIN
      OptionParser.new do |flags|
        flags.on('--socket PATH') { |value| socket = value }
        flags.on('--build HEX', /\A\h+\z/) { |value| build = value.downcase }
        flags.on('--domain ID', Integer) { |value| domain = value }
        yield flags if block_given?
      end.parse!(arguments)
      raise OptionParser::InvalidArgument, "#{command} needs --socket PATH, the guest's host link socket" unless socket
      raise OptionParser::InvalidArgument, "#{command}: the code service loads only into the system domain, #{SYSTEM_DOMAIN}" unless
        domain == SYSTEM_DOMAIN

      [Target.new(socket: socket, build: build), arguments]
    end
  end
end
