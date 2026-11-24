# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/usb_boot'

# The usb suite's stick (tools/lib/erx/usb_boot.rb): how QEMU is told to attach it, the
# image the harness writes, and the stages the harness judges itself after the boot.
class UsbBootTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  STICK = Erx::UsbBoot::Stick
  SERVED = "1.2 notice domain 7 principal 1 usb: erx_usb_bot: medium LUN 0 ready: 2048 blocks of 512 bytes\r\n"
  ENDED = "1.9 notice domain 7 principal 1 usb: erx_usb_bot: medium LUN 0 ended: device\r\n"

  def setup
    @directory = Dir.mktmpdir('erx-usb-')
    File.chmod(0o700, @directory)
    @socket = File.join(@directory, 'q.sock')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def plan(**options) = Erx::QemuPlan.argv(platform: PLATFORM, accel: 'hvf', image: 'image', serial: 'serial', **options)

  # A disk on the controller's bus is a removable usb-storage stick over its raw image, its
  # drive with no front end, named usbstick0 for device_del; the keyboard keeps its line.
  def test_a_stick_is_a_removable_usb_storage_over_its_raw_image
    stick = File.join(@directory, 'stick.img')
    pcie = Erx::QemuPlan::Pcie.new(qmp_socket: @socket, functions: { 2 => 'qemu-xhci' },
                                   usb: ['usb-kbd', Erx::QemuPlan::Disk.new(path: stick)])
    pairs = plan(pcie: pcie).each_cons(2).to_a
    assert_includes pairs, ['-device', 'usb-kbd,bus=pcie2.0']
    assert_includes pairs, ['-drive', "if=none,id=usbstick0drive,file=#{stick},format=raw"]
    assert_includes pairs, ['-device', 'usb-storage,bus=pcie2.0,drive=usbstick0drive,removable=on,id=usbstick0']
    second = Erx::QemuPlan::Pcie.new(qmp_socket: @socket, functions: { 2 => 'qemu-xhci' },
                                     usb: [Erx::QemuPlan::Disk.new(path: stick), 'usb-kbd', Erx::QemuPlan::Disk.new(path: stick)])
    assert_includes plan(pcie: second).each_cons(2).to_a,
                    ['-device', 'usb-storage,bus=pcie2.0,drive=usbstick1drive,removable=on,id=usbstick1']
    assert_raises(Erx::Error) { Erx::QemuPlan::Pcie.new(qmp_socket: @socket, functions: { 2 => 'qemu-xhci' }, usb: ['usb-storage']) }
  end

  # The image is 1 MiB; each of its first sectors is its own line, the rest zeros, and the
  # MD5 the guest compares against is of those sectors alone.
  def test_the_image_holds_a_line_per_read_sector_then_zeros
    image = STICK.image
    assert_equal 1 << 20, image.bytesize
    assert image.byteslice(3 * 512, 512).start_with?("erxos usb-storage sector 0003\n")
    assert_equal "\0" * 512, image.byteslice(STICK::READ * 512, 512)
    assert_match(/\A[0-9A-F]{32}\z/, STICK.read_md5)
    assert_equal STICK::WRITE_SECTORS * 512, STICK.written.bytesize
  end

  # Seeded: the image after the boot passes persisted only with the written pattern in
  # place, and a console passes each logged stage only with its own line, the served one
  # at the image's capacity.
  def test_host_stages_need_the_pattern_on_the_image_and_each_line_on_the_console
    written = STICK.image.dup
    written[STICK::WRITE_SECTOR * 512, STICK.written.bytesize] = STICK.written
    assert_equal %w[persisted logged_served logged_ended],
                 Erx::UsbBoot.host_passed(image: written, console: SERVED + ENDED)
    off_by_one = written.dup
    off_by_one[(STICK::WRITE_SECTOR * 512) + 7] = 'X'
    assert_equal [], Erx::UsbBoot.host_passed(image: off_by_one, console: '')
    assert_equal [], Erx::UsbBoot.host_passed(image: STICK.image, console: ENDED)
    assert_equal [], Erx::UsbBoot.host_passed(image: STICK.image, console: SERVED.sub('2048 blocks', '2047 blocks'))
    assert_equal ['logged_served'], Erx::UsbBoot.host_passed(image: STICK.image, console: SERVED)
    assert_equal ['logged_served'], Erx::UsbBoot.host_passed(image: STICK.image, console: ENDED + SERVED)
  end

  # The stick's answer, the USB domain's text and then the media domain's, names its stages
  # as the keyboard's do; only those true pass, from either text.
  def test_only_the_true_stages_of_a_stick_answer_pass
    line = '(system@erxos)5> {usb_stick,<<"{[{reported,true},{sized,true}],{#{units => #{0 => serving}},2048}}">>,' \
           '<<"{[{read,false},{written,true},{read_back,true},{flushed,true}],{ok,ok,ok,ok}}">>}'
    assert_equal %w[reported sized written read_back flushed], Erx::UsbBoot.passed(line, tag: 'usb_stick')
    assert_equal ['unplugged'], Erx::UsbBoot.passed('{usb_gone,<<"{[{unplugged,true}],[]}">>}', tag: 'usb_gone')
  end

  # Only the restart cell's boot allows the USB domain a restart; the stick's keeps none.
  def test_only_the_restart_boot_allows_the_usb_domain_a_restart
    source = Erx::UsbBoot.manifest_source(ROOT, platform: PLATFORM)
    stick, restart = [0, 1].map { |restarts| Erx::UsbBoot.manifest(source, restarts: restarts) }
    assert_equal [0, 1], Erx::UsbBoot::BOOTS.map(&:restarts).sort
    assert_equal ["  restarts 0\n"], stick.lines - restart.lines
    assert_equal ["  restarts 1\n"], restart.lines - stick.lines
  end

  # The restart line's answer holds three texts, each starting with its stages, and each
  # true stage the restart boot names passes its cell; a stage inside a text's data, its
  # quotes escaped, is not read, nor one the boot does not name.
  def test_the_restart_answer_reports_the_stages_of_each_text
    line = '(system@erxos)6> {usb_restart,<<"{[{restarted,true}],#{name => <<\"usb\">>}}">>,' \
           '<<"{[{followed,false}],#{phase => ended}}">>,' \
           '<<"{[{started,true},{described,true}],{running,#{},[<<\"{[{typed,true}]\">>]}}">>}'
    assert_equal %w[restarted started described], Erx::UsbBoot.passed(line, tag: 'usb_restart')
    assert_equal [], Erx::UsbBoot.passed(line, tag: 'usb_retyped')
    cells = []
    notes = []
    Erx::UsbBoot.answer('usb_restart', sides: Erx::UsbBoot::RESTART_SIDES.fetch(:restart), side: ->(cell) { cells << cell },
                                       note: ->(text) { notes << text }).call(line)
    assert_equal %w[-restart-domain -restart-described], cells
    assert_equal 1, notes.length
  end

  # The restart boot ends at the second key's answer, whose typed stage is the second key's
  # cell, not the first's.
  def test_the_restart_boot_ends_at_the_second_key
    points = Erx::UsbBoot.restart_checkpoints([{ name: 'release-shell' }], socket: @socket, side: ->(_) {}, note: ->(_) {})
    assert_equal %w[usb-enum usb-typed usb-restart usb-retyped], points.filter_map { |point| point[:name] }.last(4)
    assert_equal Erx::UsbBoot.retyped_line, points[-2].fetch(:type)
    cells = []
    Erx::UsbBoot.restart_checkpoints([{ name: 'release-shell' }], socket: @socket, side: ->(cell) { cells << cell },
                                                                  note: ->(_) {})
                .last.fetch(:verify).call('{usb_retyped,<<"{[{typed,true}],[]}">>}')
    assert_equal ['-restart-second-key'], cells
  end
end
