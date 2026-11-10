# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'production_image'
require_relative 'qemu'
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
  # connection (docs/design-runtime.md, "Connections in ERTS"), then kills the domain
  # service. The system domain is system@<host> with creation 4, alive since kernel
  # started net_kernel, before the domain service; each domain's node() is its name at the
  # host and its creation its id, as erpc:call from the system shell, which needs the
  # system side to carry frames both ways, answers. The service is the system release's
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
    # that halts, so its init runs the release's boot script and the domain stays up, and
    # over the erx carrier in place of no carrier, so the domain is a node.
    NO_CARRIER = %w[-kernel start_distribution false].freeze
    CARRIER = %w[-no_epmd -proto_dist erx].freeze
    raise Error, 'MediumBoot::DOMAIN_ARGS no longer ends in its -eval' unless MediumBoot::DOMAIN_ARGS[-2] == '-eval'

    BOOT_ARGS = MediumBoot::DOMAIN_ARGS[0...-2]
    NO_CARRIER_AT = BOOT_ARGS.each_cons(NO_CARRIER.size).find_index(NO_CARRIER)
    raise Error, 'MediumBoot::DOMAIN_ARGS no longer runs with no carrier' unless NO_CARRIER_AT

    DOMAIN_ARGS = [*BOOT_ARGS[0...NO_CARRIER_AT], *CARRIER, *BOOT_ARGS[(NO_CARRIER_AT + NO_CARRIER.size)..]].freeze

    # MediumBoot's configured row with DOMAIN_ARGS, and a second domain, peer, of the same
    # limits and arguments: restarts 0, so the domain service starts each once, at boot.
    ARGS_LINE = /^  args ".*"\n\z/
    DOMAIN_ROW = MediumBoot::DOMAIN_ROW.sub(ARGS_LINE, "  args \"#{DOMAIN_ARGS.join(' ')}\"\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW does not end in its args line' if DOMAIN_ROW == MediumBoot::DOMAIN_ROW

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
    # SdWait: polls SdLives every 100 ms at most N times until two domains run, and answers
    # the last SdLives.
    SERVICE_KILL_WAIT = 'SdWait=fun SdW(0)->SdLives();SdW(SdK)->case SdLives() of ' \
                        '[{_,_,running},{_,_,running}]=SdLv->SdLv;_->timer:sleep(100),SdW(SdK-1) end end'
    # SdAsk: erpc:call of erlang:F(A) at a node, within 10 s, or the class and reason it
    # raised. SdPeers: each domain's id with its node() and creation, as it answers them.
    SERVICE_KILL_ASK = 'SdAsk=fun(SdN,SdF,SdA)->try erpc:call(SdN,erlang,SdF,SdA,10000) catch SdC:SdR->{SdC,SdR} end end,' \
                       'SdPeers=fun(SdL)->[{SdI,SdAsk(SdN,node,[]),SdAsk(SdN,system_info,[creation])}||{SdI,SdN,_}<-SdL] end'
    # The system node's name and creation, and the connected nodes. That the node was
    # alive before the domain service started follows from the configured domains running:
    # the service opened their sides at its start, which a runtime that is no node cannot.
    SERVICE_KILL_SYSTEM = 'node(),erlang:system_info(creation),lists:sort(nodes())'
    # Prints the answer, then kills the service. The line starts with a binding, so the
    # shell's echo of it does not start {service_kill, and only the printed answer
    # matches SERVICE_KILL_START.
    SERVICE_KILL_EXPRESSION = "#{SERVICE_KILL_LIVES},#{SERVICE_KILL_WAIT},#{SERVICE_KILL_ASK},SdL=SdWait(600)," \
                              "io:format(\"~0p~n\",[{service_kill,SdL,#{SERVICE_KILL_SYSTEM},SdPeers(SdL)}])," \
                              'exit(whereis(erx_domain_srv),kill).'
    SERVICE_KILL_ANSWER = begin
      lives = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,running}" }.join(',')
      nodes = DOMAINS.keys.map { |name| "#{name}@erxos" }.join(',')
      peers = DOMAINS.map { |name, id| "{#{id},#{name}@erxos,#{id}}" }.join(',')
      "{service_kill,[#{lives}],#{SYSTEM_NODE},#{SYSTEM_CREATION},[#{nodes}],[#{peers}]}".freeze
    end
    SERVICE_KILL_START = /\A(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?\{service_kill,/n
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
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: "#{SERVICE_KILL_EXPRESSION}\r").freeze,
       { name: 'domain-running', pattern: SERVICE_KILL_START, seconds: 180,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} before the kill" unless answer.match?(text) } }.freeze,
       { name: 'system-domain-ended', pattern: SLOGAN_PATTERN, seconds: 60,
         verify: ->(text) { raise Error, "the runtime ended with #{text.inspect}" unless SLOGAN.match?(text) } }.freeze].freeze
    end

    # Boots the image under HVF at each CPU count. Returns { "hvf-<n>cpu" =>
    # 'passed' }; any disagreement raises.
    class Run
      def self.cells(cpus) = cpus.map { |count| "hvf-#{count}cpu" }

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
      def call(cpus:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/system-domain/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest)
        Run.cells(cpus).zip(cpus).to_h { |cell, count| [cell, service_kill(count, built)] }
      end

      private

      def service_kill(count, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: 'hvf', cpus: count, image: built.single, memory_mib: MACHINE.memory_mib, machine_end: true,
                 checkpoints: SystemDomain.service_kill_checkpoints(points))
        'passed'
      end
    end
  end
end
