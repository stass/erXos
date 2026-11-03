# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require 'uri'
require_relative 'dependencies'
require_relative 'oracle_results'
require_relative 'runner'
require_relative 'json_input'
require_relative 'oracle_export'
require_relative 'bounded_file'

module Erx
  class OracleInvocationError < Error
    attr_reader :result

    def initialize(result, detail:)
      @result = result
      super("#{detail}; report: #{result.fetch('report')}")
    end
  end

  # The adapter owns one container for the whole build or suite, not merely
  # its attached client. Every exit path removes that exact owned namespace.
  class OracleContainer
    OWNER_LABEL = 'org.erxos.oracle.owner'
    ROLE_LABEL = 'org.erxos.oracle.role'
    FLAVOURS = %w[emu jit].freeze
    SUITES = %w[emulator kernel stdlib compiler].freeze
    RESOURCES = { 'cpus' => 4, 'memory_bytes' => 8 * 1024**3,
                  'pids' => 4096, 'shm_bytes' => 256 * 1024**2 }.freeze
    GUEST_ENV = { 'HOME' => '/tmp/erx-oracle/home', 'XDG_CONFIG_HOME' => '/tmp/erx-oracle/xdg',
                  'TMPDIR' => '/tmp/erx-oracle/tmp',
                  'TS_EXTRA_PLATFORM_LABEL' => 'Docker',
                  'PATH' => '/usr/local/bin:/usr/bin:/bin', 'LANG' => 'C.UTF-8',
                  'LC_ALL' => 'C.UTF-8', 'USER' => 'erx', 'LOGNAME' => 'erx' }.freeze
    INPUTS = {
      'test/oracle/container_job.rb' => 'container_job.rb',
      'test/oracle/erx_oracle_events.erl' => 'erx_oracle_events.erl',
      'test/oracle/erx_oracle_observer.erl' => 'erx_oracle_observer.erl',
      'test/oracle/common_test/test_server_ctrl.erl' => 'test_server_ctrl.erl',
      'test/oracle/reporter-source.json' => 'reporter-source.json',
      'test/oracle/common_test/ORIGIN.md' => 'reporter-ORIGIN.md',
      'tools/lib/erx/runner.rb' => 'runner.rb',
      'tools/lib/erx/error.rb' => 'error.rb',
      'tools/lib/erx/output_directory.rb' => 'output_directory.rb',
      'tools/lib/erx/sources.rb' => 'sources.rb',
      'tools/lib/erx/json_input.rb' => 'json_input.rb',
      'tools/lib/erx/oracle_guest.rb' => 'oracle_guest.rb',
      'tools/lib/erx/oracle_export.rb' => 'oracle_export.rb',
      'test/oracle/export_job.rb' => 'export_job.rb'
    }.freeze

    def initialize(root:, context:, image: nil, resources: RESOURCES,
                   runner: nil, docker_program: 'docker')
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @dependencies = Dependencies.new(root: @root, runner: @runner)
      @image = image || @dependencies.image_for('oracle-toolchain')
      @context = context
      @resources = resources.dup.freeze
      @docker = executable(docker_program)
      validate_inputs
    end

    def build(flavours: FLAVOURS, jobs: 4)
      flavours.map do |flavour|
        result = execute(operation: 'build', flavour: flavour, jobs: jobs, deadline: 3000)
        finish_build(result)
      end
    end

    def run(suite, flavour: 'emu', jobs: 4, deadline: 14_400, test_suite: nil, testcase: nil)
      raise Error, 'unsupported Linux oracle suite' unless SUITES.include?(suite)
      unless deadline.is_a?(Integer) && deadline.between?(1, 80_000)
        raise Error, 'Linux oracle suite deadline must be between 1 and 80000 seconds'
      end
      result = execute(operation: 'run', flavour: flavour, jobs: jobs, deadline: deadline + 2500,
                       suite_deadline: deadline, suite: suite, test_suite: test_suite, testcase: testcase)
      collect_suite(result)
    rescue OracleInvocationError => error
      result = error.result
      raise unless result['artifacts'].is_a?(Hash) && result['guest'].is_a?(Hash)
      collect_suite(result)
    end

    def probe(flavour: 'emu')
      result = execute(operation: 'probe', flavour: flavour, jobs: 1, deadline: 60)
      unless result.fetch('state') == 'completed' && result.fetch('guest')['state'] == 'completed'
        raise Error, "Linux oracle context probe failed; report: #{result.fetch('report')}"
      end
      result
    end

    # Used by the owned cleanup fixture. No caller can supply Docker flags,
    # mounts, entrypoints or a program outside the checked input set.
    def detached_fixture(flavour: 'emu', cancelled: nil, started: nil, ready: nil, heartbeat: nil, cancel_when_ready: false)
      execute(operation: 'detached', flavour: flavour, jobs: 1, deadline: 120, cancelled: cancelled,
              started: started, ready: ready, heartbeat: heartbeat, cancel_when_ready: cancel_when_ready)
    end

    # Read-only running-status check for the exact fixture this adapter started.
    def fixture_witness(record)
      directory = File.realpath(record.fetch('directory'))
      prefix = File.join(@root, 'build/oracle/linux') + '/'
      unless record['operation'] == 'detached' && record['context'] == @context &&
             directory.start_with?(prefix) && /\A[0-9a-f]{64}\z/.match?(record.fetch('owner'))
        raise Error, 'invalid fixture identity for running-status check'
      end
      cid = validate_cid(record.fetch('cid'))
      connection = { 'config' => File.join(directory, 'docker-config') }
      value = inspect_owned(connection, cid: cid, owner: record.fetch('owner'))
      state = value.fetch('State')
      unless state.is_a?(Hash) && state['Running'] == true && state['Status'] == 'running'
        raise Error, 'owned fixture is not running'
      end
      { 'cid' => cid, 'observed_at' => Time.now.utc.iso8601, 'state' => 'running' }
    rescue KeyError, SystemCallError => error
      raise Error, "cannot check running fixture: #{error.message}"
    end

    private

    def validate_inputs
      unless @context.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/.match?(@context)
        raise Error, 'an explicit local Docker context is required'
      end
      reference = @image.fetch('reference')
      digest = @image.fetch('manifest_sha256')
      unless /\A[0-9a-f]{64}\z/.match?(digest) && reference.end_with?("@sha256:#{digest}") &&
             %w[linux/arm64 linux/amd64].include?(@image.fetch('platform')) &&
             /\A[0-9a-f]{64}\z/.match?(@image.fetch('config_sha256'))
        raise Error, 'invalid pinned Linux oracle image'
      end
      unless @resources.keys.sort == RESOURCES.keys.sort &&
             @resources.values.all? { |value| value.is_a?(Integer) && value.positive? } &&
             @resources.fetch('cpus').between?(1, 64) &&
             @resources.fetch('memory_bytes').between?(128 * 1024**2, 128 * 1024**3) &&
             @resources.fetch('pids').between?(32, 65_536) &&
             @resources.fetch('shm_bytes') <= @resources.fetch('memory_bytes')
        raise Error, 'invalid Linux oracle resource limits'
      end
      raise Error, 'container oracle must be launched by a non-root host user' if Process.uid.zero?
    rescue KeyError, NoMethodError => error
      raise Error, "invalid Linux oracle image or resources: #{error.message}"
    end

    def execute(operation:, flavour:, jobs:, deadline:, suite_deadline: 1,
                 suite: nil, test_suite: nil, testcase: nil, cancelled: nil,
                 started: nil, ready: nil, heartbeat: nil, cancel_when_ready: false)
      raise Error, 'invalid Linux oracle flavour' unless FLAVOURS.include?(flavour)
      raise Error, 'invalid Linux oracle parallelism' unless jobs.is_a?(Integer) && jobs.between?(1, 64)
      validate_selection(test_suite, testcase: testcase)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/oracle/linux', flavour))
      directory = Dir.mktmpdir("#{operation}-", parent)
      ownership = SecureRandom.hex(32).freeze
      cid_path = File.join(directory, 'container.cid')
      export_cid_path = File.join(directory, 'export.cid')
      volume = 'erx-oracle-' + ownership
      manifest = { 'state' => 'prepared', 'operation' => operation, 'flavour' => flavour,
                   'context' => @context, 'platform_label' => GUEST_ENV.fetch('TS_EXTRA_PLATFORM_LABEL'),
                   'owner' => ownership, 'cid_path' => cid_path,
                   'cid' => nil, 'volume' => volume, 'export_cid' => nil, 'export_cid_path' => export_cid_path,
                   'deadline_seconds' => deadline,
                   'started_at' => Time.now.utc.iso8601, 'directory' => directory }
      write_manifest(directory, manifest)
      result = nil
      original_error = nil
      cleanup_error = nil
      export_error = nil
      connection = nil
      workload_removed = false
      volume_verified = false
      begin
        host = @runner.run(['uname', '-a'], name: 'oracle-host', deadline: 10)
        manifest['host'] = { 'identity' => BoundedFile.read(host.fetch('log'), maximum: 1024 * 1024).strip,
                             'command' => host }
        connection = prepare_context(directory)
        image = verify_image(connection)
        engine = docker_json(connection, ['info', '--format', '{{json .}}'], name: 'oracle-engine')
        unless engine['OSType'] == 'linux' && engine['NCPU'].is_a?(Integer) &&
               engine['NCPU'] >= @resources.fetch('cpus') &&
               engine['MemTotal'].is_a?(Integer) && engine['MemTotal'] >= @resources.fetch('memory_bytes')
          raise Error, 'local engine does not support the requested Linux oracle resources'
        end
        source, archive = @dependencies.archive_for('otp')
        inputs, workspace, hashes = prepare_files(directory, archive: archive, source: source)
        create_volume(connection, name: volume, owner: ownership)
        volume_verified = true
        plan = { 'operation' => operation, 'flavour' => flavour, 'suite' => suite,
                 'jobs' => jobs, 'suite_deadline' => suite_deadline,
                 'test_suite' => test_suite, 'testcase' => testcase,
                 'environment' => GUEST_ENV, 'source_sha256' => source.fetch('sha256'),
                 'resources' => @resources, 'artifact_limits' => OracleExport::DEFAULT_LIMITS }
        File.write(File.join(inputs, 'job.json'), JSON.pretty_generate(plan) + "\n")
        hashes['job.json'] = Digest::SHA256.file(File.join(inputs, 'job.json')).hexdigest
        args = create_arguments(inputs: inputs, volume: volume, cid_path: cid_path,
                                owner: ownership, deadline: deadline)
        manifest.merge!('endpoint' => connection.fetch('endpoint'), 'image' => image,
                        'engine' => engine.slice('ID', 'Name', 'ServerVersion', 'OperatingSystem', 'KernelVersion', 'Architecture', 'NCPU', 'MemTotal'),
                        'resources' => @resources, 'inputs_sha256' => hashes, 'create_arguments' => args,
                        'workspace' => workspace)
        write_manifest(directory, manifest)
        docker(connection, args, name: 'oracle-container-create', deadline: 30)
        cid = read_cid(cid_path)
        manifest['cid'] = cid
        inspect = inspect_owned(connection, cid: cid, owner: ownership)
        verify_container(inspect, image: image, inputs: inputs, volume: volume, deadline: deadline)
        manifest['state'] = 'running'
        write_manifest(directory, manifest)
        started.call(JsonInput.parse(JSON.generate(manifest), label: 'oracle running status')) if started
        announced_ready = false
        last_heartbeat = -1
        progress = lambda do |log|
          next false unless operation == 'detached'
          bytes = File.binread(log, 65_536) || ''.b
          observed = bytes.scan(/^ERX_ORACLE_HEARTBEAT ([0-9]{1,6})$/).last
          if observed && observed.first.to_i > last_heartbeat
            last_heartbeat = observed.first.to_i
            heartbeat.call(last_heartbeat) if heartbeat
          end
          next false unless bytes.include?("ERX_ORACLE_DETACHED_READY\n")
          unless announced_ready
            ready.call if ready
            announced_ready = true
          end
          cancel_when_ready
        end
        begin
          command = docker(connection, ['start', '--attach', cid], name: "oracle-linux-#{operation}-#{flavour}",
                           deadline: deadline + 30, cancelled: cancelled, success: progress)
        rescue CommandError => error
          command = error.result
        end
        final = inspect_owned(connection, cid: cid, owner: ownership).fetch('State')
        command = command.merge('state' => 'cancelled') if cancel_when_ready && announced_ready
        result = manifest.merge('state' => 'incomplete', 'command' => command, 'container_state' => final)
      rescue Error, SystemCallError, KeyError => error
        original_error = error
        result = manifest.merge('state' => 'setup_error', 'diagnostic' => error.message)
      ensure
        result ||= manifest.merge('state' => 'interrupted')
        if connection
          begin
            cleanup_owned(connection, cid_path: cid_path, owner: ownership)
            workload_removed = true
            if volume_verified
              begin
                result['artifacts'] = export_artifacts(connection, inputs: inputs, workspace: workspace, volume: volume,
                                                       cid_path: export_cid_path, owner: ownership, image: image,
                                                       manifest: manifest)
                result['guest'] = read_guest_result(workspace)
              rescue Error, SystemCallError, KeyError => error
                export_error = error
              end
            end
          rescue Error, SystemCallError, KeyError => error
            cleanup_error = error
          ensure
            begin
              cleanup_owned(connection, cid_path: export_cid_path, owner: ownership, role: 'export')
              remove_volume(connection, name: volume, owner: ownership) if workload_removed
            rescue Error, SystemCallError, KeyError => error
              cleanup_error ||= error
            end
          end
        end
        result.merge!(manifest.slice('export_cid', 'export_started_at'))
        if result['guest']
          if result['command'] && result['container_state']
            begin
              result['workload_state'] = invocation_state(result.fetch('command'), container: result.fetch('container_state'),
                                                           guest: result.fetch('guest'))
              result['state'] = result.fetch('workload_state')
            rescue Error, KeyError => error
              original_error ||= error
              result.merge!('state' => 'setup_error', 'diagnostic' => error.message)
            end
          end
        end
        result['cleanup_verified'] = cleanup_error.nil?
        if export_error
          result.merge!('state' => 'artifact_error', 'artifact_diagnostic' => export_error.message)
        end
        if cleanup_error
          result.merge!('state' => 'cleanup_error', 'cleanup_diagnostic' => cleanup_error.message)
        end
        result['report'] = File.join(directory, 'result.json')
        File.write(result.fetch('report'), JSON.pretty_generate(result) + "\n")
        write_manifest(directory, result)
      end
      raise OracleInvocationError.new(result, detail: "Linux oracle setup failed: #{original_error.message}") if original_error
      raise OracleInvocationError.new(result, detail: 'Linux oracle cleanup failed') if cleanup_error
      raise OracleInvocationError.new(result, detail: 'Linux oracle artifact export failed') if export_error
      result
    end

    def invocation_state(command, container:, guest:)
      unless container.is_a?(Hash) && [true, false].include?(container['Running']) &&
             [true, false].include?(container['OOMKilled']) &&
             container['ExitCode'].is_a?(Integer) && container['Status'].is_a?(String)
        raise Error, 'invalid final oracle container state'
      end
      states = [command.fetch('state'), guest.fetch('state'), guest.dig('suite_command', 'state')]
      return 'cancelled' if states.include?('cancelled')
      return 'timed_out' if states.include?('timed_out') || container.fetch('ExitCode') == 124
      return 'resource_exhausted' if container.fetch('OOMKilled')
      return 'setup_error' if guest.fetch('state') == 'setup_error'
      return 'incomplete' if guest.fetch('state') == 'incomplete'
      if command.fetch('state') == 'succeeded' && !container.fetch('Running') &&
         container.fetch('Status') == 'exited' && container.fetch('ExitCode').zero? &&
         guest.fetch('state') == 'completed'
        'completed'
      else
        'failed'
      end
    end

    def prepare_context(directory)
      operator = ENV['DOCKER_CONFIG'] || File.join(Dir.home, '.docker')
      command = cli(['--config', operator, 'context', 'inspect', @context, '--format', '{{json .}}'],
                    name: 'oracle-context-read', deadline: 10)
      context = read_json(command.fetch('log'))
      unless context.is_a?(Hash) && context['Endpoints'].is_a?(Hash) &&
             context.fetch('Endpoints')['docker'].is_a?(Hash) &&
             context.fetch('Endpoints').fetch('docker')['Host'].is_a?(String)
        raise Error, 'invalid local Docker context shape'
      end
      endpoint = context.fetch('Endpoints').fetch('docker').fetch('Host')
      uri = URI.parse(endpoint)
      unless uri.scheme == 'unix' && uri.userinfo.nil? && uri.opaque.nil? &&
             (uri.host.nil? || uri.host.empty?) && uri.port.nil? &&
             uri.query.nil? && uri.fragment.nil? && uri.path.is_a?(String) &&
             uri.path.start_with?('/') && !uri.path.include?('%') && File.socket?(uri.path)
        raise Error, 'Linux oracle requires a canonical local UNIX Docker endpoint'
      end
      socket = File.realpath(uri.path)
      endpoint = "unix://#{socket}"
      config = File.join(directory, 'docker-config')
      Dir.mkdir(config, 0o700)
      File.write(File.join(config, 'config.json'), "{\"auths\":{}}\n")
      cli(['--config', config, 'context', 'create', 'erx-oracle', '--docker', "host=#{endpoint}"],
          name: 'oracle-context-create', deadline: 10)
      { 'config' => config, 'endpoint' => endpoint }
    rescue URI::InvalidURIError, KeyError, TypeError => error
      raise Error, "invalid local Docker context: #{error.message}"
    end

    def verify_image(connection)
      image = docker_json(connection, ['image', 'inspect', @image.fetch('reference'), '--format', '{{json .}}'],
                          name: 'oracle-image-verify')
      config_id = "sha256:#{@image.fetch('config_sha256')}"
      manifest_id = "sha256:#{@image.fetch('manifest_sha256')}"
      descriptor = image['Descriptor']
      volumes = image['Config'].is_a?(Hash) ? image.fetch('Config')['Volumes'] : nil
      unless [config_id, manifest_id].include?(image['Id']) &&
             "#{image['Os']}/#{image['Architecture']}" == @image.fetch('platform') &&
             image['RepoDigests'].is_a?(Array) &&
             image.fetch('RepoDigests').all? { |value| value.is_a?(String) } &&
             image.fetch('RepoDigests').any? { |value| value.end_with?("@sha256:#{@image.fetch('manifest_sha256')}") } &&
             (descriptor.nil? || (descriptor.is_a?(Hash) && descriptor['digest'] == manifest_id)) &&
             image['Config'].is_a?(Hash) &&
             (volumes.nil? || (volumes.is_a?(Hash) && volumes.empty?))
        raise Error, 'cached oracle image differs from its pinned platform/configuration or declares volumes'
      end
      { 'reference' => @image.fetch('reference'), 'platform' => @image.fetch('platform'),
        'manifest_sha256' => @image.fetch('manifest_sha256'), 'configuration_digest' => config_id,
        'engine_image_id' => image.fetch('Id') }
    end

    def prepare_files(directory, archive:, source:)
      inputs = File.join(directory, 'inputs')
      workspace = File.join(directory, 'work')
      Dir.mkdir(inputs, 0o700)
      Dir.mkdir(workspace, 0o700)
      FileUtils.copy_file(archive, File.join(inputs, 'otp.tar.gz'))
      unless Digest::SHA256.file(File.join(inputs, 'otp.tar.gz')).hexdigest == source.fetch('sha256')
        raise Error, 'oracle source changed while preparing read-only inputs'
      end
      INPUTS.each do |relative, name|
        path = File.realpath(File.join(@root, relative))
        raise Error, 'oracle host-tool input is not a regular file' unless File.file?(path)
        FileUtils.copy_file(path, File.join(inputs, name))
      end
      File.write(File.join(inputs, 'resolv.conf'), "nameserver 127.0.0.1\noptions timeout:1 attempts:1\n")
      hashes = Dir.children(inputs).sort.to_h do |name|
        [name, Digest::SHA256.file(File.join(inputs, name)).hexdigest]
      end
      [File.realpath(inputs), File.realpath(workspace), hashes]
    end

    def create_arguments(inputs:, volume:, cid_path:, owner:, deadline:, role: 'workload', artifacts: nil)
      mounts = if role == 'workload'
                 ['--mount', "type=volume,src=#{volume},dst=/tmp"]
               else
                 ['--mount', "type=volume,src=#{volume},dst=/native,readonly",
                  '--mount', "type=bind,src=#{artifacts},dst=/artifacts,bind-propagation=rprivate"]
               end
      ['create', '--pull', 'never', '--platform', @image.fetch('platform'), '--cidfile', cid_path,
       '--label', "#{OWNER_LABEL}=#{owner}", '--label', "#{ROLE_LABEL}=#{role}",
       '--network', 'none', '--init', '--ipc', 'private',
       '--cgroupns', 'private', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
       '--log-driver', 'none', '--restart', 'no', '--no-healthcheck', '--hostname', 'erx-oracle',
       '--add-host', 'erx-oracle:127.0.0.1', '--user', "#{Process.uid}:#{Process.gid}",
       '--cpus', @resources.fetch('cpus').to_s, '--memory', @resources.fetch('memory_bytes').to_s,
       '--memory-swap', @resources.fetch('memory_bytes').to_s,
       '--pids-limit', @resources.fetch('pids').to_s, '--shm-size', @resources.fetch('shm_bytes').to_s,
       '--mount', "type=bind,src=#{inputs},dst=/inputs,readonly,bind-propagation=rprivate",
       *mounts,
       '--mount', "type=bind,src=#{inputs}/resolv.conf,dst=/etc/resolv.conf,readonly,bind-propagation=rprivate",
       '--workdir', '/tmp', '--entrypoint', '/usr/bin/env', @image.fetch('reference'), '-i',
       *GUEST_ENV.map { |name, value| "#{name}=#{value}" }, '/usr/bin/timeout', '-k', '10',
       deadline.to_s, '/usr/local/bin/ruby', role == 'workload' ? '/inputs/container_job.rb' : '/inputs/export_job.rb']
    end

    def verify_container(value, image:, inputs:, volume:, deadline:, role: 'workload', artifacts: nil)
      unless value.is_a?(Hash) && value['Config'].is_a?(Hash) && value['HostConfig'].is_a?(Hash) &&
             value['State'].is_a?(Hash) && value['Mounts'].is_a?(Array) &&
             value.fetch('Mounts').all? { |mount| mount.is_a?(Hash) }
        raise Error, 'invalid oracle container inspection shape'
      end
      config = value.fetch('Config')
      host = value.fetch('HostConfig')
      unless config['Healthcheck'].is_a?(Hash) && host['LogConfig'].is_a?(Hash) && host['RestartPolicy'].is_a?(Hash)
        raise Error, 'invalid oracle health/log inspection shape'
      end
      expected_mounts = [['bind', inputs, '/inputs', false],
                         ['bind', File.join(inputs, 'resolv.conf'), '/etc/resolv.conf', false]]
      expected_mounts += if role == 'workload'
                           [['volume', volume, '/tmp', true]]
                         else
                           [['volume', volume, '/native', false], ['bind', artifacts, '/artifacts', true]]
                         end
      actual_mounts = value.fetch('Mounts').map do |mount|
        unless %w[bind volume].include?(mount['Type']) &&
               mount['Source'].is_a?(String) && mount['Destination'].is_a?(String) &&
               [true, false].include?(mount['RW'])
          raise Error, 'oracle container has an unexpected mount kind or propagation'
        end
        identity = if mount['Type'] == 'bind'
                     raise Error, 'oracle bind propagation differs from plan' unless mount['Propagation'] == 'rprivate'
                     mount.fetch('Source')
                   else
                     raise Error, 'oracle volume driver differs from plan' unless mount['Driver'] == 'local' && mount['Name'] == volume
                     mount.fetch('Name')
                   end
        [mount.fetch('Type'), identity, mount.fetch('Destination'), mount.fetch('RW')]
      end.sort
      security = host.fetch('SecurityOpt')
      valid = value.dig('State', 'Status') == 'created' && value.dig('State', 'Running') == false &&
              value['Image'] == image.fetch('engine_image_id') &&
              config['Image'] == @image.fetch('reference') &&
              config['User'] == "#{Process.uid}:#{Process.gid}" && config['Hostname'] == 'erx-oracle' &&
              config['WorkingDir'] == '/tmp' && host['PublishAllPorts'] == false &&
              config['Entrypoint'] == ['/usr/bin/env'] && config.dig('Healthcheck', 'Test') == ['NONE'] &&
              host['NetworkMode'] == 'none' && host['Init'] == true && host['IpcMode'] == 'private' &&
              host['CgroupnsMode'] == 'private' && ['', nil].include?(host['PidMode']) &&
              ['', nil].include?(host['UTSMode']) && ['', nil].include?(host['UsernsMode']) &&
              host['Privileged'] == false && Array(host['CapAdd']).empty? && host['CapDrop'] == ['ALL'] &&
              security.is_a?(Array) && security.size == 1 &&
              %w[no-new-privileges no-new-privileges:true].include?(security.first) &&
              Array(host['Devices']).empty? && Array(host['DeviceRequests']).empty? &&
              Array(host['DeviceCgroupRules']).empty? &&
              (host['PortBindings'].nil? || host['PortBindings'].empty?) &&
              host.dig('LogConfig', 'Type') == 'none' && host['AutoRemove'] == false &&
              host.dig('RestartPolicy', 'Name') == 'no' && host.dig('RestartPolicy', 'MaximumRetryCount') == 0 &&
              host['NanoCpus'] == @resources.fetch('cpus') * 1_000_000_000 &&
              host['Memory'] == @resources.fetch('memory_bytes') && host['MemorySwap'] == host['Memory'] &&
              host['PidsLimit'] == @resources.fetch('pids') && host['ShmSize'] == @resources.fetch('shm_bytes') &&
              actual_mounts == expected_mounts.sort && config.dig('Labels', ROLE_LABEL) == role
      raise Error, 'created oracle container differs from its isolation/resource plan' unless valid
      command = config.fetch('Cmd')
      unless command == ['-i', *GUEST_ENV.map { |name, data| "#{name}=#{data}" }, '/usr/bin/timeout', '-k', '10',
                         deadline.to_s, '/usr/local/bin/ruby', role == 'workload' ? '/inputs/container_job.rb' : '/inputs/export_job.rb']
        raise Error, 'created oracle container command differs from its deadline plan'
      end
    rescue KeyError => error
      raise Error, "invalid oracle container inspection fields: #{error.message}"
    end

    def inspect_owned(connection, cid:, owner:, role: 'workload')
      value = docker_json(connection, ['inspect', '--type', 'container', cid, '--format', '{{json .}}'],
                          name: 'oracle-container-inspect')
      unless value['Id'] == cid && value['Config'].is_a?(Hash) &&
             value.fetch('Config')['Labels'].is_a?(Hash) &&
             value.fetch('Config').fetch('Labels')[OWNER_LABEL] == owner &&
             value.fetch('Config').fetch('Labels')[ROLE_LABEL] == role
        raise Error, 'container identity or ownership label mismatch'
      end
      value
    end

    def cleanup_owned(connection, cid_path:, owner:, role: 'workload')
      ids = docker(connection, ['ps', '--all', '--no-trunc', '--filter', "label=#{OWNER_LABEL}=#{owner}",
                                '--filter', "label=#{ROLE_LABEL}=#{role}",
                                '--format', '{{.ID}}'], name: 'oracle-container-recover', deadline: 30)
      owned = File.read(ids.fetch('log')).lines.map(&:strip).reject(&:empty?).map { |value| validate_cid(value) }
      raise Error, 'ambiguous oracle container ownership after creation' if owned.size > 1
      cid = find_cid(cid_path) || owned.first
      return if cid.nil?
      raise Error, 'oracle CID and recovered ownership differ' unless owned.empty? || owned == [cid]
      unless owned.empty?
        inspect_owned(connection, cid: cid, owner: owner, role: role)
        docker(connection, ['rm', '--force', cid], name: 'oracle-container-remove', deadline: 30)
      end
      check = docker(connection, ['ps', '--all', '--no-trunc', '--filter', "id=#{cid}", '--format', '{{.ID}}'],
                     name: 'oracle-container-removed', deadline: 30)
      raise Error, "owned oracle container still exists: #{cid}" unless File.read(check.fetch('log')).strip.empty?
    end

    def volume_present?(connection, name)
      command = docker(connection, ['volume', 'ls', '--filter', "name=#{name}", '--format', '{{.Name}}'],
                       name: 'oracle-volume-list', deadline: 30)
      names = File.read(command.fetch('log')).lines.map(&:strip).reject(&:empty?)
      names.include?(name)
    end

    def inspect_volume(connection, name:, owner:)
      value = docker_json(connection, ['volume', 'inspect', name, '--format', '{{json .}}'],
                          name: 'oracle-volume-inspect')
      unless value['Name'] == name && value['Driver'] == 'local' && value['Scope'] == 'local' &&
             [nil, {}].include?(value['Options']) && value['Labels'].is_a?(Hash) &&
             value.fetch('Labels')[OWNER_LABEL] == owner
        raise Error, 'native oracle volume differs from its ownership/storage plan'
      end
      value
    end

    def create_volume(connection, name:, owner:)
      raise Error, 'oracle volume name already exists' if volume_present?(connection, name)
      docker(connection, ['volume', 'create', '--driver', 'local', '--label', "#{OWNER_LABEL}=#{owner}", name],
             name: 'oracle-volume-create', deadline: 30)
      inspect_volume(connection, name: name, owner: owner)
    end

    def remove_volume(connection, name:, owner:)
      return unless volume_present?(connection, name)
      inspect_volume(connection, name: name, owner: owner)
      docker(connection, ['volume', 'rm', name], name: 'oracle-volume-remove', deadline: 30)
      raise Error, 'owned oracle volume still exists after removal' if volume_present?(connection, name)
    end

    def export_artifacts(connection, inputs:, workspace:, volume:, cid_path:, owner:, image:, manifest:)
      manifest.merge!('state' => 'exporting', 'export_started_at' => Time.now.utc.iso8601)
      write_manifest(manifest.fetch('directory'), manifest)
      arguments = create_arguments(inputs: inputs, volume: volume, cid_path: cid_path, owner: owner,
                                   deadline: 600, role: 'export', artifacts: workspace)
      docker(connection, arguments, name: 'oracle-export-create', deadline: 30)
      cid = read_cid(cid_path)
      manifest['export_cid'] = cid
      write_manifest(manifest.fetch('directory'), manifest)
      inspection = inspect_owned(connection, cid: cid, owner: owner, role: 'export')
      verify_container(inspection, image: image, inputs: inputs, volume: volume, deadline: 600,
                       role: 'export', artifacts: workspace)
      docker(connection, ['start', '--attach', cid], name: 'oracle-export-run', deadline: 630)
      final = inspect_owned(connection, cid: cid, owner: owner, role: 'export').fetch('State')
      unless final['Status'] == 'exited' && final['Running'] == false &&
             final['OOMKilled'] == false && final['ExitCode'] == 0
        raise Error, 'oracle artifact exporter did not exit successfully'
      end
      OracleExport.verify(destination: workspace, limits: OracleExport::DEFAULT_LIMITS)
    rescue KeyError => error
      raise Error, "invalid oracle exporter inspection fields: #{error.message}"
    end

    def finish_build(result)
      unless result.fetch('state') == 'completed' && result.fetch('guest').dig('build', 'state') == 'ready'
        raise Error, "Linux oracle build failed; report: #{result.fetch('report')}"
      end
      result
    end

    def collect_suite(result)
      workspace = result.fetch('workspace')
      suite = result.fetch('guest')['suite_command'] || { 'state' => result.fetch('state') }
      suite = suite.merge('state' => 'timed_out') if result.fetch('state') == 'timed_out'
      xml = Dir.glob(File.join(workspace, 'source/**/make_test_dir/ct_logs/**/junit_report.xml'))
      report = read_suite_evidence(xml_reports: xml, events: File.join(workspace, 'events.jsonl'), command: suite)
      artifacts = result.fetch('artifacts')
      files = artifacts.fetch('files').map { |entry| entry.fetch('path') }
      report['cases'].each { |record| project_case_log(record, workspace: workspace, exported_files: files) }
      report.merge!('execution_context' => 'linux-container', 'container' => result,
                     'oracle_build' => result.fetch('guest')['build'])
      ordinary_test_failure = result.fetch('state') == 'failed' &&
                              result.fetch('guest').dig('suite_command', 'state') == 'failed'
      unless result.fetch('state') == 'completed' || ordinary_test_failure
        report['state'] = result.fetch('state')
        report['complete'] = false
      end
      unless artifacts.fetch('mandatory_evidence') == 'complete'
        report['complete'] = false
        report['state'] = 'incomplete' if %w[completed failed].include?(report.fetch('state'))
      end
      output = File.join(result.fetch('directory'), 'suite-result.json')
      report['report'] = output
      File.write(output, JSON.pretty_generate(report) + "\n")
      raise Error, "Linux oracle suite #{report.fetch('state')}; report: #{output}" unless report.fetch('state') == 'completed'
      report
    end

    # Parser refusal is incomplete evidence. A valid event stream still names
    # observed cases when XML is truncated; invalid events leave counts unknown.
    def read_suite_evidence(xml_reports:, events:, command:)
      report = OracleResults.read(xml: xml_reports.size == 1 ? xml_reports.first : nil, events: events, command: command)
      report['junit_reports'] = xml_reports
      report
    rescue Error => original
      begin
        partial = OracleResults.read(xml: nil, events: events, command: command)
      rescue Error => event_error
        partial = { 'counts' => nil, 'observed_counts' => nil, 'cases' => [], 'partial_events' => [],
                    'command' => command, 'event_report' => events, 'event_diagnostic' => event_error.message }
      end
      partial.merge('state' => 'incomplete', 'complete' => false, 'diagnostic' => original.message,
                    'junit_report' => xml_reports.size == 1 ? xml_reports.first : nil,
                    'junit_reports' => xml_reports)
    end

    def project_case_log(record, workspace:, exported_files:)
      original = record['log']
      record['upstream_log'] = original
      record['log'] = nil
      record['log_status'] = 'unknown'
      return unless original.is_a?(String) && original.start_with?('/tmp/erx-oracle/')
      relative = original.delete_prefix('/tmp/erx-oracle/')
      return if relative.split('/').any? { |part| ['', '.', '..'].include?(part) }
      return unless exported_files.include?(relative)
      candidate = File.join(workspace, relative)
      return unless File.file?(candidate) && File.realpath(candidate).start_with?(File.realpath(workspace) + '/')
      record['log'] = candidate
      record['log_status'] = 'available'
    end

    def read_guest_result(workspace)
      path = File.join(workspace, 'result.json')
      unless File.file?(path)
        return { 'state' => 'incomplete', 'metadata_status' => 'missing',
                 'diagnostic' => 'guest produced no completed result' }
      end
      value = read_json(path)
      unless value.is_a?(Hash) && %w[completed failed timed_out cancelled setup_error incomplete].include?(value['state']) &&
             (!value.key?('build') || value['build'].is_a?(Hash)) &&
             (!value.key?('suite_command') || (value['suite_command'].is_a?(Hash) &&
                %w[succeeded failed timed_out cancelled setup_error].include?(value.fetch('suite_command')['state'])))
        raise Error, 'invalid guest oracle result shape'
      end
      value.merge('metadata_status' => 'complete')
    rescue Error, SystemCallError => error
      { 'state' => 'incomplete', 'metadata_status' => 'invalid', 'diagnostic' => error.message }
    end

    def validate_selection(suite, testcase:)
      raise Error, 'invalid selected Common Test suite' if suite && !/\A[A-Za-z][A-Za-z0-9_]*_SUITE\z/.match?(suite)
      if testcase && (!suite || !/\A[A-Za-z][A-Za-z0-9_]*\z/.match?(testcase))
        raise Error, 'invalid selected Common Test case'
      end
    end

    def read_cid(path)
      find_cid(path) || raise(Error, 'oracle container creation did not record a CID')
    end

    def find_cid(path)
      return nil unless File.file?(path)
      value = BoundedFile.read(path, maximum: 128).strip
      value.empty? ? nil : validate_cid(value)
    end

    def validate_cid(value)
      raise Error, 'invalid owned Docker CID' unless /\A[0-9a-f]{64}\z/.match?(value)
      value
    end

    def docker(connection, arguments, name:, deadline: 30, cancelled: nil, success: nil)
      cli(['--config', connection.fetch('config'), '--context', 'erx-oracle', *arguments],
          name: name, deadline: deadline, cancelled: cancelled, success: success)
    end

    def docker_json(connection, arguments, name:)
      command = docker(connection, arguments, name: name)
      value = read_json(command.fetch('log'))
      raise Error, 'Docker returned a non-object identity' unless value.is_a?(Hash)
      value
    end

    def cli(arguments, name:, deadline:, cancelled: nil, success: nil)
      # A fresh environment removes Docker redirects, credentials helpers and
      # proxy variables by construction rather than enumerating their names.
      path = [File.dirname(@docker), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].uniq.join(':')
      @runner.run(['/usr/bin/env', '-i', "PATH=#{path}", 'LANG=C', @docker, *arguments],
                  name: name, deadline: deadline, cancelled: cancelled, success: success)
    end

    def read_json(path)
      bytes = File.binread(path, 8 * 1024 * 1024 + 1)
      JsonInput.parse(bytes, max_bytes: 8 * 1024 * 1024, label: 'oracle engine/result JSON')
    end

    def executable(program)
      if program.include?('/')
        raise Error, "missing Docker tool: #{program}" unless File.file?(program) && File.executable?(program)
        return File.expand_path(program)
      end
      candidate = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, program) }
                     .find { |path| File.file?(path) && File.executable?(path) }
      raise Error, 'missing Docker CLI; install the development tool' unless candidate
      # Multi-call tool distributions choose their behaviour from argv[0].
      File.expand_path(candidate)
    end

    def write_manifest(directory, value)
      temporary = File.join(directory, 'manifest.json.tmp')
      File.write(temporary, JSON.pretty_generate(value) + "\n")
      File.rename(temporary, File.join(directory, 'manifest.json'))
    end
  end
end
