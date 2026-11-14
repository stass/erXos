# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

# Phase 1's manifest check over configured domains (docs/design-stopgap.md, "The
# Phase 1 manifest check"): the kept properties a domain row brings, each with a
# seeded violation, and the refusals it adds, each with a seeded record. Every seed
# edits the real development manifest with two configured domains, alpha and beta,
# added, so a seed fails for its own reason. A recording planner stands in for the
# domain library's host build, which test/host/dom_planner_test.rb runs.
class ManifestDomainsTest < Minitest::Test
  APP_LIMITS = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
               "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
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
    @plain = ManifestContextFixture.sessionless(File.binread(File.join(root, 'config/manifest/qemu-virt-development.txt')))
    @platform = JSON.parse(File.read(File.join(root, 'config/platforms/qemu-virt.json')))
    @source = with_domains(self.class.domain('alpha'), self.class.domain('beta', flags: 'rescue'))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: @platform))
    @planner = RecordingPlanner.new
  end

  # The rows, with the system principal's domain quota covering them, and max_domains
  # the sum of the quotas, as property 4 asks.
  def with_domains(*rows)
    ManifestContextFixture.with_quota(@plain, rows.size) + APP_LIMITS + rows.join
  end

  def admit(source = @source, planner: @planner)
    Erx::Manifest.admit(source: source, codec: @codec, context: @context, planner: planner)
  end

  def refused(klass, property, field, source = @source, planner: @planner, message: nil)
    error = assert_raises(klass) { admit(source, planner: planner) }
    assert_equal property, error.property, error.message
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

  # A row's boot_timeout_s reaches the encoded row; a row without one gets
  # boot_timeout_default_s; 0 and anything past boot_timeout_max_s are refused.
  def test_a_configured_domains_boot_timeout_is_its_own_or_the_default_within_bounds
    alpha = "  restart_period_s 5\ndomain beta"
    view = @codec.open('manifest', admit(@source.sub(alpha, "  restart_period_s 5\n  boot_timeout_s 90\ndomain beta")).bytes)
    assert_equal [90, @codec.constant('boot_timeout_default_s')], rows(view, 'domains').map { |row| row.fetch('boot_timeout_s') }
    [0, @codec.constant('boot_timeout_max_s') + 1].each do |seconds|
      refused(Erx::Manifest::Invalid, 'source', 'domain.boot_timeout_s',
              @source.sub(alpha, "  restart_period_s 5\n  boot_timeout_s #{seconds}\ndomain beta"))
    end
  end

  def test_the_report_counts_the_planned_domains
    report = admit.report
    assert_equal 'stopgap', report.fetch('mode')
    assert_equal 2, report.fetch('child_plan_instances')
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
    error = refused(Erx::Manifest::Invalid, 12, 'view', planner: ->(_view) { { 'refused' => 'manifest: why' } })
    assert_match(/refuses the manifest's view: why\z/, error.message)
  end

  def test_a_manifest_without_domains_needs_no_planner
    plain = Erx::Manifest.admit(source: @plain, codec: @codec, context: @context, planner: nil)
    assert_equal 0, plain.report.fetch('child_plan_instances')
  end

  # The system principal's template gives root's console session, which needs the
  # planner (property 17), so without one such a manifest fails closed.
  def test_root_s_console_session_needs_a_planner
    refused(Erx::Manifest::Unsupported, 12, 'planner', @plain + self.class.session, planner: nil)
  end

  # Property 1: a unit's holder is the system domain or a configured domain.
  def test_a_unit_held_by_a_configured_domain_is_admitted
    source = @source.sub("placement \"block\"\n  holder system", "placement \"block\"\n  holder @domain.beta")
    view = @codec.open('manifest', admit(source).bytes)
    assert_includes rows(view, 'units').map { |row| row.fetch('holder') }, 1
  end

  def test_a_unit_held_by_no_configured_domain_is_refused
    source = @source.sub("placement \"block\"\n  holder system", "placement \"block\"\n  holder @domain.absent")
    refused(Erx::Manifest::Invalid, 1, 'unit.holder', source)
  end

  # Property 2: services, facets and introductions name what the manifest contains.
  def test_a_service_of_a_configured_domain_is_admitted
    view = @codec.open('manifest', admit(@source + service('probe', '@domain.alpha')).bytes)
    assert_equal [0], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_a_service_of_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 2, 'service.server', @source + service('probe', '@domain.absent'))
  end

  def test_a_facet_naming_no_service_is_refused
    refused(Erx::Manifest::Invalid, 2, 'facet.service', @source + facet('f', '@domain.alpha', '@service.absent'))
  end

  def test_a_facet_granted_to_neither_the_system_domain_nor_a_configured_domain_is_refused
    source = @source + service('b', '@domain.beta') + facet('f', '@domain.absent', '@service.b')
    refused(Erx::Manifest::Invalid, 2, 'facet.grantee', source)
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

  # The registry installs a facet under its service's name, so one grantee takes one
  # facet of a service name, and the system domain none of its own service.
  def test_two_facets_of_one_service_name_to_one_grantee_are_refused
    source = @source + service('b', '@domain.beta') + facet('ab', '@domain.alpha', '@service.b') +
             facet('ab2', '@domain.alpha', '@service.b')
    refused(Erx::Manifest::Invalid, 2, 'facet.service', source)
  end

  def test_a_facet_of_the_system_domains_own_service_to_it_is_refused
    refused(Erx::Manifest::Invalid, 2, 'facet.grantee', @source + service('probe', 'system') + facet('f', 'system', '@service.probe'))
  end

  # Property 8: a facet of the driver-control interface stops and starts the drivers of
  # its server's units, so only the system domain holds one, however the service row
  # spells the interface; its service row keeps the declared number.
  def test_a_driver_control_facet_goes_to_the_system_domain_alone
    control = service('ctl', '@domain.beta').sub('interface 1', 'interface driver_control')
    view = @codec.open('manifest', admit(@source + control + facet('ctl', 'system', '@service.ctl')).bytes)
    assert_equal [2], rows(view, 'services').map { |row| row.fetch('interface') }
    [control, control.sub('interface driver_control', 'interface 2')].each do |row|
      refused(Erx::Manifest::Invalid, 8, 'facet.grantee', @source + row + facet('ctl', '@domain.alpha', '@service.ctl'))
    end
  end

  def test_an_interface_name_no_fragment_declares_is_refused
    source = @source + service('ctl', '@domain.beta').sub('interface 1', 'interface driver_ctl')
    error = assert_raises(Erx::ABI::SchemaError) { admit(source) }
    assert_match(/interface names no service/, error.message)
  end

  # A facet's operations resolve against its service's generated declarations, which
  # the packer does not read in Phase 1, so a facet that names any is refused.
  def test_a_facet_naming_an_operation_is_refused_naming_its_milestone
    named = facet('ab', '@domain.alpha', '@service.b').sub('operations none', 'operations read')
    refused(Erx::Manifest::Unsupported, 'unsupported', 'facet', @source + service('b', '@domain.beta') + named, message: /M5/)
  end

  def test_introductions_are_written_once_lower_index_first
    view = @codec.open('manifest', admit("#{@source}introduce @domain.beta @domain.alpha\n").bytes)
    assert_equal [[0, 1]], rows(view, 'introductions').map { |row| row.values_at('from', 'to') }
  end

  def test_an_introduction_of_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 2, 'introduce', "#{@source}introduce @domain.alpha @domain.absent\n")
  end

  def test_an_introduction_of_a_domain_to_itself_is_refused
    refused(Erx::Manifest::Invalid, 2, 'introduce', "#{@source}introduce @domain.alpha @domain.alpha\n")
  end

  def test_one_pair_introduced_twice_is_refused
    source = "#{@source}introduce @domain.alpha @domain.beta\nintroduce @domain.beta @domain.alpha\n"
    refused(Erx::Manifest::Invalid, 2, 'introduce', source)
  end

  # Property 4: every living domain, configured or requested, is one of its
  # principal's quota, so the quotas alone sum within max_domains; the configured
  # domains' budgets and grants are the planner's (test/host/dom_planner_test.rb).
  def test_principal_quotas_over_max_domains_are_refused
    refused(Erx::Manifest::Invalid, 4, 'principals.domains', @source.sub('max_domains 2', 'max_domains 1'))
  end

  # Property 5 over the configured domains and the services they serve.
  def test_a_domain_with_a_pooled_name_is_refused
    refused(Erx::Manifest::Invalid, 5, 'domain.name', @source.sub('domain alpha', 'domain alice_1'))
  end

  def test_a_domain_name_with_a_dot_is_refused
    error = assert_raises(Erx::ABI::SchemaError) { admit(@source.sub('domain alpha', 'domain a.b')) }
    assert_match(/needs one identifier/, error.message)
  end

  def test_a_domain_named_as_a_principal_is_refused
    refused(Erx::Manifest::Invalid, 5, 'domain.name', @source.sub('domain alpha', 'domain system'))
  end

  def test_one_name_on_two_servers_is_admitted
    source = @source + service('probe_a', '@domain.alpha').sub('service probe_a', "service probe_a\n  name \"probe\"") +
             service('probe_b', '@domain.beta').sub('service probe_b', "service probe_b\n  name \"probe\"")
    view = @codec.open('manifest', admit(source).bytes)
    assert_equal [0, 1], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_one_name_twice_on_one_server_is_refused
    source = @source + service('probe_a', '@domain.alpha').sub('service probe_a', "service probe_a\n  name \"probe\"") +
             service('probe_b', '@domain.alpha').sub('service probe_b', "service probe_b\n  name \"probe\"")
    refused(Erx::Manifest::Invalid, 5, 'service.name', source)
  end

  # Property 8: the console lines and the slot writer's windows stay the system domain's.
  def test_a_console_uart_held_by_a_configured_domain_is_refused
    %w[console hostlink].each do |unit|
      source = @source.sub(/(unit #{unit}\n  placement "[^"]*"\n)  holder system/, "\\1  holder @domain.alpha")
      refused(Erx::Manifest::Invalid, 8, "machine.#{unit}", source)
    end
  end

  def test_a_slot_window_held_by_a_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 8, 'window.holder', @source.sub("window slot_a\n  holder system", "window slot_a\n  holder @domain.alpha"))
  end

  def test_a_domain_named_system_is_refused
    source = @source.sub('principal system', 'principal root').gsub('@principal.system', '@principal.root').sub('domain alpha', 'domain system')
    refused(Erx::Manifest::Invalid, 5, 'domain.name', source)
  end

  def test_arguments_and_environment_over_the_boot_page_are_refused
    long = "  args \"#{'a' * 1500}\"\n  env \"X=#{'b' * 1500}\"\n"
    refused(Erx::Manifest::Invalid, 12, 'domain.args', with_domains(self.class.domain('alpha') + long))
  end

  # A row's release names a boot script of the domain release, and the packer binds it:
  # the packed arguments are the row's emulator flags, then -- -boot /bin/<name> --,
  # then the row's init arguments, so the binding is init's first flag and no later word
  # (-extra, a final -S) can make it a plain argument. A row whose own arguments name
  # -boot is refused, so no row boots a script its release does not name.
  def test_a_domain_boots_the_script_its_release_names
    { '-x y' => "-x\0y\0--\0-boot\0/bin/app\0--\0",
      '-x -- -nouser -extra a' => "-x\0--\0-boot\0/bin/app\0--\0-nouser\0-extra\0a\0" }.each do |args, packed|
      view = @codec.open('manifest', admit(with_domains(self.class.domain('alpha') + "  args \"#{args}\"\n")).bytes)
      assert_equal packed, view.string(rows(view, 'domains').fetch(0).fetch('args'))
    end
  end

  def test_a_domain_naming_boot_is_refused
    ['-boot /bin/session', '-x -boot /bin/app'].each do |args|
      refused(Erx::Manifest::Invalid, 12, 'domain.args', with_domains(self.class.domain('alpha') + "  args \"#{args}\"\n"),
              message: /-boot/)
    end
  end

  def test_a_session_template_boots_the_script_its_release_names
    view = @codec.open('manifest', admit(with_session(self.class.session)).bytes)
    assert_equal "-x\0y\0--\0-boot\0/bin/app\0--\0", view.string(rows(view, 'sessions').fetch(0).fetch('args'))
    refused(Erx::Manifest::Invalid, 14, 'session.args', with_session(self.class.session.sub('-x y', '-boot /bin/app')),
            message: /-boot/)
  end

  # Property 7: no secret domain, since no entry carries the sealing secret.
  def test_a_secret_domain_is_refused_naming_its_milestone
    refused(Erx::Manifest::Invalid, 7, 'domain.kind', with_domains(self.class.domain('vault', kind: 'secret')), message: /M11/)
  end

  # A window's holder is the system domain or a configured domain.
  def test_a_window_held_by_a_configured_domain_is_admitted
    source = @source.sub("window data\n  holder system", "window data\n  holder @domain.alpha")
    view = @codec.open('manifest', admit(source).bytes)
    assert_includes rows(view, 'windows').map { |row| row.fetch('holder') }, 0
  end

  # Property 10: the facets of the configured domains lead back to none of them.
  def test_facets_that_lead_back_are_refused
    source = @source + service('a', '@domain.alpha') + service('b', '@domain.beta') +
             facet('ab', '@domain.alpha', '@service.b') + facet('ba', '@domain.beta', '@service.a')
    refused(Erx::Manifest::Invalid, 10, 'facet.service', source)
  end

  def test_a_domain_holding_a_facet_of_its_own_service_is_refused
    source = @source + service('a', '@domain.alpha') + facet('aa', '@domain.alpha', '@service.a')
    refused(Erx::Manifest::Invalid, 10, 'facet.service', source)
  end

  # The order places every server before its clients and breaks ties by name order.
  def test_the_boot_order_puts_servers_first_and_names_break_ties
    parsed = Erx::Manifest::Frontend.parse(@source, version: @codec.constant('manifest_version'))
    check = Erx::Manifest::Stopgap.new(parsed, codec: @codec, context: @context, planner: nil, consumers: {})
    none = @codec.constant('mf_none')
    order = check.send(:boot_order, [{}, {}, {}, {}], [[0, 2], [2, 1], [3, none]])
    assert_equal [1, 2, 0, 3], order.map { |row| row.fetch('domain') }
  end

  # Property 11: a rescue domain takes facets only of the system domain and of other
  # rescue domains.
  def test_a_rescue_domain_on_a_domain_rescue_does_not_start_is_refused
    source = @source + service('a', '@domain.alpha') + facet('ba', '@domain.beta', '@service.a')
    refused(Erx::Manifest::Invalid, 11, 'facet.service', source)
  end

  # A facet of a service the system domain serves, granted to a configured domain,
  # reaches the encoded manifest, which the domain service reads at boot.
  def test_a_system_served_facet_of_a_rescue_domain_passes_property_eleven_and_is_encoded
    source = @source + service('s', 'system') + facet('bs', '@domain.beta', '@service.s')
    view = @codec.open('manifest', admit(source).bytes)
    services = rows(view, 'services')
    assert_equal [[1, @codec.constant('mf_none')]],
                 rows(view, 'facets').map { |row| [row.fetch('grantee'), services.fetch(row.fetch('service')).fetch('server')] }
  end

  # Property 12: what the domain library refuses fails the build, and without the
  # planner a manifest with domains fails closed.
  def test_a_domain_the_library_refuses_fails_the_build
    error = refused(Erx::Manifest::Invalid, 12, 'domain', planner: RecordingPlanner.new([0, -6]))
    assert_match(/beta with nomem/, error.message)
  end

  def test_an_introduction_the_library_refuses_fails_the_build
    error = refused(Erx::Manifest::Invalid, 12, 'introduce', "#{@source}introduce @domain.alpha @domain.beta\n",
                    planner: RecordingPlanner.new(introductions: [-7]))
    assert_match(/introduction of alpha and beta with limit/, error.message)
  end

  def test_configured_domains_without_a_planner_fail_closed
    refused(Erx::Manifest::Unsupported, 12, 'planner', planner: nil)
  end

  def test_a_runtime_that_names_no_executable_is_refused
    refused(Erx::Manifest::Invalid, 12, 'domain.runtime', with_domains(self.class.domain('alpha', runtime: '@artifact.app')))
  end

  def test_a_release_that_names_no_domain_release_is_refused
    %w[@artifact.emu @artifact.absent "app"].each do |release|
      refused(Erx::Manifest::Invalid, 12, 'domain.release', with_domains(self.class.domain('alpha', release: release)))
    end
  end

  def test_a_partial_boot_configures_no_domains
    refused(Erx::Manifest::Invalid, 12, 'domain', @source.sub('flags development', 'flags development,partial_boot'))
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
    refused(Erx::Manifest::Invalid, 14, 'session.limits', with_session(self.class.session(limits: '@limits.app')))
  end

  def test_a_session_template_keyed_by_no_principal_is_refused
    refused(Erx::Manifest::Invalid, 14, 'session.name', with_session(self.class.session('alpha')))
  end

  def test_two_session_templates_of_one_principal_are_refused
    refused(Erx::Manifest::Invalid, 'source', 'session', with_session(self.class.session, self.class.session))
  end

  def test_a_partial_boot_makes_no_sessions
    source = @plain.sub('flags development', 'flags development,partial_boot') + APP_LIMITS + self.class.session
    refused(Erx::Manifest::Invalid, 14, 'session', source)
  end

  # Holders, servers and introductions resolve through the domain table, which
  # holds no template, so none of them can name one: each is refused under its
  # own property as naming no configured domain.
  def test_nothing_names_a_session_template
    source = with_session(self.class.session)
    refused(Erx::Manifest::Invalid, 2, 'introduce', "#{source}introduce @domain.alpha @session.system\n")
    refused(Erx::Manifest::Invalid, 2, 'service.server', source + service('probe', '@session.system'))
    refused(Erx::Manifest::Invalid, 8, 'window.holder', source.sub("window data\n  holder system", "window data\n  holder @session.system"))
    refused(Erx::Manifest::Invalid, 1, 'unit.holder', source.sub(/(unit block\n(?:  .*\n)*?  holder )system/, '\1@session.system'))
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
    refused(Erx::Manifest::Invalid, 2, 'facet.grantee', source)
  end

  # Properties 2 and 14: a session template may hold a facet of a service the system
  # domain serves, which the domain service starts for each session made from it, as
  # it may one of a configured domain's; no server takes a facet of its own service.
  def test_a_session_granted_a_system_domain_service_is_admitted
    admit(with_session(self.class.session) + service('s', 'system') + facet('f', '@session.system', '@service.s'))
    refused(Erx::Manifest::Invalid, 2, 'facet.grantee',
            with_session(self.class.session) + service('s', 'system') + facet('f', 'system', '@service.s'))
  end

  # Property 15: the system domain holds no facet of the net or netadmin interface,
  # however the service row spells the interface.
  def test_the_system_domain_holds_no_network_facet
    net = service('n', '@domain.beta')
    ['interface net', 'interface 3', 'interface netadmin', 'interface 4'].each do |interface|
      source = with_session(self.class.session) + net.sub('interface 1', interface) + facet('n', 'system', '@service.n')
      refused(Erx::Manifest::Invalid, 15, 'facet.grantee', source, message: /facet n grants the system domain/)
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
      refused(Erx::Manifest::Invalid, 15, 'runtime_limits.max_frame', source, message: /#{floor}/)
    end
  end

  # Property 16: a files facet's grantee, the system domain, a configured domain or a
  # session template, and its server each take frames of at least files_max_frame_min
  # under their own runtime limits, and the facet's max_request admits a request that
  # long. beta serves under the system runtime limits, and so does alpha as a grantee; a
  # session takes the session ones.
  def test_a_files_receiver_below_the_frame_floor_is_refused
    floor = @codec.constant('files_max_frame_min')
    files = service('f', '@domain.beta').sub('interface 1', 'interface files')
    files_facet = ->(grantee) { facet('f', grantee, '@service.f').sub('max_request 1', "max_request #{floor}") }
    granted = ->(grantee) { with_session(self.class.session) + files + files_facet.call(grantee) }
    refused(Erx::Manifest::Invalid, 16, 'facet.max_request', granted.call('system').sub("max_request #{floor}", "max_request #{floor - 1}"),
            message: /f's max_request #{floor - 1} .*#{floor}/)
    %w[system @domain.alpha @session.system].each { |grantee| admit(granted.call(grantee)) }
    admit(with_max_frame(granted.call('@domain.alpha'), 'session', floor - 1))
    [['grantee', with_max_frame(granted.call('@session.system'), 'session', floor - 1)],
     ['server', with_max_frame(granted.call('@session.system'), 'system', floor - 1)],
     ['grantee', with_max_frame(granted.call('system'), 'system', floor - 1)]].each do |role, source|
      refused(Erx::Manifest::Invalid, 16, 'runtime_limits.max_frame', source, message: /f's #{role} .*#{floor}/)
    end
  end

  # Property 16 for inspect: a grantee of an inspect facet, here a session template, and
  # its server, the system domain, each run with max_frame, max_message_heap and
  # funnel_depth at least the interface's floors, as the development manifest's
  # runtime limits do. The seeds are the design's: a check
  # that reads only the grantee's limits admits the server's; one of max_frame alone
  # admits the template's max_message_heap.
  def test_an_inspect_receiver_below_a_floor_is_refused
    floors = { 'max_frame' => @codec.constant('inspect_max_frame_min'),
               'max_message_heap' => @codec.constant('inspect_message_heap_min'),
               'funnel_depth' => @codec.constant('inspect_funnel_depth_min') }
    inspect = service('i', 'system').sub('interface 1', 'interface inspect')
    granted = with_session(self.class.session) + inspect + facet('i', '@session.system', '@service.i')
    admit(granted)
    refused(Erx::Manifest::Invalid, 16, 'service.server', granted.sub("service i\n  server system", "service i\n  server @domain.beta"),
            message: /only the system domain serves the inspect interface/)
    %w[system session].product(floors.keys).each do |name, field|
      role = name == 'system' ? 'server' : 'grantee'
      refused(Erx::Manifest::Invalid, 16, "runtime_limits.#{field}",
              with_runtime_limit(granted, name, field, floors.fetch(field) - 1),
              message: /i's #{role} runs with #{field} #{floors.fetch(field) - 1}, below inspect's floor/)
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
                          grants: [facet('sb', '@session.system', '@service.b') + sb,
                                   facet('ob', '@session.other', '@service.b') + ob])
  end

  def service_index(view, name) = rows(view, 'services').index { |row| view.string(row.fetch('name')) == name }

  def test_a_start_row_is_packed_with_its_defaults_or_its_own_fields
    none = @codec.constant('mf_none')
    enabled = @codec.member('mf_start_flags', 'enabled')
    fields = %w[principal flags display restarts restart_period_s]
    view = @codec.open('manifest', admit(with_session(self.class.session) + self.class.start).bytes)
    assert_equal [[0, enabled, none, 5, 600]], rows(view, 'starts').map { |row| row.values_at(*fields) }
    own = self.class.start('system', "  enable NO\n  restarts 3\n  restart_period_s 60\n")
    view = @codec.open('manifest', admit(with_session(self.class.session) + own).bytes)
    assert_equal [[0, 0, none, 3, 60]], rows(view, 'starts').map { |row| row.values_at(*fields) }
  end

  def test_a_start_row_of_a_principal_without_a_session_template_is_refused
    refused(Erx::Manifest::Invalid, 17, 'start.name', @source + self.class.start)
    refused(Erx::Manifest::Invalid, 17, 'start.name', with_session(self.class.session) + self.class.start('alpha'))
  end

  def test_a_start_row_s_restart_period_is_at_least_a_second
    refused(Erx::Manifest::Invalid, 17, 'start.restart_period_s',
            with_session(self.class.session) + self.class.start('system', "  restart_period_s 0\n"))
  end

  def test_two_start_rows_of_one_principal_are_refused
    refused(Erx::Manifest::Invalid, 'source', 'start', with_session(self.class.session) + self.class.start + self.class.start)
  end

  def test_a_start_row_s_intensity_past_its_ceilings_is_refused
    base = with_session(self.class.session)
    fields = %w[restarts restart_period_s]
    view = @codec.open('manifest', admit(base + self.class.start('system', "  restarts 100\n  restart_period_s 86400\n")).bytes)
    assert_equal [[100, 86_400]], rows(view, 'starts').map { |row| row.values_at(*fields) }
    refused(Erx::Manifest::Invalid, 17, 'start.restarts', base + self.class.start('system', "  restarts 101\n"))
    refused(Erx::Manifest::Invalid, 17, 'start.restart_period_s', base + self.class.start('system', "  restart_period_s 86401\n"))
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
    refused(Erx::Manifest::Invalid, 17, 'start.display', with_display(self.class.start('system', display)),
            message: /not a windows service/)
    refused(Erx::Manifest::Invalid, 17, 'start.display', with_display(self.class.start('system', "  display @service.c\n")),
            message: /does not contain/)
    other_only = with_display(self.class.start('system', display),
                              served: "service b\n  server @domain.beta\n  interface windows\n#{DISPLAY}",
                              grants: [facet('ob', '@session.other', '@service.b') + "  parameter pixels 4096\n"])
    refused(Erx::Manifest::Invalid, 17, 'start.display', other_only, message: /not granted/)
  end

  # Two enabled rows on one display are refused; a disabled row holds no display.
  def test_two_enabled_start_rows_on_one_display_are_refused
    display = "  display @service.b\n"
    refused(Erx::Manifest::Invalid, 17, 'start.display',
            with_windows(self.class.start('system', display), self.class.start('other', display)), message: /two enabled/)
    view = @codec.open('manifest', admit(with_windows(self.class.start('system', display),
                                                      self.class.start('other', "  enable NO\n#{display}"))).bytes)
    assert_equal 2, view.count('starts')
  end

  def test_a_partial_boot_starts_no_row
    refused(Erx::Manifest::Invalid, 17, 'start', @plain.sub('flags development', 'flags development,partial_boot') + self.class.start)
    refused(Erx::Manifest::Invalid, 2, 'display', @plain.sub('flags development', 'flags development,partial_boot') + DISPLAY)
  end

  # Property 18: the display record is packed by its service's index, with its policy
  # and idle times.
  def test_a_display_record_is_packed_by_its_service
    view = @codec.open('manifest', admit(with_windows).bytes)
    fields = %w[service policy idle_dim_s idle_off_s]
    assert_equal [[service_index(view, 'b'), @codec.member('mf_display_policy', 'single'), 60, 600]],
                 rows(view, 'displays').map { |row| row.values_at(*fields) }
    rio = DISPLAY.sub('single', 'rio').sub('idle_off_s 600', 'idle_off_s 0')
    view = @codec.open('manifest', admit(with_windows(record: rio)).bytes)
    assert_equal [[@codec.member('mf_display_policy', 'rio'), 0]], rows(view, 'displays').map { |row| row.values_at('policy', 'idle_off_s') }
  end

  def test_a_display_record_s_policy_and_idle_times_are_checked
    assert_raises(Erx::ABI::SchemaError) { admit(with_windows(record: DISPLAY.sub('single', 'tiled'))) }
    refused(Erx::Manifest::Invalid, 18, 'display.idle_off_s', with_windows(record: DISPLAY.sub('idle_off_s 600', 'idle_off_s 59')),
            message: /off before it dims/)
  end

  # Seed: a windows service with no display record would have grants no sum counts.
  def test_every_windows_service_has_a_display_record_and_every_record_one
    refused(Erx::Manifest::Invalid, 18, 'display.name', with_windows(record: ''), message: /has no display record/)
    refused(Erx::Manifest::Invalid, 18, 'display.name', with_display(served: service('b', '@domain.beta') + DISPLAY),
            message: /not of the windows interface/)
    refused(Erx::Manifest::Invalid, 18, 'display.name', with_windows + DISPLAY.sub('display b', 'display c'),
            message: /does not contain/)
    refused(Erx::Manifest::Invalid, 'source', 'display', with_windows + DISPLAY)
  end

  # Seed: a domain serving two displays would pay for both displays' grants out of one
  # outer budget, which each display's sum alone admits.
  def test_one_domain_serves_one_display
    second = "service c\n  server @domain.beta\n  interface windows\n#{DISPLAY.sub('display b', 'display c')}" +
             facet('sc', '@session.system', '@service.c') + "  parameter pixels 4096\n"
    refused(Erx::Manifest::Invalid, 18, 'display.name', with_windows + second, message: /one domain serves two displays/)
    admit(with_windows + second.gsub('@domain.beta', '@domain.alpha'))
  end

  def test_a_display_is_served_by_a_configured_domain
    refused(Erx::Manifest::Invalid, 18, 'display.name', with_windows(server: 'system'), message: /system domain/)
  end

  # Seed: the system domain is connected to every domain at its creation, by no
  # introduction, so its connection to a display has no pixel area (design-display.md,
  # "The pixel area"); a windows grant to it would be installed without one.
  def test_no_display_is_granted_to_the_system_domain
    granted = with_windows + facet('ys', 'system', '@service.b') + "  parameter pixels 4096\n"
    refused(Erx::Manifest::Invalid, 18, 'facet.grantee', granted, message: /grants a display to the system domain/)
  end

  # Seed: the session parameter is the domain service's alone.
  def test_no_facet_row_sets_session
    refused(Erx::Manifest::Invalid, 18, 'facet.parameter', with_windows(sb: "  parameter pixels 4096\n  parameter session no\n"),
            message: /sets session/)
  end

  # Seed: a template's grant costs its pixel area and the display's side once for each
  # session its principal's domains quota allows, 2 for the system principal and 0 for
  # other. 127 pages and the side's page, twice, fill beta's 1 MiB outer budget; one
  # page more each passes it, which counting the template once would admit.
  def test_a_template_s_pixel_areas_count_once_for_each_session_it_can_have
    admit(with_windows(sb: "  parameter pixels #{127 * 4096}\n", ob: "  parameter pixels #{1 << 30}\n"))
    refused(Erx::Manifest::Invalid, 18, 'facet.parameter', with_windows(sb: "  parameter pixels #{128 * 4096}\n"),
            message: /past its domain's outer budget/)
    refused(Erx::Manifest::Invalid, 18, 'facet.parameter', with_windows(sb: ''), message: /past its domain's outer budget/)
  end

  # A facet's parameters, resolved against its service's declarations, are packed in
  # key order, each facet's run its parameters span; facets are in name order, ob first.
  def test_facet_parameters_are_packed_in_key_order
    view = @codec.open('manifest', admit(with_windows(sb: "  parameter snarf yes\n  parameter pixels 4096\n  parameter windows 2\n")).bytes)
    u64, boolean = %w[u64 boolean].map { |kind| @codec.member('mf_parameter_kind', kind) }
    assert_equal [[2, u64, 4096], [1, u64, 2], [2, u64, 4096], [3, boolean, 1]],
                 rows(view, 'facet_parameters').map { |row| row.values_at('key', 'kind', 'scalar') }
    granted = rows(view, 'facets').select { |row| %w[ob sb].include?(view.string(row.fetch('name'))) }
    assert_equal [1, 3], granted.map { |row| row.fetch('parameters').fetch('count') }
  end

  def test_a_facet_parameter_is_declared_stated_once_and_within_its_bound
    { "  parameter root \"/\"\n" => /not declared/, "  parameter windows 2\n  parameter windows 2\n" => /twice/,
      "  parameter windows 0\n" => /outside 1 to 4096/, "  parameter windows 4097\n" => /outside 1 to 4096/ }.each do |lines, message|
      refused(Erx::Manifest::Invalid, 2, 'facet.parameter', with_windows(sb: "  parameter pixels 4096\n#{lines}"), message: message)
    end
    assert_raises(Erx::ABI::SchemaError) { admit(with_windows(sb: "  parameter pixels 4096\n  parameter snarf true\n")) }
    undeclared = facet('ab', '@domain.alpha', '@service.b') + "  parameter root \"/\"\n"
    refused(Erx::Manifest::Invalid, 2, 'facet.parameter', @source + service('b', '@domain.beta') + undeclared, message: /not declared/)
  end
end
