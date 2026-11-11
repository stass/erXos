# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'medium_boot'
require_relative 'production_image'

module Erx
  module SystemDomain
    # The re-grant boot of the system_domain suite (docs/design-system.md, "Facets a
    # configured domain serves"): a domain's restart makes the grants it serves, and the
    # grants it holds, anew. Its test image has the service-kill boot's configured
    # domains, erts serving echo through erx_echo_test (ECHO_BOOT) and peer, each restarted
    # once (restarts 1), and grants echo to peer as well as to the system domain. Typed
    # at the system's Erlang shell, EXPRESSION waits for peer's grant, halts erts (the
    # server), waits for the grant of erts's next incarnation, halts peer (the grantee)
    # and waits for the grant of peer's next incarnation, then prints ANSWER and kills the
    # domain service, so the runtime ends with SLOGAN and the machine by itself.
    module Regrant
      RESTARTS_LINE = "  restarts 0\n"
      raise Error, 'the configured rows have no restarts 0 line' unless ECHO_ROW.include?(RESTARTS_LINE)

      ROWS = [ECHO_ROW, PEER_ROW].map { |row| row.sub(RESTARTS_LINE, "  restarts 1\n") }.join +
             ECHO_SERVICES +
             "facet echo_peer\n  grantee @domain.peer\n  service @service.echo\n  operations none\n  max_request 512\n" \
             "  in_flight 4\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n"

      # The ids the domain service gives: erts, peer and the development manifest's
      # storage at boot, then erts's next incarnation and peer's, in the order the
      # expression halts them.
      ERTS = DOMAINS.fetch('erts')
      PEER = DOMAINS.fetch('peer')
      ERTS_AGAIN = STORAGE_ID + 1
      PEER_AGAIN = STORAGE_ID + 2

      # Every variable carries the prefix Rg. RgWait polls the domain service's grant G
      # every 100 ms, at most 1200 times, until it is installed for the pair P (server id,
      # grantee id), and answers its facet, or none. RgSee answers, for peer's facet F,
      # its owner, whether peer's erx:cap(echo) names F, and F's answer to an echo that
      # peer sends it. RgMon watches erts's first facet, which ends with erts.
      EXPRESSION = 'RgAsk=fun(RgN,RgM,RgF,RgA)->try erpc:call(RgN,RgM,RgF,RgA,10000) catch RgC:RgR->{RgC,RgR} end end,' \
                   'RgMints=fun()->gen_server:call(erx_domain_srv,mints) end,' \
                   'RgWait=fun RgW(_,_,0)->none;RgW(RgG,RgP,RgK)->case maps:get(RgG,maps:get(grants,RgMints()),none) of ' \
                   '{installed,RgP,RgFc}->RgFc;_->timer:sleep(100),RgW(RgG,RgP,RgK-1) end end,' \
                   'RgPeer=case [RgG||{RgR,echo}=RgG<-maps:keys(maps:get(grants,RgMints())),RgR=/=system] of [RgPg]->RgPg;_->none end,' \
                   'RgSee=fun(none)->none;(RgFc)->{erx:owner(RgFc),RgAsk(peer@erxos,erx,cap,[echo])=:=RgFc,' \
                   'RgAsk(peer@erxos,gen_server,call,[RgFc,{echo,hi},5000])} end,' \
                   "RgF1=RgWait(RgPeer,{#{ERTS},#{PEER}},1200),RgS1=RgSee(RgF1),RgMon=monitor(process,RgF1)," \
                   'RgAsk(erts@erxos,erlang,halt,[0]),' \
                   "RgD=receive {'DOWN',RgMon,process,_,RgDr}->RgDr after 30000->none end," \
                   "RgF2=RgWait(RgPeer,{#{ERTS_AGAIN},#{PEER}},1200),RgS2=RgSee(RgF2),RgLate=RgAsk(erts@erxos,erx_facet,provide,[late,RgF2])," \
                   "RgSys=RgWait({system,echo},{#{ERTS_AGAIN},#{SYSTEM_CREATION}},1200)," \
                   'RgAsk(peer@erxos,erlang,halt,[0]),' \
                   "RgF3=RgWait(RgPeer,{#{ERTS_AGAIN},#{PEER_AGAIN}},1200),RgS3=RgSee(RgF3)," \
                   'io:format("~0p~n",[{regrant,RgS1,RgD,RgS2,RgF2=/=RgF1,RgLate,RgSys=:=erx:cap(echo),RgS3,RgF3=/=RgF2,' \
                   'maps:get(counts,RgMints())}]),' \
                   'exit(whereis(erx_domain_srv),kill).'
      # peer's first facet is erts's and answers; it ends with erts, which the system
      # domain's monitor sees as erts's domain_down with its halt; the
      # next, of erts's next incarnation, is a new pid that peer finds and calls, as is
      # the system domain's; peer's next incarnation gets another, from the same erts.
      # erts's next incarnation refuses a mint named after its ready report, since init
      # left the provides as reported (erx_facet:provide/2).
      # Each of erts's two reports had relay refused as a mint it does not own and stray
      # as undeclared, and nothing else was refused or dropped.
      ANSWER = "{regrant,{#{ERTS},true,{echo,hi}},{domain_down,#{ERTS},{halt,0}},{#{ERTS_AGAIN},true,{echo,hi}},true,{error,reported},true," \
               "{#{ERTS_AGAIN},true,{echo,hi}},true,\#{{refused,foreign_mint} => 2,{refused,undeclared} => 2}}"
      START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{regrant,/n

      module_function

      # The manifest: MediumBoot's with ROWS, room for erts and peer and a spare for the
      # remains of an ended incarnation's introduced connection.
      def manifest(source) = MediumBoot.manifest(source, row: ROWS, domains: 3)

      # The production checkpoints to the command shell, then the Erlang shell, the
      # expression's answer and the runtime's end. points must end at the command shell.
      def checkpoints(points)
        raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

        answer = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(ANSWER)}\r*\n\z/n
        [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
         ProductionImage::Run::ERLANG_SHELL.merge(type: "#{EXPRESSION}\r").freeze,
         { name: 'regrant', pattern: START, seconds: 600,
           verify: ->(text) { raise Error, "the re-grants gave #{text.inspect}" unless answer.match?(text) } }.freeze,
         { name: 'system-domain-ended', pattern: SLOGAN_PATTERN, seconds: 60,
           verify: ->(text) { raise Error, "the runtime ended with #{text.inspect}" unless SLOGAN.match?(text) } }.freeze].freeze
      end
    end
  end
end
