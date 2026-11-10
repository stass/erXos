# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/dom_planner'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/manifest_context'

# Property 12 with the domain library's own host build: the manifest check runs
# the library (liberx/system/dom_core.c, dom_life.c and dom_boot_view.c) through tools/host/dom_plan.c,
# which PackTools builds, planning the configured domains in boot order and then the
# introductions, each plan recorded before the next. So a configured domain or an
# introduction the library refuses fails the build, and what the library counts
# across domains is judged by the library alone: each seed below is one sum it holds.
class DomPlannerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
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

  def refused(source, field, message)
    error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
    assert_equal [12, field], [error.property, error.field], error.message
    assert_match message, error.message
  end

  def test_the_library_plans_a_configured_domain
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
  end

  # Two principals' session templates (property 14), each its principal's, of the
  # profile split; system and guest split users between them, and guest takes a page
  # of system's memory.
  SESSIONS = NARROW +
             LIMITS.sub('limits app', 'limits split').sub('grant @share.users', 'grant @share.narrow')
                   .sub('  spaces none', '  spaces @share.narrow').sub("  flags none\n", "  flags spaces\n") +
             "principal guest\n  memory 4096\n  grant @share.narrow\n  domains 0\n  names 0\n" \
             "  default_limits @limits.native\n  ceiling_limits @limits.native\n" +
             %w[guest system].map do |principal|
               "session #{principal}\n  limits @limits.split\n  runtime @artifact.emu\n  release @artifact.app\n"
             end.join

  def with_sessions
    source = with_domains('alpha', share: 'narrow')
    system = source.sub(/^(principal system\n  memory )(\d+)\n  grant @share\.users$/) do
      "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2)) - 4096}\n  grant @share.narrow"
    end
    refute_equal source, system, "the system principal's memory and grant"
    system.sub(/(limits native\n(?:  .*\n)*?  grant )@share\.users/, '\1@share.narrow') + SESSIONS
  end

  def test_session_templates_are_read_but_never_planned
    assert_equal 1, admit(with_sessions).report.fetch('child_plan_instances')
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
    source = with_domains('alpha', 'beta').sub('max_connections 4', 'max_connections 1').sub('  connections 2', '  connections 1')
    refused(source, 'domain', /configured domain beta with limit/)
  end

  def test_introductions_within_every_bound_are_admitted
    source = "#{NARROW}#{with_domains('alpha', 'beta', 'gamma', share: 'narrow').sub('max_connections 4', 'max_connections 5')}" \
             "introduce @domain.alpha @domain.beta\nintroduce @domain.beta @domain.gamma\n"
    assert_equal 3, admit(source).report.fetch('child_plan_instances')
  end

  def test_an_introduction_past_the_connection_table_fails_the_build
    source = "#{with_domains('alpha', 'beta').sub('max_connections 4', 'max_connections 2')}introduce @domain.alpha @domain.beta\n"
    refused(source, 'introduce', /introduction of alpha and beta with limit/)
  end

  # Each recorded introduction counts against both parties' connections quota.
  def test_an_introduction_past_a_partys_connections_quota_fails_the_build
    source = NARROW + with_domains('alpha', 'beta', 'gamma', share: 'narrow').sub('max_connections 4', 'max_connections 6')
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

  # The platform record's units, with the network transport moved into the block
  # transport's register page: the view derives units from pages, so two units that
  # share one are a split unit, whether one holder takes both or two do. No view is
  # built from such a manifest, so no row is created from it and nothing is given.
  def test_units_that_share_a_register_page_fail_the_build
    platform = JSON.parse(JSON.generate(@context.platform))
    block = platform.fetch('units').find { |unit| unit.fetch('key') == 'block' }.fetch('devices').first
    platform.fetch('units').find { |unit| unit.fetch('key') == 'net' }.fetch('devices').first['base'] = block.fetch('base') - 0x200
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    two = ManifestContextFixture.substitute(@source, /^(unit net\n  placement "net"\n  holder )system$/, '\1@domain.alpha')
    [@source, two].each do |source|
      error = assert_raises(Erx::Manifest::Invalid) { admit(source) }
      assert_equal [12, 'view'], [error.property, error.field], error.message
      assert_match(/share a register page/, error.message)
    end
  end

  def test_a_malformed_input_is_refused_by_the_helper
    manifest = admit(@source).bytes
    head = @codec.encode_layout('erx_image_manifest', ManifestContextFixture.image(@codec))
    paths = %w[manifest heads plan].map { |name| File.join(@directory, "bad-#{name}") }
    [[manifest, '', "order 0 1\n"], [manifest, '', "order 1\n"], [manifest, '', "order 0\norder 0\n"],
     [manifest, head, "file 1 0 0\norder 0\n"], [manifest, '', "file 1 0 56\norder 0\n"],
     [manifest, '', "order 0\nfile 1 0 0\n"], [manifest, '', "order 0\nintroduce 0 1\n"],
     ['short', '', "order 0\n"]].each do |bytes, heads, plan|
      [bytes, heads, plan].zip(paths).each { |content, file| File.binwrite(file, content) }
      assert_raises(Erx::Error, plan) { @helper.run(paths, runner: @runner, name: 'dom-plan-bad', deadline: 30) }
    end
  end

  def test_the_reply_must_hold_one_status_per_domain_and_introduction
    assert_equal({ 'domains' => [0, -6], 'introductions' => [-7] },
                 Erx::DomainPlanner.statuses("domain 0 0\ndomain 1 -6\nintroduce 0 -7\n", domains: 2, introductions: 1))
    ["domain 0 0\ndomain 1 0\n", "domain 1 0\ndomain 0 0\nintroduce 0 0\n", "domain 0 0\ndomain 1 x\nintroduce 0 0\n",
     "domain 0 0\nintroduce 0 0\ndomain 1 0\n", "domain 0 0\ndomain 1 0\nintroduce 1 0\n"].each do |reply|
      assert_raises(Erx::Error, reply) { Erx::DomainPlanner.statuses(reply, domains: 2, introductions: 1) }
    end
  end
end
