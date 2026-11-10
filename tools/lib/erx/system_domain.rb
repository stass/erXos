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
  # "System services", "The root task and its end"). It boots the production image on
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
    MACHINE = MediumBoot::MACHINE
    # What the configured domains' ERTS runs: MediumBoot's arguments without the -eval
    # that halts, so its init runs the release's boot script over the erx carrier and the
    # domain stays up as a node, behind the emulator flag that lets the control_table step
    # hold its system connection's ring (erx_lane_drv.c, port_control 4).
    raise Error, 'MediumBoot::DOMAIN_ARGS no longer ends in its -eval' unless MediumBoot::DOMAIN_ARGS[-2] == '-eval'
    raise Error, 'MediumBoot::UP_ARGS no longer starts with --' unless MediumBoot::UP_ARGS.first == '--'

    DOMAIN_ARGS = ['-erx', 'test_lane_hold', *MediumBoot::UP_ARGS].freeze

    # MediumBoot's configured row with DOMAIN_ARGS and one connection, so its control table
    # has one slot, and a second domain, peer, of the same limits and arguments: restarts 0,
    # so the domain service starts each once, at boot.
    ARGS_LINE = /^  args ".*"\n\z/
    CONNECTIONS_LINE = /^  connections 0\n/
    DOMAIN_ROW = MediumBoot::DOMAIN_ROW.sub(ARGS_LINE, "  args \"#{DOMAIN_ARGS.join(' ')}\"\n")
                                       .sub(CONNECTIONS_LINE, "  connections 1\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW does not end in its args line' unless DOMAIN_ROW.include?('test_lane_hold')
    raise Error, 'MediumBoot::DOMAIN_ROW has no connections 0 line' unless DOMAIN_ROW.include?("  connections 1\n")

    PEER_ROW = DOMAIN_ROW[/^domain erts\n.*/m].to_s.sub(/\Adomain erts\n/, "domain peer\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW has no domain erts' unless PEER_ROW.start_with?("domain peer\n")

    # The domain service gives the configured rows the first ids above the system domain's,
    # in row order; host is the development manifest's.
    CONFIGURED_ID = MediumBoot::CONFIGURED_ID
    DOMAINS = { 'erts' => CONFIGURED_ID, 'peer' => CONFIGURED_ID + 1 }.freeze
    SYSTEM_NODE = 'system@erxos'
    SYSTEM_CREATION = MediumBoot::SYSTEM_DOMAIN_ID

    # Typed at the Erlang shell, in parts. Every variable carries the prefix Sd, which no
    # other expression of the suite binds, since the shell keeps every binding.
    # SdLives: each domain's id, node and life, by id, from the domain service's state
    # (MediumBoot reads it the same way); the shell starts after the boot, so the core is
    # built.
    SERVICE_KILL_LIVES = 'SdLives=fun()->lists:sort([{SdI,SdN,SdS}||#{id:=SdI,node:=SdN,state:=SdS}<-' \
                         'erx_domain_core:domains(maps:get(core,sys:get_state(erx_domain_srv)))]) end'
    # SdWait: polls SdLives every 100 ms at most N times until two domains are ready, their
    # inits having reported, and answers the last SdLives.
    SERVICE_KILL_WAIT = 'SdWait=fun SdW(0)->SdLives();SdW(SdK)->case SdLives() of ' \
                        '[{_,_,ready},{_,_,ready}]=SdLv->SdLv;_->timer:sleep(100),SdW(SdK-1) end end'
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
                          'SdPid!{erx_ready,#{connections=>self()}},SdPid!{erx_connection_mapped,1},' \
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
    # {sd_burst, I} to R in order, then PADDING of sd_pad, which R gets enveloped too, waits until its system side's port counts them all sent into the lane (the
    # counts' first word, erx_lane_drv.h), so the burst is published, and kills Agent, which
    # halts erts; it waits on, so its end is erts's. SdCollect: a system-domain process that traps exits, links to the burst's
    # process P and gathers what arrives until P's 'EXIT'; it answers
    # {sd_collected, R, {Count, InOrder, Exit}}. The domain service ends erts's side only
    # after the finish has delivered every published frame, so the whole burst comes before
    # the exit.
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
    # may (badarg), and then has the domain service write N records one at a time through
    # erts's domain pid (its test_record hook), each a connection_down about a connection
    # erts does not hold, which erts's agent gets as {erx_origin, 4, Msg} and answers
    # unmapped, so the slot is free again (SdFree). Every record arrives behind the full,
    # paused lane, and the stray call writes none: Taken is N exactly.
    RECORDS = 3
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
                         'SdSlots=fun()->{ok,#{slots:=SdSs}}=erx_domain_core:fetch(SdTid,maps:get(core,sys:get_state(erx_domain_srv))),SdSs end,' \
                         'SdFree=fun SdFf(0)->timeout;SdFf(SdFk)->case SdSlots() of #{}=SdFm when map_size(SdFm)=:=0->ok;' \
                         '_->timer:sleep(10),SdFf(SdFk-1) end end,' \
                         'SdTag=erpc:call(erts@erxos,erlang,whereis,[erx_connections],10000),' \
                         'SdSink=spawn(erts@erxos,timer,sleep,[infinity]),SdHo=spawn(erts@erxos,SdHold),SdHm=monitor(process,SdHo),' \
                         "SdHo!{sd_hold,self(),#{RECORDS}},SdHolding=receive {erx_origin,_,{sd_holding,SdHo}}->ok;{'DOWN',SdHm,_,_,SdHx0}->{down,SdHx0} " \
                         'after 10000->timeout end,SdP0=SdPaused(),' \
                         'SdFill=fun SdFl(0)->never;SdFl(SdFk)->case erlang:send(SdSink,<<0:8192>>,[nosuspend]) of ' \
                         'nosuspend->full;_->SdFl(SdFk-1) end end,SdFull=SdFill(100000),' \
                         'SdStray=try erlang:port_control(SdSys,3,[<<0:32>>,term_to_binary({22,self(),SdTag}),' \
                         'term_to_binary({erx_connection_down,999,noconnection})]) catch error:badarg->badarg end,' \
                         "SdRecs=[case gen_server:call(erx_domain_srv,{test_record,SdTid,100+SdRi}) of {ok,0}->SdFree(3000);SdRo->SdRo end||SdRi<-lists:seq(1,#{RECORDS})]," \
                         "SdHeld=receive {erx_origin,_,{sd_held,SdHo,SdHg1,SdHt3,SdHw3}}->{SdHg1,SdHt3,SdHw3};{'DOWN',SdHm,_,_,SdHx1}->{down,SdHx1} " \
                         'after 60000->timeout end'
    # A watcher of a process of peer, then peer's system side's port, found by its open
    # command, whose last word is the domain's node (erx_connections:open/3), ended with
    # {domain_down, D2, x}, D2 erts's id and not peer's: the watcher's link and monitor
    # fire noconnection (edit 56 of docs/design-runtime.md), and peer stops, its system
    # side lost (docs/design-system.md, "A lost system connection ends the domain"). Then a
    # watcher of a process of erts, and erts made to kill its own agent, its pid asked of
    # erts first, since the system domain may only send to it, by SdBurst behind its burst,
    # with the domain service suspended until erts no longer answers and the watcher's spawn_request into it is
    # made, so the request is pending as the side ends, as are the library calls of
    # SERVICE_KILL_PENDING; SERVICE_KILL_RPC's call runs in erts as it halts. erts halts
    # with status 69, and the link, the monitor and the spawn all fire
    # {domain_down, Erts, {halt, 69}}, the reason the service ends the side's port with.
    # SdE1 and SdE2 are the deaths after each, SdL1 the domains still alive after the
    # first, SdV1 and SdV2 what the watchers saw, SdG2 the probe's verdict, SdB1 and SdB2 whether each
    # library call was blocked in its request before erts's side ended, SdV3 what the
    # library calls returned, SdV4 what the burst's collector gathered.
    SERVICE_KILL_ENDS = 'SdPp=spawn(peer@erxos,timer,sleep,[infinity]),SdW1=SdWatch(SdPp),SdW1!sd_go,' \
                        'SdPort=hd([SdPt||SdPt<-erlang:ports(),{name,SdNm}<-[erlang:port_info(SdPt,name)],' \
                        'lists:suffix(" peer@erxos",SdNm)]),' \
                        "exit(SdPort,{domain_down,#{DOMAINS.fetch('erts')},x}),SdE1=SdUntil(1,600),SdL1=SdLives()," \
                        'SdV1=receive {sd_watched,SdW1,SdV1w}->SdV1w after 60000->timeout end,' \
                        "SdPe=spawn(erts@erxos,timer,sleep,[infinity]),SdW2=SdWatch(SdPe),#{SERVICE_KILL_RPC}," \
                        'SdAgent=erpc:call(erts@erxos,erlang,whereis,[erx_connections],10000),' \
                        'sys:suspend(erx_domain_srv),SdTp=spawn(erts@erxos,SdBurst),SdTr=SdCollect(SdTp),SdTp!{sd_go,SdTr,SdAgent},' \
                        'SdG2=SdGone(erts@erxos,100),SdW2!{sd_spawn,erts@erxos},' \
                        "receive {sd_spawned,SdW2}->ok after 10000->timeout end,#{SERVICE_KILL_PENDING}," \
                        'sys:resume(erx_domain_srv),' \
                        'SdE2=SdUntil(2,600),SdV2=receive {sd_watched,SdW2,SdV2w}->SdV2w after 60000->timeout end,' \
                        'SdV3=[receive {sd_called,SdCk,SdCv}->SdCv after 60000->timeout end||SdCk<-[SdC1,SdC2,SdC3,SdC4,SdC5]],' \
                        'SdV4=receive {sd_collected,SdTr,SdTv}->SdTv after 60000->timeout end'
    # Prints the answer, ends the two domains, prints how they ended, then kills the
    # service. The line starts with a binding, so the shell's echo of it starts neither
    # {service_kill nor {domain_ends, and only the printed answers match.
    SERVICE_KILL_EXPRESSION = "#{SERVICE_KILL_LIVES},#{SERVICE_KILL_WAIT},#{SERVICE_KILL_ASK},#{SERVICE_KILL_DEATHS}," \
                              "#{SERVICE_KILL_FORGED},#{SERVICE_KILL_WATCH},#{SERVICE_KILL_CALL},#{SERVICE_KILL_BURST}," \
                              'SdL=SdWait(600),' \
                              "io:format(\"~0p~n\",[{service_kill,SdL,#{SERVICE_KILL_SYSTEM},SdPeers(SdL),SdForged(#{DOMAINS.fetch('erts')},erts@erxos)}])," \
                              "#{SERVICE_KILL_TABLE},io:format(\"~0p~n\",[{control_table,SdHolding,SdFull,SdPaused()>SdP0,SdStray,SdRecs,SdHeld}])," \
                              "#{SERVICE_KILL_ENDS},io:format(\"~0p~n\",[{domain_ends,SdE1,SdL1,SdV1,SdG2,SdE2,SdV2,SdB1,SdB2,SdV3,SdV4}])," \
                              'exit(whereis(erx_domain_srv),kill).'
    SERVICE_KILL_ANSWER = begin
      lives = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,ready}" }.join(',')
      nodes = DOMAINS.keys.map { |name| "#{name}@erxos" }.join(',')
      peers = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,#{id}}" }.join(',')
      "{service_kill,[#{lives}],#{SYSTEM_NODE},#{SYSTEM_CREATION},[#{nodes}],[#{peers}],{2,erts@erxos}}".freeze
    end
    SERVICE_KILL_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{service_kill,/n
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
    # The lane filled and the side paused, the stray call refused, every record answered and
    # its slot freed, and erts's port took the records and nothing more, none rewritten.
    CONTROL_TABLE_ANSWER = "{control_table,ok,full,true,badarg,[#{(['ok'] * RECORDS).join(',')}],{ok,#{RECORDS},0}}"
    CONTROL_TABLE_START = /\A\{control_table,/n
    # init's slogan as it halts the runtime once the permanent application erx_domain has
    # ended, shut down by its supervisor; it may follow an unended prompt. The application
    # controller's reason is a string, which init prints with its quotes:
    # ("{application_terminated,erx_domain,shutdown}").
    SLOGAN_PATTERN = /Kernel pid terminated \(application_controller\)/n
    SLOGAN = /Kernel pid terminated \(application_controller\) \("\{application_terminated,erx_domain,shutdown\}"\)\r*\n\z/n

    module_function

    # The manifest: MediumBoot's, room for two domains, with DOMAIN_ROW and PEER_ROW for its rows.
    def manifest(source) = MediumBoot.manifest(source, row: DOMAIN_ROW + PEER_ROW)

    # The production checkpoints to the command shell, then the Erlang shell, the kill and
    # the runtime's end. points must end at the command shell.
    def service_kill_checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      answer = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(SERVICE_KILL_ANSWER)}\r*\n\z/n
      ends = /\A#{Regexp.escape(DOMAIN_ENDS_ANSWER)}\r*\n\z/n
      table = /\A#{Regexp.escape(CONTROL_TABLE_ANSWER)}\r*\n\z/n
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: "#{SERVICE_KILL_EXPRESSION}\r").freeze,
       { name: 'domain-running', pattern: SERVICE_KILL_START, seconds: 180,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} before the kill" unless answer.match?(text) } }.freeze,
       { name: 'control-table', pattern: CONTROL_TABLE_START, seconds: 180,
         verify: ->(text) { raise Error, "the control table answered #{text.inspect}" unless table.match?(text) } }.freeze,
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
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @manifest = SystemDomain.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)))
      end

      # Packs the image once (with its release medium, which no boot here attaches: the
      # medium build is the one that takes MACHINE), then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/system-domain/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", service_kill(accel, count, remote, built)]
        end
      end

      private

      def service_kill(accel, count, remote, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MACHINE.memory_mib, machine_end: true,
                 checkpoints: SystemDomain.service_kill_checkpoints(points))
        'passed'
      end
    end
  end
end
