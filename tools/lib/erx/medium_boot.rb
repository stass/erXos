# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest/md5'
require 'fileutils'
require 'json'
require_relative 'boot_record'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'pack_wire'
require_relative 'release_files'
require_relative 'release_medium'
require_relative 'runner'

module Erx
  # The QEMU harness as the firmware of a release medium (docs/design-platforms.md,
  # "Slots and the boot-selection record"): it reads the boot-selection record with the
  # slot parser (BootRecord), copies the committed slot's bootable file out of the
  # medium, boots it with -kernel and the medium as the guest's block device, and
  # writes the boot value into /chosen/bootloader of QEMU's own device tree, which it
  # passes with -dtb. Every boot here is a normal boot: the harness asks for no trial,
  # so tryboot is 0.
  module MediumBoot
    # The kernel's line that names the boot value it took from /chosen.
    BOOT_VALUE = /\Aerx: boot value /n

    # An expression for a shell of the booted system that runs the CRC-32C per-byte
    # primitive, erx_bytes:crc32c/2: over "123456789", whose CRC-32C is RFC 3720's check
    # value E3069283; over 100000 bytes in two calls, the second continuing the first,
    # since one call takes at most 65536 bytes; and over those 100000 bytes in one call,
    # which is refused. It follows another typed expression, whose variables stay bound in
    # the shell, and a shell fun sees them, so it names values only as fun parameters,
    # which shadow them. It starts with a fun, so the shell's echo of it does not start
    # {crc32c, and only the answer matches CRC32C_START.
    CRC32C_EXPRESSION = '(fun(Data)->(fun(Head,Tail)->' \
                        '{crc32c,integer_to_list(erx_bytes:crc32c(0,<<"123456789">>),16),' \
                        'integer_to_list(erx_bytes:crc32c(erx_bytes:crc32c(0,Head),Tail),16),' \
                        'try erx_bytes:crc32c(0,Data) catch error:badarg->badarg end} end)' \
                        '(binary:part(Data,0,65536),binary:part(Data,65536,byte_size(Data)-65536)) end)' \
                        '(binary:copy(<<"erXos">>,20000)).'
    # 2D78517F is the CRC-32C of 20000 copies of "erXos", from the bitwise model in
    # test/host/medium_boot_test.rb.
    CRC32C_ANSWER = '{crc32c,"E3069283","2D78517F",badarg}'
    CRC32C_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{crc32c,/n
    # The machine of a medium boot: the production image's, with room for the medium
    # manifest's two domains (manifest). RAM grows to 768 MiB, Fiasco keeping about
    # 6% of it, and the root moves up to 192 MiB, as on the QEMU oracle's machine, since the
    # archive below it carries the domain runtime images and the domain release; QEMU puts
    # the device tree 128 MiB into a machine this large (docs/design-platforms.md).
    MACHINE = ProductionImage::Machine.new(memory_mib: 768, fiasco_reserve_mib: 48, system_growth_mib: 0, tmp_growth_mib: 0,
                                           root_mib: 192)
    # The domain's own budget and its outer one: what native_domain's ERTS domain runs in.
    DOMAIN_MEMORY = 160 << 20
    DOMAIN_OUTER = 1 << 20
    # The boot script the domain runs, of the applications every domain boots through, as
    # the image's build defines a boot script named by a manifest row (ProductionImage).
    DOMAIN_BOOT = ReleaseFiles.domain_boot('erts', applications: ProductionImage::DOMAIN_APPLICATIONS)
    # The halt DOMAIN_ARGS evaluates: erlang:halt(N), N the digits leading its -sname,
    # plus 100 unless init:script_id() names DOMAIN_BOOT, whose release file is named
    # after it (ReleaseFiles#boot_files). Its words hold no space and no double quote,
    # since a manifest row's args are one quoted string split at spaces.
    NAMED_HALT = 'erlang:halt(length(lists:takewhile(fun(C)->(C>=$0)andalso(C=<$9)end,' \
                 'hd(hd(element(2,init:get_argument(sname))))))' \
                 "+100-lists:sum([100||{S,_}<-[init:script_id()],S=:=atom_to_list(#{DOMAIN_BOOT.name})]))"
    # What the domain's ERTS runs: its boot script, which the manifest's packer and the
    # domain service bind as -boot before these words (they start with --, so the
    # binding is init's first flag), over the erx carrier, as every domain's release
    # does, so the domain is a node and its init reports ready before -eval
    # (docs/design-runtime.md, edit 65); then NAMED_HALT. So a halt with status 0 says
    # init ran DOMAIN_BOOT's script and -eval, and that the node is named by the
    # domain's name, not by its id.
    DOMAIN_ARGS = %W[-- -root / -bindir /bin -progname erl -home / -nouser -nocookie
                     -no_epmd -proto_dist erx -eval #{NAMED_HALT}].freeze
    # DOMAIN_ARGS without the halt: a domain that stays up until it is stopped.
    UP_ARGS = DOMAIN_ARGS[0...-2].freeze
    # The medium manifest's configured domain: the interpreter's image on DOMAIN_BOOT,
    # in a limits profile of the domain's budgets, with DOMAIN_ARGS, the arguments the
    # cell's own creates pass. The domain service starts it at boot and, with restarts 0,
    # never again once it halts.
    DOMAIN_ROW = "limits erts\n  memory #{DOMAIN_MEMORY}\n  outer #{DOMAIN_OUTER}\n  grant @share.users\n  spaces none\n" \
                 "  lane 4096\n  connections 0\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
                 "  peer_held 4096\n  peer_held_total 4096\n" \
                 "domain erts\n  principal @principal.system\n  limits @limits.erts\n  kind service\n  flags none\n" \
                 "  runtime @artifact.#{ProductionImage::DOMAIN_RUNTIME_ARTIFACT}\n  release @artifact.#{DOMAIN_BOOT.name}\n" \
                 "  restarts 0\n  restart_period_s 5\n  args \"#{DOMAIN_ARGS.join(' ')}\"\n"

    # The system domain's id, ERX_DOM_SYSTEM_ID (include/erx/dom.h): the library refuses
    # any id at or below it, and the domain service gives ids in turn above it, so the
    # configured domain takes the first, the cell's two creates the library refuses the
    # next two, and its seven domains the seven after.
    SYSTEM_DOMAIN_ID = 4
    CONFIGURED_ID = SYSTEM_DOMAIN_ID + 1
    DOMAIN_IDS = (4..10).map { |offset| SYSTEM_DOMAIN_ID + offset }.freeze
    # An id nothing takes in the cell, for the calls the shell makes of the library itself.
    FREE_ID = SYSTEM_DOMAIN_ID + 11

    # Where the domain's runtime images and release are in the archive: the boot image's
    # indexes a create names them by. runtime is the interpreter's image, jit the BeamAsm
    # image's, the one whose manifest carries ERX_IMAGE_JIT.
    Domain = Data.define(:runtime, :jit, :release, :release_files)
    # What the BeamAsm domain evaluates in NAMED_HALT's place: a halt with status 0 says its
    # boot script ran, translated by BeamAsm, which needs a space that allows JIT objects
    # (docs/design-runtime.md, "BeamAsm"), and that the image it runs is BeamAsm's.
    JIT_HALT = 'erlang:halt(case erlang:system_info(emu_flavor) of jit->0;_->2 end)'
    JIT_ARGS = [*DOMAIN_ARGS[0...-1], JIT_HALT].freeze
    # The most, in bytes, a BeamAsm domain of DOMAIN_BOOT may take from the machine's
    # free memory beyond what an interpreter domain of it takes. The interpreter holds its
    # loaded code, about 5 MiB of this release, in ERTS's own memory; BeamAsm holds it in
    # its code space instead, two blocks of 2 and 4 MiB, so the extra is the code space
    # less those 5 MiB. The bound leaves room for one more doubling of the code space as
    # the release grows, and fails a first block of 32 MiB or more, such as upstream's
    # 64 MiB.
    JIT_EXTRA_BOUND = 16 << 20
    # What the faceted domain evaluates in NAMED_HALT's place: a gen_server call of ping
    # to its facet echo (erx:cap/1, docs/design-domains.md, "Facets"), which forwards it to
    # the process of the system domain behind it, whose answer is the call's. A halt with
    # status 0 says the domain held the facet before -eval and the call went through it
    # and back; 3 is another answer, 4 a call that raised, as one to undefined does.
    FACET_HALT = 'erlang:halt(try gen_server:call(erx:cap(echo),ping,10000) of ping->0;_->3 catch _:_->4 end)'
    FACET_ARGS = [*DOMAIN_ARGS[0...-1], FACET_HALT].freeze
    # The process of the system domain behind the facet: it answers every gen_server call
    # with its request.
    FACET_ECHO = %q{spawn(fun DlEcho()->receive {'$gen_call',DlEF,DlEM}->gen:reply(DlEF,DlEM),DlEcho() end end)}

    # The cell's steps as [variable, call, answer], each bound in turn, since each relies
    # on the ones before it. The answer of each is the line's element in its place
    # (DOMAIN_LIB_ANSWER). DlBadarg turns the NIF's badarg into the atom badarg.
    DOMAIN_LIB_STEPS = [
      # The maps the NIF refuses before the library is reached.
      ['DlCrash', 'DlBadarg(fun()->Lib:create(Spec#{crash=>0})end)', 'badarg'], # a key the library sets
      ['DlWide', 'DlBadarg(fun()->Lib:create(Spec#{id=>1 bsl 32})end)', 'badarg'], # wider than its field
      ['DlArgs', 'DlBadarg(fun()->Lib:create(Spec#{args=><<(binary:copy(<<"a">>,2048))/binary,0>>})end)',
       'badarg'], # one byte past the boot page's strings
      ['DlBoth', 'DlBadarg(fun()->Lib:create(Spec#{args=><<(binary:copy(<<"a">>,2046))/binary,0>>,env=><<"x",0>>})end)',
       'badarg'], # args and env together one past them
      ['DlNotId', 'DlBadarg(fun()->Lib:start(foo)end)', 'badarg'],
      # The domain service registered at its start, so no other process takes its ends
      # or changes the library: a well-formed create, a configured row and a stop from the
      # shell are refused.
      ['DlRegistered', 'Lib:register()', '{error,ebusy}'],
      ['DlNotCreate', 'Lib:create(Spec)', '{error,erights}'],
      ['DlNotService', "Lib:configured(#{FREE_ID},0,self())", '{error,erights}'],
      ['DlNotStop', "Lib:stop(#{CONFIGURED_ID},0)", '{error,erights}'],
      # The maps the library itself refuses, asked of the service, which spends an id on each.
      ['DlFiles', 'DlAsk(<<"files">>,#{release_files=>16#ffffffff})', '{error,einval}'], # past the archive
      ['DlUnaligned', 'DlAsk(<<"unaligned">>,#{memory=>4097})', '{error,einval}'], # not whole pages
      # The configured domain halted once, with status 0, and was not restarted: its one
      # death is the system principal's, and the cell's first create takes the next id.
      ['DlConfigured', 'DlFirstDeaths(600)', "[{#{CONFIGURED_ID},{halt,0}}]"],
      # Three ERTS domains of the interpreter through erx_domain (DlRun), each watched by a monitor on its domain
      # pid. A halt and a stop end the pid with {domain_down, Id, Info}; a kill ends it at
      # once, and the service stops the domain behind it. The stopped and the killed
      # domain run UP_ARGS, so no halt of their own races the stop.
      ['DlHalted', 'DlRun(<<"halts">>,fun(_)->ok end)', "{#{DOMAIN_IDS[0]},ok,{domain_down,#{DOMAIN_IDS[0]},{halt,0}}}"],
      ['DlStopped', 'DlRunWith(<<"stops">>,UpFields,fun(DlD)->erx_domain:stop(DlD,shutdown) end)',
       "{#{DOMAIN_IDS[1]},ok,{domain_down,#{DOMAIN_IDS[1]},stopped}}"],
      ['DlKilled', 'DlRunWith(<<"killed">>,UpFields,fun(DlD)->erx_domain:stop(DlD,kill) end)', "{#{DOMAIN_IDS[2]},ok,killed}"],
      # A domain of the BeamAsm image, which the library gives a space that allows JIT
      # objects because the image's manifest marks it: it runs, and halts with status 0.
      ['DlJit', 'DlRunWith(<<"jitted">>,JitFields,fun(_)->ok end)', "{#{DOMAIN_IDS[3]},ok,{domain_down,#{DOMAIN_IDS[3]},{halt,0}}}"],
      # A domain whose spec names an echo process of the system domain under facets: the
      # domain service mints it a facet in front of the process and answers its init's
      # report with it, and the domain's call through the facet answers, so it halts 0.
      ['DlFacet', 'DlRunWith(<<"faceted">>,FacetFields,fun(_)->ok end)',
       "{#{DOMAIN_IDS[4]},ok,{domain_down,#{DOMAIN_IDS[4]},{halt,0}}}"],
      # What a BeamAsm domain costs the machine beyond an interpreter domain of the same
      # release, each up, measured, then stopped before the next is made: below
      # JIT_EXTRA_BOUND, so BeamAsm's code space grows with the code it holds and does not
      # start at a large fixed block.
      ['DlJitExtra', "begin DlJitCost=DlCost(<<\"jitcost\">>,maps:merge(JitFields,UpFields))," \
                     "DlEmuCost=DlCost(<<\"emucost\">>,UpFields),DlJitCost-DlEmuCost<#{JIT_EXTRA_BOUND} end",
       'true']
    ].freeze
    # DlRunWith: asks the domain service for a domain named Name with the request fields of
    # Spec changed by Fields, monitors its domain pid, does Then to it and waits for the
    # monitor's reason, answering the id, Then's result and that reason, or the create's
    # refusal; a missing end is timeout in the reason's place. A domain that reports ready
    # and halts at once may have ended, and its pid with it, by the time the create
    # answers, so the monitor's noproc is read from the service's record of the death,
    # whose Info the pid's reason carries otherwise. DlRun is DlRunWith with Spec's own
    # fields.
    DOMAIN_LIB_RUN = 'fun(Name,Fields,Then)->case erx_domain:create(maps:merge(maps:without([id,principal,domain_pid],Spec),Fields#{name=>Name,boot=><<"%<boot>s">>})) of ' \
                     '{ok,DlDomain}->DlMonitor=monitor(process,erx_domain:pid(DlDomain)),DlThen=Then(DlDomain),' \
                     'DlWhy=receive {\'DOWN\',DlMonitor,process,_,noproc}->DlDeath(erx_domain:id(DlDomain));' \
                     '{\'DOWN\',DlMonitor,process,_,DlReason}->DlReason after 60000->timeout end,' \
                     '{erx_domain:id(DlDomain),DlThen,DlWhy};' \
                     'DlRefused->DlRefused end end' % { boot: DOMAIN_BOOT.name }
    # DlAsk: the domain service's answer to a create of Name with the request fields of Spec
    # changed by Fields.
    DOMAIN_LIB_ASK = 'fun(Name,Fields)->erx_domain:create(maps:merge(maps:without([id,principal,domain_pid],Spec),Fields#{name=>Name,boot=><<"%<boot>s">>})) end' % { boot: DOMAIN_BOOT.name }
    # DlFirstDeaths: the system principal's deaths as {Id, Info}, once there is one, polled from the
    # domain service's state every 100 ms at most N times; timeout if none comes.
    DOMAIN_LIB_WAIT = 'fun DlWait(0)->timeout;DlWait(N)->' \
                      'case erx_domain_core:deaths(1,maps:get(core,sys:get_state(erx_domain_srv))) of ' \
                      '[]->timer:sleep(100),DlWait(N-1);' \
                      'DlDeaths->[{DlI,DlInfo}||#{id:=DlI,info:=DlInfo}<-DlDeaths] end end'
    # DlDeath: domain Id's end as its domain pid's reason gives it, {domain_down, Id, Info},
    # from the system principal's deaths in the domain service's state; noproc if none.
    DOMAIN_LIB_DEATH = 'fun(Id)->case [DlDInfo||#{id:=DlDId,info:=DlDInfo}<-erx_domain_core:deaths(1,' \
                       'maps:get(core,sys:get_state(erx_domain_srv))),DlDId=:=Id] of ' \
                       '[DlDInfo1|_]->{domain_down,Id,DlDInfo1};[]->noproc end end'
    # DlFree: the machine's free memory in bytes, as the stopgap's page pool reports it.
    DOMAIN_LIB_FREE = 'fun()->#{attrs:=#{memory_free:={_,{partial,DlFreeB}}}}=erx_kernel_records:machine(),DlFreeB end'
    # DlCost: what a domain named Name with the request fields of Spec changed by Fields
    # takes from the machine's free memory once its create has answered, which comes after
    # its init reported ready. The domain is then stopped, and its domain_down awaited,
    # which the service sends only after the library's teardown has returned the domain's
    # pages, so the next DlCost starts from a pool without them. Prints the figure, so a
    # failing DlJitExtra shows both.
    DOMAIN_LIB_COST = 'fun(Name,Fields)->DlCostBefore=DlFree(),' \
                      '{_,DlCostTaken,{domain_down,_,stopped}}=DlRunWith(Name,Fields,fun(DlCostDomain)->' \
                      'DlCostTakenNow=DlCostBefore-DlFree(),erx_domain:stop(DlCostDomain,shutdown),DlCostTakenNow end),' \
                      'io:format("~s ~w~n",[Name,DlCostTaken]),DlCostTaken end'
    # The line the cell prints: every step's answer, in order.
    DOMAIN_LIB_ANSWER = "{domain_lib,#{DOMAIN_LIB_STEPS.map(&:last).join(',')}}".freeze
    DOMAIN_LIB_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{domain_lib,/n

    module_function

    # The domain service's NIF module, erx_domain_lib, in the system domain, with the
    # library the root built from the medium manifest: DOMAIN_LIB_STEPS in order, then
    # their answers. Variables are fun parameters or carry a Dl prefix no earlier
    # expression binds, since the shell keeps every binding. The domain service is the
    # library's registrant, so the shell's own register is refused and no end reaches it. The
    # answers are printed with ~0p, on one line however long, and the shell's own ok
    # follows on the next. The expression starts with io:format, so the shell's echo of it
    # does not start {domain_lib, and only the printed answer matches DOMAIN_LIB_START.
    def domain_lib_expression(domain)
      spec = erlang_map(id: FREE_ID, name: '<<"cell">>', principal: 1, runtime: domain.runtime, release: domain.release,
                        release_files: domain.release_files, memory: DOMAIN_MEMORY, outer: DOMAIN_OUTER,
                        grant: erlang_map(quota_ns: (1 << 64) - 1, cpuset: 1, capacity_mcpu: 1000),
                        lane: 4096, args: binary_args(DOMAIN_ARGS), env: '<<>>', domain_pid: 'self()')
      jit = erlang_map(runtime: domain.jit, args: binary_args(JIT_ARGS))
      facet = erlang_map(args: binary_args(FACET_ARGS), facets: erlang_map(echo: FACET_ECHO))
      up = erlang_map(args: binary_args(UP_ARGS))
      badarg = 'DlBadarg=fun(Call)->try Call() catch error:badarg->badarg end end'
      steps = DOMAIN_LIB_STEPS.map { |name, call, _answer| "#{name}=#{call}" }
      "io:format(\"~0p~n\",[(fun(Lib,Spec,JitFields,FacetFields,UpFields)->DlDeath=#{DOMAIN_LIB_DEATH}," \
        "DlRunWith=#{DOMAIN_LIB_RUN},DlRun=fun(Name,Then)->DlRunWith(Name,\#{},Then) end,DlAsk=#{DOMAIN_LIB_ASK}," \
        "DlFirstDeaths=#{DOMAIN_LIB_WAIT},#{badarg},DlFree=#{DOMAIN_LIB_FREE},DlCost=#{DOMAIN_LIB_COST}," \
        "#{steps.join(',')},{domain_lib,#{DOMAIN_LIB_STEPS.map(&:first).join(',')}} end)" \
        "(erx_domain_lib,#{spec},#{jit},#{facet},#{up})])."
    end

    # A boot page's argument strings as an Erlang binary expression: each NUL-terminated.
    def binary_args(args) = "<<#{args.map { |arg| "\"#{arg}\",0" }.join(',')}>>"

    # An Erlang map expression of pairs, each value an expression already.
    def erlang_map(pairs) = "\#{#{pairs.map { |key, value| "#{key}=>#{value}" }.join(',')}}"

    # The development manifest with a domain row and room for two domains (MACHINE's
    # manifest, with no growth of the system). The row, DOMAIN_ROW, is there so the image
    # carries the release and the runtime image it names, which is how a manifest makes
    # its image carry them (docs/design-stopgap.md, "The production image"). The domain
    # service starts the row at boot; the shell creates the cell's domains through the
    # service, each awaited before the next. By default the room is for two: the configured row, which
    # the build's planner plans against the principal and which runs while the shell starts,
    # and one domain of the shell's, or two at once after a kill, whose domain the service
    # stops behind its pid while the next create runs, once the configured one has ended. So
    # the system principal's quota and max_domains each grow by domains (2), and its memory
    # and root_memory each by that many domains' budgets. Machine#manifest drops the system
    # principal's session template, so the console's login at boot starts no session and
    # the ids and the room are the cell's own. The development manifest itself, what the
    # production image promises, is unchanged. row replaces DOMAIN_ROW for a harness whose
    # configured domain runs another way (SystemDomain); domains is how many of
    # domain_memory's domains the principal gains room for.
    def manifest(source, row: DOMAIN_ROW, domains: 2, domain_memory: DOMAIN_MEMORY)
      growth = domains * (domain_memory + DOMAIN_OUTER)
      { /^(principal system\n  memory )([0-9]+)$/ => growth, /^(  root_memory )([0-9]+)$/ => growth,
        /^(principal system\n(?:  .*\n)*?  domains )([0-9]+)$/ => domains,
        /^(  max_domains )([0-9]+)$/ => domains }
        .reduce(MACHINE.manifest(source)) do |text, (pattern, added)|
          raise Error, "the manifest does not have exactly one line #{pattern.source}" unless text.scan(pattern).size == 1

          text.sub(pattern) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2), 10) + added}" }
        end + row
    end

    # The domain's runtime images and release in the archive at path: the indexes of the
    # interpreter's image, of the BeamAsm image and of DOMAIN_BOOT's run of entries.
    def domain_in(archive, codec:)
      paths = PackWire.entries_of(File.binread(archive), codec).map(&:first)
      runtime = paths.index(ProductionImage::DOMAIN_RUNTIME_PATH.b)
      jit = paths.index(ProductionImage::JIT_RUNTIME_PATH.b)
      run = ReleaseFiles.domain_runs(paths)[DOMAIN_BOOT.name]
      raise Error, "the archive #{archive} lacks a domain runtime image or the release" unless runtime && jit && run

      Domain.new(runtime: runtime, jit: jit, release: run.fetch('entry'), release_files: run.fetch('files'))
    end

    # The device tree source that adds the firmware's two properties to a tree: dtc
    # merges a node defined twice, so appended to QEMU's own tree it adds them under its
    # /chosen. choice is the slot parser's answer.
    def chosen_source(choice)
      partition = BootRecord::SLOTS.fetch(choice.slot).partition
      "\n/ {\n\tchosen {\n\t\tbootloader {\n\t\t\tpartition = <#{partition}>;\n\t\t\ttryboot = <0>;\n\t\t};\n\t};\n};\n"
    end

    # The checkpoint of the kernel's boot value line: a normal boot of the chosen slot.
    def boot_value_checkpoint(choice)
      whole = /\Aerx: boot value normal slot #{choice.slot}\r?\n\z/n
      { name: 'boot-value', pattern: BOOT_VALUE, seconds: 30,
        verify: ->(text) { raise Error, "the kernel reports #{text.inspect}" unless whole.match?(text) } }.freeze
    end

    # The production boot's checkpoints with the boot value's inserted: the kernel
    # prints "erx: boot image build ..." and then "erx: boot value ...". The boot ends at
    # the console's command shell, where the person starts the Erlang shell. There the
    # person reads a release file from the slot's EROFS image (image_checkpoints), which
    # waits for the image mounts, runs the CRC-32C primitive (crc32c_checkpoints), and
    # then starts a nested command shell and types at it (command_shell_checkpoints),
    # whose lines read the mounts. Each list takes the line before it and sets what the
    # person types there.
    def checkpoints(points, choice, release:, domain:)
      at = points.index { |point| point.fetch(:name) == 'image-identity' }
      raise Error, 'the production checkpoints name no image-identity' unless at
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      erlang, image_answer = image_checkpoints(ProductionImage::Run::ERLANG_SHELL, release)
      *crc32c, crc32c_answer = crc32c_checkpoints(image_answer)
      *domain_lib, domain_lib_answer = domain_lib_checkpoints(crc32c_answer, domain)
      [*points[0..at], boot_value_checkpoint(choice), *points[(at + 1)...-1],
       points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze, erlang,
       *crc32c, *domain_lib, *command_shell_checkpoints(domain_lib_answer)].freeze
    end

    # After the shell's line previous, the person types CRC32C_EXPRESSION, and its answer
    # must be CRC32C_ANSWER whole.
    def crc32c_checkpoints(previous)
      whole = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(CRC32C_ANSWER)}\r*\n\z/n
      [previous.merge(type: "#{CRC32C_EXPRESSION}\r").freeze,
       { name: 'crc32c', pattern: CRC32C_START, seconds: 30,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} to the CRC-32C expression" unless whole.match?(text) } }.freeze]
    end

    # After the shell's line previous, the person types domain_lib_expression of the
    # archive's domain, and its answer must be DOMAIN_LIB_ANSWER whole. Three ERTS domains
    # boot and end before it, the configured one first, so it has more time than the other
    # answers.
    def domain_lib_checkpoints(previous, domain)
      whole = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?#{Regexp.escape(DOMAIN_LIB_ANSWER)}\r*\n\z/n
      [previous.merge(type: "#{domain_lib_expression(domain)}\r").freeze,
       { name: 'domain-lib', pattern: DOMAIN_LIB_START, seconds: 300,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} to the domain library expression" unless whole.match?(text) } }.freeze]
    end

    # After the Erlang shell's line previous, the person starts a nested command shell, and
    # its lines follow (COMMAND_SHELL).
    def command_shell_checkpoints(previous)
      [previous.merge(type: "erx_shell:start().\r").freeze, *COMMAND_SHELL]
    end

    # The command shell on the console (docs/design-shell.md), started from the Erlang
    # shell: each line it shows, and what the person then types. The banner says it has
    # the input, so nothing is typed before; a variable, a loop that echoes it, a line
    # continued on the next, whose prompt is empty, and a syntax error. Then its Erlang
    # commands: a file in /tmp written by a redirection and read back, a pipeline that
    # lists the release's applications, of which stdlib's line is matched, a directory
    # made beside the file and both listed in order, a name no command has, and `cd`
    # with `pwd`; `ls -1 /`, which lists the mount points proc and tmp among the
    # release's names (docs/design-files.md, Listings across mounts); `uname -a`, whose
    # host is the manifest's and whose version the build facts give (the source revision, its date, the configuration and the kernel), then
    # `uname -i` and `uname -K` alone; `dmesg | grep`, which finds the boot's littlefs line in
    # /proc/kernel/log after the console has written it; and exit, after which the Erlang shell answers again. Lines between
    # the matched ones, such as the other applications, are passed over. The line editor
    # echoes each line as typed and then redraws it after cursor movements, which no
    # pattern here matches; it rings the bell at a `}` with no `{` on its line.
    COMMAND_SHELL = [
      ['rc-banner', /\Arc: the command shell; exit ends it\r*\n\z/n, "x=(a b c)\r"],
      ['rc-assign', /\A% x=\(a b c\)\r*\n\z/n, "for(i in $x) echo $i\r"],
      ['rc-loop', /\A% for\(i in \$x\) echo \$i\r*\n\z/n, nil],
      ['rc-loop-a', /\Aa\r*\n\z/n, nil],
      ['rc-loop-b', /\Ab\r*\n\z/n, nil],
      ['rc-loop-c', /\Ac\r*\n\z/n, "{\r"],
      ['rc-open', /\A% \{\r*\n\z/n, "echo con tinued}\r"],
      ['rc-continued-line', /\Aecho con tinued\}\a?\r*\n\z/n, nil],
      ['rc-continued', /\Acon tinued\r*\n\z/n, "echo a)\r"],
      ['rc-syntax-error', /\Arc: syntax error at line 1, column 7: unexpected '\)'\r*\n\z/n,
       "echo hello >/tmp/x; cat /tmp/x\r"],
      ['rc-file', /\Ahello\r*\n\z/n, "ls /images/release/system/lib | cat\r"],
      ['rc-pipeline', /\Astdlib-[0-9][0-9.]*\r*\n\z/n, "mkdir /tmp/d; ls -1 /tmp\r"],
      ['rc-mkdir', /\Ad\r*\n\z/n, nil],
      ['rc-ls-file', /\Ax\r*\n\z/n, "nosuch\r"],
      ['rc-not-found', /\Anosuch: not found\r*\n\z/n, "cd /tmp; pwd\r"],
      ['rc-pwd', %r{\A/tmp\r*\n\z}n, "ls -1 /\r"],
      ['rc-ls-proc', /\Aproc\r*\n\z/n, nil],
      ['rc-ls-tmp', /\Atmp\r*\n\z/n, "uname -a\r"],
      ['rc-uname', %r{\AerXos erxos [0-9][0-9.]* (?:n[1-9][0-9]{0,9}-)?[0-9a-f]{12}(?:-dirty)? [A-Z][a-z]{2} [A-Z][a-z]{2} [ 1-3][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} UTC [0-9]{4} qemu-virt/development fiasco-[0-9a-f]{12} arm64\r*\n\z}n, "uname -i\r"],
      ['rc-uname-i', %r{\Aqemu-virt/development\r*\n\z}n, "uname -K\r"],
      ['rc-uname-k', /\Afiasco-[0-9a-f]{12}\r*\n\z/n, "dmesg | grep 'erx_lfs: volume mounted'\r"],
      ['rc-dmesg', /\A#[0-9]+ [0-9]+\.[0-9]{6} debug space [0-9]+: erx_lfs: volume mounted\r*\n\z/n, "exit\r"],
      ['rc-exit', /\A% exit\r*\n\z/n, nil],
      ['rc-returned', /\Aok\r*\n\z/n, "rc_ended.\r"],
      ['erlang-shell-again', /\Arc_ended\r*\n\z/n, nil]
    ].map { |name, pattern, type| { name: name, pattern: pattern, seconds: 30, **{ type: type }.compact }.freeze }.freeze

    # The release file the shell reads from the image: stdlib's lists module, many blocks long.
    IMAGE_FILE = %r{\Asystem/lib/stdlib-[^/]+/ebin/lists\.beam\z}

    # At the Erlang shell's banner, the person types an expression that waits for the block driver
    # to have started, which is when its image mounts are made, and prints the MD5 of
    # IMAGE_FILE as /images/release shows it, the system release's EROFS image in the slot
    # (docs/design-stopgap.md, "Image windows"); it must be the MD5 of the file the
    # packer put in the image. The echo of the line does not start {image_md5, so only
    # the answer matches.
    def image_checkpoints(shell, release)
      entry = release.find { |candidate| IMAGE_FILE.match?(candidate.fetch('path')) }
      raise Error, 'the release has no stdlib lists module to read from the image' unless entry

      path = "/images/release/#{entry.fetch('path')}"
      digest = Digest::MD5.file(entry.fetch('artifact')).hexdigest.upcase
      expression = "application:ensure_all_started(erx_blk),case file:read_file(\"#{path}\") of " \
                   "{ok,B}->{image_md5,binary:encode_hex(erlang:md5(B))};E->{image_md5,E} end.\r"
      whole = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{image_md5,<<"#{digest}">>\}\r*\n\z/n
      [shell.merge(type: expression).freeze,
       { name: 'image-md5', pattern: /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{image_md5,/n, seconds: 120,
         verify: ->(text) { raise Error, "the shell read #{text.inspect} from the image" unless whole.match?(text) } }.freeze]
    end

    # Boots the production image from its release medium to the shell under HVF.
    class Run
      MEMORY_MIB = MACHINE.memory_mib
      # Under HVF the watchdog numbers are the kernel's defaults, whatever they are.
      WATCHDOG = '[0-9]+,[0-9]+,[0-9]+'

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @manifest = MediumBoot.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)))
      end

      # Packs the production image and its release medium once, then boots each CPU
      # count from a fresh copy of the medium. Returns { "hvf-<n>cpu" => 'passed' }; any
      # disagreement raises.
      def call(cpus:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/medium-boot/image'))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                        .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest)
        domain = MediumBoot.domain_in(built.archive, codec: ABI::Codec.new(ABI::Generator.plan(root: @root).schema))
        cpus.to_h { |count| ["hvf-#{count}cpu", boot(count, built, written, domain)] }
      end

      private

      def boot(count, built, written, domain)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700,
                                            path: File.join(@root, 'build/medium-boot', "hvf-#{count}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"))
        medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        raise Error, 'the slot parser chose a file that is not the packed image' unless FileUtils.compare_file(image, built.single)

        disks = [QemuPlan::Disk.new(path: medium)]
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: WATCHDOG, cpus: count, manifest_source: @manifest,
                                                  memory_mib: MEMORY_MIB)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: 'hvf', cpus: count, image: image, memory_mib: MEMORY_MIB, directory: File.join(directory, 'boot'),
                 checkpoints: MediumBoot.checkpoints(points, choice, release: built.release, domain: domain), dtb: firmware_tree(count, image, disks, choice, directory),
                 disks: disks)
        'passed'
      end

      # QEMU's own tree for this boot's machine with the firmware's /chosen properties. The
      # dump's plan has the host link, as the boot's does, so the tree has the host link's UART
      # and its /chosen/bootargs carry erx.hostlink=1.
      def firmware_tree(count, image, disks, choice, directory)
        stock = File.join(directory, 'virt.dtb')
        tree = File.join(directory, 'firmware.dtb')
        source = File.join(directory, 'firmware.dts')
        argv = QemuPlan.argv(accel: 'hvf', image: image, serial: '/dev/null', cpus: count, memory_mib: MEMORY_MIB,
                             program: @qemu, disks: disks)
        machine = argv.index('-machine') + 1
        @runner.run([*argv[0...machine], "#{argv[machine]},dumpdtb=#{stock}", *argv[(machine + 1)..]],
                    name: 'qemu-dumpdtb-firmware', deadline: 30)
        listing = File.read(@runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', stock], name: 'dtc-firmware', deadline: 30).fetch('log'))
        File.write(source, listing + MediumBoot.chosen_source(choice))
        @runner.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', tree, source], name: 'dtc-firmware-tree', deadline: 30)
        tree
      end
    end

    # The measuring cell of the driver domains' footprint (docs/plan.md, G6 and G9; no
    # product code). It boots MACHINE's image with three configured domains that halt at
    # once, so the archive's domain release carries their boot scripts: bare (the domain
    # base), storage (base and erx_blk) and network (base, erx_net and erx_net_client),
    # each in a small runtime_limits profile. At the system domain's shell it creates a
    # domain booting each script, reads the root's pool pages in use (the system
    # domain's budget record) with the domain up and again once it has stopped, and asks
    # the domain over its system connection for erlang:memory(), its allocators' carriers,
    # its threads and its loaded modules. Pool pages up minus after is the domain's cost
    # to the root, ERTS copy included; it is an upper bound, since nothing of ERTS is
    # shared between domains.
    # erx_net and erx_blk are loaded and not started: erx_net's application needs the
    # system domain's local transport and a device needs a holder, so the figure is the
    # domain at rest with its modules loaded.
    module Footprint
      RELEASES = {
        'bare' => ProductionImage::DOMAIN_APPLICATIONS,
        'storage' => [*ProductionImage::DOMAIN_APPLICATIONS, 'erx_blk'].freeze,
        'network' => [*ProductionImage::DOMAIN_APPLICATIONS, 'erx_net', 'erx_net_client'].freeze
      }.freeze
      # Applications a release only loads: erx_net's needs the system domain's local transport and
      # erx_blk's a device. The cell loads the modules of these and of erx_net_client by hand.
      LOAD_ONLY = %w[erx_net erx_blk].freeze
      LOADED = %w[erx_blk erx_net erx_net_client].freeze
      MEMORY = 64 << 20
      # The small profile of the session domain, in the configured rows and in every create.
      PROCESSES = 1024
      ATOMS = 16_384
      # A step: its name, its release and the cap of the domain's /tmp in bytes. The last step
      # has a tmp cap above 0: the pool figure must not change, since a tmp cap is charged on use.
      STEPS = [['bare', 'bare', 0], ['storage', 'storage', 0], ['network', 'network', 0],
               ['bare-tmp4', 'bare', 4 << 20]].freeze
      # The system domain's /tmp cap: the tmp line of the runtime_limits system row.
      TMP_LINE = /^(runtime_limits system\n(?:  .*\n)*?  tmp )[0-9]+$/

      PROFILE = <<~ROW
        share drivers
          quota_ns 3000000
          period_ns 10000000
          cpuset 15
          capacity_mcpu 300
          capacity_first 0
          slice_us 1000
          grace_us 5
          base 16
          ceiling 31
          flags none
        runtime_limits small
          max_frame 65536
          max_message_heap 1048576
          funnel_depth 64
          exports 256
          tmp 0
          overlay 0
          atoms #{ATOMS}
          foreign_atoms 1024
          processes #{PROCESSES}
        limits drv
          memory #{MEMORY}
          outer #{DOMAIN_OUTER}
          grant @share.drivers
          spaces none
          lane 4096
          connections 0
          crash 0
          flags none
          runtime_limits @runtime_limits.small
          peer_held 4096
          peer_held_total 4096
      ROW

      # Start type load for the modules a domain cannot start, in domain releases; in the
      # system release erx_net and erx_blk are loaded too, so the system domain's figure is
      # the shell's with no device service running.
      module LoadOnly
        private

        def release_entry(application)
          return "{#{application},\"#{version(application)}\",load}" if LOAD_ONLY.include?(application)

          super
        end
      end

      # The build's release table with the three releases of RELEASES.
      module Table
        def domain_boot(name) = RELEASES.key?(name) ? ReleaseFiles.domain_boot(name, applications: RELEASES.fetch(name)) : super
      end

      module_function

      def domain_row(name)
        "domain #{name}\n  principal @principal.system\n  limits @limits.drv\n  kind service\n  flags none\n" \
          "  runtime @artifact.#{ProductionImage::DOMAIN_RUNTIME_ARTIFACT}\n  release @artifact.#{name}\n" \
          "  restarts 0\n  restart_period_s 5\n  args \"#{DOMAIN_ARGS.join(' ')}\"\n"
      end

      # MACHINE's manifest with room for the three domains, the configured rows, and the
      # system domain's /tmp cap at system_tmp bytes.
      def manifest(source, system_tmp:)
        raise Error, 'the development manifest does not have exactly one tmp line in its runtime_limits system row' unless source.scan(TMP_LINE).size == 1

        MediumBoot.manifest(source.sub(TMP_LINE) { "#{Regexp.last_match(1)}#{system_tmp}" }, domains: RELEASES.size, domain_memory: MEMORY,
                                                                          row: PROFILE + RELEASES.keys.map { |name| domain_row(name) }.join)
      end

      # The shell expression. Variables carry the prefix Fp, which nothing else binds, since the
      # shell keeps every binding. It waits for the configured domains to end, takes the system
      # domain's own figures, runs every step and prints one {fp_report, ...} line. A step is
      # {Name, Before, PoolPages, Row, Loaded, Stop} or, when the create fails, {Name, Error}.
      # Before is the pool pages in use just before the create, so drift shows as drift; PoolPages
      # is the pages in use with the domain up minus the pages once it has stopped; Row is
      # {Memory, Carriers, Threads, Processes, Atoms, Modules} of the domain at rest, with Carriers
      # the bytes each allocator holds from the system. Loaded is {ModuleCount, LoadResult, Memory,
      # Carriers, PoolPagesUp}: the figures once the modules of the applications a release only
      # loads are loaded, PoolPagesUp being the pages in use then minus the pages once it has
      # stopped. Stop is down, or timeout when the domain did not end within 60 s, in which case
      # PoolPages is no figure. The system's own figures are {Memory, Carriers, Threads, Pool}.
      # runs: ReleaseFiles.domain_runs(paths).
      def expression(runs:, runtime:)
        spec = MediumBoot.erlang_map(runtime: runtime, memory: MEMORY, outer: DOMAIN_OUTER, lane: 4096,
                                     grant: MediumBoot.erlang_map(quota_ns: (1 << 64) - 1, cpuset: 1, capacity_mcpu: 1000),
                                     args: MediumBoot.binary_args(UP_ARGS), env: '<<>>', connections: 1)
        calls = STEPS.map do |name, release, tmp|
          run = runs.fetch(release)
          "{<<\"#{name}\">>,<<\"#{release}\">>,#{run.fetch('entry')},#{run.fetch('files')},#{tmp}}"
        end
        [
          'FpEnded=fun FpE(0)->timeout;FpE(FpK)->case length(erx_domain_core:deaths(1,maps:get(core,sys:get_state(erx_domain_srv)))) >= ' \
          "#{RELEASES.size} of true->ok;false->timer:sleep(200),FpE(FpK-1) end end",
          'FpUsed=fun()->#{attrs:=#{used:={_,{_,FpU}}}}=erx_kernel_records:budget(),FpU end',
          'FpAsk=fun(FpN,FpM,FpF,FpA)->try erpc:call(FpN,FpM,FpF,FpA,20000) catch FpC:FpR->{FpC,FpR} end end',
          'FpList=fun(FpV)->case is_list(FpV) of true->FpV;false->[] end end',
          # The bytes each allocator holds from the system: every mbcs and sbcs carrier of every instance.
          'FpCarriers=fun(FpN)->lists:reverse(lists:keysort(2,[{FpA,FpSz}||FpA<-FpList(FpAsk(FpN,erlang,system_info,[alloc_util_allocators])),' \
          'FpSz<-[lists:sum([lists:sum([FpCs||{FpK,FpL}<-FpIn,FpK=:=mbcs orelse FpK=:=sbcs,{carriers_size,FpCs,_,_}<-FpL])' \
          '||{instance,_,FpIn}<-FpList(FpAsk(FpN,erlang,system_info,[{allocator,FpA}]))])],FpSz>0])) end',
          'FpThreads=fun(FpN)->[FpAsk(FpN,erlang,system_info,[FpT])||FpT<-[schedulers,dirty_cpu_schedulers,dirty_io_schedulers,thread_pool_size]] end',
          "FpSpec=#{spec}",
          "FpStep=fun(FpName,FpBoot,FpRel,FpNf,FpTmp)->FpU0=FpUsed(),FpLim=\#{processes=>#{PROCESSES},atoms=>#{ATOMS},tmp=>FpTmp}," \
          'case erx_domain:create(FpSpec#{name=>FpName,boot=>FpBoot,release=>FpRel,release_files=>FpNf,limits=>FpLim}) of ' \
          '{ok,FpD}->FpNode=erx_domain:node(FpD),timer:sleep(15000),FpU1=FpUsed(),' \
          'FpRow={FpAsk(FpNode,erlang,memory,[]),FpCarriers(FpNode),FpThreads(FpNode),FpAsk(FpNode,erlang,system_info,[process_count]),' \
          'FpAsk(FpNode,erlang,system_info,[atom_count]),length(FpList(FpAsk(FpNode,code,all_loaded,[])))},' \
          "FpMods=lists:append([case FpAsk(FpNode,application,get_key,[FpAp,modules]) of {ok,FpMs}->FpMs;_->[] end||FpAp<-[#{LOADED.join(',')}]])," \
          'FpLoad=FpAsk(FpNode,code,ensure_modules_loaded,[FpMods]),' \
          'FpRow2={length(FpMods),FpLoad,FpAsk(FpNode,erlang,memory,[]),FpCarriers(FpNode),FpUsed()},' \
          "FpMon=monitor(process,erx_domain:pid(FpD)),erx_domain:stop(FpD,shutdown)," \
          "FpStop=receive {'DOWN',FpMon,process,_,_}->down after 60000->timeout end,timer:sleep(3000),FpU2=FpUsed()," \
          '{FpName,FpU0,case FpStop of down->FpU1-FpU2;_->no_figure end,FpRow,setelement(5,FpRow2,element(5,FpRow2)-FpU2),FpStop};FpBad->{FpName,FpBad} end end',
          'FpWaited=FpEnded(600)',
          'timer:sleep(3000)',
          'FpSys={erlang:memory(),FpCarriers(node()),FpThreads(node()),FpUsed()}',
          "FpRun=lists:map(fun({FpA2,FpE2,FpB2,FpC2,FpD2})->FpStep(FpA2,FpE2,FpB2,FpC2,FpD2) end,[#{calls.join(',')}])",
          'io:format("~0p~n",[{fp_report,FpWaited,FpSys,FpRun,FpUsed()}])'
        ].join(',') + '.'
      end

      # Packs the image, boots it once with cpus guest CPUs, and runs the cell at the system
      # domain's shell. Returns the paths, in directory, of the archive's sizes (bytes of data per release and runtime
      # image, as JSON) and of the serial log, whose {fp_report, ...} line holds
      # the figures. build_medium and the guest's boot are the production image's own;
      # the table and the load types are replaced in a child process, which only measures.
      class Run
        def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                       compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
          @root = File.expand_path(root)
          @runner = runner
          @compiler = compiler
          @linker = linker
          @qemu = qemu
        end

        # The table and the load types are replaced in a child process, which builds, boots and
        # writes into directory, so nothing of them outlives the call in the caller.
        def call(cpus:, system_tmp:, directory:, jobs: 4, build: true)
          FileUtils.mkdir_p(directory)
          child = fork do
            measure(cpus: cpus, system_tmp: system_tmp, directory: directory, jobs: jobs, build: build)
            exit!(0)
          rescue StandardError => e
            warn "#{e.class}: #{e.message}"
            exit!(1)
          end
          _, status = Process.wait2(child)
          raise Error, "the footprint cell failed (#{status})" unless status.success?

          { archive: File.join(directory, "archive-tmp#{system_tmp}.json"),
            serial_log: File.join(directory, "serial-tmp#{system_tmp}-#{cpus}cpu.log") }
        end

        private

        def measure(cpus:, system_tmp:, directory:, jobs:, build:)
          ProductionImage.singleton_class.prepend(Table)
          ReleaseFiles.prepend(LoadOnly)
          manifest = Footprint.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)), system_tmp: system_tmp)
          fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
          fiasco.build(jobs: jobs) if build
          image = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/footprint/image'))
          built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                  .build_medium(directory: image, machine: MACHINE, manifest_source: manifest)
          entries = PackWire.entries_of(File.binread(built.archive), ABI::Codec.new(ABI::Generator.plan(root: @root).schema))
          File.write(File.join(directory, "archive-tmp#{system_tmp}.json"),
                     JSON.pretty_generate(archive_sizes(entries, File.size(built.archive))))
          boot(cpus, built, manifest, entries.map(&:first), File.join(directory, "serial-tmp#{system_tmp}-#{cpus}cpu.log"))
        end

        # Bytes of data per group of archive entries: the domain release, each runtime image,
        # the system release and the boot files.
        def archive_sizes(entries, file_bytes)
          sizes = entries.each_with_object(Hash.new(0)) do |(path, entry), by_group|
            by_group[path.b[%r{\A(domains/[^/]+|runtimes/[^/]+|system|boot)}n] || 'other'] += entry.fetch('data_size')
          end
          sizes.merge('archive_file_bytes' => file_bytes)
        end

        def boot(cpus, built, manifest, paths, serial_copy)
          shell = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: cpus,
                                                          manifest_source: manifest, memory_mib: MACHINE.memory_mib)
          raise Error, 'the production checkpoints do not end at the release shell' unless shell.last.fetch(:name) == 'release-shell'

          expression = Footprint.expression(runs: ReleaseFiles.domain_runs(paths),
                                            runtime: paths.index(ProductionImage::DOMAIN_RUNTIME_PATH.b))
          checkpoints = [*shell[0...-1], shell.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
                         ProductionImage::Run::ERLANG_SHELL.merge(type: "#{expression}\r").freeze,
                         { name: 'fp-report', pattern: REPORT_START, seconds: 900,
                           verify: ->(text) { raise Error, "the report: #{text[0, 300].inspect}" unless REPORT.match?(text) },
                           type: "erlang:halt().\r" }.freeze].freeze
          run_directory = File.join(@root, 'build/footprint/run')
          FileUtils.rm_rf(run_directory)
          run = Qemu.new(root: @root, runner: @runner, program: @qemu)
                    .run(accel: 'hvf', cpus: cpus, image: built.single, memory_mib: MACHINE.memory_mib, machine_end: true,
                         directory: run_directory,
                         checkpoints: checkpoints)
          FileUtils.cp(run.fetch('serial_log'), serial_copy)
        end
      end

      REPORT_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{fp_report,/n
      REPORT = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{fp_report,.*\}\r*\n\z/mn
    end
  end
end
