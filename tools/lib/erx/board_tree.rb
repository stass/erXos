# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'error'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'runner'
require_relative 'source_revision'

module Erx
  # A board's device tree, compiled on the host from Linux's sources at deps.lock's pin
  # `linux-dts` (docs/design.md, the dependency table; docs/design-fiasco.md, "The
  # Raspberry Pi 4"):
  #
  # * the board's tree, compiled from Linux's source with one edit, the serial aliases,
  #   and with that source, as preprocessed and edited, beside it, since the tree is
  #   GPL-2.0 and ships as a file of its own. The source keeps Linux's comments, its
  #   license and copyright lines among them, and opens with the notice GPL-2.0's
  #   section 2(a) asks of a changed file: that erXos changed it, how, and when, the date
  #   of the commit it was built from (edit_notice). Linux's GPL-2.0 text ships beside
  #   them (Built#license). The firmware loads the tree, applies the
  #   overlays config.txt names and fills its memory node; it leaves the aliases as
  #   they are. BL31 points /chosen/stdout-path at serial0 (TF-A's
  #   plat/rpi/rpi4/rpi4_setup.c), so the board's serial0 must be the console's UART:
  #   the edit makes it so, and the build refuses a record whose console is not it;
  # * each overlay config.txt names, compiled from erXos's source in hw/dts;
  # * the model's tree: what the firmware makes of the card's files, since no firmware
  #   runs under QEMU: the board's tree with the overlays applied, the memory node
  #   written from the platform record and the nodes of devices the model does not
  #   answer at disabled (Board#unmodelled), and nothing else, so BL31 picks the
  #   console's UART on the model from the same aliases as on the board.
  #
  # The source is run through the C preprocessor, as Linux's build does but keeping
  # comments (-C), the notice prepended and the alias edit appended; dtc compiles it
  # with symbols (-@) so overlays apply; fdtoverlay
  # applies them and fdtput writes the memory node and disables the unmodelled nodes.
  module BoardTree
    SOURCE_ID = 'linux-dts'
    OUTPUT = 'build/board-tree'
    DEADLINE = 60

    # source: the board's tree in the Linux tree; file: the name the firmware loads it
    # by; memory: the memory node the firmware fills; unmodelled: the nodes of devices
    # QEMU's model of the board does not answer at, which the model's tree disables;
    # aliases: the serial aliases the board's tree carries in place of Linux's; overlays:
    # config.txt's dtoverlay names and erXos's source of each. The Pi's aliases swap
    # Linux's two: serial0 is the mini UART, the console on GPIO 14 and 15, and serial1 the
    # PL011 UART0, which the board wires to its Bluetooth chip.
    Board = Data.define(:source, :file, :memory, :unmodelled, :aliases, :overlays)
    BOARDS = {
      'raspi4b' => Board.new(source: 'arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts', file: 'bcm2711-rpi-4-b.dtb',
                             memory: '/memory@0',
                             # QEMU's model never completes a read at the RNG200's registers, and it is
                             # not known to count the power-management watchdog's timeout down and take its
                             # reloads (it resets at BL31's ten ticks), so the root arms that on the board alone.
                             unmodelled: ['/soc/rng@7e104000', '/soc/watchdog@7e100000'].freeze,
                             aliases: { 'serial0' => '/soc/serial@7e215040', 'serial1' => '/soc/serial@7e201000' }.freeze,
                             overlays: { 'uart3' => 'hw/dts/raspi4b-uart3.dtso' }.freeze)
    }.freeze

    # board: the board's tree; source: its preprocessed source; license: Linux's GPL-2.0
    # text, which covers both; overlays: each overlay's compiled file by its name; model:
    # the tree the QEMU model boots with.
    Built = Data.define(:board, :source, :license, :overlays, :model)
    # Linux's GPL-2.0 text in its tree (deps.lock's linux-dts members name it).
    LICENSE = 'LICENSES/preferred/GPL-2.0'
    # The name it ships by, beside the board's tree and source.
    LICENSE_FILE = 'LICENSE.linux-dts'
    # The boot CPU's node under /cpus, the one a one-CPU tree keeps, and any CPU's.
    BOOT_CPU = 'cpu@0'
    CPU_NODE = /\Acpu@\h+\z/

    module_function

    def board(platform) = BOARDS.fetch(platform.name) { raise Error, "platform #{platform.name} has no board tree" }

    # The platform's board, for a record whose console is the board tree's serial0, the
    # UART that BL31's stdout-path and so every stage after it writes. Any other console
    # is refused: the card would print to one UART and the root task expect another.
    def console_board(platform)
      board = board(platform)
      console = platform.record.fetch('console')
      serial0 = board.aliases.fetch('serial0')
      return board if console == serial0

      raise Error, "platform #{platform.name}: the console #{console} is not serial0 of the board's tree, " \
                   "#{serial0}, which BL31's stdout-path names"
    end

    # The source appended to Linux's preprocessed tree: the board's serial aliases, which
    # replace Linux's, since a later definition of a property wins. dtc refuses an alias
    # whose node the tree lacks (-E alias_paths), and a path that is not a plain node
    # path is refused here, before it is quoted.
    def alias_source(board)
      aliases = board.aliases.map do |name, path|
        raise Error, "board tree: alias #{name} is not a node path" unless path.match?(%r{\A/[A-Za-z0-9,._+@/-]*\z})

        "\t\t#{name} = \"#{path}\";"
      end
      ['', '/* erXos edit: the serial aliases, serial0 naming the console (tools/lib/erx/board_tree.rb). */',
       '/ {', "\taliases {", *aliases, "\t};", '};'].map { |line| "#{line}\n" }.join
    end

    # The notice that opens the edited source: that erXos changed the file, the one change
    # (alias_source), and its date, the committer date of the source revision the build is
    # of (SourceRevision), so one commit gives one notice. A tree that is no git checkout
    # has no revision, and the notice says the date is not recorded rather than make one up.
    def edit_notice(board, revision:)
      when_changed = if revision
                       "on #{revision.committed_at.strftime('%Y-%m-%d')}, at erXos source revision #{revision}"
                     else
                       'on a date this build does not record, since its erXos source is no git checkout'
                     end
      ['/*', " * Changed by erXos #{when_changed}: this file is Linux's #{board.source},",
       ' * run through the C preprocessor, with the serial aliases at its end replacing',
       " * Linux's (tools/lib/erx/board_tree.rb). It is distributed under GPL-2.0, whose",
       " * text is #{LICENSE_FILE} beside it.", ' */', ''].map { |line| "#{line}\n" }.join
    end

    # The cells of the memory node's reg for RAM as the record states it, in the tree's
    # root #address-cells and #size-cells: each number split into 32-bit cells, most
    # significant first. A number the cells cannot hold is refused.
    def memory_cells(platform, address_cells:, size_cells:)
      { 'ram_first' => address_cells, 'ram_bytes' => size_cells }.flat_map do |field, cells|
        value = platform.record.fetch(field)
        raise Error, "#{field} does not fit the tree's #{cells} cells" unless cells.between?(1, 2) && value < (1 << (32 * cells))

        (cells - 1).downto(0).map { |index| (value >> (32 * index)) & 0xffff_ffff }
      end
    end

    # The GIC's interrupt types in a tree's interrupts cells, with the interrupt number each
    # one's first line has (the GIC binding: SPIs from 32, PPIs from 16).
    GIC_FIRST_LINE = { 0 => 32, 1 => 16 }.freeze

    # What each device-tree device of platform's record says differently from the board's
    # tree: a node the tree lacks, a compatible list that does not name the record's, or a
    # base, size or line other than the node's; of a framebuffer row only a lacking node. nodes maps a path to the node's
    # compatible strings, reg cells, GIC interrupts cells and its bus's #address-cells and
    # #size-cells; ranges maps each bus's path to its ranges, each [bus address, CPU
    # address, size], which turn the node's bus address into the CPU's, as the record
    # states it. The record's line is the node's first interrupt, 0 for a node with none: a
    # device with more, as GENET's second line is, gives its driver the first alone, and no
    # unit holds the rest.
    def device_problems(platform, nodes:, ranges:)
      devices = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
      devices.select { |device| device.fetch('selector') == 'dt' }.filter_map do |device|
        path = device.fetch('path')
        node = nodes[path]
        next "#{path}: not in the device tree" unless node
        # A framebuffer row's path is the node the firmware adds its framebuffer under and its
        # window memory no node describes (docs/design-device-tree.md, "The framebuffer
        # record"), so only the node is the board tree's to have.
        next if device.fetch('role') == 'framebuffer'
        next "#{path}: compatible #{node.fetch(:compatible)} does not name #{device.fetch('compatible')}" unless
          node.fetch(:compatible).include?(device.fetch('compatible'))

        tree = window(node, ranges.fetch(File.dirname(path), []))
        recorded = device.slice('base', 'size', 'line').transform_keys(&:to_sym)
        "#{path}: base, size or line #{recorded} differ from the tree's #{tree || 'unreadable reg or interrupts'}" if
          recorded != tree
      end
    end

    # A node's base on the CPU, size and line of its first register range, as
    # erx_dt_registers reads it, or nil when its reg is not whole bus addresses and sizes,
    # each in its bus's cells, or its first lies in no range, or its interrupts are neither
    # GIC interrupts nor none. A node with no interrupts, as the RNG200's, raises none, and the record states
    # its line as 0 (docs/design-abi.md, "Devices and partition windows").
    def window(node, ranges)
      reg = node.fetch(:reg)
      address_cells = node.fetch(:address_cells)
      interrupts = node.fetch(:interrupts)
      type, number, = interrupts
      entry = address_cells + node.fetch(:size_cells)
      return nil unless !reg.empty? && (reg.size % entry).zero? &&
                        (interrupts.empty? || ((interrupts.size % 3).zero? && GIC_FIRST_LINE.key?(type)))

      bus, size = [reg.take(address_cells), reg.take(entry).drop(address_cells)].map { |cells| number_of(cells) }
      range = ranges.find { |first, _, length| bus >= first && bus + size <= first + length }
      line = interrupts.empty? ? 0 : GIC_FIRST_LINE.fetch(type) + number
      range && { base: range[1] + (bus - range[0]), size: size, line: line }
    end

    # The number a run of 32-bit cells holds, most significant first.
    def number_of(cells) = cells.reduce(0) { |value, cell| (value << 32) | cell }

    # Builds the board's tree, its overlays and the model's tree into build/board-tree/NAME,
    # replacing what was there, the source's notice dated from revision (edit_notice).
    def build(root:, runner:, platform:, revision:, compiler: ENV.fetch('ERX_CLANG', ''))
      raise Error, 'the board tree needs ERX_CLANG, whose preprocessor reads Linux\'s tree' if compiler.empty?

      board = console_board(platform)
      tree = Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID)
      parent = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      destination = File.join(parent, platform.name)
      Dir.mktmpdir(".#{platform.name}-", parent) do |work|
        output = File.join(work, 'out')
        FileUtils.mkdir_p(File.join(output, 'overlays'))
        compile = Compile.new(runner: runner)
        source = compile.preprocess(compiler: compiler, linux: tree, source: File.join(tree, board.source),
                                    output: File.join(output, source_file(board)))
        File.write(source, edit_notice(board, revision: revision) + File.read(source) + alias_source(board))
        FileUtils.cp(File.join(tree, LICENSE), File.join(output, LICENSE_FILE))
        base = compile.dtc(source, File.join(output, board.file))
        overlays = board.overlays.to_h do |name, overlay|
          [name, compile.dtc(File.join(root, overlay), File.join(output, 'overlays', "#{name}.dtbo"))]
        end
        model = File.join(output, 'model.dtb')
        compile.run(['fdtoverlay', '-i', base, '-o', model, *overlays.values], 'fdtoverlay')
        cells = %w[#address-cells #size-cells].map { |name| compile.cell(model, '/', name) }
        compile.run(['fdtput', '-t', 'u', model, board.memory, 'reg',
                     *memory_cells(platform, address_cells: cells[0], size_cells: cells[1]).map(&:to_s)], 'fdtput-memory')
        board.unmodelled.each { |node| compile.run(['fdtput', '-t', 's', model, node, 'status', 'disabled'], 'fdtput-unmodelled') }
        raise Error, "board tree output is a symbolic link: #{destination}" if File.symlink?(destination)

        FileUtils.rm_rf(destination)
        File.rename(output, destination)
      end
      Built.new(board: File.join(destination, board.file), source: File.join(destination, source_file(board)),
                license: File.join(destination, LICENSE_FILE), model: File.join(destination, 'model.dtb'),
                overlays: board.overlays.keys.to_h { |name| [name, File.join(destination, 'overlays', "#{name}.dtbo")] })
    end

    # The CPU nodes of /cpus that a one-CPU tree removes, from the names fdtget -l prints
    # there: every cpu@N but the boot CPU's, which must be among them. Pure.
    def other_cpus(names)
      raise Error, "the board's tree has no #{BOOT_CPU} under /cpus" unless names.include?(BOOT_CPU)

      names.grep(CPU_NODE) - [BOOT_CPU]
    end

    # built with its board tree replaced by a copy in one-cpu/ beside it that keeps only
    # the boot CPU's node, so a kernel that starts the CPUs its tree lists starts one
    # (docs/design-bench.md, "L4Re on the board"). The source shipped beside it is the
    # whole board's; the set's record says the tree was cut.
    def boot_cpu_only(built, runner:)
      directory = File.join(File.dirname(built.board), 'one-cpu')
      FileUtils.mkdir_p(directory)
      tree = File.join(directory, File.basename(built.board))
      FileUtils.cp(built.board, tree)
      compile = Compile.new(runner: runner)
      others = other_cpus(compile.subnodes(tree, '/cpus'))
      compile.run(['fdtput', '-r', tree, *others.map { |name| "/cpus/#{name}" }], 'fdtput-cpus') unless others.empty?
      built.with(board: tree)
    end

    # The preprocessed source shipped beside the board's tree: its name with .dts.
    def source_file(board) = "#{File.basename(board.file, '.dtb')}.dts"

    # deps.lock's pin of Linux's tree, and the recipe that builds from it: what a build
    # record of the board's tree names (BootPartition.record).
    def source_record(root:)
      DependencySchema.parse(File.binread(File.join(root, 'deps.lock')))
                      .find { |source| source.fetch('id') == SOURCE_ID } ||
        raise(Error, "deps.lock has no #{SOURCE_ID} source")
    end

    def recipe_path = __FILE__

    # The dtc the build runs: the first on PATH, as the runner finds it.
    def dtc_path
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |directory| File.join(directory, 'dtc') }
         .find { |path| File.file?(path) && File.executable?(path) } || raise(Error, 'the board tree needs dtc on PATH')
    end

    # The commands of one build, each under the runner's deadline and log.
    Compile = Data.define(:runner) do
      # Linux's tree through the C preprocessor, as its build runs it, into one source
      # file. -P leaves out line markers, which would carry this host's paths; -C keeps
      # the comments, so each file's license and copyright lines reach the shipped source.
      def preprocess(compiler:, linux:, source:, output:)
        run([compiler, '-E', '-P', '-C', '-nostdinc', '-undef', '-D__DTS__', '-x', 'assembler-with-cpp',
             '-I', File.join(linux, 'include'), '-I', File.dirname(source), '-o', output, source], 'dts-cpp')
        output
      end

      def dtc(source, output)
        run(['dtc', '-q', '-E', 'alias_paths', '-@', '-I', 'dts', '-O', 'dtb', '-o', output, source], 'dtc')
        output
      end

      # A one-cell number property of the tree, as fdtget prints it.
      def cell(tree, node, property)
        log = run(['fdtget', '-t', 'u', tree, node, property], 'fdtget').fetch('log')
        text = BoundedFile.read(log, maximum: 64)
        raise Error, "#{node} #{property} is not one number" unless text.match?(/\A\d{1,10}\n?\z/)

        Integer(text, 10)
      end

      # The names of node's subnodes, as fdtget -l prints them.
      def subnodes(tree, node)
        log = run(['fdtget', '-l', tree, node], 'fdtget-list').fetch('log')
        names = BoundedFile.read(log, maximum: 4096).split("\n")
        raise Error, "#{node}'s subnodes are not node names" unless names.all? { |name| name.match?(/\A[A-Za-z0-9,._+@-]{1,64}\z/) }

        names
      end

      def run(argv, name) = runner.run(argv, name: "board-tree-#{name}", deadline: DEADLINE)
    end
  end
end
