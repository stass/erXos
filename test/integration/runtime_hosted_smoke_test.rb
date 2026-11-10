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
require_relative '../../tools/lib/erx/medium_boot'
require_relative '../fixtures/generated_tree'

# ERTS built with ERLANG_OSTYPE=erxos, driven through a terminal as a person would:
# the command shell, `erl`, `1>`, an expression, its answer, then halt, over erx_console
# and erx_stdio.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime. With no runtime, or one older
# than the tree, it fails: nothing is skipped.
class RuntimeHostedSmokeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  # A boot to `1>` takes seconds; the budget is the whole dialogue on a loaded host.
  BUDGET_SECONDS = 60
  # The Erlang shell prompt's node name, (system@erxos), before its count.
  PROMPT = '(?:\(\S+\))?'
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
        erlang_shell(reader, writer, transcript, deadline)
        writer.write("1+1.\n")
        read_until(reader, transcript, /^2\n.*^#{PROMPT}2> /m, deadline)
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
        erlang_shell(reader, writer, transcript, deadline)
        at_prompt = plain(transcript).scan(RUNS_LINE)
        report_runs('at 1>', at_prompt)
        writer.write("length(lists:seq(1, 4000000)).\n")
        read_until(reader, transcript, /^4000000\n.*^#{PROMPT}2> /m, deadline)
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
        erlang_shell(reader, writer, transcript, deadline)
        writer.write("{erlang:system_info(schedulers), erlang:system_info(dirty_cpu_schedulers)}.\n")
        read_until(reader, transcript, /^\{\d+,\d+\}\n.*^#{PROMPT}2> /m, deadline)
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
        erlang_shell(reader, writer, transcript, deadline)
        writer.write("{erlang:system_info(schedulers), erlang:system_info(dirty_cpu_schedulers)}.\n")
        read_until(reader, transcript, /^\{\d+,\d+\}\n.*^#{PROMPT}2> /m, deadline)
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
        erlang_shell(reader, writer, transcript, deadline)
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
                                    '-iquote', File.join(ROOT, Erx::Generated::OUTPUT),
                                    '-iquote', Erx::Generated.path('include', root: ROOT),
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
    assert_answers(expected)
  end

  # No lookup runs, so a well-formed one is unsupported, where stock answers notfound for a
  # name its resolver does not know. inet reads any error as not found, as with stock's. The
  # node must live through all of them: a stopped runtime is the machine.
  def test_a_native_lookup_answers_unsupported_and_inet_answers_as_stock_does
    assert_answers(
      'inet_gethost_native:gethostbyname("nosuch.invalid").' => /^\{error,notsup\}$/,
      'inet_gethost_native:gethostbyname("nosuch.invalid", inet6).' => /^\{error,notsup\}$/,
      'inet_gethost_native:gethostbyaddr("192.0.2.1").' => /^\{error,notsup\}$/,
      'inet_db:set_lookup([native]).' => /^ok$/,
      'inet:gethostbyname("nosuch.invalid").' => /^\{error,nxdomain\}$/,
      'inet:gethostbyaddr("192.0.2.1").' => /^\{error,nxdomain\}$/,
      'inet_db:set_lookup([file]).' => /^ok$/,
      'inet_gethost_native:gethostbyaddr("x").' => /^\{error,formerr\}$/,
      'inet_gethost_native:gethostbyname(1, inet).' => /^\{error,formerr\}$/,
      'inet_gethost_native:control(soft_restart).' => /^ok$/,
      'inet_gethost_native:control(foo).' => /^\{error,formerr\}$/,
      'inet_db:set_lookup([native]), inet:gethostbyname("nosuch.invalid").' => /^\{error,nxdomain\}$/,
      'inet:getaddr("nosuch.invalid", inet).' => /^\{error,nxdomain\}$/,
      'inet:gethostbyaddr({192,0,2,1}).' => /^\{error,nxdomain\}$/
    )
  end

  # The release loads compiler and runtime_tools without starting them
  # (docs/design-runtime.md), so the shell compiles and traces while nothing of either runs.
  def test_the_shell_compiles_and_traces_with_neither_application_started
    assert_answers(
      '[lists:keymember(A, 1, application:which_applications()) || A <- [compiler, runtime_tools]].' => /^\[false,false\]$/,
      '[lists:keymember(A, 1, application:loaded_applications()) || A <- [compiler, runtime_tools]].' => /^\[true,true\]$/,
      'whereis(runtime_tools_sup).' => /^undefined$/,
      '{ok, Mod, Bin} = compile:forms([{attribute, 1, module, erx_probe}, {attribute, 1, export, [{f, 0}]}, ' \
      '{function, 1, f, 0, [{clause, 1, [], [], [{atom, 1, compiled}]}]}]), ' \
      'code:load_binary(Mod, "erx_probe", Bin), erx_probe:f().' => /^compiled$/,
      'code:which(dbg).' => %r{^"/lib/runtime_tools-[0-9.]+/ebin/dbg\.beam"$},
      '{ok, _} = dbg:tracer(), ok = dbg:stop(), dbg_done.' => /^dbg_done$/
    )
  end

  # erx_trace_ring's BIFs over the hosted backend's ring (docs/design-live.md, "Tracing"):
  # the clock pair, a read from the present that later finds the executors' parks and
  # wakes, each marked cpu_unknown with thread and space 0 (a host thread has neither),
  # the kernel's row refused as unsupported, a cursor past the head refused as inval, and badarg for a cursor of 2^64 - 1 or more, a Max
  # outside 1 to 512 and an unknown source. Then erx:trace/1 itself: its refusals, a
  # kernel trace that prints the kernel row unsupported and the backend's events, and a
  # trace of the shell's own process that prints its in and out.
  def test_the_trace_ring_bifs_and_erx_trace_run_in_the_release
    assert_answers(
      '{Mono, Clock} = erx_trace_ring:clocks(), {is_integer(Mono), is_integer(Clock) andalso Clock > 0}.' =>
        /^\{true,true\}$/,
      '[{cpu_unknown, Unknown}] = erx_abi_events:flags(trace_record_flags), ' \
      '{ok, [], Head, 0} = erx_trace_ring:read(backend, present, 512), timer:sleep(200), ' \
      '{ok, Records, Next, 0} = erx_trace_ring:read(backend, Head, 512), ' \
      '{Records =/= [], Next =:= Head + length(Records), lists:all(fun({T, E, _, F, Th, Sp, {_, _, _}}) -> ' \
      'T > 0 andalso E >= 1 andalso E =< 5 andalso F band Unknown =/= 0 andalso Th =:= 0 andalso Sp =:= 0 end, Records)}.' =>
        /^\{true,true,true\}$/,
      '{erx_trace_ring:read({kernel, 0}, present, 1), erx_trace_ring:read(backend, 1 bsl 64 - 2, 1)}.' =>
        /^\{\{error,unsupported\},\{error,inval\}\}$/,
      '[element(1, element(2, catch erx_trace_ring:read(S, C, M))) || {S, C, M} <- [{backend, 1 bsl 64 - 1, 1}, ' \
      '{backend, 1 bsl 64, 1}, {backend, -1, 1}, {backend, present, 0}, {backend, present, 513}, {nope, present, 1}, ' \
      '{{kernel, -1}, present, 1}]].' => /^\[badarg,badarg,badarg,badarg,badarg,badarg,badarg\]$/,
      '{erx:trace(#{}), erx:trace(#{select => lists:duplicate(17, 4)}), erx:trace(#{select => [5]}), ' \
      'erx:trace(#{select => [4], colour => red}), erx:trace(#{frames => true, kernel => true})}.' =>
        /^\{\{error,badarg\},\s*\{error,badarg\},\s*\{error,scope\},\s*\{error,badarg\},\s*\{error,badarg\}\}$/,
      '{ok, K} = erx:trace(#{kernel => true}), timer:sleep(300), erx:trace_stop(K), timer:sleep(100), kernel_done.' =>
        /^ *\d+\.\d{9} kernel unsupported \[kernel\]$.*^ *\d+\.\d{9} backend (?:park|wake) \S+=\S+ slot=\d+ cpu=unknown thread=\d+ space=\d+ \[liberx trace\]$.*^kernel_done$/m,
      '{ok, S} = erx:trace(#{select => [self()]}), timer:sleep(50), erx:trace_stop(S), timer:sleep(100), self_done.' =>
        /^ *\d+\.\d{9} erts (?:in|out) pid=<[0-9.]+> domain=4 mfa=.* \[runtime\]$.*^self_done$/m,
      # The spawn option {erx_untraced, true} (OTP edit 52): a session over every process,
      # opened before the spawn, with call tracing of timer:sleep/1, sees a process spawned
      # without it run ({in, ...}) and call ({call, ...}), and one spawned with it do neither;
      # unlike sensitive, the option hides nothing from process_info.
      'Seen = fun(Opts) -> Col = spawn(fun() -> receive {go, Fr, Pr} -> timer:sleep(100), ' \
      'Tags = [T || {trace, Qr, T, _} <- element(2, process_info(self(), messages)), Qr =:= Pr], ' \
      'Fr ! {seen, {lists:member(in, Tags), lists:member(call, Tags)}} end end), ' \
      'Ses = trace:session_create(untraced_test, Col, []), trace:process(Ses, all, true, [running, call]), ' \
      'trace:function(Ses, {timer, sleep, 1}, true, []), ' \
      'Pr = spawn_opt(fun() -> timer:sleep(10) end, Opts), Col ! {go, self(), Pr}, ' \
      'receive {seen, Bo} -> trace:session_destroy(Ses), Bo end end, ' \
      'Un = spawn_opt(fun() -> receive stop -> ok end end, [{erx_untraced, true}]), Un ! hello, ' \
      '{messages, Ms} = process_info(Un, messages), Un ! stop, ' \
      '{Seen([]), Seen([{erx_untraced, true}]), Ms}.' =>
        /^\{\{true,true\},\{false,false\},\[hello\]\}$/,
      # It holds against a session opened after the spawn on the untraced pid itself, after
      # that process turns sensitive on and off, and against a parent's set_on_spawn: of
      # the untraced process, the untraced child and the plain parent, only the parent runs
      # in the session's view.
      'Col2 = spawn(fun() -> receive {go2, F2, Ps} -> timer:sleep(100), F2 ! {seen2, lists:usort(' \
      '[Q || {trace, Q, _, _} <- element(2, process_info(self(), messages)), lists:member(Q, Ps)])} end end), ' \
      'Me = self(), Un2 = spawn_opt(fun() -> receive go -> process_flag(sensitive, true), ' \
      'process_flag(sensitive, false), timer:sleep(10) end end, [{erx_untraced, true}]), ' \
      'Par = spawn(fun() -> receive go -> Me ! {child, spawn_opt(fun() -> timer:sleep(10) end, ' \
      '[{erx_untraced, true}])}, timer:sleep(10) end end), S2 = trace:session_create(untraced_later, Col2, []), ' \
      'trace:process(S2, Un2, true, [running]), trace:process(S2, Par, true, [running, set_on_spawn]), ' \
      'Un2 ! go, Par ! go, Ch = receive {child, Cx} -> Cx end, Col2 ! {go2, self(), [Un2, Ch, Par]}, ' \
      'receive {seen2, Qs} -> trace:session_destroy(S2), Qs =:= [Par] end.' => /^true$/,
      # Two traces of every process at once, each printing what feeds the other and
      # itself, end when stopped: the window bounds what each has out.
      '{ok, TA} = erx:trace(#{select => [4]}), {ok, TB} = erx:trace(#{select => [4]}), timer:sleep(300), ' \
      'erx:trace_stop(TA), erx:trace_stop(TB), timer:sleep(300), both_done.' => /^both_done$/
    )
  end

  # The CRC-32C per-byte primitive, a static NIF, runs in the release: the same expression
  # and answer as the boot from a release medium (Erx::MediumBoot::CRC32C_EXPRESSION). There
  # the expression follows another that binds shell variables, so here the shell holds
  # bindings first, and the expression must answer whatever names they use.
  def test_the_crc32c_primitive_runs_in_the_release
    assert_answers(
      'A = 1, B = <<"bound">>, D = 2, Data = 3, Head = 4, Tail = 5, bound.' => /^bound$/,
      Erx::MediumBoot::CRC32C_EXPRESSION => /^#{Regexp.escape(Erx::MediumBoot::CRC32C_ANSWER)}$/
    )
  end

  # The SHA-256 per-byte primitive runs in the release and agrees with the oracle: the probe
  # (test/fixtures/erx_sha256_probe.erl) digests its messages on stock OTP with crypto:hash/2,
  # then checks erx_bytes's calls against those digests and FIPS 180-4's examples, over random
  # cuts and reused states, and their refusals; the answer is all empty lists only if each
  # check passed.
  def test_the_sha256_primitive_runs_in_the_release_and_agrees_with_the_oracle
    Dir.mktmpdir('erx-hosted-sha256-') do |directory|
      probe = compiled_fixture('erx_sha256_probe', directory)
      digests = oracle_sha256_digests(directory)
      assert_equal 15, digests.size
      assert_answers(
        "{module, erx_sha256_probe} = code:load_binary(erx_sha256_probe, \"probe\", base64:decode(\"#{probe}\")), " \
        'loaded.' => /^loaded$/,
        "erx_sha256_probe:check([#{digests.map { |digest| "<<\"#{digest}\">>" }.join(',')}])." =>
          /^\{sha256,\[\],\[\],\[\],\[\]\}$/
      )
    end
  end

  # The network stack's per-byte primitives run in the release and agree with the host
  # stand-in's models: the probe (test/fixtures/erx_net_bytes_probe.erl) answers its calls on
  # stock OTP with test/erlang/host_bytes/erx_bytes.erl, then checks the BIFs' answers to the
  # same calls against those, over iolists that nest binaries at odd and even offsets, and
  # every refusal and acceptance of the contract
  # against its literal answer; the answer is empty lists only if each check passed.
  def test_the_network_primitives_run_in_the_release_and_agree_with_the_models
    Dir.mktmpdir('erx-hosted-net-bytes-') do |directory|
      probe = compiled_fixture('erx_net_bytes_probe', directory)
      answers = stand_in_net_bytes_answers(directory)
      assert_answers(
        "{module, erx_net_bytes_probe} = code:load_binary(erx_net_bytes_probe, \"probe\", base64:decode(\"#{probe}\")), " \
        'loaded.' => /^loaded$/,
        "erx_net_bytes_probe:check(#{answers})." => /^\{net_bytes,\[\],\[\]\}$/
      )
    end
  end

  # A failed read of the entropy entry raises {entropy, Status} and returns no bytes
  # (docs/design-runtime.md, "Per-byte primitives", the entropy entry): with
  # ERX_HOSTED_ENTROPY_FAIL=1 the hosted backend lets the boot's one read, the reference key's,
  # through and refuses every later erx_entropy_read with ERX_ENOTSUP, as the native backend
  # does when it cannot reach its generator service.
  def test_a_failed_entropy_read_raises
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home, 'ERX_HOSTED_ENTROPY_FAIL' => '1') do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        erlang_shell(reader, writer, transcript, deadline)
        writer.write("try erx_bytes:entropy(16) catch error:Reason -> Reason end.\n")
        read_until(reader, transcript, /^\{entropy,notsup\}\n.*^#{PROMPT}2> /m, deadline)
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        status = wait_for(pid, deadline, transcript)
        @reaped = true
        assert status.success?, "the runtime ended with #{status.inspect}\n#{plain(transcript)}"
      end
    end
  end

  # M4's exit criterion "a module reloaded in a loop on four CPUs never runs stale code",
  # through the release's code service: the probe (test/fixtures/erx_code_reload_probe.erl)
  # loads 1,000 versions of a module through erx_code, one after another, while a caller on
  # each of four schedulers calls it, and counts the calls that returned a version older
  # than the last load that had returned before the call began. The answer names the
  # schedulers online, the loads, the stale calls, the callers that ran to the end, whether
  # each made more calls than there were loads, and the version current at the end.
  def test_a_module_reloaded_in_a_loop_on_four_schedulers_never_runs_stale_code
    Dir.mktmpdir('erx-hosted-reload-') do |directory|
      probe = compiled_fixture('erx_code_reload_probe', directory)
      assert_answers(
        'is_pid(whereis(erx_code)) andalso erlang:system_info(schedulers_online) >= 4.' => /^true$/,
        "{module, erx_code_reload_probe} = code:load_binary(erx_code_reload_probe, \"probe\", " \
        "base64:decode(\"#{probe}\")), loaded." => /^loaded$/,
        'erx_code_reload_probe:run(1000).' => /^\{reload,\d+,1000,0,4,true,1000\}$/
      )
    end
  end

  # Stock's code server dies on a root directory in its path, with no version to split from
  # its empty base name, and three of those stop the node. Here the working directory is "/".
  def test_the_root_directory_on_the_code_path_leaves_the_code_server_running
    assert_answers(
      'code:set_path(["/" | code:get_path()]).' => /^true$/,
      'is_pid(whereis(code_server)).' => /^true$/,
      'code:del_path("/").' => /^true$/
    )
  end

  # The oracle runs with ROOTDIR=/, where the library directory is "/lib": "//lib" would put
  # every application there on the path a second time beside a -pa for it, and code_SUITE
  # compares the path with what code:set_path/1 gives back, which is normalized.
  def test_the_library_directory_of_a_root_of_slash_is_in_its_normal_form
    assert_answers({ "code:lib_dir()." => %r{^"/lib"$},
                     "[D || D <- code:get_path(), D =/= filename:join([D])]." => /^\[\]$/ },
                   { "ROOTDIR" => "/" })
  end

  # process_SUITE's spawn_request_link_parent_exit fills ETS tables to a peak of 1.6 GB on stock
  # OTP. Rows this size come from the pool's carriers, where a single huge binary would not.
  def test_a_workload_of_more_than_a_gigabyte_fits_the_pool
    assert_answers(
      'T = ets:new(t, [public]), [ets:insert(T, {I, lists:duplicate(1000, I)}) || I <- lists:seq(1, 100000)], ' \
      'ets:info(T, size).' => /^100000$/
    )
  end

  # A library is not looked for at all: only NIFs linked into the runtime image load.
  def test_a_library_load_is_refused_without_reaching_the_host
    probe = compiled_load_nif_probe
    assert_answers(
      "{module, load_nif_probe} = code:load_binary(load_nif_probe, \"probe\", base64:decode(\"#{probe}\")), loaded." =>
        /^loaded$/,
      'load_nif_probe:go("/nosuch/lib").' =>
        %r{^\{error,\{load_failed,"Failed to load NIF library /nosuch/lib: 'only NIFs linked into the runtime image load'"\}\}$},
      'erl_ddll:load_driver("/nosuch", "nodrv").' => /^\{error,no_ddll_available\}$/
    )
  end

  # A runtime refuses to start without entropy for its reference key, since its references
  # would then be guessable (docs/design-runtime.md, "Representation and aliases"): with every
  # read failing it stops before init, with its reason.
  def test_a_start_without_entropy_for_the_reference_key_stops_with_its_reason
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERX_HOSTED_ENTROPY_FAIL' => '0')
    output, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s, OUTPUT.beam,
                                     OUTPUT.archive, stdin_data: '')
    refute status.success?, output
    assert_match(/references: no entropy for the reference key/, output)
  end

  # Every scheduler thread makes references from a source of its own, so a reference made on
  # a dirty CPU or dirty I/O scheduler deciphers to that thread's id, and references made at
  # once on four of each kind of scheduler are all distinct.
  def test_references_made_on_every_kind_of_scheduler_are_their_threads_own
    assert_answers(
      'Make = fun(dirty_cpu) -> erts_debug:dirty_cpu(make_ref, 5000); ' \
      '(dirty_io) -> erts_debug:dirty_io(make_ref, 5000); ' \
      '(normal) -> erts_debug:dirty(normal, make_ref, 5000) end, P = self(), ' \
      'Kinds = [K || K <- [normal, dirty_cpu, dirty_io], _ <- lists:seq(1, 4)], ' \
      '[spawn(fun() -> P ! {made, Make(K)} end) || K <- Kinds], ' \
      'Made = [receive {made, R} -> R end || _ <- Kinds], ' \
      '{refs_made, [E || {error, _, _} = E <- Made], ' \
      'length(lists:usort(lists:append([R || R <- Made, is_list(R)])))}.' => /\{refs_made,\[\],60000\}\n/
    )
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
      'init:get_argument(erx).' => /\["console_driver","erx_stdio"\]\]\}$/,
      'code:which(lists).' => %r{^"/lib/stdlib-[0-9.]+/ebin/lists\.beam"$},
      'file:read_file_info("/bin/start.boot") =/= {error,enoent}.' => /^true$/,
      'file:read_file("/etc/hosts").' => /^\{error,enoent\}$/,
      'file:write_file("/x", <<>>).' => /^\{error,erofs\}$/,
      'file:list_dir("/").' => /"bin"/,
      'erlang:system_info(emu_flavor).' => /^emu$/,
      '[element(1, C) || C <- supervisor:which_children(kernel_sup)].' => /code_server/,
      'lists:keymember(erx_watchdog, 1, supervisor:which_children(kernel_sup)).' => /^true$/,
      'erlang:ports().' => /^\[\]$/,
      'catch open_port({spawn, "ls"}, []).' => /badarg/,
      'catch os:cmd("ls").' => /open_port,badarg/,
      'element(2, os:type()).' => /^erxos$/,
      '{ok, Ram} = file:open(<<"ram">>, [ram, binary, read]), file:read(Ram, 3).' => /^\{ok,<<"ram">>\}$/,
      'catch open_port({fd, 0, 1}, []).' => /badarg/,
      'catch open_port({spawn_driver, "tcp_inet"}, []).' => /badarg/,
      '[code:which(M) || M <- [prim_socket, prim_net, socket_registry]].' => /^\[non_existing,non_existing,non_existing\]$/,
      '[whereis(N) || N <- [heart, socket_registry, erl_epmd, net_kernel, auth]].' => /^\[undefined,undefined,undefined,undefined,undefined\]$/,
      # rex, global and global_group start without a carrier, as on a stock node that is
      # not distributed, so a name registered globally answers on this node alone.
      '[is_pid(whereis(N)) || N <- [rex, global_name_server, global_group]].' => /^\[true,true,true\]$/,
      'global:register_name(erx_local, self()).' => /^yes$/,
      'global:whereis_name(erx_local) =:= self().' => /^true$/,
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
        erlang_shell(reader, writer, transcript, deadline)
        answers = expected.each_with_index.map do |(expression, _), index|
          writer.write("#{expression}\n")
          read_until(reader, transcript, /^#{PROMPT}#{index + 2}> /, deadline)
          plain(transcript)[/^#{PROMPT}#{index + 1}> .*\z/m]
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

  # Types each expression at a prompt of one node and matches its answer, then halts.
  def assert_answers(expected, environment = {})
    Dir.mktmpdir('erx-hosted-home-') do |home|
      spawn_shell(home, environment) do |reader, writer, pid|
        transcript = +''
        deadline = monotonic + BUDGET_SECONDS
        erlang_shell(reader, writer, transcript, deadline)
        answers = expected.each_with_index.map do |(expression, _), index|
          writer.write("#{expression}\n")
          read_until(reader, transcript, /^#{PROMPT}#{index + 2}> /, deadline)
          plain(transcript)[/^#{PROMPT}#{index + 1}> .*\z/m]
        end
        writer.write("halt().\n")
        read_to_end(reader, transcript, deadline)
        @reaped = true if wait_for(pid, deadline, transcript)
        expected.values.zip(answers).each { |pattern, answer| assert_match pattern, answer }
      end
    end
  end

  # The fixture's BEAM, in base64, compiled on the host by the oracle's erlc, so the probe
  # depends on nothing in the release but the loader it tests.
  def compiled_load_nif_probe
    Dir.mktmpdir('erx-hosted-probe-') { |directory| compiled_fixture('load_nif_probe', directory) }
  end

  # The BEAM of test/fixtures/NAME.erl, compiled by the oracle's erlc into directory without
  # its documentation, in base64.
  def compiled_fixture(name, directory)
    log, status = Open3.capture2e(File.join(ROOT, 'build/oracle/emu/install/bin/erlc'), '+no_docs', '-o', directory,
                                  File.join(ROOT, "test/fixtures/#{name}.erl"), stdin_data: '')
    assert status.success?, log
    [File.binread(File.join(directory, "#{name}.beam"))].pack('m0')
  end

  # The probe's digests by stock OTP's crypto:hash/2, from the probe compiled in directory.
  def oracle_sha256_digests(directory)
    expression = 'io:format("~s~n", [lists:join(",", erx_sha256_probe:digests(fun(Data) -> ' \
                 'crypto:hash(sha256, Data) end))]), halt().'
    output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                                     File.join(ROOT, 'build/oracle/emu/install/bin/erl'), '-noshell', '-pa', directory,
                                     '-eval', expression, stdin_data: '')
    assert status.success?, output
    output.chomp.split(',')
  end

# The probe's answers from the host stand-in on stock OTP, as an Erlang list's text: the
# stand-in is compiled into a directory of its own, so the release loads only the probe.
def stand_in_net_bytes_answers(directory)
  stand_in = File.join(directory, 'stand-in')
  FileUtils.mkdir_p(stand_in)
  log, status = Open3.capture2e(File.join(ROOT, 'build/oracle/emu/install/bin/erlc'), '+no_docs', '-o', stand_in,
                                File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl'),
                                File.join(ROOT, 'test/erlang/host_bytes/erx_tcp_merge_model.erl'), stdin_data: '')
  assert status.success?, log
  output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                                   File.join(ROOT, 'build/oracle/emu/install/bin/erl'), '-noshell',
                                   '-pa', directory, '-pa', stand_in, '-eval',
                                   'io:format("~w~n", [erx_net_bytes_probe:answers()]), halt().', stdin_data: '')
  assert status.success?, output
  output.chomp
end

  # The release's manifest holds every argument, and nothing of the host's environment reaches the page.
  # Waits for the console's command shell, which the runtime starts at boot (the boot's log
  # records may land between its banner and its prompt), starts an
  # Erlang shell from it with `erl`, and waits for that shell's first prompt.
  def erlang_shell(reader, writer, transcript, deadline)
    read_until(reader, transcript, /^rc: the command shell; erl starts the Erlang shell\r?\n(?:[^\n]*\n)*% /, deadline)
    writer.write("erl\n")
    read_until(reader, transcript, /^#{PROMPT}1> /, deadline)
  end

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
