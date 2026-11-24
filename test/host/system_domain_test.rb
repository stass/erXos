# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/system_domain'

# What the system_domain suite's harness types and expects (tools/lib/erx/system_domain.rb).
# Nothing boots here.
class SystemDomainTest < Minitest::Test
  Suite = Erx::SystemDomain
  ROOT = File.expand_path('../..', __dir__)
  SITE = Erx::Platform.development(ROOT).site_manifest_source(ROOT)
  # The create grant of the suite's manifest.
  GRANT = Erx::MediumBoot.created_grant(Suite.manifest(SITE))

  # The rows are MediumBoot's with the halt dropped, so each configured domain stays up,
  # over the erx carrier, as MediumBoot's, so each is a node, behind the flag that lets the
  # control_table step hold a domain's ring; the manifest differs from MediumBoot's only in
  # that row's arguments, its one connection, the control table's one slot, erts's test
  # script (ECHO_BOOT), the second row, peer, and the echo checkpoint's service and facet
  # rows.
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
    medium = Erx::MediumBoot.manifest(SITE)
    ours = Suite.manifest(SITE)
    assert ours.end_with?(Suite::ECHO_ROW + Suite::PEER_ROW + Suite::ECHO_SERVICES)
    assert_equal Suite::DOMAIN_ROW, Suite::ECHO_ROW.sub("  release @artifact.echo\n", "  release @artifact.erts\n")
    assert Suite::ECHO_BOOT.test
    assert_includes Suite::ECHO_BOOT.applications, 'erx_echo_test'
    assert ours.start_with?(medium.delete_suffix(Erx::MediumBoot::DOMAIN_ROW) + Erx::MediumBoot::EIGHTH_SHARE)
    rows = ours
    kept = medium.lines.size - 1
    assert_equal [["  connections 0\n", "  connections 1\n"], ["  release @artifact.erts\n", "  release @artifact.echo\n"]],
                 medium.lines[0...-1].zip(rows.lines[0...kept]).reject { |theirs, mine| theirs == mine }
    assert_match(/^  args ".* -eval /, medium.lines.last)
    assert_equal ["  args \"#{Suite::DOMAIN_ARGS.join(' ')}\"\n", *Suite::PEER_ROW.lines, *Suite::ECHO_SERVICES.lines],
                 rows.lines[kept..]
  end

  # The kill follows the Erlang shell; the answer must name both configured domains
  # running, the system node, and each domain's own answers over its system connection;
  # the ends must be peer's stop alone, then erts's halt with status 69; and the runtime
  # must end with the slogan of erx_domain's end, not another.
  def test_the_kill_waits_for_the_running_domains_and_must_see_the_applications_end
    shell = { name: 'release-shell', pattern: /x/n, seconds: 60 }.freeze
    domain = Erx::MediumBoot::Domain.new(runtime: 11, jit: 12, release: 13, release_files: 14)
    points = Suite.service_kill_checkpoints([{ name: 'image-identity', pattern: /y/n, seconds: 30 }, shell], domain: domain, grant: GRANT)
    lines = [Suite.service_kill_setup(domain, grant: GRANT), *Suite::SERVICE_KILL_STEPS.values]
    assert_equal %w[image-identity release-shell erlang-shell echo-facet foreign-atom service-kill-1 domain-running service-kill-2
                    control-table service-kill-3 introduced service-kill-4 hostile service-kill-5 connection-down service-kill-6
                    ignored-down service-kill-7 later-domain service-kill-8 domain-ends system-domain-ended],
                 points.map { |point| point.fetch(:name) }
    assert_equal Erx::ProductionImage::Run::ERL_LINE, points[1].fetch(:type)
    # Each line is typed once the shell has printed the atom the line before ends with,
    # and the console's tty holds every one whole.
    typed = points.drop(2).filter_map { |point| point[:type] }
    assert_equal [*lines[0...-1].each_with_index.map { |line, index| "#{line},service_kill_#{index + 1}.\r" }, "#{lines.last}\r"], typed
    assert_equal 'service-kill-1', points[5].fetch(:name)
    assert_match points[5].fetch(:pattern), "service_kill_1\r\n"
    refute_match points[5].fetch(:pattern), "#{typed.first}\n"
    typed.each { |line| assert_operator line.bytesize, :<, Erx::ABI::Generated.constant('tty_max_input') }
    Erx::Transcript.new(checkpoints: points)
    # The later domain's request names the image's runtime and release, the rows' boot
    # script, and one connection.
    assert lines.first.start_with?('SdSpec=#{name=><<"peer">>,runtime=>11,release=>13,release_files=>14,boot=><<"erts">>,')
    assert lines.first.end_with?(",connections=>1},#{Suite::ECHO_EXPRESSION},#{Suite::FOREIGN_ATOM_EXPRESSION}")
    assert lines[1].start_with?('SdLives=')
    named = points.to_h { |point| [point.fetch(:name), point] }
    running, table, ignored, later, ends, ended = named.values_at('domain-running', 'control-table', 'ignored-down', 'later-domain',
                                                                  'domain-ends', 'system-domain-ended')
    # No answer's pattern matches the shell's echo of a typed line, after a prompt or not.
    echoes = typed.flat_map { |line| ["#{line}\n", "1> #{line}\n"] }
    named.except('image-identity', 'release-shell', 'erlang-shell').each_value do |point|
      echoes.each { |echo| refute_match point.fetch(:pattern), echo, point.fetch(:name) }
    end
    # The echo checkpoint: the facet answered and both hostile provides refused, and
    # nothing else. A report whose foreign mint was taken (no owner check), a call the
    # facet did not answer, or a facet erx:cap/1 does not find each fails.
    echo = points[3]
    good_echo = '{echo_facet,true,{echo,hi},{error,badarg},#{{refused,foreign_mint} => 1,{refused,undeclared} => 1}}'
    echo.fetch(:verify).call("1> #{good_echo}\r\n")
    [good_echo.sub('{refused,foreign_mint} => 1,', ''), good_echo.sub('{echo,hi}', "{'EXIT',noproc}"),
     good_echo.sub('echo_facet,true', 'echo_facet,false')].each do |bad|
      assert_raises(Erx::Error) { echo.fetch(:verify).call("#{bad}\r\n") }
    end
    good = '{service_kill,[{5,erts@erxos,ready},{7,peer@erxos,ready}],system@erxos,4,' \
           '[erts@erxos,network@erxos,peer@erxos,storage@erxos],[{5,erts@erxos,5},{7,peer@erxos,7}],{2,erts@erxos}}'
    running.fetch(:verify).call("1> #{good}\r\n")
    ['timeout', good.sub('system@erxos,4', 'nonode@nohost,0'), good.sub('peer@erxos,storage', 'storage'),
     good.sub('network@erxos,', ''),
     good.sub('{7,peer@erxos,7}', '{7,{error,{erpc,noconnection}},{error,{erpc,noconnection}}}'),
     good.sub('{7,peer@erxos,ready}', '{7,peer@erxos,running}'), good.sub('{2,erts@erxos}', '{3,erts@erxos}')].each do |line|
      assert_raises(Erx::Error) { running.fetch(:verify).call("#{line}\r\n") }
    end
    # The control table: the introduction's record through the full lane and the paused
    # side, the stray command 3 refused. A record that waited behind the paused port (a
    # domain pid that sends it as a message), a stray call that wrote a slot (no caller
    # check), or a lane never filled each fails.
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
    hostile.fetch(:verify).call("#{Suite::HOSTILE_ANSWER}\r\n")
    [Suite::HOSTILE_ANSWER.sub(',ok,1,1,', ',ok,timeout,1,'), Suite::HOSTILE_ANSWER.sub(',1,1,', ',1,0,'),
     Suite::HOSTILE_ANSWER.sub('{pong,5,ping}', '{error,{erpc,noconnection}}'),
     Suite::HOSTILE_ANSWER.sub(/up\}\z/, 'closing}'),
     # a domain pid that passes malformed answers on, a core that does not count an
     # answer for a connection that does not exist
     Suite::HOSTILE_ANSWER.sub('{5,3}', '{8,0}'), Suite::HOSTILE_ANSWER.sub('{5,3}', '{2,3}')].each do |answer|
      assert_raises(Erx::Error) { hostile.fetch(:verify).call("#{answer}\r\n") }
    end
    # The down path: a burst's tail lost (an agent without the finish), a side never told
    # (no connection_lost from a port that ended by itself), objects never deleted or a
    # quota never freed each fails.
    down = points.find { |point| point.fetch(:name) == 'connection-down' }
    down.fetch(:verify).call("#{Suite::CONNECTION_DOWN_ANSWER}\r\n")
    [Suite::CONNECTION_DOWN_ANSWER.sub('{20,true,noconnection}', '{0,true,timeout}'),
     Suite::CONNECTION_DOWN_ANSWER.sub('{ok,noconnection}', '{ok,timeout}'),
     Suite::CONNECTION_DOWN_ANSWER.sub('none,ok,ok', 'closing,{error,closing},ok'),
     Suite::CONNECTION_DOWN_ANSWER.sub(/none,ok,(\{ok,pong,false,timeout,ok,pong\})\}\z/,
                                       'gone,{error,system_limit},\1}'),
     Suite::CONNECTION_DOWN_ANSWER.sub('{ok,pong,false,timeout,ok,pong}', '{ok,pong,true,pong,ok,pong}')].each do |line|
      assert_raises(Erx::Error) { down.fetch(:verify).call("#{line}\r\n") }
    end
    # The ignored connection_down: a core that lets the connection go, or frees erts's
    # quota, while erts never answered, or an agent that answered anyway, each fails.
    ignored.fetch(:verify).call("#{Suite::IGNORED_DOWN_ANSWER}\r\n")
    [Suite::IGNORED_DOWN_ANSWER.sub('{closing,1,0,', '{gone,0,0,'), Suite::IGNORED_DOWN_ANSWER.sub('{closing,1,0,', '{closing,0,0,'),
     Suite::IGNORED_DOWN_ANSWER.sub('{error,closing}', 'ok'), Suite::IGNORED_DOWN_ANSWER.sub('false,true', 'true,true'), Suite::IGNORED_DOWN_ANSWER.sub(',ok,none,ok}', ',ok,closing,{error,closing}}')]
      .each { |answer| assert_raises(Erx::Error) { ignored.fetch(:verify).call("#{answer}\r\n") } }
    # The later domain of peer: one that reused the ended domain's id, a nodeup before
    # the nodedown, or a message to the ended domain's pid that ended the connection (a
    # target rule that requires the receiver's creation), a monitor of that pid answered
    # by the connection's end (a monitor sent to the later peer), or a stale pid taken for
    # the later domain's process of the same number and serial, or a build answer that is
    # supervised or has no supervised key, each fails.
    later.fetch(:verify).call("#{Suite::LATER_DOMAIN_ANSWER}\r\n")
    [Suite::LATER_DOMAIN_ANSWER.sub('{9,ok}', '{7,ok}'), Suite::LATER_DOMAIN_ANSWER.sub('[nodedown,nodeup]', '[nodeup,nodedown]'),
     Suite::LATER_DOMAIN_ANSWER.sub('true},up}', 'true},down}'), Suite::LATER_DOMAIN_ANSWER.sub('{9,ok}', '{error,name_taken}'),
     Suite::LATER_DOMAIN_ANSWER.sub('{noproc,noproc,noproc,noproc,', '{noconnection,noproc,noconnection,noconnection,'),
     Suite::LATER_DOMAIN_ANSWER.sub('sd_new', 'sd_old'), Suite::LATER_DOMAIN_ANSWER.sub(/false\}\z/, 'true}'),
     Suite::LATER_DOMAIN_ANSWER.sub(/false\}\z/, 'none}')]
      .each { |answer| assert_raises(Erx::Error) { later.fetch(:verify).call("#{answer}\r\n") } }
    down = '{domain_down,5,{halt,69}}'
    good_ends = '{domain_ends,[{7,stopped}],[{5,erts@erxos,ready}],[noconnection,noconnection],gone,' \
                "[{5,{halt,69}},{7,stopped}],[#{down},#{down},{error,#{down}}]," \
                'ok,[ok,ok,ok,ok],[{badrpc,nodedown},{exit,{nodedown,erts@erxos}},{error,{erpc,noconnection}},noconnection,noconnection],' \
                "{500,true,#{down}}}"
    ends.fetch(:verify).call("#{good_ends}\r\n")
    # erts stopped with peer, or ended otherwise than by the halt, or not at all; a watcher
    # told noconnection for erts's end (no edit 56) or erts's reason for peer's end (no
    # creation check); erts still answering when the spawn was made; a library call given
    # the raw domain_down reason, not stock's result for a node gone down.
    [good_ends.sub('[{5,erts@erxos,ready}]', '[]'), good_ends.sub('[{5,{halt,69}},{7,stopped}]', '[{5,stopped},{7,stopped}]'),
     good_ends.sub('[{5,{halt,69}},{7,stopped}]', '[{7,stopped}]'),
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
    assert_raises(Erx::Error) { Suite.service_kill_checkpoints([shell, points[0]], domain: domain, grant: GRANT) }
  end

  # The re-grant boot: the service-kill boot's rows, each restarted once, with echo
  # granted to peer and to the system principal's sessions as well, and the development
  # manifest's session template kept, so root_1 takes the line at boot and Ctrl-G gives
  # it to the system shell. Its checkpoint takes only the whole answer: a grant not made
  # again for erts's next incarnation (a core that does not reconcile on a restarted
  # row's report leaves the waits at none), a facet that does not answer, a mint taken
  # after the report, a missing refusal, or a session that keeps its old facet, gets
  # none or gets none again each fails.
  def test_the_regrant_boot_restarts_each_domain_once_and_needs_every_grant_anew
    regrant = Suite::Regrant
    rows = regrant::ROWS
    assert_equal 2, rows.scan("  restarts 1\n").size
    refute_includes rows, "  restarts 0\n"
    assert_includes rows, "limits erts\n"
    assert_includes rows, "  connections 2\n"
    assert_includes rows, "facet echo_peer\n  grantee @domain.peer\n  service @service.echo\n"
    manifest = regrant.manifest(SITE)
    # Each record the boot adds is in the manifest whole (the edits print it again,
    # kind by kind, so not at its end).
    added = (rows + Erx::ProductionImage.sessions(SITE) + regrant::SESSION_FACET).scan(/^[a-z].*\n(?:  .*\n)*/)
    assert_operator added.size, :>, 3
    added.each { |record| assert_includes manifest, record }
    assert_includes manifest, "facet echo_session\n  grantee @session.system\n  service @service.echo\n" \
                              "#{regrant::FACET_LIMITS.sub("  service @service.echo\n", '')}"
    assert_equal 1, manifest.scan(/^session /).size
    assert_equal Integer(SITE[/^  max_connections ([0-9]+)$/, 1], 10) + 2,
                 Integer(manifest[/^  max_connections ([0-9]+)$/, 1], 10)
    assert_raises(Erx::Error) { regrant.manifest(Erx::ProductionImage.without_sessions(SITE)) }
    shell = { name: 'release-shell', pattern: /y/n, seconds: 30 }.freeze
    points = regrant.checkpoints([shell])
    assert_raises(Erx::Error) { regrant.checkpoints([shell.merge(type: "x\r")]) }
    assert_equal %w[release-shell root_1-shell menu system-shell erlang-shell regrant load crash-record],
                 points.map { |point| point.fetch(:name) }
    assert_equal [nil, "\a", 's', "erl\r", "#{regrant::EXPRESSION}\r"], points[0..4].map { |point| point[:type] }
    verify = points[5].fetch(:verify)
    verify.call("1> #{regrant::ANSWER}\r\n")
    again = regrant::ERTS_AGAIN
    first = "{#{regrant::ERTS},true,{echo,hi}}"
    [regrant::ANSWER.sub("{#{again},true,{echo,hi}},true,{error,reported},true", 'none,true,{error,{erpc,noconnection}},false'),
     regrant::ANSWER.sub('{error,reported}', 'ok'),
     regrant::ANSWER.sub(/\{#{again},true,\{echo,hi\}\},true,\{session,/o, 'none,true,{session,'),
     regrant::ANSWER.sub('{echo,hi}', "{error,{erpc,noconnection}}"),
     regrant::ANSWER.sub('{refused,foreign_mint} => 2', '{refused,foreign_mint} => 1'),
     regrant::ANSWER.sub("{session,#{first}", '{session,none'),
     regrant::ANSWER.sub("{session,#{first},{domain_down,#{regrant::ERTS},{halt,0}}", "{session,#{first},none"),
     regrant::ANSWER.sub("{halt,0}},{#{again},true,{echo,hi}},true}", "{halt,0}},{#{regrant::ERTS},false,{echo,hi}},true}"),
     regrant::ANSWER.sub("{halt,0}},{#{again},true,{echo,hi}},true}", '{halt,0}},none,true}')].each do |bad|
      refute_equal regrant::ANSWER, bad
      assert_raises(Erx::Error) { verify.call("#{bad}\r\n") }
    end
    load = points[6].fetch(:verify)
    load.call("#{regrant::LOAD_ANSWER}\r\n")
    assert_raises(Erx::Error) { load.call("{load,[true,false,true]}\r\n") }
    assert_raises(Erx::Error) { regrant.checkpoints([shell, { name: 'other' }]) }
  end

  # The boot's end is judged by the first crash record after the load's line: the abort's
  # write to address 0 in the root task passes; a record before that line, or another
  # root fault, a read of a decommitted page, does not.
  def test_the_regrant_boot_ends_with_a_crash_record_of_the_aborts_write_to_address_0
    load = "#{Suite::Regrant::LOAD_ANSWER}\r\n"
    abort = File.binread(File.expand_path('../fixtures/system_domain/abort.log', __dir__))
    Suite::Regrant.judge(abort)
    other = File.binread(File.expand_path('../fixtures/native_crash/decommitted.log', __dir__))
    assert_match(/absent/, assert_raises(Erx::Error) { Suite::Regrant.judge(other + load) }.message)
    assert_match(/address, access disagree/, assert_raises(Erx::Error) { Suite::Regrant.judge(load + other) }.message)
  end
end
