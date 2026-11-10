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
  # MediumBoot's machine with a manifest whose configured ERTS domain stays up, and
  # types at the system's Erlang shell, as a person would, from the production
  # checkpoints' command shell on.
  #
  # Its one cell, service_kill, at each CPU count: once the configured domain runs, the
  # shell kills the domain service. The service is the system release's significant
  # child, so its end shuts its supervisor down and ends the permanent application,
  # and init ends the runtime with its slogan on the console, which is the report of
  # the failure table's row; the root's stop then ends the machine. The machine must
  # end by itself (Qemu#run's machine_end). That no domain is left running follows
  # from it, since every domain's space is a child of the system domain's; the cell
  # does not look for one. Nor does it read a crash record: on the stopgap kernel the
  # root's own stop writes none (TODO.md, the liberx Fiasco backend's halt item).
  module SystemDomain
    MACHINE = MediumBoot::MACHINE
    # What the configured domain's ERTS runs: MediumBoot's arguments without the -eval
    # that halts, so its init runs the release's boot script and the domain stays up.
    DOMAIN_ARGS = MediumBoot::DOMAIN_ARGS[0...-2].freeze
    raise Error, 'MediumBoot::DOMAIN_ARGS no longer ends in its -eval' unless MediumBoot::DOMAIN_ARGS[-2] == '-eval'

    # MediumBoot's configured row with DOMAIN_ARGS: restarts 0, so the domain service
    # starts it once, at boot.
    ARGS_LINE = /^  args ".*"\n\z/
    DOMAIN_ROW = MediumBoot::DOMAIN_ROW.sub(ARGS_LINE, "  args \"#{DOMAIN_ARGS.join(' ')}\"\n").freeze
    raise Error, 'MediumBoot::DOMAIN_ROW does not end in its args line' if DOMAIN_ROW == MediumBoot::DOMAIN_ROW

    # The domain service gives the configured row the first id above the system domain's.
    CONFIGURED_ID = MediumBoot::CONFIGURED_ID

    # Typed at the Erlang shell, in three parts. Every variable carries the prefix Sd,
    # which no other expression of the suite binds, since the shell keeps every binding.
    # SdLives: each domain's id and life, from the domain service's state (MediumBoot
    # reads it the same way); the shell starts after the boot, so the core is built.
    SERVICE_KILL_LIVES = 'SdLives=fun()->[{SdI,SdS}||#{id:=SdI,state:=SdS}<-' \
                         'erx_domain_core:domains(maps:get(core,sys:get_state(erx_domain_srv)))] end'
    # SdWait: polls SdLives every 100 ms at most N times until the one domain runs, and
    # answers {service_kill, Id, running}, or timeout.
    SERVICE_KILL_WAIT = 'SdWait=fun SdW(0)->timeout;SdW(SdN)->case SdLives() of ' \
                        '[{SdId,running}]->{service_kill,SdId,running};_->timer:sleep(100),SdW(SdN-1) end end'
    # Prints the wait's answer, then kills the service. The line starts with a binding,
    # so the shell's echo of it does not start {service_kill, and only the printed
    # answer matches SERVICE_KILL_START.
    SERVICE_KILL_EXPRESSION = "#{SERVICE_KILL_LIVES},#{SERVICE_KILL_WAIT}," \
                              'io:format("~0p~n",[SdWait(600)]),exit(whereis(erx_domain_srv),kill).'
    SERVICE_KILL_ANSWER = "{service_kill,#{CONFIGURED_ID},running}".freeze
    SERVICE_KILL_START = /\A(?:[0-9]+> )?\{service_kill,/n
    # init's slogan as it halts the runtime once the permanent application erx_domain has
    # ended, shut down by its supervisor; it may follow an unended prompt. The application
    # controller's reason is a string, which init prints with its quotes:
    # ("{application_terminated,erx_domain,shutdown}").
    SLOGAN_PATTERN = /Kernel pid terminated \(application_controller\)/n
    SLOGAN = /Kernel pid terminated \(application_controller\) \("\{application_terminated,erx_domain,shutdown\}"\)\r*\n\z/n

    module_function

    # The manifest: MediumBoot's, room for two domains, with DOMAIN_ROW for its row.
    def manifest(source) = MediumBoot.manifest(source, row: DOMAIN_ROW)

    # The production checkpoints to the command shell, then the Erlang shell, the kill and
    # the runtime's end. points must end at the command shell.
    def service_kill_checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      answer = /\A(?:[0-9]+> )?#{Regexp.escape(SERVICE_KILL_ANSWER)}\r*\n\z/n
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: "#{SERVICE_KILL_EXPRESSION}\r").freeze,
       { name: 'domain-running', pattern: SERVICE_KILL_START, seconds: 120,
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
