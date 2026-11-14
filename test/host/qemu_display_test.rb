# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'socket'
require_relative '../../tools/lib/erx/qemu'
require_relative '../../tools/lib/erx/qmp'
require_relative '../../tools/lib/erx/screen_reference'

# The harness's display support: the plan's devices and QMP socket, the QMP client against
# a scripted peer, and one real QEMU, whose guest runs no driver, shown through screendump.
class QemuDisplayTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  REFERENCES = File.join(ROOT, 'test/display/reference')
  DISPLAY = Erx::QemuPlan::Display
  # The QEMU release (and so machine type, virt-11.1) whose own picture of an inactive display
  # the reference holds.
  REFERENCE_QEMU = '11.1'
  PPM = "P6\n1 1\n255\n\x10\x20\x30".b.freeze

  def setup
    @directory = Dir.mktmpdir('erx-display-')
    @socket = File.join(@directory, 'q.sock')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def plan(**options)
    Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', **options)
  end

  def pairs(argv) = argv.each_cons(2).to_a

  # The display is three virtio devices on the page below the network device's, and QMP;
  # QEMU still opens no window and has no monitor.
  def test_a_display_adds_three_devices_on_their_own_transports_and_qmp
    argv = plan(display: DISPLAY.new(qmp_socket: @socket))
    devices = pairs(argv).select { |flag, _| flag == '-device' }.map(&:last)
    assert_equal %w[virtio-gpu-device,bus=virtio-mmio-bus.15 virtio-keyboard-device,bus=virtio-mmio-bus.14
                    virtio-tablet-device,bus=virtio-mmio-bus.13], devices
    assert_includes pairs(argv), ['-qmp', "unix:#{@socket},server=on,wait=off"]
    assert_includes pairs(argv), ['-display', 'none']
    assert_includes pairs(argv), ['-monitor', 'none']
    assert_equal 1, argv.count('-global')
    assert_equal plan, argv - ['-global', 'virtio-mmio.force-legacy=false', '-qmp', "unix:#{@socket},server=on,wait=off",
                               *devices.flat_map { |device| ['-device', device] }]
  end

  def test_display_disks_and_network_device_keep_pages_of_their_own
    disks = [Erx::QemuPlan::Disk.new(path: '/a'), Erx::QemuPlan::Disk.new(path: '/b')]
    nic = Erx::QemuPlan::Nic.new(frames_port: 5001, peer_port: 5002, echo_port: 5003)
    argv = plan(display: DISPLAY.new(qmp_socket: @socket), disks: disks, nic: nic)
    buses = argv.grep(/bus=virtio-mmio-bus\.(\d+)/) { Regexp.last_match(1).to_i }
    assert_equal [31, 30, 23, 15, 14, 13], buses
    assert_equal [[3, 3], [2], [1, 1, 1]], buses.map { |bus| bus / 8 }.chunk_while { |a, b| a == b }.to_a
  end

  def test_a_transport_on_a_page_the_disks_or_the_network_device_hold_is_refused
    disk = Erx::QemuPlan::Disk.new(path: '/a')
    nic = Erx::QemuPlan::Nic.new(frames_port: 5001, peer_port: 5002, echo_port: 5003)
    error = assert_raises(Erx::Error) { plan(display: DISPLAY.new(qmp_socket: @socket, gpu: 24), disks: [disk]) }
    assert_includes error.message, '0x0a003000 (disks, display)'
    assert_raises(Erx::Error) { plan(display: DISPLAY.new(qmp_socket: @socket, tablet: 22), nic: nic) }
    assert_raises(Erx::Error) { plan(display: DISPLAY.new(qmp_socket: @socket, keyboard: 28), disks: [disk]) }
    # The same transports are fine when the disks and the network device are not there.
    plan(display: DISPLAY.new(qmp_socket: @socket, gpu: 24))
  end

  def test_a_display_that_could_change_what_qemu_opens_is_refused
    [nil, 'relative.sock', "/a\0b", '/a,b', "/#{'x' * 110}", 5].each do |path|
      assert_raises(Erx::Error, path.inspect) { DISPLAY.new(qmp_socket: path) }
    end
    [{ gpu: 15, keyboard: 15 }, { gpu: -1 }, { tablet: 32 }, { gpu: '15' }].each do |buses|
      assert_raises(Erx::Error, buses.inspect) { DISPLAY.new(qmp_socket: @socket, **buses) }
    end
    assert_raises(Erx::Error) { plan(display: '/a.sock') }
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b')
    # A loaded board takes a display as QMP alone; one with a virtio transport is refused.
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(platform: pi, accel: 'tcg', image: '/b/i', stub: '/b/s', dtb: '/b/d', serial: 'serial',
                         hostlink: Erx::QemuPlan::NO_HOSTLINK, display: DISPLAY.new(qmp_socket: @socket, gpu: 24))
    end
  end

  # The scripted peers below listen on a UNIX socket in the test's own directory (mode 0700).
  # greet is QEMU's greeting and its answer to the capabilities command.
  def greet(connection)
    connection.write(%({"QMP": {"version": {}, "capabilities": ["oob"]}}\n))
    command = JSON.parse(connection.gets)
    connection.write(%({"return": {}, "id": #{command['id']}}\n))
  end

  def test_screendump_returns_the_decoded_picture_through_events_and_removes_the_file
    server = UNIXServer.new(@socket)
    dump = File.join(@directory, 'screen.ppm')
    thread = Thread.new do
      connection = server.accept
      greet(connection)
      request = JSON.parse(connection.gets)
      assert_equal 'screendump', request['execute']
      assert_equal({ 'filename' => dump, 'format' => 'ppm' }, request['arguments'])
      File.binwrite(dump, PPM)
      connection.write(%({"event": "STOP"}\n{"return": {}, "id": #{request['id']}}\n))
      request = JSON.parse(connection.gets)
      connection.write(%({"event": "SHUTDOWN"}\n{"return": {}, "id": #{request['id']}}\n))
      connection.close
    end
    client = Erx::Qmp.connect(@socket, timeout: 2)
    assert_equal "\x10\x20\x30".b, client.screendump_image(dump).row(0)
    refute File.exist?(dump)
    client.quit
    thread.join(5)
  ensure
    server&.close
  end

  # Each way QEMU's side can misbehave is a typed error, never a hang or a crash.
  def test_a_peer_that_misbehaves_raises_a_typed_error
    {
      'not json' => ["garbage\n", Erx::Qmp::ProtocolError],
      'not an object' => ["[1]\n", Erx::Qmp::ProtocolError],
      'no greeting' => [%({"return": {}}\n), Erx::Qmp::ProtocolError],
      'overlong line' => ["#{'x' * 70_000}\n", Erx::Qmp::ProtocolError],
      'overlong line without a newline' => ['x' * 70_000, Erx::Qmp::ProtocolError],
      'deep nesting' => ["#{'[' * 100}#{']' * 100}\n", Erx::Qmp::ProtocolError],
      'closed at once' => ['', Erx::Qmp::ProtocolError]
    }.each do |name, (bytes, error)|
      File.unlink(@socket) if File.exist?(@socket)
      server = UNIXServer.new(@socket)
      thread = Thread.new do
        connection = server.accept
        connection.write(bytes)
        sleep 0.2
        connection.close
      rescue SystemCallError
        nil
      end
      assert_raises(error, name) { Erx::Qmp.connect(@socket, timeout: 2) }
      thread.join(5)
      server.close
    end
  end

  def test_an_error_reply_a_wrong_id_and_an_event_flood_are_refused
    {
      'error reply' => [%({"error": {"class": "GenericError", "desc": "no \\u001b[31mdevice"}, "id": 2}\n), /GenericError.*no .*device/],
      'wrong id' => [%({"return": {}, "id": 99}\n), /id 99/],
      'event flood' => [%({"event": "X"}\n) * 100, /events/],
      'neither' => [%({"id": 2}\n), /neither/]
    }.each do |name, (reply, pattern)|
      File.unlink(@socket) if File.exist?(@socket)
      server = UNIXServer.new(@socket)
      thread = Thread.new do
        connection = server.accept
        greet(connection)
        connection.gets
        connection.write(reply)
        sleep 0.3
        connection.close
      rescue SystemCallError
        nil
      end
      client = Erx::Qmp.connect(@socket, timeout: 2)
      error = assert_raises(Erx::Qmp::ProtocolError, name) { client.screendump_image(File.join(@directory, 'x.ppm')) }
      assert_match pattern, error.message, name
      refute_includes error.message, "\e", 'QEMU text reaches a message escaped'
      client.close
      thread.join(5)
      server.close
    end
  end

  # QMP gives whoever connects the developer's power over the machine, so a plan whose socket
  # directory others can enter never reaches QEMU; and a dump goes only where the connection's
  # own directory is, and a refused path deletes nothing.
  def test_the_plan_and_the_dump_path_keep_to_the_owner_only_directory
    open_directory = File.join(@directory, 'open')
    Dir.mkdir(open_directory, 0o755)
    FileUtils.chmod(0o755, open_directory)
    assert_raises(Erx::Qmp::Untrusted) { plan(display: DISPLAY.new(qmp_socket: File.join(open_directory, 'q.sock'))) }
    assert_raises(Erx::Qmp::Untrusted) { plan(display: DISPLAY.new(qmp_socket: File.join(@directory, 'absent', 'q.sock'))) }
    server = UNIXServer.new(@socket)
    thread = Thread.new do
      connection = server.accept
      greet(connection)
      sleep 0.2
    end
    client = Erx::Qmp.connect(@socket, timeout: 2)
    victim = File.join(open_directory, 'victim.ppm')
    File.write(victim, 'mine')
    [victim, 'relative.ppm', "#{@directory}/x\0y"].each do |path|
      assert_raises(Erx::Qmp::ProtocolError, path) { client.screendump_image(path) }
    end
    assert_equal 'mine', File.read(victim)
    refute_respond_to client, :screendump
    client.close
    thread.join(5)
    server.close
  end

  def test_a_silent_peer_times_out
    server = UNIXServer.new(@socket)
    thread = Thread.new do
      connection = server.accept
      sleep 1
      connection.close
    rescue SystemCallError
      nil
    end
    assert_raises(Erx::Qmp::Timeout) { Erx::Qmp.connect(@socket, timeout: 0.3) }
    thread.join(5)
    server.close
  end

  def test_a_socket_that_never_appears_times_out
    assert_raises(Erx::Qmp::Timeout) { Erx::Qmp.connect(@socket, timeout: 0.2) }
  end

  def test_a_directory_others_can_read_or_a_file_that_is_no_socket_is_untrusted
    open_directory = File.join(@directory, 'open')
    Dir.mkdir(open_directory, 0o755)
    FileUtils.chmod(0o755, open_directory)
    assert_raises(Erx::Qmp::Untrusted) { Erx::Qmp.connect(File.join(open_directory, 'q.sock'), timeout: 0.2) }
    File.write(@socket, 'not a socket')
    assert_raises(Erx::Qmp::Untrusted) { Erx::Qmp.connect(@socket, timeout: 0.2) }
    ['relative', "/a\0b", nil].each { |path| assert_raises(Erx::Qmp::Untrusted) { Erx::Qmp.connect(path) } }
  end

  def test_a_link_at_the_dump_path_is_replaced_and_never_read_through
    File.symlink('/etc/hosts', File.join(@directory, 'link.ppm'))
    server = UNIXServer.new(@socket)
    thread = Thread.new do
      connection = server.accept
      greet(connection)
      request = JSON.parse(connection.gets)
      connection.write(%({"return": {}, "id": #{request['id']}}\n))
      sleep 0.2
    rescue SystemCallError
      nil
    end
    client = Erx::Qmp.connect(@socket, timeout: 2)
    assert_raises(Erx::Ppm::FormatError) { client.screendump_image(File.join(@directory, 'link.ppm')) }
    refute File.symlink?(File.join(@directory, 'link.ppm'))
    client.close
    thread.join(5)
    server.close
  end

  # One real QEMU: a guest that runs no driver (one instruction, a branch to itself) with the
  # display's devices on. QEMU's graphics console then shows its own picture of an inactive
  # display, which screendump captures under -display none; it is the checked-in reference,
  # and two boots give the same pixels.
  def test_a_guest_with_no_gpu_driver_shows_the_same_picture_each_boot
    version = IO.popen(['qemu-system-aarch64', '--version'], err: File::NULL, &:read).to_s
    skip 'qemu-system-aarch64 is not installed' if version.empty?
    skip "the reference was recorded with QEMU #{REFERENCE_QEMU}, this is #{version.lines.first.strip}" unless version.include?("version #{REFERENCE_QEMU}.")

    accel = qemu_accelerators.include?('hvf') ? 'hvf' : 'tcg'
    images = Array.new(2) { |boot| boot_and_capture(accel, boot) }
    assert_equal images.first.digest, images.last.digest
    assert_nil Erx::ScreenReference.check(images.first, directory: REFERENCES, name: 'no-gpu-driver')
  end

  def qemu_accelerators
    Erx::QemuPlan.accelerators(IO.popen(['qemu-system-aarch64', '-accel', 'help'], err: File::NULL, &:read))
  end

  def boot_and_capture(accel, boot)
    spin = File.join(@directory, 'spin.bin')
    File.binwrite(spin, "\x00\x00\x00\x14".b)
    socket = File.join(@directory, "qmp#{boot}.sock")
    argv = Erx::QemuPlan.argv(platform: PLATFORM, accel: accel, image: spin, serial: File.join(@directory, "serial#{boot}.log"),
                              hostlink: Erx::QemuPlan::NO_HOSTLINK, display: DISPLAY.new(qmp_socket: socket))
    log = File.join(@directory, "qemu#{boot}.log")
    pid = Process.spawn(*argv, in: File::NULL, out: log, err: log, pgroup: true)
    client = Erx::Qmp.connect(socket, timeout: 30)
    image = client.screendump_image(File.join(@directory, "screen#{boot}.ppm"))
    client.quit
    wait_for_exit(pid)
    image
  ensure
    client&.close
    stop(pid)
  end

  # QEMU ends after quit: waited for at most 20 seconds, never for ever.
  def wait_for_exit(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.05 until Process.wait(pid, Process::WNOHANG) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # QEMU has quit by now; a hung one is killed, and never waited on.
  def stop(pid)
    return unless pid
    return if Process.wait(pid, Process::WNOHANG)

    Process.kill('TERM', -pid)
    sleep 1
    Process.kill('KILL', -pid) unless Process.wait(pid, Process::WNOHANG)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
