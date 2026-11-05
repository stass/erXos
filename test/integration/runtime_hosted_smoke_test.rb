# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'pty'
require 'tmpdir'
require 'io/wait'
require_relative '../../tools/lib/erx/runtime'
require_relative '../../tools/lib/erx/runtime_seam'

# ERTS built with ERLANG_OSTYPE=erxos, driven through a terminal as a person would:
# `1>`, an expression, its answer, then halt, over erx_console and erx_stdio.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older
# than the tree, it fails: nothing is skipped.
class RuntimeHostedSmokeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  # A boot to `1>` takes seconds; the budget is the whole dialogue on a loaded host.
  BUDGET_SECONDS = 60
  ESCAPE_SEQUENCE = /\e\[[0-9;?]*[A-Za-z]/n
  GROUP_LINE = /erx: hosted: group: parked (\d+) of (\d+)\n/
  # What an idle sample waits for, and the most an idle runtime may spend, with liberx's
  # reporting thread looking at the status page ten times a second.
  IDLE_SAMPLE_SECONDS = 3
  IDLE_CPU_PERCENT_MAX = 2.0
  DIRTY_DISPATCH_ROUNDS = 20
  # Each makes schedulers sleep and wake in a way of its own, so a lost wake hangs one of
  # them and the budget's deadline ends the test.
  # A typed line can reach the terminal before the last prompt, so an answer need not start a line.
  WAKE_PATTERNS = {
    'P = self(), [spawn(fun() -> P ! ok end) || _ <- lists:seq(1, 20000)], ' \
    '[receive ok -> ok end || _ <- lists:seq(1, 20000)], storm_done.' => /\bstorm_done\n/,
    '[timer:sleep(1) || _ <- lists:seq(1, 200)], sleeps_done.' => /\bsleeps_done\n/,
    'erts_debug:dirty_cpu(scheduler, type).' => /\bdirty_cpu\n/,
    'erts_debug:dirty_io(scheduler, type).' => /\bdirty_io\n/,
    'S = erlang:system_info(schedulers), erlang:system_flag(schedulers_online, 1), ' \
    'erlang:system_flag(schedulers_online, S), online_done.' => /\bonline_done\n/,
    'erlang:system_flag(multi_scheduling, block), erlang:system_flag(multi_scheduling, unblock), ' \
    'blocking_done.' => /\bblocking_done\n/,
    # A timer on every scheduler ends its park during a block of thread progress, so each
    # goes from a returned park to waiting for the block's end.
    'erts_debug:set_internal_state(available_internal_state, true), ' \
    '[spawn_opt(fun() -> receive after 50 -> ok end end, [{scheduler, N}]) || ' \
    'N <- lists:seq(1, erlang:system_info(schedulers))], timer:sleep(10), ' \
    'erts_debug:set_internal_state(block, 200), progress_done.' => /\bprogress_done\n/
  }.freeze
  RUNS_LINE = /erx: hosted: range table: (runs (\d+) high (\d+) of (\d+) committed_pages (\d+))\n/

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_terminal_gets_a_prompt_and_evaluates
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        writer.write("1+1.\n")
        read_until(reader, transcript, /^2\n.*^2> /m, deadline)
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  # ERTS's objects import no other way to get pages, as the seam check below holds
  # them to, and a list that needs more of them commits more on the range table.
  def test_memory_comes_from_the_range_table_and_its_runs_are_reported
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home, 'ERX_HOSTED_VM_RUNS' => '1') do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        at_prompt = plain(transcript).scan(RUNS_LINE)
        report_runs('at 1>', at_prompt)
        writer.write("length(lists:seq(1, 4000000)).\n")
        read_until(reader, transcript, /^4000000\n.*^2> /m, deadline)
        since_prompt = plain(transcript).scan(RUNS_LINE).drop(at_prompt.size)
        report_runs('after a list of 4000000', since_prompt)
        assert_operator since_prompt.map { |line| line.last.to_i }.max, :>, at_prompt.last.last.to_i
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  # Idle means every executor parked and the CPU at rest, and each wake pattern ends with
  # the same sample: what spins or hangs after a lost wake shows in one or the other.
  def test_schedulers_park_at_idle_and_every_wake_arrives
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home, 'ERX_HOSTED_GROUP_REPORT' => '1') do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        writer.write("{erlang:system_info(schedulers), erlang:system_info(dirty_cpu_schedulers)}.\n")
        read_until(reader, transcript, /^\{\d+,\d+\}\n.*^2> /m, deadline)
        schedulers, dirty = plain(transcript)[/^\{(\d+),(\d+)\}\n/, 0].scan(/\d+/).map(&:to_i)
        assert_idle(reader, transcript, pid, schedulers: schedulers, dirty: dirty, moment: 'at the first prompt')
        WAKE_PATTERNS.each do |expression, answer|
          writer.write("#{expression}\n")
          read_until(reader, transcript, answer, deadline)
        end
        assert_idle(reader, transcript, pid, schedulers: schedulers, dirty: dirty, moment: 'after every wake pattern')
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  # The idle check takes the highest parked count of its sample, so one executor awake for
  # a moment passes; this seeds an executor that never parks, which must not.
  def test_a_stuck_executor_fails_the_idle_check
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home, 'ERX_HOSTED_GROUP_REPORT' => '1') do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        writer.write("{erlang:system_info(schedulers), erlang:system_info(dirty_cpu_schedulers)}.\n")
        read_until(reader, transcript, /^\{\d+,\d+\}\n.*^2> /m, deadline)
        schedulers, dirty = plain(transcript)[/^\{(\d+),(\d+)\}\n/, 0].scan(/\d+/).map(&:to_i)
        writer.write("spawn(fun() -> (fun Spin() -> Spin() end)() end), spinning.\n")
        read_until(reader, transcript, /\bspinning\n/, deadline)
        failure = assert_raises(Minitest::Assertion) do
          assert_idle(reader, transcript, pid, schedulers: schedulers, dirty: dirty, moment: 'with an executor spinning')
        end
        assert_match(/Expected: #{schedulers + dirty}\n\s+Actual: #{schedulers + dirty - 1}/, failure.message)
      end
    end
  end

  # With every normal scheduler spinning, the parked executor a keystroke wakes is a dirty CPU
  # scheduler, unless a normal one reaches its safe point first: either delivers the label.
  def test_input_arrives_while_every_normal_scheduler_is_busy
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        writer.write("[spawn(fun() -> (fun Spin() -> Spin() end)() end) || _ <- lists:seq(1, erlang:system_info(schedulers))], spinning.\n")
        read_until(reader, transcript, /\bspinning\n/, deadline)
        DIRTY_DISPATCH_ROUNDS.times do |round|
          writer.write("{round, #{round}}.\n")
          read_until(reader, transcript, /\{round,#{round}\}\n/, deadline)
        end
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  # The events' word protocol over umtx, on the runtime's own libethread and liberx.
  def test_ethread_events_survive_a_storm
    Dir.mktmpdir('erx-event-storm-') do |directory|
      binary = File.join(directory, 'storm')
      internal = File.join(OUTPUT.root, 'erts/lib/internal', Erx::Runtime::TARGET)
      log, status = Open3.capture2e('clang', '-std=c17', '-D__erxos__', '-O1', '-g',
                                    '-I', File.join(OUTPUT.root, 'erts/include/internal'),
                                    '-I', File.join(OUTPUT.root, 'erts/include/internal', Erx::Runtime::TARGET),
                                    '-I', File.join(OUTPUT.root, 'erts/include', Erx::Runtime::TARGET),
                                    '-iquote', ROOT, '-iquote', File.join(ROOT, 'include'),
                                    File.join(ROOT, 'test/fixtures/ethr_event_storm.c'),
                                    File.join(internal, 'libethread.a'), File.join(internal, 'liberts_internal_r.a'),
                                    OUTPUT.liberx, '-o', binary)
      assert status.success?, log
      output, status = Open3.capture2e('gtimeout', '-k', '5', BUDGET_SECONDS.to_s, binary, stdin_data: '')
      assert status.success?, "the storm ended with #{status.inspect}\n#{output}"
      assert_match(/^storm done$/, output)
    end
  end

  def test_the_runtime_links_liberx_and_its_imports_are_on_the_list
    # The makefile names this object after ERLANG_OSTYPE, and only sys/erxos holds its source.
    assert_path_exists File.join(OUTPUT.objects, 'erl_erxos_sys_ddll.o')
    assert(Erx::RuntimeSeam.defined_names(OUTPUT.beam).any? { |name| name.start_with?('erx_') },
           'hosted liberx is in the executable')
    report = Erx::RuntimeSeam.check_objects(objects: Erx::RuntimeSeam.objects(OUTPUT), liberx: OUTPUT.liberx,
                                            executable: OUTPUT.beam, imports_path: File.join(OUTPUT.root, Erx::RuntimeSeam::IMPORTS_FILE))
    assert_empty report.violations.map { |violation| "#{violation.object}: #{violation.name}" }
  end

  # What the runtime answers about its clocks and its start, each from a shell's prompt:
  # both clocks name liberx's calls, CPU time is refused as natively, nothing of the host's
  # environment or zone arrives, and the boot page's node name reached init's arguments.
  def test_time_and_the_boot_page_as_a_shell_sees_them
    expected = {
      'proplists:get_value(function, erlang:system_info(os_monotonic_time_source)).' => /^erx_clock_ns$/,
      'proplists:get_value(function, erlang:system_info(os_system_time_source)).' => /^erx_time_wall_ns$/,
      'catch erlang:statistics(runtime).' => /^\{'EXIT',\{notsup,/,
      'erlang:localtime_to_universaltime({{2026,7,1},{12,0,0}}).' => /^\{\{2026,7,1\},\{12,0,0\}\}$/,
      'os:getenv("ERX_SMOKE_LEAK").' => /^false$/,
      'init:get_argument(sname).' => /^\{ok,\[\["system@erxos"\]\]\}$/,
      "abs(os:system_time(second) - #{Time.now.to_i}) < 300." => /^true$/,
      'file:native_name_encoding().' => /^utf8$/,
      'os:version().' => /^\{0,1,0\}$/,
      'T0 = erlang:monotonic_time(millisecond), timer:sleep(20), erlang:monotonic_time(millisecond) - T0 >= 20.' => /^true$/
    }
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        answers = expected.each_with_index.map do |(expression, _), index|
          writer.write("#{expression}\n")
          read_until(reader, transcript, /^#{index + 2}> /, deadline)
          plain(transcript)[/^#{index + 1}> .*\z/m]
        end
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        @reaped = true if wait_for(pid, deadline, transcript)
        expected.values.zip(answers).each { |pattern, answer| assert_match pattern, answer }
      end
    end
  end

  def test_a_word_the_page_refuses_stops_the_start_with_its_reason
    output, status = Open3.capture2e('gtimeout', '-k', '10', BUDGET_SECONDS.to_s, OUTPUT.beam, OUTPUT.archive, 'word', '',
                                     stdin_data: '')
    assert_equal 1, status.exitstatus, output
    assert_match(/empty word/, output)
  end

  def test_a_start_with_no_archive_stops_with_its_reason
    expected = { [] => /usage: beam ARCHIVE/, ['/nonexistent/system.pack'] => /boot archive refused: unreadable/ }
    expected.each do |arguments, pattern|
      output, status = Open3.capture2e('gtimeout', '-k', '10', BUDGET_SECONDS.to_s, OUTPUT.beam, *arguments, stdin_data: '')
      assert_equal 1, status.exitstatus, output
      assert_match pattern, output
    end
  end

  # The release alone serves init: its arguments are the manifest's, its code and every
  # path answer from the archive, and no host file is in reach. The transcript prints what
  # kernel_sup started and whether a port or a socket module is in use at the prompt.
  def test_init_runs_from_the_archive_alone
    expected = {
      'init:get_argument(root).' => %r{^\{ok,\[\["/"\]\]\}$},
      'init:get_argument(boot).' => %r{^\{ok,\[\["/bin/start"\]\]\}$},
      'init:get_argument(erx).' => /^\{ok,\[\["console_driver","erx_stdio"\]\]\}$/,
      'code:which(lists).' => %r{^"/lib/stdlib-[0-9.]+/ebin/lists\.beam"$},
      'file:read_file_info("/bin/start.boot") =/= {error,enoent}.' => /^true$/,
      'file:read_file("/etc/hosts").' => /^\{error,enoent\}$/,
      'file:write_file("/x", <<>>).' => /^\{error,erofs\}$/,
      'file:list_dir("/").' => /"bin"/,
      'erlang:system_info(emu_flavor).' => /^emu$/,
      '[element(1, C) || C <- supervisor:which_children(kernel_sup)].' => /code_server/,
      'erlang:ports().' => /^\[\]$/,
      'catch open_port({spawn, "ls"}, []).' => /badarg/,
      'catch os:cmd("ls").' => /open_port,badarg/,
      'element(2, os:type()).' => /^erxos$/,
      '{ok, Ram} = file:open(<<"ram">>, [ram, binary, read]), file:read(Ram, 3).' => /^\{ok,<<"ram">>\}$/,
      'catch open_port({fd, 0, 1}, []).' => /badarg/,
      'catch open_port({spawn_driver, "tcp_inet"}, []).' => /badarg/,
      '[code:which(M) || M <- [prim_socket, prim_net, socket_registry]].' => /^\[non_existing,non_existing,non_existing\]$/,
      '[whereis(N) || N <- [heart, socket_registry, erl_epmd, net_kernel, rex]].' => /^\[undefined,undefined,undefined,undefined,undefined\]$/,
      '[M || {M, _} <- code:all_loaded(), lists:member(M, [socket, prim_socket, prim_net, socket_registry, gen_tcp, inet_tcp, heart, erl_epmd])].' => /^\[heart\]$/,
      'inet:getaddr("localhost", inet).' => /^\{ok,\{127,0,0,1\}\}$/,
      'inet:gethostbyname("no.such.name").' => /^\{error,nxdomain\}$/,
      'gen_tcp:listen(0, []).' => /^\{error,eprotonosupport\}$/,
      'gen_udp:open(0, []).' => /^\{error,eprotonosupport\}$/,
      'application:which_applications().' => /kernel/
    }
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        read_until(reader, transcript, /^1> /, deadline)
        answers = expected.each_with_index.map do |(expression, _), index|
          writer.write("#{expression}\n")
          read_until(reader, transcript, /^#{index + 2}> /, deadline)
          plain(transcript)[/^#{index + 1}> .*\z/m]
        end
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        @reaped = true if wait_for(pid, deadline, transcript)
        puts plain(transcript)
        expected.values.zip(answers).each { |pattern, answer| assert_match pattern, answer }
      end
    end
  end

  private

  # Reads for the sample's length, then asks the status page's newest word and the process's CPU time.
  def assert_idle(reader, transcript, pid, schedulers:, dirty:, moment:)
    drain(reader, transcript, 1)
    cpu_before = process_cpu_seconds(pid)
    assert_operator cpu_before, :>, 0, 'ps gives the CPU time a boot spent'
    lines_before = plain(transcript).scan(GROUP_LINE).size
    drain(reader, transcript, IDLE_SAMPLE_SECONDS)
    percent = (process_cpu_seconds(pid) - cpu_before) * 100.0 / IDLE_SAMPLE_SECONDS
    lines = plain(transcript).scan(GROUP_LINE).map { |line| line.map(&:to_i) }
    sampled = lines.drop(lines_before - 1)
    parked = sampled.map(&:first).max
    executors = sampled.last.last
    puts format('idle %s: parked %d of %d executors (%d schedulers, %d dirty CPU), CPU %.2f%%',
                moment, parked, executors, schedulers, dirty, percent)
    assert_equal schedulers + dirty, executors
    assert_equal executors, parked
    assert_operator percent, :<, IDLE_CPU_PERCENT_MAX
  end

  def drain(reader, transcript, seconds)
    finish = monotonic + seconds
    loop do
      left = finish - monotonic
      break if left <= 0

      ready = reader.wait_readable(left)
      transcript << reader.read_nonblock(4096) if ready
    end
  end

  # ps prints minutes:seconds.hundredths, with hours or days in front on a long run.
  def process_cpu_seconds(pid)
    text, = Open3.capture2('ps', '-o', 'time=', '-p', pid.to_s)
    text.strip.split(':').map(&:to_f).reduce(0.0) { |total, part| (total * 60) + part }
  end

  # The newest of the lines hosted liberx prints as the table changes.
  def report_runs(moment, lines)
    refute_empty lines, "no range table line #{moment}"
    summary, runs, high, limit = lines.last
    puts "range table #{moment}: #{summary}"
    assert_operator runs.to_i, :>, 0
    assert_operator high.to_i, :<, limit.to_i
  end

  # The release's manifest holds every argument, and nothing of the host's environment reaches the page.
  def spawn_shell(home, extra_environment = {})
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge(
      'TZ' => 'America/New_York', 'ERX_SMOKE_LEAK' => 'yes', **extra_environment
    )
    PTY.spawn(environment, OUTPUT.beam, OUTPUT.archive, chdir: home) do |reader, writer, pid|
      yield reader, writer, pid
    ensure
      end_if_running(pid)
    end
  end

  # The child leads a session of its own.
  def end_if_running(pid)
    return if @reaped

    begin
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil # A leader that already ended, with nothing left in its group.
    end
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def read_until(reader, transcript, pattern, deadline)
    # A line of liberx's reports can land anywhere in the terminal's output.
    until pattern.match?(plain(transcript).gsub(RUNS_LINE, '').gsub(GROUP_LINE, ''))
      remaining = deadline - monotonic
      flunk("no #{pattern.inspect} within #{BUDGET_SECONDS} s\n#{plain(transcript)}") unless remaining.positive?
      chunk = read_chunk(reader, remaining)
      flunk("the terminal closed before #{pattern.inspect}\n#{plain(transcript)}") if chunk.nil?
      transcript << chunk
    end
  end

  def read_to_end(reader, transcript, deadline)
    while (remaining = deadline - monotonic).positive?
      chunk = read_chunk(reader, remaining)
      return if chunk.nil?

      transcript << chunk
    end
    flunk("the runtime did not close its terminal within #{BUDGET_SECONDS} s\n#{plain(transcript)}")
  end

  # nil at end of input: a closed pty reads as EIO on macOS.
  def read_chunk(reader, seconds)
    return '' unless reader.wait_readable(seconds)

    chunk = reader.read_nonblock(4096, exception: false)
    chunk == :wait_readable ? '' : chunk&.force_encoding(Encoding::BINARY)
  rescue EOFError, Errno::EIO
    nil
  end

  def wait_for(pid, deadline, transcript)
    while monotonic < deadline
      waited = Process.waitpid2(pid, Process::WNOHANG)
      return waited.last if waited

      IO.select(nil, nil, nil, 0.05)
    end
    flunk("the runtime did not exit within #{BUDGET_SECONDS} s\n#{plain(transcript)}")
  end

  def plain(transcript) = transcript.b.gsub(ESCAPE_SEQUENCE, '').delete("\r")
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
