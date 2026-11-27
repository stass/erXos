# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/platform'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

# Phase 1's manifest check over configured domains (docs/design-fiasco.md, "The
# Phase 1 manifest check"): the kept properties a domain row brings, each with a
# seeded violation, and the refusals it adds, each with a seeded record. Every seed
# edits the real development manifest with two configured domains, alpha and beta,
# added, so a seed fails for its own reason. A recording planner stands in for the
# domain library's host build, which test/host/dom_planner_test.rb runs.
class ManifestDomainsTest < Minitest::Test
  APP_LIMITS = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
               "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n  band app\n" \
               "  peer_held 4096\n  peer_held_total 4096\n"

  # Each domain's status, in boot order, and each introduction's; [] plans them all,
  # and every session.
  class RecordingPlanner
    attr_reader :views

    def initialize(statuses = [], introductions: [])
      @statuses = statuses
      @introductions = introductions
      @views = []
    end

    def call(view)
      @views << view
      { 'domains' => view.fetch('order').each_index.map { |index| @statuses.fetch(index, 0) },
        'introductions' => view.fetch('introductions').each_index.map { |index| @introductions.fetch(index, 0) },
        'sessions' => view.fetch('sessions').map { 0 } }
    end
  end

  def self.domain(name, flags: 'none', kind: 'service', runtime: '@artifact.emu', release: '@artifact.app')
    "domain #{name}\n  principal @principal.system\n  limits @limits.app\n  kind #{kind}\n  flags #{flags}\n" \
      "  runtime #{runtime}\n  release #{release}\n  restarts 3\n  restart_period_s 5\n"
  end

  def setup
    root = File.expand_path('../..', __dir__)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root)))
    # The tests write their own session templates, of the manifest's session profile.
    @plain = ManifestContextFixture.sessionless(Erx::Platform.load(root: root, name: 'qemu-virt').manifest_source(root))
    @platform = Erx::Platform.load(root: root, name: 'qemu-virt').record
    @source = with_domains(self.class.domain('alpha'), self.class.domain('beta', flags: 'rescue'))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @platform))
    @planner = RecordingPlanner.new
  end

  # The rows, with the system principal's domain quota covering them, and max_domains
  # the sum of the quotas, as property 4 asks.
  def with_domains(*rows)
    ManifestContextFixture.with_quota(@plain, rows.size) + APP_LIMITS + rows.join
  end

  def admit(source = @source, planner: @planner, context: @context)
    Erx::Manifest.admit(source: source, codec: @codec, context: context, planner: planner)
  end

  def refused(klass, field, source = @source, planner: @planner, message: nil)
    error = assert_raises(klass) { admit(source, planner: planner) }
    assert_equal field, error.field, error.message
    assert_match message, error.message if message
    error
  end

  def service(name, server)
    "service #{name}\n  server #{server}\n  interface 1\n"
  end

  def facet(name, grantee, service)
    "facet #{name}\n  grantee #{grantee}\n  service #{service}\n  operations none\n  max_request 1\n" \
      "  in_flight 1\n  reductions 1\n  period_ns 1\n  max_heap_size 1\n"
  end

  # A facet of a windows service, an erx_fs grant of a tree, whose max_request is
  # property 16's files floor.
  def window_facet(name, grantee, service)
    facet(name, grantee, service).sub("  max_request 1\n", "  max_request #{@codec.constant('files_max_frame_min')}\n")
  end

  def rows(view, table) = view.count(table).times.map { |index| view.fetch(table, index) }

  def test_configured_domains_reach_the_encoded_manifest_in_name_order
    view = @codec.open('manifest', admit(@source.sub('domain alpha', 'domain gamma')).bytes)
    domains = rows(view, 'domains')
    assert_equal %w[beta gamma], domains.map { |row| view.string(row.fetch('name')) }
    emu = @context.artifacts.fetch('emu').fetch('entry')
    assert_equal [[emu, 0, @context.artifacts.fetch('app').fetch('files')]] * 2, domains.map { |row| row.values_at('runtime', 'release', 'release_files') }
    assert_equal [@codec.member('mf_domain_flags', 'rescue'), 0], domains.map { |row| row.fetch('flags') }
    assert_equal [[3, 5]] * 2, domains.map { |row| row.values_at('restarts', 'restart_period_s') }
    assert_equal [0, 1], rows(view, 'boot_order').map { |row| row.fetch('domain') }
    assert_equal 2, view.header.fetch('max_domains')
  end

  # The machine's boot_timeout_s, which every configured domain takes, reaches the
  # encoded header; a machine without one gets boot_timeout_default_s; 0 and anything
  # past boot_timeout_max_s are refused. A domain row takes no boot timeout of its own.
  def test_the_machines_boot_timeout_is_its_own_or_the_default_within_bounds
    stated = ->(seconds) { @source.sub(/^(  max_connections \d+\n)/) { "#{Regexp.last_match(1)}  boot_timeout_s #{seconds}\n" } }
    assert_equal 600, @codec.open('manifest', admit(stated.call(600)).bytes).header.fetch('boot_timeout_s')
    assert_equal @codec.constant('boot_timeout_default_s'), @codec.open('manifest', admit.bytes).header.fetch('boot_timeout_s')
    [0, @codec.constant('boot_timeout_max_s') + 1].each do |seconds|
      refused(Erx::Manifest::Invalid, 'machine.boot_timeout_s', stated.call(seconds),
              message: /boot timeout of #{seconds} s is outside/)
    end
    error = assert_raises(Erx::ABI::SchemaError) do
      admit(@source.sub("  restart_period_s 5\ndomain beta", "  restart_period_s 5\n  boot_timeout_s 90\ndomain beta"))
    end
    assert_match(/unknown or duplicate manifest property/, error.message)
  end

  def test_the_report_counts_the_planned_domains
    assert_equal 2, admit.report.fetch('child_plan_instances')
  end

  # Property 12's view: the packed manifest itself, which the library's own builder
  # reads as the root does; every archive entry with the bytes it will start with, an
  # image its encoded image manifest; the rows in boot order and each introduction's
  # parties as places in that order.
  def test_the_planner_sees_the_packed_manifest_and_the_archive
    admitted = admit("#{@source}introduce @domain.beta @domain.alpha\n")
    view = @planner.views.fetch(0)
    assert_equal admitted.bytes, view.fetch('manifest')
    assert_equal [{ 'a' => 0, 'b' => 1 }], view.fetch('introductions')
    assert_equal [0, 1], view.fetch('order').sort
    assert_equal @context.catalog.map { |row| row.fetch('kind') }, view.fetch('files').map { |file| file.fetch('kind') }
    assert_equal @context.catalog.map { |row| row['image'] ? @codec.encode_layout('erx_image_manifest', row['image']) : '' },
                 view.fetch('files').map { |file| file.fetch('head') }
  end

  def test_a_refused_view_fails_the_build
    error = refused(Erx::Manifest::Invalid, 'view', planner: ->(_view) { { 'refused' => 'manifest: why' } },
                    message: /the domain library refuses the manifest's view: why/)
    assert_match(/refuses the manifest's view: why\z/, error.message)
  end

  def test_a_manifest_without_domains_needs_no_planner
    plain = Erx::Manifest.admit(source: @plain, codec: @codec, context: @context, planner: nil)
    assert_equal 0, plain.report.fetch('child_plan_instances')
  end

  # The system principal's template gives root's console session, which needs the
  # planner (property 17), so without one such a manifest fails closed.
  def test_root_s_console_session_needs_a_planner
    refused(Erx::Manifest::Unsupported, 'planner', @plain + self.class.session, planner: nil,
            message: /configured domains and sessions need the domain library's host/)
  end

  # Property 1: a unit's holder is the system domain or a configured domain.
  def test_a_unit_held_by_a_configured_domain_is_accepted
    source = @source.sub("placement \"block\"\n  holder system", "placement \"block\"\n  holder @domain.beta")
    view = @codec.open('manifest', admit(source).bytes)
    assert_includes rows(view, 'units').map { |row| row.fetch('holder') }, 1
  end

  def test_a_unit_held_by_no_configured_domain_is_refused
    source = @source.sub("placement \"block\"\n  holder system", "placement \"block\"\n  holder @domain.absent")
    refused(Erx::Manifest::Invalid, 'unit.holder', source, message: /names neither the system domain nor a configured domain/)
  end

  # Property 2: services, facets and introductions name what the manifest contains.
  def test_a_service_of_a_configured_domain_is_accepted
    view = @codec.open('manifest', admit(@source + service('probe', '@domain.alpha')).bytes)
    assert_equal [0], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_a_service_of_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 'service.server', @source + service('probe', '@domain.absent'),
            message: /names neither the system domain nor a configured domain/)
  end

  def test_a_facet_naming_no_service_is_refused
    refused(Erx::Manifest::Invalid, 'facet.service', @source + facet('f', '@domain.alpha', '@service.absent'),
            message: /facet names a service the manifest does not contain/)
  end

  def test_a_facet_granted_to_neither_the_system_domain_nor_a_configured_domain_is_refused
    source = @source + service('b', '@domain.beta') + facet('f', '@domain.absent', '@service.b')
    refused(Erx::Manifest::Invalid, 'facet.grantee', source, message: /names neither the system domain, a configured domain nor a/)
  end

  # A configured domain's service granted to another configured domain and to the
  # system domain, the system domain's grantee having no index, and an omitted queue
  # resolved to system_queue; the facets sort by name.
  def test_facets_of_a_configured_domains_service_reach_the_encoded_manifest
    source = @source + service('b', '@domain.beta') + facet('sb', 'system', '@service.b') +
             facet('ab', '@domain.alpha', '@service.b').sub("  max_request 1\n", "  max_request 512\n  queue 4096\n")
    view = @codec.open('manifest', admit(source).bytes)
    facets = rows(view, 'facets')
    assert_equal %w[ab sb], facets.map { |row| view.string(row.fetch('name')) }
    domain, system = %w[domain system].map { |kind| @codec.member('mf_grantee', kind) }
    assert_equal [[domain, 0, 0, 512, 4096], [system, 0, 0, 1, 16_384]],
                 facets.map { |row| row.values_at('grantee_kind', 'grantee', 'service', 'max_request', 'queue') }
    assert_equal [[0, 0]] * 2, facets.map { |row| [row.fetch('operations').fetch('count'), row.fetch('parameters').fetch('count')] }
    assert_equal [1, 0], rows(view, 'boot_order').map { |row| row.fetch('domain') }
  end

  # The system domain takes no facet of its own service. That one grantee takes one
  # facet of a service name, since the registry installs a facet under its service's
  # name, is the boot view's to judge (test/host/dom_planner_test.rb).
  def test_a_facet_of_the_system_domains_own_service_to_it_is_refused
    refused(Erx::Manifest::Invalid, 'facet.grantee', @source + service('probe', 'system') + facet('f', 'system', '@service.probe'),
            message: /the system domain takes no facet of its own service/)
  end

  # Property 8: a facet of the driver-control interface stops and starts the drivers of
  # its server's units, so only the system domain holds one, however the service row
  # spells the interface; its service row keeps the declared number.
  def test_a_driver_control_facet_goes_to_the_system_domain_alone
    control = service('ctl', '@domain.beta').sub('interface 1', 'interface driver_control')
    view = @codec.open('manifest', admit(@source + control + facet('ctl', 'system', '@service.ctl')).bytes)
    assert_equal [2], rows(view, 'services').map { |row| row.fetch('interface') }
    [control, control.sub('interface driver_control', 'interface 2')].each do |row|
      refused(Erx::Manifest::Invalid, 'facet.grantee', @source + row + facet('ctl', '@domain.alpha', '@service.ctl'),
              message: /only the system domain holds a driver-control facet/)
    end
  end

  # A facet row of the code_objects interface is refused whoever its grantee, a
  # configured domain or a template: the domain service grants every session that facet
  # itself, with its own limits.
  def test_a_code_objects_facet_row_is_refused
    objects = service('code_objects', 'system').sub('interface 1', 'interface code_objects')
    assert_equal [14], rows(@codec.open('manifest', admit(@source + objects).bytes), 'services').map { |row| row.fetch('interface') }
    { @source => '@domain.alpha', with_session(self.class.session) => '@session.system' }.each do |source, grantee|
      refused(Erx::Manifest::Invalid, 'facet.service', source + objects + facet('objects', grantee, '@service.code_objects'),
              message: /no facet row grants code_objects, which the domain service/)
    end
  end

  # The code_objects service is served once, under that name, by the system domain: the
  # name and server the domain service grants every session's facet under.
  def test_the_code_objects_service_is_the_system_domain_s_alone
    objects = service('code_objects', 'system').sub('interface 1', 'interface code_objects')
    [objects.sub('server system', 'server @domain.alpha'), objects.sub('service code_objects', 'service objects'),
     objects + objects.sub('service code_objects', 'service objects')].each do |row|
      refused(Erx::Manifest::Invalid, 'service.interface', @source + row,
              message: /the manifest serves code_objects once, by that name, from the/)
    end
  end

  def test_an_interface_name_no_fragment_declares_is_refused
    source = @source + service('ctl', '@domain.beta').sub('interface 1', 'interface driver_ctl')
    error = assert_raises(Erx::ABI::SchemaError) { admit(source) }
    assert_match(/interface names no service/, error.message)
  end

  # A grant of the inspect interface (abi/services/inspect.txt: inspect 1, entries 2),
  # served by the system domain, to the system principal's session template, naming
  # operations.
  def inspect_grant(operations)
    inspect = service('i', 'system').sub('interface 1', 'interface inspect')
    with_session(self.class.session) + inspect +
      facet('i', '@session.system', '@service.i').sub('operations none', "operations #{operations}")
  end

  # A facet's operations resolve against its interface's declarations into its span of
  # facet_operations, in ascending number order whatever the order the row names them.
  def test_a_facet_s_operations_are_packed_as_their_numbers
    view = @codec.open('manifest', admit(inspect_grant('entries,inspect')).bytes)
    facet = rows(view, 'facets').find { |row| view.string(row.fetch('name')) == 'i' }
    span = facet.fetch('operations')
    first = (span.fetch('offset') - view.header.fetch('facet_operations').fetch('offset')) / 4
    assert_equal [1, 2], span.fetch('count').times.map { |at| view.fetch('facet_operations', first + at).fetch('operation') }
    assert_equal [2], rows(@codec.open('manifest', admit(inspect_grant('entries')).bytes), 'facet_operations')
      .map { |row| row.fetch('operation') }
  end

  def test_a_facet_naming_an_undeclared_or_repeated_operation_is_refused
    %w[set inspect,set inspect,inspect inspect, ,inspect].each do |operations|
      refused(Erx::Manifest::Invalid, 'facet.operations', inspect_grant(operations), message: /facet i's operations name/)
    end
  end

  # Only the system domain's erx_facet checks a grant's operations (docs/design-time.md,
  # "On Fiasco"), so a row naming operations of a service a configured domain serves is
  # refused, as is one of a tree, whose interfaces declare none.
  def test_operations_only_the_system_domain_checks_are_accepted
    web = "service w\n  server @domain.beta\n  interface web\n"
    named = facet('w', '@domain.alpha', '@service.w').sub('operations none', 'operations data')
    refused(Erx::Manifest::Unsupported, 'facet.operations', @source + web + named,
            message: /a service a configured domain serves/)
    files = "service f\n  server @domain.beta\n  interface files\n"
    tree = window_facet('f', '@domain.alpha', '@service.f').sub('operations none', 'operations read')
    refused(Erx::Manifest::Invalid, 'facet.operations', @source + files + tree, message: /does not declare/)
  end

  def test_introductions_are_written_once_lower_index_first
    view = @codec.open('manifest', admit("#{@source}introduce @domain.beta @domain.alpha\n").bytes)
    assert_equal [[0, 1]], rows(view, 'introductions').map { |row| row.values_at('from', 'to') }
  end

  def test_an_introduction_of_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 'introduce', "#{@source}introduce @domain.alpha @domain.absent\n",
            message: /introduction names no configured domain/)
  end

  def test_an_introduction_of_a_domain_to_itself_is_refused
    refused(Erx::Manifest::Invalid, 'introduce', "#{@source}introduce @domain.alpha @domain.alpha\n",
            message: /an introduction joins two different domains/)
  end

  def test_one_pair_introduced_twice_is_refused
    source = "#{@source}introduce @domain.alpha @domain.beta\nintroduce @domain.beta @domain.alpha\n"
    refused(Erx::Manifest::Invalid, 'introduce', source, message: /two introductions join one pair/)
  end

  # Property 4: every living domain, configured or requested, is one of its
  # principal's quota, so the quotas alone sum within max_domains; the configured
  # domains' budgets and grants are the planner's (test/host/dom_planner_test.rb).
  def test_principal_quotas_over_max_domains_are_refused
    refused(Erx::Manifest::Invalid, 'principals.domains', @source.sub('max_domains 2', 'max_domains 1'),
            message: /principal domain quotas and the apps row's max exceed/)
  end

  # Property 5 over the configured domains and the services they serve.
  def test_a_domain_with_a_pooled_name_is_refused
    refused(Erx::Manifest::Invalid, 'domain.name', @source.sub('domain alpha', 'domain alice_1'),
            message: /a configured domain's name has a pooled name's form/)
  end

  def test_a_domain_name_with_a_dot_is_refused
    error = assert_raises(Erx::ABI::SchemaError) { admit(@source.sub('domain alpha', 'domain a.b')) }
    assert_match(/needs one identifier/, error.message)
  end

  def test_a_domain_named_as_a_principal_is_refused
    refused(Erx::Manifest::Invalid, 'domain.name', @source.sub('domain alpha', 'domain system'),
            message: /a configured domain shares a principal's name/)
  end

  def test_one_name_on_two_servers_is_accepted
    source = @source + service('probe_a', '@domain.alpha').sub('service probe_a', "service probe_a\n  name \"probe\"") +
             service('probe_b', '@domain.beta').sub('service probe_b', "service probe_b\n  name \"probe\"")
    view = @codec.open('manifest', admit(source).bytes)
    assert_equal [0, 1], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_one_name_twice_on_one_server_is_refused
    source = @source + service('probe_a', '@domain.alpha').sub('service probe_a', "service probe_a\n  name \"probe\"") +
             service('probe_b', '@domain.alpha').sub('service probe_b', "service probe_b\n  name \"probe\"")
    refused(Erx::Manifest::Invalid, 'service.name', source, message: /two services of one server share a name/)
  end

  # Property 8: the console lines and the slot writer's windows stay the system domain's.
  def test_a_console_uart_held_by_a_configured_domain_is_refused
    %w[console hostlink].each do |unit|
      source = @source.sub(/(unit #{unit}\n  placement "[^"]*"\n)  holder system/, "\\1  holder @domain.alpha")
      refused(Erx::Manifest::Invalid, "machine.#{unit}", source, message: /UART is not assigned to the system domain/)
    end
  end

  def test_a_slot_window_held_by_a_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 'window.holder', @source.sub("window boot_a\n  holder system", "window boot_a\n  holder @domain.alpha"),
            message: /only the system domain, the slot writer, holds the slot windows/)
  end

  def test_a_domain_named_system_is_refused
    source = @source.sub('principal system', 'principal root').gsub('@principal.system', '@principal.root').sub('domain alpha', 'domain system')
    refused(Erx::Manifest::Invalid, 'domain.name', source, message: /the system domain's name is not a configured domain's/)
  end

  def test_arguments_and_environment_over_the_boot_page_are_refused
    long = "  args \"#{'a' * 1500}\"\n  env \"X=#{'b' * 1500}\"\n"
    refused(Erx::Manifest::Invalid, 'domain.args', with_domains(self.class.domain('alpha') + long),
            message: /arguments and environment exceed the boot page's strings/)
  end

  # A row's release names a boot script of the domain release, and the packer binds it:
  # the packed arguments are the row's emulator flags, then -- -boot /bin/<name> --,
  # then the row's declaration (docs/design-system.md, "The declaration"; none served
  # here), then its init arguments, so the binding is init's first flag and no later word
  # (-extra, a final -S) can make it a plain argument. A row whose own arguments name
  # -boot is refused, so no row boots a script its release does not name.
  def test_a_domain_boots_the_script_its_release_names
    serves = "-erx_serves\0--\0"
    { '-x y' => "-x\0y\0--\0-boot\0/bin/app\0--\0#{serves}",
      '-x -- -nouser -extra a' => "-x\0--\0-boot\0/bin/app\0--\0#{serves}-nouser\0-extra\0a\0" }.each do |args, packed|
      view = @codec.open('manifest', admit(with_domains(self.class.domain('alpha') + "  args \"#{args}\"\n")).bytes)
      assert_equal packed, view.string(rows(view, 'domains').fetch(0).fetch('args'))
    end
  end

  def test_a_domain_naming_boot_is_refused
    ['-boot /bin/session', '-x -boot /bin/app'].each do |args|
      refused(Erx::Manifest::Invalid, 'domain.args', with_domains(self.class.domain('alpha') + "  args \"#{args}\"\n"),
              message: /-boot/)
    end
  end

  def test_a_session_template_boots_the_script_its_release_names
    view = @codec.open('manifest', admit(with_session(self.class.session)).bytes)
    assert_equal "-x\0y\0--\0-boot\0/bin/app\0--\0", view.string(rows(view, 'sessions').fetch(0).fetch('args'))
    refused(Erx::Manifest::Invalid, 'session.args', with_session(self.class.session.sub('-x y', '-boot /bin/app')),
            message: /-boot/)
  end

  # Property 7: no secret domain, since no entry carries the sealing secret.
  def test_a_secret_domain_is_refused_naming_its_milestone
    refused(Erx::Manifest::Invalid, 'domain.kind', with_domains(self.class.domain('vault', kind: 'secret')), message: /M11/)
  end

  # A window's holder is the system domain or a configured domain.
  def test_a_window_held_by_a_configured_domain_is_accepted
    source = @source.sub("window data\n  holder system", "window data\n  holder @domain.alpha")
    view = @codec.open('manifest', admit(source).bytes)
    assert_includes rows(view, 'windows').map { |row| row.fetch('holder') }, 0
  end

  # Property 10: the facets of the configured domains lead back to none of them.
  def test_facets_that_lead_back_are_refused
    source = @source + service('a', '@domain.alpha') + service('b', '@domain.beta') +
             facet('ab', '@domain.alpha', '@service.b') + facet('ba', '@domain.beta', '@service.a')
    refused(Erx::Manifest::Invalid, 'facet.service', source, message: /a configured domain's facets lead back to it/)
  end

  def test_a_domain_holding_a_facet_of_its_own_service_is_refused
    source = @source + service('a', '@domain.alpha') + facet('aa', '@domain.alpha', '@service.a')
    refused(Erx::Manifest::Invalid, 'facet.service', source, message: /a configured domain's facets lead back to it/)
  end

  # The order places every server before its clients and breaks ties by name order.
  def test_the_boot_order_puts_servers_first_and_names_break_ties
    parsed = Erx::Manifest::Frontend.parse(@source, version: @codec.constant('manifest_version'))
    check = Erx::Manifest::Check.new(parsed, codec: @codec, context: @context, planner: nil)
    none = @codec.constant('mf_none')
    order = check.send(:boot_order, [{}, {}, {}, {}], [[0, 2], [2, 1], [3, none]])
    assert_equal [1, 2, 0, 3], order.map { |row| row.fetch('domain') }
  end

  # Property 11: a rescue domain takes facets only of the system domain and of other
  # rescue domains.
  def test_a_rescue_domain_on_a_domain_rescue_does_not_start_is_refused
    source = @source + service('a', '@domain.alpha') + facet('ba', '@domain.beta', '@service.a')
    refused(Erx::Manifest::Invalid, 'facet.service', source, message: /a rescue domain names a service of a domain the rescue/)
  end

  # A facet of a service the system domain serves, granted to a configured domain,
  # reaches the encoded manifest, which the domain service reads at boot.
  def test_a_system_served_facet_of_a_rescue_domain_passes_the_rescue_rule_and_is_encoded
    source = @source + service('s', 'system') + facet('bs', '@domain.beta', '@service.s')
    view = @codec.open('manifest', admit(source).bytes)
    services = rows(view, 'services')
    assert_equal [[1, @codec.constant('mf_none')]],
                 rows(view, 'facets').map { |row| [row.fetch('grantee'), services.fetch(row.fetch('service')).fetch('server')] }
  end

  # Property 12: what the domain library refuses fails the build, and without the
  # planner a manifest with domains fails closed.
  def test_a_domain_the_library_refuses_fails_the_build
    error = refused(Erx::Manifest::Invalid, 'domain', planner: RecordingPlanner.new([0, -6]),
                    message: /the domain library refuses configured domain beta with nomem/)
    assert_match(/beta with nomem/, error.message)
  end

  def test_an_introduction_the_library_refuses_fails_the_build
    error = refused(Erx::Manifest::Invalid, 'introduce', "#{@source}introduce @domain.alpha @domain.beta\n",
                    planner: RecordingPlanner.new(introductions: [-7]), message: /the domain library refuses the introduction of alpha and beta/)
    assert_match(/introduction of alpha and beta with limit/, error.message)
  end

  def test_configured_domains_without_a_planner_fail_closed
    refused(Erx::Manifest::Unsupported, 'planner', planner: nil, message: /configured domains and sessions need the domain library's host/)
  end

  def test_a_runtime_that_names_no_executable_is_refused
    refused(Erx::Manifest::Invalid, 'domain.runtime', with_domains(self.class.domain('alpha', runtime: '@artifact.app')),
            message: /runtime names no executable artifact of this pack/)
  end

  def test_a_release_that_names_no_domain_release_is_refused
    %w[@artifact.emu @artifact.absent "app"].each do |release|
      refused(Erx::Manifest::Invalid, 'domain.release', with_domains(self.class.domain('alpha', release: release)),
              message: /release names no release artifact of this pack/)
    end
  end

  def test_a_partial_boot_configures_no_domains
    refused(Erx::Manifest::Invalid, 'domain', @source.sub('flags development', 'flags development,partial_boot'),
            message: /a partial boot configures no domains/)
  end

  # Property 14: a session template is a record of its own table, keyed by its
  # principal's name, which the boot never creates.
  def self.session(principal = 'system', limits: '@limits.session')
    "session #{principal}\n  limits #{limits}\n  runtime @artifact.emu\n  release @artifact.app\n  args \"-x y\"\n"
  end

  def with_session(*sessions) = with_domains(self.class.domain('alpha'), self.class.domain('beta', flags: 'rescue')) + sessions.join

  def test_a_session_template_is_packed_but_neither_ordered_nor_planned
    admitted = admit(with_session(self.class.session))
    view = @codec.open('manifest', admitted.bytes)
    alpha = rows(view, 'domains').fetch(0)
    assert_equal [[0, *alpha.values_at('runtime', 'release', 'release_files')]],
                 rows(view, 'sessions').map { |row| row.values_at('principal', 'runtime', 'release', 'release_files') }
    assert_equal %w[alpha beta], rows(view, 'domains').map { |row| view.string(row.fetch('name')) }
    assert_equal [0, 1], rows(view, 'boot_order').map { |row| row.fetch('domain') }
    assert_equal [0, 1], @planner.views.fetch(0).fetch('order')
    assert_equal 2, admitted.report.fetch('child_plan_instances')
  end

  def test_a_session_template_without_sub_spaces_is_refused
    refused(Erx::Manifest::Invalid, 'session.limits', with_session(self.class.session(limits: '@limits.app')),
            message: /a session template's limits do not enable SPACES/)
  end

  def test_a_session_template_keyed_by_no_principal_is_refused
    refused(Erx::Manifest::Invalid, 'session.name', with_session(self.class.session('alpha')),
            message: /a session template names no principal/)
  end

  def test_two_session_templates_of_one_principal_are_refused
    refused(Erx::Manifest::Invalid, 'session', with_session(self.class.session, self.class.session), message: /duplicate source alias/)
  end

  def test_a_partial_boot_makes_no_sessions
    source = @plain.sub('flags development', 'flags development,partial_boot') + APP_LIMITS + self.class.session
    refused(Erx::Manifest::Invalid, 'session', source, message: /a partial boot makes no sessions/)
  end

  # Holders, servers and introductions resolve through the domain table, which
  # holds no template, so none of them can name one: each is refused under its
  # own property as naming no configured domain.
  def test_nothing_names_a_session_template
    source = with_session(self.class.session)
    refused(Erx::Manifest::Invalid, 'introduce', "#{source}introduce @domain.alpha @session.system\n",
            message: /introduction names no configured domain/)
    refused(Erx::Manifest::Invalid, 'service.server', source + service('probe', '@session.system'),
            message: /names neither the system domain nor a configured domain/)
    refused(Erx::Manifest::Invalid, 'window.holder', source.sub("window data\n  holder system", "window data\n  holder @session.system"),
            message: /names neither the system domain nor a configured domain/)
    refused(Erx::Manifest::Invalid, 'unit.holder', source.sub(/(unit block\n(?:  .*\n)*?  holder )system/, '\1@session.system'),
            message: /names neither the system domain nor a configured domain/)
  end

  # A session template as a facet grantee, written @session.PRINCIPAL: the facet row
  # names the template by its index in the sessions table, which the reader checks as
  # it checks a configured domain's; a template is never a server and never placed in
  # the boot order, so the grant adds no boot edge.
  def test_a_facet_granted_to_a_session_template_reaches_the_encoded_manifest
    source = with_session(self.class.session) + service('b', '@domain.beta') +
             facet('sb', '@session.system', '@service.b') + facet('ab', '@domain.alpha', '@service.b')
    view = @codec.open('manifest', admit(source).bytes)
    kind = ->(name) { @codec.member('mf_grantee', name) }
    assert_equal [[kind.call('domain'), 0], [kind.call('session'), 0]],
                 rows(view, 'facets').map { |row| row.values_at('grantee_kind', 'grantee') }
    alone = with_session(self.class.session) + service('b', '@domain.beta') + facet('sb', '@session.system', '@service.b')
    assert_equal [0, 1], rows(@codec.open('manifest', admit(alone).bytes), 'boot_order').map { |row| row.fetch('domain') }
  end

  # The system domain's grantee has no index: its kind says system and its index is 0.
  def test_a_facet_granted_to_the_system_domain_has_no_index
    view = @codec.open('manifest', admit(@source + service('b', '@domain.beta') + facet('sb', 'system', '@service.b')).bytes)
    assert_equal [[@codec.member('mf_grantee', 'system'), 0]],
                 rows(view, 'facets').map { |row| row.values_at('grantee_kind', 'grantee') }
  end

  def test_a_facet_granted_to_no_session_template_is_refused
    source = with_session(self.class.session) + service('b', '@domain.beta') + facet('f', '@session.nobody', '@service.b')
    refused(Erx::Manifest::Invalid, 'facet.grantee', source, message: /names neither the system domain, a configured domain nor a/)
  end

  # Properties 2 and 14: a session template may hold a facet of a service the system
  # domain serves, which the domain service starts for each session made from it, as
  # it may one of a configured domain's; no server takes a facet of its own service.
  def test_a_session_granted_a_system_domain_service_is_accepted
    admit(with_session(self.class.session) + service('s', 'system') + facet('f', '@session.system', '@service.s'))
    refused(Erx::Manifest::Invalid, 'facet.grantee',
            with_session(self.class.session) + service('s', 'system') + facet('f', 'system', '@service.s'), message: /the system domain takes no facet of its own service/)
  end

  # Property 15: the system domain holds no facet of the net or netadmin interface,
  # however the service row spells the interface.
  def test_the_system_domain_holds_no_network_facet
    net = service('n', '@domain.beta')
    ['interface net', 'interface 3', 'interface netadmin', 'interface 4'].each do |interface|
      source = with_session(self.class.session) + net.sub('interface 1', interface) + facet('n', 'system', '@service.n')
      refused(Erx::Manifest::Invalid, 'facet.grantee', source, message: /facet n grants the system domain/)
    end
  end

  # Property 15's floor: a net facet's grantee, a configured domain or a session
  # template, has a max_frame of at least net_max_frame_min in its own runtime limits,
  # whatever the system domain's are. alpha runs under the system runtime limits, a
  # session under the session ones.
  def test_a_net_grantee_below_the_frame_floor_is_refused
    floor = @codec.constant('net_max_frame_min')
    net = service('n', '@domain.beta').sub('interface 1', 'interface net')
    to_session = with_session(self.class.session) + net + facet('n', '@session.system', '@service.n')
    to_alpha = with_session(self.class.session) + net + facet('n', '@domain.alpha', '@service.n')
    admit(to_session)
    admit(to_alpha)
    [with_max_frame(to_session, 'session', floor - 1), with_max_frame(to_alpha, 'system', floor - 1)].each do |source|
      refused(Erx::Manifest::Invalid, 'runtime_limits.max_frame', source, message: /#{floor}/)
    end
  end

  # A net facet's sockets and buffers, the grant's limits of their names
  # (abi/services/net.txt): each a u64 packed under its key when the row states it,
  # within its declared bound, and absent when it does not, so the grant takes its
  # default; a value outside its bound, a word or a quoted number is refused.
  def test_a_net_facet_s_sockets_and_buffers_are_bounded_parameters
    granted = lambda do |lines|
      with_session(self.class.session) + service('n', '@domain.beta').sub('interface 1', 'interface net') +
        facet('n', '@session.system', '@service.n') + lines
    end
    keys = @codec.schema.services.find { |service| service.fetch(:name) == 'net' }.fetch(:parameters)
                 .to_h { |name, parameter| [parameter.fetch(:number), name] }
    u64 = @codec.member('mf_parameter_kind', 'u64')
    # The packed rows as {name => value}, each checked to be a u64 row, in key order.
    packed = lambda do |lines|
      found = rows(@codec.open('manifest', admit(granted.call(lines)).bytes), 'facet_parameters')
      assert_equal found.map { |row| row.fetch('key') }.sort, found.map { |row| row.fetch('key') }
      assert(found.all? { |row| row.fetch('kind') == u64 })
      found.to_h { |row| [keys.fetch(row.fetch('key')), row.fetch('scalar')] }
    end
    assert_empty packed.call('')
    # Stated out of key order; the packer writes them sorted.
    assert_equal({ 'sockets' => 80, 'buffers' => 1_048_576 },
                 packed.call("  parameter buffers 1048576\n  parameter sockets 80\n"))
    [[1, 131_072], [4096, 67_108_864]].each do |sockets, buffers|
      assert_equal({ 'sockets' => sockets, 'buffers' => buffers },
                   packed.call("  parameter sockets #{sockets}\n  parameter buffers #{buffers}\n"))
    end
    { "  parameter sockets 0\n" => /outside 1 to 4096/, "  parameter sockets 4097\n" => /outside 1 to 4096/,
      "  parameter buffers 131071\n" => /outside 131072 to 67108864/,
      "  parameter buffers 67108865\n" => /outside 131072 to 67108864/ }.each do |line, message|
      refused(Erx::Manifest::Invalid, 'facet.parameter', granted.call(line), message: message)
    end
    ["  parameter sockets many\n", "  parameter sockets \"80\"\n"].each do |line|
      assert_raises(Erx::ABI::SchemaError, line) { admit(granted.call(line)) }
    end
  end

  # A net facet's ports and listen, sets of at most 16 ports (abi/services/net.txt): each
  # element a u64 row of its key, in ascending order whatever order the lines give, after
  # the scalars of lower keys; a port outside 1 to 65535, a 17th port or one stated twice is
  # refused, and so is a listen port that is not one of the grant's ports, those it lists
  # or by default 1024 to 65535.
  def test_a_net_facet_s_ports_and_listen_are_bounded_sets
    granted = lambda do |lines|
      with_session(self.class.session) + service('n', '@domain.beta').sub('interface 1', 'interface net') +
        facet('n', '@session.system', '@service.n') + lines
    end
    keys = @codec.schema.services.find { |service| service.fetch(:name) == 'net' }.fetch(:parameters)
                 .to_h { |name, parameter| [parameter.fetch(:number), name] }
    packed = lambda do |lines|
      rows(@codec.open('manifest', admit(granted.call(lines)).bytes), 'facet_parameters')
        .map { |row| [keys.fetch(row.fetch('key')), row.fetch('scalar')] }
    end
    lines = ->(key, ports) { ports.map { |port| "  parameter #{key} #{port}\n" }.join }
    assert_equal [['sockets', 80], ['ports', 2222], ['ports', 5000], ['ports', 65_535], ['listen', 5000]],
                 packed.call(lines.call('listen', [5000]) + lines.call('ports', [65_535, 2222, 5000]) +
                             "  parameter sockets 80\n")
    sixteen = (2000...2016).to_a
    assert_equal sixteen.map { |port| ['ports', port] }, packed.call(lines.call('ports', sixteen.reverse))
    assert_equal [['listen', 1024], ['listen', 65_535]], packed.call(lines.call('listen', [65_535, 1024]))
    { lines.call('ports', [0]) => /outside 1 to 65535/, lines.call('listen', [65_536]) => /outside 1 to 65535/,
      lines.call('ports', sixteen + [3000]) => /states over 16 values/,
      lines.call('ports', [2222, 5000, 2222]) => /states 2222 twice/ }.each do |line, message|
      refused(Erx::Manifest::Invalid, 'facet.parameter', granted.call(line), message: message)
    end
    { lines.call('listen', [1023]) => /listens on 1023, none of its ports/,
      lines.call('ports', [2222]) + lines.call('listen', [2222, 5000]) => /listens on 5000, none of its ports/ }
      .each do |line, message|
      refused(Erx::Manifest::Invalid, 'facet.parameter', granted.call(line), message: message)
    end
  end

  # A privileged port, below 1024, which a net grant binds only when it lists it, is listed
  # by one grant of its network domain alone, to a configured domain: a second grant of
  # the same network domain listing it, which could bind it first, and a session template's
  # grant, which every session made from it holds, are refused. A grant of another network
  # domain, a stack of its own, may list it too.
  def test_a_privileged_port_is_one_configured_domain_s
    source = lambda do |second_grantee, second_service, port|
      with_domains(self.class.domain('alpha'), self.class.domain('beta', flags: 'rescue'), self.class.domain('gamma')) +
        self.class.session +
        service('n', '@domain.beta').sub('interface 1', 'interface net') +
        service('m', '@domain.alpha').sub('interface 1', 'interface net') +
        facet('a', '@domain.alpha', '@service.n') + "  parameter ports 22\n" +
        facet('b', second_grantee, second_service) + "  parameter ports #{port}\n"
    end
    admit(source.call('@domain.gamma', '@service.n', 23))
    admit(source.call('@domain.gamma', '@service.m', 22))
    refused(Erx::Manifest::Invalid, 'facet.parameter', source.call('@domain.gamma', '@service.n', 22),
            message: /privileged port 22 is listed by facets a, b of one network domain/)
    refused(Erx::Manifest::Invalid, 'facet.grantee', source.call('@session.system', '@service.m', 22),
            message: /privileged ports to a session template/)
  end

  # Property 16: a files facet's grantee, the system domain, a configured domain or a
  # session template, and its server each take frames of at least files_max_frame_min
  # under their own runtime limits, and the facet's max_request admits a request that
  # long. beta serves under the system runtime limits, and so does alpha as a grantee; a
  # session takes the session ones. A session granted no files facet is still held to
  # the code protocol's load floor, which equals this one (test_code_receivers_below_a_floor_are_refused).
  def test_a_files_receiver_below_the_frame_floor_is_refused
    floor = @codec.constant('files_max_frame_min')
    files = service('f', '@domain.beta').sub('interface 1', 'interface files')
    files_facet = ->(grantee) { facet('f', grantee, '@service.f').sub('max_request 1', "max_request #{floor}") }
    granted = ->(grantee) { with_session(self.class.session) + files + files_facet.call(grantee) }
    refused(Erx::Manifest::Invalid, 'facet.max_request', granted.call('system').sub("max_request #{floor}", "max_request #{floor - 1}"),
            message: /f's max_request #{floor - 1} .*#{floor}/)
    %w[system @domain.alpha @session.system].each { |grantee| admit(granted.call(grantee)) }
    [['grantee', with_max_frame(granted.call('@session.system'), 'session', floor - 1)],
     ['server', with_max_frame(granted.call('@session.system'), 'system', floor - 1)],
     ['grantee', with_max_frame(granted.call('system'), 'system', floor - 1)]].each do |role, source|
      refused(Erx::Manifest::Invalid, 'runtime_limits.max_frame', source, message: /f's #{role} .*#{floor}/)
    end
  end

  # Property 16 binds every interface abi/services serves as a tree, not files alone: a
  # line grantee carries the files frame floor (docs/design-bluetooth.md, "The
  # controller's line"). The line service's own parameters wait on their grant checker,
  # so the seed is an interface declared as line is, served_as tree, without them.
  def test_a_tree_receiver_below_the_files_frame_floor_is_refused
    root = File.expand_path('../..', __dir__)
    carried = Erx::ABI::Syntax.parse("service carried 99\n  served_as tree\n", path: 'abi/services/carried.txt')
    sources = Erx::ABI::Sources.read(root: root)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(
                                   Erx::ABI::SourceSet.new(declarations: sources.declarations + carried, inputs: sources.inputs)
                                 ))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @platform))
    floor = @codec.constant('files_max_frame_min')
    granted = with_session(self.class.session) + "service c\n  server system\n  interface carried\n" +
              facet('c', '@session.system', '@service.c').sub('max_request 1', "max_request #{floor}")
    admit(granted)
    refused(Erx::Manifest::Invalid, 'facet.max_request', granted.sub("max_request #{floor}", "max_request #{floor - 1}"),
            message: /c's max_request #{floor - 1} .*#{floor}/)
    refused(Erx::Manifest::Invalid, 'runtime_limits.max_frame', with_max_frame(granted, 'session', floor - 1),
            message: /c's grantee .*#{floor}/)
  end

  # A files facet's rights, the files interface's member parameter (abi/services/files.txt):
  # ro, rw or rx, each packed as its member's value; any other word, rwx among them, a
  # quoted name or a number is refused.
  def test_a_files_facet_s_rights_are_one_of_ro_rw_and_rx
    floor = @codec.constant('files_max_frame_min')
    granted = lambda do |line|
      @source + service('f', '@domain.beta').sub('interface 1', 'interface files') +
        facet('f', '@domain.alpha', '@service.f').sub('max_request 1', "max_request #{floor}") + line
    end
    member = @codec.member('mf_parameter_kind', 'member')
    %w[ro rw rx].each do |rights|
      view = @codec.open('manifest', admit(granted.call("  parameter rights #{rights}\n")).bytes)
      assert_equal [[1, member, @codec.member('files_rights', rights)]],
                   rows(view, 'facet_parameters').map { |row| row.values_at('key', 'kind', 'scalar') }
    end
    ['rwx', 'wr', '"ro"', '2'].each do |value|
      assert_raises(Erx::ABI::SchemaError, value) { admit(granted.call("  parameter rights #{value}\n")) }
    end
  end

  # Property 16 for inspect: a grantee of an inspect facet, here a session template, and
  # its server, the system domain, each run with max_frame, max_message_heap and
  # funnel_depth at least the interface's floors, as the development manifest's
  # runtime limits do. The seeds are the design's: a check
  # that reads only the grantee's limits accepts the server's; one of max_frame alone
  # accepts the template's max_message_heap.
  def test_an_inspect_receiver_below_a_floor_is_refused
    floors = { 'max_frame' => @codec.constant('inspect_max_frame_min'),
               'max_message_heap' => @codec.constant('inspect_message_heap_min'),
               'funnel_depth' => @codec.constant('inspect_funnel_depth_min') }
    inspect = service('i', 'system').sub('interface 1', 'interface inspect')
    granted = with_session(self.class.session) + inspect + facet('i', '@session.system', '@service.i')
    admit(granted)
    refused(Erx::Manifest::Invalid, 'service.server', granted.sub("service i\n  server system", "service i\n  server @domain.beta"),
            message: /only the system domain serves the inspect interface/)
    %w[system session].product(floors.keys).each do |name, field|
      role = name == 'system' ? 'server' : 'grantee'
      refused(Erx::Manifest::Invalid, "runtime_limits.#{field}",
              with_runtime_limit(granted, name, field, floors.fetch(field) - 1),
              message: /i's #{role} runs with #{field} #{floors.fetch(field) - 1}, below inspect's floor/)
    end
  end

  # Property 16 for code: every configured domain and session template runs with the
  # code protocol's load floors and the system domain with its answer floors, granted
  # anything or nothing, and a facet of the code interface admits code_request_max and
  # its grantee and server run with the facet floors. The
  # seeds are the design's: a check of the domains alone accepts the session template's
  # limits; one of max_frame alone accepts its max_message_heap; one that holds the
  # system domain to the load floors accepts its funnel_depth below the answer floor,
  # the one field whose answer floor is above its load floor.
  def test_code_receivers_below_a_floor_are_refused
    floors = %w[load answer].to_h do |direction|
      [direction, { 'max_frame' => @codec.constant("code_#{direction}_max_frame_min"),
                    'max_message_heap' => @codec.constant("code_#{direction}_message_heap_min"),
                    'funnel_depth' => @codec.constant("code_#{direction}_funnel_depth_min") }]
    end
    source = with_session(self.class.session)
    admit(source)
    refute_empty(floors.fetch('answer').select { |field, floor| floor > floors.fetch('load').fetch(field) },
                 'no answer floor is above its load floor, so the system domain seed refuses nothing')
    [['session', 'load'], ['system', 'answer']].each do |name, direction|
      floors.fetch(direction).each do |field, floor|
        # alpha and beta run under the system runtime limits, so the load check meets an
        # answer floor no higher than its load floor first.
        next if direction == 'answer' && floor <= floors.fetch('load').fetch(field)

        refused(Erx::Manifest::Invalid, "runtime_limits.#{field}", with_runtime_limit(source, name, field, floor - 1),
                message: /run with #{field} #{floor - 1}, below the code protocol's #{direction} floor/)
      end
    end
    bound = @codec.constant('code_request_max')
    code = service('c', 'system').sub('interface 1', 'interface code')
    granted = source + code + facet('c', '@session.system', '@service.c').sub('max_request 1', "max_request #{bound}")
    admit(granted)
    refused(Erx::Manifest::Invalid, 'facet.max_request', granted.sub("max_request #{bound}", "max_request #{bound - 1}"),
            message: /c's max_request #{bound - 1} is below code_request_max/)
    # The facet's grantee takes its requests and replies, which pass the load floors on
    # at least one limit; a grantee at the load floors but below the facet's is refused.
    stricter = { 'max_frame' => 'max_frame', 'max_message_heap' => 'message_heap', 'funnel_depth' => 'funnel_depth' }
               .filter_map do |field, name|
                 floor = @codec.constant("code_facet_#{name}_min")
                 [field, floor] if floor > floors.fetch('load').fetch(field)
               end
    refute_empty stricter
    stricter.each do |field, floor|
      refused(Erx::Manifest::Invalid, "runtime_limits.#{field}", with_runtime_limit(granted, 'session', field, floor - 1),
              message: /facet c's grantee runs with #{field} #{floor - 1}, below code's floor of #{floor}/)
    end
  end

  # source with field of the runtime limits name set to value.
  def with_runtime_limit(source, name, field, value)
    pattern = /^(runtime_limits #{name}\n(?:  .*\n)*?  #{field} )\d+$/
    raise ArgumentError, "no #{field} in runtime_limits #{name}" unless source.match?(pattern)

    source.sub(pattern) { "#{Regexp.last_match(1)}#{value}" }
  end

  # source with the max_frame of the runtime limits name set to bytes.
  def with_max_frame(source, name, bytes)
    pattern = /^(runtime_limits #{name}\n  max_frame )\d+$/
    raise ArgumentError, "no runtime_limits #{name}" unless source.match?(pattern)

    source.sub(pattern, "\\1#{bytes}")
  end

  # Property 17: a start row, keyed by its principal's name, names a principal with a
  # session template, takes its defaults where its source states none, and names a
  # display only as a windows service granted to that template, of which no two
  # enabled rows name one.
  def self.start(principal = 'system', fields = '') = "start #{principal}\n#{fields}"

  # A second principal with a session template, so two start rows can name one
  # display; it and the system principal each take half of users. Only the build
  # check reads it, so it needs no domain quota.
  OTHER = "share half\n  quota_ns 5000000\n  period_ns 10000000\n  cpuset 15\n  capacity_mcpu 500\n  capacity_first 0\n" \
          "  slice_us 1000\n  grace_us 5\n  base 16\n  ceiling 31\n  flags none\n" \
          "principal other\n  memory 1048576\n  grant @share.half\n  domains 0\n  names 1\n" \
          "  default_limits @limits.native\n  ceiling_limits @limits.native\n"

  # Both templates, service b and its grants to them, and starts. The system
  # principal's domains quota is 2 (with_domains), other's 0.
  def with_display(*starts, served: service('b', '@domain.beta'),
                   grants: [facet('sb', '@session.system', '@service.b'), facet('ob', '@session.other', '@service.b')])
    halved = with_session(self.class.session, self.class.session('other'))
             .sub(/^(principal system\n(?:  .*\n)*?  grant )@share.users/, '\1@share.half')
             .sub(/^(limits native\n(?:  .*\n)*?  grant )@share.users/, '\1@share.half')
    halved + OTHER + served + grants.join + starts.join
  end

  # Property 18's display: service b of the windows interface, served by server, with
  # record, its display record, and granted to both templates, each grant with the
  # parameter lines of sb or ob; beta's limits give it an outer budget of 1 MiB and a
  # lane of a page.
  DISPLAY = "display b\n  policy single\n  idle_dim_s 60\n  idle_off_s 600\n"

  def with_windows(*starts, server: '@domain.beta', record: DISPLAY, sb: "  parameter pixels 4096\n",
                   ob: "  parameter pixels 4096\n")
    with_display(*starts, served: "service b\n  server #{server}\n  interface windows\n#{record}",
                          grants: [window_facet('sb', '@session.system', '@service.b') + sb,
                                   window_facet('ob', '@session.other', '@service.b') + ob])
  end

  def service_index(view, name) = rows(view, 'services').index { |row| view.string(row.fetch('name')) == name }

  def test_a_start_row_is_packed_with_its_defaults_or_its_own_fields
    none = @codec.constant('mf_none')
    enabled = @codec.member('mf_start_flags', 'enabled')
    published = @codec.member('mf_start_flags', 'published_enabled')
    fields = %w[principal flags display restarts restart_period_s]
    view = @codec.open('manifest', admit(with_session(self.class.session) + self.class.start).bytes)
    assert_equal [[0, enabled | published, none, 5, 600]], rows(view, 'starts').map { |row| row.values_at(*fields) }
    own = self.class.start('system', "  enable NO\n  restarts 3\n  restart_period_s 60\n")
    view = @codec.open('manifest', admit(with_session(self.class.session) + own).bytes)
    assert_equal [[0, 0, none, 3, 60]], rows(view, 'starts').map { |row| row.values_at(*fields) }
    # A published default apart from enable is packed beside it, in either direction.
    { "  enable YES\n  published_enable NO\n" => enabled, "  enable NO\n  published_enable YES\n" => published }
      .each do |lines, flags|
        source = with_session(self.class.session) + self.class.start('system', lines)
        view = @codec.open('manifest', admit(source).bytes)
        assert_equal [flags], rows(view, 'starts').map { |row| row.fetch('flags') }
      end
  end

  def test_a_start_row_of_a_principal_without_a_session_template_is_refused
    refused(Erx::Manifest::Invalid, 'start.name', @source + self.class.start, message: /a start row's principal has no session template/)
    refused(Erx::Manifest::Invalid, 'start.name', with_session(self.class.session) + self.class.start('alpha'),
            message: /a start row names no principal/)
  end

  def test_a_start_row_s_restart_period_is_at_least_a_second
    refused(Erx::Manifest::Invalid, 'start.restart_period_s',
            with_session(self.class.session) + self.class.start('system', "  restart_period_s 0\n"), message: /a start row's restart period is under a second/)
  end

  def test_two_start_rows_of_one_principal_are_refused
    refused(Erx::Manifest::Invalid, 'start', with_session(self.class.session) + self.class.start + self.class.start,
            message: /duplicate source alias/)
  end

  def test_a_start_row_s_intensity_past_its_ceilings_is_refused
    base = with_session(self.class.session)
    fields = %w[restarts restart_period_s]
    view = @codec.open('manifest', admit(base + self.class.start('system', "  restarts 100\n  restart_period_s 86400\n")).bytes)
    assert_equal [[100, 86_400]], rows(view, 'starts').map { |row| row.values_at(*fields) }
    refused(Erx::Manifest::Invalid, 'start.restarts', base + self.class.start('system', "  restarts 101\n"),
            message: /a start row's restarts is over 100/)
    refused(Erx::Manifest::Invalid, 'start.restart_period_s', base + self.class.start('system', "  restart_period_s 86401\n"),
            message: /a start row's restart_period_s is over 86400/)
  end

  def test_a_start_row_s_enable_is_only_yes_or_no
    assert_raises(Erx::ABI::SchemaError) { admit(with_session(self.class.session) + self.class.start('system', "  enable yes\n")) }
  end

  # Property 17's accepting path: a row names a windows service that a facet row grants
  # its principal's template, and the row holds the service's index.
  def test_a_start_row_on_a_display_granted_to_its_template_is_packed
    view = @codec.open('manifest', admit(with_windows(self.class.start('system', "  display @service.b\n"))).bytes)
    assert_equal [service_index(view, 'b')], rows(view, 'starts').map { |row| row.fetch('display') }
  end

  def test_a_start_row_s_display_is_a_windows_service_granted_to_its_template
    display = "  display @service.b\n"
    refused(Erx::Manifest::Invalid, 'start.display', with_display(self.class.start('system', display)),
            message: /not a windows service/)
    refused(Erx::Manifest::Invalid, 'start.display', with_display(self.class.start('system', "  display @service.c\n")),
            message: /does not contain/)
    other_only = with_display(self.class.start('system', display),
                              served: "service b\n  server @domain.beta\n  interface windows\n#{DISPLAY}",
                              grants: [window_facet('ob', '@session.other', '@service.b') + "  parameter pixels 4096\n"])
    refused(Erx::Manifest::Invalid, 'start.display', other_only, message: /not granted/)
  end

  # Two enabled rows on one display are refused; a disabled row holds no display.
  def test_two_enabled_start_rows_on_one_display_are_refused
    display = "  display @service.b\n"
    refused(Erx::Manifest::Invalid, 'start.display',
            with_windows(self.class.start('system', display), self.class.start('other', display)), message: /two enabled/)
    view = @codec.open('manifest', admit(with_windows(self.class.start('system', display),
                                                      self.class.start('other', "  enable NO\n#{display}"))).bytes)
    assert_equal 2, view.count('starts')
    # A boot that cannot read the settings file starts the published defaults' rows.
    off = "  enable NO\n  published_enable YES\n#{display}"
    refused(Erx::Manifest::Invalid, 'start.display',
            with_windows(self.class.start('system', off), self.class.start('other', off)),
            message: /two published-default enabled/)
  end

  def test_a_partial_boot_starts_no_row
    refused(Erx::Manifest::Invalid, 'start', @plain.sub('flags development', 'flags development,partial_boot') + self.class.start,
            message: /a partial boot starts no row/)
    refused(Erx::Manifest::Invalid, 'display', @plain.sub('flags development', 'flags development,partial_boot') + DISPLAY,
            message: /a partial boot runs no services/)
  end

  # Property 8's input clause (abi/services/input.txt): an input tree's facet goes only to
  # a display domain, alpha, which serves the windows service b, and never to beta, a
  # configured domain that serves no display, the system domain or a session template; and
  # the interface declares no rights, so a row that states rw is refused.
  def test_an_input_facet_goes_to_a_display_domain_alone_and_read_only
    input = ->(server) { "service kbd\n  server #{server}\n  interface input\n" }
    granted = ->(server, grantee) { with_windows(server: '@domain.alpha') + input.call(server) + window_facet('kbd', grantee, '@service.kbd') }
    view = @codec.open('manifest', admit(granted.call('@domain.beta', '@domain.alpha')).bytes)
    assert_includes rows(view, 'services').map { |row| row.fetch('interface') }, 15
    [['@domain.alpha', '@domain.beta'], ['@domain.beta', 'system'], ['@domain.beta', '@session.system']].each do |server, grantee|
      refused(Erx::Manifest::Invalid, 'facet.grantee', granted.call(server, grantee),
              message: /input facet kbd is granted to no display domain/)
    end
    refused(Erx::Manifest::Invalid, 'facet.parameter', granted.call('@domain.beta', '@domain.alpha') + "  parameter rights rw\n",
            message: /parameter rights is not declared by its service/)
  end

  # Property 18: the display record is packed by its service's index, with its policy,
  # idle times and palette, light unless the record names one.
  def test_a_display_record_is_packed_by_its_service
    view = @codec.open('manifest', admit(with_windows).bytes)
    fields = %w[service policy idle_dim_s idle_off_s palette]
    assert_equal [[service_index(view, 'b'), @codec.member('mf_display_policy', 'single'), 60, 600,
                   @codec.member('mf_display_palette', 'light')]],
                 rows(view, 'displays').map { |row| row.values_at(*fields) }
    never = DISPLAY.sub('idle_off_s 600', 'idle_off_s 0')
    view = @codec.open('manifest', admit(with_windows(record: never)).bytes)
    assert_equal [0], rows(view, 'displays').map { |row| row.fetch('idle_off_s') }
    dark = DISPLAY.sub('idle_off_s 600', "idle_off_s 600\n  palette dark")
    view = @codec.open('manifest', admit(with_windows(record: dark)).bytes)
    assert_equal [@codec.member('mf_display_palette', 'dark')], rows(view, 'displays').map { |row| row.fetch('palette') }
    assert_raises(Erx::ABI::SchemaError) { admit(with_windows(record: DISPLAY.sub('idle_off_s 600', "idle_off_s 600\n  palette sepia"))) }
  end

  # A policy is a member of mf_display_policy, which has one for each window manager the
  # display domain has, so rio, erx_wm_rio's, is accepted and tiled, which names none, is
  # refused.
  def test_a_display_record_s_policy_and_idle_times_are_checked
    admit(with_windows(record: DISPLAY.sub('single', 'rio')))
    error = assert_raises(Erx::ABI::SchemaError) { admit(with_windows(record: DISPLAY.sub('single', 'tiled'))) }
    assert_match(/policy names no member of mf_display_policy/, error.message)
    refused(Erx::Manifest::Invalid, 'display.idle_off_s', with_windows(record: DISPLAY.sub('idle_off_s 600', 'idle_off_s 59')),
            message: /off before it dims/)
  end

  # Seed: a windows service with no display record would have grants no sum counts.
  def test_every_windows_service_has_a_display_record_and_every_record_one
    refused(Erx::Manifest::Invalid, 'display.name', with_windows(record: ''), message: /has no display record/)
    refused(Erx::Manifest::Invalid, 'display.name', with_display(served: service('b', '@domain.beta') + DISPLAY),
            message: /not checked by windows_grant/)
    refused(Erx::Manifest::Invalid, 'display.name', with_windows + DISPLAY.sub('display b', 'display c'),
            message: /does not contain/)
    refused(Erx::Manifest::Invalid, 'display', with_windows + DISPLAY, message: /duplicate source alias/)
  end

  # Seed: a domain serving two displays would pay for both displays' grants out of one
  # outer budget, which each display's sum alone accepts.
  def test_one_domain_serves_one_display
    second = "service c\n  server @domain.beta\n  interface windows\n#{DISPLAY.sub('display b', 'display c')}" +
             window_facet('sc', '@session.system', '@service.c') + "  parameter pixels 4096\n"
    refused(Erx::Manifest::Invalid, 'display.name', with_windows + second, message: /one domain serves two displays/)
    admit(with_windows + second.gsub('@domain.beta', '@domain.alpha'))
  end

  def test_a_display_is_served_by_a_configured_domain
    refused(Erx::Manifest::Invalid, 'display.name', with_windows(server: 'system'), message: /system domain/)
  end

  # Seed: the system domain is connected to every domain at its creation, by no
  # introduction, so its connection to a display has no pixel area (design-display.md,
  # "The pixel area"); a windows grant to it would be installed without one.
  def test_no_display_is_granted_to_the_system_domain
    granted = with_windows + window_facet('ys', 'system', '@service.b') + "  parameter pixels 4096\n"
    refused(Erx::Manifest::Invalid, 'facet.grantee', granted, message: /grants a display to the system domain/)
  end

  # Seed: the session parameter is the domain service's alone.
  def test_no_facet_row_sets_session
    refused(Erx::Manifest::Invalid, 'facet.parameter', with_windows(sb: "  parameter pixels 4096\n  parameter session no\n"),
            message: /sets session/)
  end

  # Property 18's front clause: only the row granting the display to the system
  # principal's template, root's, sets front, and only in a development build, since the
  # newest window of a front grant takes a single display's screen. Seeds: a configured
  # domain's row; another principal's template's row, which a check accepting any session
  # template misses; and root's row in a release build.
  def test_only_root_s_development_grant_sets_front
    front = "  parameter pixels 4096\n  parameter front yes\n"
    admit(with_windows(sb: front))
    refused(Erx::Manifest::Invalid, 'facet.parameter', with_windows(ob: front), message: /sets front/)
    domain = with_windows + window_facet('ab', '@domain.alpha', '@service.b') + front
    refused(Erx::Manifest::Invalid, 'facet.parameter', domain, message: /sets front/)
    release = Class.new(Erx::Manifest::Check) { private def check_mode(development:, partial:) = nil }
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @platform),
                                         build_kind: 'release')
    check = lambda do |sb|
      parsed = Erx::Manifest::Frontend.parse(with_windows(sb: sb).sub('flags development', 'flags none'),
                                             version: @codec.constant('manifest_version'))
      release.new(parsed, codec: @codec, context: context, planner: @planner).check
    end
    check.call("  parameter pixels 4096\n")
    error = assert_raises(Erx::Manifest::Invalid) { check.call(front) }
    assert_equal 'facet.parameter', error.field, error.message
    assert_match(/sets front/, error.message)
  end

  # Seed: a template's grant costs its pixel area and the display's side once for each
  # session its principal's domains quota allows, 2 for the system principal and 0 for
  # other. 127 pages and the side's page, twice, fill beta's 1 MiB outer budget; one
  # page more each passes it, which counting the template once would accept.
  def test_a_template_s_pixel_areas_count_once_for_each_session_it_can_have
    admit(with_windows(sb: "  parameter pixels #{127 * 4096}\n", ob: "  parameter pixels #{1 << 30}\n"))
    refused(Erx::Manifest::Invalid, 'facet.parameter', with_windows(sb: "  parameter pixels #{128 * 4096}\n"),
            message: /past its domain's outer budget/)
    refused(Erx::Manifest::Invalid, 'facet.parameter', with_windows(sb: ''), message: /past its domain's outer budget/)
  end

  # A facet's parameters, resolved against its service's declarations, are packed in
  # key order, each facet's run its parameters span; facets are in name order, ob first.
  def test_facet_parameters_are_packed_in_key_order
    view = @codec.open('manifest', admit(with_windows(sb: "  parameter clipboard yes\n  parameter pixels 4096\n  parameter windows 2\n")).bytes)
    u64, boolean = %w[u64 boolean].map { |kind| @codec.member('mf_parameter_kind', kind) }
    assert_equal [[2, u64, 4096], [1, u64, 2], [2, u64, 4096], [3, boolean, 1]],
                 rows(view, 'facet_parameters').map { |row| row.values_at('key', 'kind', 'scalar') }
    granted = rows(view, 'facets').select { |row| %w[ob sb].include?(view.string(row.fetch('name'))) }
    assert_equal [1, 3], granted.map { |row| row.fetch('parameters').fetch('count') }
  end

  def test_a_facet_parameter_is_declared_stated_once_and_within_its_bound
    { "  parameter root \"/\"\n" => /not declared/, "  parameter windows 2\n  parameter windows 2\n" => /twice/,
      "  parameter windows 0\n" => /outside 1 to 4096/, "  parameter windows 4097\n" => /outside 1 to 4096/ }.each do |lines, message|
      refused(Erx::Manifest::Invalid, 'facet.parameter', with_windows(sb: "  parameter pixels 4096\n#{lines}"), message: message)
    end
    assert_raises(Erx::ABI::SchemaError) { admit(with_windows(sb: "  parameter pixels 4096\n  parameter clipboard true\n")) }
    undeclared = facet('ab', '@domain.alpha', '@service.b') + "  parameter root \"/\"\n"
    refused(Erx::Manifest::Invalid, 'facet.parameter', @source + service('b', '@domain.beta') + undeclared, message: /not declared/)
  end

  # Property 19 (docs/design-packaging.md, "The build's check"): the apps row, its
  # services, the signer rows, and the board's sums counting max apps, each a principal
  # with a domains quota of one holding every service of the row. Each clause has a
  # seeded violation. The row follows the service named packages_service, which the build
  # grants the system domain and the app template; packages false leaves it out, for a
  # second row.
  PACKAGES = "service packages\n  server @domain.beta\n  interface files\n"
  def self.apps(memory: 65_536, services: nil, max: nil, packages: true, gatt: nil)
    "#{PACKAGES if packages}apps\n  memory #{memory}\n#{"  services #{services}\n" if services}#{"  max #{max}\n" if max}" \
      "#{"  gatt #{gatt}\n" if gatt}"
  end

  # source ready for an apps row: max_domains raised by count, the domains max apps take
  # (property 4), and the system tree the row needs, held by beta (property 19).
  def for_apps(source, count)
    ManifestContextFixture.with_system_tree(source, holder: '@domain.beta')
                          .sub(/^(  max_domains )(\d+)$/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).to_i + count}" }
  end

  def test_an_apps_row_takes_its_default_max_within_max_domains
    admit(for_apps(@source + self.class.apps, 8))
    admit(for_apps(@source + self.class.apps(max: 64), 64))
    # Seed: an app not counted as a principal with a domain quota of one.
    refused(Erx::Manifest::Invalid, 'principals.domains', for_apps(@source + self.class.apps, 7), message: /apps row's max/)
  end

  def test_an_apps_row_s_max_and_memory_are_bounded
    refused(Erx::Manifest::Invalid, 'apps.max', for_apps(@source + self.class.apps(max: 0), 8), message: /max is outside 1 to 64/)
    refused(Erx::Manifest::Invalid, 'apps.max', for_apps(@source + self.class.apps(max: 65), 65), message: /max is outside 1 to 64/)
    refused(Erx::Manifest::Invalid, 'apps.memory', for_apps(@source + self.class.apps(memory: 4097), 8),
            message: /the apps budget must be positive and page-aligned/)
    refused(Erx::Manifest::Invalid, 'apps.memory', for_apps(@source + self.class.apps(memory: 0), 8),
            message: /the apps budget must be positive and page-aligned/)
  end

  # Seed: the apps budget left out of property 4's sum within root_memory.
  def test_the_apps_budget_counts_within_root_memory
    root_memory = Integer(@source[/^  root_memory (\d+)$/, 1])
    refused(Erx::Manifest::Invalid, 'principals.memory', for_apps(@source + self.class.apps(memory: root_memory), 8),
            message: /apps budget/)
  end

  def test_a_manifest_holds_at_most_one_apps_row
    refused(Erx::Manifest::Invalid, 'apps', for_apps(@source + self.class.apps + self.class.apps(packages: false), 8),
            message: /at most one apps row/)
  end

  # Seeds: services naming what would let an app command the start table, install
  # packages, rewrite /etc/rc.conf or end the machine, or what it holds already, each
  # refused by name whether or not the manifest has such a service; and a name of no
  # service.
  def test_an_apps_row_s_services_are_services_an_app_may_take
    %w[packages start apps etc machine].each do |name|
      refused(Erx::Manifest::Invalid, 'apps.services', for_apps(@source + self.class.apps(services: name), 8),
              message: /services names #{name}:/)
    end
    refused(Erx::Manifest::Invalid, 'apps.services', for_apps(@source + self.class.apps(services: 'nowhere'), 8),
            message: /not the name of one service/)
    refused(Erx::Manifest::Invalid, 'apps.services', for_apps(@source + self.class.apps(services: 'data data'), 8),
            message: /twice/)
    # Seed: a service of the files interface that passes the name checks above, whose
    # grant no tree apps roots at the app's directory.
    refused(Erx::Manifest::Unsupported, 'apps.services',
            for_apps(with_display(grants: [], served: "service b\n  server @domain.beta\n  interface files\n") +
                      self.class.apps(services: 'b'), 8),
            message: /services names b, of a files interface, whose grant/)
    # Seed: a service of the media interface, whatever its name, which no app takes.
    refused(Erx::Manifest::Invalid, 'apps.services',
            for_apps(with_display(grants: [], served: "service b\n  server @domain.beta\n  interface media\n") +
                      self.class.apps(services: 'b'), 8),
            message: /services names b, of the media interface, which no app takes: its grant reaches every drive/)
    refused(Erx::Manifest::Invalid, 'apps.services', for_apps(with_display(grants: []) + self.class.apps(services: 'b'), 8),
            message: /no ABI file declares/)
    two = with_display(grants: [], served: "service b\n  server @domain.beta\n  interface files\n" \
                                         "service a2\n  name \"b\"\n  server @domain.alpha\n  interface files\n")
    refused(Erx::Manifest::Invalid, 'apps.services', for_apps(two + self.class.apps(services: 'b'), 8),
            message: /not the name of one service/)
    inspect = "service seen\n  server system\n  interface inspect\n"
    refused(Erx::Manifest::Unsupported, 'apps.services', for_apps(@source + inspect + self.class.apps(services: 'seen'), 8),
            message: /services names seen, of the inspect interface, whose scope for/)
  end

  # Seed: a service whose ABI file gives a parameter no default, which an app's row,
  # granted with no parameter stated, could not satisfy.
  def test_an_apps_row_names_only_services_whose_parameters_have_defaults
    root = File.expand_path('../..', __dir__)
    needy = Erx::ABI::Syntax.parse("service needy 99\n  served_as message\n  parameter depth 1 u64 one range 1 2 checked_by windows_grant\n",
                                   path: 'abi/services/needy.txt')
    sources = Erx::ABI::Sources.read(root: root)
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(
                                  Erx::ABI::SourceSet.new(declarations: sources.declarations + needy, inputs: sources.inputs)
                                ))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec).merge(platform: @platform))
    source = for_apps(@source + "service needy\n  server @domain.beta\n  interface needy\n" + self.class.apps(services: 'needy'), 8)
    error = assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest.admit(source: source, codec: codec, context: context, planner: @planner)
    end
    assert_equal 'apps.services', error.field, error.message
    assert_match(/gives depth no default/, error.message)
  end

  # Seed: the app template counted once in property 18. Beta's outer budget holds sb's
  # two grants of a page and its side and one app's default pixel area and side, so one
  # app is accepted and two pass the budget.
  def test_every_app_counts_against_a_display_its_row_names
    outer = 2 * (4096 + 4096) + @codec.constant('windows_pixels_default') + 4096
    roomy = ->(source) { source.sub("  memory 4194304\n  outer 1048576\n", "  memory 16777216\n  outer #{outer}\n") }
    admit(for_apps(roomy.call(with_windows + self.class.apps(services: 'b', max: 1)), 1))
    refused(Erx::Manifest::Invalid, 'apps.max', for_apps(roomy.call(with_windows + self.class.apps(services: 'b', max: 2)), 2),
            message: /past its domain's outer budget/)
    admit(for_apps(roomy.call(with_windows + self.class.apps(max: 2)), 2))
  end

  # The rows the build derives from the apps row (docs/design-packaging.md, "The apps
  # row"): the app template, last among the sessions, naming no principal, of the limits
  # session record and the app release; the system domain's packages row, rights rw, and
  # the template's, rights ro; the template's row of each service of services, with its
  # service's declared quantities; and the apps row naming the template and its rows by
  # index. The derivation skipped, or the template's packages row granted rw, fails it.
  def test_the_build_derives_the_app_template_and_its_rows
    outer = 2 * (4096 + 4096) + @codec.constant('windows_pixels_default') + 4096
    roomy = with_windows.sub("  memory 4194304\n  outer 1048576\n", "  memory 16777216\n  outer #{outer}\n")
    view = @codec.open('manifest', admit(for_apps(roomy + self.class.apps(services: 'b', max: 1), 1)).bytes)
    sessions = view.each('sessions').to_a
    template = sessions.size - 1
    limits = view.each('limits').map { |row| view.string(row.fetch('name')) }
    assert_equal [@codec.constant('mf_none'), 'session'], [sessions.last.fetch('principal'), limits.fetch(sessions.last.fetch('limits'))]
    apps = view.each('apps').first
    services = view.each('services').map { |row| view.string(row.fetch('name')) }
    facets = view.each('facets').to_a
    parameters = view.each('facet_parameters').to_a
    first = view.header.fetch('facet_parameters').fetch('offset')
    rights = lambda do |facet|
      span = facet.fetch('parameters')
      parameters[(span.fetch('offset') - first) / 32, span.fetch('count')].map { |row| row.fetch('scalar') }
    end
    granted = facets.map do |facet|
      [facet.fetch('grantee_kind'), facet.fetch('grantee'), services.fetch(facet.fetch('service')), rights.call(facet)]
    end
    session = @codec.member('mf_grantee', 'session')
    rw, rx = %w[rw rx].map { |name| @codec.member('files_rights', name) }
    installed = @codec.member('files_tree', 'installed')
    assert_includes granted, [@codec.member('mf_grantee', 'system'), 0, 'packages', [rw]]
    assert_equal [session, template, 'packages', [rx, installed]], granted.fetch(apps.fetch('packages_facet'))
    app_services = view.each('app_services').to_a
    assert_equal [[session, template, 'b', []]], app_services.map { |row| granted.fetch(row.fetch('facet')) }
    assert_equal ['b'], app_services.map { |row| services.fetch(row.fetch('service')) }
    assert_equal template, apps.fetch('app_template')
    declared = @codec.schema.services.find { |service| service.fetch(:name) == 'windows' }.fetch(:quantities)
    assert_equal declared, facets.fetch(app_services.first.fetch('facet')).slice(*declared.keys)
  end

  # The home rows the build derives (docs/design-files.md, "A user's home"): every
  # session template but the app template holds one grant of the home service, rights
  # rw and tree home, and the app template none; a source row of the home service, which
  # would state no tree, is refused. The app template given a home row, or a template
  # left out, fails it.
  def test_the_build_derives_a_home_row_for_every_user_template
    outer = 2 * (4096 + 4096) + @codec.constant('windows_pixels_default') + 4096
    roomy = with_windows.sub("  memory 4194304\n  outer 1048576\n", "  memory 16777216\n  outer #{outer}\n")
    home = "service #{@codec.fixed_bytes('home_service').delete("\0")}\n  server @domain.beta\n  interface files\n"
    view = @codec.open('manifest', admit(for_apps(roomy + home + self.class.apps(max: 1), 1)).bytes)
    sessions = view.each('sessions').to_a
    users = sessions.each_index.reject { |index| sessions.fetch(index).fetch('principal') == @codec.constant('mf_none') }
    refute_empty users
    assert_equal sessions.size - 1, users.size
    services = view.each('services').map { |row| view.string(row.fetch('name')) }
    parameters = view.each('facet_parameters').to_a
    first = view.header.fetch('facet_parameters').fetch('offset')
    homes = view.each('facets').select { |facet| services.fetch(facet.fetch('service')) == 'home' }.map do |facet|
      span = facet.fetch('parameters')
      [facet.fetch('grantee_kind'), facet.fetch('grantee'),
       parameters[(span.fetch('offset') - first) / 32, span.fetch('count')].map { |row| row.fetch('scalar') }]
    end
    granted = [@codec.member('files_rights', 'rw'), @codec.member('files_tree', 'home')]
    assert_equal users.map { |index| [@codec.member('mf_grantee', 'session'), index, granted] }, homes.sort
    row = window_facet('own_home', '@domain.alpha', '@service.home')
    refused(Erx::Manifest::Invalid, 'facet.service', for_apps(roomy + home + self.class.apps(max: 1) + row, 1),
            message: /home service/)
  end

  # Property 19's tenth clause (docs/design-files.md, "A user's home"): a user's one
  # place on the data volume is its home, so a grant of the service named data_service,
  # the whole volume, is the system domain's or, only in a development manifest, root's
  # template's, the system principal's; another template's or a configured domain's is
  # refused. The
  # Phase 1 check refuses every release build in check_mode, before any facet, so the
  # release case runs a check whose check_mode lets one through.
  # Seed: the clause binds every row that is not one of the well-known services' own
  # derived rows, so the app template's row of a service named data, which an apps row
  # asks for and which states no tree, is refused as a source row would be, whatever the
  # service's interface.
  def test_an_apps_row_s_grant_of_data_is_refused_as_the_whole_volume
    data = "service #{@codec.fixed_bytes('data_service').delete("\0")}\n  server @domain.beta\n  interface net\n"
    refused(Erx::Manifest::Invalid, 'facet.grantee',
            for_apps(with_display(served: data, grants: []) + self.class.apps(services: 'data'), 8), message: /whole volume/)
  end

  def test_only_roots_template_takes_the_whole_volume_and_only_in_development
    data = "service #{@codec.fixed_bytes('data_service').delete("\0")}\n  server @domain.beta\n  interface files\n"
    system = window_facet('data', 'system', '@service.data')
    root = window_facet('data_session', '@session.system', '@service.data')
    source = with_display(served: data, grants: [system, root])
    admit(source)
    other = window_facet('data_session', '@session.other', '@service.data')
    refused(Erx::Manifest::Invalid, 'facet.grantee', with_display(served: data, grants: [system, other]),
            message: /whole volume/)
    domain = window_facet('data_alpha', '@domain.alpha', '@service.data')
    refused(Erx::Manifest::Invalid, 'facet.grantee', with_display(served: data, grants: [system, domain]),
            message: /whole volume/)
    release = Class.new(Erx::Manifest::Check) { private def check_mode(development:, partial:) = nil }
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @platform),
                                         build_kind: 'release')
    check = lambda do |grants|
      parsed = Erx::Manifest::Frontend.parse(with_display(served: data, grants: grants).sub('flags development', 'flags none'),
                                             version: @codec.constant('manifest_version'))
      release.new(parsed, codec: @codec, context: context, planner: @planner).check
    end
    check.call([system])
    error = assert_raises(Erx::Manifest::Invalid) { check.call([system, root]) }
    assert_equal 'facet.grantee', error.field, error.message
    assert_match(/whole volume/, error.message)
  end

  # Property 19's refusals of what would derive the template wrongly: a source facet
  # carrying a tree, apps or installed, which only a derived row may; a source facet naming the template,
  # which no @session.NAME reaches, since it names no principal; an apps row with no
  # limits session record, or one that does not enable SPACES; and a service whose ABI
  # file leaves a quantity out.
  def test_the_apps_rules_refuse_what_would_derive_the_template_wrongly
    %w[apps installed].each do |tree|
      row = facet('treed', '@domain.alpha', '@service.packages') + "  parameter tree #{tree}\n"
      refused(Erx::Manifest::Invalid, 'facet.parameter', for_apps(@source + self.class.apps + row, 8), message: /carries a tree/)
    end
    app = facet('app_packages', '@session.app', '@service.packages')
    assert_raises(Erx::Manifest::Invalid) { admit(for_apps(@source + self.class.apps + app, 8)) }
    session = /^limits session\n(?:  .*\n)*/
    refused(Erx::Manifest::Invalid, 'apps', for_apps(@source.sub(session, '') + self.class.apps, 8), message: /limits session/)
    flat = @source.sub(session) { |record| record.sub(/^  flags .*$/, '  flags none').sub(/^  spaces .*$/, '  spaces none') }
    refute_equal @source, flat
    refused(Erx::Manifest::Invalid, 'apps', for_apps(flat + self.class.apps, 8), message: /SPACES/)
    bare = Erx::ABI::Syntax.parse("service bare 98\n  served_as message\n", path: 'abi/services/bare.txt')
    sources = Erx::ABI::Sources.read(root: File.expand_path('../..', __dir__))
    codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(
                                  Erx::ABI::SourceSet.new(declarations: sources.declarations + bare, inputs: sources.inputs)
                                ))
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec).merge(platform: @platform))
    source = for_apps(@source + "service bare\n  server @domain.beta\n  interface bare\n" + self.class.apps(services: 'bare'), 8)
    error = assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest.admit(source: source, codec: codec, context: context, planner: @planner)
    end
    assert_equal 'apps.services', error.field, error.message
    assert_match(/declares no max_request/, error.message)
  end

  # Seed: an apps row whose max and the manifest's start rows pass start_rows_max.
  # Each start row is a disabled row of a principal of its own, with a template.
  def test_the_start_rows_and_every_app_s_row_fit_the_start_table
    rows_max = @codec.constant('start_rows_max')
    max = @codec.constant('apps_max_limit')
    starts = (rows_max - max + 1).times.map do |index|
      "principal p#{index}\n  memory 4096\n  grant @share.half\n  domains 0\n  names 1\n" \
        "  default_limits @limits.native\n  ceiling_limits @limits.native\n" \
        "#{self.class.session("p#{index}")}#{self.class.start("p#{index}", "  enable NO\n")}"
    end
    base = with_display(grants: []) + starts.join
    admit(for_apps(base + self.class.apps(max: max - 1), max - 1))
    refused(Erx::Manifest::Invalid, 'apps.max', for_apps(base + self.class.apps(max: max), max), message: /start_rows_max/)
  end

  def test_a_signer_row_holds_an_ed25519_public_key_under_a_unique_name
    key = ->(bytes) { "  key hex:#{'ab' * bytes}\n" }
    admit(@source + "signer dev\n#{key.call(32)}signer ops\n#{key.call(32)}")
    refused(Erx::Manifest::Invalid, 'signer.key', @source + "signer dev\n#{key.call(31)}", message: /signer dev's key is not 32 bytes/)
    refused(Erx::Manifest::Invalid, 'signer.key', @source + "signer dev\n#{key.call(33)}", message: /signer dev's key is not 32 bytes/)
    refused(Erx::Manifest::Invalid, 'signer', @source + "signer dev\n#{key.call(32)}signer dev\n#{key.call(32)}",
            message: /duplicate source alias/)
    assert_raises(Erx::ABI::SchemaError) { admit(@source + "signer dev\n  key \"#{'a' * 32}\"\n") }
  end

  # The development package key is the build's, never a row (docs/design-packaging.md,
  # "The SDK"): a source row named development is refused, the context carries the key
  # only in a development build, as an Ed25519 public key of signer_key_bytes, and a
  # manifest with no apps row, whose machine takes no packages, packs none.
  def test_the_development_key_comes_from_a_development_build_alone
    refused(Erx::Manifest::Invalid, 'signer.name', @source + "signer development\n  key hex:#{'ab' * 32}\n",
            message: /signer development is the build's development package key,/)
    arguments = ManifestContextFixture.arguments(@codec).merge(platform: @platform)
    error = assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest::Context.new(**arguments, build_kind: 'release', development_key: "\x01".b * 32)
    end
    assert_equal 'context.development_key', error.field
    @context = Erx::Manifest::Context.new(**arguments, development_key: "\x01".b * 31)
    refused(Erx::Manifest::Invalid, 'context.development_key', for_apps(@source + self.class.apps, 8),
            message: /the development package key is not 32 bytes/)
    @context = Erx::Manifest::Context.new(**arguments, development_key: "\x01".b * 32)
    assert_equal 0, @codec.open('manifest', admit.bytes).count('development_key')
    assert_equal false, admit.report.fetch('development_key')
  end

  # The published package key, whose private half the tree holds, is never a trust root
  # (docs/design-packaging.md, "The `apps` row"): a signer row of any source holding it,
  # under any name, is refused, and so is a build that hands it over as the development
  # key; a row beside it holding another key is accepted.
  def test_the_published_package_key_is_never_a_trust_root
    published = Erx::PackageKey.published.public_key
    admit(@source + "signer deployer\n  key hex:#{'ab' * 32}\n")
    refused(Erx::Manifest::Invalid, 'signer.key', @source + "signer deployer\n  key hex:#{published.unpack1('H*')}\n",
            message: /\bsigner deployer's key is the published package key, which nothing trusts\z/)
    arguments = ManifestContextFixture.arguments(@codec).merge(platform: @platform)
    @context = Erx::Manifest::Context.new(**arguments, development_key: published)
    refused(Erx::Manifest::Invalid, 'context.development_key', for_apps(@source + self.class.apps, 8),
            message: /\bthe development package key is the published package key, which nothing trusts\z/)
  end

  # The manifest packs the apps row, its services, the package and signer rows and the
  # development key as records the machine reads (abi/manifest.txt), each as the check
  # accepted it; a manifest with none of them packs empty tables.
  def test_the_apps_package_and_signer_rows_are_packed
    with_packages('clock' => 4096, 'quotes' => 4096)
    arguments = ManifestContextFixture.arguments(@codec)
    @context = Erx::Manifest::Context.new(**arguments.merge(platform: @platform, artifacts: @context.artifacts,
                                                            development_key: "\x07".b * 32))
    source = for_apps(@source + self.class.apps(memory: 1 << 20, max: 2) + self.class.package('quotes') +
                       self.class.package('clock', enable: 'YES') + "signer ops\n  key hex:#{'cd' * 32}\n", 2)
    admitted = admit(source)
    assert_equal true, admitted.report.fetch('development_key')
    view = @codec.open('manifest', admitted.bytes)
    assert_equal [{ 'memory' => 1 << 20, 'max' => 2 }],
                 view.each('apps').map { |row| row.except('services', 'app_template', 'packages_facet', 'system_facet') }
    assert_equal 0, view.header.fetch('app_services').fetch('count')
    assert_equal [['clock', 1, "\xab".b * 32], ['quotes', 0, "\xab".b * 32]],
                 view.each('packages').map { |row| [view.string(row.fetch('name')), row.fetch('flags'), row.fetch('sha256')] }
    assert_equal [['ops', "\xcd".b * 32]], view.each('signers').map { |row| [view.string(row.fetch('name')), row.fetch('key')] }
    assert_equal ["\x07".b * 32], view.each('development_key').map { |row| row.fetch('key') }

    @context = Erx::Manifest::Context.new(**arguments.merge(platform: @platform))
    plain = @codec.open('manifest', admit.bytes)
    assert_equal [0] * 5, %w[apps app_services packages signers development_key].map { |name| plain.header.fetch(name).fetch('count') }
  end

  # The context with a package artifact for each name => declared memory of packages,
  # as Erx::ImageApps names them.
  def with_packages(packages, gatt = {})
    arguments = ManifestContextFixture.arguments(@codec)
    artifacts = packages.to_h do |name, memory|
      ["package-#{name}", { 'kind' => 'package', 'name' => name, 'memory' => memory, 'sha256' => 'ab' * 32,
                            'gatt' => gatt.fetch(name, []) }]
    end
    @context = Erx::Manifest::Context.new(**arguments.merge(platform: @platform, artifacts: arguments.fetch(:artifacts).merge(artifacts)))
  end

  def self.package(name, input: "package-#{name}", enable: nil)
    "package #{name}\n  input @artifact.#{input}\n#{"  enable #{enable}\n" if enable}"
  end

  # Property 19's fifth clause on the host: each package row is bound to the artifact
  # the build's file check described, and the build record lists each with its header's
  # SHA-256, enabled only when its row says YES.
  def test_a_package_row_is_bound_to_its_package_and_recorded
    with_packages('clock' => 4096, 'quotes' => 4096)
    source = for_apps(@source + self.class.apps + self.class.package('quotes') + self.class.package('clock', enable: 'YES'), 8)
    assert_equal [{ 'name' => 'clock', 'sha256' => 'ab' * 32, 'enabled' => true },
                  { 'name' => 'quotes', 'sha256' => 'ab' * 32, 'enabled' => false }],
                 admit(source).report.fetch('packages')
  end

  # Seeds: a row whose input is no package artifact or another app's package, rows past
  # the apps row's max or with no apps row, and enabled packages whose declared memory
  # passes the apps budget, which a row left disabled does not count against.
  def test_a_package_row_is_refused_unless_its_package_fits_the_apps_row
    with_packages('clock' => 65_536, 'quotes' => 4096)
    apps = for_apps(@source + self.class.apps(max: 1), 1)
    refused(Erx::Manifest::Invalid, 'package.input', apps + self.class.package('clock', input: 'app'), message: /no package artifact/)
    refused(Erx::Manifest::Invalid, 'package.input', apps + self.class.package('clock', input: 'package-quotes'),
            message: /is the package of quotes/)
    refused(Erx::Manifest::Invalid, 'package', apps + self.class.package('clock') + self.class.package('quotes'),
            message: /pass the apps row's max, 1/)
    refused(Erx::Manifest::Invalid, 'package', @source + self.class.package('clock'), message: /max, 0/)
    roomy = for_apps(@source + self.class.apps(memory: 65_536, max: 2), 2)
    admit(roomy + self.class.package('clock', enable: 'YES') + self.class.package('quotes'))
    refused(Erx::Manifest::Invalid, 'package.enable',
            roomy + self.class.package('clock', enable: 'YES') + self.class.package('quotes', enable: 'YES'),
            message: /declare 69632 bytes, past the apps budget of 65536/)
  end

  # Admission's steps 7 and 8 in the build's run over the package rows
  # (docs/design-packaging.md, "Admission", PK13): a package of the image declares only
  # GATT services the apps row's gatt offers, and no two declare one. Seeds: a package
  # declaring a service the row does not offer, and two declaring nus.
  def test_a_package_row_declares_only_offered_gatt_services_none_twice
    ble = "service ble\n  server @domain.beta\n  interface ble\n"
    source = for_apps(@source + ble + self.class.apps(services: 'ble', gatt: 'nus', max: 2), 2)
    rows = self.class.package('clock') + self.class.package('quotes')
    with_packages({ 'clock' => 4096, 'quotes' => 4096 }, { 'clock' => %w[nus] })
    admit(source + rows)
    with_packages({ 'clock' => 4096, 'quotes' => 4096 }, { 'clock' => %w[nus], 'quotes' => %w[hrs] })
    refused(Erx::Manifest::Invalid, 'package.input', source + rows,
            message: /package quotes declares the GATT service "hrs", which the apps row's gatt does not offer/)
    with_packages({ 'clock' => 4096, 'quotes' => 4096 }, { 'clock' => %w[nus], 'quotes' => %w[nus] })
    refused(Erx::Manifest::Invalid, 'package.input', source + rows,
            message: /packages clock and quotes both declare the GATT service "nus"/)
  end

  # Property 8's line clause (docs/design-system.md, "The manifest"; docs/design-bluetooth.md,
  # "The controller's line"): the platform with two more UARTs, each a unit of its own,
  # line_a and line_b, held by the system domain unless HOLDERS says otherwise, the
  # system domain's line service, and GRANTS (ManifestContextFixture.with_line).
  def line_context(lines: {})
    Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                       .merge(platform: ManifestContextFixture.line_platform(@platform, lines: lines)))
  end

  def with_line(*grants, base: @source, holders: {}, serial: false) = ManifestContextFixture.with_line(base, *grants, holders: holders, serial: serial)
  def line_grant(*given, **options)
    ManifestContextFixture.line_grant(*given, floor: @codec.constant('files_max_frame_min'), **options)
  end

  def refused_line(field, source, message, context: line_context)
    error = assert_raises(Erx::Manifest::Invalid) { admit(source, context: context) }
    assert_equal field, error.field, error.message
    assert_match message, error.message
  end

  # A line grant's device, a device reference, is packed as its device row's index.
  def test_a_line_grant_packs_its_device_as_its_device_row
    view = @codec.open('manifest', admit(with_line(line_grant('la', '@domain.alpha', '/pl011@9050000')), context: line_context).bytes)
    uart = rows(view, 'devices').index { |device| view.string(device.fetch('path')) == '/pl011@9050000' }
    kinds = %w[device u64 identifier].map { |kind| @codec.member('mf_parameter_kind', kind) }
    assert_equal [[1, kinds[0], 0, '', uart], [2, kinds[1], 115_200, '', 0], [3, kinds[2], 0, 'none', 0]],
                 rows(view, 'facet_parameters').map { |row| [*row.values_at('key', 'kind', 'scalar'), view.string(row.fetch('bytes')), row.fetch('index')] }
  end

  # Seeds: a device naming no placed device, a device that is neither a UART nor a serial
  # device, the console's and the host link's UARTs, a UART another domain holds, a flow
  # of neither word, and a UART's grant without its rate or its flow.
  def test_a_line_grant_names_a_uart_of_the_system_domain_s_that_no_other_use_takes
    { '/pl011@9070000' => /names no placed device/, '/virtio_mmio@a003e00' => /names no UART or serial device/,
      @platform.fetch('console') => /console's or the host link's/,
      @platform.fetch('hostlink') => /console's or the host link's/ }.each do |device, message|
      refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', device)), message)
    end
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'), holders: { 'line_a' => '@domain.beta' }),
                 /not the system domain's/)
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000', flow: 'xon')), /none or rts_cts/)
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000', rate: nil)), /states no rate/)
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000', flow: nil)), /none or rts_cts/)
    admit(with_line(line_grant('la', '@domain.alpha', '/pl011@9050000', flow: 'rts_cts')), context: line_context)
  end

  # A virtio console's line grant names its serial device and states no rate or flow,
  # and the device is the system domain's. Seeds: a serial grant with a rate, one with a
  # flow, and a serial device another domain holds.
  def test_a_line_grant_names_a_serial_device_without_a_rate_or_a_flow
    serial = ManifestContextFixture::LINE_SERIAL.fetch(1)
    view = @codec.open('manifest', admit(with_line(line_grant('la', '@domain.alpha', serial, rate: nil, flow: nil), serial: true),
                                         context: line_context).bytes)
    index = rows(view, 'devices').index { |device| view.string(device.fetch('path')) == serial }
    assert_equal [[1, index]], rows(view, 'facet_parameters').map { |row| row.values_at('key', 'index') }
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', serial, flow: nil), serial: true), /states no rate or flow/)
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', serial, rate: nil), serial: true), /states no rate or flow/)
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', serial, rate: nil, flow: nil), serial: true,
                                              holders: { 'line_serial' => '@domain.beta' }), /not the system domain's/)
  end

  # Rule serial-device-granted. Seeds: a serial device the system domain holds that no
  # line grant names, beside a UART's grant and with no line grant at all; and one a
  # configured domain holds.
  def test_every_placed_serial_device_is_named_by_a_line_grant
    message = %r{serial device /virtio_mmio@a008000 is named by no line grant}
    refused_line('devices.role', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'), serial: true), message)
    refused_line('devices.role', with_line(serial: true), message)
    refused_line('devices.role', with_line(serial: true, holders: { 'line_serial' => '@domain.beta' }), message)
  end

  # Seeds: a line UART on the console's interrupt line, and a line service a configured
  # domain serves.
  def test_the_system_domain_serves_the_line_off_the_console_s_interrupt_line
    grant = with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'))
    console_line = @platform.fetch('units').flat_map { |unit| unit.fetch('devices') }
                            .find { |device| device['path'] == @platform.fetch('console') }.fetch('line')
    refused_line('facet.parameter', grant, /share interrupt line #{console_line}/, context: line_context(lines: { 'line_a' => console_line }))
    refused_line('service.server', grant.sub("service line\n  server system\n", "service line\n  server @domain.beta\n"),
                 /only the system domain serves the line/)
  end

  # The line interface's service is named line, the one name its lookup (erx_uart_sup),
  # its serve call, the facet-names check and its grantees' mount (erx_ns, /line) take.
  # Seeds: the line service named bt_line, and a system service named line of another
  # interface.
  def test_the_line_interface_s_service_is_named_line
    grant = with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'))
    admit(grant, context: line_context)
    refused_line('service.name', grant.sub("service line\n", "service bt_line\n").sub('@service.line', '@service.bt_line'),
                 /bt_line is named line exactly when it is of the line interface/)
    refused_line('service.name', with_line.sub("interface line\n", "interface net\n"),
                 /service line is named line exactly when/)
  end

  # Seeds: two grants of one UART; two line grants of different UARTs, since one line
  # service serves one line (TODO.md); and a grant to a session template.
  def test_a_manifest_grants_one_line_to_a_configured_domain
    refused_line('facet.parameter', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'),
                                              line_grant('lb', '@domain.beta', '/pl011@9050000')), /two line grants name one device/)
    refused_line('facet.service', with_line(line_grant('la', '@domain.alpha', '/pl011@9050000'),
                                            line_grant('lb', '@domain.beta', '/pl011@9060000')), /at most one line grant/)
    refused_line('facet.grantee', with_line(line_grant('ls', '@session.system', '/pl011@9050000'),
                                            base: with_session(self.class.session)), /no configured domain/)
  end

  def codec_with(declaration) = ManifestContextFixture.codec_with(declaration)

  # A context whose abi/gatt declares ManifestContextFixture::GATT_NAMES.
  def gatt_context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec).merge(platform: @platform,
                                                                                                gatt_services: ManifestContextFixture::GATT_NAMES))

  def ble_grant(services, **options) = ManifestContextFixture.ble_grant(services, **options)

  # An identifier set, a ble grant's services, packs one row an element, its names
  # lexicographic over unsigned bytes, a name before every longer name it begins: nus,
  # nusb, nv in that order, whatever order its source lines state them in. A name twice
  # and a ninth name are refused.
  def test_an_identifier_set_packs_in_byte_order
    context = gatt_context
    ordered = %w[nus nusb nv]
    kind = @codec.member('mf_parameter_kind', 'identifier')
    ordered.permutation.each do |names|
      view = @codec.open('manifest', admit(@source + ble_grant(names), context: context).bytes)
      assert_equal ordered.map { |name| [1, kind, name] },
                   rows(view, 'facet_parameters').map { |row| [row.fetch('key'), row.fetch('kind'), view.string(row.fetch('bytes'))] },
                   names.join(' ')
    end
    { %w[nus nus] => /states "nus" twice/, ManifestContextFixture::GATT_NAMES => /states over 8 values/ }.each do |names, message|
      error = assert_raises(Erx::Manifest::Invalid, names.join(' ')) { admit(@source + ble_grant(names), context: context) }
      assert_equal 'facet.parameter', error.field, error.message
      assert_match message, error.message
    end
  end

  # ble_grant (docs/design-bluetooth.md, "Declarations: `abi/gatt`"): a grant of the ble
  # service, served by a configured domain, to another configured domain, naming services
  # abi/gatt declares, packs. Each seeded violation differs from it in one thing and is
  # refused: the service of the ble interface named otherwise, a service named ble of
  # another interface, the service served by the system domain, the grant to the system
  # domain (B8), the grant to root's session template, and a name abi/gatt does not declare,
  # against the tree's declarations
  # and against the context's.
  def test_a_ble_grant_names_declared_services_of_the_ble_service
    admit(@source + ble_grant(%w[nus]))
    {
      ['service.name', ble_grant(%w[nus], service: 'gatt')] => /service gatt is named ble exactly when it is of the ble interface/,
      ['service.name', service('ble', '@domain.beta')] => /service ble is named ble exactly when it is of the ble interface/,
      ['service.server', ble_grant(%w[nus], server: 'system')] => /service ble is served by no configured domain/,
      ['facet.grantee', ble_grant(%w[nus], grantee: 'system')] => /ble grant nm is granted to the system domain/,
      ['facet.grantee', ble_grant(%w[nus], grantee: '@session.system')] => /ble grant nm is granted to root's session template/,
      ['facet.parameter', ble_grant(%w[nus nusb])] => /ble grant nm names "nusb", which abi\/gatt does not declare/
    }.each do |(field, grant), message|
      refused(Erx::Manifest::Invalid, field, with_session(self.class.session) + grant, message: message)
    end
    error = assert_raises(Erx::Manifest::Invalid) do
      admit(@source + ble_grant(%w[nus]), context: Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec)
                                                                                 .merge(platform: @platform, gatt_services: %w[nusb])))
    end
    assert_equal 'facet.parameter', error.field, error.message
    assert_match(/names "nus", which abi\/gatt does not declare/, error.message)
  end

  # The Bluetooth domain's served set (docs/design-bluetooth.md, "The Bluetooth domain" and
  # "Declarations: `abi/gatt`"): the build derives the server's -erx_bt services, first
  # among init's words after the boot binding and closed by --, from the ble rows alone:
  # a grant naming nus serves nus and no other declaration of the tree's, bondcheck among
  # them; a grant and the apps row's gatt serve their names together, sorted and quoted; a
  # ble service with no grant serves none; and no other domain gets the key. A row naming
  # the key itself is refused, as one naming -boot is, whether or not it serves ble. Plain
  # words at the head of the row's init arguments stay plain arguments: under the
  # oracle's erl, init and application_controller give the key the derived value alone.
  def test_the_ble_server_serves_what_the_ble_rows_name
    served = lambda do |source, context: @context|
      view = @codec.open('manifest', admit(source, context: context).bytes)
      rows(view, 'domains').to_h { |row| [view.string(row.fetch('name')), view.string(row.fetch('args'))] }
    end
    key = ->(names) { "\0--\0-erx_bt\0services\0#{names}\0--\0" }
    granted = served.call(@source + ble_grant(%w[nus]))
    assert_includes granted.fetch('beta'), key.call("['nus']")
    refute_includes granted.fetch('alpha'), 'services'
    offered = for_apps(@source + ble_grant(%w[nv]) + self.class.apps(services: 'ble', gatt: 'nus'), 8)
    assert_includes served.call(offered, context: gatt_context).fetch('beta'), key.call("['nus','nv']")
    assert_includes served.call(@source + "service ble\n  server @domain.beta\n  interface ble\n").fetch('beta'), key.call('[]')
    ['-erx_bt services x', '-erx_bt name y services x', '-- -erx_bt services x -eval ok'].each do |args|
      refused(Erx::Manifest::Invalid, 'domain.args', @source + "  args \"#{args}\"\n" + ble_grant(%w[nus]),
              message: /the arguments name -erx_bt services, which the build derives/)
    end
    refused(Erx::Manifest::Invalid, 'domain.args', @source + "  args \"-erx_bt services x\"\n",
            message: /the arguments name -erx_bt services, which the build derives/)
    continued = served.call(@source + "  args \"-- services [bondcheck] -eval ok\"\n" + ble_grant(%w[nus])).fetch('beta')
    assert_equal "{ok,[nus]} [\"services\",\"[bondcheck]\"]\n", erx_bt_keys(continued)
  end

  # Every domain's declaration (docs/design-system.md, "The declaration"): the build derives
  # -erx_serves, each service of the row's server as its name and its interface's number,
  # sorted by name, first among init's words after the boot binding and closed by --; a
  # row that serves nothing gets the key and its -- alone; the system domain's, its
  # services', follows system_args's first --. A domain row or system_args naming the key
  # is refused. Under the oracle's erl, init gives the key one occurrence, the derived
  # words, and plain words at the head of a row's init arguments stay plain.
  def test_every_domain_declares_what_it_serves
    key = ->(*words) { ['--', '-erx_serves', *words, '--'].join("\0") }
    source = @source + "  args \"-- head words\"\n" + service('zeta', '@domain.beta') + service('eta', '@domain.beta') +
             service('omega', 'system')
    view = @codec.open('manifest', admit(source).bytes)
    args = rows(view, 'domains').to_h { |row| [view.string(row.fetch('name')), view.string(row.fetch('args'))] }
    assert_includes args.fetch('beta'), "\0#{key.call('eta', '1', 'zeta', '1')}\0"
    assert_includes args.fetch('alpha'), "\0#{key.call}\0"
    system = rows(view, 'services').select { |row| row.fetch('server') == @codec.constant('mf_none') }
                                   .flat_map { |row| [view.string(row.fetch('name')), row.fetch('interface').to_s] }
    assert_equal %w[omega 1], system
    assert view.string(view.header.fetch('system_args')).start_with?("#{key.call(*system)}\0")
    assert_equal "{ok,[[\"eta\",\"1\",\"zeta\",\"1\"]]} [\"head\",\"words\"]\n", init_view(args.fetch('beta'))
    ['-erx_serves', '-- -erx_serves x 1', '-- -extra -erx_serves'].each do |words|
      refused(Erx::Manifest::Invalid, 'domain.args', @source + "  args \"#{words}\"\n",
              message: /the arguments name -erx_serves, which the build derives/)
    end
    refused(Erx::Manifest::Invalid, 'machine.system_args', @source.sub(/^  system_args "/, '\0-erx_serves x 1 '),
            message: /the arguments name -erx_serves, which the build derives/)
  end

  # What the oracle's erl's init makes of a domain's packed arguments past the boot
  # binding: the -erx_serves key's occurrences and the plain arguments.
  def init_view(packed)
    words = packed.split("\0")
    report = 'io:format("~p ~p~n", [init:get_argument(erx_serves), init:get_plain_arguments()]), halt().'
    output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell',
                                     *words.drop(words.index('-boot') + 3), '-eval', report, stdin_data: '')
    assert status.success?, output
    output
  end

  # What the oracle's erl makes of a domain's packed arguments past the boot binding:
  # erx_bt's services key, as application_controller loads it, and the plain arguments.
  def erx_bt_keys(packed)
    words = packed.split("\0")
    init = words.drop(words.index('-boot') + 3)
    report = 'ok = application:load({application, erx_bt, [{env, []}]}), ' \
             'io:format("~w ~p~n", [application:get_env(erx_bt, services), init:get_plain_arguments()]), halt().'
    output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', *init, '-eval', report,
                                     stdin_data: '')
    assert status.success?, output
    output
  end

  # A start row's template (docs/design-bluetooth.md, "Who holds `ble`"): a ble grant to
  # the session template of principal other, which has a start row and a domains quota
  # of 1, packs, since one session of it lives at a time. Each seed differs from it in
  # one thing and is refused as a grant to a session template: other with no start row,
  # other with a quota of 2, and the start row the system principal's, not other's. A
  # grant to root's session template is refused as root's even when the system principal
  # has a start row and a quota of 1 (its configured domains given to other): a radio
  # peer reaches root's line only through bleuart's login, never root's console template.
  def test_a_start_rows_template_with_one_domain_holds_ble
    source = lambda do |start: self.class.start('other'), domains: 1|
      with_display(start, served: '', grants: [ble_grant(%w[nus], grantee: '@session.other')])
        .sub("principal other\n  memory 1048576\n  grant @share.half\n  domains 0\n",
             "principal other\n  memory 1048576\n  grant @share.half\n  domains #{domains}\n")
        .sub(ManifestContextFixture::MAX_DOMAINS) { |line| line.sub(/\d+$/) { |count| (count.to_i + domains).to_s } }
    end
    admit(source.call)
    roots = with_display(self.class.start, served: '', grants: [ble_grant(%w[nus], grantee: '@session.system')])
            .gsub("  principal @principal.system\n  limits @limits.app\n", "  principal @principal.other\n  limits @limits.app\n")
            .sub("principal other\n  memory 1048576\n  grant @share.half\n  domains 0\n",
                 "principal other\n  memory 1048576\n  grant @share.half\n  domains 2\n")
            .sub(ManifestContextFixture::SYSTEM_QUOTA) { "#{Regexp.last_match(1)}1" }
            .sub(ManifestContextFixture::MAX_DOMAINS) { "#{Regexp.last_match(1)}3" }
    [source.call(start: ''), source.call(domains: 2), source.call(start: self.class.start)].each do |seeded|
      refused(Erx::Manifest::Invalid, 'facet.grantee', seeded, message: /ble grant nm is granted to a session template/)
    end
    refused(Erx::Manifest::Invalid, 'facet.grantee', roots, message: /ble grant nm is granted to root's session template/)
  end

  # The app template's ble row (docs/design-bluetooth.md, "Who holds `ble`";
  # docs/design-packaging.md, "The apps row", property 19's first clause, PK13): an apps
  # row naming ble with gatt nus derives the template's row of the ble service, whose
  # services are nus and whose quantities are the ble interface's, and ble_grant takes
  # it, the one template row it takes. Each seeded row differs from it in one thing and
  # is refused: ble with no gatt, gatt with no ble, a gatt name abi/gatt does not
  # declare, nine names, and a name a configured domain's ble row names, which no app may
  # then be offered.
  def test_the_apps_rows_gatt_is_the_app_templates_ble_grant
    ble = "service ble\n  server @domain.beta\n  interface ble\n"
    offered = ->(gatt, services: 'ble') { for_apps(@source + ble + self.class.apps(services: services, gatt: gatt), 8) }
    view = @codec.open('manifest', admit(offered.call('nus')).bytes)
    service = rows(view, 'services').index { |row| view.string(row.fetch('name')) == 'ble' }
    first = view.header.fetch('facet_parameters').fetch('offset')
    parameters = rows(view, 'facet_parameters')
    granted = rows(view, 'facets').select { |row| row.fetch('service') == service }.map do |row|
      span = row.fetch('parameters')
      named = parameters[(span.fetch('offset') - first) / 32, span.fetch('count')].map { |item| view.string(item.fetch('bytes')) }
      [row.fetch('grantee_kind'), named, row.fetch('max_request'), row.fetch('in_flight')]
    end
    assert_equal [[@codec.member('mf_grantee', 'session'), ['nus'], 1024, 16]], granted
    {
      ['apps.gatt', offered.call(nil)] => /services names ble, so the row states gatt/,
      ['apps.gatt', offered.call('nus', services: nil)] => /gatt is stated, so services names ble/,
      ['facet.parameter', offered.call('nusb')] => %r{the apps row's gatt names "nusb", which abi/gatt does not declare},
      ['facet.parameter', for_apps(@source + ble_grant(%w[nus]) + self.class.apps(services: 'ble', gatt: 'nus'), 8)] =>
        /(ble grant nm and the apps row's gatt|the apps row's gatt and ble grant nm) both name "nus"/
    }.each do |(field, source), message|
      refused(Erx::Manifest::Invalid, field, source, message: message)
    end
    error = assert_raises(Erx::Manifest::Invalid) do
      admit(offered.call(ManifestContextFixture::GATT_NAMES.join(' ')), context: gatt_context)
    end
    assert_equal 'apps.gatt', error.field, error.message
    assert_match(/gatt names over 8 services/, error.message)
  end

  # Seed: a service of another interface whose parameters name line_grant. Its facet is
  # the line checker's, which refuses its uart, the console's; a checker choosing its
  # facets by interface would accept it unchecked.
  def test_a_facet_goes_to_the_checker_its_service_names_whatever_its_interface
    codec = codec_with("service spare 98\n  served_as tree\n  parameter device 1 device one target devices checked_by line_grant\n" \
                       "  parameter rate 2 u64 optional range 115200 115200 checked_by line_grant\n" \
                       "  parameter flow 3 identifier optional bytes 7 checked_by line_grant\n")
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec)
                                                                .merge(platform: ManifestContextFixture.line_platform(@platform)))
    grant = line_grant('sp', '@domain.alpha', @platform.fetch('console')).sub('@service.line', '@service.sp')
    source = with_line + "service sp\n  server system\n  interface spare\n" + grant
    error = assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest.admit(source: source, codec: codec, context: context, planner: @planner)
    end
    assert_equal 'facet.parameter', error.field, error.message
    assert_match(/console's or the host link's/, error.message)
  end

  # Seed: a service of another interface whose parameters name windows_grant is a
  # display's, so it has a display record as every windows service does.
  def test_a_service_naming_the_display_checker_is_a_display_whatever_its_interface
    codec = codec_with("service pane 97\n  served_as tree\n" \
                       "  parameter pixels 2 u64 optional range 4096 1099511627776 checked_by windows_grant\n")
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec).merge(platform: @platform))
    error = assert_raises(Erx::Manifest::Invalid) do
      Erx::Manifest.admit(source: @source + "service pn\n  server @domain.beta\n  interface pane\n", codec: codec,
                          context: context, planner: @planner)
    end
    assert_equal 'display.name', error.field, error.message
  end

  # Seed: one service's parameters naming two checkers, which no dispatch could serve.
  def test_a_service_names_one_grant_checker
    assert_raises(Erx::ABI::SchemaError) do
      codec_with("service mixed 96\n  served_as message\n  parameter a 1 u64 one range 1 2 checked_by line_grant\n" \
                 "  parameter b 2 u64 one range 1 2 checked_by windows_grant\n")
    end
  end

  # The configured login front ends of docs/design-login.md, "Who holds it", and two
  # domains that are none: the Bluetooth domain and another, each a configured domain of
  # its name.
  LOGIN_DOMAINS = %w[ssh web bluetooth alpha].freeze
  # bleuart's principal, whose session template is the third front end. Only the build
  # check reads it, so it needs no domain quota.
  BLEUART = "principal bleuart\n  memory 1048576\n  grant @share.users\n  domains 0\n  names 1\n" \
            "  default_limits @limits.native\n  ceiling_limits @limits.native\n"

  # The login service, served by server, the domains LOGIN_DOMAINS names, root's
  # template and bleuart's; or, with bleuart_domain, a configured domain named bleuart in
  # place of its principal and template, since no domain shares a principal's name.
  def with_login(server: 'system', bleuart_domain: false)
    domains = LOGIN_DOMAINS + (bleuart_domain ? %w[bleuart] : [])
    bleuart = bleuart_domain ? '' : BLEUART + self.class.session('bleuart')
    with_domains(*domains.map { |name| self.class.domain(name) }) + bleuart + self.class.session +
      "service login\n  server #{server}\n  interface login\n"
  end

  # A login facet row named name to grantee, a manifest token (system, @domain.NAME or
  # @session.PRINCIPAL), listing operations, minting line and allowing logins.
  def login_grant(name, grantee:, operations:, line:, logins:, max_request: 131_072, in_flight: 8)
    "facet #{name}\n  grantee #{grantee}\n  service @service.login\n  operations #{operations}\n" \
      "  max_request #{max_request}\n  in_flight #{in_flight}\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n" \
      "  parameter line \"#{line}\"\n  parameter logins #{logins}\n"
  end

  # Each front end's row as the table states it.
  SSH_LOGIN = { grantee: '@domain.ssh', operations: 'cookie,key_ok,login_key,login_passphrase', line: 'tty_line',
                logins: 128 }.freeze
  WEB_LOGIN = { grantee: '@domain.web', operations: 'login_passphrase', line: 'web_line', logins: 16 }.freeze
  BLEUART_LOGIN = { grantee: '@session.bleuart', operations: 'root_line', line: 'tty_line', logins: 1 }.freeze

  # login_grant (docs/design-login.md, "Who holds it"): each front end's row, as the
  # table states it, packs, the three together and each alone.
  def test_a_login_grant_to_each_front_end_packs
    holders = [SSH_LOGIN, WEB_LOGIN, BLEUART_LOGIN]
    view = @codec.open('manifest', admit(with_login + holders.each_with_index.map { |row, at| login_grant("lg#{at}", **row) }.join).bytes)
    assert_equal 3, rows(view, 'facets').count { |row| view.string(row.fetch('name')).start_with?('lg') }
    holders.each { |row| admit(with_login + login_grant('lg', **row)) }
  end

  # Each seeded violation differs from an accepted row in one thing and is refused: the
  # service served by a configured domain; a row to a domain the table does not list (the
  # Bluetooth domain, another), to a configured domain that shares bleuart's name, or to
  # another session template; a row whose line, logins or operations (one more, one
  # fewer) differ from its holder's; and two rows for one holder. A row to the system
  # domain is refused by normalize_facets's rule that the system domain takes no facet of
  # its own service, before the login check.
  def test_a_login_grant_is_held_to_its_front_end_s_row
    web = ->(**change) { login_grant('lg', **WEB_LOGIN, **change) }
    ssh = ->(**change) { login_grant('lg', **SSH_LOGIN, **change) }
    bleuart = ->(**change) { login_grant('lg', **BLEUART_LOGIN, **change) }
    {
      ['service.server', with_login(server: '@domain.alpha') + web.call] => /service login is served by a configured domain/,
      ['facet.grantee', with_login + web.call(grantee: '@domain.bluetooth')] =>
        /login grant lg is granted to domain bluetooth, which docs\/design-login.md lists as no login front end/,
      ['facet.grantee', with_login + web.call(grantee: '@domain.alpha')] => /login grant lg is granted to domain alpha/,
      ['facet.grantee', with_login + web.call(grantee: '@session.system')] =>
        /login grant lg is granted to session template system, which docs\/design-login.md lists as no login front end/,
      ['facet.grantee', with_login(bleuart_domain: true) + bleuart.call(grantee: '@domain.bleuart')] =>
        /login grant lg is granted to domain bleuart, which docs\/design-login.md lists as no login front end/,
      ['facet.parameter', with_login + bleuart.call(logins: 2)] =>
        /login grant lg to session template bleuart allows 2 logins, where bleuart's login row allows 1/,
      ['facet.operations', with_login + web.call(operations: 'login_passphrase,root_line')] =>
        /login grant lg to domain web lists root_line, which web's login row does not/,
      ['facet.operations', with_login + bleuart.call(operations: 'login_passphrase')] =>
        /login grant lg to session template bleuart lists login_passphrase, which bleuart's login row does not/,
      ['facet.grantee', with_login + web.call(grantee: 'system')] => /the system domain takes no facet of its own service/,
      ['facet.parameter', with_login + web.call(line: 'tty_line')] =>
        /login grant lg to domain web mints tty_line, where web's login row mints web_line/,
      ['facet.parameter', with_login + web.call(logins: 17)] => /login grant lg to domain web allows 17 logins, where web's login row allows 16/,
      ['facet.parameter', with_login + ssh.call(logins: 64)] => /allows 64 logins, where ssh's login row allows 128/,
      ['facet.operations', with_login + web.call(operations: 'cookie,login_passphrase')] =>
        /login grant lg to domain web lists cookie, which web's login row does not/,
      ['facet.operations', with_login + ssh.call(operations: 'key_ok,login_key,login_passphrase')] =>
        /login grant lg to domain ssh omits cookie, which ssh's login row lists/,
      ['facet.max_request', with_login + web.call(max_request: 131_073)] =>
        /login grant lg to domain web has max_request 131073, where the login interface's is 131072/,
      ['facet.max_request', with_login + ssh.call(max_request: 65_536)] => /has max_request 65536, where the login interface's is 131072/,
      ['facet.in_flight', with_login + web.call(in_flight: 9)] => /has in_flight 9, where the login interface's is 8/,
      ['facet.in_flight', with_login + ssh.call(in_flight: 1)] => /has in_flight 1, where the login interface's is 8/,
      ['facet.grantee', with_login + login_grant('lga', **WEB_LOGIN) + login_grant('lgb', **WEB_LOGIN)] =>
        /domain web holds more than one login grant/
    }.each do |(field, source), message|
      refused(Erx::Manifest::Invalid, field, source, message: message)
    end
  end
end
