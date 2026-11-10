# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'time'
require 'timeout'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'generated'
require_relative 'line_escape'
require_relative 'net_bench'

module Erx
  # The network benchmarks on the FreeBSD test host, p620: erx_net on stock OTP and lwIP,
  # each as a client of a peer in a jail on the same tap's bridge, bulk each way and
  # request-reply, as docs/design-network-fastpath.md's "Benchmarks and targets" states.
  # `tools/erx bench net-p620` stages erx_net's modules (built here, with the host's
  # erlc), its C sources and the lwIP client on p620, builds the C there, runs every
  # workload of NetBench::WORKLOADS on both stacks `runs` times, and prints the table
  # of NetBench::Report with the conditions it ran under. The raw output of every run
  # is kept in the output directory, never in the tree.
  #
  # Everything remote goes through Remote, one ssh command string built from an argument
  # vector, since p620's login shell is tcsh.
  module NetBenchP620
    class RemoteError < Error; end

    # One ssh destination and the one place its command string is built. The remote login
    # shell reads the string, so a command is `sh -c '...'` with its words quoted for sh and
    # the whole in single quotes, which tcsh keeps literal except for `!` and newlines;
    # a command that has either is refused, and so is any word with a control character.
    class Remote
      HOST = /\A[A-Za-z0-9][A-Za-z0-9.-]*\z/
      DEADLINE_GRACE = 10

      def initialize(host:, deadline_tool: 'gtimeout')
        raise ArgumentError, "bad host name: #{host.inspect}" unless HOST.match?(host)

        @host = host
        @deadline_tool = deadline_tool
      end

      attr_reader :host

      # The one string ssh is given for argv.
      def command_string(argv)
        inner = Shellwords.join(argv)
        raise RemoteError, "a remote command may not hold ! or a control character: #{inner.inspect}" if inner.match?(/[!\x00-\x1f\x7f]/)

        "sh -c '#{inner.gsub("'", %q('\\\\''))}'"
      end

      # ssh's argument vector for a remote command that stops after seconds.
      def ssh_argv(argv, seconds:)
        [@deadline_tool, '-k', DEADLINE_GRACE.to_s, seconds.to_s, 'ssh', '-o', 'BatchMode=yes', @host, command_string(argv)]
      end

      # Output (standard output and error together) and status of a remote command.
      def capture(argv, seconds:)
        Open3.capture2e(*ssh_argv(argv, seconds: seconds), stdin_data: '')
      end

      def capture!(argv, seconds:)
        output, status = capture(argv, seconds: seconds)
        raise RemoteError, "#{argv.first(3).join(' ')} failed (#{status.exitstatus}): #{LineEscape.escape(output.byteslice(-400, 400) || output)}" unless status.success?

        output
      end

      # Starts a remote command in the background, its output to the file log; the caller
      # waits for it. Its own remote deadline is what ends it, wherever ssh goes.
      def spawn(argv, seconds:, log:)
        Process.spawn(*ssh_argv(argv, seconds: seconds), in: File::NULL, out: log, err: %i[child out])
      end

      def rsync(source, destination, rsync_path: '/usr/local/bin/rsync')
        _, status = Open3.capture2e('rsync', '-a', '--delete', '-e', 'ssh -o BatchMode=yes', "--rsync-path=#{rsync_path}", "#{source}/",
                                    "#{@host}:#{destination}/", stdin_data: '')
        raise RemoteError, "rsync to #{@host} failed" unless status.success?
      end
    end

    Setup = Data.define(:host, :jail, :tap, :peer_ip, :remote_dir, :lwip_src, :runs)

    DEFAULTS = Setup.new(host: 'p620.seagull-luma.ts.net', jail: 'erxpeer1', tap: '/dev/tap1', peer_ip: '10.77.0.11',
                         remote_dir: 'erx-net-bench', lwip_src: 'lwip-bench/src', runs: 3).freeze

    STACKS = %w[erx_net lwip].freeze
    FIRST_PORT = 5300
    BULK_SECONDS = 150
    PEER_GRACE = 30
    MARKER = '.erx-net-bench'
    PEER_SETTLE = { 'send' => 1.5, 'recv' => 1.5, 'rr' => 5 }.freeze

    # Stages, builds, runs and reports. The tree it stages is the one at root.
    class Runner
      def initialize(root:, setup: DEFAULTS, erlc: nil, output: nil, clock: Time)
        @root = File.realpath(root)
        @setup = setup
        @erlc = erlc || ENV.fetch('ERX_ERLC') { File.join(@root, 'build/oracle/jit/install/bin/erlc') }
        @clock = clock
        @output = output || File.join(@root, 'build/bench', "net-p620-#{clock.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
        @remote = Remote.new(host: setup.host)
        validate(setup)
      end

      # Returns the report's lines; the exit status is the caller's to take from failures.
      Outcome = Data.define(:lines, :failures)

      def call(only: nil, require_fast_path: false)
        FileUtils.mkdir_p(File.join(@output, 'logs'))
        stage
        build
        conditions = gather_conditions(require_fast_path: require_fast_path)
        runs, failures = measure(only: only, require_fast_path: require_fast_path)
        medians = runs.group_by { |run| run.workload.name }.transform_values do |per_workload|
          per_workload.group_by(&:stack).transform_values { |per_stack| NetBench.median(per_stack) }
        end
        lines = NetBench::Report.lines(conditions: conditions, medians: medians, stacks: STACKS, planned: @setup.runs)
        lines += ['', "failed runs: #{failures.length}", *failures.map { |failure| "  #{failure}" }] unless failures.empty?
        File.write(File.join(@output, 'report.txt'), "#{lines.join("\n")}\n")
        File.write(File.join(@output, 'result.json'), JSON.pretty_generate(runs.map { |run| run_record(run) }))
        Outcome.new(lines: [*lines, '', "raw output: #{@output}"], failures: failures)
      end

      private

      def validate(setup)
        { jail: /\A[a-z][a-z0-9]*\z/, tap: %r{\A/dev/tap\d+\z}, peer_ip: /\A\d{1,3}(\.\d{1,3}){3}\z/,
          remote_dir: %r{\A[A-Za-z0-9_][A-Za-z0-9_./-]*\z}, lwip_src: %r{\A[A-Za-z0-9_][A-Za-z0-9_./-]*\z} }.each do |name, shape|
          raise ArgumentError, "bad #{name}: #{setup.public_send(name).inspect}" unless shape.match?(setup.public_send(name))
        end
        raise ArgumentError, "remote_dir may not hold . or .. components: #{setup.remote_dir}" if setup.remote_dir.split('/').any? { |part| part.match?(/\A\.*\z/) }
        raise ArgumentError, 'runs must be odd, 1 to 9' unless setup.runs.odd? && setup.runs.between?(1, 9)
      end

      def home = @home ||= @remote.capture!(%w[printenv HOME], seconds: 30).strip
      def remote_path(*parts) = File.join(home, @setup.remote_dir, *parts)

      # erx_net's modules, the client's and the bench driver compiled with the target
      # build's flags, beside the C sources the host builds and the lwIP client's files.
      def stage
        stage_dir = File.join(@output, 'stage')
        FileUtils.rm_rf(stage_dir)
        apps = File.join(@root, 'erlang/apps')
        compile(File.join(stage_dir, 'erx_net/ebin'), %w[erx_net/src erx_net/portable].flat_map { |dir| Dir[File.join(apps, dir, '**/*.erl')].sort })
        compile(File.join(stage_dir, 'erx_net_client/ebin'), Dir[File.join(apps, 'erx_net_client/src/**/*.erl')].sort,
                pa: [File.join(stage_dir, 'erx_net/ebin')])
        compile(File.join(stage_dir, 'bench'), [File.join(@root, 'bench/erx_net_bench.erl')])
        FileUtils.cp_r(File.join(apps, 'erx_net/c_src'), File.join(stage_dir, 'erx_net/c_src'))
        FileUtils.mkdir_p(File.join(stage_dir, 'lwip'))
        FileUtils.cp(Dir[File.join(@root, 'bench/lwip/*')], File.join(stage_dir, 'lwip'))
        File.write(File.join(stage_dir, MARKER), "staged by tools/erx bench net-p620\n")
        # rsync --delete empties its destination, so only a directory this tool made is synced.
        @remote.capture!(['sh', '-c', %q(if test -e "$0"; then test -f "$0/) + MARKER + %q("; fi), @setup.remote_dir], seconds: 30)
        @remote.rsync(stage_dir, @setup.remote_dir)
      end

      def compile(ebin, sources, pa: [])
        FileUtils.mkdir_p(ebin)
        includes = ['-I', Generated.path('erlang/apps/erx/include', root: @root), '-I', File.join(@root, 'erlang/apps/erx_net/include')]
        output, status = Open3.capture2e(@erlc, *ErlangApps::FLAGS, *includes, *[ebin, *pa].flat_map { |dir| ['-pa', dir] },
                                         '-o', ebin, *sources, stdin_data: '')
        raise RemoteError, "erlc failed: #{output.lines.first(10).join}" unless status.success?
      end

      def build
        @remote.capture!(['make', '-C', remote_path('erx_net/c_src'), "ERL=#{erl}", 'nif', 'tap'], seconds: 300)
        @remote.capture!(['gmake', '-C', remote_path('lwip'), "LWIP=#{lwip_tree('lwip-2.2.1')}",
                          "CONTRIB=#{lwip_tree('contrib-2.1.0')}"], seconds: 300)
      end

      def erl = File.join(home, 'bin/erl')
      def lwip_tree(name) = File.join(home, @setup.lwip_src, name)

      # What the numbers hold under: the remote host's own words, escaped when printed.
      def gather_conditions(require_fast_path:)
        {
          'host' => remote_line(%w[uname -srm]),
          'load before the runs' => remote_line(%w[uptime]),
          'erx_net' => "#{tree_state} on stock OTP #{otp_version}, default flags, no accelerator or QEMU (native)",
          'erx_net build' => "erlc #{Erx::ErlangApps::FLAGS.join(' ')}; C: #{make_variable('erlang/apps/erx_net/c_src/Makefile', 'ERX_CFLAGS')}",
          'lwIP' => "2.2.1 with contrib 2.1.0, raw API, 65535-byte windows; cc: #{remote_line(['sh', '-c', 'cc --version | head -n 1'])}; " \
                    "flags: #{make_variable('bench/lwip/Makefile', 'CFLAGS')}",
          'medium' => "#{@setup.tap}, bridge0, jail #{@setup.jail} at #{@setup.peer_ip}; peers: nc for bulk, stock gen_tcp echo for request-reply",
          'workloads' => NetBench::WORKLOADS.map { |w| "#{w.name} #{w.arguments.join(' ')}" }.join(', '),
          'runs' => "#{@setup.runs} per cell, the median reported; CPU and switches are time -l of the whole client process, startup and the 1 s ARP settle included",
          'client differences' => 'erx_net bulk sends 64 KiB with nodelay; lwIP bulk writes 32 KiB from read-only data with Nagle on',
          'fast-path check' => require_fast_path ? 'required' : 'not required (the counters are not kept yet)'
        }
      end

      def remote_line(argv) = @remote.capture!(argv, seconds: 30).lines.first.to_s.strip

      def otp_version
        remote_line([erl, '-noshell', '-eval', 'io:format("~s (erts ~s)~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().'])
      end

      def tree_state
        head, = Open3.capture2e('git', '-C', @root, 'rev-parse', '--short=12', 'HEAD', stdin_data: '')
        dirty, = Open3.capture2e('git', '-C', @root, 'status', '--porcelain', '--untracked-files=no', stdin_data: '')
        "erXos #{head.strip}#{dirty.strip.empty? ? '' : ' (uncommitted changes)'}"
      end

      def make_variable(path, name)
        File.read(File.join(@root, path))[/^#{name} = (.*)$/, 1].to_s
      end

      # Every cell of the matrix, @setup.runs times, in the order a person reads the table.
      def measure(only:, require_fast_path:)
        runs = []
        failures = []
        cells = NetBench::WORKLOADS.select { |w| only.nil? || only.include?(w.name) }.product(STACKS).flat_map { |workload, stack| Array.new(@setup.runs) { |index| [workload, stack, index] } }
        cells.each_with_index do |(workload, stack, index), number|
          runs << one_run(workload: workload, stack: stack, index: index, port: FIRST_PORT + number,
                          require_fast_path: require_fast_path)
        rescue Error => e
          failures << "#{stack} #{workload.name} run #{index + 1}: #{LineEscape.escape(e.message)}"
        end
        [runs, failures]
      end

      def one_run(workload:, stack:, index:, port:, require_fast_path:)
        log = File.join(@output, 'logs', "#{stack}-#{workload.name}-#{index + 1}")
        peer = @remote.spawn(peer_argv(workload, port), seconds: peer_seconds(workload), log: "#{log}.peer")
        sleep(PEER_SETTLE.fetch(workload.mode))
        output, status = @remote.capture(client_argv(stack, workload, port), seconds: client_seconds(workload))
        File.write("#{log}.client", output)
        finish_peer(peer, abandon: !status.success? || workload.mode == 'rr')
        peer = nil
        raise RemoteError, "client exited #{status.exitstatus}" unless status.success?

        result, counters = NetBench::Output.parse(output)
        NetBench::Output.validate(result, workload.mode)
        failure = stack == 'erx_net' && require_fast_path && NetBench::Counters.fast_path_failure(workload.mode, counters)
        raise NetBench::CounterError, failure if failure

        NetBench::Run.new(stack: stack, workload: workload, result: result, counters: counters,
                          rusage: NetBench::TimeReport.parse(output))
      ensure
        # An interrupt or an unexpected error must not leave the peer's ssh behind.
        stop_peer(peer) if peer
      end

      def stop_peer(pid)
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def peer_seconds(workload) = workload.mode == 'rr' ? rr_seconds(workload) + 30 : BULK_SECONDS + 20
      def client_seconds(workload) = workload.mode == 'rr' ? rr_seconds(workload) + 20 : BULK_SECONDS
      def rr_seconds(workload) = Integer(workload.arguments.last)

      # A bulk peer ends with the client's end of stream. A request-reply echo server runs on a
      # timer and a failed client's peer is useless, so those are stopped; the remote deadline
      # is the guarantee that nothing stays on the host.
      def finish_peer(pid, abandon:)
        Process.kill('TERM', pid) if abandon
        Timeout.timeout(PEER_GRACE) { Process.wait(pid) }
      rescue Timeout::Error
        Process.kill('TERM', pid)
        Process.wait(pid)
      end

      def peer_argv(workload, port)
        in_jail = ['sudo', '-n', 'jexec', '-U', login, @setup.jail]
        deadline = peer_seconds(workload).to_s
        case workload.mode
        when 'send'
          [*in_jail, 'sh', '-c', "timeout -k 2 #{deadline} nc -l #{@setup.peer_ip} #{port} > /dev/null"]
        when 'recv'
          [*in_jail, 'sh', '-c', "dd if=/dev/zero bs=1m count=#{Integer(workload.arguments.first)} 2>/dev/null | " \
                                "timeout -k 2 #{deadline} nc -N -l #{@setup.peer_ip} #{port}"]
        else
          [*in_jail, 'timeout', '-k', '2', deadline, erl, '-noshell', '-pa', remote_path('bench'), '-run', 'erx_net_bench',
           'main', 'echo', @setup.peer_ip, port.to_s, (rr_seconds(workload) + 20).to_s]
        end
      end

      def login = @login ||= @remote.capture!(%w[id -un], seconds: 30).strip

      def client_argv(stack, workload, port)
        ['/usr/bin/time', '-l', 'timeout', '-k', '5', client_seconds(workload).to_s, *client_command(stack, workload, port)]
      end

      def client_command(stack, workload, port)
        arguments = [@setup.peer_ip, port.to_s, *workload.arguments]
        if stack == 'lwip'
          ['env', 'PRECONFIGURED_TAPIF=1', "TAPDEV=#{@setup.tap}", remote_path('lwip/lwip_bench'), workload.mode, *arguments]
        else
          [erl, '-noshell', '-pa', remote_path('erx_net/ebin'), '-pa', remote_path('erx_net_client/ebin'),
           '-pa', remote_path('bench'), '-run', 'erx_net_bench', 'main', workload.mode, @setup.tap, *arguments]
        end
      end

      def run_record(run)
        { 'stack' => run.stack, 'workload' => run.workload.name, 'result' => run.result, 'counters' => run.counters,
          'rusage' => run.rusage.to_h }
      end
    end
  end
end
