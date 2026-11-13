# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/display_domain'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

# The display_domain suite's own manifest and checkpoints (tools/lib/erx/display_domain.rb).
# Nothing boots here; the suite's pack admits the manifest.
class DisplayDomainTest < Minitest::Test
  Suite = Erx::DisplayDomain
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
  SITE = PLATFORM.site_manifest_source(ROOT)

  def figure(text, key) = Integer(text[/^  #{key} ([0-9]+)$/, 1], 10)

  # The site manifest gains the display row and the display unit on it, room for one domain
  # of the row's budgets, the client, and root_memory the gpu's DMA memory and the client
  # principal's memory on top.
  def test_the_manifest_places_the_display_unit_and_grows_root_memory_by_its_dma_memory
    ours = Suite.manifest(SITE, platform: PLATFORM)
    assert ours.end_with?(Suite::ROW + Suite::UNIT + Suite::CLIENT)
    refute_match(/placement "display"/, SITE)
    assert_equal 9_437_184, Suite.dma_memory(PLATFORM)
    budgets = Suite::MEMORY + Suite::OUTER
    assert_equal figure(SITE, 'root_memory') + budgets + 9_437_184 + Suite::CLIENT_MEMORY, figure(ours, 'root_memory')
    assert_equal figure(SITE, 'max_domains') + 1 + Suite::CLIENT_SESSIONS, figure(ours, 'max_domains')
    assert_match(/^  grant @share\.eighth$/, Suite::ROW)
    assert_match(/^  release @artifact\.display$/, Suite::ROW)
    assert_match(/^  restarts 0$/, Suite::ROW)
  end

  # Property 18's sum for screen, the client template's one grant for each session its
  # domains quota allows, fits the display's outer budget beside MediumBoot's, and the
  # display has a connection for each; the start row, enabled, names screen, and the
  # template boots the client's test script.
  def test_the_display_s_grants_fit_its_outer_budget
    cost = Suite::CLIENT_SESSIONS * (Suite::PIXELS + Suite::LANE)
    assert_equal Erx::MediumBoot::DOMAIN_OUTER + cost, figure(Suite::ROW, 'outer')
    assert_equal Suite::CLIENT_SESSIONS, figure(Suite::ROW, 'connections')
    assert_equal Suite::CLIENT_SESSIONS, figure(Suite::CLIENT, 'domains')
    assert_equal Suite::PIXELS, Integer(Suite::CLIENT[/^  parameter pixels ([0-9]+)$/, 1], 10)
    assert_match(/^start client\n  enable YES\n  display @service\.screen\n/, Suite::CLIENT)
    assert_match(/^  release @artifact\.pattern$/, Suite::CLIENT)
    assert Suite::BOOT.test
    assert_includes Suite::BOOT.applications, 'erx_pattern_test'
    assert_match(/^service screen\n  server @domain\.display\n  interface windows\ndisplay screen\n/, Suite::ROW)
  end

  # The manifest check admits the suite's manifest, properties 4 and 18 among its own,
  # over the fixture's archive with a planner that places nothing.
  def test_the_manifest_check_admits_the_suite_s_manifest
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    arguments = ManifestContextFixture.archive_arguments(codec, boots: %w[display network pattern session storage web])
    context = Erx::Manifest::Context.new(**arguments.merge(platform: platform))
    planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
    assert Erx::Manifest.admit(source: Suite.manifest(SITE, platform: PLATFORM), codec: codec, context: context, planner: planner)
  end

  # The input devices sit off the gpu's register page, on a page no unit of the manifest holds.
  def test_the_input_devices_are_off_the_gpus_page
    per_page = Erx::QemuPlan::TRANSPORTS_PER_PAGE
    gpu, keyboard, tablet = Suite::DISPLAY_BUSES.values_at(:gpu, :keyboard, :tablet)
    refute_includes [keyboard / per_page, tablet / per_page], gpu / per_page
    assert_equal [0, 0], [keyboard / per_page, tablet / per_page]
  end

# One presented passes; a refused open, a second outcome after the session was started
# again, or no outcome at all fails. The started line is not an outcome.
def test_the_client_lines_are_one_presented
  started = "space 3: notice: erx_pattern_test: started\r\n"
  presented = "space 3: notice: erx_pattern_test: presented\r\n"
  Suite.check_client_lines("boot\r\n#{started}#{presented}shell\r\n")
  ["boot\r\n#{started}", "#{started}space 3: notice: erx_pattern_test: {error,open,none}\r\n",
   "#{started}#{presented}#{started}#{presented}"].each do |log|
    assert_raises(Erx::Error) { Suite.check_client_lines(log) }
  end
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
    assert_equal 60 + Suite::WAIT_SECONDS + Suite::CLIENT_WAIT_SECONDS + 15, shell.fetch(:seconds)
    assert shell.fetch(:verify).respond_to?(:call)
    assert_raises(Erx::Error) { Suite.checkpoints([{ name: 'boot' }.freeze], socket: '/x', references: '/y', serial: '/z') }
  end
end
