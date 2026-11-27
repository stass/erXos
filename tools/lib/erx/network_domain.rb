# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'dev_key'
require_relative 'error'
require_relative 'fiasco'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'net_device'
require_relative 'net_device_echo_server'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu_gate'
require_relative 'qemu'
require_relative 'runner'
require_relative 'session_domain'

module Erx
  # The network domain's footprint on the medium machine: the development manifest, whose
  # `network` domain runs the stack (docs/design-network-stack.md, "Who holds the network
  # device"), with one edit, the domain's row restarting it 0 times, so that the cell ends
  # it for good with one kill.
  #
  # The image is the medium machine's (MediumBoot.machine), with the release medium, so
  # the storage domain runs as on the development image. The cell boots it with a network
  # device on slirp (QemuPlan::Nic). At the system's Erlang shell it waits for the network
  # domain's DHCP lease, and checks that the system domain's boot arguments give it no
  # network device while the network domain's give it one, which says coherent: QEMU virt
  # marks the transport's node dma-coherent, and the root reads that from the firmware's
  # device tree into the device's catalogue entry (docs/design-device-tree.md, "Facts into
  # records"). Root's session then runs
  # ifconfig, which shows the lease, ping -c 3 to slirp's gateway, and from its Erlang
  # shell a 1 MiB TCP echo through slirp's guest forward. That shell then finds SSH's
  # development daemon (erx_ssh_dev; docs/design-ssh.md, "Stages", stage 1), which root's
  # session started at boot on DevKey::PORT, which a host forward reaches, in an image
  # that carries the clone's development login key (DevKey), and the host's ssh logs in
  # through it and types ps at rc on the login's tty, then runs commands with no tty,
  # whose output and error output, every byte value of them, cross apart and unchanged
  # and whose status is ssh's, and one on a tty (check_ssh).
  # Last, the system's shell kills the network domain's pid and, once the domain is
  # gone, reads the root's pool pages again: each figure (after the lease, after the
  # echo and the logins) minus that last one is the domain's
  # footprint as MediumBoot::Footprint counts it, printed in the run's measurements. The
  # echo's figure is exact; the lease's is a lower bound, since root's session grows (its
  # Erlang shell, the echo's bindings) between the lease and the last reading. The domain
  # runs within the development manifest's budget, so the cell also shows that the budget
  # holds the domain through the echo.
  #
  # The reboot cell boots the same image again to the lease, starts the daemon the same
  # way, and root, logged in over ssh, pings slirp's gateway past the daemon's first
  # rekeying check (REKEY_CHECK_PINGS) and then ends the machine (check_ssh_reboot): the
  # login's rc runs on a tty of root_1's session, which holds the machine grant, and its reboot
  # writes the reset line to the /machine/ctl the session mounts (docs/design-system.md,
  # "A session's request"). QEMU's exit under -no-reboot shows the reset, after
  # `rebooted by root` on the console and with no crash frame.
  module NetworkDomain
    # The one edit of the development manifest: the network domain is never restarted.
    EDIT = { ['domain network', 'restarts'] => 0 }.freeze

    ECHO_BYTES = 1 << 20
    RECV_PIECE = NetDevice::RECV_PIECE
    # Typed at the session's Erlang shell: a connection through slirp's guest forward to
    # the harness's echo server, ECHO_BYTES each way, and whether they came back whole.
    ECHO_LINE = "begin {ok, S} = erx_gen_tcp:connect(#{NetDevice::ECHO_TUPLE}, #{QemuPlan::NIC_ECHO_PORT}, " \
                '[binary, {active, false}], 10000), ' \
                "D = rand:bytes(#{ECHO_BYTES}), ok = erx_gen_tcp:send(S, D), " \
                "E = iolist_to_binary([begin {ok, B} = erx_gen_tcp:recv(S, #{RECV_PIECE}, 10000), B end " \
                "|| _ <- lists:seq(1, #{ECHO_BYTES / RECV_PIECE})]), ok = erx_gen_tcp:close(S), E =:= D end.\r"
    # Typed at the system's Erlang shell, whose bindings carry the prefix Nd: the network
    # domain's node once it is up, its lease, the device records of both domains' boot
    # arguments, and the root's pool pages in use. The lease and the network domain's
    # record are judged at its node, which answers a boolean, or a failure printed as a
    # binary: the system domain decodes the domain's answers in safe mode and drops one
    # that names an atom it lacks, as its interfaces' and records' maps may
    # (docs/design-runtime.md, edit 9).
    LEASE_LINE = [
      'NdDomains = fun() -> erx_domain_core:domains(maps:get(core, sys:get_state(erx_domain_srv))) end',
      'NdUsed = fun() -> #{attrs := #{used := {_, {_, NdU}}}} = erx_kernel_records:budget(erx_kernel_records:system_domain()), NdU end',
      'NdLeased = fun(NdN) -> erpc:call(NdN, fun() -> string:find(lists:flatten(io_lib:format("~0p", [erx_net:interfaces()])), ' \
      '"{10,0,2,15}") =/= nomatch end, 5000) end',
      'NdWait = fun NdW(0) -> timeout; NdW(NdK) -> case catch [NdN || #{name := {erx_ident, <<"network">>}, node := NdN} <- NdDomains()] of ' \
      '[NdN] -> case catch NdLeased(NdN) of true -> NdN; _ -> timer:sleep(500), NdW(NdK - 1) end; ' \
      '_ -> timer:sleep(500), NdW(NdK - 1) end end',
      'NdNode = NdWait(360)',
      '{nd_lease, erx_device_record:find(net, virtio_net), ' \
      'erpc:call(NdNode, fun() -> case erx_device_record:find(net, virtio_net) of {ok, [#{coherent := true} | _]} -> true; ' \
      'NdR -> iolist_to_binary(io_lib:format("~0p", [NdR])) end end), NdUsed()}'
    ].join(', ') + ".\r"
    ECHOED_LINE = "{nd_echoed, NdUsed()}.\r"
    # Ends the network domain for good: kills its domain pid, which its row restarts 0
    # times, waits until the domain service holds no record of it, then reads the pool
    # pages once its remains are gone.
    END_LINE = [
      '[NdPid] = [NdP || #{name := {erx_ident, <<"network">>}, pid := NdP} <- NdDomains()]',
      'exit(NdPid, kill)',
      'NdEnd = fun NdE(0) -> timeout; NdE(NdK) -> case [NdD || #{name := {erx_ident, <<"network">>}} = NdD <- NdDomains()] of ' \
      '[] -> ended; _ -> timer:sleep(500), NdE(NdK - 1) end end',
      'NdEnded = NdEnd(120)',
      'timer:sleep(5000)',
      '{nd_ended, NdEnded, NdUsed()}'
    ].join(', ') + ".\r"

    # Typed at root's session's Erlang shell: waits for the daemon the session started at
    # boot (erx_ssh_dev:boot/1), registered as erx_ssh_dev once it listens, for as long as
    # it runs, and answers {ok, Daemon}; `timeout` after 240 polls 500 ms apart.
    SSH_LINE = '(fun Wait(0) -> timeout; Wait(N) -> case whereis(erx_ssh_dev) of ' \
               "undefined -> timer:sleep(500), Wait(N - 1); Daemon -> {ok, Daemon} end end)(240).\r"
    # What root types at rc on the login's tty, ending each line with the CR a terminal
    # sends: ps, then exit, which ends the shell and so the login. ps's header
    # (erx_cmd_ps, FreeBSD's default columns) in what the tty sent back shows that rc ran it;
    # the tty's echo of the typed line holds no such header.
    SSH_INPUT = "ps\rexit\r"
    SSH_ANSWER = /PID +TT +STAT +TIME +COMMAND/n
    # ssh's server checks the bytes a connection has sent, to decide on rekeying, 60 s
    # after the login (REKEY_DATA_TIMOUT, otp/lib/ssh/src/ssh.hrl), by asking its socket
    # (inet:getstat/2, which erx_gen_tcp answers). One ping a second, so the reboot login's
    # ping runs past that check, which must leave the login up for the reboot after it.
    REKEY_CHECK_PINGS = 70
    # What root types to end the machine once the check has passed: rc's reboot
    # (erx_cmd_reboot), after the ping.
    SSH_REBOOT = "ping -c #{REKEY_CHECK_PINGS} 10.0.2.2\rreboot\r"
    # The host ssh's line when the daemon turns down every key it offered.
    SSH_REFUSED = 'Permission denied (publickey)'
    SSH_DEADLINE = 60
    # The cell's ssh asks nothing, on top of what every ssh of DevKey's runs with. -e none
    # keeps every typed byte the guest's, never an escape of the host's ssh.
    SSH_OPTIONS = ['-e', 'none', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=30'].freeze
    # An exec's ssh logs only its errors, no notice of its own such as a new host key's
    # or a key exchange's, so its standard error is the job's unless ssh failed.
    SSH_EXEC_OPTIONS = ['-o', 'LogLevel=ERROR'].freeze
    # One exec over ssh (docs/design-ssh.md, "Stages"): the command, ssh's tty option
    # (-tt asks for a tty though ssh's input is a file, -T for none, nil leaves ssh's
    # default, none with a command), the bytes ssh reads, and what it must print on its
    # standard output and its standard error and exit with; output or error_output nil
    # is not checked. Without a tty ssh's standard error holds the job's and ssh's own
    # errors only (SSH_EXEC_OPTIONS).
    SshExec = Data.define(:name, :command, :tty, :input, :output, :error_output, :status)
    # Every byte value, 512 times: 128 KiB, past a job's input and output pieces of
    # tty_line_data_max bytes (abi/services/tty_line.txt) and a message pipe's capacity
    # (erx_shell_pipe).
    SSH_BYTES = ((0..255).to_a.pack('C*') * 512).freeze
    # Without a tty a job's output and error output cross apart and unchanged and its
    # status is ssh's; on a tty an exec's status is ssh's too.
    SSH_EXECS = [
      SshExec.new(name: 'ssh-exec-echo', command: 'echo hi', tty: '-T', input: nil, output: "hi\n", error_output: '',
                  status: 0),
      SshExec.new(name: 'ssh-exec-stderr', command: 'echo out; echo err >[1=2]', tty: '-T', input: nil, output: "out\n",
                  error_output: "err\n", status: 0),
      SshExec.new(name: 'ssh-exec-cat', command: 'cat', tty: '-T', input: SSH_BYTES, output: SSH_BYTES, error_output: '',
                  status: 0),
      SshExec.new(name: 'ssh-exec-exit', command: 'exit 3', tty: nil, input: nil, output: nil, error_output: nil, status: 3),
      SshExec.new(name: 'ssh-exec-tty-exit', command: 'exit 4', tty: '-tt', input: nil, output: nil, error_output: nil,
                  status: 4),
      # The SSH route of a load (docs/design-live.md, "One load, three routes"): the
      # session's load reads the module from its standard input and hands it to the code
      # service through root's install facet, whose loader refuses bytes that are no module.
      SshExec.new(name: 'ssh-exec-load', command: 'load -s -m erx_ssh_load_probe:12', tty: '-T', input: 'not a module',
                  output: '', error_output: "load: erx_ssh_load_probe: badfile\n", status: 1)
    ].freeze
    # check_ssh's logins: root's on a tty, the two refused, and the execs.
    SSH_LOGINS = 3 + SSH_EXECS.size

    PROMPT = SessionDomain::PROMPT

    module_function

    # The development manifest source with EDIT.
    def manifest(source) = Manifest::Edit.set(source, EDIT)

    def answer(source) = /\A#{PROMPT}#{source}\r*\n\z/n

    # The production checkpoints to the system's command shell, then the cell; figures
    # collects the pool pages each answer gives, and check_ssh runs once the daemon is up.
    def checkpoints(points, figures, check_ssh:)
      run = ProductionImage::Run
      menu_left = SessionDomain::MENU_LEFT
      figure = ->(key) { ->(line) { figures[key] = Integer(line[/([0-9]+)\}\r*\n\z/, 1], 10) } }
      [*leased_session(points, typed: NetDevice::IFCONFIG_LINE, verify_lease: figure.call(:lease)),
       line_point('ifconfig-vtnet0', 'vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500'),
       line_point('ifconfig-inet', "\tinet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255", type: NetDevice::PING_LINE),
       line_point('ping-head', 'PING 10.0.2.2 (10.0.2.2): 56 data bytes'),
       line_point('ping-counts', '3 packets transmitted, 3 packets received, 0.0% packet loss', type: run::ERL_LINE),
       run::ERLANG_SHELL.merge(name: 'session-erlang-shell', type: ECHO_LINE).freeze,
       { name: 'tcp-echo', pattern: answer('true'), seconds: 120, type: SSH_LINE }.freeze,
       ssh_daemon(check_ssh).merge(type: run::CTRL_G).freeze,
       # Its seconds also pay for check_ssh's logins within the run's deadline, the sum of
       # the checkpoints' seconds; its own clock starts once they returned.
       { name: 'system-menu', pattern: run::CTRL_G_MENU, seconds: (SSH_LOGINS * SSH_DEADLINE) + 30, type: 's' }.freeze,
       { name: 'system-again', pattern: menu_left, seconds: 30, type: ECHOED_LINE }.freeze,
       { name: 'echoed', pattern: answer('\{nd_echoed,[0-9]+\}'), seconds: 60, verify: figure.call(:echoed),
         type: END_LINE }.freeze,
       { name: 'ended', pattern: answer('\{nd_ended,ended,[0-9]+\}'), seconds: 120, verify: figure.call(:ended) }.freeze]
    end

    # The reboot cell's checkpoints: the production checkpoints to the system's command
    # shell, the lease, root_1's Erlang shell finding the daemon, and, once the login
    # (check_ssh_reboot) has ended the machine, the end's console line.
    def reboot_checkpoints(points, login:)
      run = ProductionImage::Run
      [*leased_session(points, typed: run::ERL_LINE),
       run::ERLANG_SHELL.merge(name: 'session-erlang-shell', type: SSH_LINE).freeze,
       ssh_daemon(login).freeze,
       # Its seconds also pay for the login within the run's deadline, the sum of the
       # checkpoints' seconds; its own clock starts once the login returned.
       SessionDomain.machine_end_point('reboot').merge(seconds: SSH_DEADLINE + REKEY_CHECK_PINGS + 120).freeze]
    end

    # The production checkpoints to the system's command shell; then, from the system's
    # Erlang shell, the network domain's lease, whose line verify_lease (if any) takes;
    # then root_1's command shell again, where typed is typed. points must end at the
    # command shell.
    def leased_session(points, typed:, verify_lease: nil)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      run = ProductionImage::Run
      menu_left = SessionDomain::MENU_LEFT
      [*points,
       SessionDomain.session_shell('root_1-shell', run::CTRL_G),
       { name: 'menu', pattern: run::CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
       { name: 'system-shell', pattern: menu_left, seconds: 30, type: run::ERL_LINE }.freeze,
       run::ERLANG_SHELL.merge(name: 'system-erlang-shell', type: LEASE_LINE).freeze,
       { name: 'lease', pattern: answer('\{nd_lease,\{ok,\[\]\},true,[0-9]+\}'), seconds: 240, verify: verify_lease,
         type: run::CTRL_G }.compact.freeze,
       { name: 'session-menu', pattern: run::CTRL_G_MENU, seconds: 30, type: '1' }.freeze,
       { name: 'session-shell', pattern: menu_left, seconds: 30, type: typed }.freeze]
    end

    # The checkpoint of the boot's daemon answered at root_1's Erlang shell (SSH_LINE),
    # whose verify runs logins, the host's login or logins. Its time covers SSH_LINE's
    # wait, at most 240 polls 500 ms apart.
    def ssh_daemon(logins)
      { name: 'ssh-daemon', pattern: answer('\{ok,<[0-9]+\.[0-9]+\.[0-9]+>\}'), seconds: 180,
        verify: ->(_line) { logins.call } }
    end

    # The host's ssh through the host forward at port, as `tools/erx ssh` runs it but
    # asking nothing, with the boot's known-hosts file in a directory of the cell's own,
    # since the cell's guest is a boot of its own: root with pair's key types SSH_INPUT on
    # the login's tty and gets ps's header back, while the user daemon with that key and
    # root with another key are refused; then root runs each of SSH_EXECS. What the guest
    # printed reaches an error only escaped.
    def check_ssh(pair:, port:, runner:)
      Dir.mktmpdir('erx-ssh-cell') do |work|
        input = input_file(work, SSH_INPUT)
        output = File.join(work, 'answer')
        runner.run(ssh_argv(pair, port: port, work: work), name: 'ssh-root', deadline: SSH_DEADLINE, stdin: input,
                                                           stdout: output)
        answer = File.binread(output, 4096).to_s
        raise Error, "root typed ps at rc over ssh and got #{answer.dump}, with no ps header" unless SSH_ANSWER.match?(answer)

        other = DevKey.ensure(directory: File.join(work, 'other-key'), runner: runner)
        refused(ssh_argv(pair, port: port, work: work, user: 'daemon'), name: 'ssh-other-user', input: input, work: work,
                                                                        runner: runner)
        refused(ssh_argv(other, port: port, work: work), name: 'ssh-other-key', input: input, work: work, runner: runner)
        SSH_EXECS.each { |exec| check_exec(exec, pair: pair, port: port, work: work, runner: runner) }
      end
    end

    # Root runs the expected exec's command with its input as ssh's, which must exit with
    # its status and print exactly its output and error output, each where not nil. ssh's
    # standard error is the run's log.
    def check_exec(expected, pair:, port:, work:, runner:)
      stdin = expected.input && input_file(work, expected.input, name: "#{expected.name}-input")
      stdout = File.join(work, expected.name)
      argv = ssh_argv(pair, port: port, work: work, tty: expected.tty, command: expected.command)
      result = begin
        runner.run(argv, name: expected.name, deadline: SSH_DEADLINE, stdin: stdin, stdout: stdout)
      rescue CommandError => error
        raise unless error.result.fetch('state') == 'failed'

        error.result
      end
      status = result.fetch('exit_status')
      printed = File.binread(stdout)
      error_output = File.binread(result.fetch('log'))
      wrong = []
      wrong << "exited #{status.inspect}, not #{expected.status}" unless status == expected.status
      wrong << "printed #{shown_bytes(printed, expected.output)}" unless as_expected?(printed, expected.output)
      unless as_expected?(error_output, expected.error_output)
        wrong << "wrote #{shown_bytes(error_output, expected.error_output)} to standard error"
      end
      return if wrong.empty?

      raise Error, "#{expected.name}: ssh #{[*expected.tty, expected.command.dump].join(' ')} #{wrong.join(', ')}; " \
                   "log: #{result.fetch('log')}"
    end

    # Whether bytes are the expected ones, which nil leaves unchecked.
    def as_expected?(bytes, expected) = expected.nil? || bytes == expected

    # Bytes an exec gave that differ from the expected ones, for an error: a few escaped
    # beside the expected ones, more by their size and the offset of the first byte that
    # differs, the shorter one's size when one is a prefix of the other.
    def shown_bytes(bytes, expected)
      return "#{bytes.dump}, not #{expected.dump}" if bytes.bytesize <= 64 && expected.bytesize <= 64

      differs = (0..bytes.bytesize).find { |at| bytes.getbyte(at) != expected.getbyte(at) }
      "#{bytes.bytesize} bytes of #{expected.bytesize} expected, the first differing at offset #{differs}"
    end

    # Root with pair's key logs in through the host forward at port and types SSH_REBOOT
    # at rc, the ping's seconds added to the login's deadline. The guest's end closes the
    # connection, or leaves ssh to its deadline, so a failed ssh is no failure of the cell
    # unless the daemon refused the login: the end's console line and log line decide.
    def check_ssh_reboot(pair:, port:, runner:)
      Dir.mktmpdir('erx-ssh-cell') do |work|
        runner.run(ssh_argv(pair, port: port, work: work), name: 'ssh-reboot', deadline: SSH_DEADLINE + REKEY_CHECK_PINGS,
                                                           stdin: input_file(work, SSH_REBOOT), stdout: File.join(work, 'answer'))
      end
    rescue CommandError => error
      raise Error, "the guest refused root's login; log: #{error.result.fetch('log')}" if ssh_refused?(error)
    end

    # The host's ssh as user with pair's key through the host forward at port, with a
    # known-hosts file in work, a directory of the check's own: with ssh's tty option tty,
    # by default a tty though ssh's input is a file, and running command, by default a
    # shell; a command's ssh adds SSH_EXEC_OPTIONS.
    def ssh_argv(pair, port:, work:, user: 'root', tty: '-tt', command: nil)
      DevKey.ssh_argv(pair: pair, port: port, user: user, known_hosts: File.join(work, DevKey::KNOWN_HOSTS),
                      options: [*tty, *SSH_OPTIONS, *(command ? SSH_EXEC_OPTIONS : [])], command: command)
    end

    # Writes text, what a check's ssh types or reads, to the file name in work and returns
    # its path.
    def input_file(work, text, name: 'input') = File.join(work, name).tap { |path| File.binwrite(path, text) }

    # Runs argv typing input's bytes, which the guest's daemon must refuse with SSH_REFUSED.
    # A login it admits runs rc, which exits at input's exit, and the tty's output goes
    # to a file of work's, so the log holds only what ssh itself printed.
    def refused(argv, name:, input:, work:, runner:)
      runner.run(argv, name: name, deadline: SSH_DEADLINE, stdin: input, stdout: File.join(work, name))
      raise Error, "#{name}: the guest admitted a login it must refuse"
    rescue CommandError => error
      raise Error, "#{name}: ssh ended without the daemon's refusal; log: #{error.result.fetch('log')}" unless
        ssh_refused?(error)
    end

    # Whether a failed ssh's log, which holds only what ssh itself printed, says that the
    # daemon turned down every key it offered.
    def ssh_refused?(error) = File.binread(error.result.fetch('log'), 1 << 16).to_s.include?(SSH_REFUSED)

    def line_point(name, text, type: nil)
      { name: name, pattern: /\A#{Regexp.escape(text)}\r*\n\z/n, seconds: 60, type: type }.compact.freeze
    end

    # Builds the image once and boots it under HVF with one CPU twice: the footprint cell
    # and the reboot cell. Returns { CELL => 'passed', REBOOT_CELL => 'passed' }; any
    # disagreement raises.
    class Run
      CELL = "#{QemuGate::SUITE_ACCELERATOR}-1cpu-network-domain"
      REBOOT_CELL = "#{CELL}-ssh-reboot"

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @machine = MediumBoot.machine(platform)
        @manifest = NetworkDomain.manifest(platform.manifest_source(@root))
        @measurements = []
      end

      # One line with the domain's footprint at each figure, for the gate's output.
      def measurements = @measurements.dup.freeze

      def call(jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        key = DevKey.ensure(directory: DevKey.directory(root: @root, runner: @runner), runner: @runner)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/network-domain/image'))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                             fiasco: fiasco, login_key: key.public_line)
                                        .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
        { CELL => footprint_boot(built, written, key), REBOOT_CELL => ssh_reboot_boot(built, written, key) }
      end

      private

      def footprint_boot(built, written, key)
        figures = {}
        boot(built, written, name: 'footprint') do |points, port|
          NetworkDomain.checkpoints(points, figures, check_ssh: -> { NetworkDomain.check_ssh(pair: key, port: port, runner: @runner) })
        end
        record(QemuGate::SUITE_ACCELERATOR, figures)
        'passed'
      end

      def ssh_reboot_boot(built, written, key)
        report = boot(built, written, name: 'ssh-reboot', machine_end: true) do |points, port|
          NetworkDomain.reboot_checkpoints(points, login: -> { NetworkDomain.check_ssh_reboot(pair: key, port: port, runner: @runner) })
        end
        SessionDomain.machine_ended!(File.binread(report.fetch('serial_log')), command: 'reboot')
        'passed'
      end

      # Boots built with a fresh copy of its medium, written, as the disk, so the storage
      # domain serves /data and root's session has its data facet, where erx_ssh_dev
      # writes the host key; the medium as built stays as the image build wrote it. The
      # block takes the production checkpoints and the host's port of the ssh forward,
      # and answers the boot's checkpoints. Returns QEMU's report.
      def boot(built, written, name:, machine_end: false)
        boot_directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/network-domain', name))
        medium = written.fresh(directory: OutputDirectory.prepare(root: @root, path: boot_directory, mode: 0o700))
        echo = NetDevice::EchoServer.new(limit: 2 * ECHO_BYTES).start
        link = NetDevice::Link.new
        forward = QemuPlan::Forward.new(host: NetDevice.free_tcp_port, guest: DevKey::PORT)
        nic = QemuPlan::Nic.new(frames_port: link.frames_port, peer_port: link.peer_port, echo_port: echo.port, forward: forward)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: 1,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        report = Qemu.new(root: @root, runner: @runner)
                     .run(platform: @machine.platform, accel: QemuGate::SUITE_ACCELERATOR, cpus: 1, image: built.single,
                          memory_mib: @machine.memory_mib, disks: [QemuPlan::Disk.new(path: medium)],
                          checkpoints: yield(points, forward.host), nic: nic, machine_end: machine_end)
        failed = echo.stop
        raise failed if failed

        report
      ensure
        echo&.stop
        link&.close
      end

      def record(accel, figures)
        ended = figures.fetch(:ended)
        @measurements << "network_domain: #{accel}, 1 CPU, #{@machine.memory_mib} MiB: the network domain's root pool pages " \
                         "after the lease at least #{figures.fetch(:lease) - ended}, after ping, a #{ECHO_BYTES}-byte TCP echo and #{SSH_LOGINS} ssh logins " \
                         "#{figures.fetch(:echoed) - ended} (pages in use with the domain up minus #{ended} once it ended)"
      end
    end
  end
end
