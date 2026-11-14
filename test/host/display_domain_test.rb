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
  KEPT = PLATFORM.site_manifest_source(ROOT, keep: [Suite::DOMAIN])
  DEVELOPMENT = PLATFORM.manifest_source(ROOT)

  def figure(text, key) = Integer(text[/^  #{key} ([0-9]+)$/, 1], 10)
  def field(text, record, key) = Erx::Manifest::Edit.value(text, record: record, field: key)
  def record(text, header) = text[/^#{header}\n(?:  .*\n)*/]

  # The suite boots the development manifest's own display records: the site manifest with
  # the display domain kept holds them line for line, and the suite's manifest changes
  # only what the client needs (the display's outer budget, by the client's pixel areas
  # and lanes, its connections and its restarts) and the room the client takes, before
  # the client itself.
  def test_the_suite_boots_the_development_manifests_display_records
    %w[share runtime_limits limits domain service display unit].each do |kind|
      assert_equal record(DEVELOPMENT, "#{kind} display"), record(KEPT, "#{kind} display"), kind
    end
    refute_match(/^domain display$/, PLATFORM.site_manifest_source(ROOT))
    ours = Suite.manifest(KEPT)
    assert ours.end_with?(Suite::CLIENT)
    before = Erx::ProductionImage.without_sessions(KEPT)
    assert_equal field(before, 'limits display', 'outer') + Suite::CLIENT_AREAS, field(ours, 'limits display', 'outer')
    assert_equal field(before, 'limits display', 'connections') + Suite::CLIENT_SESSIONS,
                 field(ours, 'limits display', 'connections')
    assert_equal 0, field(ours, 'domain display', 'restarts')
    assert_equal field(before, 'principal system', 'memory') + Suite::CLIENT_AREAS, field(ours, 'principal system', 'memory')
    assert_equal figure(before, 'root_memory') + Suite::CLIENT_AREAS + Suite::CLIENT_MEMORY, figure(ours, 'root_memory')
    assert_equal figure(before, 'max_domains') + Suite::CLIENT_SESSIONS, figure(ours, 'max_domains')
    assert_equal figure(before, 'max_connections') + Suite::CLIENT_SESSIONS, figure(ours, 'max_connections')
    changed = before.lines.zip(ours.lines).reject { |left, right| left == right }.map { |left, _right| left[/\A {2}([a-z_]+) /, 1] }
    assert_equal %w[connections max_connections max_domains memory outer restarts root_memory], changed.sort
    assert_equal before.lines.size + Suite::CLIENT.lines.size, ours.lines.size
  end

  # Property 18's sum for the client template's one grant of the display for each session
  # its domains quota allows is what the display's outer budget gains; the start row,
  # enabled, names the display, and the template boots the client's test script.
  def test_the_display_s_grants_fit_its_outer_budget
    assert_equal Suite::CLIENT_SESSIONS * (Suite::PIXELS + Suite::LANE), Suite::CLIENT_AREAS
    assert_equal Suite::CLIENT_SESSIONS, figure(Suite::CLIENT, 'domains')
    assert_equal Suite::PIXELS, Integer(Suite::CLIENT[/^  parameter pixels ([0-9]+)$/, 1], 10)
    assert_match(/^facet display\n  grantee @session\.client\n  service @service\.display\n/, Suite::CLIENT)
    assert_match(/^start client\n  enable YES\n  display @service\.display\n/, Suite::CLIENT)
    assert_match(/^  release @artifact\.pattern$/, Suite::CLIENT)
    assert Suite::BOOT.test
    assert_includes Suite::BOOT.applications, 'erx_pattern_test'
  end

  # A domain's registry holds each facet under its service's name, the service record's
  # name field or else the record's own name, never under the facet record's name
  # (docs/design-system.md, "Facets a configured domain serves"). The name
  # erx_pattern_test opens is the display service's in the manifest the suite boots; any
  # other name finds no grant, and the client polls until the suite's wait runs out.
  def test_the_client_opens_the_display_by_its_service_name
    service = record(Suite.manifest(KEPT), "service #{Suite::SERVICE}")
    registry_name = service[/^  name "?([a-z_]+)"?$/, 1] || Suite::SERVICE
    source = File.read(File.join(ROOT, 'test/erlang/apps/erx_pattern_test/src/erx_pattern_test.erl'))
    assert_equal registry_name, source[/^-define\(DISPLAY, ([a-z_]+)\)\.$/, 1]
  end

  # The manifest check admits the suite's manifest, properties 4 and 18 among its own,
  # over the fixture's archive with a planner that places nothing.
  def test_the_manifest_check_admits_the_suite_s_manifest
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    arguments = ManifestContextFixture.archive_arguments(codec, boots: %w[display network pattern session storage web])
    context = Erx::Manifest::Context.new(**arguments.merge(platform: platform))
    planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
    assert Erx::Manifest.admit(source: Suite.manifest(KEPT), codec: codec, context: context, planner: planner)
  end

  # The input drivers' paths are the platform record's input devices, on the gpu's page.
  def test_the_input_drivers_are_the_records_input_devices
    record = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    display = record.fetch('units').find { |unit| unit.fetch('key') == 'display' }.fetch('devices')
    paths = display.select { |device| device.fetch('role') == 'input' }.map { |device| device.fetch('path') }
    assert_equal paths.map { |path| "erx_virtio_input: #{path} driven" }, Suite::INPUT_DRIVEN
  end

  # Both bring-ups and the key's and the corner's reads pass; a missing bring-up, a failed
  # one, a missing read, a read of another record or a second read fails.
  def test_the_input_lines_are_two_bring_ups_and_two_reads
    tablet, keyboard = Suite::INPUT_DRIVEN.map { |line| "% #6 0.4 debug space 1: #{line}\r\n" }
    kbd, mouse = Suite::INPUT_READ.map { |line| "space 3: notice: #{line}\r\n" }
    Suite.check_input_lines("boot\r\n#{tablet}#{keyboard}shell\r\n#{kbd}#{mouse}")
    failed = "% #6 0.4 debug space 1: erx_virtio_input: /virtio_mmio@a001c00 not driven: {attach,ebusy}\r\n"
    ["#{tablet}#{kbd}#{mouse}", "#{tablet}#{failed}#{kbd}#{mouse}", "#{tablet}#{keyboard}#{kbd}",
     "#{tablet}#{keyboard}#{kbd}space 3: notice: erx_pattern_test: mouse {1,0,0}\r\n",
     "#{tablet}#{keyboard}#{kbd}#{mouse}#{mouse}"].each do |log|
      assert_raises(Erx::Error) { Suite.check_input_lines(log) }
    end
  end

# One presented passes; a refused open, a second outcome after the session was started
# again, or no outcome at all fails. The started line is not an outcome.
def test_the_client_lines_are_one_presented
  started = "space 3: notice: erx_pattern_test: started\r\n"
  presented = "space 3: notice: erx_pattern_test: presented\r\n"
  Suite.check_client_lines("boot\r\n#{started}#{presented}shell\r\nspace 3: notice: erx_pattern_test: kbd {typed,97}\r\n")
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
    assert_equal 60 + Suite::WAIT_SECONDS + (2 * Suite::CLIENT_WAIT_SECONDS) + 15, shell.fetch(:seconds)
    assert shell.fetch(:verify).respond_to?(:call)
    assert_raises(Erx::Error) { Suite.checkpoints([{ name: 'boot' }.freeze], socket: '/x', references: '/y', serial: '/z') }
  end
end
