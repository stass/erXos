# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'shellwords'
require_relative 'error'

module Erx
  # QEMU on a second development host (docs/design-build.md, "Placing
  # cells"). Only QEMU runs there: the harness here builds the image, copies
  # the boot's input files into a run directory of their own on that host,
  # starts QEMU there over ssh with its serial line on ssh's standard input
  # and output, and judges the line here as it judges a local boot.
  #
  # ssh hands its command to the remote user's shell, which must be of the
  # Bourne family (sh, bash, zsh), and which must print nothing on standard
  # output for a command it runs; so every remote command
  # is built here from words, each quoted with Shellwords.escape, and fixed
  # operators; and every word that comes from configuration (the destination,
  # the paths) is checked against a plain character set first, so the quoting
  # is never the only defence.
  module QemuRemote
    # The remote host could not be reached, or refused the boot's setup; the
    # boot did not start. The cell is reported as not run (QemuCells.lanes).
    class Unreachable < Error; end

    # Never prompt, never read a password, give up on a dead link, and open
    # nothing but the one session, whatever the user's ssh configuration
    # forwards: no agent, X11 or port forwarding, and no shared connection.
    SSH_OPTIONS = %w[-T -a -x -e none -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=15
                     -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ClearAllForwardings=yes
                     -o ControlMaster=no -o ControlPath=none].freeze
    # user@host or host, as ssh takes it; no leading dash, so never an option.
    DESTINATION = /\A(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z/
    # A remote path: absolute, or relative to the remote home directory, of
    # components that start with no dot or dash, so none is `..` or an option.
    PATH_WORD = %r{\A/?[A-Za-z0-9_][A-Za-z0-9._-]*(?:/[A-Za-z0-9_][A-Za-z0-9._-]*)*\z}
    MAX_PATH_BYTES = 200
    # The remote QEMU's own deadline runs this much past the local one, so the
    # local deadline is the one a slow boot meets, and the remote one ends a
    # QEMU whose harness died without cleaning up.
    REMOTE_DEADLINE_SLACK = 30
    # The names the boot's input files take in its run directory.
    INPUT_NAMES = %w[image initrd dtb].freeze

    # The remote host and what it runs: work_dir holds one directory per
    # boot, program is its QEMU and timeout its GNU timeout.
    Host = Data.define(:destination, :work_dir, :program, :timeout) do
      def initialize(destination:, work_dir: 'erxos-qemu', program: '/usr/local/bin/qemu-system-aarch64',
                     timeout: '/usr/local/bin/gtimeout')
        raise Error, "invalid remote QEMU host #{destination.inspect}" unless destination.is_a?(String) && DESTINATION.match?(destination)

        { 'work directory' => work_dir, 'QEMU' => program, 'timeout program' => timeout }.each do |what, path|
          next if path.is_a?(String) && path.bytesize <= MAX_PATH_BYTES && PATH_WORD.match?(path)

          raise Error, "invalid remote #{what} #{path.inspect}"
        end
        super
      end

      # The process name the remote QEMU runs under, which cleanup checks.
      def program_name = File.basename(program)
    end

    # One boot's remote side: its run directory, named by 16 hex digits under
    # the host's work directory, and the commands that use it. Every method
    # that makes a command returns the local argv of the ssh that runs it.
    class Boot
      RUN_NAME = /\A\h{16}\z/
      attr_reader :host, :directory

      # name is random unless a test fixes it; it is never a path, so cleanup
      # removes nothing but a run directory under the work directory.
      def initialize(host:, name: Random.bytes(8).unpack1('H*'))
        raise Error, 'a remote run directory is named by 16 hex digits' unless name.is_a?(String) && RUN_NAME.match?(name)

        @host = host
        @directory = File.join(host.work_dir, name)
        @prepared = false
      end

      # Whether this boot made its run directory, which cleanup then removes.
      def prepared? = @prepared

      def prepared! = (@prepared = true)

      # Where an input file lands: one of INPUT_NAMES in the run directory.
      def path(name)
        raise Error, "no remote input named #{name.inspect}" unless INPUT_NAMES.include?(name)

        File.join(@directory, name)
      end

      def pidfile = File.join(@directory, 'qemu.pid')

      # The work directory, then the run directory, owner-only; mkdir fails
      # on a run directory that already exists.
      def prepare_argv = ssh(words('mkdir', '-p', '-m', '700', '--', @host.work_dir),
                             '&&', words('mkdir', '-m', '700', '--', @directory))

      # Writes its standard input to the input file name.
      def upload_argv(name) = ssh(words('cat'), '>', words(path(name)))

      # Prints the SHA-256 of the remote QEMU, which names it in reuse keys.
      def digest_argv = ssh(words('shasum', '-a', '256', '--', @host.program))

      def version_argv = ssh(words(@host.program, '--version'))

      # QEMU under the remote timeout, writing its pid where cleanup finds it.
      # qemu_argv is QemuPlan.argv's, naming the remote program and the run
      # directory's files. Every remote command starts in the remote home
      # directory, which a relative work directory is relative to.
      def boot_argv(qemu_argv, deadline:)
        raise Error, 'a remote boot runs the remote host\'s QEMU' unless qemu_argv.first == @host.program

        ssh('exec', words(@host.timeout, '-k', '10', (deadline + REMOTE_DEADLINE_SLACK).to_s, *qemu_argv, '-pidfile', pidfile))
      end

      # Kills the boot's QEMU if it still runs, then removes the run directory.
      # QEMU deletes its pid file when it exits, so a pid file left names a
      # QEMU still running; pkill's pattern also requires the QEMU's process
      # name, so a stale pid names nothing else.
      def cleanup_argv = ssh(words('pkill', '-KILL', '-F', pidfile, '--', @host.program_name), '2>/dev/null', ';',
                             words('rm', '-rf', '--', @directory))

      private

      # Each word quoted for the remote shell, joined by spaces.
      def words(*list)
        raise Error, 'a remote command word is a string without NUL' unless list.all? { |word| word.is_a?(String) && !word.include?("\0") }

        list.map { |word| Shellwords.escape(word) }.join(' ')
      end

      def ssh(*parts) = ['ssh', *SSH_OPTIONS, '--', @host.destination, parts.join(' ')].freeze
    end
  end
end
