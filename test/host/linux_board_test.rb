# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/linux_board'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/runner'

# Linux on the Raspberry Pi 4 (docs/design-bench.md, "Linux on the same board"): the set's
# layout beside erXos's, and the board's /init, which builds on the host for the board.
# The record of a Linux walk is BoardRecord's, tested with it.
class LinuxBoardTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')
  LINUX = { Erx::LinuxBoard::KERNEL => '/k/kernel8.img', Erx::LinuxBoard::TREE => '/k/bcm2711-rpi-4-b.dtb',
            Erx::LinuxBoard::LICENSE => '/k/COPYING.linux' }.freeze
  FIRMWARE = { 'start4.elf' => '/f/start4.elf', 'fixup4.dat' => '/f/fixup4.dat' }.freeze

  def plan(firmware: FIRMWARE)
    Erx::LinuxBoard.plan(platform: PI, name: 'posix', linux: LINUX, initramfs: '/b/initramfs.cpio',
                         bl31: '/b/bl31.bin', bl31_license: '/b/license.rst', firmware: firmware)
  end

  def test_the_set_is_erxoss_partition_with_linuxs_kernel_tree_and_initramfs
    laid = plan
    assert_equal '/k/kernel8.img', laid.fetch('kernel8.img')
    assert_equal '/k/bcm2711-rpi-4-b.dtb', laid.fetch('bcm2711-rpi-4-b.dtb')
    assert_equal '/b/initramfs.cpio', laid.fetch('initramfs.cpio')
    assert_equal '/b/bl31.bin', laid.fetch('bl31.bin')
    assert_equal '/f/start4.elf', laid.fetch('start4.elf')
    config = laid.fetch('config.txt').bytes
    erxos = Erx::BootPartition.config_txt(PI, overlays: [], build_kind: Erx::BuildKind::DEVELOPMENT)
    assert config.start_with?(erxos), "config.txt is not erXos's own"
    assert config.end_with?("initramfs initramfs.cpio 0x10000000\n")
    refute_match(/^dtoverlay=/, config)
    assert_match(/^arm_freq=1500\nforce_turbo=1\n.*^total_mem=1024$/m, config)
    assert_equal 'console=ttyS0,115200 quiet cpufreq.default_governor=performance panic=-1 maxcpus=4 -- posix 4', laid.fetch('cmdline.txt').bytes
    laid.each_key { |name| assert_match Erx::BootPartition::NAME, name }
  end

  def test_linux_on_the_board_runs_only_what_linuxs_guest_runs
    assert Erx::LinuxBoard.runs?('posix')
    assert Erx::LinuxBoard.runs?('wake')
    refute Erx::LinuxBoard.runs?('xdomain')
  end

  def test_firmware_that_would_replace_a_file_of_the_set_is_refused
    error = assert_raises(Erx::Error) { plan(firmware: FIRMWARE.merge('config.txt' => '/f/config.txt')) }
    assert_match(/config\.txt would replace/, error.message)
  end

  # The board's /init (bench/linux/init.c with ERX_INIT_BOARD), and the guest's beside it,
  # build and link for Linux with erXos's compiler, as LinuxBoard.lay_out builds them;
  # skipped where the compiler or Linux's C library is not at hand.
  def test_the_boards_init_builds_for_linux
    skip 'set ERX_CLANG and ERX_LLD' unless ENV['ERX_CLANG'] && ENV['ERX_LLD']
    Dir.mktmpdir('erx-linux-board-') do |directory|
      runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
      usr = begin
        Erx::LinuxGuest.lock(root: ROOT, runner: runner).fetched_tree(Erx::LinuxGuest::MUSL_DEV)
      rescue Erx::Error => e
        skip e.message
      end
      [['-DERX_INIT_BOARD'], []].each do |mode|
        output = File.join(directory, mode.empty? ? 'guest' : 'board')
        Dir.mkdir(output)
        program = Erx::LinuxGuest.compile(root: ROOT, usr: usr, output: output, runner: runner, source: Erx::LinuxGuest::INIT,
                                          flags: ['-DERX_INIT_DEADLINE_S=60u', *mode, '-Werror'])
        assert File.size(program).positive?
      end
    end
  end
end
