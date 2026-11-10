# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'shellwords'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu'
require_relative '../../tools/lib/erx/qemu_cells'
require_relative '../../tools/lib/erx/qemu_gate'
require_relative '../../tools/lib/erx/qemu_remote'

# Cells placed on a remote host: the remote commands keep every word one word,
# a moved cell is named for the accelerator it ran under, nothing moves unless
# the gate was given a host, the suite declares offload and this host is busy,
# and a remote boot that fails or cannot start never passes and is always
# cleaned up. ssh never runs: a fake runner stands in for it.
class QemuRemoteTest < Minitest::Test
  Cells = Erx::QemuCells
  Remote = Erx::QemuRemote
  Gate = Erx::QemuGate
  ROOT = File.expand_path('../..', __dir__)
  HOST = Remote::Host.new(destination: 'dev@host.example.net', work_dir: 'erxos-qemu')

  # Records each command and plays the remote side: setup steps succeed, the
  # boot writes boot_serial to the stdout path it is given, or fails when
  # boot_serial is nil.
  class FakeRunner
    attr_reader :calls

    def initialize(directory, boot_serial:)
      @directory = directory
      @boot_serial = boot_serial
      @calls = []
    end

    def run(argv, name:, deadline:, success: nil, stdin: nil, stdout: nil)
      @calls << { argv: argv, name: name, deadline: deadline, stdin: stdin, stdout: stdout }
      log = File.join(@directory, "#{name}-#{@calls.size}.log")
      File.write(log, name == 'qemu-version' ? "QEMU emulator version 11.1.2\n" : '')
      return { 'log' => log, 'state' => 'succeeded' } unless name.end_with?('-remote')

      raise Erx::CommandError, { 'state' => 'failed', 'log' => log } unless @boot_serial

      File.binwrite(stdout, @boot_serial)
      success&.call(log)
      { 'log' => log, 'state' => 'succeeded' }
    end
  end

  def boot_serial
    "erx: bootstrap: memory #{128 << 20} bytes\n/_/\\_\\ \\___/ |___/\nerXos\ndevelopment build: trusted code only\n"
  end

  def remote_run(boot_serial:)
    Dir.mktmpdir('erx-qemu-remote-', File.join(ROOT, 'build')) do |directory|
      image = File.join(directory, 'image.elf')
      File.binwrite(image, 'kernel')
      runner = FakeRunner.new(directory, boot_serial: boot_serial)
      qemu = Erx::Qemu.new(root: ROOT, runner: runner)
      points = [{ name: 'banner', pattern: /erXos\r?\n/n, seconds: 30 }]
      begin
        report = qemu.run(accel: 'tcg', cpus: 4, image: image, memory_mib: 128, checkpoints: points,
                          directory: File.join(directory, 'run'), remote: HOST)
      rescue Erx::Error => e
        error = e
      end
      yield runner.calls, report, error, File.join(directory, 'run')
    end
  end

  # The remote command as a POSIX shell splits it.
  def remote_words(argv) = Shellwords.split(argv.last)

  def test_every_remote_word_stays_one_word
    boot = Remote::Boot.new(host: HOST, name: '0123456789abcdef')
    hostile = ['-append', 'erx.det=1 two words; rm -rf ~ $(id) `id` "q\' \\']
    qemu = [HOST.program, '-smp', '4', *hostile]
    argv = boot.boot_argv(qemu, deadline: 60)

    assert_equal ['ssh', *Remote::SSH_OPTIONS, '--', HOST.destination], argv[0...-1]
    assert_equal ['exec', HOST.timeout, '-k', '10', '90', *qemu, '-pidfile', 'erxos-qemu/0123456789abcdef/qemu.pid'],
                 remote_words(argv)
    assert_equal ['cat', '>', 'erxos-qemu/0123456789abcdef/image'], remote_words(boot.upload_argv('image'))
    assert_equal ['pkill', '-KILL', '-F', 'erxos-qemu/0123456789abcdef/qemu.pid', '--', 'qemu-system-aarch64', '2>/dev/null', ';',
                  'rm', '-rf', '--', 'erxos-qemu/0123456789abcdef'], remote_words(boot.cleanup_argv)
  end

  def test_configuration_words_are_plain
    ['-oProxyCommand=sh', 'host;id', 'a b', ''].each do |destination|
      assert_raises(Erx::Error) { Remote::Host.new(destination: destination) }
    end
    ['../up', 'dir/../up', 'dir;id', 'with space', '-rf', '.hidden'].each do |path|
      assert_raises(Erx::Error) { Remote::Host.new(destination: 'host', work_dir: path) }
      assert_raises(Erx::Error) { Remote::Host.new(destination: 'host', program: path) }
    end
    assert_raises(Erx::Error) { Remote::Boot.new(host: HOST).path('../etc') }
    ['Documents', '../0123456789abcdef', '0123456789abcdeg'].each do |name|
      assert_raises(Erx::Error) { Remote::Boot.new(host: HOST, name: name) }
    end
  end

  def test_a_moved_cell_is_named_for_its_accelerator_and_host
    local = Cells::Cell.new(accel: 'hvf', cpus: 4)
    moved = Cells.place(local, HOST)

    assert_equal ['tcg-4cpu', HOST], [moved.name, moved.remote]
    assert_equal local, Cells.place(Cells::Cell.new(accel: 'hvf', cpus: 4), nil)
    assert_equal 'hvf-1cpu', Cells.place(Cells::Cell.new(accel: 'hvf', cpus: 1), HOST).name
    assert_equal %w[hvf-1cpu tcg-4cpu smoke-tcg-1cpu],
                 %w[hvf-1cpu hvf-4cpu smoke-tcg-1cpu].map { |name| Cells.placed_name(name, HOST) }
  end

  def test_cells_move_only_for_an_offload_suite_on_a_busy_host
    placed = lambda do |remote: HOST, offload: true, load: 20.0|
      Cells.placement(cells: %w[hvf-1cpu hvf-4cpu], remote: remote, offload: offload, load: load, busy_load: 16, cores: 16)
    end

    assert_equal HOST, placed.call.remote
    assert_nil placed.call(remote: nil).remote
    assert_nil placed.call(offload: false).remote
    assert_nil placed.call(load: 15.9).remote
  end

  def test_local_cells_boot_side_by_side_only_with_idle_cores
    placed = ->(load) { Cells.placement(cells: %w[hvf-1cpu hvf-4cpu], remote: nil, offload: false, load: load, busy_load: 0, cores: 16) }

    assert placed.call(11.0).side_by_side
    refute placed.call(11.5).side_by_side
  end

  def test_with_no_remote_every_cell_runs_here_in_order
    seen = []
    ran = Cells::HERE.each(accels: ['hvf'], cpus: [1, 4]) do |accel, count, remote|
      seen << [accel, count, remote, Thread.current]
      ["#{accel}-#{count}cpu", 'ok']
    end

    assert_equal({ 'hvf-1cpu' => 'ok', 'hvf-4cpu' => 'ok' }, ran)
    assert_equal [['hvf', 1, nil, Thread.current], ['hvf', 4, nil, Thread.current]], seen
  end

  def offload_suite(&boot)
    Gate::Suite.new(name: 'offloaded', cells: %w[hvf-1cpu hvf-4cpu], offload: true, run: lambda do |context|
      Gate.result(context.placement.each(accels: ['hvf'], cpus: [1, 4]) { |accel, count, remote| ["#{accel}-#{count}cpu", boot.call(remote)] })
    end)
  end

  def gate_run(suite, load: 32.0)
    Gate.run(suites: [suite], context: Gate::Context.new(root: ROOT, jobs: 1), host_load: -> { load }, cores: 16,
             offload: Gate::Offload.new(remote: HOST, busy_load: 16)).fetch(suite.name)
  end

  def test_an_unreachable_remote_cell_is_not_run
    result = nil
    assert_output(nil, /tcg-4cpu: not run: no route/) do
      result = gate_run(offload_suite { |remote| remote ? raise(Remote::Unreachable, 'no route') : 'passed' })
    end

    assert_equal({ 'hvf-1cpu' => 'passed', 'tcg-4cpu' => 'not_run' }, result.cells)
    assert_equal 'incomplete', Gate.status(result)
  end

  def test_a_failed_remote_boot_fails_the_suite
    result = gate_run(offload_suite { |remote| remote ? raise(Erx::Error, 'checkpoint timed out') : 'passed' })

    assert_equal 'failed', Gate.status(result)
    assert_equal ['checkpoint timed out'], result.notes
  end

  def test_a_quiet_host_keeps_the_cells_here
    result = gate_run(offload_suite { |remote| remote ? 'moved' : 'passed' }, load: 2.0)

    assert_equal({ 'hvf-1cpu' => 'passed', 'hvf-4cpu' => 'passed' }, result.cells)
  end

  def test_a_remote_boot_is_judged_here_and_cleaned_up
    remote_run(boot_serial: boot_serial) do |calls, report, error, directory|
      assert_nil error
      assert_equal 'passed', report.fetch('state')
      assert_equal HOST.destination, report.fetch('remote')
      assert_equal %w[qemu-remote-prepare qemu-remote-upload qemu-version qemu-tcg-remote qemu-remote-cleanup], calls.map { |call| call[:name] }
      boot = calls.find { |call| call[:name] == 'qemu-tcg-remote' }
      assert_equal File.join(directory, 'serial.log'), boot[:stdout]
      assert_includes remote_words(boot[:argv]), 'stdio'
      assert_match(/erXos/, File.binread(boot[:stdout]))
    end
  end

  def test_a_failed_remote_boot_is_cleaned_up_and_never_passes
    remote_run(boot_serial: nil) do |calls, report, error, directory|
      assert_nil report
      assert_kind_of Erx::CommandError, error
      assert_equal 'qemu-remote-cleanup', calls.last[:name]
      assert_equal 'failed', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
    end
  end

  def test_a_remote_boot_takes_only_what_qemu_inputs_determine
    error = assert_raises(Erx::Error) do
      Erx::Qemu.new(root: ROOT, runner: FakeRunner.new(ROOT, boot_serial: nil))
               .run(accel: 'tcg', cpus: 4, image: __FILE__, nic: Erx::QemuPlan::Nic.new(frames_port: 1, peer_port: 2, echo_port: 3),
                    remote: HOST)
    end
    assert_match(/remote boot takes no disk/, error.message)
  end
end
