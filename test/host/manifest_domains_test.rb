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

  # Each domain's status, in boot order, and each introduction's; [] plans them all.
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
        'introductions' => view.fetch('introductions').each_index.map { |index| @introductions.fetch(index, 0) } }
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
    assert_equal [[emu, 0, 3]] * 2, domains.map { |row| row.values_at('runtime', 'release', 'release_files') }
    assert_equal [@codec.member('mf_domain_flags', 'rescue'), 0], domains.map { |row| row.fetch('flags') }
    assert_equal [[3, 5]] * 2, domains.map { |row| row.values_at('restarts', 'restart_period_s') }
    assert_equal [0, 1], rows(view, 'boot_order').map { |row| row.fetch('domain') }
    assert_equal 2, view.header.fetch('max_domains')
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
    view = @codec.open('manifest', admit(@source + service('log', '@domain.alpha')).bytes)
    assert_equal [0], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_a_service_of_no_configured_domain_is_refused
    refused(Erx::Manifest::Invalid, 2, 'service.server', @source + service('log', '@domain.absent'))
  end

  def test_a_facet_naming_no_service_is_refused
    refused(Erx::Manifest::Invalid, 2, 'facet.service', @source + facet('f', '@domain.alpha', '@service.absent'))
  end

  def test_a_facet_granted_to_no_configured_domain_is_refused
    source = @source + service('log', 'system') + facet('f', 'system', '@service.log')
    refused(Erx::Manifest::Invalid, 2, 'facet.grantee', source)
  end

  # A facet's operations and parameters resolve against its service's generated
  # declarations, which the packer does not read in Phase 1.
  def test_a_facet_on_a_known_service_is_refused_naming_its_milestone
    source = @source + service('log', 'system') + facet('f', '@domain.alpha', '@service.log')
    refused(Erx::Manifest::Unsupported, 'unsupported', 'facet', source, message: /M5/)
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
    source = @source + service('log_a', '@domain.alpha').sub('service log_a', "service log_a\n  name \"log\"") +
             service('log_b', '@domain.beta').sub('service log_b', "service log_b\n  name \"log\"")
    view = @codec.open('manifest', admit(source).bytes)
    assert_equal [0, 1], rows(view, 'services').map { |row| row.fetch('server') }
  end

  def test_one_name_twice_on_one_server_is_refused
    source = @source + service('log_a', '@domain.alpha').sub('service log_a', "service log_a\n  name \"log\"") +
             service('log_b', '@domain.alpha').sub('service log_b', "service log_b\n  name \"log\"")
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

  def test_a_rescue_domain_on_the_system_domain_passes_property_eleven
    source = @source + service('s', 'system') + facet('bs', '@domain.beta', '@service.s')
    refused(Erx::Manifest::Unsupported, 'unsupported', 'facet', source)
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
    refused(Erx::Manifest::Invalid, 2, 'service.server', source + service('log', '@session.system'))
    refused(Erx::Manifest::Invalid, 8, 'window.holder', source.sub("window data\n  holder system", "window data\n  holder @session.system"))
    refused(Erx::Manifest::Invalid, 1, 'unit.holder', source.sub(/(unit block\n(?:  .*\n)*?  holder )system/, '\1@session.system'))
  end
end
