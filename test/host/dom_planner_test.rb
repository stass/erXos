# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/display_domain'
require_relative '../../tools/lib/erx/dom_planner'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/net_device'
require_relative '../../tools/lib/erx/network_domain'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/system_domain'
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
           "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
           "  peer_held 4096\n  peer_held_total 4096\n"
  DOMAINS = "#{LIMITS}domain alpha\n  principal @principal.system\n  limits @limits.app\n  kind service\n" \
            "  flags none\n  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n"
  UNCAPPED = "share wide\n  quota_ns uncapped\n  period_ns 10000000\n  cpuset 15\n  capacity_mcpu 1000\n" \
             "  capacity_first 0\n  slice_us 1000\n  grace_us 5\n  base 16\n  ceiling 31\n  flags none\n"
  NARROW = UNCAPPED.sub('share wide', 'share narrow').sub('quota_ns uncapped', 'quota_ns 5000000')

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    @plain = ManifestContextFixture.sessionless(File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt')))
    @source = with_domains('alpha')
    @directory = Dir.mktmpdir('dom-planner-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    tools = Erx::PackTools.build(root: ROOT, owner_root: @directory, directory: File.join(@directory, 'tools'),
                                 runner: @runner, compiler: ENV.fetch('ERX_CLANG', 'clang'))
    @helper = tools.fetch('domains')
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

  def development_manifest
    source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner).bytes
  end

  # The view's catalogue and services, or its refusal, as test/fixtures/dom_view_driver.c prints them,
  # or with mode framebuffer its framebuffer rows' ranges before and after placement.
  def view_lines(manifest, name, *mode)
    @view_driver ||= File.join(@directory, 'dom-view').tap do |output|
      sources = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/system/dom_boot_view.c liberx/erx_lane.c
                   liberx/backend/core/boot_manifest.c
                   tools/host/input.c test/fixtures/dom_view_driver.c].map { |path| File.join(ROOT, path) }
      @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror',
                   '-O1', *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'),
                   '-I', ROOT, '-I', File.join(ROOT, 'tools/host'), *sources,
                   Erx::Generated.path('liberx/generated/abi_reader.c', root: ROOT), '-o', output],
                  name: 'dom-view-build', deadline: 120)
    end
    path = File.join(@directory, "view-#{name}.bin")
    File.binwrite(path, manifest)
    File.readlines(@runner.run([@view_driver, path, *mode], name: "dom-view-#{name}", deadline: 30).fetch('log'), chomp: true)
  end

  # source with the machine's max_connections set to count; raises when the manifest
  # has no such row, so a manifest change cannot quietly disable a test.
  def with_max_connections(source, count)
    ManifestContextFixture.substitute(source, /^(  max_connections )\d+$/, "\\1#{count}")
  end

  def refused(source, field, message)
    error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
    assert_equal [12, field], [error.property, error.field], error.message
    assert_match message, error.message
  end

  def test_the_library_plans_a_configured_domain
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
  end

  # The development manifest as it ships, with its session template and its own
  # configured domains, storage, which holds the block unit, network, which holds the net
  # unit, web, and display, which holds the display unit: the library plans all four, and
  # the system domain's arguments start no stack.
  def test_the_library_plans_the_development_manifests_domains
    source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    assert_equal 4, Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
                                 .report.fetch('child_plan_instances')
    refute_includes source[/^  system_args .*$/], '-erx_net'
    assert_includes source, "unit net\n  placement \"net\"\n  holder @domain.network\n"
    assert_includes source, "unit display\n  placement \"display\"\n  holder @domain.display\n"
  end

  # The production image's narrow manifest (ProductionImage::Run.narrow_manifest), which
  # its 4-CPU cells boot: the system share on two CPUs, and the storage, web and display
  # domains' grants, which must fit the system share, on them too, so the library plans
  # them.
  def test_the_library_plans_the_narrow_images_domain
    source = Erx::ProductionImage::Run.narrow_manifest(ROOT, platform: PLATFORM)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @context.platform))
    assert_equal 3, Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: @planner)
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

  # The network domain cell's manifest (NetworkDomain.manifest), the development manifest
  # with the network row's restarts at 0, on the medium machine: the library plans it.
  def test_the_library_plans_the_network_domain_cells_domains
    source = PLATFORM.manifest_source(ROOT)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                                .merge(platform: Erx::MediumBoot.machine(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: Erx::NetworkDomain.manifest(source), codec: @codec, context: context,
                                   planner: @planner)
    assert_equal 4, admitted.report.fetch('child_plan_instances')
  end

  # The net_device suite's manifest (NetDevice.manifest), the development manifest with
  # the network row on BeamAsm and the storage row still on the interpreter: the library
  # plans it on the development machine the suite boots, and only the network row changed.
  def test_the_library_plans_the_net_device_suites_beamasm_network_row
    source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
    edited = Erx::NetDevice.manifest(source)
    assert_equal '@artifact.jit', edited[/^domain network\n(?:  .*\n)*?  runtime (\S+)$/, 1]
    assert_equal '@artifact.emu', edited[/^domain storage\n(?:  .*\n)*?  runtime (\S+)$/, 1]
    assert_equal source.lines.size, edited.lines.size
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                                .merge(platform: Erx::ProductionImage::Machine.development(PLATFORM).record))
    admitted = Erx::Manifest.admit(source: edited, codec: @codec, context: context, planner: @planner)
    assert_equal 4, admitted.report.fetch('child_plan_instances')
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

  # A template is no configured domain: alpha is the one domain the boot plans.
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
    assert_equal [17, 'start'], [error.property, error.field], error.message
    assert_match(/session of start row guest with nomem\b/i, error.message)
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
    assert_equal [17, 'start'], [error.property, error.field], error.message
    assert_match(/session of start row system with nomem\b/i, error.message)
    alone = fixture.substitute(source, memory, "\\1#{domain}")
    error = assert_raises(Erx::Manifest::Invalid) { admit(alone) }
    assert_equal [17, 'machine.console'], [error.property, error.field], error.message
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
      assert_match(/\Arefused manifest: the session templates are not one per principal in principal order\n\z/,
                   File.binread(record.fetch('log')))
    end
  end

  # A facet the check admits reaches the root's view; one granted to its service's own
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

  # Two facets of one service name to one grantee, which the check never writes: the
  # view refuses them, since the domain service would refuse them at boot. Facet ab
  # grants alpha beta's b, facet bc grants beta gamma's c, also named b, and the
  # patch makes alpha bc's grantee.
  def test_two_facets_of_one_service_name_to_one_grantee_are_refused_by_the_view
    facet = lambda do |name, grantee, service|
      "facet #{name}\n  grantee @domain.#{grantee}\n  service @service.#{service}\n  operations none\n" \
        "  max_request 1\n  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
    end
    services = "service b\n  server @domain.beta\n  interface 1\nservice c\n  name \"b\"\n  server @domain.gamma\n  interface 1\n"
    manifest = admit(with_domains('alpha', 'beta', 'gamma', share: 'narrow') + NARROW + services +
                     facet.call('ab', 'alpha', 'b') + facet.call('bc', 'beta', 'c')).bytes
    offset = @codec.open('manifest', manifest).header.fetch('facets').fetch('offset')
    paths = %w[manifest heads plan].map { |name| File.join(@directory, "facets-#{name}") }
    bytes = manifest.dup.tap { |copy| copy[offset + 80 + 8, 4] = [0].pack('V') }
    [bytes, '', "order 2\norder 1\norder 0\n"].zip(paths).each { |content, file| File.binwrite(file, content) }
    record = @helper.run(paths, runner: @runner, name: 'dom-plan-facets', deadline: 30)
    assert_match(/\Arefused manifest: a grantee takes two facets of one service name\n\z/, File.binread(record.fetch('log')))
  end

  # The Ruby check takes any byte count; the library takes only whole pages.
  def test_a_budget_the_library_refuses_fails_the_build
    error = assert_raises(Erx::Manifest::Invalid) { admit(@source.sub("limits app\n  memory 4194304", "limits app\n  memory 4194305")) }
    assert_equal 12, error.property
    assert_match(/alpha with inval/, error.message)
  end

  # Two grants whose exact rates sum to 2.25 CPUs, what system's 3 CPUs keep past the
  # reserve, which the library's thousandths, each rounded up, put one over: planned in
  # boot order against the first's record, the second is refused.
  def test_grants_within_the_reserve_only_in_exact_arithmetic_fail_the_build
    shares = { 'up' => 11_250_001, 'down' => 11_249_999 }.map do |name, quota|
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).then do |arguments|
      arguments.merge(platform: @context.platform,
                      catalog: arguments.fetch(:catalog).map { |row| row.fetch('path') == 'runtimes/emu' ? row.except('image') : row })
    end)
    assert_equal 12, assert_raises(Erx::Manifest::Invalid) { admit(@source) }.property
  end

  # The seed the shared builder exists for: a principal the Ruby check admits but
  # erx_dom_principal_check refuses (memory not a whole number of pages), which ended
  # the machine at boot while the check planned from a view of its own. Without
  # configured domains too, since a build always plans.
  def test_a_principal_the_library_refuses_fails_the_build
    [@plain, @source].each do |source|
      principal = source.sub(/^(principal system\n(?:  .*\n)*?  memory )(\d+)$/) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) - 1}" }
      refute_equal source, principal
      error = assert_raises(Erx::Manifest::Invalid) { admit(principal) }
      assert_equal [12, 'view'], [error.property, error.field], error.message
      assert_match(/refuses a principal/, error.message)
    end
  end

  # The boot page's strings hold both node names beside a row's arguments and
  # environment, and a -erx given record per device the row holds, so a row whose
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
      assert_equal [12, 'view'], [error.property, error.field], error.message
      assert_match(/reserve/, error.message)
    end
  end

  # The device of the platform record's unit key, the record's units having one each.
  def device_of(platform, key) = platform.fetch('units').find { |unit| unit.fetch('key') == key }.fetch('devices').first

  # Every checked-in manifest over its own board's platform record: the view relates the
  # board's devices by page and by line (docs/design-shared-devices.md, "The unit rule"),
  # and every unit the records list is closed under both, the Raspberry Pi 4's five
  # PL011s on one page and line, and its mini UART and auxiliary SPI controllers, included.
  def test_every_checked_in_manifest_keeps_its_units_whole
    manifests = Dir[File.join(ROOT, 'config/manifest/*.txt')]
    assert_operator manifests.size, :>=, 3
    manifests.each do |path|
      board = File.basename(path, '.txt').delete_suffix('-development').delete_suffix('-site')
      platform = JSON.parse(File.read(File.join(ROOT, Erx::Platform.record_path(board))))
      context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: platform))
      admitted = Erx::Manifest.admit(source: File.binread(path), codec: @codec, context: context, planner: @planner)
      refute_empty admitted.bytes, path
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    two = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, two].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
      assert_equal [12, 'view'], [error.property, error.field], error.message
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    two = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, two].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
      assert_equal [12, 'view'], [error.property, error.field], error.message
      assert_match(/share an interrupt line are in two units/, error.message)
    end
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    assert_equal 1, admit(held).report.fetch('child_plan_instances')
  end

  # The Raspberry Pi 4's sd unit: EMMC2 and, on its line, the legacy SD controller,
  # whose role and compatible string are in no row of erx/device_kinds.h. A configured
  # row may hold it, as the system domain holds the auxiliary SPI controllers: the
  # kindless device is given its objects with its unit and gets no -erx given record
  # (docs/design-shared-devices.md, "The unit rule"). The view admits that placement.
  def test_a_configured_row_holding_a_device_of_no_kind_is_admitted
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/soc/mmc@a000e00', 'base' => 0x0a000e00, 'role' => 'ordinary',
                           'compatible' => 'brcm,bcm2835-sdhci', 'dma' => 'none', 'dma_memory' => 0,
                           'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, held].each { |source| refused(source, 'view', /a device of a kind no runtime drives has DMA memory/) }
  end

  # A unit of two devices that share a register page, as QEMU virt's virtio-mmio
  # transports 0x200 apart do: the root makes the system domain's windows itself, so
  # the system domain may hold it, but a give windows one device and the library
  # refuses a window over a page another entry's window meets, so every creation of
  # a configured row holding it would fail. The view refuses that placement, and so
  # the build does.
  def test_a_configured_row_holding_a_unit_whose_devices_share_a_page_fails_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    net = platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices')
    net << net.first.merge('path' => '/virtio_mmio@a002c00', 'base' => net.first.fetch('base') - 0x200,
                           'line' => net.first.fetch('line') - 1, 'placement_key' => 'net-second')
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
    held = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    refused(held, 'view', /a configured domain holds share a register page/)
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
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    ManifestContextFixture.substitute(@source, /^unit net\n  placement "net"\n  holder system\n/,
                                      "\\0unit framebuffer\n  placement \"framebuffer\"\n  holder @domain.alpha\n")
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
    # network 1, storage 2, web 3) or none for the system domain: apps, of files, data, of
    # files, display, of windows, inspect, log, net, network_ctl, storage_ctl and web.
    assert_equal ["service 0 name=apps server=none interface=#{interface.call('files')}",
                  "service 1 name=data server=2 interface=#{interface.call('files')}",
                  "service 2 name=display server=0 interface=#{interface.call('windows')}",
                  "service 3 name=inspect server=none interface=#{interface.call('inspect')}",
                  "service 4 name=log server=none interface=#{interface.call('log')}",
                  "service 5 name=net server=1 interface=#{interface.call('net')}",
                  "service 6 name=network_ctl server=1 interface=#{interface.call('driver_control')}",
                  "service 7 name=storage_ctl server=2 interface=#{interface.call('driver_control')}",
                  "service 8 name=web server=3 interface=#{interface.call('web')}"],
                 lines.grep(/\Aservice /)
  end

  # The display suite's manifest (tools/lib/erx/display_domain.rb), admitted over the
  # fixture's archive with a planner that places nothing, with source's edit applied.
  def display_manifest(edit = ->(source) { source })
    platform = Erx::Platform.load(root: ROOT, name: 'qemu-virt')
    arguments = ManifestContextFixture.archive_arguments(@codec, boots: [*%w[display network session storage web], Erx::DisplayDomain::BOOT.name])
    context = Erx::Manifest::Context.new(**arguments.merge(platform: @context.platform))
    planner = ->(view) { %w[domains introductions sessions].to_h { |key| [key, view.fetch(key == 'domains' ? 'order' : key).map { 0 }] } }
    source = edit.call(Erx::DisplayDomain.manifest(platform.site_manifest_source(ROOT), platform: platform))
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: planner).bytes
  end

  # The display domain serves screen, so its row carries screen's display record, whose
  # words its creation puts in its environment (docs/design-display.md, "A display's
  # session"), and no other row carries one.
  def test_the_display_domain_s_row_carries_its_display_record
    lines = view_lines(display_manifest, 'display')
    server = lines.grep(/\Aservice \d+ name=screen /).first[/ server=(\d+) /, 1]
    assert_equal ["display #{server} name=screen policy=#{@codec.member('mf_display_policy', 'single')} " \
                  'idle_dim_s=0 idle_off_s=0'], lines.grep(/\Adisplay /)
  end

  # A display domain whose own environment sets a key of its display's is refused, so
  # each key it reads has its display record's value: by the check (property 18), for a
  # key in any position, and by the view as its second line, over bytes the check packed
  # with another key that the test then renames. A key that only starts with display is
  # the row's own.
  def test_a_display_domain_that_sets_its_display_s_keys_is_refused
    with_env = ->(words) { ->(source) { source.sub("domain display\n", "domain display\n  env \"#{words}\"\n") } }
    ['display=other', 'LANG=C display_policy=rio', 'LANG=C display_idle_off_s=1'].each do |words|
      error = assert_raises(Erx::Manifest::Invalid) { display_manifest(with_env.call(words)) }
      assert_equal [18, 'domain.env'], [error.property, error.field], words
    end
    bytes = display_manifest(with_env.call('LANG=C dispXay_policy=rio'))
    assert_equal 1, bytes.scan('dispXay_policy=rio').size
    assert_equal ['refused manifest: a display domain\'s environment sets a key its display record gives it'],
                 view_lines(bytes.sub('dispXay_policy=rio', 'display_policy=rio'), 'display-renamed')
    lines = view_lines(display_manifest(with_env.call('displayed=yes display_mode=x')), 'display-own')
    assert_empty lines.grep(/\Arefused /)
    assert_equal 1, lines.grep(/\Adisplay \d+ name=screen /).size
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
end
