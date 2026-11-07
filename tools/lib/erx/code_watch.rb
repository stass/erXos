# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'bounded_file'
require_relative 'code_load'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'oracle'
require_relative 'runner'
require_relative 'runtime'

module Erx
  # Compiling Erlang on the host for the running system (docs/design-live.md, "Code from
  # the host"). The target runs OTP 29.1.2, and the image's own applications are compiled
  # by the stock oracle's erlc of that release (Runtime#build_erlang_apps), so a module
  # sent from the host is compiled by the same erlc, with the same include directories
  # and the same clean environment. It keeps the image's +deterministic and +debug_info
  # but not its -Werror, so a warning in a module under development does not stop a load.
  # +deterministic keeps a module's bytes, and so its hash, the same from one compile to
  # the next, so an unchanged module costs no transfer.
  class ErlangCompile
    FLAGS = %w[+deterministic +debug_info].freeze
    DEADLINE = 120
    REPORT_MAX = 65_536

    # The compiler for the tree at root: the oracle's erlc, which `make oracle-bootstrap`
    # builds, run under a Runner logging to root's build/logs.
    def self.for_tree(root:)
      erlc = File.join(File.dirname(Oracle.new(root: root).erl_path(Runtime::HOST_OTP_FLAVOUR)), 'erlc')
      raise Error, "no erlc at #{erlc}: run make oracle-bootstrap" unless File.executable?(erlc)

      new(erlc: erlc, root: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')))
    end

    def initialize(erlc:, root:, runner:)
      @erlc = erlc
      @root = root
      @runner = runner
    end

    # The argument vector that compiles source into the directory output.
    def argv(source, output:) =
      [@erlc, *FLAGS, *ErlangApps.include_flags(root: @root), '-o', File.expand_path(output), File.expand_path(source)]

    # Compiles source into the directory output and returns the module's file there;
    # raises Erx::Error with erlc's own report when the compile fails or passes its
    # deadline. OTP's clean environment means no ERL_COMPILER_OPTIONS or ERL_LIBS of the
    # user's changes the bytes loaded.
    def call(source, output:)
      @runner.run(argv(source, output: output), name: 'erlc', deadline: DEADLINE, chdir: @root, env: Oracle::CLEAN_ERLANG_ENV)
      File.join(output, "#{File.basename(source, '.erl')}.beam")
    rescue CommandError => e
      raise Error, "erlc #{source} #{e.result.fetch('state')}:\n#{BoundedFile.read(e.result.fetch('log'), maximum: REPORT_MAX)}"
    end
  end

  # `tools/erx watch DIR`: polls the modification times of DIR's Erlang sources, and for
  # each source that is new or changed since the last scan compiles it and loads it into
  # the system domain. Polling is portable and needs no dependency; a scan of a source tree
  # every half second costs little beside a compile.
  class CodeWatch
    # A source's state as a scan sees it: its modification time and size.
    Stamp = Data.define(:mtime, :size)

    module Scan
      module_function

      # Every Erlang source under dir, with its stamp. A source that vanishes between the
      # listing and its stat, or a dangling link, is left out: it has nothing to compile.
      def call(dir)
        Dir.glob('**/*.erl', base: dir).sort.filter_map do |path|
          full = File.join(dir, path)
          stat = File.stat(full)
          [full, Stamp.new(mtime: stat.mtime, size: stat.size)]
        rescue Errno::ENOENT
          nil
        end.to_h
      end

      # The sources of after that before lacks or stamps differently, in path order.
      def changed(before, after) = after.reject { |path, stamp| before[path] == stamp }.keys
    end

    # compile is an ErlangCompile; load takes a list of module files and loads them as one
    # batch; out prints a line; sleep waits seconds.
    def initialize(compile:, load:, out:, interval: 0.5, sleep: Kernel.method(:sleep))
      @compile = compile
      @load = load
      @out = out
      @interval = interval
      @sleep = sleep
    end

    # Watches dir until rounds scans have passed, forever when rounds is nil. The first
    # scan loads nothing: the sources as they stand are taken as what is loaded. A source
    # stays pending from its change until a load of it succeeds, so a round that failed,
    # on another source's compile error or a guest that was restarting, is tried again,
    # whole, at the next change.
    def call(dir, rounds: nil)
      raise Error, "#{dir} is not a directory" unless File.directory?(dir)

      seen = Scan.call(dir)
      pending = []
      @out.call("watching #{seen.size} sources under #{dir}")
      scans = 0
      while rounds.nil? || scans < rounds
        @sleep.call(@interval)
        scans += 1
        now = Scan.call(dir)
        changed = Scan.changed(seen, now)
        seen = now
        next if changed.empty?

        pending = ((pending & now.keys) | changed).sort
        pending = [] if reload(pending)
      end
    end

    private

    # Compiles sources into a fresh directory and loads them as one batch, so modules
    # changed together become current together. Returns whether the load succeeded; a
    # compile or load that fails is reported and the watch goes on.
    def reload(sources)
      Dir.mktmpdir('erx-watch') do |output|
        beams = sources.map { |source| @compile.call(source, output: output) }
        @out.call(@load.call(beams))
      end
      true
    rescue Error => e
      e.message.each_line { |line| @out.call(line.chomp) }
      false
    end
  end
end
