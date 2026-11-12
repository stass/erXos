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
  # The report lines of clock's sessions arrive whenever their sessions get their
  # grants, interleaved with root's login, so they are read from the whole serial log
  # once a boot has ended (reports!) rather than as checkpoints.
  module Apps
    # The app's principal, its sessions' name prefix, and the boot script of its
    # template's release: what every session boots, the command shell and erx_session,
    # which the template's -eval starts, and the test-only app. It holds neither
    # erx_net_client nor the line to the web domain (ReleaseFiles::SESSION_ONLY), since
    # the template is granted neither net nor web.
    PRINCIPAL = 'clock'
    BOOT = ReleaseFiles.domain_boot(PRINCIPAL, applications: [*ProductionImage::DOMAIN_APPLICATIONS, 'erx_shell',
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
    # The principals' grants together fit within the users share (manifest property 4),
    # which the system principal takes whole in the development manifest, and users cannot
    # grow, since the system and users shares fill the machine's CPUs. How users is divided
    # among principals is not settled (TODO.md), so this split is the suite's own: root is
    # three quarters of users, and the system principal, its native profile and the session
    # share are moved onto it, because each profile must fit within its principal's grant;
    # app is the last quarter, clock's, on the CPU sessions run on.
    # The configured domains' profiles (storage, network) keep users, since a configured
    # domain's grant fits within the system share, not its principal's (dom_check_grants).
    # SHARES follows the share web.
    SHARES = <<~ROWS.freeze
      share root
        quota_ns 7500000
        period_ns 10000000
        cpuset 15
        capacity_mcpu 750
        capacity_first 0
        slice_us 1000
        grace_us 5
        base 16
        ceiling 31
        flags none
      share app
        quota_ns 2500000
        period_ns 10000000
        cpuset 1
        capacity_mcpu 250
        capacity_first 0
        slice_us 1000
        grace_us 5
        base 16
        ceiling 31
        flags none
    ROWS
    # Each edit of the development manifest's text for the split: a line that occurs
    # exactly once, and what its value becomes.
    SPLIT = { /^(limits native\n(?:  .*\n)*?  grant @share\.)users$/ => 'root',
              /^(principal system\n(?:  .*\n)*?  grant @share\.)users$/ => 'root',
              /^(share session\n  quota_ns )10000000$/ => '7500000',
              /^(share session\n(?:  .*\n)*?  capacity_mcpu )1000$/ => '750' }.freeze
    APP = <<~ROWS.freeze
      limits app
        memory #{LIMITS_MEMORY}
        outer #{LIMITS_OUTER}
        grant @share.app
        spaces @share.app
        lane 65536
        connections 4
        crash 0
        flags spaces
        runtime_limits @runtime_limits.session
        peer_held 4096
        peer_held_total 4096
      principal #{PRINCIPAL}
        memory #{MEMORY}
        grant @share.app
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
    # sessions is in it.
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
              'nomatch -> timer:sleep(500), CkL(CkN - 1); _ -> reported end; CkE -> CkE end end, '
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
    # The sessions the domain service holds 20 s after the start service has made its
    # table, time enough for a kept session to get a domain, and what /proc/apps says
    # of clock's row: the state disabled for a row left off, the error scope where no
    # row exists.
    NO_CLOCK = "#{HELPERS}CkMade = fun CkM(0) -> timeout; CkM(CkN) -> case erx_inspector:inspect([apps]) of " \
               '{ok, #{children := CkC}} when is_list(CkC) -> made; _ -> timer:sleep(500), CkM(CkN - 1) end end, ' \
               'CkMade(240) =:= made orelse exit(unmade), timer:sleep(20000), ' \
               "CkRow = case erx_inspector:inspect([apps, <<\"#{PRINCIPAL}\">>]) of " \
               '{ok, #{attrs := #{state := {_, {ok, CkSt}}}}} -> CkSt; CkO -> CkO end, ' \
               "io:format(\"~0p~n\", [{no_clock, lists:sort([CkName || \#{origin := {session, _}, node := CkName} <- CkDoms()]), CkRow}]).\r"
    NO_CLOCK_ANSWER = { disabled: '{no_clock,[root_1@erxos],disabled}',
                        unlisted: '{no_clock,[root_1@erxos],{error,scope}}' }.freeze
    # At root_1's command shell (docs/design-apps.md, "Interfaces").
    SERVICE_GHOST = "service ghost enable || echo ghost-refused\r"
    GHOST_WHY = 'service: ghost does not exist in the system manifest'
    SERVICE_STATUS = "service #{PRINCIPAL} status || echo status-failed\r"
    STATUS_DOWN = "#{PRINCIPAL} is not running (down)."
    # The row's record at /proc/apps/clock/status, one attribute a line (erx_procfs_core).
    PROC_DOWN = "grep '^state' /proc/apps/#{PRINCIPAL}/status\r"
    PROC_STATE = /\Astate\tdown\t[^\t\r\n]+\r*\n\z/n
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
    # Any line of the app's, its start's among them.
    ANY_LINE = /space [0-9]+: [a-z]+: erx_clock_test: /n

    module_function

    def answer(text) = SessionDomain.answer(text)

    def line(text) = SessionDomain.line(text)

    # The development manifest source with clock's principal, template and data grant,
    # the start row of boot (START), and the machine grown to hold clock's sessions.
    def manifest(source, boot:)
      split = SPLIT.reduce(source) { |text, (pattern, value)| edit_once(text, pattern) { value } }
                   .then { |text| edit_once(text, /^(share web\n(?:  .*\n)*)/) { SHARES } }
      grown = GROWTH.reduce(split) do |text, (pattern, growth)|
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

    # The production checkpoints to the system's command shell, then root_1's command
    # shell, and the steps of boot.
    def checkpoints(points, boot:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell = ProductionImage::Run::ERLANG_SHELL
      steps = boot == :kept ? kept_steps(shell) : no_clock_steps(shell, boot)
      [*points, SessionDomain.session_shell('root_1-shell', SERVICE_GHOST),
       { name: 'ghost-why', pattern: line(GHOST_WHY), seconds: 60 }.freeze,
       { name: 'ghost-refused', pattern: line('ghost-refused'), seconds: 60, type: CTRL_G }.freeze,
       { name: 'system-menu', pattern: CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'system-shell', pattern: MENU_LEFT, seconds: 30, type: ERL }.freeze,
       *steps].freeze
    end

    def kept_steps(shell)
      [shell.merge(name: 'system-erlang-shell', type: KILL_CLOCK).freeze,
       { name: 'clock-killed', pattern: answer(KILLED), seconds: KILL_SECONDS, type: CTRL_G }.freeze,
       { name: 'session-menu', pattern: CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'session-shell', pattern: MENU_LEFT, seconds: 30, type: SERVICE_STATUS }.freeze,
       { name: 'status-down', pattern: line(STATUS_DOWN), seconds: 60 }.freeze,
       { name: 'status-failed', pattern: line('status-failed'), seconds: 60, type: PROC_DOWN }.freeze,
       { name: 'proc-down', pattern: PROC_STATE, seconds: 60, type: SERVICE_E }.freeze,
       { name: 'service-e-clock', pattern: line(PRINCIPAL), seconds: 60 }.freeze,
       { name: 'service-listed', pattern: line('service-listed'), seconds: 60 }.freeze]
    end

    def no_clock_steps(shell, boot)
      [shell.merge(name: 'system-erlang-shell', type: NO_CLOCK).freeze,
       { name: 'no-clock', pattern: answer(NO_CLOCK_ANSWER.fetch(boot)), seconds: 240 }.freeze]
    end

    # Raises unless the serial log's text holds the report lines boot expects: at least
    # one, each CLOCK_REPORT, for the kept boot, and none for the others.
    def reports!(text, boot:)
      reports = text.b.lines.grep(ANY_REPORT)
      if boot == :kept
        raise Error, 'no session of clock reported what it holds' if reports.empty?

        waited = reports.grep(TIMED_OUT)
        raise Error, "a session of clock never got its data grant: #{waited.first.inspect}" unless waited.empty?

        wrong = reports.grep_v(CLOCK_REPORT)
        raise Error, "a session of clock holds what its template does not grant: #{wrong.first.inspect}" unless wrong.empty?
      else
        lines = text.b.lines.grep(ANY_LINE)
        raise Error, "a session of clock started in the #{boot} boot: #{lines.first.inspect}" unless lines.empty?
      end
      true
    end

    # Packs the three test images once, on a medium machine (MediumBoot.machine), then
    # boots each at each CPU count, where placement puts each cell, each from a fresh
    # copy of its release medium. Returns { "<accel>-<n>cpu" => 'passed' }; any
    # disagreement raises.
    class Run
      BOOTS = %i[kept disabled unlisted].freeze

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
          BOOTS.each { |boot| run_boot(accel: accel, cpus: count, remote: remote, boot: boot, **images.fetch(boot)) }
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
        { built: built, written: image.release_medium(built) }
      end

      # Boots built at cpus from a fresh copy of its release medium, which is removed
      # once the boot ends (each is about a gigabyte), and checks its report lines.
      def run_boot(accel:, cpus:, remote:, boot:, built:, written:)
        run = "#{boot}-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"
        directory = OutputDirectory.prepare(root: @root, mode: 0o700, path: File.join(@root, 'build/apps', run))
        production = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: cpus,
                                                             manifest_source: @manifests.fetch(boot), memory_mib: @machine.memory_mib,
                                                             test_image: true)
        points = Apps.checkpoints(production, boot: boot)
        medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors, volume: written.volume)
        report = begin
          Qemu.new(root: @root, runner: @runner, program: @qemu)
              .run(platform: @machine.platform, accel: accel, cpus: cpus, remote: remote, image: built.single,
                   memory_mib: @machine.memory_mib, disks: [QemuPlan::Disk.new(path: medium)],
                   checkpoints: points, directory: File.join(directory, 'boot'))
        ensure
          FileUtils.rm_f(medium)
        end
        Apps.reports!(File.binread(report.fetch('serial_log')), boot: boot)
      end
    end
  end
end
