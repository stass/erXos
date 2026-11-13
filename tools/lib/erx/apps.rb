# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'release_files'
require_relative 'release_medium'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The start table on the development machine (docs/design-apps.md, "Verification and
  # testing"): an app is a principal, clock, with a session template whose release boots
  # the test-only application erx_clock_test, a `data` grant, and a `start` row, so its
  # session starts at boot with no login and is started again when it ends.
  #
  # Each cell boots three test images (ProductionImage#build_test_image, with a release
  # medium so the storage domain serves /data and the start service reads rc.conf), each
  # from the development manifest with root's session template, so the console logs root
  # in and root_1 takes the line:
  #
  # * kept: the row enabled with an intensity of one end in ten minutes. clock_1 boots
  #   with no login and erx_clock_test logs what its session holds (CLOCK_REPORT): its
  #   template's one grant, `data`, and nothing of root's, no `apps` among them, so
  #   erx:cap(apps) is undefined and /apps does not exist where /data lists. At root_1's
  #   command shell `service ghost enable` is refused, ghost having no manifest row. At
  #   the system's Erlang shell the row is running; clock's session is killed, a new one
  #   takes its place, that one is killed too, and the row is then down (KILL_CLOCK).
  #   Back at root_1, `service clock status` says the row is down, and so does
  #   /proc/apps/clock/status, and `service -e` still lists the row, which is enabled.
  # * disabled: the same row with `enable NO`, the kept boot's seeded fault: no session
  #   of clock starts and the row is disabled (NO_CLOCK).
  # * unlisted: no `start` row: no session but root's console login (AP2), and
  #   /proc/apps has no clock.
  #
  # Then the kept image boots three times from one copy of its medium (CHAIN), so what
  # `service` wrote to rc.conf on /data is what the next boot reads:
  #
  # * disable: once clock's row is running and its session has reported (CLOCK_UP),
  #   `service clock disable` at root_1's command shell says so, and
  #   /proc/apps/clock/status gives the row disabled.
  # * reenable: the row the manifest enables is disabled by rc.conf alone, so no session
  #   of clock starts (NO_CLOCK); `service clock enable` then starts one.
  # * enabled: clock's session starts again with no command, so rc.conf now enables
  #   the row that the reenable boot found it disabling.
  #
  # The report lines of clock's sessions arrive whenever their sessions get their
  # grants, interleaved with root's login, so they are read from the whole serial log
  # once a boot has ended (reports!) rather than as checkpoints.
  module Apps
    # The app's principal, its sessions' name prefix, and the boot script of its
    # template's release: what every session boots, the command shell and erx_session,
    # which the template's -eval starts, and the test-only app. It holds neither
    # erx_net_client nor the line to the web domain (ReleaseFiles::RELEASE_SCRIPTS), since
    # the template is granted neither net nor web.
    PRINCIPAL = 'clock'
    BOOT = ReleaseFiles.domain_boot(PRINCIPAL, applications: [*ReleaseFiles::DOMAIN_BASE, 'erx_shell',
                                                              'erx_session', 'erx_clock_test'],
                                               test: true)
    # A session of clock's profile, limits app, takes the development manifest's session
    # profile's memory and outer budget; clock's principal holds two at once, so a kept session's
    # successor is admitted while its predecessor's domain is still being taken down,
    # and 1 MiB of slack, as the system principal keeps. The machine's root_memory grows
    # by the principal's memory, max_domains by its two domains, and max_connections by
    # the system connection and data grant of a session and of its successor.
    LIMITS_MEMORY = 37_748_736
    LIMITS_OUTER = 1_048_576
    SESSION_MEMORY = LIMITS_MEMORY + LIMITS_OUTER
    MEMORY = (2 * SESSION_MEMORY) + 1_048_576
    DOMAINS = 2
    CONNECTIONS = 4
    TEMPLATE_ARGS = '-- -root / -bindir /bin -progname erl -home / -nouser -nocookie -no_epmd -proto_dist erx ' \
                    '-eval ok=application:start(erx_session)'
    APP = <<~ROWS.freeze
      limits app
        memory #{LIMITS_MEMORY}
        outer #{LIMITS_OUTER}
        grant @share.users
        spaces @share.users
        lane 65536
        connections 4
        crash 0
        flags spaces
        runtime_limits @runtime_limits.session
        peer_held 4096
        peer_held_total 4096
      principal #{PRINCIPAL}
        memory #{MEMORY}
        grant @share.users
        domains #{DOMAINS}
        names 4
        default_limits @limits.app
        ceiling_limits @limits.app
      session #{PRINCIPAL}
        limits @limits.app
        runtime @artifact.emu
        release @artifact.#{BOOT.name}
        args "#{TEMPLATE_ARGS}"
      facet clock_data
        name "data"
        grantee @session.#{PRINCIPAL}
        service @service.data
        operations none
        max_request 131072
        in_flight 16
        reductions 100000
        period_ns 1000000000
        max_heap_size 262144
    ROWS
    # The start rows of the three boots: the intensity one end in ten minutes, so the
    # second kill leaves the row down.
    START = { kept: "start #{PRINCIPAL}\n  enable YES\n  restarts 1\n  restart_period_s 600\n",
              disabled: "start #{PRINCIPAL}\n  enable NO\n  restarts 1\n  restart_period_s 600\n",
              unlisted: '' }.freeze
    GROWTH = { /^(  root_memory )([0-9]+)$/ => MEMORY, /^(  max_domains )([0-9]+)$/ => DOMAINS,
               /^(  max_connections )([0-9]+)$/ => CONNECTIONS }.freeze

    PROMPT = SessionDomain::PROMPT
    CTRL_G = ProductionImage::Run::CTRL_G
    CTRL_G_MENU = ProductionImage::Run::CTRL_G_MENU
    MENU_LEFT = ProductionImage::Run::MENU_LEFT
    ERL = ProductionImage::Run::ERL_LINE

    # Typed at the system's Erlang shell, where every variable carries the prefix Ck.
    # CkDoms is the domain service's domains; CkPid(Old, N) polls until a domain of
    # clock's sessions has a pid other than Old and answers it, `timeout` after N polls
    # 500 ms apart; CkState(Want, N) polls the same way until /proc/apps's row clock is
    # in state Want; CkLog(N) polls the kernel log the same way until a report of clock's
    # sessions is in it; CkRc() is whether the row is enabled and which of its fields
    # rc.conf set, rather than the manifest's start row.
    HELPERS = 'CkDoms = fun() -> erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv))) end, ' \
              'CkPid = fun CkF(_, 0) -> timeout; CkF(CkOld, CkN) -> ' \
              'case [CkP || #{origin := {session, _}, node := CkNode, pid := CkP} <- CkDoms(), is_pid(CkP), ' \
              "CkP =/= CkOld, lists:prefix(\"#{PRINCIPAL}_\", atom_to_list(CkNode))] of " \
              '[CkP | _] -> CkP; [] -> timer:sleep(500), CkF(CkOld, CkN - 1) end end, ' \
              'CkState = fun CkS(_, 0) -> timeout; CkS(CkWant, CkN) -> ' \
              "case erx_inspector:inspect([apps, <<\"#{PRINCIPAL}\">>]) of " \
              '{ok, #{attrs := #{state := {_, {ok, CkWant}}}}} -> CkWant; ' \
              '_ -> timer:sleep(500), CkS(CkWant, CkN - 1) end end, ' \
              'CkLog = fun CkL(0) -> timeout; CkL(CkN) -> case file:read_file("/proc/kernel/log") of {ok, CkB} -> ' \
              'case binary:match(CkB, <<"erx_clock_test: {clock_", "report,">>) of ' \
              'nomatch -> timer:sleep(500), CkL(CkN - 1); _ -> reported end; CkE -> CkE end end, ' \
              "CkRc = fun() -> case erx_inspector:inspect([apps, <<\"#{PRINCIPAL}\">>]) of " \
              '{ok, #{attrs := #{enabled := {_, {ok, CkEn}}, local := {_, {ok, CkLo}}}}} -> {CkEn, CkLo}; ' \
              'CkO -> CkO end end, '
    # The row running and its session's report in the kernel log, which the console
    # also prints (CLOCK_REPORT), so the session lived to report; the configured
    # domains' grants the domain service holds for that session, each with its state
    # (CkGrants, polled until none is still being introduced, minted or installed, since
    # a facet reaches the session before the domain service hears it installed); then
    # that session killed, the next one killed once it has a domain pid, and the row
    # down: one end more than its intensity allows.
    #
    # The session's own report sees the grants of its ready answer, which arrive before
    # its applications start, but a configured domain's grant may arrive after data. The
    # domain service enters every grant of the session's template at once when the
    # session reports ready (erx_domain_mints, session_ready), so the grants read here
    # are all there will be, and data alone, installed, says no other is coming. A
    # second look at erx:caps() later would only shrink that window, not close it.
    KILL_CLOCK = "#{HELPERS}CkGrants = fun CkGr(_, 0) -> timeout; CkGr(CkPd, CkN) -> " \
                 '#{grants := CkG} = gen_server:call(erx_domain_srv, mints), ' \
                 'CkHas = lists:sort([{CkGn, case CkGs of CkT when is_tuple(CkT) -> element(1, CkT); CkT -> CkT end} ' \
                 '|| #{id := CkI, pid := CkQ} <- CkDoms(), CkQ =:= CkPd, ' \
                 '{{session, CkJ}, CkGn} := CkGs <- CkG, CkJ =:= CkI]), ' \
                 'case [CkS || {_, CkS} <- CkHas, lists:member(CkS, [introducing, minting, installing])] of ' \
                 '[] -> CkHas; _ -> timer:sleep(500), CkGr(CkPd, CkN - 1) end end, ' \
                 'CkRun = CkState(running, 600), CkReported = CkLog(600), CkP1 = CkPid(none, 600), ' \
                 'CkHeld = CkGrants(CkP1, 20), exit(CkP1, kill), ' \
                 'CkP2 = CkPid(CkP1, 600), exit(CkP2, kill), ' \
                 'io:format("~0p~n", [{clock_killed, CkRun, CkReported, CkHeld, is_pid(CkP1), is_pid(CkP2), ' \
                 "CkState(down, 240)}]).\r"
    KILLED = '{clock_killed,running,reported,[{data,installed}],true,true,down}'
    # Every poll of KILL_CLOCK at its limit, 500 ms each, and a minute more, so a step
    # that times out answers `timeout` in the line rather than the checkpoint expiring.
    KILL_SECONDS = (((4 * 600) + 20 + 240) / 2) + 60
    # The sessions the domain service holds 20 s after the start service has read
    # rc.conf, time enough for a kept session to get a domain, and what /proc/apps says
    # of clock's row: for a row left off, the state disabled and the fields rc.conf set,
    # and the error scope where no row exists. It waits for rc.conf to be read, not only
    # for the table to be made: while rc.conf cannot be read the table holds the
    # manifest's rows alone, which would start a row that rc.conf disables.
    NO_CLOCK = "#{HELPERS}CkRead = fun CkM(0) -> timeout; CkM(CkN) -> case erx_inspector:inspect([apps]) of " \
               '{ok, #{attrs := #{rc_conf := {_, {ok, read}}}}} -> read; _ -> timer:sleep(500), CkM(CkN - 1) end end, ' \
               'CkRead(240) =:= read orelse exit(unread), timer:sleep(20000), ' \
               "CkRow = case erx_inspector:inspect([apps, <<\"#{PRINCIPAL}\">>]) of " \
               '{ok, #{attrs := #{state := {_, {ok, CkSt}}, local := {_, {ok, CkLo}}}}} -> {CkSt, CkLo}; ' \
               'CkO -> CkO end, ' \
               "io:format(\"~0p~n\", [{no_clock, lists:sort([CkName || \#{origin := {session, _}, node := CkName} <- CkDoms()]), CkRow}]).\r"
    NO_CLOCK_ANSWER = { disabled: '{no_clock,[root_1@erxos],{disabled,[]}}',
                        reenable: '{no_clock,[root_1@erxos],{disabled,[enable]}}',
                        unlisted: '{no_clock,[root_1@erxos],{error,scope}}' }.freeze
    # The row running and its session's report in the kernel log, polled as KILL_CLOCK
    # polls them, and then whether the row is enabled and by what (CkRc): by the
    # manifest alone before any `service` command, by rc.conf once `enable` has written
    # it. CLOCK_UP_POLLS is for a shell where HELPERS is already bound, since binding
    # its variables again to new funs would not match.
    CLOCK_UP_POLLS = "io:format(\"~0p~n\", [{clock_up, CkState(running, 600), CkLog(600), CkRc()}]).\r"
    CLOCK_UP = "#{HELPERS}#{CLOCK_UP_POLLS}"
    CLOCK_IS_UP = { disable: '{clock_up,running,reported,{true,[]}}',
                    reenable: '{clock_up,running,reported,{true,[enable]}}',
                    enabled: '{clock_up,running,reported,{true,[enable]}}' }.freeze
    CLOCK_UP_SECONDS = ((600 + 600) / 2) + 60
    # At root_1's command shell (docs/design-apps.md, "Interfaces").
    SERVICE_GHOST = "service ghost enable || echo ghost-refused\r"
    GHOST_WHY = 'service: ghost does not exist in the system manifest'
    SERVICE_STATUS = "service #{PRINCIPAL} status || echo status-failed\r"
    STATUS_DOWN = "#{PRINCIPAL} is not running (down)."
    # The row's record at /proc/apps/clock/status, one attribute a line (erx_procfs_core).
    PROC_GREP = "grep '^state' /proc/apps/#{PRINCIPAL}/status\r"
    # `service NAME enable` and `disable` print the file they changed, then the echo
    # says the command's status was 0.
    SERVICE_DISABLE = "service #{PRINCIPAL} disable && echo disable-done\r"
    SERVICE_ENABLE = "service #{PRINCIPAL} enable && echo enable-done\r"
    DISABLED_IN = "#{PRINCIPAL} disabled in /apps/rc.conf"
    ENABLED_IN = "#{PRINCIPAL} enabled in /apps/rc.conf"
    # `service -e`: the configured domains, then the enabled rows, a row that is down
    # among them, with status 0.
    SERVICE_E = "service -e && echo service-listed\r"
    # What every report line of clock's sessions says (erx_clock_test:report/0): a
    # session of clock holding the data grant alone, erx:cap(apps) undefined, no /apps,
    # and /data listed.
    # Each anchored at the kernel log record's own prefix, which no echo of a typed line has.
    CLOCK_REPORT = /space [0-9]+: notice: erx_clock_test: \{clock_report,#{PRINCIPAL}_[0-9]+@erxos,\[data\],true,\{error,enoent\},ok\}/n
    ANY_REPORT = /space [0-9]+: notice: erx_clock_test: \{clock_report,/n
    TIMED_OUT = /space [0-9]+: notice: erx_clock_test: \{clock_report,[^,]+,timeout\}/n
    # Any line of the app's, its start's among them, or any line naming a node of
    # clock's sessions, which a session the start service stopped before its app
    # logged anything may still have left.
    ANY_LINE = /space [0-9]+: [a-z]+: erx_clock_test: |#{PRINCIPAL}_[0-9]+@erxos/n

    module_function

    def answer(text) = SessionDomain.answer(text)

    def line(text) = SessionDomain.line(text)

    # PROC_GREP's answer for a row in state, then its reporter's label.
    def proc_state(state) = /\Astate\t#{Regexp.escape(state)}\t[^\t\r\n]+\r*\n\z/n

    # The development manifest source with clock's principal, template and data grant,
    # the start row of boot (START), and the machine grown to hold clock's sessions.
    def manifest(source, boot:)
      grown = GROWTH.reduce(source) do |text, (pattern, growth)|
        edit_once(text, pattern) { |match| Integer(match[2], 10) + growth }
      end
      grown + APP + START.fetch(boot)
    end

    # text with the one match of pattern replaced by its first group followed by what
    # the block answers for the match; raises unless pattern matches exactly once.
    def edit_once(text, pattern)
      raise Error, "the manifest does not match #{pattern.source} exactly once" unless text.scan(pattern).size == 1

      text.sub(pattern) { "#{Regexp.last_match(1)}#{yield Regexp.last_match}" }
    end

    # The production checkpoints to the system's command shell, then, in every boot,
    # root_1's command shell refusing ghost and the system's Erlang shell started from
    # the console's Ctrl-G menu, and the steps of boot from that Erlang shell on.
    #
    # A checkpoint's type is typed once its pattern is seen, so a step that ends at one
    # shell types CTRL_G, and the next step, to_session or to_system, takes the menu.
    def checkpoints(points, boot:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      erlang = ProductionImage::Run::ERLANG_SHELL.merge(name: 'system-erlang-shell').freeze
      steps = case boot
              in :kept then kept_steps(erlang)
              in :disabled | :unlisted then no_clock_steps(erlang, boot)
              in :disable then disable_steps(erlang)
              in :reenable then reenable_steps(erlang)
              in :enabled then enabled_steps(erlang)
              end
      [*points, SessionDomain.session_shell('root_1-shell', SERVICE_GHOST),
       { name: 'ghost-why', pattern: line(GHOST_WHY), seconds: 60 }.freeze,
       { name: 'ghost-refused', pattern: line('ghost-refused'), seconds: 60, type: CTRL_G }.freeze,
       *to_system(ERL, name: 'system'),
       *steps].freeze
    end

    def kept_steps(erlang)
      [erlang.merge(type: KILL_CLOCK).freeze,
       { name: 'clock-killed', pattern: answer(KILLED), seconds: KILL_SECONDS, type: CTRL_G }.freeze,
       *to_session(SERVICE_STATUS),
       { name: 'status-down', pattern: line(STATUS_DOWN), seconds: 60 }.freeze,
       { name: 'status-failed', pattern: line('status-failed'), seconds: 60, type: PROC_GREP }.freeze,
       { name: 'proc-down', pattern: proc_state('down'), seconds: 60, type: SERVICE_E }.freeze,
       { name: 'service-e-clock', pattern: line(PRINCIPAL), seconds: 60 }.freeze,
       { name: 'service-listed', pattern: line('service-listed'), seconds: 60 }.freeze]
    end

    def no_clock_steps(erlang, boot, then_type: nil)
      [erlang.merge(type: NO_CLOCK).freeze,
       { name: 'no-clock', pattern: answer(NO_CLOCK_ANSWER.fetch(boot)), seconds: 240, type: then_type }.compact.freeze]
    end

    # The chain's first boot: clock up, then disabled at root_1's command shell, and
    # its row disabled at /proc/apps.
    def disable_steps(erlang)
      [erlang.merge(type: CLOCK_UP).freeze, clock_up(:disable, then_type: CTRL_G),
       *to_session(SERVICE_DISABLE),
       { name: 'disabled-in', pattern: line(DISABLED_IN), seconds: 60 }.freeze,
       { name: 'disable-done', pattern: line('disable-done'), seconds: 60, type: PROC_GREP }.freeze,
       { name: 'proc-disabled', pattern: proc_state('disabled'), seconds: 60 }.freeze]
    end

    # The chain's second boot: no session of clock and the row disabled by rc.conf,
    # then enabled at root_1's command shell, and clock up, back in the same Erlang
    # shell, where NO_CLOCK has bound HELPERS.
    def reenable_steps(erlang)
      [*no_clock_steps(erlang, :reenable, then_type: CTRL_G),
       *to_session(SERVICE_ENABLE),
       { name: 'enabled-in', pattern: line(ENABLED_IN), seconds: 60 }.freeze,
       { name: 'enable-done', pattern: line('enable-done'), seconds: 60, type: CTRL_G }.freeze,
       *to_system(CLOCK_UP_POLLS, name: 'system-again'), clock_up(:reenable)]
    end

    # The chain's last boot: clock up with no command, its row enabled by rc.conf.
    def enabled_steps(erlang) = [erlang.merge(type: CLOCK_UP).freeze, clock_up(:enabled)]

    # CLOCK_UP's answer for boot, with then_type typed once it is seen.
    def clock_up(boot, then_type: nil)
      { name: 'clock-up', pattern: answer(CLOCK_IS_UP.fetch(boot)), seconds: CLOCK_UP_SECONDS,
        type: then_type }.compact.freeze
    end

    # From the console's Ctrl-G menu to root_1's command shell, with typed typed there.
    def to_session(typed)
      [{ name: 'session-menu', pattern: CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'session-shell', pattern: MENU_LEFT, seconds: 30, type: typed }.freeze]
    end

    # From the console's Ctrl-G menu to the system's console job, with typed typed
    # there; its checkpoints are name-menu and name-shell.
    def to_system(typed, name:)
      [{ name: "#{name}-menu", pattern: CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: "#{name}-shell", pattern: MENU_LEFT, seconds: 30, type: typed }.freeze]
    end

    # Raises unless the serial log's text holds the report lines boot expects: at least
    # one, each CLOCK_REPORT, for a boot where clock runs, and none for the others. In
    # the reenable boot clock runs only from `service clock enable` on, which root_1
    # types after NO_CLOCK has answered, so the text before that answer, which the
    # no-clock checkpoint saw whole, holds no line of the app's.
    def reports!(text, boot:)
      bytes = text.b
      case boot
      in :kept | :disable | :enabled then clock_reports!(bytes)
      in :disabled | :unlisted then no_clock_lines!(bytes, boot)
      in :reenable
        answered_at = bytes.index(NO_CLOCK_ANSWER.fetch(:reenable))
        raise Error, 'the reenable boot never answered NO_CLOCK' unless answered_at

        no_clock_lines!(bytes[0...answered_at], boot)
        clock_reports!(bytes[answered_at..])
      end
      true
    end

    def clock_reports!(text)
      reports = text.lines.grep(ANY_REPORT)
      raise Error, 'no session of clock reported what it holds' if reports.empty?

      waited = reports.grep(TIMED_OUT)
      raise Error, "a session of clock never got its data grant: #{waited.first.inspect}" unless waited.empty?

      wrong = reports.grep_v(CLOCK_REPORT)
      raise Error, "a session of clock holds what its template does not grant: #{wrong.first.inspect}" unless wrong.empty?
    end

    def no_clock_lines!(text, boot)
      lines = text.lines.grep(ANY_LINE)
      raise Error, "a session of clock started in the #{boot} boot: #{lines.first.inspect}" unless lines.empty?
    end

    # Packs the three test images once, on a medium machine (MediumBoot.machine), then
    # boots each at each CPU count, where placement puts each cell, each from a fresh
    # copy of its release medium, and boots the kept image CHAIN's boots in order from
    # one more copy. Returns { "<accel>-<n>cpu" => 'passed' }; any disagreement raises.
    class Run
      BOOTS = %i[kept disabled unlisted].freeze
      CHAIN = %i[disable reenable enabled].freeze

      def self.cells(cpus) = cpus.map { |count| QemuCells::Cell.new(accel: QemuCells::LOCAL_ACCELERATOR, cpus: count).name }

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        source = platform.manifest_source(@root)
        @manifests = BOOTS.to_h { |boot| [boot, Apps.manifest(source, boot: boot)] }
      end

      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        images = BOOTS.to_h { |boot| [boot, image(fiasco, boot)] }
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          BOOTS.each { |boot| run_boots(accel: accel, cpus: count, remote: remote, boots: [boot], **images.fetch(boot)) }
          run_boots(accel: accel, cpus: count, remote: remote, boots: CHAIN, **images.fetch(:kept))
          ["#{accel}-#{count}cpu", 'passed']
        end
      end

      private

      # A test image under build/apps/<boot>/image carrying clock's boot script (BOOT),
      # with boot's manifest, and its release medium's parts (built and written).
      def image(fiasco, boot)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/apps', boot.to_s, 'image'))
        image = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                    fiasco: fiasco)
        nothing = ProductionImage::Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
        built = image.build_test_image(directory: directory, added: nothing, domains: [BOOT],
                                       manifest_source: @manifests.fetch(boot))
        { built: built, written: image.release_medium(built), manifest: @manifests.fetch(boot) }
      end

      # Boots built, packed with manifest, at cpus once for each of boots, in order, all
      # from one fresh copy of its release medium, so each boot finds /data as the one
      # before left it; the copy is removed once the last boot ends (each is about a
      # gigabyte). Each boot's report lines are checked as it ends, so a boot that fails
      # stops the rest.
      def run_boots(accel:, cpus:, remote:, boots:, built:, written:, manifest:)
        run = "#{boots.first}-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(@root, 'build/apps', run))
        medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors, volume: written.volume)
        begin
          boots.each do |boot|
            boot_once(accel: accel, cpus: cpus, remote: remote, boot: boot, built: built, manifest: manifest,
                      medium: medium, directory: File.join(directory, boot.to_s))
          end
        ensure
          FileUtils.rm_f(medium)
        end
      end

      # One boot of built, packed with manifest, from medium.
      def boot_once(accel:, cpus:, remote:, boot:, built:, manifest:, medium:, directory:)
        production = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: cpus,
                                                             manifest_source: manifest, memory_mib: @machine.memory_mib,
                                                             test_image: true)
        report = Qemu.new(root: @root, runner: @runner, program: @qemu)
                     .run(platform: @machine.platform, accel: accel, cpus: cpus, remote: remote, image: built.single,
                          memory_mib: @machine.memory_mib, disks: [QemuPlan::Disk.new(path: medium)],
                          checkpoints: Apps.checkpoints(production, boot: boot), directory: directory)
        Apps.reports!(File.binread(report.fetch('serial_log')), boot: boot)
      end
    end
  end
end
