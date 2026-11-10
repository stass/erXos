# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/system_domain'

# What the system_domain suite's harness types and expects (tools/lib/erx/system_domain.rb).
# Nothing boots here.
class SystemDomainTest < Minitest::Test
  Suite = Erx::SystemDomain
  PLAIN = File.binread(File.expand_path('../../config/manifest/qemu-virt-development.txt', __dir__))

  # The row is MediumBoot's with the halt dropped, so the configured domain stays up,
  # and the manifest differs from MediumBoot's only in that row.
  def test_the_configured_domain_stays_up_and_is_the_manifests_one_change
    row_args = Suite::DOMAIN_ROW[/^  args "(.*)"$/, 1].split
    assert_equal Erx::MediumBoot::DOMAIN_ARGS[0...-2], row_args
    refute_includes row_args, '-eval'
    assert_match(/^  restarts 0$/, Suite::DOMAIN_ROW)
    medium = Erx::MediumBoot.manifest(PLAIN)
    ours = Suite.manifest(PLAIN)
    assert ours.end_with?(Suite::DOMAIN_ROW)
    assert_equal medium.lines[0...-1], ours.lines[0...-1]
    assert_match(/^  args ".* -eval /, medium.lines.last)
    assert_equal "  args \"#{Suite::DOMAIN_ARGS.join(' ')}\"\n", ours.lines.last
  end

  # The kill follows the Erlang shell; the answer must name the configured domain
  # running, and the runtime must end with the slogan of erx_domain's end, not another.
  def test_the_kill_waits_for_the_running_domain_and_must_see_the_applications_end
    shell = { name: 'release-shell', pattern: /x/n, seconds: 60 }.freeze
    points = Suite.service_kill_checkpoints([{ name: 'image-identity', pattern: /y/n, seconds: 30 }, shell])
    assert_equal %w[image-identity release-shell erlang-shell domain-running system-domain-ended], points.map { |point| point.fetch(:name) }
    assert_equal Erx::ProductionImage::Run::ERL_LINE, points[1].fetch(:type)
    assert_equal "#{Suite::SERVICE_KILL_EXPRESSION}\r", points[2].fetch(:type)
    running, ended = points.last(2)
    refute_match running.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    running.fetch(:verify).call("1> {service_kill,#{Suite::CONFIGURED_ID},running}\r\n")
    ["timeout\r\n", "{service_kill,#{Suite::CONFIGURED_ID + 1},running}\r\n"].each do |line|
      assert_raises(Erx::Error) { running.fetch(:verify).call(line) }
    end
    # The line as a boot printed it, after the shell's prompt.
    ended.fetch(:verify).call("2> Kernel pid terminated (application_controller) (\"{application_terminated,erx_domain,shutdown}\")\r\r\n")
    ['("{application_terminated,erx_net,shutdown}")', '({application_terminated,erx_domain,shutdown})'].each do |reason|
      assert_raises(Erx::Error) { ended.fetch(:verify).call("Kernel pid terminated (application_controller) #{reason}\r\n") }
    end
    assert_raises(Erx::Error) { Suite.service_kill_checkpoints([shell, points[0]]) }
  end
end
