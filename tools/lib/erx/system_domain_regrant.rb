# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'manifest_text'
require_relative 'medium_boot'
require_relative 'production_image'
require_relative 'session_domain'

module Erx
  module SystemDomain
    # The re-grant boot of the system_domain suite (docs/design-system.md, "Facets a
    # configured domain serves"): a domain's restart makes the grants it serves, and the
    # grants it holds, anew. Its test image has the service-kill boot's configured
    # domains, erts serving echo through erx_echo_test (ECHO_BOOT) and peer, each restarted
    # once (restarts 1), and grants echo to peer and to the system principal's sessions
    # as well as to the system domain. It keeps the development manifest's session
    # template, so the console logs root in at boot and root's session, root_1, takes the
    # line; Ctrl-G gives it to the system shell. Typed at the system's Erlang shell,
    # EXPRESSION waits for peer's grant and root_1's, halts erts (the server), waits for
    # the grants of erts's next incarnation, halts peer (the grantee) and waits for the
    # grant of peer's next incarnation, then prints ANSWER and kills the domain service,
    # so the runtime ends with SLOGAN and the machine by itself.
    module Regrant
      RESTARTS_LINE = "  restarts 0\n"
      raise Error, 'the configured rows have no restarts 0 line' unless ECHO_ROW.include?(RESTARTS_LINE)

      # erts serves echo over two introduced connections, peer's and root_1's, so the
      # limits record erts and peer share allows two.
      CONNECTIONS_LINE = "  connections 1\n"
      raise Error, 'the echo row has no connections 1 line' unless ECHO_ROW.include?(CONNECTIONS_LINE)

      FACET_LIMITS = "  service @service.echo\n  operations none\n  max_request 512\n" \
                     "  in_flight 4\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n"
      ROWS = [ECHO_ROW.sub(CONNECTIONS_LINE, "  connections 2\n"), PEER_ROW]
             .map { |row| row.sub(RESTARTS_LINE, "  restarts 1\n") }.join +
             ECHO_SERVICES +
             "facet echo_peer\n  grantee @domain.peer\n#{FACET_LIMITS}"
      # The grant to every session made from the system principal's template. It follows
      # the template, which the manifest takes from the development manifest's.
      SESSION_FACET = "facet echo_session\n  grantee @session.system\n#{FACET_LIMITS}"

      # The ids the domain service gives: erts, peer and the development manifest's
      # network and storage at boot, then root_1, the console's login, then erts's next incarnation
      # and peer's, in the order the expression halts them.
      ERTS = DOMAINS.fetch('erts')
      PEER = DOMAINS.fetch('peer')
      SESSION = STORAGE_ID + 1
      ERTS_AGAIN = STORAGE_ID + 2
      PEER_AGAIN = STORAGE_ID + 3
      SESSION_NODE = 'root_1@erxos'

      # Every variable carries the prefix Rg. RgWait polls the domain service's grant G
      # every 100 ms, at most 1200 times, until it is installed for the pair P (server id,
      # grantee id), and answers its facet, or none. RgPeer is peer's grant, the one keyed
      # by a configured row; RgSk is root_1's. RgSee answers, for node N's facet F, its
      # owner, whether N's erx:cap(echo) names F, and F's answer to an echo that N sends
      # it. RgMon and RgMs watch erts's first facets, peer's and root_1's, which end with
      # erts. ANSWER's {session,...} element is {RgT1,RgDs,RgT2,RgG2=/=RgG1}: RgSee of
      # root_1's facet RgG1 from erts, RgMs's down reason RgDs, RgSee of RgG2, the facet
      # of erts's next incarnation, and whether that facet is a new one.
      EXPRESSION = 'RgAsk=fun(RgN,RgM,RgF,RgA)->try erpc:call(RgN,RgM,RgF,RgA,10000) catch RgC:RgR->{RgC,RgR} end end,' \
                   'RgMints=fun()->gen_server:call(erx_domain_srv,mints) end,' \
                   'RgWait=fun RgW(_,_,0)->none;RgW(RgG,RgP,RgK)->case maps:get(RgG,maps:get(grants,RgMints()),none) of ' \
                   '{installed,RgP,RgFc}->RgFc;_->timer:sleep(100),RgW(RgG,RgP,RgK-1) end end,' \
                   'RgPeer=case [RgG||{RgR,echo}=RgG<-maps:keys(maps:get(grants,RgMints())),is_integer(RgR)] of [RgPg]->RgPg;_->none end,' \
                   "RgSk={{session,#{SESSION}},echo}," \
                   'RgSee=fun(_,none)->none;(RgNd,RgFc)->{erx:owner(RgFc),RgAsk(RgNd,erx,cap,[echo])=:=RgFc,' \
                   'RgAsk(RgNd,gen_server,call,[RgFc,{echo,hi},5000])} end,' \
                   "RgF1=RgWait(RgPeer,{#{ERTS},#{PEER}},1200),RgS1=RgSee(peer@erxos,RgF1),RgMon=monitor(process,RgF1)," \
                   "RgG1=RgWait(RgSk,{#{ERTS},#{SESSION}},1200),RgT1=RgSee(#{SESSION_NODE},RgG1),RgMs=monitor(process,RgG1)," \
                   'RgAsk(erts@erxos,erlang,halt,[0]),' \
                   "RgD=receive {'DOWN',RgMon,process,_,RgDr}->RgDr after 30000->none end," \
                   "RgDs=receive {'DOWN',RgMs,process,_,RgDsr}->RgDsr after 30000->none end," \
                   "RgF2=RgWait(RgPeer,{#{ERTS_AGAIN},#{PEER}},1200),RgS2=RgSee(peer@erxos,RgF2)," \
                   'RgLate=RgAsk(erts@erxos,erx_facet,provide,[late,RgF2]),' \
                   "RgSys=RgWait({system,echo},{#{ERTS_AGAIN},#{SYSTEM_CREATION}},1200)," \
                   "RgG2=RgWait(RgSk,{#{ERTS_AGAIN},#{SESSION}},1200),RgT2=RgSee(#{SESSION_NODE},RgG2)," \
                   'RgAsk(peer@erxos,erlang,halt,[0]),' \
                   "RgF3=RgWait(RgPeer,{#{ERTS_AGAIN},#{PEER_AGAIN}},1200),RgS3=RgSee(peer@erxos,RgF3)," \
                   'io:format("~0p~n",[{regrant,RgS1,RgD,RgS2,RgF2=/=RgF1,RgLate,RgSys=:=erx:cap(echo),RgS3,RgF3=/=RgF2,' \
                   '{session,RgT1,RgDs,RgT2,RgG2=/=RgG1},maps:get(counts,RgMints())}]),' \
                   'exit(whereis(erx_domain_srv),kill).'
      # peer's first facet is erts's and answers; it ends with erts, which the system
      # domain's monitor sees as erts's domain_down with its halt; the
      # next, of erts's next incarnation, is a new pid that peer finds and calls, as is
      # the system domain's; peer's next incarnation gets another, from the same erts.
      # erts's next incarnation refuses a mint named after its ready report, since init
      # left the provides as reported (erx_facet:provide/2).
      # root_1's facet, minted when its session reported ready, is erts's too and answers,
      # ends with erts as peer's does, and root_1 gets a new one, of erts's next
      # incarnation, which answers as well.
      # Each of erts's two reports had relay refused as a mint it does not own and stray
      # as undeclared, and nothing else was refused or dropped.
      ANSWER = "{regrant,{#{ERTS},true,{echo,hi}},{domain_down,#{ERTS},{halt,0}},{#{ERTS_AGAIN},true,{echo,hi}},true,{error,reported},true," \
               "{#{ERTS_AGAIN},true,{echo,hi}},true," \
               "{session,{#{ERTS},true,{echo,hi}},{domain_down,#{ERTS},{halt,0}},{#{ERTS_AGAIN},true,{echo,hi}},true}," \
               "\#{{refused,foreign_mint} => 2,{refused,undeclared} => 2}}"
      START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{regrant,/n

      module_function

      # The machine's connection table holds every domain's system connection and every
      # introduced pair. The development manifest's rows fit erts's, peer's and storage's
      # and the pair erts-peer; root_1's system connection and the pair erts-root_1 take
      # two more, with no slack. After erts halts, its system row is freed at once but
      # each introduced pair row only when its survivor lets go, and root_1's own quota
      # (connections 1) counts its old pair row until then; the cell relies on a domain
      # boot (seconds) outlasting that release (milliseconds). Losing that race fails
      # the cell with a grant left at none, never a false pass.
      MORE_CONNECTIONS = 2

      # The manifest: MediumBoot's with ROWS, the source's session templates and
      # SESSION_FACET, room for erts and peer and a spare for the remains of an ended
      # incarnation's introduced connection, and MORE_CONNECTIONS; root_1 takes the room
      # the development manifest keeps for a session.
      def manifest(source)
        sessions = ProductionImage.sessions(source)
        raise Error, 'the manifest has no session template of the system principal' unless sessions.start_with?("session system\n")

        ManifestText.grow(MediumBoot.manifest(source, row: ROWS + sessions + SESSION_FACET, domains: 3),
                          { %w[machine max_connections] => MORE_CONNECTIONS })
      end

      # The production checkpoints to the system's command shell, root_1's command shell,
      # the Ctrl-G menu and its system shell entry, then the system's Erlang shell, the
      # expression's answer and the runtime's end. points must end at the command shell
      # and type nothing there, since root_1 takes the line next.
      def checkpoints(points)
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'
        raise Error, 'the production checkpoints type at the shell' if points.last.key?(:type)

        answer = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(ANSWER)}\r*\n\z/n
        [*points,
         SessionDomain.session_shell('root_1-shell', ProductionImage::Run::CTRL_G),
         { name: 'menu', pattern: ProductionImage::Run::CTRL_G_MENU, seconds: 30, type: 's' }.freeze,
         { name: 'system-shell', pattern: SessionDomain::MENU_LEFT, seconds: 30, type: ProductionImage::Run::ERL_LINE }.freeze,
         ProductionImage::Run::ERLANG_SHELL.merge(type: "#{EXPRESSION}\r").freeze,
         { name: 'regrant', pattern: START, seconds: 600,
           verify: ->(text) { raise Error, "the re-grants gave #{text.inspect}" unless answer.match?(text) } }.freeze,
         { name: 'system-domain-ended', pattern: SLOGAN_PATTERN, seconds: 60,
           verify: ->(text) { raise Error, "the runtime ended with #{text.inspect}" unless SLOGAN.match?(text) } }.freeze].freeze
      end
    end
  end
end
