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
  PLATFORM = Erx::Platform.development(ROOT)
  HOST = Remote::Host.new(destination: 'dev@host.example.net', work_dir: 'erxos-qemu')

  # A clock that only pretends: sleeping moves it on at once.
  class FakeClock
    attr_reader :now

    def initialize = (@now = 0.0)

    def sleep(seconds) = (@now += seconds)
  end

  # Records each command and plays the remote side. Setup steps succeed. The
  # remote guest writes boot_serial's lines at the remote seconds line_seconds
  # gives, and then nothing more, and with exit_at QEMU exits 0 at that
  # second. Each poll, lost or not, moves the remote clock on to the next
  # line's time, or two seconds once all are written; one that reaches the
  # host answers with the state and the size samples and serial bytes asked
  # for, the sampler taking one sample each second. When boot_serial is nil,
  # QEMU has exited with status 1. lost maps a step to the tries of it
  # (counted from 1) that lose their connection, as ssh's exit status 255
  # reports it: a count of first tries, or a range.
  class FakeRunner
    EPOCH = 1_000_000

    attr_reader :calls

    def initialize(directory, boot_serial:, lost: {}, line_seconds: nil, exit_at: nil)
      @directory = directory
      @lines = boot_serial&.lines
      @line_seconds = line_seconds || (1..@lines.to_a.size).to_a
      @exit_at = exit_at
      @lost = lost.transform_values { |tries| tries.is_a?(Range) ? tries : 1..tries }
      @tries = Hash.new(0)
      @now = 0
      @calls = []
    end

    def run(argv, name:, deadline:, success: nil, stdin: nil, stdout: nil)
      @calls << { argv: argv, name: name, deadline: deadline, stdin: stdin, stdout: stdout }
      log = File.join(@directory, "#{name}-#{@calls.size}.log")
      File.write(log, output(name, stdin))
      tick if name == 'qemu-remote-poll'
      if @lost.fetch(name, 0..0).cover?(@tries[name] += 1)
        raise Erx::CommandError, { 'state' => 'failed', 'log' => log, 'exit_status' => Erx::QemuRemote::SSH_LOST }
      end
      File.binwrite(stdout, poll(Shellwords.split(argv.last))) if name == 'qemu-remote-poll'
      { 'log' => log, 'state' => 'succeeded' }
    end

    private

    # The digest steps print the SHA-256 of what was uploaded, which the fake keeps.
    def output(name, stdin)
      case name
      when 'qemu-version' then "QEMU emulator version 11.1.2\n"
      when 'qemu-remote-upload' then (@uploaded = File.binread(stdin)) && ''
      when 'qemu-remote-upload-digest' then "#{Digest::SHA256.hexdigest(@uploaded)}  file\n"
      when 'qemu-remote-digest' then "#{'ab' * 32}  qemu\n"
      else ''
      end
    end

    def tick
      @now = @line_seconds.find { |second| second > @now } || @now + 2
      @now = [@now, @exit_at].min if @exit_at
    end

    # The serial log as it stood at the given remote second.
    def written_by(second) = @lines.first(@line_seconds.count { |at| at <= second }).join

    # The poll's `tail` operand after option, which counts from 1.
    def from(words, option) = Integer(words.fetch(words.index(option) + 1)) - 1

    def poll(words)
      return "1\n--\n" unless @lines

      state = @now == @exit_at ? '0' : 'running'
      samples = (0..@now).map { |second| "#{EPOCH + second}    #{written_by(second).bytesize}\n" }
      "#{state}\n#{samples.drop(from(words, '-n')).join}--\n#{written_by(@now).byteslice(from(words, '-c')..)}"
    end
  end

  def boot_serial
    "erx: bootstrap: memory #{128 << 20} bytes\n/_/\\_\\ \\___/ |___/\nerXos\ndevelopment build: trusted code only\n" \
      "kernel trace rings: on; expect slower IPC and switches (erx.trace=0 turns them off)\n"
  end

  def remote_run(boot_serial:, lost: {}, line_seconds: nil, exit_at: nil, machine_end: false,
                 points: [{ name: 'banner', pattern: /erXos\r?\n/n, seconds: 30 }])
    Dir.mktmpdir('erx-qemu-remote-', File.join(ROOT, 'build')) do |directory|
      image = File.join(directory, 'image.elf')
      File.binwrite(image, 'kernel')
      runner = FakeRunner.new(directory, boot_serial: boot_serial, lost: lost, line_seconds: line_seconds, exit_at: exit_at)
      qemu = Erx::Qemu.new(root: ROOT, runner: runner, remote_clock: FakeClock.new)
      begin
        report = qemu.run(platform: PLATFORM, accel: 'tcg', cpus: 4, image: image, memory_mib: 128, checkpoints: points,
                          directory: File.join(directory, 'run'), remote: HOST, machine_end: machine_end)
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
    argv = boot.start_argv(qemu, seconds: 90)

    run = 'erxos-qemu/0123456789abcdef'
    assert_equal ['ssh', *Remote::SSH_OPTIONS, '--', HOST.destination], argv[0...-1]
    assert_equal ['nohup', 'sh', "#{run}/start.sh", *%w[started status sizes keyboard typed serial.log qemu.log].map { |file| "#{run}/#{file}" },
                  HOST.timeout, '10', '90', *qemu, '>', '/dev/null', '2>&1', '<', '/dev/null', '&'], remote_words(argv)
    assert_equal ['dd', "of=#{run}/image", 'bs=1048576', 'seek=4', 'conv=notrunc', '2>/dev/null'],
                 remote_words(boot.write_at_argv(boot.path('image'), 4 << 20))
    assert_equal({ 'bs' => '4', 'seek' => '3' }, dd_operands(boot.type_argv(12)))
    assert_equal({ 'bs' => '1', 'seek' => '7' }, dd_operands(boot.type_argv(7)))
    kill = ['pkill', '-KILL', '-f', '--', '0123456789abcdef', '2>/dev/null;']
    assert_equal [*kill, 'rm', '-rf', '--', run, '||', '{', 'sleep', '1;', *kill, 'rm', '-rf', '--', run, ';', '}'],
                 remote_words(boot.cleanup_argv)
  end

  # A dd command's block size and seek, by name.
  def dd_operands(argv) = remote_words(argv).filter_map { |word| word.split('=', 2) if word.start_with?('bs=', 'seek=') }.to_h

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
    # A cell named with its case after it (boot_image's) moves as the cell does.
    assert_equal %w[hvf-1cpu-single tcg-4cpu-single hvf-1cpu-two-file damage-cases],
                 %w[hvf-1cpu-single hvf-4cpu-single hvf-1cpu-two-file damage-cases].map { |name| Cells.placed_name(name, HOST) }
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
      assert_equal %w[qemu-remote-prepare qemu-remote-upload qemu-remote-upload-digest qemu-remote-upload qemu-remote-upload-digest
                      qemu-version qemu-remote-start qemu-remote-poll qemu-remote-poll qemu-remote-poll qemu-remote-cleanup],
                   calls.map { |call| call[:name] }
      start = remote_words(calls.find { |call| call[:name] == 'qemu-remote-start' }[:argv])
      assert(start.any? { |word| word.match?(%r{\Afile,id=serial0,path=erxos-qemu/\h{16}/serial\.log,input-path=erxos-qemu/\h{16}/keyboard\z}) })
      assert_equal boot_serial.lines.first(3).join, File.binread(File.join(directory, 'serial.log'))
    end
  end

  def test_a_failed_remote_boot_is_cleaned_up_and_never_passes
    remote_run(boot_serial: nil) do |calls, report, error, directory|
      assert_nil report
      assert_kind_of Erx::CommandError, error
      assert_equal %w[qemu-remote-log qemu-remote-cleanup], calls.last(2).map { |call| call[:name] }
      assert_equal 'failed', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
    end
  end

  # The connection drops for a while: a step and a poll that lose it run again,
  # and the boot passes as if nothing happened.
  def test_a_lost_connection_retries_the_step_and_the_poll
    remote_run(boot_serial: boot_serial, lost: { 'qemu-remote-upload' => 2, 'qemu-remote-poll' => 3 }) do |calls, report, error, directory|
      assert_nil error
      assert_equal 'passed', report.fetch('state')
      assert_equal 4, calls.count { |call| call[:name] == 'qemu-remote-upload' }
      assert_equal 4, calls.count { |call| call[:name] == 'qemu-remote-poll' }
      assert_equal boot_serial.lines.first(3).join, File.binread(File.join(directory, 'serial.log'))
    end
  end

  # Checkpoints 5 s apart, each line written a second after the last: a lost
  # connection that holds the lines back here for over a minute does not fail
  # the boot, because each byte is judged by when the remote host wrote it.
  def test_a_long_outage_between_checkpoints_judges_by_the_remote_clock
    points = [{ name: 'memory', pattern: /bootstrap: memory/n, seconds: 5 },
              { name: 'banner', pattern: /erXos\r?\n/n, seconds: 5 }]
    remote_run(boot_serial: boot_serial, points: points, lost: { 'qemu-remote-poll' => 2..40 }) do |calls, report, error, _directory|
      assert_nil error
      assert_equal 'passed', report.fetch('state')
      assert_equal 41, calls.count { |call| call[:name] == 'qemu-remote-poll' }
    end
  end

  # The same checkpoints, but the banner written 25 s after the memory line on
  # the remote host's clock: the boot times out, however promptly polls run.
  def test_a_late_line_on_the_remote_clock_times_out
    points = [{ name: 'memory', pattern: /bootstrap: memory/n, seconds: 5 },
              { name: 'banner', pattern: /erXos\r?\n/n, seconds: 5 }]
    remote_run(boot_serial: boot_serial, points: points, line_seconds: [1, 2, 26, 27]) do |_calls, report, error, directory|
      assert_nil report
      assert_kind_of Erx::TranscriptTimeout, error
      assert_equal 'timed_out', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
    end
  end

  # A guest that must end the machine and never does times out at the deadline
  # on the remote host's clock, though the start script never reports an end.
  def test_a_boot_that_never_ends_times_out_at_its_deadline
    remote_run(boot_serial: boot_serial, machine_end: true) do |_calls, report, error, directory|
      assert_nil report
      assert_kind_of Erx::CommandError, error
      assert_equal 'timed_out', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
    end
  end

  # A guest that ends the machine past its deadline, while the connection is
  # down, still times out: the last sample dates its exit on the remote clock.
  def test_a_boot_that_ends_late_during_an_outage_times_out
    remote_run(boot_serial: boot_serial, machine_end: true, exit_at: 50, lost: { 'qemu-remote-poll' => 5..40 }) do |calls, report, error, directory|
      assert_nil report
      assert_kind_of Erx::CommandError, error
      assert_equal 'timed_out', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
      assert_equal 41, calls.count { |call| call[:name] == 'qemu-remote-poll' }
    end
  end

  # What the transcript types reaches the remote typed file at its own offset.
  def test_typing_writes_each_piece_at_its_offset
    points = [{ name: 'banner', pattern: /erXos\r?\n/n, seconds: 30, type: 'ab' },
              { name: 'build', pattern: /development build/n, seconds: 30, type: 'c' }]
    remote_run(boot_serial: boot_serial, points: points, lost: { 'qemu-remote-type' => 1 }) do |calls, report, error, _directory|
      assert_nil error
      assert_equal 'passed', report.fetch('state')
      typed = calls.select { |call| call[:name] == 'qemu-remote-type' }.map { |call| dd_operands(call[:argv]) }
      assert_equal [{ 'bs' => '1048576', 'seek' => '0' }, { 'bs' => '1048576', 'seek' => '0' }, { 'bs' => '2', 'seek' => '1' }], typed
    end
  end

  # A host that never answers leaves the start unconfirmed after its tries, and
  # one lost after the start leaves the boot without a result once the remote
  # QEMU is surely gone: either way the cell is not run, and cleanup was tried.
  def test_a_host_that_never_answers_leaves_the_cell_not_run
    [{ 'qemu-remote-start' => Float::INFINITY }, { 'qemu-remote-poll' => Float::INFINITY }].each do |lost|
      assert_output(nil, /remote cleanup of .* lost its connection/) do
        remote_run(boot_serial: boot_serial, lost: lost.merge('qemu-remote-cleanup' => Float::INFINITY)) do |calls, report, error, directory|
          assert_nil report
          assert_kind_of Remote::Unreachable, error
          assert_equal 'not_run', JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('state')
          assert_operator calls.count { |call| call[:name] == 'qemu-remote-cleanup' }, :>=, Remote::STEP_TRIES
        end
      end
    end
  end

  # Runs each remote command line with this host's sh in place of ssh, its
  # standard input through a pipe as ssh's is, and every one twice, as a step
  # retried after a lost connection that had in fact done its work.
  class ShellRunner
    def initialize(directory) = (@directory = directory)

    def run(argv, name:, deadline:, success: nil, stdin: nil, stdout: nil)
      log = File.join(@directory, "#{name}.log")
      2.times do
        reader, writer = IO.pipe
        pid = Process.spawn('sh', '-c', argv.last, in: reader, out: stdout || log, err: log)
        reader.close
        File.open(stdin, 'rb') { |input| IO.copy_stream(input, writer) } if stdin
        writer.close
        status = Process.wait2(pid).last
        raise Erx::CommandError, { 'state' => 'failed', 'log' => log, 'exit_status' => status.exitstatus } unless status.success?
      end
      { 'log' => log, 'state' => 'succeeded' }
    end
  end

  # A stand-in QEMU: says ready on the serial line, reads a line from the
  # keyboard, echoes it and exits; each start it makes is counted.
  FAKE_QEMU = <<~SH
    #!/bin/sh
    echo start >> "$1.starts"
    echo ready >> "$1"
    read line < "$2"
    echo "got $line" >> "$1"
  SH

  # A boot of FAKE_QEMU through the real remote commands, with typing, which
  # lets it end itself, or without, which leaves it waiting for cleanup to
  # end it; yields the boot and its result.
  def shell_boot(type:)
    timeout = %w[/opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout].find { |path| File.executable?(path) }
    skip 'no GNU timeout' unless timeout
    Dir.mktmpdir('erx-qemu-remote-') do |directory|
      directory = File.realpath(directory)
      program = File.join(directory, 'fake-qemu')
      File.write(program, FAKE_QEMU, perm: 0o700)
      image = File.join(directory, 'image.elf')
      File.binwrite(image, Random.bytes(Remote::UPLOAD_PIECE_BYTES + 12_345))
      boot = Remote::Boot.new(host: Remote::Host.new(destination: 'localhost', work_dir: File.join(directory, 'work'), program: program,
                                                     timeout: timeout))
      run = Remote::Run.new(boot: boot, runner: ShellRunner.new(directory), clock: Remote::Clock, directory: directory)
      serial = File.join(directory, 'serial.log')
      File.write(serial, '')
      typed = false
      stop = lambda do |_seconds|
        ready = File.read(serial).include?("ready\n")
        next ready unless type

        if ready && !typed
          typed = true
          run.keyboard.write("hello\n")
        end
        false
      end
      run.upload({ 'image' => image })
      assert_equal File.binread(image), File.binread(boot.path('image'))
      result = run.run([program, boot.serial, boot.keyboard], deadline: 20, serial: serial, stop: stop)
      yield boot, result, File.read(serial)
      run.cleanup
      refute File.exist?(boot.directory)
      assert_empty IO.popen(['pgrep', '-f', File.basename(boot.directory)], &:read)
    end
  end

  def test_the_remote_commands_run_a_detached_boot_under_sh
    shell_boot(type: true) do |boot, result, serial|
      assert_equal 'succeeded', result.fetch('state')
      assert_equal 0, result.fetch('exit_status')
      assert_equal "ready\ngot hello\n", serial
      assert_equal "start\n", File.read("#{boot.serial}.starts")
    end
  end

  def test_cleanup_ends_a_remote_boot_that_still_runs
    shell_boot(type: false) do |_boot, result, serial|
      assert_equal 'succeeded', result.fetch('state')
      assert_equal "ready\n", serial
    end
  end

  def test_a_remote_boot_takes_only_what_qemu_inputs_determine
    error = assert_raises(Erx::Error) do
      Erx::Qemu.new(root: ROOT, runner: FakeRunner.new(ROOT, boot_serial: nil))
               .run(platform: PLATFORM, accel: 'tcg', cpus: 4, image: __FILE__, nic: Erx::QemuPlan::Nic.new(frames_port: 1, peer_port: 2, echo_port: 3),
                    remote: HOST)
    end
    assert_equal 'a remote boot takes no nic', error.message
  end
end
