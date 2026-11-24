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
  def without_connections(record) = record.sub(/^  connections [0-9]+\n/, '')

  # The configured domains a facet joins to the display, either way round, as usb_input
  # joins the USB domain's input tree to it, each by its reference (@domain.usb). Read
  # from the manifest's records, not from Manifest::Edit.without_domain.
  def display_peers(text)
    records = Erx::Manifest::Frontend.read(text).records
    servers = records.fetch('service', []).to_h { |service| ["@service.#{service.name}", service.reference('server')] }
    records.fetch('facet', []).filter_map do |facet|
      grantee = facet.reference('grantee')
      server = servers.fetch(facet.reference('service'))
      case [grantee, server]
      in ['@domain.display', /\A@domain\./ => peer] then peer
      in [/\A@domain\./ => peer, '@domain.display'] then peer
      else nil
      end
    end.uniq
  end

  # The suite boots the development manifest's own display records: the site manifest with
  # the display domain kept holds them line for line, but for the display's connections.
  # Those lose one for each domain the site leaves out that a facet joins to the display,
  # since Manifest::Edit.without_domain gives back their one connection: leaving out the
  # USB domain gives back the display's connection to usb_input. The suite's manifest then
  # changes only what the client needs (the display's outer budget, by the client's pixel
  # areas and lanes, its connections and its restarts) and the room the client takes,
  # before the client itself.
  def test_the_suite_boots_the_development_manifests_display_records
    %w[share runtime_limits domain service display unit].each do |kind|
      assert_equal record(DEVELOPMENT, "#{kind} display"), record(KEPT, "#{kind} display"), kind
    end
    assert_equal without_connections(record(DEVELOPMENT, 'limits display')), without_connections(record(KEPT, 'limits display')),
                 'limits display without connections'
    left_out = display_peers(DEVELOPMENT) - display_peers(KEPT)
    assert_equal field(DEVELOPMENT, 'limits display', 'connections') - left_out.size, field(KEPT, 'limits display', 'connections'),
                 "connections given back for #{left_out}"
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
    assert_includes Suite::BOOT.applications, 'erx_lvgl_lease_test'
    assert_includes Suite::BOOT.applications, 'erx_kiosk_test'
  end

  # Each boot's cell has its lvgl, lvgl-lease, lvgl-damage, lvgl-confine and lvgl-restart
  # cells beside it.
  def test_each_boot_carries_its_side_cells
    assert_equal %w[hvf-1cpu hvf-1cpu-lvgl hvf-1cpu-lvgl-lease hvf-1cpu-lvgl-damage hvf-1cpu-lvgl-confine
                    hvf-1cpu-lvgl-restart], Suite.cells(%w[hvf-1cpu])
  end

  # The lvgl client's lines are shown and then the button's event, and nothing else: a
  # client that never got the click, or whose UI went down, fails.
  def test_the_kiosk_lines_are_shown_then_pressed
    shown = "space 4: notice: erx_kiosk_test: shown\r\n"
    pressed = "space 4: notice: erx_kiosk_test: event pressed\r\n"
    Suite.check_kiosk_lines("space 4: notice: erx_kiosk_test: started\r\n#{shown}#{pressed}")
    [shown, "#{shown}space 4: notice: erx_kiosk_test: {ui_down,renderer_down}\r\n", "#{shown}#{pressed}#{pressed}"].each do |log|
      assert_raises(Erx::Error) { Suite.check_kiosk_lines(log) }
    end
  end

  # The lvgl cell's reference is a picture of the suite's screen, the pattern's size.
  def test_the_lvgl_reference_is_of_the_screen
    references = File.expand_path('../display/reference', __dir__)
    lvgl = Erx::ScreenReference.load(references, Suite::LVGL)
    pattern = Erx::ScreenReference.load(references, Suite::PATTERN)
    assert_equal [pattern.width, pattern.height], [lvgl.width, lvgl.height]
  end

  # One passed of the run passes, whatever the other runs logged; a failed round, a second
  # outcome after the session was started again, or no outcome at all fails. The started
  # line is not an outcome.
  def test_each_runs_lines_are_one_passed
    started = "space 3: notice: erx_lvgl_lease_test: started\r\n"
    passed = "space 3: notice: erx_lvgl_lease_test: lease passed\r\n"
    damage = "space 3: notice: erx_lvgl_lease_test: damage {error,10,{0,not_down}}\r\n"
    Suite.check_run_lines("boot\r\n#{started}space 3: notice: erx_pattern_test: presented\r\n#{passed}#{damage}", run: 'lease')
    ["boot\r\n#{started}", "#{started}space 3: notice: erx_lvgl_lease_test: lease {error,4,start_refused}\r\n",
     "#{started}#{passed}#{started}#{passed}", "#{started}#{damage}"].each do |log|
      assert_raises(Erx::Error) { Suite.check_run_lines(log, run: 'lease') }
    end
    assert_raises(Erx::Error) { Suite.check_run_lines("#{started}#{passed}#{damage}", run: 'damage') }
  end

  # The manifest check accepts the suite's manifest, properties 4 and 18 among its own,
  # over the fixture's archive with a planner that places nothing.
  def test_the_manifest_check_accepts_the_suite_s_manifest
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    source = Suite.manifest(KEPT)
    arguments = ManifestContextFixture.manifest_arguments(codec, source)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: platform))
    planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
    assert Erx::Manifest.admit(source: source, codec: codec, context: context, planner: planner)
  end

  # The input drivers' paths are the platform record's input devices, on the gpu's page:
  # the tablet's, then the keyboard's at the higher address.
  def test_the_input_drivers_are_the_records_input_devices
    assert_equal ['erx_virtio_input: /virtio_mmio@a001a00 driven', 'erx_virtio_input: /virtio_mmio@a001c00 driven'],
                 Suite.input_driven(PLATFORM)
  end

  # Both bring-ups and the key's and the corner's reads pass; a missing bring-up, a failed
  # one, a missing read, a read of another record or a second read fails.
  def test_the_input_lines_are_two_bring_ups_and_two_reads
    tablet, keyboard = Suite.input_driven(PLATFORM).map { |line| "% #6 0.4 debug space 1: #{line}\r\n" }
    kbd, mouse = Suite::INPUT_READ.map { |line| "space 3: notice: #{line}\r\n" }
    Suite.check_input_lines("boot\r\n#{tablet}#{keyboard}shell\r\n#{kbd}#{mouse}", platform: PLATFORM)
    failed = "% #6 0.4 debug space 1: erx_virtio_input: /virtio_mmio@a001c00 not driven: {attach,ebusy}\r\n"
    ["#{tablet}#{kbd}#{mouse}", "#{tablet}#{failed}#{kbd}#{mouse}", "#{tablet}#{keyboard}#{kbd}",
     "#{tablet}#{keyboard}#{kbd}space 3: notice: erx_pattern_test: mouse {1,0,0}\r\n",
     "#{tablet}#{keyboard}#{kbd}#{mouse}#{mouse}"].each do |log|
      assert_raises(Erx::Error) { Suite.check_input_lines(log, platform: PLATFORM) }
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
    side = ->(_suffix, &_check) {}
    *, shell, erlang, killed = Suite.checkpoints(points, platform: PLATFORM, socket: '/nonexistent/qmp.sock', references: '/nonexistent',
                                                         serial: '/nonexistent/serial.log', side: side)
    assert_equal 'release-shell', shell.fetch(:name)
    assert_equal ["erl\r", Suite::KILL_LINE], [shell, erlang].map { |point| point.fetch(:type) }
    assert_match killed.fetch(:pattern), "{kiosk_killed,true,false,true}\r\n"
    refute_match killed.fetch(:pattern), "1> KtDoms = fun() -> {kiosk_killed, is_pid(KtK)}\r\n"
    assert_equal 60 + (2 * Suite::WAIT_SECONDS) + (3 * Suite::CLIENT_WAIT_SECONDS) + Suite::LEASE_WAIT_SECONDS +
                 (2 * Suite::PROBE_WAIT_SECONDS) + 15, shell.fetch(:seconds)
    assert shell.fetch(:verify).respond_to?(:call)
    assert_raises(Erx::Error) do
      Suite.checkpoints([{ name: 'boot' }.freeze], platform: PLATFORM, socket: '/x', references: '/y', serial: '/z', side: side)
    end
  end
end
