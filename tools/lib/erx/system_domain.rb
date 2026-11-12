# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # The system domain with ERTS domains running under it (docs/design-system.md,
  # "System services", "The root task and its end"). It boots a test image (ECHO_BOOT) on
  # MediumBoot's machine with a manifest whose two configured ERTS domains stay up, each
  # a node over the erx carrier, and types at the system's Erlang shell, as a person
  # would, from the production checkpoints' command shell on.
  #
  # Its one cell, service_kill, at each CPU count: once both configured domains run, the
  # shell prints what the system node is and what each domain answers over its system
  # connection (docs/design-runtime.md, "Connections in ERTS"), ends each domain from its
  # connection, and then kills the domain service. The system domain is system@<host> with
  # creation 4, alive since kernel started net_kernel, before the domain service; each
  # domain's node() is its name at the host and its creation its id, as erpc:call from the
  # system shell, which needs the system side to carry frames both ways, answers. Ending
  # peer's system side's port in the system domain with {domain_down, D2, x}, D2 not
  # peer's id, fires noconnection on a system-domain process's link to and monitor on a
  # process of peer, and stops peer and only peer (docs/design-system.md, "A lost system
  # connection ends the domain"); killing erts's own agent, its erx_connections, halts
  # erts with status 69, and the domain service's end of erts's side fires
  # {domain_down, Erts, {halt, 69}} on a link, a monitor and a pending spawn_request
  # into it (edit 56 of docs/design-runtime.md), while gen:call, erpc:call, rpc:call,
  # spawn_monitor/4 and spawn_link/4 into it keep stock's results for a node gone down
  # (edit 64);
  # and the system domain runs on to the service's kill. The service is the system release's
  # significant child, so its end shuts its supervisor down and ends the permanent
  # application, and init ends the runtime with its slogan on the console, which is the
  # report of the failure table's row; the root's stop then ends the machine. The machine
  # must end by itself (Qemu#run's machine_end). That no domain is left running follows
  # from it, since every domain's space is a child of the system domain's; the cell does
  # not look for one. Nor does it read a crash record: on the stopgap kernel the root's
  # own stop writes none (TODO.md, the liberx Fiasco backend's halt item).
  module SystemDomain
    # What the configured domains' ERTS runs: MediumBoot's arguments without the -eval
    # that halts, so its init runs the release's boot script over the erx carrier and the
    # domain stays up as a node, behind the emulator flag that lets the control_table step
    # hold its system connection's ring (erx_lane_drv.c, port_control 4).
    raise Error, 'MediumBoot::DOMAIN_ARGS no longer ends in its -eval' unless MediumBoot::DOMAIN_ARGS[-2] == '-eval'
    raise Error, 'MediumBoot::UP_ARGS no longer starts with --' unless MediumBoot::UP_ARGS.first == '--'

    DOMAIN_ARGS = ['-erx', 'test_lane_hold', *MediumBoot::UP_ARGS].freeze

    # The suite's records for erts: MediumBoot's share eighth, limits erts and domain erts
    # with two changes. The limits allow one connection, so the control table has one
    # slot. The domain takes DOMAIN_ARGS. A second domain, peer, of the same limits and
    # arguments, follows (PEER_ROW), so the two take the 250 mcpu the reserve leaves (see
    # MediumBoot::EIGHTH_SHARE). Both have restarts 0, so the domain service starts each
    # once, at boot.
    ARGS_LINE = /^  args ".*"\n\z/
    CONNECTIONS_LINE = /^  connections 0\n/
    DOMAIN_ROW = MediumBoot::DOMAIN_ROW.sub(ARGS_LINE, "  args \"#{DOMAIN_ARGS.join(' ')}\"\n")
                                       .sub(CONNECTIONS_LINE, "  connections 1\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW does not end in its args line' unless DOMAIN_ROW.include?('test_lane_hold')
    raise Error, 'MediumBoot::DOMAIN_ROW has no connections 0 line' unless DOMAIN_ROW.include?("  connections 1\n")

    PEER_ROW = DOMAIN_ROW[/^domain erts\n.*/m].to_s.sub(/\Adomain erts\n/, "domain peer\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW has no domain erts' unless PEER_ROW.start_with?("domain peer\n")

    # The echo checkpoint (ECHO_EXPRESSION): erts boots ECHO_BOOT, MediumBoot's script with
    # the test-only application erx_echo_test, which provides echo before init's ready
    # report and adds relay, a mint of the system domain's, and stray, a name no row
    # declares; peer boots MediumBoot's script, without it. erts serves echo, relay and
    # spare; nothing provides spare, which keeps the report's three entries within the row's
    # declarations and each is judged by itself (erx_domain_mints:authenticate); the
    # system domain is granted echo. Only a test image carries ECHO_BOOT
    # (ProductionImage#build_test_image).
    ECHO_BOOT = ReleaseFiles.domain_boot('echo', applications: [*MediumBoot::DOMAIN_BOOT.applications, 'erx_echo_test'],
                                                 test: true)
    ECHO_ROW = DOMAIN_ROW.sub("  release @artifact.#{MediumBoot::DOMAIN_BOOT.name}\n", "  release @artifact.#{ECHO_BOOT.name}\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW names no release line' if ECHO_ROW == DOMAIN_ROW

    ECHO_SERVICES = %w[echo relay spare].map { |name| "service #{name}\n  server @domain.erts\n  interface 1\n" }.join +
                    "facet echo\n  grantee system\n  service @service.echo\n  operations none\n  max_request 512\n" \
                    "  in_flight 4\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 65536\n"

    # The domain service gives the configured rows the first ids above the system domain's,
    # in boot order, which is name order here: erts, the development manifest's network
    # domain, peer, then the development manifest's storage domain. The cell leaves the
    # development manifest's two (MANIFEST_NODES) out of what it reads of the service's
    # domains (SdLives) but not of the system node's nodes(); host is the development
    # manifest's.
    CONFIGURED_ID = MediumBoot::CONFIGURED_ID
    DOMAINS = { 'erts' => CONFIGURED_ID, 'peer' => CONFIGURED_ID + 2 }.freeze
    STORAGE_ID = CONFIGURED_ID + 3
    MANIFEST_NODES = %w[network@erxos storage@erxos].freeze
    SYSTEM_NODE = 'system@erxos'
    SYSTEM_CREATION = MediumBoot::SYSTEM_DOMAIN_ID

    # Typed at the Erlang shell, in parts. Every variable carries the prefix Sd, which no
    # other expression of the suite binds, since the shell keeps every binding.
    # SdLives: each of the cell's domains' id, node and life, by id, from the domain
    # service's state (MediumBoot reads it the same way), MANIFEST_NODES left out; the
    # shell starts after the boot, so the core is built.
    SERVICE_KILL_LIVES = 'SdLives=fun()->lists:sort([{SdI,SdN,SdS}||#{id:=SdI,node:=SdN,state:=SdS}<-' \
                         "erx_domain_core:domains(maps:get(core,sys:get_state(erx_domain_srv)))," \
                         "not lists:member(SdN,[#{MANIFEST_NODES.join(',')}])]) end"
    # SdWait: polls SdLives every 100 ms at most N times until two domains are ready, their
    # inits having reported, and MANIFEST_NODES are nodes of the system's nodes(), so
    # the nodes the cell reads hold them whichever domain the boot made last; answers the
    # last SdLives.
    SERVICE_KILL_WAIT = 'SdWait=fun SdW(0)->SdLives();SdW(SdK)->case {SdLives(),' \
                        "[SdM||SdM<-[#{MANIFEST_NODES.join(',')}],not lists:member(SdM,nodes())]} of " \
                        '{[{_,_,ready},{_,_,ready}]=SdLv,[]}->SdLv;_->timer:sleep(100),SdW(SdK-1) end end'
    # SdAsk: erpc:call of erlang:F(A) at a node, within 10 s, or the class and reason it
    # raised. SdPeers: each domain's id with its node() and creation, as it answers them.
    SERVICE_KILL_ASK = 'SdAsk=fun(SdN,SdF,SdA)->try erpc:call(SdN,erlang,SdF,SdA,10000) catch SdC:SdR->{SdC,SdR} end end,' \
                       'SdPeers=fun(SdL)->[{SdI,SdAsk(SdN,node,[]),SdAsk(SdN,system_info,[creation])}||{SdI,SdN,_}<-SdL] end'
    # The system node's name and creation, and the connected nodes. That the node was
    # alive before the domain service started follows from the configured domains running:
    # the service opened their sides at its start, which a runtime that is no node cannot.
    SERVICE_KILL_SYSTEM = 'node(),erlang:system_info(creation),lists:sort(nodes())'
    # SdDeaths: each ended domain's id and info, from the system principal's deaths, which
    # the domain service keeps after it retires the domain. SdUntil: polls SdDeaths every
    # 100 ms at most K times until N domains ended, and answers the last SdDeaths.
    SERVICE_KILL_DEATHS = 'SdDeaths=fun()->lists:sort([{SdI,SdF}||#{id:=SdI,info:=SdF}<-erx_domain_core:deaths(1,' \
                          'maps:get(core,sys:get_state(erx_domain_srv)))]) end,' \
                          'SdUntil=fun SdU(_,0)->SdDeaths();SdU(SdN,SdK)->case SdDeaths() of SdDs when length(SdDs)>=SdN->SdDs;' \
                          '_->timer:sleep(100),SdU(SdN,SdK-1) end end'
    # SdForged: messages to domain I's domain pid, of node N, shaped as the domain's own,
    # the ready report and an answer, but sent by this shell, unwrapped: the pid drops and
    # counts both, and its info names the agent the domain's own report named, a process
    # of N. Answers the count and the agent's node.
    SERVICE_KILL_FORGED = 'SdForged=fun(SdI,SdN)->SdPid=hd([SdP||#{id:=SdJ,pid:=SdP}<-erx_domain_core:domains(' \
                          'maps:get(core,sys:get_state(erx_domain_srv))),SdJ=:=SdI]),' \
                          'SdPid!{erx_ready,#{connections=>self(),inspect=>self()}},SdPid!{erx_connection_mapped,1},' \
                          '{ok,#{connections:=SdAg,dropped:=SdDr}}=erx_domain:info({erx_domain,SdI,SdN,SdPid}),' \
                          '{SdDr,node(SdAg)} end'
    # SdWatch: a system-domain process that traps exits, links to and monitors process P of
    # a domain, and answers the shell once it watches. Told {sd_spawn, Node}, it then makes a
    # spawn_request into Node and says so; told sd_go, it makes none. It answers
    # {sd_watched, W, [Exit, Down | Spawn]}: the reason of P's 'EXIT', of its 'DOWN', and the
    # spawn_reply's {error, Reason} or {ok, Pid}, timeout for any not come within 60 s.
    # SdGone: polls Node with an erpc:call of 500 ms at most K times, 100 ms apart, until no
    # answer comes, then gone; alive if it always answered.
    SERVICE_KILL_WATCH = 'SdWatch=fun(SdP)->SdSelf=self(),SdW=spawn(fun()->process_flag(trap_exit,true),link(SdP),' \
                         'SdM=monitor(process,SdP),SdSelf!{sd_watching,self()},' \
                         'SdQ=receive {sd_spawn,SdNd}->SdQ0=spawn_request(SdNd,timer,sleep,[infinity],[]),' \
                         'SdSelf!{sd_spawned,self()},[SdQ0];sd_go->[] end,' \
                         'SdX=receive {\'EXIT\',SdP,SdX0}->SdX0 after 60000->timeout end,' \
                         'SdD=receive {\'DOWN\',SdM,process,SdP,SdD0}->SdD0 after 60000->timeout end,' \
                         'SdR=[receive {spawn_reply,SdQ1,SdOk,SdR0}->{SdOk,SdR0} after 60000->timeout end||SdQ1<-SdQ],' \
                         'SdSelf!{sd_watched,self(),[SdX,SdD|SdR]} end),receive {sd_watching,SdW}->SdW end end,' \
                         'SdGone=fun SdG(_,0)->alive;SdG(SdN,SdK)->try erpc:call(SdN,erlang,node,[],500) of ' \
                         '_->timer:sleep(100),SdG(SdN,SdK-1) catch _:_->gone end end'
    # SdCall: a system-domain process that traps exits, runs Fn and answers the shell
    # {sd_called, C, Result}, Result Fn's value or the class and reason it raised.
    # SdBlocked: polls process C every 10 ms at most K times until it waits in a receive,
    # its call's request sent; timeout if it never does, which the printed answer shows,
    # since a call made after the side ended would get stock's results without edit 64.
    SERVICE_KILL_CALL = 'SdCall=fun(SdFn)->SdCs=self(),spawn(fun()->process_flag(trap_exit,true),' \
                        'SdCs!{sd_called,self(),try SdFn() catch SdCc:SdCr->{SdCc,SdCr} end} end) end,' \
                        'SdBlocked=fun SdB(_,0)->timeout;SdB(SdBp,SdBk)->case process_info(SdBp,status) of ' \
                        '{status,waiting}->ok;_->timer:sleep(10),SdB(SdBp,SdBk-1) end end'
    # The library calls into erts that its end interrupts, which keep stock's node-level
    # results (edit 64): an rpc:call made while erts runs, whose process erts
    # created before its agent is killed, since the agent's pid is asked of erts after the
    # call's request went out; then, made while erts no longer answers and its side still
    # stands, a gen:call to the process the watcher watches, an erpc:call, and a
    # spawn_monitor and a spawn_link into erts.
    SERVICE_KILL_RPC = 'SdC1=SdCall(fun()->rpc:call(erts@erxos,timer,sleep,[infinity],infinity) end),SdB1=SdBlocked(SdC1,500)'
    SERVICE_KILL_PENDING = 'SdC2=SdCall(fun()->gen:call(SdPe,\'$gen_call\',x,60000) end),' \
                           'SdC3=SdCall(fun()->erpc:call(erts@erxos,timer,sleep,[infinity],60000) end),' \
                           'SdC4=SdCall(fun()->{SdMp,SdMr}=spawn_monitor(erts@erxos,timer,sleep,[infinity]),' \
                           'receive {\'DOWN\',SdMr,process,SdMp,SdMd}->SdMd after 60000->timeout end end),' \
                           'SdC5=SdCall(fun()->SdLp=spawn_link(erts@erxos,timer,sleep,[infinity]),' \
                           'receive {\'EXIT\',SdLp,SdLx}->SdLx after 60000->timeout end end),' \
                           'SdB2=[SdBlocked(SdCb,500)||SdCb<-[SdC2,SdC3,SdC4,SdC5]]'
    # The burst (D17 of docs/design-runtime.md, the finish): SdBurst runs in erts and, told
    # {sd_go, R, Agent}, which arrives as every message from another domain does, in
    # {erx_origin, D, Msg} (edit 16 of docs/design-runtime.md), sends BURST messages
    # {sd_burst, I} to R in order, then PADDING of sd_pad, which R gets enveloped too, waits
    # until its system side's port counts them all sent into the lane (the counts' first
    # word, erx_lane_drv.h), so the burst is published, and kills Agent, which halts erts;
    # it waits on, so its end is erts's. SdCollect: a system-domain process that traps
    # exits, links to the burst's process P and gathers what arrives until P's 'EXIT'; it
    # answers {sd_collected, R, {Count, InOrder, Exit}}. The domain service ends erts's side
    # only after the finish has delivered every published frame, so the whole burst comes
    # before the exit.
    BURST = 500
    PADDING = 16
    SERVICE_KILL_BURST = "SdBurst=fun()->receive {erx_origin,_,{sd_go,SdTr,SdTa}}->ok end,SdTpt=hd([SdTq||SdTq<-erlang:ports()," \
                         'erlang:port_info(SdTq,name)=:={name,"erx_lane system"}]),' \
                         'SdTsent=fun()-><<SdTn:64,_/binary>>=iolist_to_binary(erlang:port_control(SdTpt,0,[])),SdTn end,' \
                         "SdT0=SdTsent(),[SdTr!{sd_burst,SdTi}||SdTi<-lists:seq(1,#{BURST})],[SdTr!sd_pad||_<-lists:seq(1,#{PADDING})]," \
                         "SdTw=fun SdTwf(0)->ok;SdTwf(SdTk)->case SdTsent()>=SdT0+#{BURST + PADDING} of true->ok;" \
                         'false->timer:sleep(1),SdTwf(SdTk-1) end end,SdTw(5000),exit(SdTa,kill),receive after infinity->ok end end,' \
                         'SdCollect=fun(SdTp)->SdTs=self(),spawn(fun()->process_flag(trap_exit,true),link(SdTp),' \
                         'SdTs!{sd_collecting,self()},SdTl=fun SdTlf(SdTacc)->receive {erx_origin,_,{sd_burst,SdTj}}->SdTlf([SdTj|SdTacc]);' \
                         "{erx_origin,_,sd_pad}->SdTlf(SdTacc);{'EXIT',SdTp,SdTx}->{lists:reverse(SdTacc),SdTx} after 60000->" \
                         '{lists:reverse(SdTacc),timeout} end end,{SdTgot,SdTex}=SdTl([]),SdTs!{sd_collected,self(),' \
                         '{length(SdTgot),SdTgot=:=lists:seq(1,length(SdTgot)),SdTex}} end),' \
                         'receive {sd_collecting,SdTc}->SdTc end end'
    # The control table (docs/design-domains.md, "The control table"): SdHold runs in
    # erts and, told {sd_hold, R, N}, holds its system connection's ring (port_control 4,
    # allowed by DOMAIN_ARGS's -erx test_lane_hold), says {sd_holding, H} to R, waits until
    # its port counts N more control records taken (the counts' eleventh word, ctl_taken,
    # erx_lane_drv.h), lets 500 ms more pass, releases the ring and answers
    # {sd_held, H, Got, Taken, Rewritten}. While it holds, the shell fills erts's lane with
    # 1 KiB sends to a sink until a send would suspend, so the system side's port is paused
    # (its second word grew), calls command 3 on that port itself, which only the domain pid
    # may (badarg), and then introduces erts and peer (erx_domain:introduce/2), so erts's
    # domain pid writes the one record erts is owed, its connection_up, which erts's agent
    # gets as {erx_origin, 4, Msg} while its ring is held, maps and answers; the
    # introduction answers ok once both domains have (SdIntro). The record arrives behind
    # the full, paused lane, and the stray call writes none: Taken is N exactly. Before the
    # hold, a process in each domain asks net_kernel for nodeup (SdUpW).
    RECORDS = 1
    SERVICE_KILL_TABLE = 'SdTid=' + CONFIGURED_ID.to_s + ',' \
                         'SdHold=fun()->receive {erx_origin,_,{sd_hold,SdHr,SdHn}}->ok end,SdHp=hd([SdHq||SdHq<-erlang:ports(),' \
                         'erlang:port_info(SdHq,name)=:={name,"erx_lane system"}]),' \
                         'SdHc=fun()-><<_:80/binary,SdHt:64,SdHw:64>>=iolist_to_binary(erlang:port_control(SdHp,0,[])),{SdHt,SdHw} end,' \
                         '{SdHt0,_}=SdHc(),erlang:port_control(SdHp,4,<<1>>),SdHr!{sd_holding,self()},' \
                         'SdHwt=fun SdHwf(0)->timeout;SdHwf(SdHk)->case SdHc() of {SdHt1,_} when SdHt1>=SdHt0+SdHn->ok;' \
                         '_->timer:sleep(10),SdHwf(SdHk-1) end end,SdHg=SdHwt(3000),timer:sleep(500),{SdHt2,SdHw2}=SdHc(),' \
                         'erlang:port_control(SdHp,4,<<0>>),SdHr!{sd_held,self(),SdHg,SdHt2-SdHt0,SdHw2} end,' \
                         'SdSys=hd([SdSp||SdSp<-erlang:ports(),{name,SdSn}<-[erlang:port_info(SdSp,name)],lists:suffix(" erts@erxos",SdSn)]),' \
                         'SdPaused=fun()-><<_:64,SdPw:64,_/binary>>=iolist_to_binary(erlang:port_control(SdSys,0,[])),SdPw end,' \
                         'SdDom=fun(SdDi)->hd([{erx_domain,SdDi,SdDn,SdDp}||#{id:=SdDj,node:=SdDn,pid:=SdDp}<-erx_domain_core:domains(' \
                         'maps:get(core,sys:get_state(erx_domain_srv))),SdDj=:=SdDi]) end,' \
                         'SdUpW=fun(SdUn)->SdUs=self(),SdUp=spawn(SdUn,fun()->ok=net_kernel:monitor_nodes(true),SdUs!{sd_monitoring,self()},' \
                         'SdUs!{sd_nodeup,self(),receive {nodeup,SdUv}->SdUv after 60000->timeout end} end),' \
                         'receive {erx_origin,_,{sd_monitoring,SdUp}}->SdUp after 10000->timeout end end,' \
                         'SdUe=SdUpW(erts@erxos),SdUq=SdUpW(peer@erxos),' \
                         'SdTag=erpc:call(erts@erxos,erlang,whereis,[erx_connections],10000),' \
                         'SdSink=spawn(erts@erxos,timer,sleep,[infinity]),SdHo=spawn(erts@erxos,SdHold),SdHm=monitor(process,SdHo),' \
                         "SdHo!{sd_hold,self(),#{RECORDS}},SdHolding=receive {erx_origin,_,{sd_holding,SdHo}}->ok;{'DOWN',SdHm,_,_,SdHx0}->{down,SdHx0} " \
                         'after 10000->timeout end,SdP0=SdPaused(),' \
                         'SdFill=fun SdFl(0)->never;SdFl(SdFk)->case erlang:send(SdSink,<<0:8192>>,[nosuspend]) of ' \
                         'nosuspend->full;_->SdFl(SdFk-1) end end,SdFull=SdFill(100000),' \
                         'SdStray=try erlang:port_control(SdSys,3,[<<0:32>>,term_to_binary({22,self(),SdTag}),' \
                         'term_to_binary({erx_connection_down,999,noconnection})]) catch error:badarg->badarg end,' \
                         "SdIn=SdCall(fun()->erx_domain:introduce(SdDom(SdTid),SdDom(#{DOMAINS.fetch('peer')})) end)," \
                         "SdHeld=receive {erx_origin,_,{sd_held,SdHo,SdHg1,SdHt3,SdHw3}}->{SdHg1,SdHt3,SdHw3};{'DOWN',SdHm,_,_,SdHx1}->{down,SdHx1} " \
                         'after 60000->timeout end,SdIntro=receive {sd_called,SdIn,SdIr}->SdIr after 60000->timeout end'
    # The introduced pair (docs/design-domains.md, "Introduction and connection down"):
    # the node each domain's watcher saw come up, each domain's nodes(), and a gen_server
    # call from erts to a process of peer, which peer exported to erts with send, so the
    # call's frame is admitted, and which answers the request it gets from erts in its
    # envelope, {erx_origin, Erts, {'$gen_call', From, ping}}; the reply reaches the caller
    # in erts as gen expects it (edit 58).
    SERVICE_KILL_INTRODUCED = 'SdUps=[receive {erx_origin,_,{sd_nodeup,SdUw,SdUv1}}->SdUv1 after 60000->timeout end||SdUw<-[SdUe,SdUq]],' \
                              'SdNodes=[case SdAsk(SdNd,nodes,[]) of SdNl when is_list(SdNl)->lists:sort(SdNl);SdNx->SdNx end' \
                              '||SdNd<-[erts@erxos,peer@erxos]],SdSs=self(),' \
                              "SdSv=spawn(peer@erxos,fun()->ok=erx_dist:export(self(),[send],#{DOMAINS.fetch('erts')}),SdSs!{sd_serving,self()}," \
                              "receive {erx_origin,SdSd,{'$gen_call',SdSf,SdSq}}->gen:reply(SdSf,{pong,SdSd,SdSq}) after 60000->ok end end)," \
                              'SdServing=receive {erx_origin,_,{sd_serving,SdSv}}->ok after 10000->timeout end,' \
                              'SdPong=try erpc:call(erts@erxos,gen_server,call,[SdSv,ping,10000],15000) catch SdPc:SdPr->{SdPc,SdPr} end'
    # Forged records on the introduced pair (docs/design-domains.md, "Verification and
    # testing"): SdZf runs in peer, exports itself to erts and waits for erts's agent, which
    # a process of erts hands it, so peer holds send on the agent (edit 8 of
    # docs/design-runtime.md); it then sends the agent {erx_connection_down, Peer,
    # noconnection} and erts's domain pid, which its fun carries from the system domain,
    # {erx_connection_lost, Peer, disconnect}, a record and an answer only the system domain
    # and erts may give. Each arrives in peer's envelope, {erx_origin, Peer, Msg}, so the
    # agent and the domain pid drop and count it: SdZpoll waits until erts's agent counts
    # one more dropped (erx_connections:dropped/0), SdZi reads the domain pid's count
    # (erx_domain:info/1).
    #
    # Then answers from erts itself that no connection expects (docs/design-system.md, "What
    # a domain sends the domain service"): a process of erts sends erts's domain pid, in
    # erts's own envelope, so the origin check passes them, three answers about introduced
    # connections erts does not have (with peer 999, an id no domain has, and with the system
    # domain, SYSTEM_CREATION, whose connection to erts is erts's system connection, not an
    # introduced one), connection_mapped and connection_unmapped for the pair, whose side is
    # mapped, so neither is the answer it waits for, and three malformed ones: a peer that is
    # no id, a connection_lost without its reason, and no answer at all. The domain pid drops
    # and counts the malformed three and passes the other five on; the domain service's
    # connection core (erx_domain_links:dropped/1) drops and counts those against erts. SdZx
    # is how much each count grew, {Core, DomainPid}, polled until both reach their number.
    #
    # Last, a gen_server call from erts to a fresh process of peer comes back, and the
    # pair's phase in the domain service's core is still up. An agent or a domain pid
    # without its origin check takes the connection down, and the call fails or the phase
    # is closing; a domain pid that passes malformed answers on moves their count to the
    # core, a core that does not count an answer for a connection that does not exist
    # counts fewer, and one that acts on an answer its side does not wait for closes the
    # pair or ends the service.
    SERVICE_KILL_HOSTILE = "SdZpeer=#{DOMAINS.fetch('peer')},SdZs=self(),SdZdp=element(4,SdDom(SdTid))," \
                           'SdZask=fun()->try erpc:call(erts@erxos,erx_connections,dropped,[],10000) catch _:_->error end end,' \
                           'SdZi=fun()->case erx_domain:info(SdDom(SdTid)) of {ok,#{dropped:=SdZn}}->SdZn;SdZe->SdZe end end,' \
                           'SdZa0=SdZask(),SdZd0=SdZi(),' \
                           'SdZf=spawn(peer@erxos,fun()->ok=erx_dist:export(self(),[send],SdTid),SdZs!{sd_zready,self()},' \
                           'receive {erx_origin,_,{sd_zagent,SdZag}}->ok end,SdZag!{erx_connection_down,SdZpeer,noconnection},' \
                           'SdZdp!{erx_connection_lost,SdZpeer,disconnect},SdZs!{sd_zsent,self()} end),' \
                           'SdZr=receive {erx_origin,_,{sd_zready,SdZf}}->ok after 10000->timeout end,' \
                           'spawn(erts@erxos,fun()->SdZf!{sd_zagent,whereis(erx_connections)} end),' \
                           'SdZw=receive {erx_origin,_,{sd_zsent,SdZf}}->ok after 10000->timeout end,' \
                           'SdZpoll=fun SdZpf(0)->timeout;SdZpf(SdZk)->case SdZask() of SdZn when is_integer(SdZn),SdZn>SdZa0->' \
                           'SdZn-SdZa0;_->timer:sleep(100),SdZpf(SdZk-1) end end,SdZad=SdZpoll(50),' \
                           'SdZdd=case SdZi() of SdZd1 when is_integer(SdZd1)->SdZd1-SdZd0;SdZd1->SdZd1 end,' \
                           'SdZl=fun()->maps:get(SdTid,erx_domain_links:dropped(maps:get(links,sys:get_state(erx_domain_srv)))) end,' \
                           'SdZn0={SdZl(),SdZi()},spawn(erts@erxos,fun()->[SdZdp!SdZm||SdZm<-[{erx_connection_mapped,999},' \
                           "{erx_connection_unmapped,#{SYSTEM_CREATION}},{erx_connection_lost,999,disconnect}," \
                           '{erx_connection_mapped,SdZpeer},{erx_connection_unmapped,SdZpeer},' \
                           '{erx_connection_mapped,x},{erx_connection_lost,SdZpeer},junk]] end),' \
                           'SdZnd=fun()->{SdZl()-element(1,SdZn0),SdZi()-element(2,SdZn0)} end,' \
                           'SdZx=(fun SdZxf(0)->SdZnd();SdZxf(SdZk)->case SdZnd() of {SdZx1,SdZx2} when SdZx1>=5,SdZx2>=3->SdZnd();' \
                           '_->timer:sleep(100),SdZxf(SdZk-1) end end)(50),' \
                           'SdZv=spawn(peer@erxos,fun()->ok=erx_dist:export(self(),[send],SdTid),SdZs!{sd_zserving,self()},' \
                           "receive {erx_origin,SdZo,{'$gen_call',SdZc,SdZq}}->gen:reply(SdZc,{pong,SdZo,SdZq}) after 60000->ok end end)," \
                           'SdZvs=receive {erx_origin,_,{sd_zserving,SdZv}}->ok after 10000->timeout end,' \
                           'SdZpong=try erpc:call(erts@erxos,gen_server,call,[SdZv,ping,10000],15000) catch SdZpc:SdZpr->{SdZpc,SdZpr} end,' \
                           'SdZph=erx_domain_links:phase(SdTid,SdZpeer,maps:get(links,sys:get_state(erx_domain_srv)))'
    # Each forgery dropped and counted once, erts's stray answers counted five by the core
    # and three by the domain pid, the call answered from erts, the pair up.
    HOSTILE_ANSWER = "{hostile,ok,ok,1,1,{5,3},ok,{pong,#{DOMAINS.fetch('erts')},ping},up}"
    HOSTILE_START = /\A\{hostile,/n
    # The connection's down path (docs/design-domains.md, "Introduction and connection
    # down"), from one side each time, on the introduced pair. SdPhase is the pair's phase
    # in the domain service's core, and SdNone polls it every 100 ms at most K times until
    # it is none: the objects deleted and the connection forgotten once both parties
    # unmapped. Each case ends with the pair introduced again, which answers ok only once
    # each domain's side is done and no longer counts against its one connection.
    # erlang:disconnect_node/1 in erts, behind a burst the finish must deliver: SdKc runs in
    # peer, exports itself to erts with send and link, holds its port's ring for erts
    # (port_control 4, allowed by DOMAIN_ARGS's -erx test_lane_hold) and gathers what
    # arrives until an 'EXIT', answering {sd_kdone, C, {Count, InOrder, Exit}}; SdKb runs in
    # erts, links to the collector, sends it DOWN_BURST messages {sd_kb, I}, waits until its
    # port counts them sent into the lane, so they are published, and disconnects peer,
    # answering {sd_kbdone, B, Sent, Exit}. erts's port ends, its agent answers
    # connection_lost, the service tells peer connection_down, and peer's agent has the port
    # finish, which releases the hold and takes the link and the whole burst before the port
    # ends with noconnection. Then a malformed frame from erts: SdMw runs in peer, exports
    # itself to erts and answers its 'EXIT'; SdMf runs in erts, links to it, waits until its
    # port counts the link sent, so peer takes it first, and writes a frame whose control
    # term is no operation onto its port, which peer's funnel refuses as malformed; it
    # answers what port_command returned and its own 'EXIT'. Before both, SdSt runs in peer,
    # exports itself to erts with send and answers each {sd_sp, From} with sd_spong; SdPing
    # pings it from a fresh process of erts. After the second reintroduction SdSt's holder
    # of the first connection holds nothing (docs/design-runtime.md, "Connections in ERTS"):
    # erx_dist:exports/1 lists none for erts and the ping is unheld, so it reaches no one;
    # an export on the new connection lets it through.
    DOWN_BURST = 20
    SERVICE_KILL_DOWN = "SdPid2=#{DOMAINS.fetch('peer')}," \
                        'SdPhase=fun()->erx_domain_links:phase(SdTid,SdPid2,maps:get(links,sys:get_state(erx_domain_srv))) end,' \
                        'SdNone=fun SdNf(0)->SdPhase();SdNf(SdNk)->case SdPhase() of none->none;_->timer:sleep(100),SdNf(SdNk-1) end end,' \
                        'SdIntroAgain=fun()->erx_domain:introduce(SdDom(SdTid),SdDom(SdPid2)) end,' \
                        'SdLanePort=fun(SdLs)->hd([SdLp||SdLp<-erlang:ports(),{name,SdLn}<-[erlang:port_info(SdLp,name)],' \
                        'lists:suffix(SdLs,SdLn)]) end,' \
                        'SdSentOf=fun(SdSp)-><<SdSw:64,_/binary>>=iolist_to_binary(erlang:port_control(SdSp,0,[])),SdSw end,' \
                        'SdSentBy=fun SdSbf(_,_,0)->timeout;SdSbf(SdSp,SdSn,SdSk)->case SdSentOf(SdSp)>=SdSn of true->ok;' \
                        'false->timer:sleep(1),SdSbf(SdSp,SdSn,SdSk-1) end end,SdDs=self(),' \
                        "SdSt=spawn(peer@erxos,fun()->ok=erx_dist:export(self(),[send],SdTid),SdDs!{sd_stserving,self()}," \
                        "(fun SdStf()->receive {erx_origin,_,{sd_sp,SdSpf}}->SdSpf!sd_spong,SdStf() end end)() end)," \
                        'SdStr=receive {erx_origin,_,{sd_stserving,SdSt}}->ok after 10000->timeout end,' \
                        "SdPing=fun()->SdPg=spawn(erts@erxos,fun()->SdSt!{sd_sp,self()}," \
                        "SdDs!{sd_pinged,self(),receive {erx_origin,_,sd_spong}->pong after 3000->timeout end} end)," \
                        'receive {erx_origin,_,{sd_pinged,SdPg,SdPv}}->SdPv after 10000->none end end,SdPing0=SdPing(),' \
                        "SdKc=fun()->process_flag(trap_exit,true),ok=erx_dist:export(self(),[send,link],SdTid)," \
                        "erlang:port_control(SdLanePort(\" erts@erxos\"),4,<<1>>),SdDs!{sd_kholding,self()}," \
                        "SdKl=fun SdKlf(SdKa)->receive {erx_origin,_,{sd_kb,SdKi}}->SdKlf([SdKi|SdKa]);{'EXIT',_,SdKx}->{lists:reverse(SdKa),SdKx} " \
                        'after 60000->{lists:reverse(SdKa),timeout} end end,{SdKg,SdKe}=SdKl([]),' \
                        'SdDs!{sd_kdone,self(),{length(SdKg),SdKg=:=lists:seq(1,length(SdKg)),SdKe}} end,' \
                        'SdKcp=spawn(peer@erxos,SdKc),SdKh=receive {erx_origin,_,{sd_kholding,SdKcp}}->ok after 10000->timeout end,' \
                        "SdKb=fun()->process_flag(trap_exit,true),link(SdKcp),SdKq=SdLanePort(\" peer@erxos\"),SdK0=SdSentOf(SdKq)," \
                        "[SdKcp!{sd_kb,SdKi}||SdKi<-lists:seq(1,#{DOWN_BURST})],SdKs=SdSentBy(SdKq,SdK0+#{DOWN_BURST},5000)," \
                        "true=erlang:disconnect_node(peer@erxos),SdKx=receive {'EXIT',SdKcp,SdKx0}->SdKx0 after 60000->timeout end," \
                        'SdDs!{sd_kbdone,self(),SdKs,SdKx} end,SdKbp=spawn(erts@erxos,SdKb),' \
                        'SdKbv=receive {erx_origin,_,{sd_kbdone,SdKbp,SdKbs,SdKbx}}->{SdKbs,SdKbx} after 60000->timeout end,' \
                        'SdKcv=receive {erx_origin,_,{sd_kdone,SdKcp,SdKcv0}}->SdKcv0 after 60000->timeout end,' \
                        'SdN1=SdNone(600),SdR1=SdIntroAgain(),' \
                        "SdMw=fun()->process_flag(trap_exit,true),ok=erx_dist:export(self(),[send,link],SdTid),SdDs!{sd_mwatching,self()}," \
                        "SdDs!{sd_mwx,self(),receive {'EXIT',_,SdMx0}->SdMx0 after 60000->timeout end} end," \
                        'SdMwp=spawn(peer@erxos,SdMw),SdMh=receive {erx_origin,_,{sd_mwatching,SdMwp}}->ok after 10000->timeout end,' \
                        "SdMf=fun()->process_flag(trap_exit,true),SdMq=SdLanePort(\" peer@erxos\"),SdM0=SdSentOf(SdMq),link(SdMwp)," \
                        'SdMs=SdSentBy(SdMq,SdM0+1,5000),' \
                        'SdMc=try erlang:port_command(SdMq,<<$p,(term_to_binary({99}))/binary>>) catch SdMcc:SdMcr->{SdMcc,SdMcr} end,' \
                        "SdDs!{sd_mfdone,self(),SdMs,SdMc,receive {'EXIT',SdMwp,SdMx1}->SdMx1 after 60000->timeout end} end," \
                        'SdMfp=spawn(erts@erxos,SdMf),' \
                        'SdMfv=receive {erx_origin,_,{sd_mfdone,SdMfp,SdMfs,SdMfc,SdMfx}}->{SdMfs,SdMfc,SdMfx} after 60000->timeout end,' \
                        'SdMwv=receive {erx_origin,_,{sd_mwx,SdMwp,SdMwx}}->SdMwx after 60000->timeout end,' \
                        'SdN2=SdNone(600),SdR2=SdIntroAgain(),' \
                        'SdStale={SdStr,SdPing0,lists:keymember(SdTid,1,erpc:call(peer@erxos,erx_dist,exports,[SdSt],10000)),SdPing(),' \
                        'erpc:call(peer@erxos,erx_dist,export,[SdSt,[send],SdTid],10000),SdPing()}'
    # Each case: erts's process told noconnection by its link, peer's by its link behind
    # the whole burst, the objects deleted and the pair introduced again.
    CONNECTION_DOWN_ANSWER = "{connection_down,ok,{ok,noconnection},{#{DOWN_BURST},true,noconnection},none,ok," \
                             'ok,{ok,true,noconnection},noconnection,none,ok,{ok,pong,false,timeout,ok,pong}}'
    CONNECTION_DOWN_START = /\A\{connection_down,/n
    # A survivor that ignores connection_down (docs/design-domains.md, "Verification and
    # testing", the hostile domain): SdYs runs in erts and suspends erts's agent, which
    # therefore never reads the record, until the shell tells it to resume the agent, or two minutes
    # pass, so a shell that fails on the way does not leave the agent suspended. peer ends
    # the connection (erlang:disconnect_node/1), its agent answers connection_lost, and the
    # service tells erts connection_down. SdYv is read once the pair is closing (SdYclosing
    # polls SdPhase) and a second more has passed: {Phase, Held(erts), Held(peer),
    # Room(erts), Room(peer), Introduce, ErtsNode}, from the service's core (held/2 and
    # room/2) and the API. The pair stays closing, the connection is counted against erts's
    # one connection and not peer's, so erts has no room for another and peer has, the
    # pair's introduction is refused as closing, and erts still answers over its system
    # connection. Once the agent runs again it answers, the connection's objects go
    # (SdNone) and the pair is introduced again, as SERVICE_KILL_ENDS expects it.
    SERVICE_KILL_IGNORED = "SdYs=spawn(erts@erxos,fun()->SdYa=whereis(erx_connections),true=erlang:suspend_process(SdYa)," \
                           'SdDs!{sd_isus,self()},receive {erx_origin,_,sd_ires}->ok after 120000->ok end,' \
                           'true=erlang:resume_process(SdYa),' \
                           'SdDs!{sd_ires,self()} end),SdYh=receive {erx_origin,_,{sd_isus,SdYs}}->ok after 10000->timeout end,' \
                           'SdYc=SdAsk(peer@erxos,disconnect_node,[erts@erxos]),' \
                           'SdYclosing=fun SdYf(0)->SdPhase();SdYf(SdYk)->case SdPhase() of closing->closing;' \
                           '_->timer:sleep(100),SdYf(SdYk-1) end end,SdYp=SdYclosing(100),timer:sleep(1000),' \
                           'SdYl=maps:get(links,sys:get_state(erx_domain_srv)),' \
                           'SdYv={SdPhase(),erx_domain_links:held(SdTid,SdYl),erx_domain_links:held(SdPid2,SdYl),' \
                           'erx_domain_links:room(SdTid,SdYl),erx_domain_links:room(SdPid2,SdYl),' \
                           'SdIntroAgain(),SdAsk(erts@erxos,node,[])},' \
                           'SdYs!sd_ires,SdYr=receive {erx_origin,_,{sd_ires,SdYs}}->ok after 10000->timeout end,' \
                           'SdYn=SdNone(600),SdYi=SdIntroAgain()'
    # The printed tuple: SdYs suspended the agent (ok), peer's disconnect_node/1 answered
    # true, the pair went closing, SdYv as above, the agent resumed (ok), the pair's
    # objects went (none) and it was introduced again (ok).
    IGNORED_DOWN_ANSWER = '{ignored_down,ok,true,closing,{closing,1,0,false,true,{error,closing},erts@erxos},ok,none,ok}'
    IGNORED_DOWN_START = /\A\{ignored_down,/n
    # The ends of both domains, with a later domain of peer's name between them, in three
    # parts: SERVICE_KILL_ENDS ends peer, SERVICE_KILL_LATER makes and checks the later
    # peer, SERVICE_KILL_HALT halts erts; SdE1, SdL1 and SdV1 of the first are printed with
    # the last's answers, and SdNh of the first with the second's.
    #
    # SERVICE_KILL_ENDS: a watcher of a process of peer, then peer's system side's port,
    # found by its open command, whose last word is the domain's node
    # (erx_connections:open/3), ended with {domain_down, D2, x}, D2 erts's id and not
    # peer's: the watcher's link and monitor fire noconnection (edit 56 of
    # docs/design-runtime.md), and peer stops, its system side lost (docs/design-system.md,
    # "A lost system connection ends the domain"). SdE1 is the deaths after it, SdL1 the
    # domains still alive once the ended peer is retired, erts having answered its
    # connection_down, and SdV1 what the watcher saw. Before peer ends, SdNw runs in erts,
    # the survivor: it watches nodes (net_kernel's monitor_nodes/1) and takes the first two
    # events about peer@erxos; told sd_nwgo, once the later peer is introduced, it sends
    # SdPp, the process of the ended peer, a message, monitors it (SdNod, the DOWN's reason),
    # links to it (SdNlk, what link/1 raised) and links to it again trapping exits (SdNex,
    # the exit's reason). Then it links, unlinks and links again at once, which replaces the
    # link being unlinked unless its exit came between (SdNrx, the first exit's reason), and
    # demonitors a new monitor (SdNdm); neither unlink/1 nor demonitor/2 may send a frame.
    # Last it waits three seconds for a nodedown.
    SERVICE_KILL_ENDS = 'SdPp=spawn(peer@erxos,timer,sleep,[infinity]),SdW1=SdWatch(SdPp),SdW1!sd_go,' \
                        'SdNw=spawn(erts@erxos,fun()->ok=net_kernel:monitor_nodes(true),SdDs!{sd_nwatching,self()},' \
                        'SdNe=[receive {SdNk,peer@erxos}->SdNk after 180000->timeout end||_<-[1,2]],' \
                        'receive {erx_origin,_,sd_nwgo}->ok after 60000->ok end,SdPp!sd_stale,' \
                        "SdNo=monitor(process,SdPp),SdNod=receive {'DOWN',SdNo,_,_,SdNor}->SdNor after 3000->timeout end," \
                        'SdNlk=try link(SdPp) catch error:SdNle->SdNle end,process_flag(trap_exit,true),link(SdPp),' \
                        "SdNex=receive {'EXIT',SdPp,SdNer}->SdNer after 3000->timeout end," \
                        "link(SdPp),unlink(SdPp),link(SdPp),SdNrx=receive {'EXIT',SdPp,SdNry}->SdNry after 3000->timeout end," \
                        "receive {'EXIT',SdPp,_}->ok after 500->ok end,SdNdm=demonitor(monitor(process,SdPp),[flush])," \
                        'SdNu=receive {nodedown,peer@erxos}->down after 3000->up end,' \
                        'SdDs!{sd_nw,self(),{SdNe,{SdNod,SdNlk,SdNex,SdNrx,SdNdm},SdNu}} end),' \
                        'SdNh=receive {erx_origin,_,{sd_nwatching,SdNw}}->ok after 10000->timeout end,' \
                        'SdPort=hd([SdPt||SdPt<-erlang:ports(),{name,SdNm}<-[erlang:port_info(SdPt,name)],' \
                        'lists:suffix(" peer@erxos",SdNm)]),' \
                        "exit(SdPort,{domain_down,#{DOMAINS.fetch('erts')},x}),SdE1=SdUntil(1,600)," \
                        'SdLeft=fun SdLf(0)->SdLives();SdLf(SdLk)->case SdLives() of [_]=SdLl->SdLl;_->timer:sleep(100),SdLf(SdLk-1) end end,' \
                        'SdL1=SdLeft(600),' \
                        'SdV1=receive {sd_watched,SdW1,SdV1w}->SdV1w after 60000->timeout end'
    # SERVICE_KILL_LATER, a later domain of the ended name (docs/design-domains.md, "Domain
    # identity"): the shell creates peer again from SdSpec, which service_kill_checkpoints
    # binds (later_spec), and introduces it to erts. It has the next id, its node's
    # creation, and erts saw nodedown and then nodeup for peer@erxos. SdNw's message to the
    # ended peer's process is dropped: a frame to a pid of another creation of the connected
    # node is one to a process that does not exist (the funnel's target rule,
    # liberx/erx_funnel.c). Its monitor and links are answered by erts itself, as stock
    # ERTS answers a pid of an earlier run of its own node: DOWN with noproc, link/1 raising
    # noproc, and an exit of noproc once SdNw traps exits, a replaced link's too; no frame
    # goes, since the later peer's answer would name the dead pid, which erts's funnel
    # refuses by the sender rule (edit 66 of docs/design-runtime.md), and the unlink and the
    # demonitor send none either. No nodedown follows. Then the same for a pid the later
    # peer's lookup would find: SdLq runs in the later peer, exports itself to erts and
    # reports to the shell the first message it gets; SdLqo is SdLq's pid with the ended peer's id for its
    # creation (the last word of its NEW_PID_EXT encoding), and a process of erts sends
    # sd_old to SdLqo and then sd_new to SdLq, so SdLq gets sd_new first: the export table's
    # lookup goes by number and serial alone, but the funnel finds SdLqo dead before it
    # asks, and ERTS behind it takes a pid of its own node name with another creation for
    # one of an earlier run, as stock ERTS does, so neither hands sd_old on; the probe
    # checks both together, and erx_funnel_check_test the funnel's rule alone. Since both
    # messages come from one process over one lane, a frame that ended the connection leaves
    # SdLq without sd_new, whatever the three seconds of SdNw saw.
    SERVICE_KILL_LATER = 'SdLc=erx_domain:create(SdSpec),SdLi=case SdLc of {ok,SdLd}->' \
                         '{erx_domain:id(SdLd),erx_domain:introduce(SdDom(SdTid),SdLd)};SdLe->SdLe end,SdNw!sd_nwgo,' \
                         'SdLv=receive {erx_origin,_,{sd_nw,SdNw,SdLv0}}->SdLv0 after 60000->timeout end,' \
                         'SdLq=spawn(peer@erxos,fun()->ok=erx_dist:export(self(),[send],SdTid),SdDs!{sd_lqready,self()},' \
                         'SdDs!{sd_lq,self(),receive {erx_origin,_,SdLqm}->SdLqm after 10000->timeout end} end),' \
                         'SdLqr=receive {erx_origin,_,{sd_lqready,SdLq}}->ok after 10000->timeout end,' \
                         'SdLqb=term_to_binary(SdLq),' \
                         'SdLqo=binary_to_term(<<(binary:part(SdLqb,0,byte_size(SdLqb)-4))/binary,SdPid2:32>>),' \
                         'spawn(erts@erxos,fun()->SdLqo!sd_old,SdLq!sd_new end),' \
                         'SdLqv=receive {erx_origin,_,{sd_lq,SdLq,SdLqv0}}->SdLqv0 after 20000->timeout end,' \
                         'SdLn=SdAsk(peer@erxos,system_info,[creation])'
    # The domain service never reuses an id: the four configured domains took the first
    # four, and the later peer is the first domain created after them.
    LATER_ID = STORAGE_ID + 1
    LATER_DOMAIN_ANSWER = "{later_domain,ok,{#{LATER_ID},ok},{[nodedown,nodeup],{noproc,noproc,noproc,noproc,true},up},ok,sd_new,#{LATER_ID}}"
    LATER_DOMAIN_START = /\A\{later_domain,/n
    # SERVICE_KILL_HALT: a watcher of a process of erts, and erts made to kill its own
    # agent, its pid asked of erts first, since the system domain may only send to it, by
    # SdBurst behind its burst, with the domain service suspended until erts no longer
    # answers and the watcher's spawn_request into it is made, so the request is pending as
    # the side ends, as are the library calls of SERVICE_KILL_PENDING; SERVICE_KILL_RPC's
    # call runs in erts as it halts. erts halts with status 69, and the link, the monitor
    # and the spawn all fire {domain_down, Erts, {halt, 69}}, the reason the service ends
    # the side's port with. SdE2 is the deaths after it, SdV2 what the watcher saw, SdG2 SdGone's
    # verdict on erts, SdB1 and SdB2 whether each library call was blocked in its request
    # before erts's side ended, SdV3 what the library calls returned, SdV4 what the burst's
    # collector gathered. The later peer is still running when the service is killed.
    SERVICE_KILL_HALT = "SdPe=spawn(erts@erxos,timer,sleep,[infinity]),SdW2=SdWatch(SdPe),#{SERVICE_KILL_RPC}," \
                        'SdAgent=erpc:call(erts@erxos,erlang,whereis,[erx_connections],10000),' \
                        'sys:suspend(erx_domain_srv),SdTp=spawn(erts@erxos,SdBurst),SdTr=SdCollect(SdTp),SdTp!{sd_go,SdTr,SdAgent},' \
                        'SdG2=SdGone(erts@erxos,100),SdW2!{sd_spawn,erts@erxos},' \
                        "receive {sd_spawned,SdW2}->ok after 10000->timeout end,#{SERVICE_KILL_PENDING}," \
                        'sys:resume(erx_domain_srv),' \
                        'SdE2=SdUntil(2,600),SdV2=receive {sd_watched,SdW2,SdV2w}->SdV2w after 60000->timeout end,' \
                        'SdV3=[receive {sd_called,SdCk,SdCv}->SdCv after 60000->timeout end||SdCk<-[SdC1,SdC2,SdC3,SdC4,SdC5]],' \
                        'SdV4=receive {sd_collected,SdTr,SdTv}->SdTv after 60000->timeout end'
    # Prints each step's answer, ends the two configured domains, prints how they ended,
    # then kills the service. The line starts with a binding, so the shell's echo of it
    # starts neither {service_kill nor {domain_ends, and only the printed answers match.
    SERVICE_KILL_EXPRESSION = "#{SERVICE_KILL_LIVES},#{SERVICE_KILL_WAIT},#{SERVICE_KILL_ASK},#{SERVICE_KILL_DEATHS}," \
                              "#{SERVICE_KILL_FORGED},#{SERVICE_KILL_WATCH},#{SERVICE_KILL_CALL},#{SERVICE_KILL_BURST}," \
                              'SdL=SdWait(600),' \
                              "io:format(\"~0p~n\",[{service_kill,SdL,#{SERVICE_KILL_SYSTEM},SdPeers(SdL),SdForged(#{DOMAINS.fetch('erts')},erts@erxos)}])," \
                              "#{SERVICE_KILL_TABLE},io:format(\"~0p~n\",[{control_table,SdHolding,SdFull,SdPaused()>SdP0,SdStray,SdIntro,SdHeld}])," \
                              "#{SERVICE_KILL_INTRODUCED},io:format(\"~0p~n\",[{introduced,SdUps,SdNodes,SdServing,SdPong}])," \
                              "#{SERVICE_KILL_HOSTILE},io:format(\"~0p~n\",[{hostile,SdZr,SdZw,SdZad,SdZdd,SdZx,SdZvs,SdZpong,SdZph}])," \
                              "#{SERVICE_KILL_DOWN},io:format(\"~0p~n\",[{connection_down,SdKh,SdKbv,SdKcv,SdN1,SdR1,SdMh,SdMfv,SdMwv,SdN2,SdR2,SdStale}])," \
                              "#{SERVICE_KILL_IGNORED},io:format(\"~0p~n\",[{ignored_down,SdYh,SdYc,SdYp,SdYv,SdYr,SdYn,SdYi}])," \
                              "#{SERVICE_KILL_ENDS},#{SERVICE_KILL_LATER},io:format(\"~0p~n\",[{later_domain,SdNh,SdLi,SdLv,SdLqr,SdLqv,SdLn}])," \
                              "#{SERVICE_KILL_HALT},io:format(\"~0p~n\",[{domain_ends,SdE1,SdL1,SdV1,SdG2,SdE2,SdV2,SdB1,SdB2,SdV3,SdV4}])," \
                              'exit(whereis(erx_domain_srv),kill).'
    SERVICE_KILL_ANSWER = begin
      lives = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,ready}" }.join(',')
      nodes = [*DOMAINS.keys.map { |name| "#{name}@erxos" }, *MANIFEST_NODES].sort.join(',')
      peers = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,#{id}}" }.join(',')
      "{service_kill,[#{lives}],#{SYSTEM_NODE},#{SYSTEM_CREATION},[#{nodes}],[#{peers}],{2,erts@erxos}}".freeze
    end
    SERVICE_KILL_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{service_kill,/n
    # Typed ahead of the service kill: SdEcho waits up to 60 s for the system domain's
    # echo grant to be installed and answers its facet; the line then calls it with an
    # echo and with a request erx_echo_test refuses, and reads the domain service's counts.
    ECHO_EXPRESSION = 'SdEcho=fun SdE(0)->none;SdE(SdK)->case maps:get({system,echo},' \
                      'maps:get(grants,gen_server:call(erx_domain_srv,mints)),none) of ' \
                      '{installed,_,SdEf}->SdEf;_->timer:sleep(100),SdE(SdK-1) end end,SdEf=SdEcho(600),' \
                      'io:format("~0p~n",[{echo_facet,SdEf=:=erx:cap(echo),catch gen_server:call(SdEf,{echo,hi},5000),' \
                      'catch gen_server:call(SdEf,other,5000),maps:get(counts,gen_server:call(erx_domain_srv,mints))}])'
    # erts's facet installed in the system domain, which erx:cap/1 finds, answers the echo
    # and refuses the other request; erts's report had relay refused as a mint it does not
    # own and stray as undeclared, and nothing else was refused or dropped.
    ECHO_ANSWER = '{echo_facet,true,{echo,hi},{error,badarg},' \
                  '#{{refused,foreign_mint} => 1,{refused,undeclared} => 1}}'
    ECHO_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{echo_facet,/n
    # peer stopped by its side's end while erts runs, its watcher told noconnection twice;
    # then erts halted with status 69, its watcher told {domain_down, Erts, {halt, 69}} by
    # the link, the monitor and the spawn's error reply, and the library calls given
    # stock's results for a node gone down, and the whole burst before erts's exit.
    DOMAIN_ENDS_ANSWER = begin
      erts = DOMAINS.fetch('erts')
      peer = DOMAINS.fetch('peer')
      down = "{domain_down,#{erts},{halt,69}}"
      "{domain_ends,[{#{peer},stopped}],[{#{erts},erts@erxos,ready}],[noconnection,noconnection],gone," \
        "[{#{erts},{halt,69}},{#{peer},stopped}],[#{down},#{down},{error,#{down}}]," \
        'ok,[ok,ok,ok,ok],[{badrpc,nodedown},{exit,{nodedown,erts@erxos}},{error,{erpc,noconnection}},noconnection,noconnection],' \
        "{#{BURST},true,#{down}}}".freeze
    end
    DOMAIN_ENDS_START = /\A\{domain_ends,/n
    # The lane filled and the side paused, the stray call refused, the introduction up, and
    # erts's port took its record and nothing more, none rewritten.
    CONTROL_TABLE_ANSWER = "{control_table,ok,full,true,badarg,ok,{ok,#{RECORDS},0}}"
    CONTROL_TABLE_START = /\A\{control_table,/n
    # erts saw peer come up and peer erts, each lists the other and the system domain, and
    # the call from erts reached peer's process from erts's id and came back.
    INTRODUCED_ANSWER = '{introduced,[peer@erxos,erts@erxos],[[peer@erxos,system@erxos],[erts@erxos,system@erxos]],ok,' \
                        "{pong,#{DOMAINS.fetch('erts')},ping}}"
    INTRODUCED_START = /\A\{introduced,/n
    # init's slogan as it halts the runtime once the permanent application erx_domain has
    # ended, shut down by its supervisor; it may follow an unended prompt. The application
    # controller's reason is a string, which init prints with its quotes:
    # ("{application_terminated,erx_domain,shutdown}").
    SLOGAN_PATTERN = /Kernel pid terminated \(application_controller\)/n
    SLOGAN = /Kernel pid terminated \(application_controller\) \("\{application_terminated,erx_domain,shutdown\}"\)\r*\n\z/n

    module_function

    # The manifest: MediumBoot's, room for two domains, with ECHO_ROW, PEER_ROW and ECHO_SERVICES for its rows.
    def manifest(source) = MediumBoot.manifest(source, row: ECHO_ROW + PEER_ROW + ECHO_SERVICES)

    # The request erx_domain:create/1 takes for SERVICE_KILL_LATER's later domain of peer:
    # the configured rows' runtime image and release, at domain's indexes in the image's
    # archive (MediumBoot.domain_in), and their boot script, budgets, lane and arguments,
    # MediumBoot's grant for the domains its shell creates, and one connection, so it can
    # be introduced. Its runtime limits are the system principal's defaults, the same profile as the rows'.
    def later_spec(domain)
      MediumBoot.erlang_map(name: '<<"peer">>', runtime: domain.runtime, release: domain.release,
                            release_files: domain.release_files, boot: "<<\"#{MediumBoot::DOMAIN_BOOT.name}\">>",
                            memory: MediumBoot::DOMAIN_MEMORY,
                            outer: MediumBoot::DOMAIN_OUTER,
                            grant: MediumBoot.erlang_map(quota_ns: (1 << 64) - 1, cpuset: 1, capacity_mcpu: 1000),
                            lane: 4096, args: MediumBoot.binary_args(DOMAIN_ARGS), env: '<<>>', connections: 1)
    end

    # The line typed at the Erlang shell: SdSpec bound to later_spec(domain), then
    # SERVICE_KILL_EXPRESSION.
    def service_kill_line(domain) = "SdSpec=#{later_spec(domain)},#{ECHO_EXPRESSION},#{SERVICE_KILL_EXPRESSION}"

    # The production checkpoints to the command shell, then the Erlang shell, the kill and
    # the runtime's end. points must end at the command shell; domain is where the image's
    # archive carries the configured rows' runtime and release.
    def service_kill_checkpoints(points, domain:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      echo = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(ECHO_ANSWER)}\r*\n\z/n
      answer = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(SERVICE_KILL_ANSWER)}\r*\n\z/n
      ends = /\A#{Regexp.escape(DOMAIN_ENDS_ANSWER)}\r*\n\z/n
      table = /\A#{Regexp.escape(CONTROL_TABLE_ANSWER)}\r*\n\z/n
      introduced = /\A#{Regexp.escape(INTRODUCED_ANSWER)}\r*\n\z/n
      hostile = /\A#{Regexp.escape(HOSTILE_ANSWER)}\r*\n\z/n
      down = /\A#{Regexp.escape(CONNECTION_DOWN_ANSWER)}\r*\n\z/n
      ignored = /\A#{Regexp.escape(IGNORED_DOWN_ANSWER)}\r*\n\z/n
      later = /\A#{Regexp.escape(LATER_DOMAIN_ANSWER)}\r*\n\z/n
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: "#{service_kill_line(domain)}\r").freeze,
       { name: 'echo-facet', pattern: ECHO_START, seconds: 180,
         verify: ->(text) { raise Error, "the echo facet gave #{text.inspect}" unless echo.match?(text) } }.freeze,
       { name: 'domain-running', pattern: SERVICE_KILL_START, seconds: 180,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} before the kill" unless answer.match?(text) } }.freeze,
       { name: 'control-table', pattern: CONTROL_TABLE_START, seconds: 180,
         verify: ->(text) { raise Error, "the control table answered #{text.inspect}" unless table.match?(text) } }.freeze,
       { name: 'introduced', pattern: INTRODUCED_START, seconds: 180,
         verify: ->(text) { raise Error, "the introduced pair answered #{text.inspect}" unless introduced.match?(text) } }.freeze,
       { name: 'hostile', pattern: HOSTILE_START, seconds: 180,
         verify: ->(text) { raise Error, "the forged records gave #{text.inspect}" unless hostile.match?(text) } }.freeze,
       { name: 'connection-down', pattern: CONNECTION_DOWN_START, seconds: 180,
         verify: ->(text) { raise Error, "the connection went down as #{text.inspect}" unless down.match?(text) } }.freeze,
       { name: 'ignored-down', pattern: IGNORED_DOWN_START, seconds: 180,
         verify: ->(text) { raise Error, "the ignored connection_down gave #{text.inspect}" unless ignored.match?(text) } }.freeze,
       { name: 'later-domain', pattern: LATER_DOMAIN_START, seconds: 600,
         verify: ->(text) { raise Error, "the later domain of peer gave #{text.inspect}" unless later.match?(text) } }.freeze,
       { name: 'domain-ends', pattern: DOMAIN_ENDS_START, seconds: 180,
         verify: ->(text) { raise Error, "the domains ended as #{text.inspect}" unless ends.match?(text) } }.freeze,
       { name: 'system-domain-ended', pattern: SLOGAN_PATTERN, seconds: 60,
         verify: ->(text) { raise Error, "the runtime ended with #{text.inspect}" unless SLOGAN.match?(text) } }.freeze].freeze
    end

    # Boots the image under HVF at each CPU count, where placement puts each cell.
    # Returns { "<accel>-<n>cpu" => 'passed' }; any disagreement raises.
    class Run
      def self.cells(cpus) = cpus.map { |count| QemuCells::Cell.new(accel: QemuCells::LOCAL_ACCELERATOR, cpus: count).name }

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        source = platform.site_manifest_source(@root)
        @manifest = SystemDomain.manifest(source)
        @regrant_manifest = Regrant.manifest(source)
      end

      # Packs the two test images once, on a medium machine (MediumBoot.machine), then boots each at each CPU count:
      # the service-kill boot, then the re-grant boot (Regrant).
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        service_kill_image = image(fiasco, 'image', @manifest)
        regrant_image = image(fiasco, 'regrant-image', @regrant_manifest)
        domain = MediumBoot.domain_in(service_kill_image.archive, codec: ABI::Codec.new(ABI::Generator.plan(root: @root).schema))
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          service_kill(accel, count, remote, service_kill_image, domain)
          ["#{accel}-#{count}cpu", regrant(accel, count, remote, regrant_image)]
        end
      end

      private

      # A test image under build/system-domain/name whose erts script boots the test-only
      # erx_echo_test (ECHO_BOOT), with manifest.
      def image(fiasco, name, manifest)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/system-domain', name))
        image = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                    fiasco: fiasco)
        nothing = ProductionImage::Added.new(entries: [].freeze, inputs: [].freeze, imports: {}.freeze)
        image.build_test_image(directory: directory, added: nothing, domains: [ECHO_BOOT],
                               manifest_source: manifest)
      end

      def regrant(accel, count, remote, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @regrant_manifest, memory_mib: @machine.memory_mib,
                                                         test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, machine_end: true,
                 checkpoints: Regrant.checkpoints(points))
        'passed'
      end

      def service_kill(accel, count, remote, built, domain)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib,
                                                         test_image: true)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, machine_end: true,
                 checkpoints: SystemDomain.service_kill_checkpoints(points, domain: domain))
        'passed'
      end
    end
  end
end

require_relative 'system_domain_regrant'
