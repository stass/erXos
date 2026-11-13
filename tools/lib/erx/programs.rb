# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi'
require_relative 'compiler_rt'
require_relative 'error'
require_relative 'fiasco'
require_relative 'lvgl'
require_relative 'medium_boot'
require_relative 'native_root'
require_relative 'native_runtime'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_files'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # Native programs of root's session (docs/design-runtime.md, "Programs as ports";
  # docs/design-programs.md): erx_program:start/1 maps a program from the session's
  # release, runs it in a sub-space the session made, and gives its owner the program's
  # end. The suite's test image is the production image with the static programs
  # of test/guest/programs/ in the domain release's bin/ (PROGRAMS), each a musl program
  # whose entry, program_task.c, stops its space with main's return. It keeps the
  # development manifest's session template, so the console logs root in at boot and
  # root's session, root_1, takes the line; it boots without a disk, since nothing here
  # reads /data.
  #
  # At root_1's Erlang shell each case (cases) is one expression, whose answer names it:
  # * exit42 ends by itself and its owner gets {exit_status, 42};
  # * fault loads from the null page, and the fault ends it with ERX_EXIT_SIGNAL plus
  #   SIGSEGV, which erx_prog:status/1 reads as {signaled, sigsegv};
  # * args, started with no descriptors, finds what its startup message gave it, every
  #   descriptor call EBADF and munmap's own checks EINVAL (test/guest/programs/args.c),
  #   and a start naming a window buffer's lease the session does not hold answers
  #   {error, einval}: the take's refusal (docs/design-display.md, "A program's window
  #   buffer");
  # * spin runs until port_close/1, which stops its space and reports nothing, since the
  #   port is gone (erx_program_core.c, ERX_PROGRAM_CLOSE): the close answers true, the
  #   port goes down, and no message of it follows;
  # * many runs MANY_RUNS rounds, one after another, each an exit42 that reports 42 and a
  #   spin that port_close/1 ends, each port down before the next program starts. Every
  #   program holds two of the gate worker's 64 registrations (ERX_GATE_SINKS) while it
  #   lives, so a registration either end fails to give back makes a start past the
  #   32nd fail. What else a start makes (budget, group, IRQ object, capability slots)
  #   must be given back too, though 2 * MANY_RUNS programs need not exhaust it;
  # * lvgl starts erx-lvgl, LVGL's renderer cross-built from the submodule
  #   (Lvgl::Program) and shipped as bin/erx-lvgl, with no descriptors: liberx takes its
  #   startup message, main runs LVGL's setup, and the map of descriptor 3, the window's
  #   buffer, which the start did not give, ends it with status 1 (display/lvgl/erx_lvgl.c).
  # * pipe_hand and install give a program a pipe write end as the pipe NIF's hand-off
  #   (docs/design-pipes.md, "Hand-offs"), the shell's process standing in for the program's
  #   handler: it makes the program's holder entry, a lane and an unbound doorbell, and the
  #   hand-off of their copies. pipe_hand names it in start/1's fds, and exit42 runs and ends
  #   with 42 only when the driver took it for that program. install hands one to a running
  #   spin with install/2: another process is refused, the owner gets the descriptor with
  #   the copies' values, a second take of the number is refused, and once the port is closed
  #   and the shell drops its own hold the entry is gone, so a new one can be made, which
  #   only the port's release of its hold allows. hand_twice names one hand-off in two fds,
  #   whose second take is refused, and the start fails with einval; hold_kept fails a
  #   second start under a running program's pid, after which an install into the running
  #   program still succeeds, since only the port that took the hold lets it go.
  #   install_refused makes an install fail at the bind, with a doorbell already bound to
  #   another program's group: the program keeps running, and none of the refused
  #   install's copies took a place in its table.
# * poll, sigign and sigdfl run pipeio (test/guest/programs/pipeio.c) with a hand-off of a
#   write end of a pipe that has no read end at descriptor 3: poll answers POLLOUT|POLLHUP
#   for it, POLLNVAL, EINVAL past the table's size and 0 at a timeout; with SIGPIPE ignored
#   the write fails with EPIPE, and under its default action the write ends the program
#   with ERX_EXIT_SIGNAL plus SIGPIPE, 269.
  # The shell then answers node() again.
  #
  # The programs are file entries, so the backend copies their segments into the space
  # (erx_fiasco_task_image_map_body); a program of image kind, whose code its slice
  # shares, is not run here.
  module Programs
    # Each program by its name in the session's release, domains/erxos/bin/<name>, and the
    # source it is built from. erx-lvgl joins them there, built from LVGL (Run#added).
    PROGRAMS = %w[exit42 fault spin args bigargs note pipeio].to_h { |name| [name, "test/guest/programs/#{name}.c"] }.freeze
    PROGRAM_PREFIX = "#{ReleaseFiles::DOMAIN_PREFIX}bin/".freeze
    # How many rounds many runs: more than the 32 programs the gate worker's 64
    # registrations hold at once, for each way a program ends.
    MANY_RUNS = 50
    # How long an expression waits for a program's message, its port's end or its
    # credit's admission of a reply, in milliseconds.
    WAIT_MS = 10_000
    NODE = "node().\r"
    ROOT_NODE = 'root_1@erxos'

    # A case: what is typed at root_1's Erlang shell, the answer it must print, and how
    # long the answer may take, in seconds.
    Case = Data.define(:name, :expression, :answer, :seconds)

    module_function

    # Typed at the shell as one line: an expression written over several lines here, so
    # it reads as Erlang, then joined with single spaces.
    def line(erlang) = "#{erlang.split.join(' ')}\r"

    # erx_program:start/1's spec for the program bin/<name> as pid, its own process group,
    # with the rest of what its startup message carries; each keyword is an Erlang term.
    def spec(name, pid, argv: "[<<\"#{name}\">>]", env: '[]', cwd: '<<"/">>', umask: '8#022', sigmask: '[]', fds: '[]')
      "\#{image => <<\"bin/#{name}\">>, pid => #{pid}, ppid => 1, pgid => #{pid}, argv => #{argv}, env => #{env}, " \
        "cwd => #{cwd}, spawn => false, sigmask => #{sigmask}, sigignore => [], umask => #{umask}, fds => #{fds}}"
    end

    # Each case's expression is a fun applied at once, so no case binds a shell variable
    # another sees. A start the driver refused, or an answer other than the one awaited,
    # shows in the case's answer instead of a timeout alone. fault_answer is fault's
    # (Run#fault_answer).
    # A hand-off of a write end of pipe 9 for program pid, made by the calling process as its
    # handler, which first makes the program's holder entry unless holder is false: its
    # descriptor, with the copies written {hand, I}, bound to D, and its number to H, each
    # variable's name ending in suffix. rights gives a ring's and a reader page's handle rights.
    def hand_off(pid, rights, suffix: '', holder: true)
      "#{holder ? "ok = erx_pipe_nif:program_holder(#{pid}), " : ''}" \
        "{ok, Ring#{suffix}, RPage#{suffix}} = erx_pipe_nif:make_lane(65536), " \
        "{ok, Bell#{suffix}} = erx_pipe_nif:make_bell({program, #{pid}}, 9, 1), " \
        "{ok, [H#{suffix}]} = erx_pipe_nif:hand_make(#{pid}, [{[{Ring#{suffix}, #{rights.fetch(:ring)}}, " \
        "{RPage#{suffix}, #{rights.fetch(:rpage)}}], {Bell#{suffix}, (9 bsl 32) bor 1}}]), " \
        "D#{suffix} = {pipe, write, {9, 1}, \#{wend => 1, ring => {hand, 1}, rpage => {hand, 2}, size => 65536, readers => []}},"
    end

    def cases(fault_answer:, rights:)
      [Case.new(name: 'e2big', seconds: 60, answer: '{e2big,{error,e2big}}', expression: line(<<~ERLANG)),
         (fun() -> {e2big, erx_program:start(#{spec('args', 6, argv: '[binary:copy(<<"a">>, 131072)]')})} end)().
       ERLANG
       Case.new(name: 'pipe_hand', seconds: 60, answer: '{pipe_hand,42}', expression: line(<<~ERLANG)),
         (fun() ->
            #{hand_off(21, rights)}
            P = erx_program:start((#{spec('exit42', 21)})\#{fds => [{3, {pipe_hand, H, D}}]}),
            receive {P, {exit_status, S}} -> {pipe_hand, S} after #{WAIT_MS} -> {pipe_hand, P} end
          end)().
       ERLANG
       # A start naming the same hand-off twice takes it once and is refused at the second
       # take, so it fails whole with einval and lets go what it took.
       Case.new(name: 'hand_twice', seconds: 60, answer: '{hand_twice,{error,einval}}', expression: line(<<~ERLANG)),
         (fun() ->
            #{hand_off(23, rights)}
            Failed = erx_program:start((#{spec('exit42', 23)})\#{fds => [{3, {pipe_hand, H, D}}, {4, {pipe_hand, H, D}}]}),
            erx_pipe_nif:holder_drop(23),
            {hand_twice, Failed}
          end)().
       ERLANG
       # A failed start of another port naming a running program's pid lets go nothing of
       # that program's hold, which only the port that took it releases: an install into the
       # running program still succeeds.
       Case.new(name: 'hold_kept', seconds: 60, answer: '{hold_kept,{error,einval},ok}', expression: line(<<~ERLANG)),
         (fun() ->
            #{hand_off(24, rights)}
            P = erx_program:start((#{spec('spin', 24)})\#{fds => [{3, {pipe_hand, H, D}}]}),
            Failed = erx_program:start(#{spec('nosuch', 24)}),
            #{hand_off(24, rights, suffix: '2', holder: false)}
            Installed = case erx_program:install(P, {pipe_hand, H2, D2}) of
                          {ok, _} -> ok;
                          Refused -> Refused
                        end,
            R = erlang:monitor(port, P),
            true = port_close(P),
            receive {'DOWN', R, port, P, _} -> ok after #{WAIT_MS} -> timeout end,
            erx_pipe_nif:holder_drop(24),
            {hold_kept, Failed, Installed}
          end)().
       ERLANG
       Case.new(name: 'install', seconds: 60, answer: '{install,{error,einval},ok,{error,einval},ok}',
                expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('spin', 22)}),
            #{hand_off(22, rights)}
            Self = self(),
            spawn(fun() -> Self ! {other, erx_program:install(P, {pipe_hand, H, D})} end),
            Other = receive {other, O} -> O after #{WAIT_MS} -> timeout end,
            Owner = case erx_program:install(P, {pipe_hand, H, D}) of
                      {ok, {pipe, write, {9, 1}, \#{ring := V1, rpage := V2}}} when is_integer(V1), is_integer(V2),
                                                                                    V1 =/= V2 -> ok;
                      Installed -> Installed
                    end,
            Again = erx_program:install(P, {pipe_hand, H, D}),
            R = erlang:monitor(port, P),
            true = port_close(P),
            receive {'DOWN', R, port, P, _} -> ok after #{WAIT_MS} -> timeout end,
            ok = erx_pipe_nif:holder_drop(22),
            Gone = erx_pipe_nif:program_holder(22),
            erx_pipe_nif:holder_drop(22),
            {install, Other, Owner, Again, Gone}
          end)().
       ERLANG
       # An install whose bind is refused fails before any copy reaches the program, which
       # keeps running: the end's doorbell, bound to spin 25's group by its install, cannot
       # move to spin 26's. The proof that no copy went is where the next install's copies
       # land: the table gives each copy its lowest free place, so a good install after the
       # refused one starts just past the good install before it (Gap 1), and a refused
       # install that left its two copies in the table pushes it two further (Gap 3).
       Case.new(name: 'install_refused', seconds: 60, answer: '{install_refused,error,1,running}',
                expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('spin', 25)}),
            #{hand_off(25, rights)}
            {ok, _} = erx_program:install(P, {pipe_hand, H, D}),
            #{hand_off(26, rights, suffix: 'a')}
            P2 = erx_program:start(#{spec('spin', 26)}),
            receive after 200 -> ok end,
            {ok, {pipe, write, _, \#{rpage := Before}}} = erx_program:install(P2, {pipe_hand, Ha, Da}),
            {ok, [H2]} = erx_pipe_nif:hand_make(26, [{[{Ring, #{rights.fetch(:ring)}}, {RPage, #{rights.fetch(:rpage)}}],
                                                      {Bell, (9 bsl 32) bor 1}}]),
            Failed = case erx_program:install(P2, {pipe_hand, H2, D}) of
                       {error, _} -> error;
                       Installed -> Installed
                     end,
            #{hand_off(26, rights, suffix: 'b', holder: false)}
            Gap = case erx_program:install(P2, {pipe_hand, Hb, Db}) of
                    {ok, {pipe, write, _, \#{ring := After}}} -> After - Before;
                    Refused -> Refused
                  end,
            Running = receive {P2, {exit_status, S}} -> S after 0 -> running end,
            Close = fun(Port) ->
                      R = erlang:monitor(port, Port),
                      catch port_close(Port),
                      receive {'DOWN', R, port, Port, _} -> ok after #{WAIT_MS} -> timeout end
                    end,
            Close(P), Close(P2),
            erx_pipe_nif:holder_drop(25), erx_pipe_nif:holder_drop(26),
            {install_refused, Failed, Gap, Running}
          end)().
       ERLANG
       # The raw path: start/1's steps by hand, with a relative working directory that
       # start/1's builder refuses and liberx must refuse before main. A reply on a slot
       # that holds no request is a send the driver refuses whole, with einval.
       Case.new(name: 'startup', seconds: 60, answer: '{startup,{error,einval},ok,<<"ok">>,127}', expression: line(<<~ERLANG)),
         (fun() ->
            P = open_port({spawn_driver, "erx_program 7 0 4096 4 0 0 0 bin/args"}, [binary]),
            <<"ok", D:64>> = port_control(P, 1, []),
            F = {erx_start, 1, \#{pid => 7, ppid => 1, pgid => 7, argv => [<<"args">>], env => [],
                                 cwd => <<"home/u">>, spawn => false, sigmask => [], sigignore => [],
                                 umask => 8#022, data_area => {D, 4}, fds => []}},
            {startup, erx_program:send(P, {erx_prog, 1, 3, ok}), erx_program:send(P, F), port_control(P, 3, []),
             receive {P, {exit_status, S}} -> S after #{WAIT_MS} -> timeout end}
          end)().
       ERLANG
       Case.new(name: 'args', seconds: 60, answer: '{args,0}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('args', 5, argv: '[<<"args">>, <<"one">>, <<"two words">>]',
                                         env: '[<<"HOME=/home/u">>, <<"TERM=vt100">>]', cwd: '<<"/home/u">>',
                                         umask: '8#027', sigmask: '[sigterm]')}),
            receive {P, {exit_status, S}} -> {args, S} after #{WAIT_MS} -> {args, timeout, P} end
          end)().
       ERLANG
       Case.new(name: 'bigargs', seconds: 60, answer: '{bigargs,0}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('bigargs', 8, argv: '[<<"bigargs">>, binary:copy(<<"x">>, 130000)]')}),
            receive {P, {exit_status, S}} -> {bigargs, S} after #{WAIT_MS} -> {bigargs, timeout, P} end
          end)().
       ERLANG
       # Lease 5 names no window buffer this session holds, so the start's take refuses it.
       Case.new(name: 'no_lease', seconds: 60, answer: '{no_lease,{error,einval}}', expression: line(<<~ERLANG)),
         (fun() -> {no_lease, erx_program:start(#{spec('args', 18, fds: '[{3, {mem, 5, 1}}]')})} end)().
       ERLANG
       # The note program writes one record of its own (test/guest/programs/note.c), and the
       # driver ends it with 256 + SIGSYS: a notice holding an atom no image has, which the
       # safe decode refuses without making it, so the atom count is unchanged; a record cut
       # short; and a notice the driver never made due.
       Case.new(name: 'note_atom', seconds: 60, answer: '{note_atom,268,0}', expression: line(<<~ERLANG)),
         (fun() ->
            N = erlang:system_info(atom_count),
            P = erx_program:start(#{spec('note', 9, argv: '[<<"note">>, <<"atom">>]')}),
            receive {P, {exit_status, S}} -> {note_atom, S, erlang:system_info(atom_count) - N}
            after #{WAIT_MS} -> {note_atom, timeout, P} end
          end)().
       ERLANG
       Case.new(name: 'note_bad', seconds: 60, answer: '{note_bad,268}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('note', 10, argv: '[<<"note">>, <<"bad">>]')}),
            receive {P, {exit_status, S}} -> {note_bad, S} after #{WAIT_MS} -> {note_bad, timeout, P} end
          end)().
       ERLANG
       Case.new(name: 'note_undue', seconds: 60, answer: '{note_undue,268}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('note', 11, argv: '[<<"note">>, <<"undue">>]')}),
            receive {P, {exit_status, S}} -> {note_undue, S} after #{WAIT_MS} -> {note_undue, timeout, P} end
          end)().
       ERLANG
       # A request on a free slot reaches the port's owner as {erx_channel, Port, Frame}, and
       # the owner's stop then ends the waiting program with the status it gives.
       Case.new(name: 'note_request', seconds: 60, answer: '{note_request,{erx_prog,1,0,getpid},ok,268}',
                expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('note', 15, argv: '[<<"note">>, <<"request">>]')}),
            F = receive {erx_channel, P, Frame} -> Frame after #{WAIT_MS} -> timeout end,
            {note_request, F, erx_program:stop(P, anchor, 268),
             receive {P, {exit_status, S}} -> S after #{WAIT_MS} -> timeout end}
          end)().
       ERLANG
       # Every frame the program wrote before its end is judged before the end is: the program
       # writes a request on each of the 16 slots and a 17th on slot 0, which is busy, rings
       # nothing and faults, so the driver first reads them with the fault's record in hand,
       # past its allowance of 16 records a run. It delivers 16 and refuses the 17th before it
       # takes the fault, so the end reports 256 + SIGSYS; a driver that took the fault at its
       # allowance, with the 17th unread, would report SIGSEGV's status.
       Case.new(name: 'note_burst', seconds: 60, answer: '{note_burst,16,268}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('note', 16, argv: '[<<"note">>, <<"burst">>]')}),
            S = receive {P, {exit_status, X}} -> X after #{WAIT_MS} -> timeout end,
            Count = fun C(N) -> receive {erx_channel, P, {erx_prog, 1, _, getpid}} -> C(N + 1) after 0 -> N end end,
            {note_burst, Count(0), S}
          end)().
       ERLANG
       # A frame for an owner that is gone: the port is handed to a process that unlinks
       # from it and exits, so the port outlives its owner, and only then does the program
       # run and write a request the credit admits. The driver drops the frame for want of a
       # reader, and the session goes on to close the port. The credit says when the driver
       # has taken the request: until then slot 0 is free and a reply on it is refused with
       # einval, and from then on it is admitted (docs/design-programs.md, "Credit"). A driver
       # that refused the frame would have ended the program, and a send to an ended program
       # is einval too, so ok also shows the frame was dropped and the program lives on. The
       # program never reads the reply. No frame reaches this process, which is not the owner.
       Case.new(name: 'owner_gone', seconds: 60, answer: '{owner_gone,ok,<<"ok">>,ok,none,true}',
                expression: line(<<~ERLANG)),
         (fun() ->
            P = open_port({spawn_driver, "erx_program 14 0 4096 4 0 0 0 bin/note"}, [binary]),
            <<"ok", D:64>> = port_control(P, 1, []),
            {ok, F} = erx_prog_grammar:build_start(\#{pid => 14, ppid => 1, pgid => 14,
                                                     argv => [<<"note">>, <<"request">>], env => [],
                                                     cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [],
                                                     umask => 8#022, data_area => {D, 4}, fds => []}),
            A = erx_program:send(P, F),
            {B, M} = spawn_monitor(fun() -> receive go -> unlink(P) end end),
            true = port_connect(P, B),
            B ! go,
            receive {'DOWN', M, process, B, normal} -> ok end,
            R = port_control(P, 3, []),
            AwaitTake = fun W(T) when T > 0 ->
                            case erx_program:send(P, {erx_prog, 1, 0, {ok, 14}}) of
                                ok -> ok;
                                _ -> receive after 10 -> W(T - 10) end
                            end;
                        W(_) -> timeout
                    end,
            Taken = AwaitTake(#{WAIT_MS}),
            Stray = receive {erx_channel, P, X} -> X after 0 -> none end,
            {owner_gone, A, R, Taken, Stray, port_close(P)}
          end)().
       ERLANG
       # Flow control: a startup message of about 40 KiB, larger than the 16 KiB ring, is
       # sent before the first thread runs, so the driver still holds most of it and a second
       # frame is busy. Once the thread runs and reads, the driver tells the owner the room
       # returned, and the second frame is taken. It is a report the profile refuses, pipe 0,
       # so spin's liberx ends it with 127 at that later frame, which shows it arrived.
       Case.new(name: 'busy', seconds: 60, answer: '{busy,ok,busy,room,ok,127}', expression: line(<<~ERLANG)),
         (fun() ->
            P = open_port({spawn_driver, "erx_program 12 0 4096 4 0 0 0 bin/spin"}, [binary]),
            <<"ok", D:64>> = port_control(P, 1, []),
            {ok, F} = erx_prog_grammar:build_start(\#{pid => 12, ppid => 1, pgid => 12,
                                                     argv => [<<"spin">>, binary:copy(<<"x">>, 40000)], env => [],
                                                     cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [],
                                                     umask => 8#022, data_area => {D, 4}, fds => []}),
            R = {erx_prog, 1, {pipe_lost, 0, 1}},
            A = erx_program:send(P, F),
            B = erx_program:send(P, R),
            <<"ok">> = port_control(P, 3, []),
            C = receive {erx_channel_room, P} -> room after #{WAIT_MS} -> timeout end,
            {busy, A, B, C, erx_program:send(P, R),
             receive {P, {exit_status, S}} -> S after #{WAIT_MS} -> timeout end}
          end)().
       ERLANG
       # The handler's stop of a program its grammar refuses: the end reports the status given.
       Case.new(name: 'stop', seconds: 60, answer: '{stop,ok,268}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('spin', 13)}),
            {stop, erx_program:stop(P, anchor, 268),
             receive {P, {exit_status, S}} -> S after #{WAIT_MS} -> timeout end}
          end)().
       ERLANG
       # A start that refused the image or its startup message would answer an error or
       # 127, and a fault in LVGL's setup a signal's status, instead of main's 1.
       Case.new(name: 'lvgl', seconds: 60, answer: '{lvgl,1}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec(Lvgl::Program::NAME, 19)}),
            receive {P, {exit_status, S}} -> {lvgl, S} after #{WAIT_MS} -> {lvgl, timeout, P} end
          end)().
       ERLANG
*[['poll', 27, 42], ['sigign', 28, 42], ['sigdfl', 29, 269]].map do |mode, pid, status|
  Case.new(name: mode, seconds: 60, answer: "{#{mode},#{status}}", expression: line(<<~ERLANG))
    (fun() ->
       #{hand_off(pid, rights)}
       P = erx_program:start((#{spec('pipeio', pid, argv: "[<<\"pipeio\">>, <<\"#{mode}\">>]")})\#{fds => [{3, {pipe_hand, H, D}}]}),
       receive {P, {exit_status, S}} -> {#{mode}, S} after #{WAIT_MS} -> {#{mode}, P} end
     end)().
  ERLANG
end,
       Case.new(name: 'exit42', seconds: 60, answer: '{exit42,42}', expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('exit42', 2)}),
            receive {P, {exit_status, S}} -> {exit42, S} after #{WAIT_MS} -> {exit42, timeout, P} end
          end)().
       ERLANG
       Case.new(name: 'fault', seconds: 60, answer: fault_answer, expression: line(<<~ERLANG)),
         (fun() ->
            P = erx_program:start(#{spec('fault', 3)}),
            receive {P, {exit_status, S}} -> {fault, S, erx_prog:status(S)} after #{WAIT_MS} -> {fault, timeout, P} end
          end)().
       ERLANG
       # The program runs for half a second first, so the close stops a running program.
       Case.new(name: 'spin', seconds: 60, answer: '{spin,true,down,none}', expression: line(<<~ERLANG)),
         (fun() ->
            case erx_program:start(#{spec('spin', 4)}) of
              P when is_port(P) ->
                timer:sleep(500),
                R = erlang:monitor(port, P),
                {spin, port_close(P),
                 receive {'DOWN', R, port, P, _} -> down after #{WAIT_MS} -> open end,
                 receive {P, M} -> M after 1000 -> none end};
              Refused -> {spin, Refused}
            end
          end)().
       ERLANG
       # Run(Image, Pid, End) starts a program, lets End see its port, and waits for the
       # port's end: ok, or what went wrong instead.
       Case.new(name: 'many', seconds: 300, answer: "{many,#{MANY_RUNS}}", expression: line(<<~ERLANG))
         (fun() ->
            Run = fun(Image, Pid, End) ->
                case erx_program:start(\#{image => Image, pid => Pid, ppid => 1, pgid => Pid, argv => [Image], env => [],
                                     cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022}) of
                  P when is_port(P) ->
                    R = erlang:monitor(port, P),
                    case End(P) of
                      ok -> receive {'DOWN', R, port, P, _} -> ok after #{WAIT_MS} -> {open, Image} end;
                      Other -> Other
                    end;
                  Refused -> {Image, Refused}
                end
              end,
            Exit = fun(P) -> receive {P, {exit_status, 42}} -> ok; {P, Status} -> Status after #{WAIT_MS} -> timeout end end,
            Close = fun(P) -> true = port_close(P), ok end,
            Many = fun Loop(Done) when Done =:= #{MANY_RUNS} -> {many, Done};
                       Loop(Done) ->
                         case {Run(<<"bin/exit42">>, 10, Exit), Run(<<"bin/spin">>, 11, Close)} of
                           {ok, ok} -> Loop(Done + 1);
                           Failed -> {many, Done, Failed}
                         end
                   end,
            Many(0)
          end)().
       ERLANG
      ].freeze
    end

    # The production checkpoints of a test image's boot to the system's command shell,
    # then root_1's command shell and Erlang shell, and each case: typed once the shell
    # has answered node(), its answer, then node() typed again. An answer line of the
    # case's own, or an exception, ends the cell at once, quoting the line, unless it is
    # the answer.
    def checkpoints(points, fault_answer:, rights:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      node = ->(name) { { name: name, pattern: SessionDomain.answer(ROOT_NODE), seconds: 60 } }
      typed = cases(fault_answer: fault_answer, rights: rights).flat_map do |each|
        [node.call("#{each.name}-ready").merge(type: each.expression).freeze, answer_point(each)]
      end
      [*points,
       SessionDomain.session_shell('root_1-shell', ProductionImage::Run::ERL_LINE),
       ProductionImage::Run::ERLANG_SHELL.merge(name: 'root_1-erlang-shell', type: NODE).freeze,
       *typed, node.call('last-node').freeze].freeze
    end

    def answer_point(each)
      expected = SessionDomain.answer(each.answer)
      { name: each.name, pattern: /\A#{SessionDomain::PROMPT}(?:\{#{each.name},|\*\* exception)/n, seconds: each.seconds,
        type: NODE,
        verify: ->(text) { raise Error, "the #{each.name} case answers #{text.inspect}" unless expected.match?(text) } }.freeze
    end

    # Builds the programs and the test image once, then boots it under HVF at each CPU
    # count, where placement puts each cell. Returns { "<accel>-<n>cpu" => 'passed' }; any
    # disagreement raises.
    class Run
      def self.cells(cpus) = cpus.map { |count| QemuCells::Cell.new(accel: QemuCells::LOCAL_ACCELERATOR, cpus: count).name }

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = ProductionImage::Machine.development(platform)
        @manifest = platform.manifest_source(@root)
        @build = File.join(@root, 'build/programs')
        @schema = ABI::Generator.plan(root: @root).schema
        @codec = ABI::Codec.new(@schema)
      end

      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", boot(accel, count, remote, built)]
        end
      end

      private

      # The production image with PROGRAMS added to the domain release, under the
      # development manifest, session template and all.
      def image(fiasco)
        runtime = NativeRuntime.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco,
                                    platform: @machine.platform)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@build, 'image'))
        # The image's build builds the runtime again; make finds nothing left to do.
        libc = runtime.build.libc
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                            fiasco: fiasco, runtime: runtime)
                       .build_test_image(directory: directory, added: added(fiasco, libc: libc),
                                         manifest_source: @manifest)
      end

      # Each program linked over musl's libc.a, the one the runtime images link, as a
      # release file of the session's: no system mark, since only the system release's
      # files carry it.
      def added(fiasco, libc:)
        native = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @machine.platform,
                                fiasco: fiasco)
        archives = [libc, CompilerRt.archive(root: @root, runner: @runner, compiler: @compiler)]
        programs = PROGRAMS.map do |name, source|
          [name, native.build_task_receipted(name: name, sources: [*NativeRoot::PROGRAM, source], directory: File.join(@build, name),
                                             archives: archives)]
        end
        lvgl = Lvgl::Program.new(root: @root, runner: @runner, native: native, compiler: @compiler,
                                 archives: archives,
                                 directory: File.join(@build, Lvgl::Program::NAME)).call
        programs = [*programs, [Lvgl::Program::NAME, lvgl]]
        library = ProductionImage::Archive.new(path: lvgl.fetch(:archive), label: 'lvgl liblvgl.a', license: Lvgl::Program::LICENSE,
                                               status: 'stopgap', notices: Lvgl::Program::NOTICES, font_data: Lvgl::Program::FONT_DATA)
        entries = programs.map do |name, program|
          { 'path' => "#{PROGRAM_PREFIX}#{name}", 'kind' => @codec.member('entry_kind', 'file'), 'flags' => 0, 'id' => "program-#{name}",
            'artifact' => program.fetch(:program), 'receipt' => program.fetch(:receipt) }.freeze
        end
        ProductionImage::Added.new(entries: entries.freeze, inputs: programs.flat_map { |_, program| program.fetch(:inputs) }.uniq.freeze,
                                   imports: {}.freeze, archives: [library].freeze)
      end

      def boot(accel, count, remote, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib, test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib,
                 checkpoints: Programs.checkpoints(points, fault_answer: fault_answer, rights: hand_rights))
        'passed'
      end

      # The handle rights of a write end's copies (docs/design-pipes.md, "The rights of a
      # copy"), from the rights abi/kernel.txt numbers: its ring's READ, WRITE and MAP, its
      # reader page's READ and MAP.
      def hand_rights
        bits = File.foreach(File.join(@root, 'abi/kernel.txt')).filter_map do |line|
          line.match(/\Aright (\w+) (\d+) /)&.captures
        end.to_h { |name, bit| [name, 1 << Integer(bit, 10)] }
        { ring: bits.fetch_values('read', 'write', 'map').sum, rpage: bits.fetch_values('read', 'map').sum }
      end

      # fault's answer as the shell prints it: the status, ERX_EXIT_SIGNAL plus the signal the
      # ABI file's fault table gives a memory fault (a load from the null page), and that
      # signal's reading by erx_prog:status/1.
      def fault_answer
        row = @schema.faults.find { |each| each.kind == 'memory' }
        raise Error, 'the fault table has no memory row' if row.nil?

        "{fault,#{@codec.member('exit_kind', 'signal') + row.signal.number},{signaled,sig#{row.signal.name}}}"
      end
    end
  end
end
