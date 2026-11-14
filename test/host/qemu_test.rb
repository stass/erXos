# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu'

class InterruptingQemuRunner
  def run(*_arguments, **_options)
    raise Interrupt, 'fixture interruption'
  end
end

class QemuTest < Minitest::Test
  PLATFORM = Erx::Platform.development(File.expand_path('../..', __dir__))

  def setup
    @directory = Dir.mktmpdir('erx-qemu-')
    @serial = File.join(@directory, 'serial.log')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def checkpoints
    [{ name: 'first', pattern: /^first\r?\n/n, seconds: 2 },
     { name: 'second', pattern: /^second\r?\n/n, seconds: 3 }]
  end

  def test_machine_and_accelerator_contract
    tcg = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial')
    hvf = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial')
    assert_includes tcg, 'virt-11.1,gic-version=3,msi=gicv2m'
    assert_includes hvf, 'virt-11.1,gic-version=3'
    assert_includes hvf, 'host'
    assert_includes tcg, '-no-reboot'
    assert_equal 'none', tcg.fetch(tcg.index('-nic') + 1)
    assert_equal 'none', tcg.fetch(tcg.index('-monitor') + 1)
  end

  # The Raspberry Pi 4's model boots as its firmware would (docs/design-platforms.md,
  # "Bring-up under QEMU"): under TCG, the stub, image and tree through QEMU's loader with
  # CPU 0 starting in the stub, the GIC with its security extensions, the console on the
  # second serial port, and no -kernel, -m, -cpu or host link. What it cannot take raises.
  def test_the_raspberry_pi_4_boots_through_the_loader
    pi = Erx::Platform.load(root: File.expand_path('../..', __dir__), name: 'raspi4b')
    plan = { platform: pi, accel: 'tcg', image: '/b/image.boot', stub: '/b/bl31.bin', dtb: '/b/model.dtb', serial: 'serial',
             cpus: 4, hostlink: Erx::QemuPlan::NO_HOSTLINK }
    argv = Erx::QemuPlan.argv(**plan)
    assert_equal ['-machine', 'raspi4b'], argv[1, 2]
    assert_equal %w[null file:serial], argv.each_cons(2).select { |flag, _| flag == '-serial' }.map(&:last)
    assert_equal ['loader,file=/b/bl31.bin,addr=0x0,cpu-num=0', 'loader,file=/b/image.boot,addr=0x200000',
                  'loader,file=/b/model.dtb,addr=0x8000000'],
                 argv.each_cons(2).select { |flag, _| flag == '-device' }.map(&:last)
    assert_includes argv.each_cons(2).to_a, ['-global', 'arm_gic.has-security-extensions=on']
    assert_includes argv, '-no-reboot'
    assert_empty argv & %w[-kernel -m -cpu -append -dtb]
    [{ accel: 'hvf' }, { hostlink: nil }, { command_line: 'erx.det=1' }, { initrd: '/b/initrd' }, { image: '/b/a,b' }].each do |change|
      assert_raises(Erx::Error, change.inspect) { Erx::QemuPlan.argv(**plan, **change) }
    end
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', stub: '/b/bl31.bin') }
  end

  # The raspi4b suite's stand-in for the firmware (Raspi4bFirmwareFb) is where CPU 0 starts, an
  # ELF at its own addresses, and the stub then carries no cpu-num; a display is QMP alone,
  # the board's own framebuffer being the screen. A board without loads takes no firmware.
  def test_the_raspberry_pi_4_runs_a_firmware_stand_in_first
    pi = Erx::Platform.load(root: File.expand_path('../..', __dir__), name: 'raspi4b')
    Dir.mktmpdir do |directory|
      socket = File.join(directory, 'qmp.sock')
      argv = Erx::QemuPlan.argv(platform: pi, accel: 'tcg', image: '/b/image.boot', stub: '/b/bl31.bin', dtb: '/b/fb.dtb',
                                serial: 'serial', cpus: 4, hostlink: Erx::QemuPlan::NO_HOSTLINK, firmware: '/b/fb.elf',
                                display: Erx::QemuPlan::Display.new(qmp_socket: socket))
      assert_equal ['loader,file=/b/fb.elf,cpu-num=0', 'loader,file=/b/bl31.bin,addr=0x0', 'loader,file=/b/image.boot,addr=0x200000',
                    'loader,file=/b/fb.dtb,addr=0x8000000'],
                   argv.each_cons(2).select { |flag, _| flag == '-device' }.map(&:last)
      assert_equal ["unix:#{socket},server=on,wait=off"], argv.each_cons(2).select { |flag, _| flag == '-qmp' }.map(&:last)
    end
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', firmware: '/b/fb.elf') }
  end

  # The Raspberry Pi 4 takes its one disk as the card on EMMC2's SD bus, never as sd0,
  # the model's own card; a second disk raises, as a disk on a board with no SD bus would.
  def test_the_raspberry_pi_4_takes_its_disk_as_its_sd_card
    pi = Erx::Platform.load(root: File.expand_path('../..', __dir__), name: 'raspi4b')
    plan = { platform: pi, accel: 'tcg', image: '/b/image.boot', stub: '/b/bl31.bin', dtb: '/b/model.dtb', serial: 'serial',
             hostlink: Erx::QemuPlan::NO_HOSTLINK }
    card = Erx::QemuPlan::Disk.new(path: '/b/sdcard.img')
    argv = Erx::QemuPlan.argv(**plan, disks: [card])
    assert_includes argv.each_cons(2).to_a, ['-drive', 'if=none,id=card0,file=/b/sdcard.img,format=raw']
    assert_includes argv.each_cons(2).to_a, ['-device', 'sd-card,drive=card0,bus=/generic-sdhci/sd-bus']
    refute_includes argv.join(' '), 'virtio'
    error = assert_raises(Erx::Error) { Erx::QemuPlan.argv(**plan, disks: [card, card]) }
    assert_equal 'raspi4b takes one disk, its SD card', error.message
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(**plan, disks: ['/b/sdcard.img']) }
  end

  def test_the_deterministic_word_counts_instructions_on_one_tcg_cpu
    plan = { accel: 'tcg', image: 'image', serial: 'serial' }
    argv = Erx::QemuPlan.argv(platform: PLATFORM, **plan, command_line: 'erx.det=1 erx.arg=-deterministic')
    assert_equal %w[-smp 1 -icount shift=0,sleep=off -rtc base=2026-01-01,clock=vm], argv[argv.index('-smp'), 6]
    assert_includes argv.fetch(argv.index('-machine') + 1).split(','), 'dtb-randomness=off'
    # Not a word of its own, by the guest's reading: a word's value, and a tab inside a word.
    ['erx.watchdog=1,30,600 erx.arg=erx.det=1', "erx.arg=a\terx.det=1"].each do |line|
      plain = Erx::QemuPlan.argv(platform: PLATFORM, **plan, accel: 'hvf', command_line: line)
      refute_includes plain, '-icount'
      refute_includes plain.fetch(plain.index('-machine') + 1), 'dtb-randomness'
    end
  end

  def test_the_deterministic_word_refuses_hvf_and_more_cpus
    plan = { image: 'image', serial: 'serial', command_line: 'erx.det=1' }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, **plan, accel: 'hvf') }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, **plan, accel: 'tcg', cpus: 4) }
  end

  def test_a_serial_input_reads_a_path_and_still_logs_to_the_file
    plain = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial')
    typed = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', serial_input: 'keys')
    assert_equal 'file:serial', plain.fetch(plain.index('-serial') + 1)
    assert_equal 'chardev:serial0', typed.fetch(typed.index('-serial') + 1)
    assert_equal 'file,id=serial0,path=serial,input-path=keys', typed.fetch(typed.index('-chardev') + 1)
  end

  # The host link's UART (docs/design-live.md, "The host link") is the second serial line on
  # every plan: QEMU's null device, or a UNIX socket QEMU listens on without waiting for a client.
  def test_the_second_serial_line_is_the_host_links
    serials = lambda do |argv|
      argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    end
    assert_equal %w[file:serial null], serials.call(Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial'))
    linked = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', hostlink: '/run/x/hostlink.sock')
    assert_equal ['file:serial', 'unix:/run/x/hostlink.sock,server=on,wait=off'], serials.call(linked)
    ['relative.sock', '/a,b.sock', "/a\0b", "/#{'a' * Erx::QemuPlan::SOCKET_PATH_MAX}"].each do |path|
      assert_raises(Erx::Error, path) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', hostlink: path) }
    end
  end

  # The host link is the boot's to ask for (docs/design-stopgap.md, "The command line"): a plan
  # with the host link's serial line puts erx.hostlink=1 first on the kernel command line, and one
  # of NO_HOSTLINK has one serial line and no word, as the website's machine has.
  def test_the_hostlink_word_comes_with_the_hostlink_serial_line
    plan = { accel: 'tcg', image: 'image', serial: 'serial' }
    append = ->(argv) { argv.include?('-append') ? argv.fetch(argv.index('-append') + 1) : nil }
    assert_equal 'erx.hostlink=1', append.call(Erx::QemuPlan.argv(platform: PLATFORM, **plan))
    assert_equal 'erx.hostlink=1', append.call(Erx::QemuPlan.argv(platform: PLATFORM, **plan, command_line: ''))
    assert_equal 'erx.hostlink=1 erx.det=1', append.call(Erx::QemuPlan.argv(platform: PLATFORM, **plan, command_line: 'erx.det=1'))
    assert_equal 'erx.hostlink=1', append.call(Erx::QemuPlan.argv(platform: PLATFORM, **plan, hostlink: '/run/x/hostlink.sock'))
    none = Erx::QemuPlan.argv(platform: PLATFORM, **plan, hostlink: Erx::QemuPlan::NO_HOSTLINK)
    assert_equal ['file:serial'], none.each_index.select { |at| none[at] == '-serial' }.map { |at| none[at + 1] }
    assert_nil append.call(none)
    assert_equal 'erx.det=1', append.call(Erx::QemuPlan.argv(platform: PLATFORM, **plan, hostlink: Erx::QemuPlan::NO_HOSTLINK, command_line: 'erx.det=1'))
    [nil, Erx::QemuPlan::NO_HOSTLINK].each do |hostlink|
      assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, **plan, hostlink: hostlink, command_line: 'erx.det=1 erx.hostlink=1') }
    end
  end

  def test_a_console_serial_line_is_this_terminal_with_the_monitor_muxed
    console = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: Erx::QemuPlan::CONSOLE)
    assert_equal 'mon:stdio', console.fetch(console.index('-serial') + 1)
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: Erx::QemuPlan::CONSOLE, serial_input: 'keys')
    end
  end

  def test_cpu_counts_outside_the_plan_range_are_refused
    [0, 9, '2', nil].each do |cpus|
      assert_raises(Erx::Error, cpus.inspect) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', cpus: cpus) }
    end
    assert_includes Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', cpus: 8), '8'
  end

  def test_a_comma_in_a_serial_input_path_is_refused
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', serial_input: 'a,b') }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'a,b', serial_input: 'keys') }
  end

  DISK = Erx::QemuPlan::Disk

  def test_a_plan_without_disks_renders_the_arguments_it_always_did
    plain = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial')
    assert_equal plain, Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', disks: [])
    assert_equal %w[qemu-system-aarch64 -machine virt-11.1,gic-version=3 -accel hvf -cpu host -smp 1 -m] + [PLATFORM.memory_mib.to_s] +
                 %w[-display none -monitor none -nic none -no-reboot -serial file:serial -serial null -kernel image
                    -append erx.hostlink=1], plain
  end

  def test_a_disk_is_a_raw_drive_with_a_virtio_blk_device_on_a_non_legacy_transport
    argv = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', disks: [DISK.new(path: '/run/a.img')])
    plain = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial')
    assert_equal plain, argv - ['-global', 'virtio-mmio.force-legacy=false', '-drive', 'file=/run/a.img,format=raw,if=none,id=disk0',
                                '-device', 'virtio-blk-device,drive=disk0,bus=virtio-mmio-bus.31']
    assert_includes argv.each_cons(2).to_a, ['-global', 'virtio-mmio.force-legacy=false']
    assert_includes argv.each_cons(2).to_a, ['-drive', 'file=/run/a.img,format=raw,if=none,id=disk0']
    assert_includes argv.each_cons(2).to_a, ['-device', 'virtio-blk-device,drive=disk0,bus=virtio-mmio-bus.31']
    assert_equal 1, argv.count('-global')
  end

  def test_several_disks_are_numbered_in_order
    argv = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', disks: [DISK.new(path: '/a'), DISK.new(path: '/b')])
    assert_equal %w[file=/a,format=raw,if=none,id=disk0 file=/b,format=raw,if=none,id=disk1],
                 argv.each_cons(2).select { |flag, _| flag == '-drive' }.map(&:last)
    assert_equal 1, argv.count('-global')
  end

  # The guest's one way to the host is the guest forward to the echo server's loopback
  # port: slirp stays restricted and forwards nothing from the host into the guest.
  def test_a_network_device_is_restricted_slirp_with_one_guest_forward_to_loopback
    nic = Erx::QemuPlan::Nic.new(frames_port: 5001, peer_port: 5002, echo_port: 5003)
    argv = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', nic: nic)
    users = argv.each_cons(2).select { |flag, value| flag == '-netdev' && value.start_with?('user,') }.map(&:last)
    assert_equal ['user,id=nic_user,restrict=on,domainname=erxos.test,guestfwd=tcp:10.0.2.4:7-tcp:127.0.0.1:5003'], users
    refute(argv.any? { |argument| argument.include?('hostfwd') })
  end

  def test_a_disk_path_that_could_change_what_qemu_opens_is_refused
    ['relative.img', 'nbd:host:1', '/a,b', "/a\0b", '', nil, 5].each do |path|
      assert_raises(Erx::Error, path.inspect) { DISK.new(path: path) }
    end
    too_many = Array.new(Erx::QemuPlan::MAX_DISKS + 1) { |index| DISK.new(path: "/d#{index}") }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', disks: too_many) }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', disks: ['/a']) }
    assert_raises(Erx::Error) { Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', disks: nil) }
  end

  def test_a_checkpoint_types_once_its_line_has_come
    matcher = Erx::Transcript.new(checkpoints: [{ name: 'prompt', pattern: /^prompt\r?\n/n, seconds: 2, type: 'a' },
                                                { name: 'second', pattern: /^second\r?\n/n, seconds: 2 }])
    assert matcher.types?
    File.binwrite(@serial, "noise\n")
    matcher.consume(@serial, elapsed: 0.1)
    assert_equal '', matcher.take_typed
    File.binwrite(@serial, "noise\nprompt\n")
    matcher.consume(@serial, elapsed: 0.2)
    assert_equal 'a', matcher.take_typed
    assert_equal '', matcher.take_typed
    refute Erx::Transcript.new(checkpoints: checkpoints).types?
  end

  def test_a_checkpoint_that_types_something_else_is_a_domain_error
    assert_raises(Erx::Error) { Erx::Transcript.new(checkpoints: [{ name: 'prompt', pattern: /^p/n, seconds: 2, type: 7 }]) }
  end

  def test_invalid_guest_configuration_is_refused
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(platform: PLATFORM, accel: 'unknown', image: 'image', serial: 'serial')
    end
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(platform: PLATFORM, accel: 'tcg', image: 'image', serial: 'serial', cpus: 0)
    end
  end

  def test_split_lines_match_once_in_order
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, 'fir')
    refute transcript.consume(@serial, elapsed: 0.1)
    File.open(@serial, 'a') { |file| file.write("st\r\nsecond\n") }
    assert transcript.consume(@serial, elapsed: 0.2)
    assert_equal %w[first second], transcript.observed.map { |entry| entry.fetch('name') }
    assert transcript.consume(@serial, elapsed: 0.3)
    assert_equal 2, transcript.observed.size
  end

  def test_out_of_order_line_does_not_satisfy_later_checkpoint
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, "second\nfirst\n")
    refute transcript.consume(@serial, elapsed: 0.1)
    assert_equal ['first'], transcript.observed.map { |entry| entry.fetch('name') }
    error = assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 3.2) }
    assert_match(/second/, error.message)
  end

  def test_missing_and_overlong_serial_are_failures
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 2) }
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, 'x' * (Erx::Transcript::MAX_LINE_BYTES + 1))
    transcript.consume(@serial, elapsed: 0.1)
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 0.2) }
  end

  def fake_guest(output:, version_delay: 0, guest_delay: 0, linger: 0, stderr: '')
    path = File.join(@directory, 'fake-qemu')
    source = <<~RUBY
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      if ARGV.include?('--version')
        sleep #{version_delay}
        puts 'QEMU emulator version 11.1.3 (fixture)'
        exit 0
      end
      serial = ARGV.fetch(ARGV.index('-serial') + 1).delete_prefix('file:')
      sleep #{guest_delay}
      File.binwrite(serial, #{output.dump})
      $stderr.write(#{stderr.dump})
      sleep #{linger}
    RUBY
    File.write(path, source)
    File.chmod(0o700, path)
    path
  end

  def image
    path = File.join(@directory, 'image.elf')
    File.write(path, 'fixture image')
    path
  end

  def test_successful_early_exit_drains_complete_serial_backlog
    output = "ordinary line\n" * 6000 + "done\n"
    guest = fake_guest(output: output)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    report = qemu.run(platform: PLATFORM, accel: 'tcg', image: image,
                      checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 2 }])
    assert_equal 'passed', report.fetch('state')
  end

  def test_version_probe_time_does_not_consume_guest_deadline
    guest = fake_guest(output: "done\n", version_delay: 1.1)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    report = qemu.run(platform: PLATFORM, accel: 'tcg', image: image,
                      checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 1 }])
    assert_equal 'passed', report.fetch('state')
  end

  # A run in a directory an earlier run used reads only its own guest's lines: the earlier
  # serial log's "done" does not pass a guest that prints nothing.
  def test_a_reused_directory_does_not_replay_the_earlier_serial_log
    directory = File.join(@directory, 'build/run')
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.write(File.join(directory, 'serial.log'), "done\n")
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: '', guest_delay: 2))
    assert_raises(Erx::Error) do
      qemu.run(platform: PLATFORM, accel: 'tcg', image: image, directory: directory,
               checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 1 }])
    end
  end

  def test_checkpoint_expiry_is_reported_as_timeout
    guest = fake_guest(output: '', guest_delay: 2)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    assert_raises(Erx::Error) do
      qemu.run(platform: PLATFORM, accel: 'tcg', image: image,
               checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 1 }])
    end
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    assert_equal 'timed_out', JSON.parse(File.read(path)).fetch('state')
  end

  def test_interruption_does_not_leave_a_running_guest_report
    qemu = Erx::Qemu.new(root: @directory, runner: InterruptingQemuRunner.new)
    assert_raises(Interrupt) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image) }
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    assert_equal 'cancelled', JSON.parse(File.read(path)).fetch('state')
  end

  def test_linked_qemu_output_branch_does_not_receive_a_guest_directory
    Dir.mktmpdir do |outside|
      FileUtils.mkdir_p(File.join(@directory, 'build'))
      File.symlink(outside, File.join(@directory, 'build/qemu'))
      qemu = Erx::Qemu.new(root: @directory, runner: InterruptingQemuRunner.new)
      begin
        qemu.run(platform: PLATFORM, accel: 'tcg', image: image)
      rescue Erx::Error, Interrupt
        # An invalid output branch is refused before creating guest files.
      end
      assert_empty Dir.children(outside)
    end
  end

  def test_late_checkpoint_cannot_restart_its_deadline
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, "first\nsecond\n")
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 3) }
  end

  # The platform record's RAM as bootstrap prints it.
  RAM = "#{PLATFORM.memory_mib}.0 MiB"

  def boot_transcript(available:, warning: "development build: trusted code only\r\n",
                      art: "  \\___||_|   /_/\\_\\ \\___/ |___/\r\n")
    last = format('%016x', PLATFORM.ram_first + (PLATFORM.memory_mib << 20) - 1)
    "L4 Bootstrapper\r\n  RAM: #{format('%016x', PLATFORM.ram_first)} - #{last}: #{RAM}\r\n" \
      "  Total RAM: #{RAM}; available for Bootstrap/Sigma0/Kernel: #{available}\r\n" \
      "#{art}\e[1;32merXos\r\n#{warning}"
  end

  def test_boot_without_the_banner_art_fails
    qemu = Erx::Qemu.new(root: @directory,
                         program: fake_guest(output: boot_transcript(available: RAM, art: '')))
    assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image) }
  end

  def test_boot_without_the_development_warning_fails
    qemu = Erx::Qemu.new(root: @directory,
                         program: fake_guest(output: boot_transcript(available: RAM, warning: '')))
    assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image) }
  end

  def test_a_guest_that_must_end_the_machine_may_exit_once_its_transcript_is_whole
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: RAM)))
    assert_equal 'passed', qemu.run(platform: PLATFORM, accel: 'tcg', image: image, machine_end: true).fetch('state')
  end

  def test_a_guest_that_ends_the_machine_early_fails
    qemu = Erx::Qemu.new(root: @directory,
                         program: fake_guest(output: boot_transcript(available: RAM, warning: '')))
    error = assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image, machine_end: true) }
    assert_match(/before completing its transcript/, error.message)
  end

  # QEMU exits 0 on SIGTERM and gtimeout passes that status on, so only QEMU's own line
  # tells a run stopped from outside from a guest that ended the machine.
  def test_qemu_stopped_by_a_signal_says_so
    { "qemu-system-aarch64: terminating on signal 15 from pid 4242 (<unknown process>)\n" => ' from pid 4242',
      "qemu-system-aarch64: terminating on signal 2\n" => '' }.each do |line, sender|
      qemu = Erx::Qemu.new(root: @directory,
                           program: fake_guest(output: boot_transcript(available: RAM, warning: ''), stderr: line))
      error = assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image) }
      signal = line[/signal (\d+)/, 1]
      assert_equal "QEMU was stopped by signal #{signal}#{sender} before completing its transcript", error.message
    end
  end

  # What a root task that never calls shutdown looks like: the transcript is
  # whole and QEMU stays up, so the run must fail at its deadline.
  def test_a_guest_that_never_ends_the_machine_fails_at_the_deadline
    points = [{ name: 'only', pattern: /line\r?\n/n, seconds: 1 }].freeze
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: "line\r\n", linger: 60))
    error = assert_raises(Erx::CommandError) do
      qemu.run(platform: PLATFORM, accel: 'tcg', image: image, checkpoints: points, machine_end: true)
    end
    assert_equal 'timed_out', error.result.fetch('state')
  end

  def test_boot_with_consistent_bootstrap_memory_passes
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: RAM)))
    report = qemu.run(platform: PLATFORM, accel: 'tcg', image: image)
    assert_equal %w[bootstrap-memory erxos-art erxos-banner development-warning],
                 report.fetch('checkpoints').map { |entry| entry.fetch('name') }
    assert_equal 'passed', report.fetch('state')
  end

  def test_boot_summary_must_match_guest_ram
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: RAM)))
    error = assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image, memory_mib: 1024) }
    assert_match(/expected '.*Kernel: 1024\.0 MiB'/, error.message)
  end

  def test_boot_reporting_more_available_than_total_memory_fails
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: '16.0 EiB')))
    error = assert_raises(Erx::Error) { qemu.run(platform: PLATFORM, accel: 'tcg', image: image) }
    assert_match(/Kernel: 16\.0 EiB/, error.message)
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    report = JSON.parse(File.read(path))
    assert_equal 'failed', report.fetch('state')
    assert_empty report.fetch('checkpoints')
  end

  def test_checkpoint_verifier_must_be_callable
    point = { name: 'first', pattern: /^first\n/n, seconds: 1, verify: 'not callable' }
    assert_raises(Erx::Error) { Erx::Transcript.new(checkpoints: [point]) }
  end

  def test_malformed_checkpoint_is_a_domain_error
    assert_raises(Erx::Error) { Erx::Transcript.new(checkpoints: [nil]) }
  end
end
