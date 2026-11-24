# frozen_string_literal: true

# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause

require_relative 'error'
require_relative 'fiasco'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'qmp'
require_relative 'runner'

module Erx
  # The PCIe domain's suite manifest on QEMU virt (docs/design-pcie.md, "Where the rows
  # live"): the development manifest, which holds the PCIe domain's rows, without its web
  # domain, which gives back the grant the test holder needs, its USB domain, whose xhci
  # unit the test holder holds instead, and its media domain, whose one drive, disk0 on that
  # unit, leaves with the USB domain, so it would boot serving no drive
  # (Manifest::Edit.without_domain).
  #
  # The `pcie` QEMU suite (docs/design-pcie.md, "The `pcie` QEMU suite") boots that
  # manifest on MediumBoot's machine with a test holder added (manifest): MediumBoot's
  # configured ERTS domain erts, staying up as a node, holding the platform's xhci unit,
  # qemu-xhci at the slot of the ECAM bridge's bus 0 that unit names, which QEMU attaches (QemuPlan::Pcie),
  # and a pci facet. From the system's Erlang shell, as a person would type it, one line
  # (line) waits for the holder to be ready, prints the holder's usb device records, has the
  # holder open its function through its pci facet, prints the library's PCIe catalogue
  # with that open's answer, and then measures the PCIe domain's memory at rest. The
  # harness reads QEMU's own view of the bus through QMP (Qmp#pci_functions) and checks
  # each case as a cell of its own (cells):
  #
  # * walk: the catalogue's functions, each's place, identity, state and placed memory BARs,
  #   equal QMP's functions with their memory regions as QEMU maps them once the holder's
  #   open has turned memory space on (check_walk). A placement off by a page writes a BAR
  #   the function rounds down to its size, so QMP's region differs, or the enumerator sees
  #   the write not take and the open fails; a walk that never reports leaves the catalogue
  #   unanswered; either fails the cell.
  # * hold: the holder, which the domain service starts only after it has answered the
  #   PCIe domain's report (docs/design-pcie.md, "The hold at boot"), finds exactly one usb
  #   function record, whose BAR 0's hardware size is that BAR's size in QMP (check_hold). With
  #   the hold removed the holder starts before the report, its give finds no layout, and
  #   it has no record.
  #
  # Last, the PCIe domain is stopped (the suite's row has no restart) and the root's pool
  # pages in use with it up and once it has ended give its memory at rest, as MediumBoot's
  # Footprint measures a domain, which the run's notes report (memory_note).
  module PcieDomain
    # The domains the suite leaves out: the web domain, whose grant the test holder takes,
    # the USB domain, whose xhci unit the test holder holds instead, and the media domain,
    # whose one drive leaves with the USB domain, so it would boot serving no drive.
    LEFT_OUT = %w[web usb media].freeze
    PCIE = 'pcie'

    # The test holder: MediumBoot's configured row, staying up as a node (MediumBoot::UP_ARGS),
    # with no restart, on a share of 100 mcpu of its own (HOLDER_SHARE); the platform's xhci
    # unit, held by it; and its pci facet, whose figures are docs/design-pcie.md's ("The
    # rows and the facets' limits"): every operation, the widest request rounded up to
    # 1,024 bytes, one call in flight for its one function, and the share and heap of a
    # small message facet. The configured domains' grants together may come to at most
    # the system share's reserve, 2,325 mcpu (MediumBoot::EIGHTH_SHARE): storage and
    # network take 900 each, display 100 and the PCIe domain 50, which leaves 375 without
    # the web domain's 150, room for this 100.
    HOLDER = 'erts'
    HOLDER_NODE = "#{HOLDER}@erxos".freeze
    HOLDER_SHARE = MediumBoot::EIGHTH_SHARE.sub("share eighth\n", "share holder\n").sub('quota_ns 1250000', 'quota_ns 1000000')
                                           .sub('capacity_mcpu 125', 'capacity_mcpu 100').freeze
    HOLDER_ROW = (HOLDER_SHARE + MediumBoot::DOMAIN_ROW.delete_prefix(MediumBoot::EIGHTH_SHARE))
                 .sub('grant @share.eighth', 'grant @share.holder')
                 .sub(/^  args ".*"\n\z/, "  args \"#{MediumBoot::UP_ARGS.join(' ')}\"\n").freeze
    HOLDER_UNIT = "unit xhci\n  placement \"xhci\"\n  holder @domain.#{HOLDER}\n".freeze
    HOLDER_FACET = "facet pci\n  grantee @domain.#{HOLDER}\n  service @service.pci\n  operations open,master,reset\n" \
                   "  max_request 1024\n  in_flight 1\n  reductions 100000\n  period_ns 1000000000\n  max_heap_size 8192\n"
    # The function QEMU attaches, qemu-xhci, as the platform's xhci unit (HOLDER_UNIT) names
    # it: its slot on the ECAM bridge's bus 0, and its identity, which the unit's compatible
    # spells pciVVVV,DDDD (docs/design-pcie.md, "The catalogue and gives").
    Xhci = Data.define(:slot, :vendor, :device)
    XHCI_IDENTITY = /\Apci([0-9a-f]{4}),([0-9a-f]{4})\z/
    def self.xhci(platform)
      units = platform.record.fetch('units').select { |unit| unit.fetch('key') == 'xhci' }
      devices = units.flat_map { |unit| unit.fetch('devices') }
      identity = devices.size == 1 ? XHCI_IDENTITY.match(devices.first.fetch('compatible')) : nil
      unless identity && devices.first.values_at('bus', 'function') == [0, 0]
        raise Error, "the platform's xhci unit is not one function 0 of bus 0 with a pci identity"
      end

      Xhci.new(slot: Integer(devices.first.fetch('device')), vendor: identity[1].hex, device: identity[2].hex)
    end

    # The manifest's text for platform, a Platform of QEMU virt, from root's sources.
    def self.manifest_source(root, platform:)
      LEFT_OUT.reduce(platform.manifest_source(root)) do |source, domain|
        Manifest::Edit.without_domain(source, domain, units: platform.record.fetch('units'))
      end
    end

    # The suite's manifest, from manifest_source's text: MediumBoot's medium manifest with
    # room for the holder alone (MediumBoot.manifest), the PCIe row without restarts, so
    # its stop at the end leaves it ended, and the holder's unit and facet.
    def self.manifest(source, row: HOLDER_ROW)
      held = MediumBoot.manifest(source, row: row, domains: 1)
      Manifest::Edit.set(held, { ["domain #{PCIE}", 'restarts'] => 0 }) + HOLDER_UNIT + HOLDER_FACET
    end

    # The wait for a domain at the Erlang shell, two expressions, the usb and Bluetooth
    # suites' too (UsbBoot, BtDomain).
    WAIT = [
      # PcFind(Node): the ready domains of Node in the domain service's state, or none while
      # the service is too busy to answer, so the waits poll on.
      'PcFind=fun(PcN)->try [PcD||#{node:=PcM,state:=ready}=PcD<-erx_domain_core:domains(' \
      'maps:get(core,sys:get_state(erx_domain_srv))),PcM=:=PcN] catch _:_->[] end end',
      # PcWait(Node, K): polls every 100 ms at most K times until Node has one ready domain.
      'PcWait=fun PcW(_,0)->timeout;PcW(PcN,PcK)->case PcFind(PcN) of [PcD]->PcD;_->timer:sleep(100),PcW(PcN,PcK-1) end end'
    ].freeze

    # The line typed at the Erlang shell for xhci, an Xhci, one expression per element. Every
    # variable starts with Pc, which nothing else the shell runs binds.
    def self.line(xhci) = [
      *WAIT,
      "PcHolder=PcWait(#{HOLDER_NODE},1200)",
      # PcAsk(Fun): Fun run at the holder's node, or the class and reason of its failure.
      "PcAsk=fun(PcF)->try erpc:call(#{HOLDER_NODE},PcF,10000) catch PcC:PcR->{PcC,PcR} end end",
      # The hold case: the holder's usb function records (docs/design-pcie.md, "The catalogue
      # and gives") as erx_device_record:find/2 reads them, for each peripheral a usb function
      # record names, each its role, peripheral and window's size, its first placed BAR's
      # hardware size; a refusal is printed as it is, so check_hold names it.
      'io:format("~0kp~n",[{pcie_hold,PcAsk(fun()->lists:append([case erx_device_record:find(usb,PcPe) of ' \
      '{ok,PcSs}->[{"usb",atom_to_list(PcPe),PcSz}||#{window:={object,_,_,PcSz}}<-PcSs];PcE->[PcE] end||' \
      'PcPe<-lists:usort([list_to_atom(PcP)||["function","usb",PcP|_]<-erx_device_record:records()])]) end)}])',
      # The catalogue's records, and whether each bridge's report was answered.
      'PcCats=case erx_domain_lib:pci_bridges() of {ok,PcCs}->PcCs;PcCe->[PcCe] end',
      'PcRecs=[PcRec||#{layouts:=PcLs}<-PcCats,#{record:=PcRec}<-PcLs]',
      # The holder's open of each qemu-xhci function through its pci facet.
      'PcOpen=PcAsk(fun()->[gen_server:call(erx:cap(pci),{open,{PcOb,PcObu,PcOd,PcOf}},5000)||' \
      "\#{bridge:=PcOb,bus:=PcObu,device:=PcOd,function:=PcOf,vendor:=#{xhci.vendor},device_id:=#{xhci.device}}<-PcRecs] end)",
      # The walk case: each function's place, identity, state and placed memory BARs, each
      # BAR its index, address and size, in place order.
      'io:format("~0kp~n",[{pcie_walk,[is_integer(PcA)||#{answered:=PcA}<-PcCats],PcOpen,' \
      'lists:sort([{PcBu,PcDe,PcFu,PcVe,PcDi,PcSt,[{PcI,PcAd,1 bsl PcLg}||' \
      '{PcI,#{kind:=memory,flags:=PcFl,size_log2:=PcLg,address:=PcAd}}<-lists:zip(lists:seq(0,length(PcBa)-1),PcBa),' \
      'lists:member(placed,PcFl)]}||' \
      '#{bus:=PcBu,device:=PcDe,function:=PcFu,vendor:=PcVe,device_id:=PcDi,state:=PcSt,bars:=PcBa}<-PcRecs])}])',
      # The PCIe domain's memory at rest: the root's pool pages in use with it up, its stop,
      # the wait for its death, which the service records once the library has returned its
      # pages, and the pages in use then.
      "PcUsed=#{MediumBoot::Footprint.pool_used('PcU')}",
      'PcGone=fun PcG(_,0)->timeout;PcG(PcId,PcK)->case [PcX||#{id:=PcX}<-erx_domain_core:deaths(1,' \
      'maps:get(core,sys:get_state(erx_domain_srv))),PcX=:=PcId] of []->timer:sleep(100),PcG(PcId,PcK-1);_->ended end end',
      "io:format(\"~0kp~n\",[{pcie_memory,case PcFind(#{PCIE}@erxos) of [\#{id:=PcMid,pid:=PcMpid}]->PcUp=PcUsed()," \
      'exit(PcMpid,shutdown),{PcGone(PcMid,600),PcUp,PcUsed()};PcMo->{absent,PcMo} end}])'
    ].join(',').concat(".\r").freeze

    # The shell's prompt, which may precede an answer, and each answer's line.
    PROMPT = '(?:(?:\([a-z0-9_]+@[a-z0-9_.-]+\))?[0-9]+> )?'
    def self.answer(tag) = /\A#{PROMPT}\{#{tag},/n

    # How long the line may take to print the hold's answer: the holder's wait (1,200 polls
    # of 100 ms) and the boot of its domain.
    HOLD_SECONDS = 240
    WALK_SECONDS = 60
    MEMORY_SECONDS = 120

    # The cells of each boot: its own, which passes once every answer came, and each case's.
    WALK_CELL = '-walk'
    HOLD_CELL = '-hold'
    SIDE_CELLS = [WALK_CELL, HOLD_CELL].freeze
    def self.cells(boots) = boots.flat_map { |cell| [cell, *SIDE_CELLS.map { |side| "#{cell}#{side}" }] }

    module_function

    # The walk's answer line as it must read, from QMP's functions: the catalogue answered
    # for its one bridge, the open answered ok, and each function in place order with state
    # ready and each memory region as its BAR's index, address and size. A region QEMU maps
    # nowhere is written with address -1, which no placed BAR has.
    def walk_answer(functions)
      layouts = functions.sort_by { |function| [function.bus, function.slot, function.function] }.map do |function|
        bars = function.regions.select { |region| region.type == :memory }.sort_by(&:bar)
                       .map { |region| "{#{region.bar},#{region.address || -1},#{region.size}}" }
        "{#{function.bus},#{function.slot},#{function.function},#{function.vendor},#{function.device},ready,[#{bars.join(',')}]}"
      end
      "{pcie_walk,[true],[ok],[#{layouts.join(',')}]}"
    end

    # The walk case: the answer line, its prompt removed, equals walk_answer of QMP's
    # functions, or Error naming both.
    def check_walk(text, functions:)
      line = text.b.sub(/\A#{PROMPT}/n, '').strip
      wanted = walk_answer(functions)
      raise Error, "the walk answered #{line.inspect}, QMP's functions give #{wanted.inspect}" unless line == wanted
    end

    # The hold case: the holder's records are one usb function record whose BAR 0's hardware
    # size is the size of BAR 0 of the one qemu-xhci function QMP lists, or Error naming them.
    HOLD_LINE = /\A\{pcie_hold,\[\{"usb","[a-z0-9_]*",([0-9]+)\}\]\}\z/n
    def check_hold(text, functions:, xhci:)
      line = text.b.sub(/\A#{PROMPT}/n, '').strip
      found = functions.select { |function| function.vendor == xhci.vendor && function.device == xhci.device }
      bar = found.size == 1 ? found.first.regions.find { |region| region.bar.zero? } : nil
      raise Error, "QMP lists #{found.size} qemu-xhci functions with BAR 0 #{bar.inspect}" unless bar

      size = HOLD_LINE.match(line)&.[](1)
      raise Error, "the holder's records are #{line.inspect}, not one usb record of #{bar.size} bytes" unless size && Integer(size, 10) == bar.size
    end

    # The memory line's figure as a note: the PCIe domain's pool pages at rest, or what came.
    MEMORY_LINE = /\A\{pcie_memory,\{ended,([0-9]+),([0-9]+)\}\}\z/n
    def memory_note(text)
      line = text.b.sub(/\A#{PROMPT}/n, '').strip
      match = MEMORY_LINE.match(line)
      return "the PCIe domain's memory was not measured: #{line.inspect}" unless match

      pages = Integer(match[1], 10) - Integer(match[2], 10)
      format("the PCIe domain's memory at rest: %<pages>d pool pages, %<mib>.1f MiB", pages: pages, mib: pages * 4096.0 / (1 << 20))
    end

    # The production checkpoints to the command shell, then the Erlang shell, xhci's line and
    # its three answers: the hold's, checked as the hold cell through side, the walk's,
    # checked as the walk cell, and the memory's, a note. Each case's check reads QMP's
    # functions through functions, a callable. points must end at the command shell.
    def checkpoints(points, xhci:, functions:, side:, note:)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: PcieDomain.line(xhci)).freeze,
       { name: 'pcie-hold', pattern: answer('pcie_hold'), seconds: HOLD_SECONDS,
         verify: ->(text) { side.call(HOLD_CELL) { check_hold(text, functions: functions.call, xhci: xhci) } } }.freeze,
       { name: 'pcie-walk', pattern: answer('pcie_walk'), seconds: WALK_SECONDS,
         verify: ->(text) { side.call(WALK_CELL) { check_walk(text, functions: functions.call) } } }.freeze,
       { name: 'pcie-memory', pattern: answer('pcie_memory'), seconds: MEMORY_SECONDS,
         verify: ->(text) { note.call(memory_note(text)) } }.freeze].freeze
    end

    # Boots the image under HVF at each CPU count, where placement puts each cell. Returns
    # { "<accel>-<n>cpu" => 'passed', and each case's "<accel>-<n>cpu<side>" => 'passed' or
    # 'failed', its reason in notes }; a boot that does not reach every answer raises.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64',
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
        @machine = MediumBoot.machine(platform)
        @xhci = PcieDomain.xhci(platform)
        @manifest = PcieDomain.manifest(PcieDomain.manifest_source(@root, platform: platform))
        @notes = []
      end

      # Why each failed case failed, and the memory measured.
      def notes = @notes.dup.freeze

      # Packs the image once, then boots it at each CPU count.
      def call(cpus:, jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/pcie/image'))
        built, = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, machine: @machine,
                                     fiasco: fiasco)
                                .build_medium(directory: directory, machine: @machine, manifest_source: @manifest)
        booted = placement.each(accels: [QemuCells::LOCAL_ACCELERATOR], cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu", boot(accel, count, remote, built)]
        end
        booted.flat_map { |cell, sides| [[cell, 'passed'], *sides.map { |side, status| ["#{cell}#{side}", status] }] }.to_h
      end

      private

      # One boot to the command shell, then the line's answers; returns each case's status, by
      # its suffix. The run's directory is made afresh and owner-only, so the QMP socket
      # QEMU creates in it is the harness's alone.
      def boot(accel, count, remote, built)
        cell = "#{accel}-#{count}cpu"
        path = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/pcie', cell))
        boot = OutputDirectory.prepare(root: @root, path: path, mode: 0o700)
        pcie = QemuPlan::Pcie.new(qmp_socket: File.join(boot, 'qmp.sock'), functions: { @xhci.slot => 'qemu-xhci' })
        sides = SIDE_CELLS.to_h { |side| [side, 'failed'] }
        side = lambda do |suffix, &check|
          check.call
          sides[suffix] = 'passed'
        rescue Error => e
          @notes << "#{cell}#{suffix}: #{e.message}"
        end
        functions = lambda do
          client = Qmp.connect(pcie.qmp_socket)
          client.pci_functions
        ensure
          client&.close
        end
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: count,
                                                         manifest_source: @manifest, memory_mib: @machine.memory_mib)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(platform: @machine.platform, accel: accel, cpus: count, remote: remote, image: built.single,
                 memory_mib: @machine.memory_mib, directory: boot, pcie: pcie,
                 checkpoints: PcieDomain.checkpoints(points, xhci: @xhci, functions: functions, side: side,
                                                     note: ->(text) { @notes << "#{cell}: #{text}" }))
        sides
      end
    end
  end
end
