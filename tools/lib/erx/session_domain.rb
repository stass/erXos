# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'hostlink_guest'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_medium'
require_relative 'runner'
require_relative 'web_build'
require_relative 'web_guest'

module Erx
  # Root's session domain on the development machine (docs/design-live.md, "The console";
  # docs/design-domains.md, "Principals, sessions and quotas"). It boots the production
  # image itself, whose development manifest carries the system principal's session
  # template, and types at the UART as a person would. Each boot has a fresh copy of the
  # image's release medium as its disk, so the storage domain serves /data from the
  # medium's new littlefs volume.
  #
  # Its one cell, root_session, at each CPU count. The system domain's command shell
  # prints its banner at boot; the console logs root in, and root's session, root_1,
  # takes the line once its tty names itself, so the next banner is the session's own
  # command shell's. There `ls /data` lists the storage domain's tree at the first prompt, since
  # the console takes the line only with the session's namespace in place (docs/design-system.md,
  # "A session takes the console"), `echo hi` answers, `ls /tmp` lists a file the shell wrote, and
  # `ps` lists none of the system domain's processes, and `dmesg` writes the kernel log, which
  # the session reads through the system domain (KERNEL_LOG); `uname -a` prints every field the
  # system shell's does (MediumBoot::UNAME_A), the build facts among them, and `uname -b`
  # the build identifier, so none is `unknown`. The session's Erlang shell answers
  # node() as root_1@erxos, passes bytes between its processes through the session's pipes
  # (PIPES), writes a line to /data/across, the storage domain's tree
  # through the session's `data` facet, and reads it back once that grant has arrived
  # (with_data), and writes 64 KiB in numbered lines while Ctrl-G opens the menu and Esc
  # leaves it mid-burst; the serial log, with the menu taken out, holds every line whole
  # and in order (burst_whole!).
  # halt(3) ends the session's domain: the console writes `session root_1 ended:
  # {halt,3}` and logs root in again, and the new session, root_1 again in a new domain,
  # takes the line. The menu lists it, refuses "start a session" past the principal's
  # domain quota, which the storage, network and web domains and the session fill, and gives the line to
  # the system shell, whose `ps` lists the domain service and whose `cat` reads
  # /data/across through the system domain's own `data` facet. Its Erlang shell answers
  # node() as system@erxos, shows root_1's init process with its runtime attributes, which
  # the session's agent answers to the system domain's query worker (SESSION_PROCESS), and
  # ends the storage domain with exit(DomainPid, kill); once
  # the domain's restart has installed a new `data` grant, a new read of /data/across
  # answers the line the session wrote (RESTART_STORAGE). exit(DomainPid, kill) of the
  # session then ends it as halt does, the next login's session takes the line, and its
  # Erlang shell reads /data/across through the restarted storage domain's grant and
  # starts the idle processes of the GW measurement's fixture (IDLE_PROCESSES), whose
  # listing the web check then opens (WebGuest).
  module SessionDomain
    # The prompt an Erlang shell's answer line may carry, of either domain's shell.
    PROMPT = '(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?'
    CTRL_G = ProductionImage::Run::CTRL_G
    CTRL_G_MENU = ProductionImage::Run::CTRL_G_MENU
    ESC = ProductionImage::Run::ESC
    MENU_LEFT = ProductionImage::Run::MENU_LEFT
    ERL = ProductionImage::Run::ERL_LINE
    # The domain id root's first session takes: the development manifest configures three
    # domains, network, storage and web, which take the domain service's first ids, 5, 6
    # and 7, at boot, so the login's is 8; each later start of a session or of a configured
    # domain takes the next, a refused one too, since admission spends the id.
    FIRST_SESSION = 8
    # A domain id no domain takes in a boot of this cell, which starts far fewer: a path
    # that names it answers `scope` at every scope, root's `all` among them, as a domain
    # outside the scope does (docs/design-live.md, "The /proc tree").
    NEVER_USED_DOMAIN = 4000
    # Typed at the last session's Erlang shell: WebGuest::IDLE_PROCESSES processes that
    # wait for ever.
    IDLE_PROCESSES = "[spawn(timer, sleep, [infinity]) || _ <- lists:seq(1, #{WebGuest::IDLE_PROCESSES})], ok.\r".freeze
    # From a session's start to its tty naming itself, which a domain creation under HVF
    # with one CPU takes seconds to reach.
    SESSION_SECONDS = 120
    # The banner of a session's command shell (erx_shell:server/1), which names no erl.
    SESSION_SHELL_BANNER = 'rc: the command shell; exit ends it'
    # How many numbered lines the burst writes, each `NNNN ` and 58 x's: 64 bytes with its
    # newline, 64 KiB in all.
    BURST_LINES = 1024
    BURST = 'lists:foreach(fun(N) -> io:format("~4..0B ~s~n", [N, lists:duplicate(58, $x)]) end, ' \
            "lists:seq(1, #{BURST_LINES})).\r".freeze
    # The menu as the console draws it over whatever the line holds: the line's last holder
    # ended, an optional notice, the menu, and the line ended again as it is left.
    MENU_BLOCK = /\e\\\e\[0m\r\n(?:[^\r\n]*\r\n)?erx_console: Ctrl-G menu\r\n.*?Esc returns\. \e\\\e\[0m\r\n/mn
    # Typed at the system's Erlang shell: the domain pid of the one session domain the
    # domain service holds, beside the configured storage, network and web domains, killed, as a person
    # would end a session from there.
    KILL_SESSION = '[P] = [Pid || #{origin := {session, _}, pid := Pid} <- ' \
                   'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                   "exit(P, kill).\r".freeze
    # Typed at root_1's Erlang shell: two starts the driver refuses (docs/design-runtime.md,
    # "Programs as ports"). The first names a program the release does not hold, so the
    # start makes the program's budget, group, IRQ object and spaces, the image map fails
    # with einval, and the start undoes what it made; the second asks for a guarantee above
    # its cap, which the driver's spec check refuses with einval before anything is made.
    # Each spec carries what the program's startup message needs. The
    # production image's session release holds no program; the programs suite's test image
    # adds some and runs them (tools/lib/erx/programs.rb).
    PROGRAM_SPEC = 'image => <<"bin/none">>, pid => 2, ppid => 1, pgid => 2, argv => [<<"none">>], env => [], ' \
                   'cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022'
    PROGRAM_REFUSED = "{erx_program:start(\#{#{PROGRAM_SPEC}}), " \
                      "erx_program:start(\#{#{PROGRAM_SPEC}, guarantee => 2, cap => 1})}.\r"
    # Typed at root_1's Erlang shell: the session's pipes between its processes
    # (docs/design-pipes.md, "The session's pipe NIF"). PpGive spawns a process that waits
    # for an end, gives it one inherited from the shell's end X, and runs F on it. The cases:
    # a 4,096-byte write that a child reads whole in one read; a child writer that writes
    # `abc` and exits, after which the shell reads `abc` and then eof; a child reader that
    # exits, after which the shell's writes fail with epipe; and the pipe server killed while
    # a child reader waits, which gets {error,eio}, never eof, before a pipe made through
    # the restarted server passes `z`. PIPES types the first two, PIPES_LOST the other two.
    # The supervisor's report of the kill is held back while it restarts the server: it would
    # reach the console late, inside a later answer's line.
    PIPES = 'PpSelf=self(),' \
            'PpGive=fun(PpX,PpF)->PpC=spawn(fun()->receive {e,PpE}->PpF(PpE) end end),' \
            '{ok,PpCE}=erx_pipe_srv:inherit(PpX,PpC),PpC!{e,PpCE},PpC end,' \
            '{ok,PpR1,PpW1}=erx_pipe_srv:pipe(),PpBin=list_to_binary([PpN rem 256||PpN<-lists:seq(1,4096)]),' \
            '_=PpGive(PpR1,fun(PpE)->PpSelf!{p1,erx_pipe_srv:read(PpE,8192,5000)} end),' \
            'ok=erx_pipe_srv:write(PpW1,PpBin,5000),' \
            'PpA1=receive {p1,PpG1}->PpG1=:=PpBin after 10000->timeout end,' \
            '{ok,PpR2,PpW2}=erx_pipe_srv:pipe(),' \
            '_=PpGive(PpW2,fun(PpE)->ok=erx_pipe_srv:write(PpE,<<"abc">>,5000) end),' \
            'ok=erx_pipe_srv:close(PpW2),' \
            'PpA2=[erx_pipe_srv:read(PpR2,100,5000),erx_pipe_srv:read(PpR2,100,5000)],' \
            "io:format(\"~0p~n\",[{pipes,PpA1,PpA2}]).\r"
    PIPES_ANSWER = '{pipes,true,[<<"abc">>,eof]}'
    # The rest, a line of its own, so that neither line nears a terminal's line limit.
    PIPES_LOST = '{ok,PpR3,PpW3}=erx_pipe_srv:pipe(),_=PpGive(PpR3,fun(_)->ok end),ok=erx_pipe_srv:close(PpR3),' \
                 'PpWr=fun PpL(0)->timeout;PpL(PpK)->case erx_pipe_srv:write(PpW3,<<"x">>,1000) of ' \
                 '{error,epipe}->epipe;ok->timer:sleep(20),PpL(PpK-1);PpO->PpO end end,PpA3=PpWr(250),' \
                 '{ok,PpR4,_PpW4}=erx_pipe_srv:pipe(),PpOld=whereis(erx_pipe_srv),' \
                 '_=PpGive(PpR4,fun(PpE)->PpSelf!{p4,erx_pipe_srv:read(PpE,100,20000)} end),' \
                 'timer:sleep(500),logger:set_module_level(supervisor,critical),exit(PpOld,kill),PpA4=receive {p4,PpG4}->PpG4 after 30000->timeout end,' \
                 'PpNew=fun PpM(0)->timeout;PpM(PpK)->case whereis(erx_pipe_srv) of ' \
                 'PpP when is_pid(PpP),PpP=/=PpOld->ok;_->timer:sleep(100),PpM(PpK-1) end end,ok=PpNew(100),logger:unset_module_level(supervisor),' \
                 '{ok,PpR5,PpW5}=erx_pipe_srv:pipe(),ok=erx_pipe_srv:write(PpW5,<<"z">>,5000),' \
                 'PpA5=erx_pipe_srv:read(PpR5,10,5000),' \
                 "io:format(\"~0p~n\",[{pipes_lost,PpA3,PpA4,PpA5}]).\r"
    PIPES_LOST_ANSWER = '{pipes_lost,epipe,{error,eio},<<"z">>}'
    # The file root's session writes and every later step reads, in Erlang and at the system
    # shell, and its one line, `across`, as file:read_file/1 answers it in the shell.
    WRITE_ACROSS = 'ok = file:write_file("/data/across", <<"across\n">>), file:read_file("/data/across")'
    READ_ACROSS = 'file:read_file("/data/across")'
    ACROSS_READ = '{ok,<<"across\n">>}'
    CAT_ACROSS = "cat /data/across\r"
    # Typed at the system's Erlang shell: the storage domain, the configured domain whose
    # node is storage@erxos, ended through its domain pid, and the file read again once the domain's restart has
    # installed a `data` grant other than the one the registry held before; a read before
    # that reaches the dead grant and answers eio.
    # Typed at the system domain's Erlang shell: the record of root_1's init process, the
    # first process of every runtime, in the session's second domain (relogin-listed).
    SESSION_PROCESS = "erx:i([processes, {pid, #{FIRST_SESSION + 1}, 0, 0}]).\r".freeze
    # erx:i/1's reductions line, whose value only the session's runtime reports; a
    # missed or refused answer shows a status in its place.
    SESSION_REDUCTIONS = /\A +reductions +runtime +[0-9]+\r*\n\z/n
    RESTART_STORAGE = '[S] = [Pid || #{origin := {configured, _}, node := storage@erxos, pid := Pid} <- ' \
                      'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                      'Old = erx:cap(data), exit(S, kill), '
    # Typed at either command shell: the domain service runs in the system domain only, so
    # the session's `ps` counts 0 of it and the system's 1.
    COUNT_SERVICE = "ps | grep -c erx_domain_srv\r"
    # Typed at root's session's command shell: the kernel log's line for the storage domain's
    # volume. dmesg reads /proc/kernel/log, which the session's /proc tree answers through the
    # session's inspect facet at the facet's scope, `all` for root in a development build, as
    # the system shell reads it through its own tree (MediumBoot).
    KERNEL_LOG = "dmesg | grep 'erx_lfs: volume mounted'\r"
    KERNEL_LOG_LINE = /\A#[0-9]+ [0-9]+\.[0-9]{6} debug space [0-9]+: erx_lfs: volume mounted\r*\n\z/n
    # `uname -b` at the session's command shell: the boot image's build identifier, which
    # the domain library gives every domain it starts, as the root gives the system domain.
    # A library that never set the identifier would give 0, which is no build's.
    BUILD_ID = /\A(?!0{16})[0-9a-f]{16}\r*\n\z/n
    # `top -b` at root_1's command shell: one display, whose header reads the machine's
    # figures and the session domain's through the session's inspect facet.
    TOP = "top -b\r"
    TOP_FIRST = /\Arun queue: [0-9]+;  up [0-9]+\+[0-9]{2}:[0-9]{2}:[0-9]{2}    /n
    TOP_MEMORY = /\AMem \(root pool\): [0-9]+[KMG] Total, [0-9]+[KMG] Free\r*\n\z/n
    TOP_BUDGET = /\ADomain #{FIRST_SESSION} budget(?: \([^)]+\)| \[[a-z ]+\])?: /n
    # `cat /proc/status` at root_1's command shell: the machine's record through the
    # session's /proc tree, its uptime line first.
    PROC_STATUS = "cat /proc/status\r"
    PROC_UPTIME = /\Auptime\t[0-9]+\tkernel\r*\n\z/n
    # The start service's tree at root_1's command shell (docs/design-apps.md,
    # "Interfaces"): root's template holds the apps grant, so rc.conf reads, and a ctl
    # write naming no manifest row is refused with an errno.
    APPS_RC_CONF = "cat /apps/rc.conf && echo apps-read\r"
    APPS_CTL_REFUSED = "echo enable ghost > /apps/ctl || echo ctl-refused\r"
    # `service -e` there: the configured domains in boot order and the enabled rows, read
    # from /proc/apps through the session's inspect facet, with status 0.
    SERVICE_E = "service -e && echo service-listed\r"
    # erx:i([]) at root_1's Erlang shell: the machine's record through the session's facet.
    MACHINE = "erx:i([]).\r"
    MACHINE_UPTIME = /\A +uptime +kernel +[0-9]+\r*\n\z/n
    # V10 across the session's facet (docs/design-live.md, Invariants): the records of the
    # system domain's processes <4.N.0> below N = V10_PROCESSES, each a query of its own, as
    # either domain asks for them (V10_RECORDS). The system domain's Erlang shell notes
    # erx:exports/1 of every process those records name as a group leader, a link or a
    # monitor; root's session reads the same records through its facet, at scope `all`; and
    # the system shell then finds each of those names, of a process still alive, exported
    # exactly as before, so the answers handed root's domain no name.
    V10_PROCESSES = 100
    V10_RECORDS = "V10Rs = [V10R || V10N <- lists:seq(0, #{V10_PROCESSES - 1}), " \
                  '{ok, V10R} <- [erx_inspector:inspect([processes, {pid, 4, V10N, 0}])]], '
    V10_BEFORE = 'V10Pid = fun({pid, V10D, V10N, V10S}) -> ' \
                 'list_to_pid(lists:flatten(io_lib:format("<~b.~b.~b>", [V10D, V10N, V10S]))) end, ' \
                 "#{V10_RECORDS}" \
                 'V10Names = lists:usort([V10Pid(V10I) || #{attrs := V10A} <- V10Rs, ' \
                 'V10K <- [group_leader, links, monitors], {_, {ok, V10V}} <- [maps:get(V10K, V10A, none)], ' \
                 'V10I <- lists:flatten([V10V]), element(2, V10I) =:= 4]), ' \
                 'V10Before = [{V10X, erx:exports(V10X)} || V10X <- V10Names, is_process_alive(V10X)], ' \
                 'io:format("~0p~n", [{v10_names, length(V10Names) > 10, ' \
                 "[V10M || \#{attrs := \#{monitors := {_, {ok, [_ | _] = V10M}}}} <- V10Rs] =/= []}]).\r"
    V10_BEFORE_ANSWER = '{v10_names,true,true}'
    V10_READ = "#{V10_RECORDS}io:format(\"~0p~n\", [{v10_read, length(V10Rs) > 10}]).\r"
    V10_READ_ANSWER = '{v10_read,true}'
    V10_AFTER = 'io:format("~0p~n", [{v10_changed, [{V10X, V10E, erx:exports(V10X)} || ' \
                "{V10X, V10E} <- V10Before, is_process_alive(V10X), erx:exports(V10X) =/= V10E]}]).\r"
    V10_AFTER_ANSWER = '{v10_changed,[]}'

    module_function

    def answer(text) = /\A#{PROMPT}#{Regexp.escape(text)}\r*\n\z/n

    def line(text) = /\A#{Regexp.escape(text)}\r*\n\z/n

    # Typed at an Erlang shell: polls until erx:cap(data) is a pid Grant that satisfies
    # guard, an Erlang guard, then evaluates action, an expression; `timeout` after 240
    # polls 500 ms apart. A session's grant arrives some time after its shell starts, since
    # the storage domain mints it once the session has reported ready, and until it arrives
    # every lookup under /data answers eio.
    def with_data(action, guard: 'true')
      '(fun Wait(0) -> timeout; Wait(N) -> case erx:cap(data) of ' \
        "Grant when is_pid(Grant), #{guard} -> #{action}; _ -> timer:sleep(500), Wait(N - 1) end end)(240).\r"
    end

    # A menu line with key and label, marked as the line's return or not.
    def menu_line(key, label) = /\A  #{key}[ *] #{Regexp.escape(label)}\r*\n\z/n

    # The menu line listing session name of domain id.
    def menu_entry(key, name, id) = menu_line(key, "#{name} (domain #{id})")

    def burst_line(number) = format("%04d %s\r\n", number, 'x' * 58)

    # The session's own command shell, whose banner its tty held until the line connected.
    def session_shell(name, typed)
      { name: name, pattern: line(SESSION_SHELL_BANNER), seconds: SESSION_SECONDS, type: typed }.freeze
    end

    # The burst's lines in the serial log's text: raises unless the menu opened between its
    # first and last lines and, with each menu taken out, every line is there whole and in
    # order. The console ends a line it interrupts, so a burst line the menu cut is whole
    # again once the menu is out.
    def burst_whole!(text)
      text = text.b
      first = text.index(burst_line(1)) or raise Error, 'the burst never started'
      menu = text.index(MENU_BLOCK, first)
      last = text.index(burst_line(BURST_LINES), first)
      raise Error, 'the menu did not open while the burst was being written' unless menu && (last.nil? || menu < last)

      expected = (1..BURST_LINES).map { |number| burst_line(number) }.join
      raise Error, 'the burst did not arrive whole and in order' unless text.gsub(MENU_BLOCK, '').include?(expected)

      true
    end

    # The production checkpoints to the system's command shell, then the cell. points must
    # end at the command shell.
    def root_session_checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell = ProductionImage::Run::ERLANG_SHELL
      [*points,
       session_shell('root_1-shell', "ls /data && echo data-listed\r"),
       { name: 'data-listed', pattern: line('data-listed'), seconds: 60, type: "echo hi\r" }.freeze,
       { name: 'echo-hi', pattern: line('hi'), seconds: 60, type: "echo x > /tmp/session; ls /tmp\r" }.freeze,
       { name: 'ls-tmp', pattern: line('session'), seconds: 60, type: COUNT_SERVICE }.freeze,
       { name: 'session-ps', pattern: line('0'), seconds: 60, type: KERNEL_LOG }.freeze,
       { name: 'session-dmesg', pattern: KERNEL_LOG_LINE, seconds: 60, type: "uname -a\r" }.freeze,
       { name: 'session-uname', pattern: MediumBoot::UNAME_A, seconds: 60, type: "uname -b\r" }.freeze,
       { name: 'session-build', pattern: BUILD_ID, seconds: 60, type: TOP }.freeze,
       { name: 'session-top', pattern: TOP_FIRST, seconds: 60 }.freeze,
       { name: 'session-top-memory', pattern: TOP_MEMORY, seconds: 30 }.freeze,
       { name: 'session-top-budget', pattern: TOP_BUDGET, seconds: 30, type: PROC_STATUS }.freeze,
       { name: 'session-proc-status', pattern: PROC_UPTIME, seconds: 60, type: APPS_RC_CONF }.freeze,
       { name: 'session-apps-rc-conf', pattern: line('apps-read'), seconds: 60, type: APPS_CTL_REFUSED }.freeze,
       { name: 'session-apps-ctl-refused', pattern: line('ctl-refused'), seconds: 60, type: SERVICE_E }.freeze,
       { name: 'session-service-e', pattern: line('service-listed'), seconds: 60, type: ERL }.freeze,
       shell.merge(name: 'root_1-erlang-shell', type: "node().\r").freeze,
       { name: 'root_1-node', pattern: answer('root_1@erxos'), seconds: 60, type: MACHINE }.freeze,
       { name: 'root_1-machine', pattern: MACHINE_UPTIME, seconds: 60, type: PROGRAM_REFUSED }.freeze,
       { name: 'program-refused', pattern: answer('{{error,einval},{error,einval}}'), seconds: 60,
         type: PIPES }.freeze,
       { name: 'session-pipes', pattern: answer(PIPES_ANSWER), seconds: 120, type: PIPES_LOST }.freeze,
       { name: 'session-pipes-lost', pattern: answer(PIPES_LOST_ANSWER), seconds: 120,
         type: with_data(WRITE_ACROSS) }.freeze,
       { name: 'session-data', pattern: answer(ACROSS_READ), seconds: 180, type: BURST }.freeze,
       { name: 'burst-first', pattern: line(burst_line(1).chomp("\r\n")), seconds: 60, type: CTRL_G }.freeze,
       { name: 'burst-menu', pattern: CTRL_G_MENU, seconds: 30, type: ESC }.freeze,
       { name: 'burst-end', pattern: answer('ok'), seconds: 120, type: "halt(3).\r" }.freeze,
       { name: 'root_1-ended', pattern: line('session root_1 ended: {halt,3}'), seconds: 60 }.freeze,
       session_shell('relogin-shell', CTRL_G),
       { name: 'relogin-menu', pattern: CTRL_G_MENU, seconds: 30 }.freeze,
       { name: 'relogin-listed', pattern: menu_entry(1, 'root_1', FIRST_SESSION + 1), seconds: 30 }.freeze,
       { name: 'start-entry', pattern: menu_line('n', 'start a session'), seconds: 30, type: 'n' }.freeze,
       { name: 'start-refused', pattern: /\Aerx_console: cannot start a session: /n, seconds: 60, type: 's' }.freeze,
       { name: 'system-shell', pattern: MENU_LEFT, seconds: 30, type: COUNT_SERVICE }.freeze,
       { name: 'system-ps', pattern: line('1'), seconds: 60, type: CAT_ACROSS }.freeze,
       { name: 'system-data', pattern: line('across'), seconds: 60, type: ERL }.freeze,
       shell.merge(name: 'system-erlang-shell', type: "node().\r").freeze,
       { name: 'system-node', pattern: answer('system@erxos'), seconds: 60, type: SESSION_PROCESS }.freeze,
       { name: 'session-process', pattern: SESSION_REDUCTIONS, seconds: 60,
         type: RESTART_STORAGE + with_data(READ_ACROSS, guard: 'Grant =/= Old') }.freeze,
       { name: 'storage-regranted', pattern: answer(ACROSS_READ), seconds: 180, type: KILL_SESSION }.freeze,
       { name: 'session-killed', pattern: answer('true'), seconds: 60 }.freeze,
       session_shell('killed-relogin-shell', CTRL_G),
       { name: 'killed-relogin-menu', pattern: CTRL_G_MENU, seconds: 30 }.freeze,
       { name: 'killed-relogin-listed', pattern: menu_entry(1, 'root_1', FIRST_SESSION + 4), seconds: 30,
         type: ESC }.freeze,
       { name: 'killed-relogin-left', pattern: MENU_LEFT, seconds: 30, type: ERL }.freeze,
       shell.merge(name: 'relogin-erlang-shell', type: with_data(READ_ACROSS)).freeze,
       { name: 'relogin-data', pattern: answer(ACROSS_READ), seconds: 180, type: CTRL_G }.freeze,
       { name: 'v10-menu', pattern: CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'v10-system', pattern: MENU_LEFT, seconds: 30, type: V10_BEFORE }.freeze,
       { name: 'v10-before', pattern: answer(V10_BEFORE_ANSWER), seconds: 120, type: CTRL_G }.freeze,
       { name: 'v10-session-menu', pattern: CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'v10-session', pattern: MENU_LEFT, seconds: 30, type: V10_READ }.freeze,
       { name: 'v10-read', pattern: answer(V10_READ_ANSWER), seconds: 120, type: CTRL_G }.freeze,
       { name: 'v10-after-menu', pattern: CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'v10-after-system', pattern: MENU_LEFT, seconds: 30, type: V10_AFTER }.freeze,
       { name: 'v10-unchanged', pattern: answer(V10_AFTER_ANSWER), seconds: 120, type: CTRL_G }.freeze,
       { name: 'v10-back-menu', pattern: CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'v10-back', pattern: MENU_LEFT, seconds: 30, type: IDLE_PROCESSES }.freeze,
       { name: 'idle-processes', pattern: answer('ok'), seconds: 60 }.freeze].freeze
    end

    # Boots the production image under HVF at each CPU count, where placement puts each
    # cell, each from a fresh copy of the release medium. Returns { "<accel>-<n>cpu" =>
    # 'passed' }; any disagreement raises.
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
      end

      # Packs the production image once and builds the web client the one-CPU cell's
      # front end serves (web_check), then boots the image at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        WebBuild.build(root: @root, runner: @runner) if cpus.include?(1)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/session-domain/image'))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                             fiasco: fiasco)
                                        .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", root_session(accel, count, remote, built, written)]
        end
      end

      private

      def root_session(accel, count, remote, built, written)
        run = "#{accel}-#{count}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(@root, 'build/session-domain', run))
        medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors, volume: written.volume)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                     .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                          memory_mib: @machine.memory_mib,
                          disks: [QemuPlan::Disk.new(path: medium)],
                          checkpoints: SessionDomain.root_session_checkpoints(points),
                          **web_check(accel, count, built, directory: File.join(directory, 'boot')))
        SessionDomain.burst_whole!(File.binread(report.fetch('serial_log')))
        'passed'
      end

      # At one CPU, once the transcript is whole, the host opens the web facet and a
      # browser's open of the machine's path is answered with the machine's record
      # through root's line (HostlinkGuest.machine), and then again through the host
      # tool's front end, tools/erx web, as a browser makes it (WebGuest): the one cell
      # whose console has logged root in and has a host link. The link's time is the
      # first check's two waits and the second's worst case. The boot's directory, which
      # holds the host link's socket, is then a short one under build/qemu, as the
      # production image's host link boot's is, since a UNIX socket's path is short;
      # otherwise it is directory.
      def web_check(accel, count, built, directory:)
        return { directory: directory } unless count == 1

        hash = HostlinkGuest.web_hash(@root)
        { directory: File.join(@root, 'build/qemu', "sd-#{accel}-#{Process.pid}"),
          link: lambda do |socket|
            { machine: HostlinkGuest.machine(socket, build: built.build_id, web_hash: hash),
              front_end: WebGuest.call(socket, root: @root, build: built.build_id, web_hash: hash, foreign: NEVER_USED_DOMAIN) }
          end,
          link_seconds: (HostlinkGuest::WEB_SECONDS * 2) + WebGuest::SECONDS }
      end
    end
  end
end
