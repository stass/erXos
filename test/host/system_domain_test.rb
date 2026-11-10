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

  # The rows are MediumBoot's with the halt dropped, so each configured domain stays up,
  # and over the erx carrier in place of none, so each is a node; the manifest differs
  # from MediumBoot's only in that row's arguments and in the second row, peer.
  def test_the_configured_domains_stay_up_as_nodes_and_are_the_manifests_one_change
    row_args = Suite::DOMAIN_ROW[/^  args "(.*)"$/, 1].split
    medium_args = Erx::MediumBoot::DOMAIN_ARGS[0...-2]
    assert_equal medium_args.join(' ').sub('-kernel start_distribution false', '-no_epmd -proto_dist erx'), row_args.join(' ')
    refute_includes row_args, '-eval'
    refute_includes row_args, 'start_distribution'
    assert_match(/^  restarts 0$/, Suite::DOMAIN_ROW)
    assert_equal Suite::DOMAIN_ROW[/^domain erts\n.*/m].sub("domain erts\n", "domain peer\n"), Suite::PEER_ROW
    medium = Erx::MediumBoot.manifest(PLAIN)
    ours = Suite.manifest(PLAIN)
    assert ours.end_with?(Suite::DOMAIN_ROW + Suite::PEER_ROW)
    kept = medium.lines.size - 1
    assert_equal medium.lines[0...-1], ours.lines[0...kept]
    assert_match(/^  args ".* -eval /, medium.lines.last)
    assert_equal ["  args \"#{Suite::DOMAIN_ARGS.join(' ')}\"\n", *Suite::PEER_ROW.lines], ours.lines[kept..]
  end

  # The kill follows the Erlang shell; the answer must name both configured domains
  # running, the system node, and each domain's own answers over its system connection;
  # the ends must be peer's stop alone, then erts's halt with status 69; and the runtime
  # must end with the slogan of erx_domain's end, not another.
  def test_the_kill_waits_for_the_running_domains_and_must_see_the_applications_end
    shell = { name: 'release-shell', pattern: /x/n, seconds: 60 }.freeze
    points = Suite.service_kill_checkpoints([{ name: 'image-identity', pattern: /y/n, seconds: 30 }, shell])
    assert_equal %w[image-identity release-shell erlang-shell domain-running domain-ends system-domain-ended],
                 points.map { |point| point.fetch(:name) }
    assert_equal Erx::ProductionImage::Run::ERL_LINE, points[1].fetch(:type)
    assert_equal "#{Suite::SERVICE_KILL_EXPRESSION}\r", points[2].fetch(:type)
    running, ends, ended = points.last(3)
    refute_match running.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    good = '{service_kill,[{5,erts@erxos,running},{6,peer@erxos,running}],system@erxos,4,' \
           '[erts@erxos,peer@erxos],[{5,erts@erxos,5},{6,peer@erxos,6}]}'
    running.fetch(:verify).call("1> #{good}\r\n")
    ['timeout', good.sub('system@erxos,4', 'nonode@nohost,0'), good.sub('[erts@erxos,peer@erxos]', '[erts@erxos]'),
     good.sub('{6,peer@erxos,6}', '{6,{error,{erpc,noconnection}},{error,{erpc,noconnection}}}'),
     good.sub('{6,peer@erxos,running}', '{6,peer@erxos,built}')].each do |line|
      assert_raises(Erx::Error) { running.fetch(:verify).call("#{line}\r\n") }
    end
    refute_match ends.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    good_ends = '{domain_ends,[{6,stopped}],[{5,erts@erxos,running}],[{5,{halt,69}},{6,stopped}]}'
    ends.fetch(:verify).call("#{good_ends}\r\n")
    # erts stopped with peer, or ended otherwise than by the halt, or not at all.
    [good_ends.sub('[{5,erts@erxos,running}]', '[]'), good_ends.sub('{halt,69}', 'stopped'),
     good_ends.sub('[{5,{halt,69}},{6,stopped}]', '[{6,stopped}]')].each do |line|
      assert_raises(Erx::Error) { ends.fetch(:verify).call("#{line}\r\n") }
    end
    # The line as a boot printed it, after the shell's prompt.
    ended.fetch(:verify).call("2> Kernel pid terminated (application_controller) (\"{application_terminated,erx_domain,shutdown}\")\r\r\n")
    ['("{application_terminated,erx_net,shutdown}")', '({application_terminated,erx_domain,shutdown})'].each do |reason|
      assert_raises(Erx::Error) { ended.fetch(:verify).call("Kernel pid terminated (application_controller) #{reason}\r\n") }
    end
    assert_raises(Erx::Error) { Suite.service_kill_checkpoints([shell, points[0]]) }
  end
end
