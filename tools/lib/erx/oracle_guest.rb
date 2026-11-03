#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require 'socket'
require_relative 'runner'
require_relative 'sources'
require_relative 'json_input'

module Erx
  # This is host tooling inside the isolated Linux oracle, not erXos code.
  # A container owns the entire invocation and every stock fixture it starts.
  class ContainerOracleJob
    TOOLS = %w[ruby timeout make gcc g++ perl tar ar ranlib ld pkg-config sed awk grep m4 df dpkg-query].freeze
    FLAVOURS = %w[emu jit].freeze
    SUITES = %w[emulator kernel stdlib compiler].freeze
    # Private instrumentation has no OTP application documentation surface.
    REPORTER_FLAGS = %w[+warnings_as_errors +no_docs +no_debug_info].freeze

    # Application test launchers use the installed primary executable. Their
    # FLAVOR override names executable suffixes, unlike ERTS build flavours.
    def self.suite_flavour_options(suite:, flavour:)
      raise Error, 'unsupported oracle suite or flavour' unless SUITES.include?(suite) && FLAVOURS.include?(flavour)
      suite == 'emulator' ? ["FLAVOR=#{flavour}"] : []
    end

    def self.suite_state(command)
      case command.fetch('state')
      when 'succeeded' then 'completed'
      when 'failed', 'timed_out', 'cancelled' then command.fetch('state')
      else raise Error, 'unexpected guest suite command state'
      end
    end

    def initialize(plan)
      @plan = plan
      Dir.mkdir('/tmp/erx-oracle', 0o700)
      @runner = Runner.new(owner_root: '/tmp/erx-oracle', log_dir: '/tmp/erx-oracle/logs', timeout_program: '/usr/bin/timeout')
      @environment = plan.fetch('environment')
      @source = '/tmp/erx-oracle/source'
      @install = '/tmp/erx-oracle/install'
    end

    def call(files: File)
      result = execute_plan
      result.merge('operator_startup_marker' => files.exist?('/tmp/erx-oracle/operator-startup-executed'),
                   'memory_events' => memory_events(files: files))
    end

    private

    def memory_events(files: File)
      path = '/sys/fs/cgroup/memory.events'
      contents = files.binread(path, 4097)
      raise Error, 'memory event evidence is empty or exceeds its bound' unless contents && contents.bytesize.between?(1, 4096)
      { 'status' => 'available', 'source' => path, 'contents' => contents }
    rescue Error, SystemCallError => error
      { 'status' => 'unavailable', 'source' => path, 'diagnostic' => error.message }
    end

    def execute_plan
      verify_plan
      FileUtils.mkdir_p('/tmp/erx-oracle/home', mode: 0o700)
      FileUtils.mkdir_p('/tmp/erx-oracle/xdg', mode: 0o700)
      FileUtils.mkdir_p('/tmp/erx-oracle/tmp', mode: 0o700)
      context = prove_context
      operation = @plan.fetch('operation')
      if operation == 'probe'
        return context.merge('state' => 'completed', 'operation' => operation,
                             'license_inventory' => license_inventory)
      elsif operation == 'detached'
        detached_fixture
        return context.merge('state' => 'completed', 'operation' => operation)
      end

      build = build_stock
      return context.merge('state' => 'completed', 'operation' => operation, 'build' => build) if operation == 'build'

      suite = @plan.fetch('suite')
      hooks = '/tmp/erx-oracle/hooks'
      Dir.mkdir(hooks)
      @runner.run([File.join(@install, 'bin/erlc'), *REPORTER_FLAGS, '-I',
                   File.join(@source, 'lib/common_test/include'), '-o', hooks,
                   '/inputs/erx_oracle_events.erl', '/inputs/erx_oracle_observer.erl'], name: 'oracle-reporter', deadline: 30,
                  env: @environment)
      selection = @plan['test_suite'] ? "-suite #{@plan.fetch('test_suite')}" : ''
      selection += " -case #{@plan.fetch('testcase')}" if @plan['testcase']
      extra = "-ct_hooks cth_surefire -event_handler erx_oracle_events -pa #{hooks}"
      environment = @environment.merge('ERL_TOP' => @source, 'ERX_ORACLE_EVENTS' => '/tmp/erx-oracle/events.jsonl',
                                        'CT_NODENAME' => 'erx_oracle')
      argv = ['/usr/bin/make', "#{suite}_test", *self.class.suite_flavour_options(suite: suite, flavour: @plan.fetch('flavour')),
              'MAKE=/usr/bin/make', "ARGS=#{selection}", "EXTRA_ARGS=#{extra}"]
      begin
        command = @runner.run(argv, name: "oracle-suite-#{suite}", deadline: @plan.fetch('suite_deadline'),
                              chdir: @source, env: environment)
      rescue CommandError => error
        command = error.result
      end
      context.merge('state' => self.class.suite_state(command), 'operation' => operation,
                    'build' => build, 'suite_command' => command)
    end

    private

    # Stock port_SUITE executes a native helper after removing read access.
    # Admission tests those exact filesystem semantics as the workload user.
    def execute_only_files
      Dir.mktmpdir('erx-execute-only-', '/tmp/erx-oracle') do |directory|
        path = File.join(directory, 'true')
        FileUtils.cp('/usr/bin/true', path)
        File.chmod(0o111, path)
        command = @runner.run([path], name: 'oracle-execute-only', deadline: 5,
                              env: @environment)
        denied = begin
          File.binread(path)
          false
        rescue Errno::EACCES
          true
        end
        unless command.fetch('state') == 'succeeded' && denied
          raise Error, 'native oracle filesystem does not preserve execute-only file semantics'
        end
        { 'execution' => command, 'ordinary_read' => 'permission_denied' }
      end
    end

    def verify_plan
      unless @plan.is_a?(Hash) && %w[build run probe detached].include?(@plan['operation']) &&
             FLAVOURS.include?(@plan['flavour']) && @environment.is_a?(Hash)
        raise Error, 'invalid container oracle job'
      end
      unless ENV.to_h == @environment
        raise Error, 'container workload environment differs from its explicit plan'
      end
      raise Error, 'oracle workload must not run as root' if Process.uid.zero?
      workspace = File.stat('/tmp/erx-oracle')
      unless workspace.uid == Process.uid && (workspace.mode & 0o777) == 0o700
        raise Error, 'native oracle workspace differs from its private ownership plan'
      end
      if @plan.fetch('operation') == 'run'
        raise Error, 'unsupported oracle suite' unless SUITES.include?(@plan['suite'])
      end
      %w[jobs suite_deadline].each do |field|
        value = @plan[field]
        raise Error, "invalid oracle job #{field}" unless value.is_a?(Integer) && value.positive? && value <= 86_400
      end
      unless @plan.fetch('jobs').between?(1, 64) && /\A[0-9a-f]{64}\z/.match?(@plan.fetch('source_sha256'))
        raise Error, 'invalid oracle source identity or parallelism'
      end
      if @plan['test_suite'] && !/\A[a-zA-Z][a-zA-Z0-9_]*_SUITE\z/.match?(@plan['test_suite'])
        raise Error, 'invalid selected Common Test suite'
      end
      if @plan['testcase'] && (!@plan['test_suite'] || !/\A[a-zA-Z][a-zA-Z0-9_]*\z/.match?(@plan['testcase']))
        raise Error, 'invalid selected Common Test case'
      end
    end

    def prove_context
      interfaces = Dir.children('/sys/class/net').sort
      raise Error, 'oracle has a non-loopback network interface' unless interfaces == ['lo']
      routes = File.readlines('/proc/net/route').drop(1).reject { |line| line.strip.empty? }
      raise Error, 'oracle has an IPv4 external route' unless routes.empty?
      limits = verify_cgroups
      ipv4_tcp, ipv4_udp = prove_loopback
      external = connection_result('192.0.2.1', 9)
      raise Error, 'oracle reached a non-loopback numeric address' unless external == 'unreachable'
      dns = begin
        Addrinfo.getaddrinfo('erx-oracle-proof.invalid', nil, Socket::AF_INET)
        'resolved'
      rescue SocketError
        'unresolved'
      end
      raise Error, 'oracle native resolver received an unexpected external answer' unless dns == 'unresolved'
      hostname = Socket.gethostname
      own_addresses = Addrinfo.getaddrinfo(hostname, nil, Socket::AF_INET).map(&:ip_address).uniq
      raise Error, 'oracle hostname does not resolve to owned loopback' unless own_addresses == ['127.0.0.1']
      ipv6 = begin
        server = TCPServer.new('::1', 0)
        server.close
        'available'
      rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
        'unsupported'
      end
      tools = TOOLS.to_h { |name| [name, executable(name)] }
      { 'guest' => identity('/usr/bin/uname', ['-a']), 'uid' => Process.uid, 'gid' => Process.gid,
        'hostname' => hostname, 'interfaces' => interfaces, 'ipv4_routes' => routes,
        'loopback_tcp' => ipv4_tcp, 'loopback_udp' => ipv4_udp,
        'numeric_external' => external, 'native_external_dns' => dns, 'ipv6' => ipv6,
        'effective_limits' => limits, 'tools' => tools,
        'execute_only_files' => execute_only_files,
        'private_startup_empty' => !File.exist?('/tmp/erx-oracle/home/.erlang') && !File.exist?('/tmp/erx-oracle/xdg/erlang/.erlang') }
    end

    def verify_cgroups
      expected = @plan.fetch('resources')
      memory = bounded_decimal(File.read('/sys/fs/cgroup/memory.max').strip)
      swap = bounded_decimal(File.read('/sys/fs/cgroup/memory.swap.max').strip)
      pids = bounded_decimal(File.read('/sys/fs/cgroup/pids.max').strip)
      cpu = File.read('/sys/fs/cgroup/cpu.max').split.map { |value| bounded_decimal(value) }
      shared = @runner.run(['/usr/bin/df', '-B1', '--output=size', '/dev/shm'],
                           name: 'oracle-shared-memory-limit', deadline: 10, env: @environment)
      shm = bounded_decimal(File.read(shared.fetch('log')).lines.last.to_s.strip)
      unless memory == expected.fetch('memory_bytes') && swap.zero? &&
             pids == expected.fetch('pids') && cpu.size == 2 &&
             cpu[0] == cpu[1] * expected.fetch('cpus') && shm == expected.fetch('shm_bytes')
        raise Error, 'oracle cgroup limits differ from the execution plan'
      end
      { 'memory_bytes' => memory, 'swap_bytes' => swap, 'pids' => pids,
        'cpu_quota' => cpu[0], 'cpu_period' => cpu[1], 'shm_bytes' => shm }
    end

    def bounded_decimal(value)
      raise Error, 'unsupported or unbounded oracle resource limit' unless /\A[0-9]{1,18}\z/.match?(value)
      value.to_i
    end

    def prove_loopback
      server = TCPServer.new('127.0.0.1', 12_321)
      client = TCPSocket.new('127.0.0.1', 12_321)
      accepted = server.accept
      client.write('loopback')
      raise Error, 'oracle TCP loopback failed' unless accepted.read(8) == 'loopback'
      udp = UDPSocket.new
      udp.bind('127.0.0.1', 0)
      sender = UDPSocket.new
      sender.send('udp', 0, '127.0.0.1', udp.addr.fetch(1))
      raise Error, 'oracle UDP loopback failed' unless udp.recv(3) == 'udp'
      ['passed', 'passed']
    ensure
      [accepted, client, server, sender, udp].compact.each(&:close)
    end

    def connection_result(address, port)
      Socket.tcp(address, port, connect_timeout: 0.5) { |_socket| }
      'connected'
    rescue Errno::ENETUNREACH, Errno::EHOSTUNREACH
      'unreachable'
    rescue Errno::ETIMEDOUT, Errno::ECONNREFUSED
      'unexpected-network-path'
    end

    def executable(name)
      path = @environment.fetch('PATH').split(':').map { |directory| File.join(directory, name) }
                         .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      raise Error, "missing oracle image prerequisite: #{name}" unless path
      File.realpath(path)
    end

    def license_inventory
      query = @runner.run(['/usr/bin/dpkg-query', '--show',
                           '--showformat=${binary:Package}\t${Version}\t${Architecture}\n'],
                          name: 'oracle-image-packages', deadline: 10, env: @environment)
      rows = File.binread(query.fetch('log'), 1024 * 1024 + 1)
      raise Error, 'oracle image package inventory exceeds bound' if rows.bytesize > 1024 * 1024
      destination = '/tmp/erx-oracle/image-licenses'
      Dir.mkdir(destination)
      packages = rows.lines.map do |row|
        name, version, architecture = row.strip.split("\t", -1)
        unless name && /\A[a-z0-9][a-z0-9+.:\-]*\z/.match?(name) && version && architecture
          raise Error, 'invalid oracle image package metadata'
        end
        source = File.join('/usr/share/doc', name.split(':').first, 'copyright')
        evidence = { 'status' => 'unknown', 'source' => source }
        if File.file?(source)
          bytes = File.binread(source, 2 * 1024 * 1024 + 1)
          raise Error, 'oracle package copyright evidence exceeds bound' if bytes.bytesize > 2 * 1024 * 1024
          hash = Digest::SHA256.hexdigest(bytes)
          path = "image-licenses/#{hash}.copyright"
          File.binwrite(File.join('/tmp/erx-oracle', path), bytes)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          labels = text.valid_encoding? ? text.lines.grep(/\ALicense:/).map(&:strip).uniq : nil
          evidence = { 'status' => 'recorded', 'source' => source, 'artifact' => path,
                       'sha256' => hash, 'declared_labels' => labels,
                       'declaration_status' => labels.nil? ? 'unknown_encoding' : 'transcribed' }
        end
        { 'package' => name, 'version' => version, 'architecture' => architecture,
          'license_evidence' => evidence }
      end
      gems = Gem::Specification.to_a.sort_by(&:name).map do |spec|
        { 'name' => spec.name, 'version' => spec.version.to_s,
          'declared_licenses' => spec.licenses, 'evidence' => spec.loaded_from }
      end
      { 'packages' => packages, 'ruby_version' => RUBY_VERSION,
        'ruby_copyright' => RUBY_COPYRIGHT, 'bundled_gem_declarations' => gems,
        'scope' => 'Debian package notices and installed gem declarations; core Ruby follows pinned image provenance',
        'interpretation' => 'upstream declarations and exact notice bytes; unknowns are not classified as permissive' }
    end

    def identity(program, arguments)
      result = @runner.run([program, *arguments], name: 'oracle-tool-identity', deadline: 10,
                           env: @environment)
      File.read(result.fetch('log')).strip
    end

    def build_stock
      Sources.unpack(archive: '/inputs/otp.tar.gz', sha256: @plan.fetch('source_sha256'),
                     destination: @source, owner_root: '/tmp/erx-oracle',
                     source_directory: 'otp_src_29.1.2', runner: @runner)
      reporting_source = install_reporting_source if @plan.fetch('operation') == 'run'
      flavour = @plan.fetch('flavour')
      configure = ["--prefix=#{@install}", flavour == 'jit' ? '--enable-jit' : '--disable-jit',
                   '--without-wx', '--without-javac', '--without-odbc']
      environment = @environment.merge('CC' => '/usr/bin/gcc', 'CXX' => '/usr/bin/g++',
                                        'CFLAGS' => '-O2', 'CXXFLAGS' => '-O2',
                                        'CPPFLAGS' => '', 'LDFLAGS' => '', 'MAKE' => '/usr/bin/make')
      @runner.run([File.join(@source, 'configure'), *configure], name: 'oracle-configure',
                  deadline: 300, chdir: @source, env: environment)
      @runner.run(['/usr/bin/make', "-j#{@plan.fetch('jobs')}", "FLAVOR=#{flavour}", 'V=1'],
                  name: 'oracle-build', deadline: 1800, chdir: @source, env: environment)
      @runner.run(['/usr/bin/make', 'install', "FLAVOR=#{flavour}"], name: 'oracle-install',
                  deadline: 300, chdir: @source, env: environment)
      expression = 'Root=code:root_dir(), Release=erlang:system_info(otp_release), ' \
                   '{ok,V}=file:read_file(filename:join([Root,"releases",Release,"OTP_VERSION"])), ' \
                   'io:format("ERX_ORACLE ~s ~s~n",[string:trim(V),erlang:system_info(emu_flavor)]),halt().'
      verification = @runner.run([File.join(@install, 'bin/erl'), '-noshell', '-noinput', '-boot',
                                   'no_dot_erlang', '-eval', expression], name: 'oracle-verify',
                                  deadline: 30, env: environment)
      unless File.read(verification.fetch('log')).lines.include?("ERX_ORACLE 29.1.2 #{flavour}\n")
        raise Error, 'container oracle version or flavour mismatch'
      end
      distribution = 'Opts=#{name=>erx_probe_peer,exec=>"/tmp/erx-oracle/install/bin/erl",connection=>standard_io,' \
                     'args=>["-boot","no_dot_erlang","-setcookie","erx_oracle_probe"]},' \
                     '{ok,P,N}=peer:start_link(Opts),pong=net_adm:ping(N),N=erpc:call(N,erlang,node,[]),' \
                     'ok=peer:stop(P),io:format("ERX_DISTRIBUTION passed~n"),halt().'
      exchange = @runner.run([File.join(@install, 'bin/erl'), '-noshell', '-noinput', '-boot',
                               'no_dot_erlang', '-sname', 'erx_probe_control', '-setcookie',
                               'erx_oracle_probe', '-eval', distribution], name: 'oracle-distribution-proof',
                              deadline: 30, env: environment)
      unless File.read(exchange.fetch('log')).lines.include?("ERX_DISTRIBUTION passed\n")
        raise Error, 'isolated Erlang distribution exchange failed'
      end
      { 'state' => 'ready', 'version' => '29.1.2', 'flavour' => flavour,
        'source_sha256' => @plan.fetch('source_sha256'), 'configure' => configure,
        'compiler' => identity('/usr/bin/gcc', ['--version']),
        'cxx' => identity('/usr/bin/g++', ['--version']),
        'build_environment' => environment, 'verification' => verification,
        'erlang_distribution' => 'passed', 'reporting_source' => reporting_source }
    end

    def install_reporting_source
      record = JsonInput.parse(File.binread('/inputs/reporter-source.json', 4097),
                               max_bytes: 4096, label: 'reporting source record')
      expected_path = 'lib/common_test/src/test_server_ctrl.erl'
      unless record.is_a?(Hash) && record.keys.sort == %w[license original_sha256 path reporting_sha256] &&
             record['path'] == expected_path && record['license'] == 'Apache-2.0' &&
             %w[original_sha256 reporting_sha256].all? { |key| /\A[0-9a-f]{64}\z/.match?(record[key].to_s) }
        raise Error, 'invalid reporting source record'
      end
      original = File.join(@source, expected_path)
      replacement = '/inputs/test_server_ctrl.erl'
      unless Digest::SHA256.file(original).hexdigest == record.fetch('original_sha256') &&
             Digest::SHA256.file(replacement).hexdigest == record.fetch('reporting_sha256')
        raise Error, 'Common Test reporting source hash mismatch'
      end
      FileUtils.copy_file(replacement, original)
      record.merge('unchanged_sources' => 'all other original archive files')
    end

    def detached_fixture
      child = fork do
        Process.setsid
        fork do
          server = TCPServer.new('127.0.0.1', 12_321)
          File.write('/tmp/erx-oracle/detached-ready', Process.pid.to_s)
          heartbeat = 0
          loop do
            File.write('/tmp/erx-oracle/detached-heartbeat', heartbeat.to_s)
            if (heartbeat % 10).zero?
              puts "ERX_ORACLE_HEARTBEAT #{heartbeat}"
              STDOUT.flush
            end
            heartbeat += 1
            sleep 0.1
          end
        ensure
          server&.close
        end
        exit! 0
      end
      Process.wait(child)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until File.file?('/tmp/erx-oracle/detached-ready')
        raise Error, 'detached fixture did not become ready' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      File.write('/tmp/erx-oracle/parent-finished', 'parent exited; detached child holds port 12321')
      puts 'ERX_ORACLE_DETACHED_READY'
      STDOUT.flush
      loop { sleep 1 }
    end
  end
end

