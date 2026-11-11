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
require_relative 'system_domain'

module Erx
  # A configured domain's device, given at each creation of its row (docs/design-system.md,
  # "Devices"). It boots the production image on MediumBoot's machine with a manifest whose
  # one configured ERTS domain holds the platform's spare unit, a virtio-mmio transport
  # QEMU virt leaves without a backend, and may restart once. From the system's Erlang
  # shell, as a person would type it, the cell asks the domain to find its device record,
  # open the device and read its magic; halts the domain; waits for the domain service to
  # restart the row under a new id; and asks the new domain the same. Each answer is the
  # transport's magic, read through a window the domain library gave that creation, at the
  # unit's offset in its register page. Then it kills the domain service, and the runtime
  # and the machine end as SystemDomain's do.
  #
  # A restart that starts the domain without its unit fails the cell: the second ask finds
  # no record (erx_device_record:find answers {ok, []}). A restart refused because the
  # first creation's give was never undone fails it too: no second domain becomes ready.
  module DeviceGive
    MACHINE = MediumBoot::MACHINE
    # The platform's spare unit (config/platforms/qemu-virt.json), whose one device's role
    # makes its record `net virtio_mmio` (include/erx/device_kinds.h).
    UNIT = "unit spare\n  placement \"spare\"\n  holder @domain.erts\n"
    ARGS_LINE = /^  args ".*"\n\z/
    RESTARTS_LINE = "  restarts 0\n"
    # MediumBoot's configured row, staying up as a node (MediumBoot::UP_ARGS), with one restart.
    DOMAIN_ROW = MediumBoot::DOMAIN_ROW.sub(ARGS_LINE, "  args \"#{MediumBoot::UP_ARGS.join(' ')}\"\n")
                                       .sub(RESTARTS_LINE, "  restarts 1\n").freeze
    FIRST_ID = MediumBoot::CONFIGURED_ID
    # The restart's id: the next after the storage domain's, which boot gave after erts's.
    RESTART_ID = MediumBoot::STORAGE_ID + 1
    # QEMU virt's virtio-mmio magic, "virt" read little-endian, and where the spare
    # transport sits in its page and how long its window is.
    MAGIC = 0x74726976
    OFFSET = 0xe00
    SIZE = 0x200

    # The parts of the line typed at the Erlang shell. Every variable starts with Dg, which
    # no other expression of the suite binds, since the shell keeps every binding.
    # DgReady: the ids of the ready domains of the erts node, from the domain service's
    # state, so the configured storage domain is not counted, or none while the service
    # is too busy to answer (a create inside its restart can outlast sys:get_state's 5 s),
    # so the wait polls on.
    READY = 'DgReady=fun()->try [DgI||#{id:=DgI,state:=ready,node:=erts@erxos}<-erx_domain_core:domains(' \
            'maps:get(core,sys:get_state(erx_domain_srv)))] catch _:_->[] end end'
    # DgWait(Old, K): polls every 100 ms at most K times until exactly one ready domain's id
    # is not Old, and answers that id, or timeout.
    WAIT = 'DgWait=fun DgW(_,0)->timeout;DgW(DgOld,DgK)->case DgReady()--[DgOld] of [DgNew]->DgNew;' \
           '_->timer:sleep(100),DgW(DgOld,DgK-1) end end'
    # DgRead(): at the domain's node, its one net virtio_mmio record opened and the magic
    # read, with the window's offset and size and the node's creation, which is the
    # domain's id, so the answer names the domain that read; or the class and reason of
    # the failure.
    READ_DEVICE = 'DgRead=fun()->try erpc:call(erts@erxos,fun()->' \
                  '{ok,[DgSpec]}=erx_device_record:find(net,virtio_mmio),{ok,DgDev}=erx_device:open(DgSpec),' \
                  '{object,_,DgOffset,DgSize}=maps:get(window,DgSpec),' \
                  '{erx_device:read(DgDev,magic),DgOffset,DgSize,erlang:system_info(creation)} end,10000) ' \
                  'catch DgC:DgR->{DgC,DgR} end end'
    # The first domain's read, its halt, the wait for the row's restart under another id,
    # the new domain's read, the answer, and the kill of the domain service.
    SEQUENCE = 'DgI1=DgWait(0,600),DgR1=DgRead(),spawn(erts@erxos,erlang,halt,[3]),' \
               'DgI2=DgWait(DgI1,600),DgR2=DgRead(),' \
               'io:format("~0p~n",[{device_give,DgI1,DgR1,DgI2,DgR2}]),exit(whereis(erx_domain_srv),kill).'
    LINE = [READY, WAIT, READ_DEVICE, SEQUENCE].join(',').freeze
    # What each domain's read answers: the magic, the window's place, and the domain's id.
    def self.read_answer(id) = "{#{MAGIC},#{OFFSET},#{SIZE},#{id}}"
    ANSWER = "{device_give,#{FIRST_ID},#{read_answer(FIRST_ID)},#{RESTART_ID},#{read_answer(RESTART_ID)}}"
    # The shell's prompt, which may precede the answer.
    PROMPT = '(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?'
    START = /\A#{PROMPT}\{device_give,/n
    
    module_function

    # The manifest: MediumBoot's, with DOMAIN_ROW for its row and the spare unit placed on it.
    def manifest(source) = MediumBoot.manifest(source, row: DOMAIN_ROW) + UNIT

    # The production checkpoints to the command shell, then the Erlang shell, the line,
    # its answer and the runtime's end. points must end at the command shell.
    def checkpoints(points)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      answer = /\A#{PROMPT}#{Regexp.escape(ANSWER)}\r*\n\z/n
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: "#{LINE}\r").freeze,
       { name: 'device-given', pattern: START, seconds: 600,
         verify: ->(text) { raise Error, "the device reads gave #{text.inspect}" unless answer.match?(text) } }.freeze,
       { name: 'system-domain-ended', pattern: SystemDomain::SLOGAN_PATTERN, seconds: 60,
         verify: lambda { |text|
           raise Error, "the runtime ended with #{text.inspect}" unless SystemDomain::SLOGAN.match?(text)
         } }.freeze].freeze
    end

    # Boots the image under HVF at each CPU count, where placement puts each cell.
    # Returns { "<accel>-<n>cpu" => 'passed' }; any disagreement raises.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @manifest = DeviceGive.manifest(File.binread(File.join(@root, ProductionImage::MANIFEST)))
      end

      # Packs the image once, then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/device-give/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                .build_medium(directory: directory, machine: MACHINE, manifest_source: @manifest)
        placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", give(accel, count, remote, built)]
        end
      end

      private

      def give(accel, count, remote, built)
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: MACHINE.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MACHINE.memory_mib, machine_end: true,
                 checkpoints: DeviceGive.checkpoints(points))
        'passed'
      end
    end
  end
end
