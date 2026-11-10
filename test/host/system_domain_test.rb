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
  # over the erx carrier, as MediumBoot's, so each is a node, behind the flag that lets the
  # control_table step hold a domain's ring; the manifest differs from MediumBoot's only in
  # that row's arguments, its one connection, the control table's one slot, and in the
  # second row, peer.
  def test_the_configured_domains_stay_up_as_nodes_and_are_the_manifests_one_change
    row_args = Suite::DOMAIN_ROW[/^  args "(.*)"$/, 1].split
    medium_args = Erx::MediumBoot::DOMAIN_ARGS[0...-2]
    assert_equal ['-erx', 'test_lane_hold', *medium_args], row_args
    assert_match(/^  connections 1$/, Suite::DOMAIN_ROW)
    assert_equal %w[-no_epmd -proto_dist erx], row_args.each_cons(3).find { |three| three.first == '-no_epmd' }
    refute_includes row_args, '-eval'
    refute_includes row_args, 'start_distribution'
    assert_match(/^  restarts 0$/, Suite::DOMAIN_ROW)
    assert_equal Suite::DOMAIN_ROW[/^domain erts\n.*/m].sub("domain erts\n", "domain peer\n"), Suite::PEER_ROW
    medium = Erx::MediumBoot.manifest(PLAIN)
    ours = Suite.manifest(PLAIN)
    assert ours.end_with?(Suite::DOMAIN_ROW + Suite::PEER_ROW)
    kept = medium.lines.size - 1
    assert_equal [["  connections 0\n", "  connections 1\n"]],
                 medium.lines[0...-1].zip(ours.lines[0...kept]).reject { |theirs, mine| theirs == mine }
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
    assert_equal %w[image-identity release-shell erlang-shell domain-running control-table introduced hostile connection-down
                    domain-ends system-domain-ended],
                 points.map { |point| point.fetch(:name) }
    assert_equal Erx::ProductionImage::Run::ERL_LINE, points[1].fetch(:type)
    assert_equal "#{Suite::SERVICE_KILL_EXPRESSION}\r", points[2].fetch(:type)
    running, table, _introduced, _hostile, _down, ends, ended = points.last(7)
    refute_match running.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    good = '{service_kill,[{5,erts@erxos,ready},{6,peer@erxos,ready}],system@erxos,4,' \
           '[erts@erxos,peer@erxos],[{5,erts@erxos,5},{6,peer@erxos,6}],{2,erts@erxos}}'
    running.fetch(:verify).call("1> #{good}\r\n")
    ['timeout', good.sub('system@erxos,4', 'nonode@nohost,0'), good.sub('[erts@erxos,peer@erxos]', '[erts@erxos]'),
     good.sub('{6,peer@erxos,6}', '{6,{error,{erpc,noconnection}},{error,{erpc,noconnection}}}'),
     good.sub('{6,peer@erxos,ready}', '{6,peer@erxos,running}'), good.sub('{2,erts@erxos}', '{3,erts@erxos}')].each do |line|
      assert_raises(Erx::Error) { running.fetch(:verify).call("#{line}\r\n") }
    end
    # The control table: the introduction's record through the full lane and the paused
    # side, the stray command 3 refused. A record that waited behind the paused port (a
    # domain pid that sends it as a message), a stray call that wrote a slot (no caller
    # check), or a lane never filled each fails.
    refute_match table.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    good_table = '{control_table,ok,full,true,badarg,ok,{ok,1,0}}'
    table.fetch(:verify).call("#{good_table}\r\n")
    [good_table.sub('badarg,ok', 'badarg,timeout').sub('{ok,1,0}', '{timeout,0,0}'),
     good_table.sub('badarg', 'ok').sub('{ok,1,0}', '{ok,2,0}'), good_table.sub('full', 'never'), good_table.sub(',ok,full', ',timeout,full'),
     good_table.sub('true', 'false')].each do |line|
      assert_raises(Erx::Error) { table.fetch(:verify).call("#{line}\r\n") }
    end
    # The introduced pair: a missing nodeup, a node missing from nodes() or a call that
    # never came back each fails.
    introduced = points.find { |point| point.fetch(:name) == 'introduced' }
    introduced.fetch(:verify).call("#{Suite::INTRODUCED_ANSWER}\r\n")
    [Suite::INTRODUCED_ANSWER.sub('[peer@erxos,erts@erxos]', '[timeout,erts@erxos]'),
     Suite::INTRODUCED_ANSWER.sub('[peer@erxos,system@erxos]', '[system@erxos]'),
     Suite::INTRODUCED_ANSWER.sub('{pong,5,ping}', '{exit,timeout}')].each do |line|
      assert_raises(Erx::Error) { introduced.fetch(:verify).call("#{line}\r\n") }
    end
    # The forged records: one the agent or the domain pid acted on (no origin check), so
    # nothing more is counted, the call fails or the pair is no longer up, each fails.
    hostile = points.find { |point| point.fetch(:name) == 'hostile' }
    refute_match hostile.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    hostile.fetch(:verify).call("#{Suite::HOSTILE_ANSWER}\r\n")
    [Suite::HOSTILE_ANSWER.sub(',ok,1,1,', ',ok,timeout,1,'), Suite::HOSTILE_ANSWER.sub(',1,1,', ',1,0,'),
     Suite::HOSTILE_ANSWER.sub('{pong,5,ping}', '{error,{erpc,noconnection}}'),
     Suite::HOSTILE_ANSWER.sub(/up\}\z/, 'closing}')].each do |line|
      assert_raises(Erx::Error) { hostile.fetch(:verify).call("#{line}\r\n") }
    end
    # The down path: a burst's tail lost (an agent without the finish), a side never told
    # (no connection_lost from a port that ended by itself), objects never deleted or a
    # quota never freed each fails.
    down = points.find { |point| point.fetch(:name) == 'connection-down' }
    refute_match down.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    down.fetch(:verify).call("#{Suite::CONNECTION_DOWN_ANSWER}\r\n")
    [Suite::CONNECTION_DOWN_ANSWER.sub('{20,true,noconnection}', '{0,true,timeout}'),
     Suite::CONNECTION_DOWN_ANSWER.sub('{ok,noconnection}', '{ok,timeout}'),
     Suite::CONNECTION_DOWN_ANSWER.sub('none,ok,ok', 'closing,{error,closing},ok'),
     Suite::CONNECTION_DOWN_ANSWER.sub(/none,ok\}\z/, 'gone,{error,system_limit}}')].each do |line|
      assert_raises(Erx::Error) { down.fetch(:verify).call("#{line}\r\n") }
    end
    refute_match ends.fetch(:pattern), "1> #{Suite::SERVICE_KILL_EXPRESSION}\r\n"
    down = '{domain_down,5,{halt,69}}'
    good_ends = '{domain_ends,[{6,stopped}],[{5,erts@erxos,ready}],[noconnection,noconnection],gone,' \
                "[{5,{halt,69}},{6,stopped}],[#{down},#{down},{error,#{down}}]," \
                'ok,[ok,ok,ok,ok],[{badrpc,nodedown},{exit,{nodedown,erts@erxos}},{error,{erpc,noconnection}},noconnection,noconnection],' \
                "{500,true,#{down}}}"
    ends.fetch(:verify).call("#{good_ends}\r\n")
    # erts stopped with peer, or ended otherwise than by the halt, or not at all; a watcher
    # told noconnection for erts's end (no edit 56) or erts's reason for peer's end (no
    # creation check); erts still answering when the spawn was made; a library call given
    # the raw domain_down reason, not stock's result for a node gone down.
    [good_ends.sub('[{5,erts@erxos,ready}]', '[]'), good_ends.sub('[{5,{halt,69}},{6,stopped}]', '[{5,stopped},{6,stopped}]'),
     good_ends.sub('[{5,{halt,69}},{6,stopped}]', '[{6,stopped}]'),
     good_ends.sub("[#{down},#{down},{error,#{down}}]", '[noconnection,noconnection,{error,noconnection}]'),
     good_ends.sub('[noconnection,noconnection]', '[{domain_down,5,x},{domain_down,5,x}]'),
     good_ends.sub(',gone,', ',alive,'),
     good_ends.sub(',ok,[ok,ok,ok,ok],', ',ok,[ok,timeout,ok,ok],'),
     good_ends.sub('{badrpc,nodedown}', "{badrpc,{'EXIT',#{down}}}"),
     good_ends.sub('{exit,{nodedown,erts@erxos}}', "{exit,#{down}}"),
     good_ends.sub('{error,{erpc,noconnection}}', "{error,{erpc,#{down}}}"),
     good_ends.sub('noconnection,noconnection],', "{error,#{down}},{error,#{down}}],"),
     good_ends.sub('noconnection,noconnection],', "#{down},#{down}],"),
     # the burst's tail lost, or the burst after the exit
     good_ends.sub("{500,true,#{down}}}", "{437,true,#{down}}}"), good_ends.sub("{500,true,#{down}}}", '{500,true,timeout}}')].each do |line|
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
