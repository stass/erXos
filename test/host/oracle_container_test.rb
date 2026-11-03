# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_container'
require_relative '../../tools/lib/erx/oracle_guest'

class OracleContainerTest < Minitest::Test
  def self.with_controller_events(events)
    token = '#Ref<0.0.1>'
    events.flat_map do |event|
      case event.fetch('event')
      when 'test_start'
        [event, { 'event' => 'selection_begin', 'id' => '#Ref<9.0.0>' },
         { 'event' => 'job_selected', 'selection' => '#Ref<9.0.0>', 'id' => '#Ref<9.0.1>', 'name' => 'fixture' },
         { 'event' => 'selection_seal', 'id' => '#Ref<9.0.0>', 'count' => 1 },
         { 'event' => 'job_admitted', 'id' => '#Ref<9.0.1>' },
         { 'event' => 'job_worker', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>' }]
      when 'tc_start'
        [{ 'event' => 'case_start', 'id' => token, 'suite' => event.fetch('suite'),
           'testcase' => event.fetch('testcase'), 'groups' => [], 'log' => nil, 'worker' => '<0.1.0>' }, event]
      when 'tc_done'
        [event, { 'event' => 'case_finish', 'id' => token, 'status' => event.fetch('result'),
                  'number' => 1, 'detail' => event.fetch('detail') }]
      when 'test_done'
        [{ 'event' => 'job_traversed', 'worker' => '<0.1.0>' },
         { 'event' => 'job_exit', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>', 'normal' => true },
         { 'event' => 'selection_close', 'id' => '#Ref<9.0.0>', 'normal' => true }, event]
      else [event]
      end
    end
  end

  class ImageRunner
    attr_reader :calls

    def initialize(directory, image)
      @directory = directory
      @image = image
      @calls = []
    end

    def run(argv, **options)
      @calls << [argv, options]
      path = File.join(@directory, "command-#{@calls.size}.log")
      File.write(path, JSON.generate(@image))
      { 'state' => 'succeeded', 'log' => path }
    end
  end

  class SourceFixture
    def archive_for(_id)
      [{ 'sha256' => 'a' * 64 }, '/unused-archive']
    end
  end

  class LifecycleAdapter < Erx::OracleContainer
    private

    def prepare_context(directory)
      { 'config' => directory, 'endpoint' => 'unix:///owned-test-socket' }
    end

    def verify_image(_connection)
      { 'engine_image_id' => 'sha256:' + 'b' * 64,
        'configuration_digest' => 'sha256:' + 'c' * 64 }
    end

    def prepare_files(directory, archive:, source:)
      inputs = File.join(directory, 'inputs')
      work = File.join(directory, 'work')
      Dir.mkdir(inputs)
      Dir.mkdir(work)
      [inputs, work, {}]
    end
  end

  class LifecycleRunner
    attr_reader :calls
    attr_accessor :partial_create, :invalid_network, :invalid_shape, :remove_failure,
                  :attach_state, :recovered_id, :partial_volume, :invalid_volume,
                  :partial_export, :export_failure, :volume_remove_failure
    attr_accessor :export_missing_field, :workload_final_missing, :truncated_guest_result, :empty_cid_file,
                  :malformed_xml, :malformed_events, :multiple_xml

    def initialize(root)
      @root = root
      @calls = []
      @containers = {}
      @native = Dir.mktmpdir('native-fixture-', root)
      @attach_state = 'succeeded'
      @cid = 'd' * 64
    end

    def run(argv, **options)
      name = options.fetch(:name)
      @calls << [name, argv]
      path = File.join(@root, "lifecycle-#{@calls.size}.log")
      File.write(path, '')
      options.fetch(:success).call(path) if name.start_with?('oracle-linux-') && options[:success]
      body = case name
             when 'oracle-engine'
               JSON.generate('OSType' => 'linux', 'NCPU' => 8, 'MemTotal' => 32 * 1024**3)
             when 'oracle-host'
               "fixture host\n"
             when 'oracle-volume-list'
               @volume ? "#{@volume.fetch('Name')}\n" : ''
             when 'oracle-volume-create'
               @volume = { 'Name' => argv.last, 'Driver' => 'local', 'Scope' => 'local', 'Options' => nil,
                           'Labels' => { Erx::OracleContainer::OWNER_LABEL => argv[argv.index('--label') + 1].split('=', 2).last } }
               ''
             when 'oracle-volume-inspect'
               JSON.generate(invalid_volume ? @volume.merge('Driver' => 'external') : @volume)
             when 'oracle-volume-remove'
               @volume = nil unless volume_remove_failure
               ''
             when 'oracle-container-create', 'oracle-export-create'
               role = name == 'oracle-container-create' ? 'workload' : 'export'
               cid = role == 'workload' ? @cid : 'e' * 64
               @containers[cid] = { create: argv, started: false }
               cid_path = argv.fetch(argv.index('--cidfile') + 1)
               partial = role == 'workload' ? partial_create : partial_export
               File.write(cid_path, cid) unless partial
               File.write(cid_path, '') if empty_cid_file && role == 'workload'
               ''
             when 'oracle-container-inspect'
               cid = argv.find { |value| value.match?(/\A[de]{64}\z/) }
               JSON.generate(inspection(cid))
             when /\Aoracle-linux-/
               @containers.fetch(@cid)[:started] = true
               create = @containers.fetch(@cid).fetch(:create)
               input_mount = create.each_cons(2).find { |flag, value| flag == '--mount' && value.include?('dst=/inputs,') }.last
               inputs = input_mount.match(/src=([^,]+)/)[1]
               @plan = JSON.parse(File.read(File.join(inputs, 'job.json')))
               write_guest_results
               ''
             when 'oracle-export-run'
               raise 'export ran while workload namespace exists' if @containers.key?(@cid)
               record = @containers.fetch('e' * 64)
               record[:started] = true
               mounts = record.fetch(:create).each_cons(2).select { |flag, _| flag == '--mount' }.map(&:last)
               destination = mounts.find { |value| value.include?('dst=/artifacts') }.match(/src=([^,]+)/)[1]
               inputs = mounts.find { |value| value.include?('dst=/inputs,') }.match(/src=([^,]+)/)[1]
               @plan ||= JSON.parse(File.read(File.join(inputs, 'job.json')))
               Erx::OracleExport.call(source: @native, destination: destination,
                                     operation: @plan.fetch('operation'), suite: @plan['suite'],
                                     limits: Erx::OracleExport::DEFAULT_LIMITS)
               ''
             when 'oracle-container-recover'
               role = argv.find { |value| value.start_with?("label=#{Erx::OracleContainer::ROLE_LABEL}=") }.split('=').last
               cid = role == 'workload' ? @cid : 'e' * 64
               @containers.key?(cid) ? "#{role == 'workload' ? recovered_id || cid : cid}\n" : ''
             when 'oracle-container-remove'
               @containers.delete(argv.last) unless remove_failure
               ''
             when 'oracle-container-removed'
               cid = argv.find { |value| value.start_with?('id=') }.delete_prefix('id=')
               @containers.key?(cid) ? "#{cid}\n" : ''
             else
               raise "unexpected fake-engine command #{name}"
             end
      File.write(path, body)
      result = { 'state' => 'succeeded', 'log' => path }
      if (name == 'oracle-container-create' && partial_create) ||
         (name == 'oracle-export-create' && partial_export) ||
         (name == 'oracle-export-run' && export_failure) ||
         (name == 'oracle-volume-create' && partial_volume) ||
         (name == 'oracle-volume-remove' && volume_remove_failure) ||
         (name == 'oracle-container-remove' && remove_failure)
        raise Erx::CommandError, result.merge('state' => 'failed')
      end
      if name.start_with?('oracle-linux-') && attach_state != 'succeeded'
        raise Erx::CommandError, result.merge('state' => attach_state)
      end
      result
    end

    def inspection(cid)
      record = @containers.fetch(cid)
      create = record.fetch(:create)
      image_index = create.index { |argument| argument.start_with?('docker.io/library/ruby@') }
      mounts = create.each_cons(2).select { |flag, _value| flag == '--mount' }.map do |_flag, value|
        source = value.match(/src=([^,]+)/)[1]
        target = value.match(/dst=([^,]+)/)[1]
        type = value.include?('type=volume') ? 'volume' : 'bind'
        { 'Type' => type, 'Source' => source, 'Name' => source, 'Driver' => 'local', 'Destination' => target,
          'RW' => !value.include?(',readonly'), 'Propagation' => 'rprivate' }
      end
      state = { 'Status' => record.fetch(:started) ? 'exited' : 'created', 'Running' => false,
                'ExitCode' => 0, 'OOMKilled' => false }
      value = {
        'Id' => cid, 'Image' => 'sha256:' + 'b' * 64, 'State' => state,
        'Config' => { 'Image' => create.fetch(image_index), 'User' => "#{Process.uid}:#{Process.gid}",
                      'Hostname' => 'erx-oracle', 'WorkingDir' => '/tmp',
                      'Labels' => create.each_cons(2).select { |flag, _| flag == '--label' }.map { |_, value| value.split('=', 2) }.to_h,
                      'Entrypoint' => ['/usr/bin/env'], 'Healthcheck' => { 'Test' => ['NONE'] },
                      'Cmd' => create.drop(image_index + 1) },
        'HostConfig' => {
          'NetworkMode' => invalid_network ? 'host' : 'none', 'Init' => true, 'IpcMode' => 'private',
          'CgroupnsMode' => 'private', 'PidMode' => '', 'UTSMode' => '', 'UsernsMode' => '',
          'Privileged' => false, 'CapAdd' => nil, 'CapDrop' => ['ALL'], 'SecurityOpt' => ['no-new-privileges'],
          'Devices' => [], 'DeviceRequests' => nil, 'PortBindings' => {}, 'PublishAllPorts' => false,
          'LogConfig' => { 'Type' => 'none' }, 'AutoRemove' => false, 'NanoCpus' => 4_000_000_000,
          'RestartPolicy' => { 'Name' => 'no', 'MaximumRetryCount' => 0 },
          'Memory' => 8 * 1024**3, 'MemorySwap' => 8 * 1024**3,
          'PidsLimit' => 4096, 'ShmSize' => 256 * 1024**2
        }, 'Mounts' => mounts
      }
      case invalid_shape
      when true then value['Mounts'] = nil
      when :health then value.fetch('Config')['Healthcheck'] = 'bad-shape'
      when :log then value.fetch('HostConfig')['LogConfig'] = 'bad-shape'
      when :mount then value.fetch('Mounts').first['Source'] = 7
      when :restart then value.fetch('HostConfig')['RestartPolicy'] = { 'Name' => 'always', 'MaximumRetryCount' => 0 }
      end
      if cid == 'e' * 64
        case export_missing_field
        when 'SecurityOpt' then value.fetch('HostConfig').delete('SecurityOpt')
        when 'Cmd' then value.fetch('Config').delete('Cmd')
        when 'State' then value.delete('State') if record.fetch(:started)
        end
      end
      value.fetch('State').delete('OOMKilled') if cid == @cid && record.fetch(:started) && workload_final_missing
      value
    end

    def write_guest_results
      result = { 'state' => 'completed' }
      if @plan.fetch('operation') == 'run'
        result['suite_command'] = { 'state' => 'succeeded' }
        logs = File.join(@native, 'source/erts/emulator/make_test_dir/ct_logs/fixture')
        FileUtils.mkdir_p(logs)
        xml = '<testsuites><testsuite name="one_SUITE" tests="1" failures="0" skipped="0" errors="0">' \
              '<testcase name="one" log="" time="0.1"/></testsuite></testsuites>'
        File.write(File.join(logs, 'junit_report.xml'), malformed_xml ? '<testsuites>' : xml)
        if multiple_xml
          other = File.join(logs, 'other')
          Dir.mkdir(other)
          File.write(File.join(other, 'junit_report.xml'), xml)
        end
        events = [{ 'event' => 'test_start' },
                  { 'event' => 'tc_start', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil },
                  { 'event' => 'tc_done', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil,
                    'result' => 'passed', 'detail' => 'ok' },
                  { 'event' => 'test_stats', 'passed' => 1, 'failed' => 0, 'user_skip' => 0, 'auto_skip' => 0 },
                  { 'event' => 'test_done' }]
        bytes = malformed_events ? '{"event":' : OracleContainerTest.with_controller_events(events).map { |event| JSON.generate(event) + "\n" }.join
        File.write(File.join(@native, 'events.jsonl'), bytes)
      end
      bytes = truncated_guest_result ? '{"state":' : JSON.generate(result)
      File.write(File.join(@native, 'result.json'), bytes)
    end
  end

  def setup
    @root = Dir.mktmpdir('erx-container-test-')
    FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(@root, 'deps.lock'))
    dependencies = Erx::Dependencies.new(root: @root, runner: nil)
    @image = dependencies.image_for('oracle-toolchain')
    @observed = JSON.parse(File.read(File.expand_path('../fixtures/oracle/image-inspect-manifest-id.json', __dir__)))
    @runner = ImageRunner.new(@root, @observed)
    @adapter = Erx::OracleContainer.new(root: @root, context: 'orbstack', image: @image,
                                       runner: @runner, docker_program: '/usr/bin/true')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_platform_manifest_id_is_not_misread_as_configuration_digest
    identity = @adapter.send(:verify_image, 'config' => '/private-config')
    assert_equal @observed.fetch('Id'), identity.fetch('engine_image_id')
    assert_equal "sha256:#{@image.fetch('config_sha256')}", identity.fetch('configuration_digest')
    assert_equal @image.fetch('manifest_sha256'), identity.fetch('manifest_sha256')
  end

  def test_multicall_docker_symlink_keeps_its_invocation_name
    target = File.join(@root, 'docker-tools')
    link = File.join(@root, 'docker')
    File.write(target, 'fixture')
    File.chmod(0o755, target)
    File.symlink(target, link)
    adapter = Erx::OracleContainer.new(root: @root, context: 'orbstack', image: @image,
                                       runner: @runner, docker_program: link)
    adapter.send(:cli, [], name: 'fixture', deadline: 1)
    assert_includes @runner.calls.last.first, link
  end

  def test_fixture_witness_checks_the_owned_running_namespace
    owner = 'a' * 64
    cid = 'd' * 64
    directory = File.join(@root, 'build/oracle/linux/emu/fixture')
    FileUtils.mkdir_p(directory)
    value = { 'Id' => cid, 'State' => { 'Running' => true, 'Status' => 'running' },
              'Config' => { 'Labels' => { Erx::OracleContainer::OWNER_LABEL => owner,
                                         Erx::OracleContainer::ROLE_LABEL => 'workload' } } }
    runner = ImageRunner.new(@root, value)
    adapter = Erx::OracleContainer.new(root: @root, context: 'orbstack', image: @image,
                                       runner: runner, docker_program: '/usr/bin/true')
    record = { 'operation' => 'detached', 'context' => 'orbstack', 'directory' => directory,
               'owner' => owner, 'cid' => cid }
    assert_equal 'running', adapter.fixture_witness(record).fetch('state')
    value.fetch('State').merge!('Running' => false, 'Status' => 'exited')
    assert_raises(Erx::Error) { adapter.fixture_witness(record) }
    value.fetch('Config').fetch('Labels')[Erx::OracleContainer::OWNER_LABEL] = 'b' * 64
    assert_raises(Erx::Error) { adapter.fixture_witness(record) }
  end

  def test_successful_guest_suite_is_a_completed_invocation
    assert_equal 'completed', Erx::ContainerOracleJob.suite_state('state' => 'succeeded')
    assert_equal 'timed_out', Erx::ContainerOracleJob.suite_state('state' => 'timed_out')
  end

  def test_application_targets_use_the_configured_primary_runtime
    assert_empty Erx::ContainerOracleJob.suite_flavour_options(suite: 'kernel', flavour: 'emu')
    assert_empty Erx::ContainerOracleJob.suite_flavour_options(suite: 'stdlib', flavour: 'jit')
    assert_equal ['FLAVOR=emu'], Erx::ContainerOracleJob.suite_flavour_options(suite: 'emulator', flavour: 'emu')
    assert_raises(Erx::Error) { Erx::ContainerOracleJob.suite_flavour_options(suite: 'kernel', flavour: 'unknown') }
  end

  def test_detached_readiness_accepts_an_initially_empty_attached_log
    adapter, = lifecycle
    result = adapter.detached_fixture
    assert_equal 'completed', result.fetch('state')
    assert result.fetch('cleanup_verified')
  end

  def test_guest_result_records_startup_marker_presence_after_the_operation
    job = Erx::ContainerOracleJob.allocate
    job.define_singleton_method(:execute_plan) { { 'state' => 'completed' } }
    File.stub(:exist?, ->(path) { path == '/tmp/erx-oracle/operator-startup-executed' }) do
      assert_equal true, job.call.fetch('operator_startup_marker')
    end
  end

  def test_guest_result_keeps_kernel_memory_events_as_bounded_evidence
    job = Erx::ContainerOracleJob.allocate
    job.define_singleton_method(:execute_plan) { { 'state' => 'completed' } }
    File.stub(:binread, "oom 2\noom_kill 1\n") do
      evidence = job.call.fetch('memory_events')
      assert_equal 'available', evidence.fetch('status')
      assert_equal "oom 2\noom_kill 1\n", evidence.fetch('contents')
    end
  end

  def test_wrong_platform_or_manifest_descriptor_is_refused
    @observed['Architecture'] = 'amd64'
    assert_raises(Erx::Error) { @adapter.send(:verify_image, 'config' => '/private-config') }
    @observed['Architecture'] = 'arm64'
    @observed.fetch('Descriptor')['digest'] = 'sha256:' + 'f' * 64
    assert_raises(Erx::Error) { @adapter.send(:verify_image, 'config' => '/private-config') }
  end

  def test_create_plan_has_no_implicit_network_or_authority
    argv = @adapter.send(:create_arguments, inputs: '/inputs-source', volume: 'owned-native-volume',
                         cid_path: '/private-cid', owner: 'a' * 64, deadline: 60)
    assert_equal 'never', argv[argv.index('--pull') + 1]
    assert_equal 'none', argv[argv.index('--network') + 1]
    assert_equal 'ALL', argv[argv.index('--cap-drop') + 1]
    assert_equal 'none', argv[argv.index('--log-driver') + 1]
    refute_includes argv, '--privileged'
    refute_includes argv, '--publish'
    refute_includes argv, '--device'
    assert_includes argv, '/usr/bin/timeout'
    mounts = argv.each_cons(2).select { |flag, _| flag == '--mount' }.map(&:last)
    assert_includes mounts, 'type=volume,src=owned-native-volume,dst=/tmp'
    assert mounts.select { |value| value.start_with?('type=bind,') }.all? { |value| value.include?(',readonly') }
  end

  def test_timeout_and_final_container_state_cannot_become_completion
    final = { 'Status' => 'exited', 'Running' => false, 'ExitCode' => 0, 'OOMKilled' => false }
    guest = { 'state' => 'completed', 'suite_command' => { 'state' => 'succeeded' } }
    assert_equal 'completed', @adapter.send(:invocation_state, { 'state' => 'succeeded' }, container: final, guest: guest)
    assert_equal 'timed_out', @adapter.send(:invocation_state, { 'state' => 'timed_out' }, container: final, guest: guest)
    guest['suite_command']['state'] = 'timed_out'
    guest['state'] = 'timed_out'
    assert_equal 'timed_out', @adapter.send(:invocation_state, { 'state' => 'failed' }, container: final, guest: guest)
    guest['state'] = 'completed'
    guest['suite_command']['state'] = 'succeeded'
    final['Running'] = true
    final['Status'] = 'running'
    refute_equal 'completed', @adapter.send(:invocation_state, { 'state' => 'succeeded' }, container: final, guest: guest)
    final.delete('OOMKilled')
    assert_raises(Erx::Error) do
      @adapter.send(:invocation_state, { 'state' => 'succeeded' }, container: final, guest: guest)
    end
  end

  def test_cancellation_taints_an_otherwise_complete_case_report
    work = File.join(@root, 'work')
    logdir = File.join(work, 'source/erts/emulator/make_test_dir/ct_logs/one')
    FileUtils.mkdir_p(logdir)
    xml = '<testsuites><testsuite name="one_SUITE" tests="1" failures="0" skipped="0" errors="0">' \
          '<testcase name="one" log="" time="0.1"/></testsuite></testsuites>'
    File.write(File.join(logdir, 'junit_report.xml'), xml)
    events = [{ 'event' => 'test_start' },
              { 'event' => 'tc_start', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil },
              { 'event' => 'tc_done', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil, 'result' => 'passed', 'detail' => 'ok' },
              { 'event' => 'test_stats', 'passed' => 1, 'failed' => 0, 'user_skip' => 0, 'auto_skip' => 0 },
              { 'event' => 'test_done' }]
    File.write(File.join(work, 'events.jsonl'), self.class.with_controller_events(events).map { |event| JSON.generate(event) + "\n" }.join)
    input = { 'state' => 'cancelled', 'workspace' => work, 'directory' => @root,
              'artifacts' => { 'mandatory_evidence' => 'complete', 'files' => [] },
              'guest' => { 'suite_command' => { 'state' => 'succeeded' } } }
    assert_raises(Erx::Error) { @adapter.send(:collect_suite, input) }
    report = JSON.parse(File.read(File.join(@root, 'suite-result.json')))
    assert_equal 'cancelled', report.fetch('state')
    refute report.fetch('complete')
  end

  def test_finished_failed_cases_remain_complete_evidence
    work = File.join(@root, 'work')
    logdir = File.join(work, 'source/erts/emulator/make_test_dir/ct_logs/one')
    FileUtils.mkdir_p(logdir)
    xml = '<testsuites><testsuite name="one_SUITE" tests="1" failures="1" skipped="0" errors="0">' \
          '<testcase name="one" log="" time="0.1"><failure>expected test failure</failure></testcase></testsuite></testsuites>'
    File.write(File.join(logdir, 'junit_report.xml'), xml)
    events = [{ 'event' => 'test_start' },
              { 'event' => 'tc_start', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil },
              { 'event' => 'tc_done', 'suite' => 'one_SUITE', 'testcase' => 'one', 'group' => nil, 'result' => 'failed', 'detail' => 'failure' },
              { 'event' => 'test_stats', 'passed' => 0, 'failed' => 1, 'user_skip' => 0, 'auto_skip' => 0 },
              { 'event' => 'test_done' }]
    File.write(File.join(work, 'events.jsonl'), self.class.with_controller_events(events).map { |event| JSON.generate(event) + "\n" }.join)
    input = { 'state' => 'failed', 'workspace' => work, 'directory' => @root,
              'artifacts' => { 'mandatory_evidence' => 'complete', 'files' => [] },
              'guest' => { 'suite_command' => { 'state' => 'failed' } } }
    assert_raises(Erx::Error) { @adapter.send(:collect_suite, input) }
    report = JSON.parse(File.read(File.join(@root, 'suite-result.json')))
    assert_equal 'failed', report.fetch('state')
    assert report.fetch('complete')
  end

  def lifecycle
    runner = LifecycleRunner.new(@root)
    adapter = LifecycleAdapter.new(root: @root, context: 'orbstack', image: @image,
                                   runner: runner, docker_program: '/usr/bin/true')
    adapter.instance_variable_set(:@dependencies, SourceFixture.new)
    [adapter, runner]
  end

  def test_complete_invocation_removes_only_its_owned_container
    adapter, runner = lifecycle
    result = adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60)
    assert_equal 'completed', result.fetch('state')
    assert result.fetch('cleanup_verified')
    assert_equal 'fixture host', result.fetch('host').fetch('identity')
    removal = runner.calls.find { |name, _argv| name == 'oracle-container-remove' }
    assert_equal 'd' * 64, removal.last.last
    assert runner.calls.any? { |name, _argv| name == 'oracle-container-removed' }
    removal_index = runner.calls.index { |name, argv| name == 'oracle-container-removed' && argv.include?('id=' + 'd' * 64) }
    export_index = runner.calls.index { |name, _argv| name == 'oracle-export-create' }
    assert_operator removal_index, :<, export_index
    assert runner.calls.any? { |name, _argv| name == 'oracle-volume-remove' }
  end

  def test_linked_build_parent_is_refused_before_any_outside_write
    outside = Dir.mktmpdir('erx-outside-oracle-')
    adapter, _runner = lifecycle
    File.write(File.join(outside, 'sentinel'), 'unchanged')
    File.symlink(outside, File.join(@root, 'build'))
    assert_raises(Erx::Error) do
      adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60)
    end
    assert_equal ['sentinel'], Dir.children(outside)
    assert_equal 'unchanged', File.read(File.join(outside, 'sentinel'))
  ensure
    FileUtils.remove_entry(outside) if outside && File.directory?(outside)
  end

  def test_partial_creation_recovers_exact_label_before_cleanup
    adapter, runner = lifecycle
    runner.partial_create = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    refute runner.calls.any? { |name, _argv| name.start_with?('oracle-linux-') }
    assert runner.calls.any? { |name, _argv| name == 'oracle-container-remove' }
  end

  def test_empty_cid_file_is_an_unrecorded_partial_creation
    adapter, runner = lifecycle
    runner.empty_cid_file = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    refute runner.calls.any? { |name, _| name.start_with?('oracle-linux-') }
    assert runner.calls.any? { |name, argv| name == 'oracle-container-remove' && argv.last == 'd' * 64 }
    directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
    report = JSON.parse(File.read(File.join(directory, 'result.json')))
    assert report.fetch('cleanup_verified')
  end

  def test_wrong_isolation_or_inspect_shape_never_starts
    %i[invalid_network invalid_shape].each do |setting|
      adapter, runner = lifecycle
      runner.public_send("#{setting}=", true)
      assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
      refute runner.calls.any? { |name, _argv| name.start_with?('oracle-linux-') }
      assert runner.calls.any? { |name, _argv| name == 'oracle-container-remove' }
    end
  end

  def test_nested_inspect_shapes_fail_with_typed_diagnostics
    %i[health log mount restart].each do |shape|
      adapter, runner = lifecycle
      runner.invalid_shape = shape
      assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
      refute runner.calls.any? { |name, _argv| name.start_with?('oracle-linux-') }
    end
  end

  def test_cancel_and_timeout_still_remove_the_container
    %w[cancelled timed_out].each do |state|
      adapter, runner = lifecycle
      runner.attach_state = state
      result = adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60)
      assert_equal state, result.fetch('state')
      assert result.fetch('cleanup_verified')
      assert runner.calls.any? { |name, _argv| name == 'oracle-container-remove' }
    end
  end

  def test_failed_removal_is_never_a_completed_report
    adapter, runner = lifecycle
    runner.remove_failure = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    report = JSON.parse(File.read(Dir.glob(File.join(@root, 'build/oracle/linux/emu/*/result.json')).max_by { |entry| File.mtime(entry) }))
    assert_equal 'cleanup_error', report.fetch('state')
    refute report.fetch('cleanup_verified')
  end

  def test_invalid_recovered_cid_is_refused_before_inspect_or_remove
    adapter, runner = lifecycle
    runner.partial_create = true
    runner.recovered_id = 'not-a-container-id'
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    refute runner.calls.any? { |name, _argv| name == 'oracle-container-inspect' }
    refute runner.calls.any? { |name, _argv| name == 'oracle-container-remove' }
  end

  def test_partial_volume_creation_removes_only_its_owned_volume
    adapter, runner = lifecycle
    runner.partial_volume = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    assert runner.calls.any? { |name, _| name == 'oracle-volume-remove' }
    refute runner.calls.any? { |name, _| name == 'oracle-container-create' }
  end

  def test_partial_export_creation_recovers_export_role_and_cleans_volume
    adapter, runner = lifecycle
    runner.partial_export = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    removed = runner.calls.select { |name, _| name == 'oracle-container-remove' }.map { |_, argv| argv.last }
    assert_equal ['d' * 64, 'e' * 64], removed
    assert runner.calls.any? { |name, _| name == 'oracle-volume-remove' }
  end

  def test_failed_workload_cleanup_never_starts_export
    adapter, runner = lifecycle
    runner.remove_failure = true
    assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
    refute runner.calls.any? { |name, _| name == 'oracle-export-create' }
    refute runner.calls.any? { |name, _| name == 'oracle-volume-remove' }
  end

  def test_export_failure_and_volume_removal_failure_are_explicit
    %i[export_failure volume_remove_failure].each do |failure|
      adapter, runner = lifecycle
      runner.public_send("#{failure}=", true)
      assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
      result = JSON.parse(File.read(Dir.glob(File.join(@root, 'build/oracle/linux/emu/*/result.json')).max_by { |entry| File.mtime(entry) }))
      expected = failure == :export_failure ? 'artifact_error' : 'cleanup_error'
      assert_equal expected, result.fetch('state')
      assert_equal failure == :export_failure, result.fetch('cleanup_verified')
    end
  end

  def test_cleanup_failure_preserves_verified_case_evidence
    adapter, runner = lifecycle
    runner.volume_remove_failure = true
    assert_raises(Erx::Error) { adapter.run('emulator') }
    directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
    result = JSON.parse(File.read(File.join(directory, 'result.json')))
    assert_equal 'completed', result.fetch('guest').fetch('state')
    assert_equal 'complete', result.fetch('artifacts').fetch('mandatory_evidence')
    suite = JSON.parse(File.read(File.join(directory, 'suite-result.json')))
    assert_equal 'cleanup_error', suite.fetch('state')
    refute suite.fetch('complete')
    assert_equal 1, suite.fetch('counts').fetch('passed')
  end

  def test_malformed_export_inspection_publishes_typed_failure
    %w[SecurityOpt Cmd State].each do |field|
      adapter, runner = lifecycle
      runner.export_missing_field = field
      assert_raises(Erx::Error) { adapter.send(:execute, operation: 'probe', flavour: 'emu', jobs: 1, deadline: 60) }
      directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
      report = JSON.parse(File.read(File.join(directory, 'result.json')))
      assert_equal 'artifact_error', report.fetch('state')
      assert report.fetch('cleanup_verified')
    end
  end

  def test_malformed_final_workload_state_keeps_exported_evidence_and_report
    adapter, runner = lifecycle
    runner.workload_final_missing = true
    assert_raises(Erx::Error) { adapter.run('emulator') }
    directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
    report = JSON.parse(File.read(File.join(directory, 'result.json')))
    assert_equal 'setup_error', report.fetch('state')
    assert_equal 'completed', report.fetch('guest').fetch('state')
    assert report.fetch('cleanup_verified')
    suite = JSON.parse(File.read(File.join(directory, 'suite-result.json')))
    assert_equal 1, suite.fetch('counts').fetch('passed')
    refute suite.fetch('complete')
  end

  def test_truncated_guest_metadata_preserves_cancelled_case_evidence
    adapter, runner = lifecycle
    runner.attach_state = 'cancelled'
    runner.truncated_guest_result = true
    assert_raises(Erx::Error) { adapter.run('emulator') }
    directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
    result = JSON.parse(File.read(File.join(directory, 'result.json')))
    assert_equal 'cancelled', result.fetch('state')
    assert_equal 'complete', result.fetch('artifacts').fetch('mandatory_evidence')
    assert_equal 'invalid', result.fetch('guest').fetch('metadata_status')
    suite = JSON.parse(File.read(File.join(directory, 'suite-result.json')))
    assert_equal 'cancelled', suite.fetch('state')
    refute suite.fetch('complete')
    assert_equal 1, suite.fetch('counts').fetch('passed')
  end

  def test_malformed_case_reports_still_publish_incomplete_conformance
    %i[malformed_events].each do |failure|
      adapter, runner = lifecycle
      runner.public_send("#{failure}=", true)
      assert_raises(Erx::Error) { adapter.run('emulator') }
      directory = Dir.glob(File.join(@root, 'build/oracle/linux/emu/*')).max_by { |entry| File.mtime(entry) }
      suite = JSON.parse(File.read(File.join(directory, 'suite-result.json')))
      assert_equal 'incomplete', suite.fetch('state')
      refute suite.fetch('complete')
      assert suite.fetch('diagnostic').is_a?(String)
      if failure != :malformed_events
        assert_equal 1, suite.fetch('counts').fetch('passed')
      else
        assert_nil suite.fetch('counts')
      end
    end
  end

  def test_invalid_or_multiple_optional_xml_reports_keep_controller_results
    %i[malformed_xml multiple_xml].each do |failure|
      adapter, runner = lifecycle
      runner.public_send("#{failure}=", true)
      result = adapter.run('emulator')
      assert result.fetch('complete')
      assert_equal 1, result.fetch('counts').fetch('passed')
    end
  end
end
