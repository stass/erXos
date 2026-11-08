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
# erx_dom_plan_configured (liberx/system/dom_core.c) through tools/host/dom_plan.c,
# which PackTools builds, so a configured domain the library refuses fails the build.
class DomPlannerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DOMAINS = "limits app\n  memory 4194304\n  outer 1048576\n  grant @share.users\n  spaces none\n  lane 4096\n" \
            "  connections 2\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
            "  peer_held 4096\n  peer_held_total 4096\n" \
            "domain alpha\n  principal @principal.system\n  limits @limits.app\n  kind service\n  flags none\n" \
            "  runtime @artifact.emu\n  release @artifact.app\n  restarts 3\n  restart_period_s 5\n"

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)))
    platform = JSON.parse(File.read(File.join(ROOT, 'config/platforms/qemu-virt.json')))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).merge(platform: platform))
    @source = File.binread(File.join(ROOT, 'config/manifest/qemu-virt-development.txt'))
                  .sub("  domains 0\n", "  domains 1\n").sub('max_domains 0', 'max_domains 2') + DOMAINS
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

  def test_the_library_plans_a_configured_domain
    assert_equal 1, admit(@source).report.fetch('child_plan_instances')
  end

  # The Ruby check takes any byte count; the library takes only whole pages.
  def test_a_budget_the_library_refuses_fails_the_build
    error = assert_raises(Erx::Manifest::Invalid) { admit(@source.sub("limits app\n  memory 4194304", "limits app\n  memory 4194305")) }
    assert_equal 12, error.property
    assert_match(/alpha with inval/, error.message)
  end

  def test_a_runtime_without_an_accepted_image_fails_the_build
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(@codec).then do |arguments|
      arguments.merge(platform: @context.platform,
                      catalog: arguments.fetch(:catalog).each_with_index.map { |row, index| index == 2 ? row.except('image') : row })
    end)
    assert_equal 12, assert_raises(Erx::Manifest::Invalid) { admit(@source) }.property
  end

  def test_a_malformed_view_is_refused_by_the_helper
    path = File.join(@directory, 'bad.txt')
    ["machine 1 1\n", "file 1 0 0 0\n", "machine 1 1 4096 250 #{'0 ' * 9}0", "domain 1\n"].each do |text|
      File.binwrite(path, text)
      assert_raises(Erx::Error, text) { @helper.run([path], runner: @runner, name: 'dom-plan-bad', deadline: 30) }
    end
  end

  def test_the_reply_must_hold_one_status_per_row
    assert_equal [0, -6], Erx::DomainPlanner.statuses("domain 0 0\ndomain 1 -6\n", rows: 2)
    ["domain 0 0\n", "domain 1 0\ndomain 0 0\n", "domain 0 0\ndomain 1 x\n"].each do |reply|
      assert_raises(Erx::Error) { Erx::DomainPlanner.statuses(reply, rows: 2) }
    end
  end
end
