# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require_relative 'code_load'
require_relative 'error'
require_relative 'line_escape'

module Erx
  # The SSH route of a load (docs/design-live.md, "One load, three routes"): `tools/erx load
  # --ssh DEST` and `watch --ssh DEST` run the session's `load` on the machine with an SSH
  # exec, `ssh -T DEST load (-s | -d D) -m NAME:BYTES ...`, and write the modules to its
  # standard input one after another. `load`'s exit status is the load's outcome; its
  # standard error, which arrives on ssh's, is printed through the line escape, as
  # everything the tool prints from the target.
  #
  # ssh joins the words after DEST into the one command line the machine's shell reads, so
  # every word the tool puts there is checked first: DEST must not begin with `-`, and follows
  # `--`, so ssh never takes it as an option, and a domain or a module name holds only letters, digits, `_`,
  # `.`, `-` and `@` and does not begin with `-`. The route sends every module of the batch,
  # and gives up after DEADLINE_SECONDS, past the code service's own deadline, saying the
  # load's outcome is unknown.
  module CodeSsh
    DEADLINE_SECONDS = 120
    STOP_GRACE_SECONDS = 10
    WORD = /\A[A-Za-z0-9_.@][A-Za-z0-9_.@-]*\z/

    # The session refused the load, or ssh failed: the status and what reached standard error.
    class Refused < Error; end

    module_function

    # The argument vector of the exec, for target :system or [:domain, D]; raises Error for a
    # word the machine's shell could read as more than one argument.
    def argv(dest:, target:, blobs:)
      ['ssh', '-T', '--', destination(dest), 'load', *target_flags(target),
       *blobs.flat_map { |blob| ['-m', "#{word(blob.name, 'module')}:#{blob.bytes.bytesize}"] }]
    end

    # dest, refused when it is empty or ssh could take it as an option; a board run's ssh
    # calls check theirs here too.
    def destination(dest)
      raise Error, "--ssh #{LineEscape.escape(dest)}: a destination does not begin with '-'" if dest.empty? || dest.start_with?('-')

      dest
    end

    # Loads blobs as one batch over ssh; returns a CodeLoad::Result naming every module as
    # sent. spawn runs an argument vector as Open3.popen3 does; deadline is in seconds.
    def install(dest:, target:, blobs:, spawn: Open3.method(:popen3), deadline: DEADLINE_SECONDS)
      CodeLoad.check_batch(blobs)
      status, errors = run(argv(dest: dest, target: target, blobs: blobs), blobs, spawn: spawn, deadline: deadline)
      unless status.success?
        raise Refused, "loading #{CodeLoad.names(blobs)} over ssh #{LineEscape.escape(dest)}: exit status " \
                       "#{status.exitstatus.inspect}#{shown(errors)}"
      end

      CodeLoad::Result.new(sent: blobs.map(&:name), loaded: blobs.map(&:name))
    end

    def target_flags(target)
      case target
      in :system then ['-s']
      in [:domain, String => domain] then ['-d', word(domain, 'domain')]
      end
    end

    def word(text, what)
      raise Error, "#{what} #{text.inspect} holds a character other than letters, digits, _ . - @ or begins with -" unless
        text.match?(WORD)

      text
    end

    # Runs argv, writing the blobs to its standard input and collecting its standard error,
    # within deadline; the standard output, `load -v`'s lines, is dropped.
    def run(argv, blobs, spawn:, deadline:)
      spawn.call(*argv) do |stdin, stdout, stderr, waiter|
        threads = [Thread.new { write_all(stdin, blobs) }, Thread.new { drain(stdout) }, Thread.new { drain(stderr) }]
        threads.each { |thread| thread.report_on_exception = false }
        unless waiter.join(deadline)
          stop(waiter)
          raise Error, "loading #{CodeLoad.names(blobs)} over ssh: no answer in #{deadline} s; the load's outcome is unknown"
        end
        [waiter.value, threads.map(&:value).last]
      end
    end

    # A stream's bytes until its end; once the process is gone its pipes may close first.
    def drain(io)
      io.read
    rescue IOError
      ''
    end

    # A session that refused before reading closes its input; the rest is not sent.
    def write_all(stdin, blobs)
      blobs.each { |blob| stdin.write(blob.bytes) }
    rescue Errno::EPIPE, IOError
      nil
    ensure
      stdin.close unless stdin.closed?
    end

    # SIGTERM, then SIGKILL STOP_GRACE_SECONDS later, so popen3's own wait for the
    # process always ends.
    def stop(waiter)
      Process.kill('TERM', waiter.pid)
      Process.kill('KILL', waiter.pid) unless waiter.join(STOP_GRACE_SECONDS)
    rescue Errno::ESRCH
      nil
    end

    def shown(errors) = errors.to_s.empty? ? '' : ":\n#{errors.each_line.map { |line| LineEscape.escape(line.chomp) }.join("\n")}"
  end
end
