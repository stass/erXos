# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest/md5'
require 'fileutils'
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
    CRC32C_START = /\A(?:[0-9]+> )?\{crc32c,/n
    # The machine of a medium boot: the production image's, with room for the medium
    # manifest's two domains (manifest). RAM grows to 768 MiB, Fiasco keeping about
    # 6% of it, and the root moves up to 192 MiB, as on the QEMU oracle's machine, since the
    # archive below it carries the domain runtime images and the domain release; QEMU puts
    # the device tree 128 MiB into a machine this large (docs/design-platforms.md).
    MACHINE = ProductionImage::Machine.new(memory_mib: 768, fiasco_reserve_mib: 48, system_growth_mib: 0, tmp_growth_mib: 0,
                                           root_mib: 192)
    # The halt DOMAIN_ARGS evaluates: erlang:halt(N), N the digits leading its -sname.
    NAMED_HALT = 'erlang:halt(length(lists:takewhile(fun(C)->(C>=$0)andalso(C=<$9)end,' \
                 'hd(hd(element(2,init:get_argument(sname)))))))'
    # The domain's own budget and its outer one: what native_domain's ERTS domain runs in.
    DOMAIN_MEMORY = 160 << 20
    DOMAIN_OUTER = 1 << 20
    # The release the domain runs, the applications every domain boots through, as the
    # image's build defines a domain release named by a manifest row (ProductionImage).
    DOMAIN_RELEASE = ReleaseFiles.domain('erts', applications: ProductionImage::DOMAIN_APPLICATIONS)
    # What the domain's ERTS runs: its release's boot script, as the system's system_args
    # do, then a halt whose status is the count of digits that lead the -sname the boot
    # page gave (Name@Host). So a halt with status 0 says init ran the boot script and
    # -eval, and that the node is named by the domain's name, not by its id.
    DOMAIN_ARGS = %W[-- -root / -bindir /bin -progname erl -home / -boot /bin/start -nouser -nocookie
                     -kernel start_distribution false -eval #{NAMED_HALT}].freeze
    # The medium manifest's configured domain: the interpreter's image on DOMAIN_RELEASE,
    # in a limits profile of the domain's budgets, with DOMAIN_ARGS, the arguments the
    # cell's own creates pass. The domain service starts it at boot and, with restarts 0,
    # never again once it halts.
    DOMAIN_ROW = "limits erts\n  memory #{DOMAIN_MEMORY}\n  outer #{DOMAIN_OUTER}\n  grant @share.users\n  spaces none\n" \
                 "  lane 4096\n  connections 0\n  crash 0\n  flags none\n  runtime_limits @runtime_limits.system\n" \
                 "  peer_held 4096\n  peer_held_total 4096\n" \
                 "domain erts\n  principal @principal.system\n  limits @limits.erts\n  kind service\n  flags none\n" \
                 "  runtime @artifact.#{ProductionImage::DOMAIN_RUNTIME_ARTIFACT}\n  release @artifact.#{DOMAIN_RELEASE.name}\n" \
                 "  restarts 0\n  restart_period_s 5\n  args \"#{DOMAIN_ARGS.join(' ')}\"\n"

    # The system domain's id, ERX_DOM_SYSTEM_ID (include/erx/dom.h): the library refuses
    # any id at or below it, and the domain service gives ids in turn above it, so the
    # configured domain takes the first, the cell's two creates the library refuses the
    # next two, and its four domains the four after.
    SYSTEM_DOMAIN_ID = 4
    CONFIGURED_ID = SYSTEM_DOMAIN_ID + 1
    DOMAIN_IDS = [SYSTEM_DOMAIN_ID + 4, SYSTEM_DOMAIN_ID + 5, SYSTEM_DOMAIN_ID + 6, SYSTEM_DOMAIN_ID + 7].freeze
    # An id nothing takes in the cell, for the calls the shell makes of the library itself.
    FREE_ID = SYSTEM_DOMAIN_ID + 8

    # Where the domain's runtime images and release are in the archive: the boot image's
    # indexes a create names them by. runtime is the interpreter's image, jit the BeamAsm
    # image's, the one whose manifest carries ERX_IMAGE_JIT.
    Domain = Data.define(:runtime, :jit, :release, :release_files)
    # What the BeamAsm domain evaluates in NAMED_HALT's place: a halt with status 0 says its
    # boot script ran, translated by BeamAsm, which needs a space that allows JIT objects
    # (docs/design-runtime.md, "BeamAsm"), and that the image it runs is BeamAsm's.
    JIT_HALT = 'erlang:halt(case erlang:system_info(emu_flavor) of jit->0;_->2 end)'
    JIT_ARGS = [*DOMAIN_ARGS[0...-1], JIT_HALT].freeze

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
      ['DlNotService', "Lib:configured(#{FREE_ID},0)", '{error,erights}'],
      ['DlNotStop', "Lib:stop(#{CONFIGURED_ID},0)", '{error,erights}'],
      # The maps the library itself refuses, asked of the service, which spends an id on each.
      ['DlFiles', 'DlAsk(<<"files">>,#{release_files=>16#ffffffff})', '{error,einval}'], # past the archive
      ['DlUnaligned', 'DlAsk(<<"unaligned">>,#{memory=>4097})', '{error,einval}'], # not whole pages
      # The configured domain halted once, with status 0, and was not restarted: its one
      # death is the system principal's, and the cell's first create takes the next id.
      ['DlConfigured', 'DlFirstDeaths(600)', "[{#{CONFIGURED_ID},{halt,0}}]"],
      # Three ERTS domains of the interpreter through erx_domain (DlRun), each watched by a monitor on its domain
      # pid. A halt and a stop end the pid with {domain_down, Id, Info}; a kill ends it at
      # once, and the service stops the domain behind it.
      ['DlHalted', 'DlRun(<<"halts">>,fun(_)->ok end)', "{#{DOMAIN_IDS[0]},ok,{domain_down,#{DOMAIN_IDS[0]},{halt,0}}}"],
      ['DlStopped', 'DlRun(<<"stops">>,fun(DlD)->erx_domain:stop(DlD,shutdown) end)',
       "{#{DOMAIN_IDS[1]},ok,{domain_down,#{DOMAIN_IDS[1]},stopped}}"],
      ['DlKilled', 'DlRun(<<"killed">>,fun(DlD)->erx_domain:stop(DlD,kill) end)', "{#{DOMAIN_IDS[2]},ok,killed}"],
      # A domain of the BeamAsm image, which the library gives a space that allows JIT
      # objects because the image's manifest marks it: it runs, and halts with status 0.
      ['DlJit', 'DlRunWith(<<"jitted">>,JitFields,fun(_)->ok end)', "{#{DOMAIN_IDS[3]},ok,{domain_down,#{DOMAIN_IDS[3]},{halt,0}}}"]
    ].freeze
    # DlRunWith: asks the domain service for a domain named Name with the request fields of
    # Spec changed by Fields, monitors its domain pid, does Then to it and waits for the
    # monitor's reason, answering the id, Then's result and that reason, or the create's
    # refusal; a missing end is timeout in the reason's place. DlRun is DlRunWith with
    # Spec's own fields.
    DOMAIN_LIB_RUN = 'fun(Name,Fields,Then)->case erx_domain:create(maps:merge(maps:without([id,principal],Spec),Fields#{name=>Name})) of ' \
                     '{ok,DlDomain}->DlMonitor=monitor(process,erx_domain:pid(DlDomain)),DlThen=Then(DlDomain),' \
                     'DlWhy=receive {\'DOWN\',DlMonitor,process,_,DlReason}->DlReason after 60000->timeout end,' \
                     '{erx_domain:id(DlDomain),DlThen,DlWhy};' \
                     'DlRefused->DlRefused end end'
    # DlAsk: the domain service's answer to a create of Name with the request fields of Spec
    # changed by Fields.
    DOMAIN_LIB_ASK = 'fun(Name,Fields)->erx_domain:create(maps:merge(maps:without([id,principal],Spec),Fields#{name=>Name})) end'
    # DlFirstDeaths: the system principal's deaths as {Id, Info}, once there is one, polled from the
    # domain service's state every 100 ms at most N times; timeout if none comes.
    DOMAIN_LIB_WAIT = 'fun DlWait(0)->timeout;DlWait(N)->' \
                      'case erx_domain_core:deaths(1,maps:get(core,sys:get_state(erx_domain_srv))) of ' \
                      '[]->timer:sleep(100),DlWait(N-1);' \
                      'DlDeaths->[{DlI,DlInfo}||#{id:=DlI,info:=DlInfo}<-DlDeaths] end end'
    # The line the cell prints: every step's answer, in order.
    DOMAIN_LIB_ANSWER = "{domain_lib,#{DOMAIN_LIB_STEPS.map(&:last).join(',')}}".freeze
    DOMAIN_LIB_START = /\A(?:[0-9]+> )?\{domain_lib,/n

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
      args = DOMAIN_ARGS.map { |arg| "\"#{arg}\",0" }.join(',')
      spec = erlang_map(id: FREE_ID, name: '<<"cell">>', principal: 1, runtime: domain.runtime, release: domain.release,
                        release_files: domain.release_files, memory: DOMAIN_MEMORY, outer: DOMAIN_OUTER,
                        grant: erlang_map(quota_ns: (1 << 64) - 1, cpuset: 1, capacity_mcpu: 1000),
                        lane: 4096, args: "<<#{args}>>", env: '<<>>')
      jit = erlang_map(runtime: domain.jit, args: "<<#{JIT_ARGS.map { |arg| "\"#{arg}\",0" }.join(',')}>>")
      badarg = 'DlBadarg=fun(Call)->try Call() catch error:badarg->badarg end end'
      steps = DOMAIN_LIB_STEPS.map { |name, call, _answer| "#{name}=#{call}" }
      "io:format(\"~0p~n\",[(fun(Lib,Spec,JitFields)->DlRunWith=#{DOMAIN_LIB_RUN}," \
        "DlRun=fun(Name,Then)->DlRunWith(Name,\#{},Then) end,DlAsk=#{DOMAIN_LIB_ASK}," \
        "DlFirstDeaths=#{DOMAIN_LIB_WAIT},#{badarg}," \
        "#{steps.join(',')},{domain_lib,#{DOMAIN_LIB_STEPS.map(&:first).join(',')}} end)(erx_domain_lib,#{spec},#{jit})])."
    end

    # An Erlang map expression of pairs, each value an expression already.
    def erlang_map(pairs) = "\#{#{pairs.map { |key, value| "#{key}=>#{value}" }.join(',')}}"

    # The development manifest with a domain row and room for two domains (MACHINE's
    # manifest, with no growth of the system). The row, DOMAIN_ROW, is there so the image
    # carries the release and the runtime image it names, which is how a manifest makes
    # its image carry them (docs/design-stopgap.md, "The production image"). The domain
    # service starts the row at boot; the shell creates the cell's domains through the
    # service, each awaited before the next. The room is for two: the configured row, which
    # the build's planner plans against the principal and which runs while the shell starts,
    # and one domain of the shell's, or two at once after a kill, whose domain the service
    # stops behind its pid while the next create runs, once the configured one has ended. So
    # the system principal's quota and max_domains go from 0 to 2, and its memory and
    # root_memory each grow by two domains' budgets. The development manifest itself,
    # what the production image promises, is unchanged.
    def manifest(source)
      growth = 2 * (DOMAIN_MEMORY + DOMAIN_OUTER)
      { /^(principal system\n  memory )([0-9]+)$/ => growth, /^(  root_memory )([0-9]+)$/ => growth,
        /^(principal system\n(?:  .*\n)*?  domains )(0)$/ => 2, /^(  max_domains )(0)$/ => 2 }
        .reduce(MACHINE.manifest(source)) do |text, (pattern, added)|
          raise Error, "the manifest does not have exactly one line #{pattern.source}" unless text.scan(pattern).size == 1

          text.sub(pattern) { "#{Regexp.last_match(1)}#{Integer(Regexp.last_match(2), 10) + added}" }
        end + DOMAIN_ROW
    end

    # The domain's runtime images and release in the archive at path: the indexes of the
    # interpreter's image, of the BeamAsm image and of DOMAIN_RELEASE's run of entries.
    def domain_in(archive, codec:)
      paths = PackWire.entries_of(File.binread(archive), codec).map(&:first)
      runtime = paths.index(ProductionImage::DOMAIN_RUNTIME_PATH.b)
      jit = paths.index(ProductionImage::JIT_RUNTIME_PATH.b)
      run = ReleaseFiles.domain_runs(paths)[DOMAIN_RELEASE.name]
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
      whole = /\A(?:[0-9]+> )?#{Regexp.escape(CRC32C_ANSWER)}\r*\n\z/n
      [previous.merge(type: "#{CRC32C_EXPRESSION}\r").freeze,
       { name: 'crc32c', pattern: CRC32C_START, seconds: 30,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} to the CRC-32C expression" unless whole.match?(text) } }.freeze]
    end

    # After the shell's line previous, the person types domain_lib_expression of the
    # archive's domain, and its answer must be DOMAIN_LIB_ANSWER whole. Three ERTS domains
    # boot and end before it, the configured one first, so it has more time than the other
    # answers.
    def domain_lib_checkpoints(previous, domain)
      whole = /\A(?:[0-9]+> )?#{Regexp.escape(DOMAIN_LIB_ANSWER)}\r*\n\z/n
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
      whole = /\A(?:[0-9]+> )?\{image_md5,<<"#{digest}">>\}\r*\n\z/n
      [shell.merge(type: expression).freeze,
       { name: 'image-md5', pattern: /\A(?:[0-9]+> )?\{image_md5,/n, seconds: 120,
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
  end
end
