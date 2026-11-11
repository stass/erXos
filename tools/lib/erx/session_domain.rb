# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_medium'
require_relative 'runner'

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
  # command shell's. There `echo hi` answers, `ls /tmp` lists a file the shell wrote, and
  # `ps` lists none of the system domain's processes. The session's Erlang shell answers
  # node() as root_1@erxos, writes a line to /data/across, the storage domain's tree
  # through the session's `data` facet, and reads it back once that grant has arrived
  # (with_data), and writes 64 KiB in numbered lines while Ctrl-G opens the menu and Esc
  # leaves it mid-burst; the serial log, with the menu taken out, holds every line whole
  # and in order (burst_whole!).
  # halt(3) ends the session's domain: the console writes `session root_1 ended:
  # {halt,3}` and logs root in again, and the new session, root_1 again in a new domain,
  # takes the line. The menu lists it, refuses "start a session" past the principal's
  # domain quota, which the storage and network domains and the session fill, and gives the line to
  # the system shell, whose `ps` lists the domain service and whose `cat` reads
  # /data/across through the system domain's own `data` facet. Its Erlang shell answers
  # node() as system@erxos and ends the storage domain with exit(DomainPid, kill); once
  # the domain's restart has installed a new `data` grant, a new read of /data/across
  # answers the line the session wrote (RESTART_STORAGE). exit(DomainPid, kill) of the
  # session then ends it as halt does, the next login's session takes the line, and its
  # Erlang shell reads /data/across through the restarted storage domain's grant.
  module SessionDomain
    MACHINE = ProductionImage::DEVELOPMENT_MACHINE
    # The prompt an Erlang shell's answer line may carry, of either domain's shell.
    PROMPT = '(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?'
    CTRL_G = ProductionImage::Run::CTRL_G
    CTRL_G_MENU = ProductionImage::Run::CTRL_G_MENU
    ESC = ProductionImage::Run::ESC
    # The menu's close, its reset at the end of a line: a session starting while the menu
    # is up may write its runtime's kernel log lines between "Esc returns. " and the reset.
    MENU_LEFT = /\e\\\e\[0m\r*\n\z/n
    ERL = ProductionImage::Run::ERL_LINE
    # The domain id root's first session takes: the development manifest configures two
    # domains, network and storage, which take the domain service's first ids, 5 and 6, at
    # boot, so the login's is 7; each later start of a session or of a configured domain
    # takes the next, a refused one too, since admission spends the id.
    FIRST_SESSION = 7
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
    # domain service holds, beside the configured storage and network domains, killed, as a person
    # would end a session from there.
    KILL_SESSION = '[P] = [Pid || #{origin := {session, _}, pid := Pid} <- ' \
                   'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                   "exit(P, kill).\r".freeze
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
    RESTART_STORAGE = '[S] = [Pid || #{origin := {configured, _}, node := storage@erxos, pid := Pid} <- ' \
                      'erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv)))], ' \
                      'Old = erx:cap(data), exit(S, kill), '
    # Typed at either command shell: the domain service runs in the system domain only, so
    # the session's `ps` counts 0 of it and the system's 1.
    COUNT_SERVICE = "ps | grep -c erx_domain_srv\r"

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
       session_shell('root_1-shell', "echo hi\r"),
       { name: 'echo-hi', pattern: line('hi'), seconds: 60, type: "echo x > /tmp/session; ls /tmp\r" }.freeze,
       { name: 'ls-tmp', pattern: line('session'), seconds: 60, type: COUNT_SERVICE }.freeze,
       { name: 'session-ps', pattern: line('0'), seconds: 60, type: ERL }.freeze,
       shell.merge(name: 'root_1-erlang-shell', type: "node().\r").freeze,
       { name: 'root_1-node', pattern: answer('root_1@erxos'), seconds: 60, type: with_data(WRITE_ACROSS) }.freeze,
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
       { name: 'system-node', pattern: answer('system@erxos'), seconds: 60,
         type: RESTART_STORAGE + with_data(READ_ACROSS, guard: 'Grant =/= Old') }.freeze,
       { name: 'storage-regranted', pattern: answer(ACROSS_READ), seconds: 180, type: KILL_SESSION }.freeze,
       { name: 'session-killed', pattern: answer('true'), seconds: 60 }.freeze,
       session_shell('killed-relogin-shell', CTRL_G),
       { name: 'killed-relogin-menu', pattern: CTRL_G_MENU, seconds: 30 }.freeze,
       { name: 'killed-relogin-listed', pattern: menu_entry(1, 'root_1', FIRST_SESSION + 4), seconds: 30,
         type: ESC }.freeze,
       { name: 'killed-relogin-left', pattern: MENU_LEFT, seconds: 30, type: ERL }.freeze,
       shell.merge(name: 'relogin-erlang-shell', type: with_data(READ_ACROSS)).freeze,
       { name: 'relogin-data', pattern: answer(ACROSS_READ), seconds: 180 }.freeze].freeze
    end

    # Boots the production image under HVF at each CPU count, where placement puts each
    # cell, each from a fresh copy of the release medium. Returns { "<accel>-<n>cpu" =>
    # 'passed' }; any disagreement raises.
    class Run
      def self.cells(cpus) = cpus.map { |count| QemuCells::Cell.new(accel: QemuCells::LOCAL_ACCELERATOR, cpus: count).name }

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @manifest = File.binread(File.join(@root, ProductionImage::MANIFEST))
      end

      # Packs the production image once, then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/session-domain/image'))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                        .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest)
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
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib)
        report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                     .run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MACHINE.memory_mib,
                          directory: File.join(directory, 'boot'), disks: [QemuPlan::Disk.new(path: medium)],
                          checkpoints: SessionDomain.root_session_checkpoints(points))
        SessionDomain.burst_whole!(File.binread(report.fetch('serial_log')))
        'passed'
      end
    end
  end
end
