# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/bt_domain'
require_relative '../../tools/lib/erx/display_domain'
require_relative '../../tools/lib/erx/dom_planner'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/net_device'
require_relative '../../tools/lib/erx/network_domain'
require_relative '../../tools/lib/erx/pcie_domain'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/system_domain'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../fixtures/dom_view_build'
require_relative '../fixtures/generated_tree'
require_relative '../fixtures/manifest_context'

# Property 12 with the domain library's own host build: the manifest check runs
# the library (liberx/system/dom_core.c, dom_life.c and dom_boot_view.c) through tools/host/dom_plan.c,
# which PackTools builds, planning the configured domains in boot order and then the
# introductions, each plan recorded before the next. So a configured domain or an
# introduction the library refuses fails the build, and what the library counts
# across domains is judged by the library alone: each seed below is one sum it holds.
class DomPlannerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PLATFORM = Erx::Platform.development(ROOT)
  LIMITS = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
           "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n  band app\n" \
           "  peer_held 4096\n  peer_held_total 4096\n"
  DOMAINS = "#{LIMITS}domain alpha\n  principal @principal.system\n  limits @limits.app\n  kind service\n" \
            "  flags none\n  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n"
  UNCAPPED = "share wide\n  quota_ns uncapped\n  period_ns 10000000\n  cpuset 15\n  capacity_mcpu 1000\n" \
             "  capacity_first 0\n  slice_us 1000\n  grace_us 5\n  base 16\n  ceiling 31\n  flags none\n"
  NARROW = UNCAPPED.sub('share wide', 'share narrow').sub('quota_ns uncapped', 'quota_ns 5000000')

  # The library's two host builds, the planner helper and the view driver, made once
  # per file into one directory: compiling them is most of a test's time, and no
  # test changes their sources.
  class << self
    def helper
      @planner_helper ||= Erx::PackTools.build(root: ROOT, owner_root: build_directory,
                                               directory: File.join(build_directory, 'tools'), runner: build_runner,
                                               compiler: ENV.fetch('ERX_CLANG', 'clang'), tools: ['domains'])
                                        .fetch('domains')
    end

    # test/fixtures/dom_view_driver.c over the library, printing the view's catalogue and services.
    def view_driver = @view_driver_path ||= view_driver_from(File.join(ROOT, 'liberx/system/dom_boot_view.c'), name: 'dom-view')

    # The view driver with boot_view in dom_boot_view.c's place, for a seeded fault.
    def view_driver_from(boot_view, name:)
      DomViewBuild.build(output: File.join(build_directory, name), runner: build_runner, name: name, boot_view: boot_view)
    end

    private

    def build_directory
      @build_directory ||= File.realpath(Dir.mktmpdir('dom-planner-tools-')).tap do |base|
        Minitest.after_run { FileUtils.remove_entry(base) }
      end
    end

    def build_runner = @build_runner ||= Erx::Runner.new(owner_root: build_directory, log_dir: File.join(build_directory, 'logs'))
  end

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt').record
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    @plain = ManifestContextFixture.sessionless(Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT))
    @source = with_domains('alpha')
    @directory = Dir.mktmpdir('dom-planner-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @helper = self.class.helper
    @planner = Erx::DomainPlanner.new(helper: @helper, runner: @runner)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def admit(source) = Erx::Manifest.admit(source: source, codec: @codec, context: @context, planner: @planner)

  # The named domains of the app profile, the system principal's quota covering them
  # and max_domains the sum of the quotas; share names the profile's grant in place of
  # users, NARROW's half a CPU keeping three domains within system's reserve.
  def with_domains(*names, quota: names.size, share: 'users')
    rows = names.map { |name| DOMAINS.delete_prefix(LIMITS).sub('domain alpha', "domain #{name}") }
    limits = LIMITS.sub('grant @share.users', "grant @share.#{share}")
    ManifestContextFixture.with_quota(@plain, quota) + limits + rows.join
  end

  def development_manifest = admit_development(development_source)

  # The view's catalogue and services, or its refusal, as test/fixtures/dom_view_driver.c prints them,
  # or with mode framebuffer its framebuffer rows' ranges before and after placement, or with
  # mode pci its bridges' catalogues, a report on each and the gives it allows.
  def view_lines(manifest, name, *mode, driver: self.class.view_driver)
    path = File.join(@directory, "view-#{name}.bin")
    File.binwrite(path, manifest)
    File.readlines(@runner.run([driver, path, *mode], name: "dom-view-#{name}", deadline: 30).fetch('log'), chomp: true)
  end

  # source with the machine's max_connections set to count; raises when the manifest
  # has no such row, so a manifest change cannot quietly disable a test.
  def with_max_connections(source, count)
    ManifestContextFixture.substitute(source, /^(  max_connections )\d+$/, "\\1#{count}")
  end

  def refused(source, field, message)
    error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
    assert_equal field, error.field, error.message
    assert_match message, error.message
  end

  def test_the_library_plans_a_configured_domain
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
  end

  # The development manifest as it ships, with its session template and its own
  # configured domains, storage, which holds the block unit, network, which holds the net
  # unit, web, display, which holds the display unit, pcie, which holds the ECAM bridge's
  # unit, and usb, which holds the xhci unit: the library plans all six, and
  # the system domain's arguments start no stack.
  def test_the_library_plans_the_development_manifests_domains
    source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    assert_equal ManifestContextFixture.rows(source, 'domain'), Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
                                                       .report.fetch('child_plan_instances')
    refute_includes source[/^  system_args .*$/], '-erx_net'
    assert_includes source, "unit net\n  placement \"net\"\n  holder @domain.network\n"
    assert_includes source, "unit display\n  placement \"display\"\n  holder @domain.display\n"
  end

  # The production image's narrow manifest (ProductionImage::Run.narrow_manifest), which
  # its 4-CPU cells boot: the system share on two CPUs, and the storage, web, display, PCIe
  # and USB domains' grants, which must fit the system share, on them too, so the library
  # plans them.
  def test_the_library_plans_the_narrow_images_domain
    source = Erx::ProductionImage::Run.narrow_manifest(ROOT, platform: PLATFORM)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    assert_equal ManifestContextFixture.rows(source, 'domain'), Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
                                                       .report.fetch('child_plan_instances')
  end

  # The system_domain suite's manifests, the service-kill boot's (SystemDomain.manifest)
  # and the re-grant boot's (SystemDomain::Regrant.manifest): their two configured rows,
  # erts and peer, beside the development manifest's storage and network, all four grants
  # within the system share's reserve, so the library plans each.
  def test_the_library_plans_the_system_domain_suites_domains
    source = PLATFORM.site_manifest_source(ROOT)
    arguments = ManifestContextFixture.archive_arguments(@codec, boots: %w[echo erts network session storage])
    context = Erx::Manifest::Context.new(**arguments.merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    [Erx::SystemDomain, Erx::SystemDomain::Regrant].each do |suite|
      admitted = Erx::Manifest.admit(source: suite.manifest(source), codec: @codec, context: context, planner: @planner)
      assert_equal 4, admitted.report.fetch('child_plan_instances'), suite.name
    end
  end

  # The pcie suite's manifest (PcieDomain.manifest): the development manifest without its
  # web domain, the PCIe domain and the test holder, whose grants with storage's,
  # network's and display's fit the system share's reserve, on the medium machine: the
  # library plans all five.
  def test_the_library_plans_the_pcie_suites_domains
    source = Erx::PcieDomain.manifest(Erx::PcieDomain.manifest_source(ROOT, platform: PLATFORM))
    arguments = ManifestContextFixture.manifest_arguments(@codec, source)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(source, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # The Bluetooth suite's manifest (BtDomain.manifest): the development manifest with
  # the line unit on the system domain, the Bluetooth domain and its line grant, and the
  # echo domain and its grant of ble for nus, on the medium machine: the check admits it,
  # the grant packs, and the library plans all eight domains.
  def test_the_library_plans_the_bluetooth_suites_domains
    source = Erx::BtDomain.manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM)
    arguments = ManifestContextFixture.manifest_arguments(@codec, source)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(source, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # The Bluetooth suite's bleuart cell (BtDomain.bleuart_manifest): the cells' medium
  # manifest with the system principal's session template kept and the Pi 4's bleuart
  # records, on the medium machine: the check admits it, bleuart's grants pack, and the
  # library plans its configured domains.
  def test_the_library_plans_the_bleuart_cells_domains
    board = Erx::Platform.load(root: ROOT, name: Erx::BtDomain::BLEUART_PLATFORM).manifest_source(ROOT)
    source = Erx::BtDomain.bleuart_manifest(PLATFORM.manifest_source(ROOT), platform: PLATFORM, board: board)
    arguments = ManifestContextFixture.manifest_arguments(@codec, source)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(source, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # The Raspberry Pi 4's development manifest, with its Bluetooth domain and the domain's
  # line grant on UART0, on the board's own record: the check admits it, and the library
  # plans every configured domain, the storage, display, PCIe, network, USB, media and
  # Bluetooth domains, whose grants fit the system share's reserve.
  def test_the_library_plans_the_raspberry_pi_s_domains
    pi = Erx::Platform.load(root: ROOT, name: 'raspi4b')
    source = pi.manifest_source(ROOT)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: pi.record))
    admitted = Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(source, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # The network domain cell's manifest (NetworkDomain.manifest), the development manifest
  # with the network row's restarts at 0, on the medium machine: the library plans it.
  def test_the_library_plans_the_network_domain_cells_domains
    source = PLATFORM.manifest_source(ROOT)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                                .merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    network = Erx::NetworkDomain.manifest(source)
    admitted = Erx::Manifest.admit(source: network, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(network, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # The net_device suite's manifest (NetDevice.manifest), the development manifest with
  # the network row on BeamAsm and the storage row still on the interpreter, and ntpd's
  # session added (NetDevice::NTPD) with the machine's limits grown for it: the library
  # plans it on the development machine the suite boots, and only the network row and the
  # machine changed.
  def test_the_library_plans_the_net_device_suites_beamasm_network_row
    source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    edited = Erx::NetDevice.manifest(source)
    before, after = [source, edited].map do |text|
      read = Erx::Manifest::Frontend.read(text)
      [read.machine, *read.records.values.flatten].to_h { |record| [record.header, record.to_h.except(:line)] }
    end
    assert_equal ['machine', 'domain network'], before.keys.reject { |header| before[header] == after[header] }
    assert_equal ['principal ntpd', 'session ntpd', 'facet ntpd_net', 'facet ntpd_clock', 'start ntpd'].sort,
                 (after.keys - before.keys).sort
    runtimes = Erx::Manifest::Frontend.read(edited).records.fetch('domain').to_h { |row| [row.name, row.reference('runtime')] }
    assert_equal '@artifact.jit', runtimes.fetch('network')
    assert_equal '@artifact.emu', runtimes.fetch('storage')
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                                .merge(platform: Erx::NetDevice.machine(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: edited, codec: @codec, context: context, planner: @planner)
    assert_equal ManifestContextFixture.rows(edited, 'domain'), admitted.report.fetch('child_plan_instances')
  end

  # ntpd's net grant holds two sockets (docs/design-time.md, "Who does what") on the
  # board's manifest and on the net_device suite's copy alike, so the grant refuses a
  # third open emfile (its limit, erx_net_grant_tests' sockets_limit); a row that leaves sockets out
  # takes the grant's default of 1,024 (erx_net_grant_core).
  def test_ntpds_net_grant_holds_two_sockets
    qemu = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)
    [Erx::Platform.load(root: ROOT, name: 'raspi4b').manifest_source(ROOT), Erx::NetDevice.manifest(qemu)].each do |source|
      facet = Erx::Manifest::Frontend.read(source).records.fetch('facet').find { |row| row.name == 'ntpd_net' }
      parameters = facet.to_h.fetch(:parameters).to_h { |key, value| [key.value, value.value] }
      assert_equal %w[2 131072], parameters.values_at('sockets', 'buffers')
    end
  end

  # Two principals' session templates (property 14), each its principal's, of the
  # profile split; system and guest split users between them, and guest takes a page
  # of system's memory. System's quota holds alpha and root's console session, which
  # the console logs in from system's template (property 17).
  SESSIONS = NARROW +
             LIMITS.sub('limits app', 'limits split').sub('grant @share.users', 'grant @share.narrow')
                   .sub('  spaces none', '  spaces @share.narrow').sub("  flags none\n", "  flags spaces\n") +
             "principal guest\n  memory 4096\n  grant @share.narrow\n  domains 0\n  names 0\n" \
             "  default_limits @limits.native\n  ceiling_limits @limits.native\n" +
             %w[guest system].map do |principal|
               "session #{principal}\n  limits @limits.split\n  runtime @artifact.emu\n  release @artifact.app\n"
             end.join

  def with_sessions
    source = with_domains('alpha', quota: 2, share: 'narrow')
    system = source.sub(/^(principal system\n  memory )(\d+)\n  grant @share\.users$/) do
      "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) - 4096}\n  grant @share.narrow"
    end
    refute_equal source, system, "the system principal's memory and grant"
    system.sub(/(limits native\n(?:  .*\n)*?  grant )@share\.users/, '\1@share.narrow') + SESSIONS
  end

  # A session's principal and default display are the words its start adds after its
  # template's environment (erx_dom_plan_session). A template whose environment sets
  # either variable, which would shadow its word, is refused by the view, which the build
  # runs. A key that only starts with one of them is the template's own. The view keeps
  # room for the words at their longest: an environment that leaves exactly that room is
  # admitted, one byte more is refused.
  def test_a_session_template_leaves_its_start_room_for_its_variables
    with_env = ->(words) { with_sessions.sub("session guest\n", "session guest\n  env \"#{words}\"\n") }
    view_refusal = ->(bytes, name) { view_lines(bytes, name).grep(/\Arefused /) }
    %w[display principal].each do |key|
      refused(with_env.call("LANG=C #{key}=other"), 'view', /a session template's environment sets a variable its start gives it/)
      assert_empty view_refusal.call(admit(with_env.call("LANG=C #{key}ed=yes")).bytes, "session-#{key}ed")
    end
    # Guest's arguments as the check packs them (Erx::Manifest's boot_args): its release's binding alone.
    room = session_env_room - %w[-- -boot /bin/app --].sum { |arg| arg.bytesize + 1 }
    word =->(bytes) { "E=#{'a' * (bytes - 3)}" }
    assert_empty view_refusal.call(admit(with_env.call(word.call(room))).bytes, 'session-room')
    error = assert_raises(Erx::Manifest::Invalid) { admit(with_env.call(word.call(room + 1))) }
    assert_match(/a session template's arguments and environment leave the boot page's strings no reserve for its node names, principal and display/,
                 error.message)
  end

  # The bytes of arguments and environment, NULs included, a session template may
  # hold: the boot page's strings less the view's reserve for node names, the build
  # record and the session's words (boot_templates), as the C headers define them.
  def session_env_room
    source = File.join(@directory, 'session-room.c')
    File.write(source, "#include <stdio.h>\n#include \"erx/boot_words.h\"\n#include \"erx/dom_lib.h\"\n" \
                       "int main(void) { printf(\"%zu\\n\", (size_t)ERX_BOOT_STRINGS_MAX - 2u * ERX_DOM_NODE_MAX - " \
                       "ERX_BOOT_BUILD_WORDS_MAX - ERX_DOM_SESSION_WORDS_MAX); return 0; }\n")
    output = File.join(@directory, 'session-room')
    @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', *Erx::Generated.include_flags(root: ROOT),
                 '-I', File.join(ROOT, 'include'), '-I', ROOT, source, '-o', output], name: 'session-room-build', deadline: 60)
    Integer(File.read(@runner.run([output], name: 'session-room', deadline: 10).fetch('log')), 10)
  end

  # A template is no configured domain: alpha is the one domain the boot plans.
  # The view places the apps row's max app entries after the manifest's principals, from
  # the app template the row names, which the check derives from QEMU virt's apps row,
  # and checks the row's indices once (docs/design-packaging.md, "The template's rows by
  # index"): an app_template naming root's template, a packages_facet naming the system
  # domain's packages row, an app_services row whose facet grants the template
  # another service, a packages_facet naming the template's grant of another service,
  # a system_facet naming the template's packages row, a template holding a facet the
  # row does not name and two app_services rows naming one facet are each refused, and
  # so is a template with no apps row.
  def test_the_view_places_the_app_entries_from_the_rows_the_apps_row_names
    bytes = development_manifest
    apps = bytes.byteslice(400, 4).unpack1('V')
    app_services = bytes.byteslice(408, 4).unpack1('V')
    template, packages = bytes.byteslice(apps + 12, 8).unpack('V2')
    first, count = bytes.byteslice(280, 8).unpack('V2')
    facets = (0...count).map { |index| bytes.byteslice(first + (index * 80), 80) }
    refute_nil extra_facet(facets, template), 'no facet row of another template to regrant'
    system_packages = facets.index do |row|
      row.byteslice(12, 4) == facets.fetch(packages).byteslice(12, 4) &&
        row.byteslice(72, 4).unpack1('V') == @codec.member('mf_grantee', 'system')
    end
    assert_equal ["apps template=#{template} first=2 max=4 memory=137363456 principals=5"],
                 view_lines(bytes, 'apps').grep(/^apps /)
    { 'app-template' => [apps + 12, template - 1,
                         'an apps row whose app_template is not the session template naming no principal'],
      'packages-facet' => [apps + 16, system_packages,
                           "the apps row's packages_facet is not the app template's grant of packages_service"],
      'packages-display' => [apps + 16, bytes.byteslice(app_services + 4, 4).unpack1('V'),
                             "the apps row's packages_facet is not the app template's grant of packages_service"],
      'system-packages' => [apps + 20, packages,
                            "the apps row's system_facet is not the app template's grant of system_service"],
      'service-facet' => [app_services + 4, packages,
                          "an app_services row's facet is not the app template's grant of its service"],
      'extra-facet' => [first + (extra_facet(facets, template) * 80) + 8, template,
                        'the app template holds a facet the apps row does not name'] }
      .each do |name, (at, value, reason)|
        assert_equal ["refused manifest: #{reason}"], view_lines(replaced_word(bytes, at, value), name)
      end
    # The second app_services row repeats the first; the facet it named goes to a grantee without that service.
    service, facet = bytes.byteslice(app_services, 8).unpack('V2')
    moved = bytes.byteslice(app_services + 12, 4).unpack1('V')
    grantee, kind = free_grantee(facets, facets.fetch(moved).byteslice(12, 4))
    refute_nil grantee, 'no grantee lacks the service the second app_services row names'
    twice = [[app_services + 8, service], [app_services + 12, facet], [first + (moved * 80) + 8, grantee],
             [first + (moved * 80) + 72, kind]].reduce(bytes) { |copy, (at, value)| replaced_word(copy, at, value) }
    assert_equal ["refused manifest: the apps row names one of the app template's facets twice"],
                 view_lines(twice, 'service-twice')
    assert_equal ['refused manifest: an app template with no apps row'],
                 view_lines(AbiManifestFixture.session_template(principal: 0xffffffff), 'template-no-apps')
  end

  # The index of a facet row granted to another session template for a service the app
  # template holds no facet of: regranted to the app template, it is a grant the apps
  # row does not name.
  def extra_facet(facets, template)
    session = @codec.member('mf_grantee', 'session')
    held = facets.select { |row| row.unpack('@8V @72V') == [template, session] }.map { |row| row.byteslice(12, 4) }
    facets.index do |row|
      row.unpack('@8V @72V') != [template, session] && row.byteslice(72, 4).unpack1('V') == session &&
        !held.include?(row.byteslice(12, 4))
    end
  end

  # A grantee, as [grantee, grantee_kind], of some facet row that holds no facet of
  # service, the packed service index of a facet row.
  def free_grantee(facets, service)
    grantees = facets.map { |row| row.unpack('@8V @72V') }.uniq
    grantees.find { |pair| facets.none? { |row| row.unpack('@8V @72V') == pair && row.byteslice(12, 4) == service } }
  end

  # bytes with the little-endian u32 at offset at replaced by value.
  def replaced_word(bytes, at, value) = bytes.dup.tap { |copy| copy[at, 4] = [value].pack('V') }

  def test_session_templates_are_not_configured_domains
    assert_equal 1, admit(with_sessions).report.fetch('child_plan_instances')
  end

  # Property 17's planning clause: each enabled start row's session is planned with
  # erx_dom_plan_session after the configured domains and introductions, as the boot
  # starts it, and recorded before the next. Each principal's quota takes its session
  # here, system's beside alpha and root's console session. Guest has a page of memory,
  # which holds no session of the split profile, so its enabled row fails the build;
  # left off, it is not planned.
  def test_an_enabled_start_row_whose_session_cannot_be_planned_fails_the_build
    fixture = ManifestContextFixture
    source = fixture.substitute(fixture.substitute(with_sessions, fixture::SYSTEM_QUOTA, '\13'), fixture::MAX_DOMAINS, '\14')
    source = fixture.substitute(source, /^(principal guest\n(?:  .*\n)*?  domains )0$/, '\11')
    admit(source + "start system\n")
    admit(source + "start guest\n  enable NO\n")
    error = assert_raises(Erx::Manifest::Invalid) { admit(source + "start system\nstart guest\n") }
    assert_equal 'start', error.field, error.message
    assert_match(/session of enabled start row guest with nomem\b/i, error.message)
    # A boot that cannot read the settings file starts the published defaults' rows.
    error = assert_raises(Erx::Manifest::Invalid) do
      admit(source + "start system\nstart guest\n  enable NO\n  published_enable YES\n")
    end
    assert_match(/session of published-default enabled start row guest with nomem\b/i, error.message)
  end

  # Property 17 counts the console's login: the console logs root in from the system
  # principal's template, so that session is planned after the configured domains and
  # before the start rows, as the boot starts the console before the start table. Alpha
  # and each session of the split profile take 5 MiB of their principal's memory, their
  # memory and outer budget. With 10 MiB, system holds alpha and root's console session,
  # so its start row, which fits beside alpha alone, fails the build. With 5 MiB it holds
  # alpha alone, so the console's session fails the build with no start row, and a
  # system principal with no template plans no console session and fits.
  def test_the_console_s_session_counts_beside_the_start_rows
    fixture = ManifestContextFixture
    domain = 4_194_304 + 1_048_576
    memory = /^(principal system\n  memory )\d+$/
    source = fixture.substitute(fixture.substitute(with_sessions, fixture::SYSTEM_QUOTA, '\13'), fixture::MAX_DOMAINS, '\13')
    source = fixture.substitute(source, memory, "\\1#{2 * domain}")
    admit(source)
    error = assert_raises(Erx::Manifest::Invalid) { admit(source + "start system\n") }
    assert_equal 'start', error.field, error.message
    assert_match(/session of enabled start row system with nomem\b/i, error.message)
    alone = fixture.substitute(source, memory, "\\1#{domain}")
    error = assert_raises(Erx::Manifest::Invalid) { admit(alone) }
    assert_equal 'machine.console', error.field, error.message
    assert_match(/console's session of root with nomem\b/i, error.message)
    admit(fixture.substitute(alone, fixture::SESSION_TEMPLATE, ''))
  end

  # A facet granted to a session template reaches the root's view, which admits it,
  # whether a configured domain serves its service or the system domain does
  # (property 14).
  def test_a_facet_granted_to_a_session_template_passes_the_view
    facet = "service b\n  server @domain.alpha\n  interface 1\nfacet gb\n  grantee @session.guest\n  service @service.b\n" \
            "  operations none\n  max_request 1\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    admit(with_sessions + facet)
    admit(with_sessions + facet.sub('server @domain.alpha', 'server system'))
  end

  # What the check never writes, which the root's view refuses: two templates out
  # of principal order, and two of one principal.
  def test_session_templates_not_one_per_principal_are_refused
    manifest = admit(with_sessions).bytes
    offset = @codec.open('manifest', manifest).header.fetch('sessions').fetch('offset')
    paths = %w[manifest heads plan].map { |name| File.join(@directory, "template-#{name}") }
    [[1, 0], [0, 0]].each do |first, second|
      bytes = manifest.dup.tap { |copy| copy[offset, 4] = [first].pack('V') }.tap { |copy| copy[offset + 40, 4] = [second].pack('V') }
      [bytes, '', "order 0\n"].zip(paths).each { |content, file| File.binwrite(file, content) }
      record = @helper.run(paths, runner: @runner, name: 'dom-plan-template', deadline: 30)
      assert_match(/\Arefused manifest: the session templates are not one per principal in principal order, with the app template last\n\z/,
                   File.binread(record.fetch('log')))
    end
  end

  # A facet the check accepts reaches the root's view; one granted to its service's own
  # server, which property 10 rules out and the check never writes, the view refuses.
  def test_a_facet_granted_to_its_own_server_is_refused_by_the_view
    facet = "service b\n  server @domain.beta\n  interface 1\nfacet ab\n  grantee @domain.alpha\n  service @service.b\n" \
            "  operations none\n  max_request 1\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    manifest = admit(with_domains('alpha', 'beta') + facet).bytes
    offset = @codec.open('manifest', manifest).header.fetch('facets').fetch('offset')
    paths = %w[manifest heads plan].map { |name| File.join(@directory, "facet-#{name}") }
    bytes = manifest.dup.tap { |copy| copy[offset + 8, 4] = [1].pack('V') }
    [bytes, '', "order 1\norder 0\n"].zip(paths).each { |content, file| File.binwrite(file, content) }
    record = @helper.run(paths, runner: @runner, name: 'dom-plan-facet', deadline: 30)
    assert_match(/\Arefused manifest: a facet is granted to its service's own server\n\z/, File.binread(record.fetch('log')))
  end

  # Two facets of one service name to one grantee: the view refuses them, since the
  # domain service would refuse them at boot, and so the build does. Facet ab grants
  # alpha beta's b and facet ac gamma's c, also named b.
  def test_two_facets_of_one_service_name_to_one_grantee_are_refused_by_the_view
    facet = lambda do |name, grantee, service|
      "facet #{name}\n  grantee @domain.#{grantee}\n  service @service.#{service}\n  operations none\n" \
        "  max_request 1\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    end
    services = "service b\n  server @domain.beta\n  interface 1\nservice c\n  name \"b\"\n  server @domain.gamma\n  interface 1\n"
    refused(with_domains('alpha', 'beta', 'gamma', share: 'narrow') + NARROW + services +
            facet.call('ab', 'alpha', 'b') + facet.call('ac', 'alpha', 'c'), 'view', /a grantee takes two facets of one service name/)
  end

  # The Ruby check takes any byte count; the library takes only whole pages.
  def test_a_budget_the_library_refuses_fails_the_build
    error = assert_raises(Erx::Manifest::Invalid) { admit(@source.sub("limits app\n  memory 4194304", "limits app\n  memory 4194305")) }
    assert_equal 'domain', error.field
    assert_match(/the domain library refuses configured domain alpha with inval/, error.message)
  end

  # Two grants whose exact rates sum to 2.325 CPUs, what system's 3.1 CPUs keep past the
  # reserve, which the library's thousandths, each rounded up, put one over: planned in
  # boot order against the first's record, the second is refused.
  def test_grants_within_the_reserve_only_in_exact_arithmetic_fail_the_build
    shares = { 'up' => 11_625_001, 'down' => 11_624_999 }.map do |name, quota|
      "share #{name}\n  quota_ns #{quota}\n  period_ns 10000000\n  cpuset 15\n  capacity_mcpu 1000\n" \
        "  capacity_first 0\n  slice_us 1000\n  grace_us 5\n  base 16\n  ceiling 31\n  flags none\n"
    end
    rows = { 'alpha' => 'up', 'beta' => 'down' }.map do |name, share|
      DOMAINS.sub("limits app\n", "limits #{name}\n").sub('grant @share.users', "grant @share.#{share}")
             .sub('domain alpha', "domain #{name}").sub('@limits.app', "@limits.#{name}")
    end
    source = shares.join + @source.delete_suffix(DOMAINS).sub("  domains 1\n", "  domains 2\n")
                                  .sub('max_domains 1', 'max_domains 4') + rows.join
    refused(source, 'domain', /configured domain beta with inval/)
  end

  def test_a_third_whole_cpu_past_the_reserve_fails_the_build
    refused(with_domains('alpha', 'beta', 'gamma'), 'domain', /configured domain gamma with inval/)
  end

  # Two domains of 8 MiB each past a principal of 16 MiB.
  def test_budgets_past_their_principal_fail_at_the_domain_that_overflows
    source = ManifestContextFixture.substitute(with_domains('alpha', 'beta'), /^(?<head>principal system\n  memory )\d+$/,
                                               '\k<head>16777216')
    refused(source.sub("limits app\n  memory 4194304", "limits app\n  memory 8388608"), 'domain', /configured domain beta with nomem/)
  end

  def test_domains_past_their_principal_quota_fail_the_build
    refused(NARROW + with_domains('alpha', 'beta', 'gamma', quota: 2, share: 'narrow'), 'domain',
            /configured domain gamma with limit/)
  end

  def test_a_grant_past_system_fails_the_build
    source = UNCAPPED + with_domains('alpha', share: 'wide')
    refused(source, 'domain', /configured domain alpha with inval/)
  end

  def test_a_sub_space_grant_past_its_domain_fails_the_build
    source = UNCAPPED + with_domains('alpha').sub("  spaces none\n  lane 4096\n  connections 2\n  crash 0\n  flags none\n",
                                                  "  spaces @share.wide\n  lane 4096\n  connections 2\n  crash 0\n  flags spaces\n")
    refused(source, 'domain', /configured domain alpha with inval/)
  end

  def test_system_connections_past_the_table_fail_the_build
    source = with_max_connections(with_domains('alpha', 'beta'), 1).sub('  connections 2', '  connections 1')
    refused(source, 'domain', /configured domain beta with limit/)
  end

  def test_introductions_within_every_bound_are_admitted
    source = "#{NARROW}#{with_max_connections(with_domains('alpha', 'beta', 'gamma', share: 'narrow'), 5)}" \
             "introduce @domain.alpha @domain.beta\nintroduce @domain.beta @domain.gamma\n"
    assert_equal 3, admit(source).report.fetch('child_plan_instances')
  end

  def test_an_introduction_past_the_connection_table_fails_the_build
    source = "#{with_max_connections(with_domains('alpha', 'beta'), 2)}introduce @domain.alpha @domain.beta\n"
    refused(source, 'introduce', /introduction of alpha and beta with limit/)
  end

  # Each recorded introduction counts against both parties' connections quota.
  def test_an_introduction_past_a_partys_connections_quota_fails_the_build
    source = NARROW + with_max_connections(with_domains('alpha', 'beta', 'gamma', share: 'narrow'), 6)
                      .sub('  connections 2', '  connections 1')
    source += "introduce @domain.alpha @domain.beta\nintroduce @domain.alpha @domain.gamma\n"
    refused(source, 'introduce', /introduction of alpha and gamma with limit/)
  end

  def test_a_runtime_without_an_accepted_image_fails_the_build
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).then do |arguments|
      arguments.merge(platform: @context.platform,
                      catalog: arguments.fetch(:catalog).map { |row| row.fetch('path') == 'runtimes/emu' ? row.except('image') : row })
    end)
    error = assert_raises(Erx::Manifest::Invalid) { admit(@source) }
    assert_match(/the domain library refuses configured domain alpha/, error.message)
  end

  # The seed the shared builder exists for: a principal the Ruby check accepts but
  # erx_dom_principal_check refuses (memory not a whole number of pages), which ended
  # the machine at boot while the check planned from a view of its own. Without
  # configured domains too, since a build always plans.
  def test_a_principal_the_library_refuses_fails_the_build
    [@plain, @source].each do |source|
      principal = source.sub(/^(principal system\n(?:  .*\n)*?  memory )(\d+)$/) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) - 1}" }
      refute_equal source, principal
      error = assert_raises(Erx::Manifest::Invalid) { admit(principal) }
      assert_equal 'view', error.field, error.message
      assert_match(/refuses a principal/, error.message)
    end
  end

  # The boot page's strings hold both node names beside a row's arguments and
  # environment, and a -erx_record given record per device the row holds, so a row whose
  # own words fit the strings alone, as the Ruby check counts them, is refused at
  # the view rather than at its creation. Words of 100 bytes with their NULs: 19
  # leave less than the two node names' 256 bytes, and 17 leave room for those but
  # not for the network transport's record once alpha holds its unit.
  def test_a_row_that_leaves_no_room_for_what_the_library_adds_fails_the_build
    holder = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    full = ->(source, count) { source.sub("domain alpha\n", "domain alpha\n  args \"#{(['a' * 99] * count).join(' ')}\"\n") }
    [[@source, 1], [@source, 17], [holder, 1]].each do |source, count|
      assert_equal 1, admit(full.call(source, count)).report.fetch('child_plan_instances')
    end
    [[@source, 19], [holder, 17]].each do |source, count|
      error = assert_raises(Erx::Manifest::Invalid) { admit(full.call(source, count)) }
      assert_equal 'view', error.field, error.message
      assert_match(/reserve/, error.message)
    end
  end

  # The device of the platform record's unit key, the record's units having one each.
  def device_of(platform, key) = platform.fetch('units').find { |unit| unit.fetch('key') == key }.fetch('devices').first

  # The system domain's pci service and its facet for alpha, the VL805's holder, since the
  # domain tests' manifest has no system service: a configured domain holds one exactly when it
  # holds a pci device (docs/design-pcie.md, "The manifest"), with the limits design-pcie.md's
  # "The rows and the facets' limits" gives a holder of one pci device.
  VL805_PCI_FACET = "service pci\n  server system\n  interface pci\nfacet alpha_pci\n  grantee @domain.alpha\n  service @service.pci\n  operations open,master,reset\n" \
                    "  max_request 1024\n  in_flight 1\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 8192\n"

  # The packed manifest of the Pi 4's closed bridge and the VL805 at its one place, line 175,
  # held by alpha, with the bridge's firmware request for the VL805, and a power line on the
  # console's UART, on the qemu-virt platform record (docs/design-usb.md, "The Phase 1 part",
  # "The VL805's firmware"; docs/design-bluetooth.md, "The power line").
  def vl805_manifest
    platform = JSON.parse(JSON.generate(@context.platform))
    row = { 'path' => '', 'bridge' => '', 'bus' => 0, 'device' => 0, 'function' => 0, 'clock' => 0, 'base' => 0, 'size' => 0,
            'line' => 0, 'dma' => 'none', 'dma_memory' => 0, 'flags' => 0 }
    bridge = row.merge('placement_key' => 'pcie', 'selector' => 'dt', 'role' => 'configuration', 'path' => '/scb/pcie@7d500000',
                       'compatible' => 'brcm,bcm2711-pcie', 'base' => 0x40_1000_0000, 'size' => 0x1000_0000, 'flags' => ['closed'],
                       'places' => [{ 'bus' => 1, 'device' => 0, 'function' => 0, 'pin' => 1 }], 'dma_limit' => 0x3c00_0000)
    function = row.merge('placement_key' => 'vl805', 'selector' => 'pci', 'role' => 'usb', 'bridge' => bridge.fetch('path'),
                         'bus' => 1, 'compatible' => 'pci1106,3483', 'line' => 175, 'dma' => 'unconfined',
                         'dma_memory' => 1 << 20, 'flags' => ['hostile'])
    platform.fetch('units').reject! { |unit| unit.fetch('key') == 'pcie' }
    platform.fetch('units').push({ 'key' => 'pcie', 'devices' => [bridge] }, { 'key' => 'vl805', 'devices' => [function] })
    platform['firmware_requests'] = [{ 'name' => 'vl805_notify', 'device' => bridge.fetch('path'), 'tag' => 'notify_xhci_reset',
                                       'arguments' => [0x0010_0000] },
                                     { 'device' => '/pl011@9000000', 'power_line' => 'bt_power', 'off_ms' => 300, 'on_ms' => 500 }]
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    source = with_domains('alpha', 'pcie') + "unit pcie\n  placement \"pcie\"\n  holder @domain.pcie\n" \
                                             "unit vl805\n  placement \"vl805\"\n  holder @domain.alpha\n" + VL805_PCI_FACET
    admit(source).bytes
  end

  # Every checked-in manifest over its own board's platform record: the view relates the
  # board's devices by page and by line (docs/design-shared-devices.md, "The unit rule"),
  # and every unit the records list is closed under both, the Raspberry Pi 4's five
  # PL011s on one page and line, and its mini UART and auxiliary SPI controllers, included.
  def test_every_checked_in_manifest_keeps_its_units_whole
    boards = Dir[File.join(ROOT, 'config/manifest/*-development.txt')].map { |path| File.basename(path, '-development.txt') }
    assert_operator boards.size, :>=, 2
    boards.each do |board|
      platform = Erx::Platform.load(root: ROOT, name: board)
      context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform.record))
      admitted = Erx::Manifest.admit(source: platform.manifest_source(ROOT), codec: @codec, context: context, planner: @planner)
      refute_empty admitted.bytes, board
    end
  end

  # The design's page fixture (docs/design-shared-devices.md, "Verification"): the network
  # transport moved into the block transport's register page, two adjacent virtio-mmio
  # transports 0x200 apart, each still on a line of its own. Two units that share a page
  # are a split unit, whether one holder takes both or two do. No view is built from such
  # a manifest, so no row is created from it and nothing is given.
  def test_units_that_share_a_register_page_fail_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    block = device_of(platform, 'block')
    device_of(platform, 'net')['base'] = block.fetch('base') - 0x200
    refute_equal block.fetch('line'), device_of(platform, 'net').fetch('line')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    two = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, two].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
      assert_equal 'view', error.field, error.message
      assert_match(/share a register page are in two units/, error.message)
    end
  end

  # The design's line fixture: the network transport moved onto the block transport's
  # line, each on a page of its own, so the two units share only a line (PL2's seeded
  # manifest). The kernel gives a line one IRQ object, so this too is a split unit,
  # whether one holder takes both or two do.
  def test_units_that_share_only_an_interrupt_line_fail_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    block = device_of(platform, 'block')
    device_of(platform, 'net')['line'] = block.fetch('line')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    two = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, two].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
      assert_equal 'view', error.field, error.message
      assert_match(/share an interrupt line are in two units/, error.message)
    end
  end

  # A function at a closed bridge's place names the line its bridge routes for the
  # place's pin, which joins the line relation as a device-tree line does
  # (docs/design-pcie.md, "The closed bus"): the VL805's line given to another unit, here
  # the block transport's, apart from its function is a split unit (docs/design-usb.md,
  # "The Phase 1 part").
  def test_a_closed_place_s_line_given_apart_from_its_function_fails_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    row = { 'path' => '', 'bridge' => '', 'bus' => 0, 'device' => 0, 'function' => 0, 'clock' => 0, 'base' => 0, 'size' => 0,
            'line' => 0, 'dma' => 'none', 'dma_memory' => 0, 'flags' => 0 }
    bridge = row.merge('placement_key' => 'pcie', 'selector' => 'dt', 'role' => 'configuration', 'path' => '/scb/pcie@7d500000',
                       'compatible' => 'brcm,bcm2711-pcie', 'base' => 0x40_1000_0000, 'size' => 0x1000_0000, 'flags' => ['closed'],
                       'places' => [{ 'bus' => 1, 'device' => 0, 'function' => 0, 'pin' => 1 }], 'dma_limit' => 0x3c00_0000)
    function = row.merge('placement_key' => 'vl805', 'selector' => 'pci', 'role' => 'usb', 'bridge' => bridge.fetch('path'),
                         'bus' => 1, 'compatible' => 'pci1106,3483', 'line' => device_of(platform, 'block').fetch('line'),
                         'dma' => 'unconfined', 'dma_memory' => 1 << 20, 'flags' => ['hostile'])
    platform.fetch('units').reject! { |unit| unit.fetch('key') == 'pcie' }
    platform.fetch('units').push({ 'key' => 'pcie', 'devices' => [bridge] }, { 'key' => 'vl805', 'devices' => [function] })
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    source = with_domains('alpha', 'pcie') + "unit pcie\n  placement \"pcie\"\n  holder @domain.pcie\n" \
                                             "unit vl805\n  placement \"vl805\"\n  holder @domain.alpha\n" + VL805_PCI_FACET
    error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
    assert_equal 'view', error.field, error.message
    assert_match(/share an interrupt line are in two units/, error.message)
  end

  # A PCIe function's entry (docs/design-usb.md, "The Phase 1 part"): the VL805's row takes
  # its kind from erx/device_kinds.h by its role and identity, pci1106,3483, so its holder
  # drives it as usb over the xhci peripheral, and its position names its bridge's entry and
  # its place there; it has no register range until its report, and its line is its place's.
  def test_a_pci_function_takes_its_kind_and_position
    lines = view_lines(vl805_manifest, 'pci')
    bridge_line = lines.find { |line| line.start_with?('device ') && line.include?('unit=pcie ') }
    refute_nil bridge_line, lines.inspect
    index = bridge_line[/\Adevice (\d+) /, 1]
    entry = /\Adevice \d+ unit=vl805 compatible=pci1106,3483 ranges= bridge=#{index} place=1\.0\.0 role=usb peripheral=xhci lines=175 confined=0\z/
    assert(lines.any? { |line| line.match?(entry) }, lines.inspect)
  end

  # The firmware requests' allow-list (docs/design-fiasco.md, "The firmware request";
  # docs/design-bluetooth.md, "The power line"): the bridge's notification resolves for the
  # bridge's row alone, the VL805's, its tag and argument the platform record's, and a power
  # line's phases for the UART whose row carries the line's times alone, off and on its
  # SET_GPIO_STATE rows at the phases' indices; every other ask, a power phase of the bridge
  # and of a UART with no times, the bridge notification of the powered UART, and a phase
  # outside fw_power_phase, is refused enotsup (-12), and a device past the catalogue and the
  # machine's rows einval (-1), before any request is made. A request that timed out marks
  # the bridge firmware_lost; one that met another request in flight does not.
  def test_a_firmware_request_resolves_only_on_the_allow_list
    lines = view_lines(vl805_manifest, 'firmware', 'firmware')
    rows = lines.grep(/\Afirmware \d+ \w+ (\d+ )?tag=/)
    device = rows.join("\n")[/^firmware (\d+) bridge /, 1]
    uart = rows.join("\n")[/^firmware (\d+) power 0 /, 1]
    refute_nil device, lines.inspect
    refute_nil uart, lines.inspect
    assert_equal ["firmware #{device} bridge tag=0x30058 arguments=0x100000,0x0",
                  "firmware #{uart} power 0 tag=0x38041 arguments=0x80,0x0",
                  "firmware #{uart} power 1 tag=0x38041 arguments=0x80,0x1"].sort, rows.sort
    assert_equal (0..2).map { |phase| "firmware #{device} power #{phase} status=-12" }, lines.grep(/\Afirmware #{device} power /)
    assert_equal ["firmware #{uart} bridge status=-12", "firmware #{uart} power 2 status=-12"],
                 lines.grep(/\Afirmware #{uart} /) - rows
    others = lines.grep(/\Afirmware (\d+) /) { |line| line[/\d+/] }.uniq - [device, uart]
    refute_empty others
    others.each { |other| assert_equal 4, lines.grep(/\Afirmware #{other} \w+ (\d+ )?status=-12\z/).size, other }
    assert_includes lines, 'firmware outside status=-1,-1'
    assert_includes lines, 'firmware machine status=-1,-1'
    assert_equal ["lost #{device} busy=0 timedout=1"], lines.grep(/\Alost /)
  end

  # A host bridge's catalogue at boot (docs/design-pcie.md, "Records", "The catalogue and
  # gives"): the view holds one per bridge row, its record's row, closed mark and places the
  # manifest's; once the root joins the tree's windows, the library takes the PCIe domain's
  # report on the VL805 and a give finds it, its BAR's CPU range the window's. Joined to a
  # tree the reader refused, the catalogue takes no report.
  def test_a_bridge_s_catalogue_takes_a_report_and_gives_its_function
    lines = view_lines(vl805_manifest, 'pci-report', 'pci')
    bridge = lines.grep(/\Abridge /)
    assert_equal 1, bridge.size, lines.inspect
    row = bridge.first[/\Abridge 0 row=(\d+) closed=1 places=1\.0\.0\/1\z/, 1]
    refute_nil row, lines.inspect
    assert_includes lines, "report #{row} status=0 field=none"
    assert_includes lines, "refused #{row} status=-1 field=bus"
    # A report the caller could not read is refused whole, and leaves no confirmation.
    assert_includes lines, "unread #{row} status=-1 record=2 field=record confirmed=0"
    assert_includes lines, 'unread none status=-1 field=bridge'
    assert_equal ["cpu=0x600000000+0x1000"], lines.grep(/\Agiven /).map { |line| line.split.last }
    # The layout keeps its placing report's state beside the latest one's.
    assert_equal ["layout #{row} 1.0.0 placed=1 state=1 confirmed=1"], lines.grep(/\Alayout /)
    # A pci row's mode: a raise only with a holder and a confirmed layout, a mode in the set,
    # the lowering always, and no write to a row that is not a pci row.
    assert_equal ['unheld=-1 held=0 mode=2 past=-1 wide=-1 unconfirmed=-1 off=0 other=-1'],
                 lines.grep(/\Amode /).map { |line| line.split.drop(2).join(' ') }
    # The incarnation answered: written only to a bridge its domain holds, 0 never.
    assert_equal ["answered #{row} before=0 unheld=-1 none=-1 held=0 other=-1 after=9"], lines.grep(/\Aanswered /)
  end

  # The seeded fault: a raise written without asking whether the catalogue gives the
  # function, so the library says decoding for a function whose layout is unconfirmed.
  def test_a_raise_of_a_function_its_catalogue_does_not_give_is_refused
    source = File.read(File.join(ROOT, 'liberx/system/dom_boot_view.c'))
    check = "\tif (mode != ERX_PCIE_MODE_OFF && (record->holder == 0 ||\n" \
            "\t    erx_dom_pci_given(lib->pci_bridges, lib->view.npci_bridges, &lib->view.devices[index], &facts) == NULL))\n"
    assert_equal 1, source.scan(check).size, 'the seed no longer applies'
    seeded = File.join(@directory, 'dom_boot_view.c')
    File.write(seeded, source.sub(check, "\t(void)facts;\n\tif (mode != ERX_PCIE_MODE_OFF && record->holder == 0)\n"))
    driver = self.class.view_driver_from(seeded, name: 'dom-view-raise-ungiven')
    lines = view_lines(vl805_manifest, 'pci-raise-ungiven', 'pci', driver: driver)
    assert_equal ['unconfirmed=0'], lines.grep(/\Amode /).map { |line| line[/unconfirmed=-?\d+/] }
  end

  # The seeded fault: the catalogue built without the tree's windows, so the report's BAR
  # lies outside every window, the intake refuses it and no give finds the function.
  def test_a_catalogue_without_the_tree_s_windows_gives_nothing
    source = File.read(File.join(ROOT, 'liberx/system/dom_boot_view.c'))
    copy = "\tmemcpy(bridge->facts.windows, tree->windows, sizeof(bridge->facts.windows));\n"
    assert_equal 1, source.scan(copy).size, 'the seed no longer applies'
    seeded = File.join(@directory, 'dom_boot_view.c')
    File.write(seeded, source.sub(copy, ''))
    driver = self.class.view_driver_from(seeded, name: 'dom-view-no-windows')
    lines = view_lines(vl805_manifest, 'pci-no-windows', 'pci', driver: driver)
    assert(lines.any? { |line| line.match?(/\Areport \d+ status=-1 field=bars\z/) }, lines.inspect)
    assert_equal ['cpu=none'], lines.grep(/\Agiven /).map { |line| line.split.last }
  end

  # Line 0 is no line (docs/design-abi.md, "Devices and partition windows"): two rows of no
  # kind whose nodes raise no interrupt, as the Raspberry Pi 4's RNG200 does, share none, so
  # they may sit in two units, on pages of their own.
  def test_units_whose_devices_have_no_line_share_none
    platform = JSON.parse(JSON.generate(@context.platform))
    base = device_of(platform, 'block').fetch('base')
    { 'net' => 0x1000, 'line' => 0x2000 }.each do |key, offset|
      device_of(platform, key).merge!('base' => base + offset, 'line' => 0, 'role' => 'ordinary', 'dma' => 'none', 'flags' => 0,
                                      'dma_memory' => 0)
    end
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    admit("#{@source}unit line\n  placement \"line\"\n  holder @domain.alpha\n")
  end

  # A unit of two devices on pages of their own that share a line, as the Raspberry Pi
  # 4's two SD controllers do: the system domain may hold it, and so may a configured
  # row, since the row's creation makes one IRQ object for the line, in the first
  # device's give, and the second device's give names it (docs/design-shared-devices.md,
  # "The unit rule"). The view admits that placement, and so the build does.
  def test_a_configured_row_holding_a_unit_whose_devices_share_a_line_is_admitted
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/virtio_mmio@a000e00', 'base' => 0x0a000e00, 'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    assert_equal 1, admit(held).report.fetch('child_plan_instances')
  end

  # The Raspberry Pi 4's sd unit: EMMC2 and, on its line, the legacy SD controller,
  # whose role and compatible string are in no row of erx/device_kinds.h. A configured
  # row may hold it, as the system domain holds the auxiliary SPI controllers: the
  # kindless device is given its objects with its unit and gets no -erx_record given record
  # (docs/design-shared-devices.md, "The unit rule"). The view admits that placement.
  def test_a_configured_row_holding_a_device_of_no_kind_is_admitted
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/soc/mmc@a000e00', 'base' => 0x0a000e00, 'role' => 'ordinary',
                           'compatible' => 'brcm,bcm2835-sdhci', 'dma' => 'none', 'dma_memory' => 0,
                           'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    assert_equal 1, admit(held).report.fetch('child_plan_instances')
  end

  # The Raspberry Pi 4's auxiliary block: the mini UART and, on its register page and
  # its line, the two auxiliary SPI controllers, of no kind a runtime drives. The give
  # windows the driven device's page, so the window covers its kindless siblings'
  # registers too, as the root's window does for the system domain: sharing inside a
  # domain is the domain's business (docs/design-shared-devices.md, "The unit rule").
  # A configured row holds it, and its creation plans.
  def test_a_configured_row_holds_a_driven_device_sharing_a_page_with_one_of_no_kind
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/soc/spi@a003080', 'base' => net.first.fetch('base') + 0x80, 'size' => 64,
                           'role' => 'ordinary', 'compatible' => 'brcm,bcm2835-aux-spi', 'dma' => 'none',
                           'dma_memory' => 0, 'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    assert_equal 1, admit(held).report.fetch('child_plan_instances')
  end

  # A device of no kind is held, not driven, so no give makes DMA memory for it: a row
  # that asks for some would be memory the platform reserves and nothing uses. The view
  # refuses it on whichever domain holds it, the system domain included.
  def test_a_device_of_no_kind_with_dma_memory_fails_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/soc/mmc@a000e00', 'base' => 0x0a000e00, 'role' => 'ordinary',
                           'compatible' => 'brcm,bcm2835-sdhci', 'dma' => 'unconfined', 'dma_memory' => 0x10000,
                           'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, held].each { |source| refused(source, 'view', /a device of a kind no runtime drives has DMA memory/) }
  end

  # A unit of two devices that share a register page, as QEMU virt's virtio-mmio
  # transports 0x200 apart do: a give is the unit's, one register window over the page
  # and one IRQ object per line (docs/design-shared-devices.md, "The unit rule"), so a
  # configured row holds it as the system domain does, and its creation plans.
  def test_a_configured_row_holds_a_unit_whose_devices_share_a_page
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/virtio_mmio@a002c00', 'base' => net.first.fetch('base') - 0x200,
                           'line' => net.first.fetch('line') - 1, 'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    assert_equal 1, admit(held).report.fetch('child_plan_instances')
  end

  # A framebuffer row (docs/design-device-tree.md, "Facts into records"): /chosen and
  # simple-framebuffer, no kind a runtime drives and no line, as the Raspberry Pi 4's
  # record has it, here at 4 MiB clear of QEMU virt's register windows. Its holder's record
  # is the root's framebuffer record over the framebuffer's pages, which the give windows
  # once the root places the framebuffer, so the view admits a configured holder and the
  # library plans the row.
  def test_a_configured_row_holding_a_framebuffer_is_admitted
    assert_equal 1, admit(framebuffer_held).report.fetch('child_plan_instances')
  end

  # A framebuffer row's entry has no range until the root places its framebuffer
  # (erx_dom_view_framebuffer), so its give windows nothing; a framebuffer whose last page
  # lies past the row's 4 MiB window is not placed and leaves none; one 0x2000 bytes 0x400
  # into the window leaves its three whole pages as the one range, never the window; placing
  # the first again takes that range back.
  def test_only_a_placed_framebuffer_leaves_a_range_and_only_its_own_pages
    lines = view_lines(admit(framebuffer_held).bytes, 'framebuffer-ranges', 'framebuffer')
    row = lines.first[/\Aframebuffer (\d+) /, 1]
    assert_equal ["framebuffer #{row} built ranges=", "framebuffer #{row} outside placed=0 ranges=",
                  "framebuffer #{row} inside placed=1 ranges=0x7e000000+0x3000 offset=0x400 size=0x2000",
                  "framebuffer #{row} again placed=0 ranges="], lines
  end

  # The development manifest with the Raspberry Pi 4's framebuffer unit added to QEMU virt's
  # platform, at 4 MiB clear of its register windows, and held by alpha.
  def framebuffer_held
    platform = JSON.parse(JSON.generate(@context.platform))
    pi = JSON.parse(File.read(File.join(ROOT, 'config/platforms/raspi4b.json')))
    framebuffer = pi.fetch('units').find { |unit| unit.fetch('key') == 'framebuffer' }
    framebuffer.fetch('devices').first.merge!('base' => 0x7e00_0000, 'size' => 0x40_0000)
    platform.fetch('units') << framebuffer
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
    ManifestContextFixture.substitute(@source, /^unit net\n  placement "net"\n  holder system\n/,
                                      "\\0unit framebuffer\n  placement \"framebuffer\"\n  holder @domain.alpha\n")
  end

  # A driven device's path is the PATH of the record its holder's creation writes, so the
  # view refuses one that is not a node path the record holds, and no creation fails for
  # it. The manifest check accepts no such path, so the bytes are the development
  # manifest's with the block device's path given a byte no node name holds.
  def test_a_driven_device_s_path_that_is_no_node_path_is_refused
    bytes = development_manifest
    refute_empty bytes.scan('/virtio_mmio@a003e00')
    assert_equal ["refused manifest: a driven device's path is not a node path its record holds"],
                 view_lines(bytes.gsub('/virtio_mmio@a003e00', "/virtio_mmio@a003#00"), 'device-path')
  end

  # What /dev and the domain service read of the root's view of the development
  # manifest as it ships (test/fixtures/dom_view_driver.c): each device's unit name,
  # its kind's compatible string (none for the UARTs, which no runtime drives), its
  # register pages and line, and the storage domain's service with the
  # driver-control interface's number.
  def test_the_view_keeps_what_dev_shows
    lines = view_lines(development_manifest, 'dev')
    page = /ranges=0x[0-9a-f]+000\+0x1000 lines=\d+ confined=0/
    { 'console' => 'none', 'hostlink' => 'none', 'block' => 'virtio,mmio', 'net' => 'virtio,mmio',
      'display' => 'virtio,mmio' }
      .each do |unit, compatible|
        assert(lines.any? { |line| line.match?(/\Adevice \d+ unit=#{unit} compatible=#{compatible} #{page}\z/) },
               "no #{unit} entry in #{lines.inspect}")
      end
    interface = ->(name) { @codec.schema.services.find { |service| service.fetch(:name) == name }.fetch(:number) }
    # The services, in name order, each with its server's index in boot order (display 0,
    # media 1, network 2, pcie 3, storage 4, usb 5, web 6) or none for the system domain, and its interface.
    services = [%w[clock none clock], %w[code_objects none code_objects], %w[data 4 files],
                %w[display 0 windows], %w[home 4 files], %w[inspect none inspect], %w[install none code],
                %w[line none line],
                %w[log none log], %w[login none login], %w[login_keys 4 files], %w[machine none svc], %w[media 1 media],
                %w[media_raw 1 media], %w[net 2 net],
                %w[network_ctl 2 driver_control],
                %w[packages 4 files], %w[pci none pci], %w[pci_bus none pci_bus], %w[pcie 3 pcie],
                %w[start none svc], %w[storage_ctl 4 driver_control],
                %w[system 4 files], %w[usb_input 5 input], %w[web 6 web]]
    assert_equal services.each_with_index.map { |(name, server, kind), index|
                   "service #{index} name=#{name} server=#{server} interface=#{interface.call(kind)}"
                 },
                 lines.grep(/\Aservice /)
  end

  # The display suite's manifest (tools/lib/erx/display_domain.rb), admitted over the
  # fixture's archive with a planner that places nothing, with source's edit applied.
  def display_manifest(edit = ->(source) { source })
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    source = edit.call(Erx::DisplayDomain.manifest(platform.site_manifest_source(ROOT, keep: [Erx::DisplayDomain::DOMAIN])))
    arguments = ManifestContextFixture.manifest_arguments(@codec, source)
    context = Erx::Manifest::Context.new(**arguments.merge(platform: @context.platform))
    planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: planner).bytes
  end

  # The display domain serves display, so its row carries that service's display record, whose
  # words its creation puts in its environment (docs/design-display.md, "A display's
  # session"), and no other row carries one.
  def test_the_display_domain_s_row_carries_its_display_record
    lines = view_lines(display_manifest, 'display')
    server = lines.grep(/\Aservice \d+ name=display /).first[/ server=(\d+) /, 1]
    assert_equal ["display #{server} name=display policy=#{@codec.member('mf_display_policy', 'single')} " \
                  'idle_dim_s=0 idle_off_s=0'], lines.grep(/\Adisplay /)
  end

  # A display domain whose own environment sets a key of its display's is refused, so
  # each key it reads has its display record's value: by the check (property 18), for a
  # key in any position, and by the view as its second line, over bytes the check packed
  # with another key that the test then renames. A key that only starts with display is
  # the row's own.
  def test_a_display_domain_that_sets_its_display_s_keys_is_refused
    with_env = ->(words) { ->(source) { source.sub("domain display\n", "domain display\n  env \"#{words}\"\n") } }
    ['display=other', 'LANG=C display_policy=single', 'LANG=C display_idle_off_s=1', 'display_palette=dark'].each do |words|
      error = assert_raises(Erx::Manifest::Invalid) { display_manifest(with_env.call(words)) }
      assert_equal 'domain.env', error.field, words
    end
    bytes = display_manifest(with_env.call('LANG=C dispXay_policy=single'))
    assert_equal 1, bytes.scan('dispXay_policy=single').size
    assert_equal ['refused manifest: a display domain\'s environment sets a key its display record gives it'],
                 view_lines(bytes.sub('dispXay_policy=single', 'display_policy=single'), 'display-renamed')
    lines = view_lines(display_manifest(with_env.call('displayed=yes display_mode=x')), 'display-own')
    assert_empty lines.grep(/\Arefused /)
    assert_equal 1, lines.grep(/\Adisplay \d+ name=display /).size
  end

  # The qemu-virt development manifest, admitted over the fixture's release image, or
  # with its system window and system_image row taken out.
  def development_source = Erx::Platform.load(root: ROOT, name: 'qemu-virt').manifest_source(ROOT)

  # The source without the record_volume window, and so without the login_keys service its
  # holder serves from it and the facets of that service, which come and go
  # with it (docs/design-ssh.md, "Who publishes it").
  def without_record_volume(source)
    [/^window record_volume\n(?:  .*\n)*/, /^service login_keys\n(?:  .*\n)*/, /^facet login_keys\n(?:  .*\n)*/,
     /^facet login_keys_session\n(?:  .*\n)*/]
      .reduce(source) { |text, record| ManifestContextFixture.substitute(text, record, '') }
  end

  # The source without the system window, and so without the system_image row and the
  # system service its holder serves (property 19), which come and go with it, and
  # without the apps row, which needs that service, and the room it took, and without the
  # record_volume window, which only that holder holds.
  def without_system_image(source)
    [/^window system\n(?:  .*\n)*/, /^system_image\n  input @artifact.release\n/, /^service system\n(?:  .*\n)*/]
      .reduce(without_record_volume(Erx::Manifest::Edit.without_apps(source))) { |text, record| ManifestContextFixture.substitute(text, record, '') }
  end

  # The storage row's packed arguments, its declaration among them.
  def storage_args(source)
    view = @codec.open('manifest', admit_development(source))
    row = view.count('domains').times.map { |at| view.fetch('domains', at) }
              .find { |domain| view.string(domain.fetch('name')) == 'storage' }
    view.string(row.fetch('args'))
  end

  def admit_development(source)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner).bytes
  end

  # The domain library writes -erx_record system_image into the boot page of the configured
  # row that holds the system window alone (docs/design-fiasco.md, "The booted slot"):
  # storage, the server of storage_ctl, carries the system_image row's words, and no other
  # row does, with the record_volume window's name after them when it holds that window too
  # (docs/design-ssh.md, "Who publishes it") and without it when the manifest has none; a
  # manifest with no system window gives the record to no row.
  def test_only_the_system_window_s_holder_carries_the_system_image_record
    lines = view_lines(admit_development(development_source), 'system-image')
    storage = lines.grep(/\Aservice \d+ name=storage_ctl /).first[/ server=(\d+) /, 1]
    tree = ManifestContextFixture.images.fetch('release').fetch('tree')
    record = "system_image #{storage} #{tree.fetch('offset')} #{tree.fetch('offset')} #{tree.fetch('length')} " \
             "#{tree.fetch('salt')} #{tree.fetch('root_hash')}"
    assert_equal ["#{record} record_volume"], lines.grep(/\Asystem_image /)
    assert_equal [record], view_lines(admit_development(without_record_volume(development_source)), 'no-record-volume')
      .grep(/\Asystem_image /)
    assert_empty view_lines(admit_development(without_system_image(development_source)), 'no-system-image').grep(/\Asystem_image /)
  end

  # The view keeps the record's room in the holder's boot page, so a holder whose own
  # arguments leave less than ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX bytes for it, 12 for the flag,
  # 13 for the form, three numbers of 21, two hex words of 65 and 14 for record_volume, is
  # refused at the view, not at its creation: the storage row takes 116 fewer two-byte words
  # when it holds the window, less what its declaration of the services it serves grows by
  # (the system tree's and the packages tree's pairs), and the web row, which does not,
  # takes as many either way.
  def test_the_system_window_s_holder_keeps_room_for_its_record
    room = lambda do |source, domain|
      (0..@codec.constant('boot_strings_max')).bsearch do |count|
        !view_admits?(source.sub(/^(domain #{domain}\n(?:  .*\n)*?  args "[^"]*)"/) { "#{Regexp.last_match(1)}#{' a' * count}\"" })
      end
    end
    without = without_system_image(development_source)
    declared = storage_args(development_source).bytesize - storage_args(without).bytesize
    assert_equal (12 + 13 + (3 * 21) + 65 + 65 + 14 + declared) / 2,
                 room.call(without, 'storage') - room.call(development_source, 'storage')
    assert_equal room.call(without, 'web'), room.call(development_source, 'web')
  end

  # The storage domain mounts the system window through the system_image row's image
  # length, tree and root hash, so neither comes without the other (property 8). The
  # view judges that, so the build refuses either alone through the planner. The row
  # without the window goes without the services and the apps row that need the window.
  def test_the_view_refuses_a_system_window_apart_from_its_row
    rowless = ManifestContextFixture.substitute(development_source, /^system_image\n  input @artifact.release\n/, '')
    windowless = [/^window system\n(?:  .*\n)*/, /^service system\n(?:  .*\n)*/]
                 .reduce(without_record_volume(Erx::Manifest::Edit.without_apps(development_source))) do |text, record|
      ManifestContextFixture.substitute(text, record, '')
    end
    [rowless, windowless].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit_development(source) }
      assert_equal 'view', error.field, error.message
      assert_includes error.message, 'the domain library refuses the manifest\'s view: ' \
                                     'a system window without its system_image row, or the row without the window'
    end
  end

  # The record_volume window is held by the system window's holder (property 8), which
  # the view judges: with the window and its login_keys service moved together, so no
  # source rule fires first, one moved to another configured domain or to the system
  # domain fails the build through the planner.
  def test_the_view_refuses_a_record_volume_window_away_from_the_system_window_s_holder
    { '@domain.web' => "a record_volume window not held by the system window's holder",
      'system' => 'more than one record_volume window, or one held by no configured domain' }.each do |holder, reason|
      source = [[/^(window record_volume\n  holder )@domain\.storage\n/, "\\1#{holder}\n"],
                [/^(service login_keys\n  server )@domain\.storage\n/, "\\1#{holder}\n"],
                [/^facet login_keys\n(?:  .*\n)*/, ''], [/^facet login_keys_session\n(?:  .*\n)*/, '']]
               .reduce(development_source) { |text, (record, with)| ManifestContextFixture.substitute(text, record, with) }
      error = assert_raises(Erx::Manifest::Invalid) { admit_development(source) }
      assert_equal 'view', error.field, error.message
      assert_includes error.message, "the domain library refuses the manifest's view: #{reason}"
    end
  end

  # Whether the boot page holds source's arguments: false for the view's refusal for its
  # reserve, and the check's for arguments past the strings themselves.
  def view_admits?(source)
    admit_development(source)
    true
  rescue Erx::Manifest::Invalid => e
    raise unless %w[view domain.args].include?(e.field)

    false
  end

  def test_a_malformed_input_is_refused_by_the_helper
    manifest = admit(@source).bytes
    head = @codec.encode_layout('erx_image_manifest', ManifestContextFixture.image(@codec))
    paths = %w[manifest heads plan].map { |name| File.join(@directory, "bad-#{name}") }
    [[manifest, '', "order 0 1\n"], [manifest, '', "order 1\n"], [manifest, '', "order 0\norder 0\n"],
     [manifest, head, "file 1 0 0\norder 0\n"], [manifest, '', "file 1 0 56\norder 0\n"],
     [manifest, '', "order 0\nfile 1 0 0\n"], [manifest, '', "order 0\nintroduce 0 1\n"],
     [manifest, '', "order 0\nsession 0\n"], [manifest, '', "session 0\norder 0\n"],
     [manifest, '', "order 0\nsession 0 1\n"], ['short', '', "order 0\n"]].each do |bytes, heads, plan|
      [bytes, heads, plan].zip(paths).each { |content, file| File.binwrite(file, content) }
      assert_raises(Erx::Error, plan) { @helper.run(paths, runner: @runner, name: 'dom-plan-bad', deadline: 30) }
    end
  end

  def test_the_reply_must_hold_one_status_per_domain_introduction_and_session
    assert_equal({ 'domains' => [0, -6], 'introductions' => [-7], 'sessions' => [-12] },
                 Erx::DomainPlanner.statuses("domain 0 0\ndomain 1 -6\nintroduce 0 -7\nsession 0 -12\n",
                                             domains: 2, introductions: 1, sessions: 1))
    ["domain 0 0\ndomain 1 0\nintroduce 0 0\n", "domain 1 0\ndomain 0 0\nintroduce 0 0\nsession 0 0\n",
     "domain 0 0\ndomain 1 x\nintroduce 0 0\nsession 0 0\n", "domain 0 0\nintroduce 0 0\ndomain 1 0\nsession 0 0\n",
     "domain 0 0\ndomain 1 0\nintroduce 1 0\nsession 0 0\n", "domain 0 0\ndomain 1 0\nsession 0 0\nintroduce 0 0\n",
     "domain 0 0\ndomain 1 0\nintroduce 0 0\nsession 1 0\n"].each do |reply|
      assert_raises(Erx::Error, reply) { Erx::DomainPlanner.statuses(reply, domains: 2, introductions: 1, sessions: 1) }
    end
  end

  # Seeded faults in the view's identifier-set order (boot_set_follows): each anchor
  # occurs once in dom_boot_view.c, and each replacement compares lengths first (nv
  # before nusb), orders a name after every longer name it begins, or lets a name follow
  # itself.
  NAMES_MUTANTS = {
    'lengths compared first' =>
      ['order = memcmp(before->bytes, value->bytes, common);',
       'order = before->bytes_len != value->bytes_len ? (before->bytes_len < value->bytes_len ? -1 : 1) : ' \
       'memcmp(before->bytes, value->bytes, common);'],
    'a name after its extensions' =>
      ['(order == 0 && before->bytes_len < value->bytes_len)', '(order == 0 && before->bytes_len > value->bytes_len)'],
    'a name twice' =>
      ['(order == 0 && before->bytes_len < value->bytes_len)', '(order == 0 && before->bytes_len <= value->bytes_len)']
  }.freeze

  # An identifier set's packed rows, a ble grant's services, which the
  # view takes only in strictly ascending byte order, a name before every longer name it
  # begins (docs/design-abi.md, "Services, facets and their parameter schemas"): it takes
  # nus, nusb, nv as the packer writes them, and refuses each other order of those rows
  # and a forged set with nus twice. Each seeded fault of NAMES_MUTANTS changes a verdict.
  def test_the_view_takes_an_identifier_set_only_in_byte_order
    manifests = names_manifests
    refusal = 'refused manifest: a facet parameter set is unsorted or repeats a value'
    expected = manifests.to_h { |name, _| [name, name == 'nus nusb nv' ? 'taken' : refusal] }
    assert_equal expected, names_verdicts(self.class.view_driver, manifests)
    source = File.read(File.join(ROOT, 'liberx/system/dom_boot_view.c'))
    NAMES_MUTANTS.each_with_index do |(name, (anchor, replacement)), index|
      assert_equal 1, source.scan(anchor).size, "the seed #{name} no longer applies"
      seeded = File.join(@directory, "dom_boot_view_names_#{index}.c")
      File.write(seeded, source.sub(anchor, replacement))
      driver = self.class.view_driver_from(seeded, name: "dom-view-names-#{index}")
      refute_equal expected, names_verdicts(driver, manifests), "seeded fault not caught: #{name}"
    end
  end

  # The manifest whose facet nm states nus, nusb, nv, by the order of its packed set, then
  # each forgery of it: the three rows of nm's parameter span in each other order, and nus
  # in place of nusb.
  def names_manifests
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: Erx::Platform.load(root: ROOT, name: 'qemu-virt').record,
                                                                                            gatt_services: ManifestContextFixture::GATT_NAMES))
    packed = Erx::Manifest.admit(source: with_domains('alpha', 'beta') + ManifestContextFixture.ble_grant(%w[nus nusb nv]),
                                 codec: @codec, context: context, planner: ManifestContextFixture.accepting_planner).bytes
    view = @codec.open('manifest', packed)
    facet = view.count('facets').times.map { |at| view.fetch('facets', at) }.find { |row| view.string(row.fetch('name')) == 'nm' }
    span = facet.fetch('parameters')
    size = @codec.layout_size('erx_mf_parameter')
    assert_equal 3, span.fetch('count')
    first = span.fetch('offset')
    rows = %w[nus nusb nv].each_with_index.to_h { |name, at| [name, packed.byteslice(first + (at * size), size)] }
    forged = ->(order) { packed.dup.tap { |copy| copy[first, 3 * size] = order.map { |name| rows.fetch(name) }.join } }
    rows.keys.permutation.to_h { |order| [order.join(' '), forged.call(order)] }
        .merge('nus nus nv' => forged.call(%w[nus nus nv]))
  end

  # Each manifest's verdict by driver: its refusal, or taken.
  def names_verdicts(driver, manifests)
    manifests.to_h do |name, bytes|
      first = view_lines(bytes, "names-#{name.tr(' ', '-')}", driver: driver).first
      [name, first.start_with?('refused ') ? first : 'taken']
    end
  end
end
