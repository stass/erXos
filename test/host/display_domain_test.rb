# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/display_domain'

# The display_domain suite's own manifest and checkpoints (tools/lib/erx/display_domain.rb).
# Nothing boots here; the suite's pack admits the manifest.
class DisplayDomainTest < Minitest::Test
  Suite = Erx::DisplayDomain
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
  SITE = PLATFORM.site_manifest_source(ROOT)

  def figure(text, key) = Integer(text[/^  #{key} ([0-9]+)$/, 1], 10)

  # The site manifest gains the display row and the display unit on it, room for one domain
  # of the row's budgets, and root_memory the gpu's DMA memory on top.
  def test_the_manifest_places_the_display_unit_and_grows_root_memory_by_its_dma_memory
    ours = Suite.manifest(SITE, platform: PLATFORM)
    assert ours.end_with?(Suite::ROW + Suite::UNIT)
    refute_match(/placement "display"/, SITE)
    assert_equal 9_437_184, Suite.dma_memory(PLATFORM)
    budgets = Suite::MEMORY + Erx::MediumBoot::DOMAIN_OUTER
    assert_equal figure(SITE, 'root_memory') + budgets + 9_437_184, figure(ours, 'root_memory')
    assert_equal figure(SITE, 'max_domains') + 1, figure(ours, 'max_domains')
    assert_match(/^  grant @share\.eighth$/, Suite::ROW)
    assert_match(/^  release @artifact\.display$/, Suite::ROW)
    assert_match(/^  restarts 0$/, Suite::ROW)
  end

  # The input devices sit off the gpu's register page, on a page no unit of the manifest holds.
  def test_the_input_devices_are_off_the_gpus_page
    per_page = Erx::QemuPlan::TRANSPORTS_PER_PAGE
    gpu, keyboard, tablet = Suite::DISPLAY_BUSES.values_at(:gpu, :keyboard, :tablet)
    refute_includes [keyboard / per_page, tablet / per_page], gpu / per_page
    assert_equal [0, 0], [keyboard / per_page, tablet / per_page]
  end

  # The screen's reads follow the shell's banner, inside its checkpoint.
  # One bring-up passes; a failed flush, a second bring-up after a restart, or none fails.
  def test_the_driver_lines_are_one_bring_up
    bring_up = "% #6 0.41 debug space 1: erx_fb: scanout 0 at 1280x800\r\n"
    Suite.check_driver_lines("boot\r\n#{bring_up}shell\r\n")
    ["boot\r\n", bring_up * 2, "#{bring_up}% #6 0.5 debug space 1: erx_fb: the device failed a flush: eio\r\n"].each do |log|
      assert_raises(Erx::Error) { Suite.check_driver_lines(log) }
    end
  end

  def test_the_screen_is_read_at_the_shell
    points = [{ name: 'boot' }.freeze, { name: 'release-shell', seconds: 60 }.freeze]
    shell = Suite.checkpoints(points, socket: '/nonexistent/qmp.sock', references: '/nonexistent', serial: '/nonexistent/serial.log').last
    assert_equal 'release-shell', shell.fetch(:name)
    assert_equal 60 + Suite::WAIT_SECONDS + 15, shell.fetch(:seconds)
    assert shell.fetch(:verify).respond_to?(:call)
    assert_raises(Erx::Error) { Suite.checkpoints([{ name: 'boot' }.freeze], socket: '/x', references: '/y', serial: '/z') }
  end
end
