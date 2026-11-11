# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/device_give'

# What the device_give suite's harness types and expects (tools/lib/erx/device_give.rb).
# Nothing boots here.
class DeviceGiveTest < Minitest::Test
  Suite = Erx::DeviceGive
  ROOT = File.expand_path('../..', __dir__)
  PLAIN = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))

  # The manifest is MediumBoot's with the row staying up, restarting once, and holding the
  # spare unit, which the development manifest leaves unplaced.
  def test_the_row_stays_up_restarts_once_and_holds_the_spare_unit
    ours = Suite.manifest(PLAIN)
    assert ours.end_with?(Suite::DOMAIN_ROW + Suite::UNIT)
    assert_match(/^  restarts 1$/, Suite::DOMAIN_ROW)
    refute_includes Suite::DOMAIN_ROW[/^  args "(.*)"$/, 1].split, '-eval'
    assert_equal Erx::MediumBoot::DOMAIN_ROW.lines.size, Suite::DOMAIN_ROW.lines.size
    refute_match(/placement "spare"/, PLAIN)
  end

  # The answer's offset and size are the spare device's place in its register page, and its
  # role is one whose record the cell's find names.
  def test_the_answer_matches_the_spare_unit_of_the_platform_record
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    unit = platform.fetch('units').find { |entry| entry.fetch('key') == 'spare' }
    device = unit.fetch('devices').fetch(0)
    assert_equal [Suite::OFFSET, Suite::SIZE], [device.fetch('base') % 4096, device.fetch('size')]
    assert_equal %w[network none], device.values_at('role', 'dma')
    assert_includes Suite::LINE, 'find(net,virtio_mmio)'
    # erts takes id 5, the network domain 6 and the storage domain 7 at boot, so the restart takes 8.
    assert_equal "{device_give,5,{1953655158,3584,512,5},8,{1953655158,3584,512,8}}", Suite::ANSWER
    assert_includes Suite::LINE, 'state:=ready,node:=erts@erxos}'
  end

  # The line follows the shell's last checkpoint, and the end is SystemDomain's.
  def test_the_line_follows_the_shell_and_the_runtime_ends
    points = [{ name: 'boot' }.freeze, { name: 'release-shell' }.freeze]
    names = Suite.checkpoints(points).map { |point| point.fetch(:name) }
    assert_equal ['boot', 'release-shell', Erx::ProductionImage::Run::ERLANG_SHELL.fetch(:name),
                  'device-given', 'system-domain-ended'], names
    assert_raises(Erx::Error) { Suite.checkpoints([{ name: 'boot' }.freeze]) }
  end
end
