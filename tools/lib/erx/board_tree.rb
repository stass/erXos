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

module Erx
  # A board's device tree, compiled on the host from Linux's sources at deps.lock's pin
  # `linux-dts` (docs/design.md, the dependency table; docs/design-stopgap.md, "The
  # Raspberry Pi 4"):
  #
  # * the board's tree, compiled from Linux's source unmodified, with that source, as
  #   preprocessed, beside it, since the tree is GPL-2.0 and ships as a file of its own;
  #   the firmware loads it, applies the overlays config.txt names, and edits it itself
  #   (the memory node, /chosen/stdout-path, the serial aliases);
  # * each overlay config.txt names, compiled from erXos's source in hw/dts;
  # * the model's tree: the board's with the overlays applied and the firmware's edits
  #   written here from the platform record, since no firmware runs under QEMU.
  #
  # The source is run through the C preprocessor, as Linux's build does, then dtc with
  # symbols (-@) so overlays apply; fdtoverlay applies them and fdtput writes the edits.
  module BoardTree
    SOURCE_ID = 'linux-dts'
    OUTPUT = 'build/board-tree'
    DEADLINE = 60

    # source: the board's tree in the Linux tree; file: the name the firmware loads it
    # by; memory: the memory node the firmware fills; overlays: config.txt's dtoverlay
    # names and erXos's source of each.
    Board = Data.define(:source, :file, :memory, :overlays)
    BOARDS = {
      'raspi4b' => Board.new(source: 'arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts', file: 'bcm2711-rpi-4-b.dtb',
                             memory: '/memory@0', overlays: { 'uart3' => 'hw/dts/raspi4b-uart3.dtso' }.freeze)
    }.freeze

    # board: the board's tree; source: its preprocessed source; overlays: each overlay's
    # compiled file by its name; model: the tree the QEMU model boots with.
    Built = Data.define(:board, :source, :overlays, :model)

    # The console's line setting the firmware writes after the console's path.
    CONSOLE_MODE = '115200n8'

    module_function

    def board(platform) = BOARDS.fetch(platform.name) { raise Error, "platform #{platform.name} has no board tree" }

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

    # /chosen/stdout-path as the firmware writes it: the console's path and line setting.
    def stdout_path(platform) = "#{platform.record.fetch('console')}:#{CONSOLE_MODE}"

    # The serial aliases as the firmware writes them: serial0 names the console, and the
    # alias that named the console before names what serial0 did, so the two trade places.
    # BL31 rewrites /chosen/stdout-path to serial0 (TF-A's plat/rpi/rpi4/rpi4_setup.c),
    # so on the model this alias, not stdout-path, is what picks the console.
    def serial_aliases(platform, serial0:, serial1:)
      console = platform.record.fetch('console')
      { 'serial0' => console, 'serial1' => serial1 == console ? serial0 : serial1 }
    end

    # The GIC's interrupt types in a tree's interrupts cells, with the interrupt number each
    # one's first line has (the GIC binding: SPIs from 32, PPIs from 16).
    GIC_FIRST_LINE = { 0 => 32, 1 => 16 }.freeze

    # What each device-tree device of platform's record says differently from the board's
    # tree: a node the tree lacks, a compatible list that does not name the record's, or a
    # base, size or line other than the node's. nodes maps a path to the node's
    # compatible strings, reg cells (one bus address and one size) and GIC interrupts
    # cells; ranges is the bus's ranges, each [bus address, CPU address, size], which turn
    # the node's bus address into the CPU's, as the record states it.
    def device_problems(platform, nodes:, ranges:)
      devices = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
      devices.select { |device| device.fetch('selector') == 'dt' }.filter_map do |device|
        path = device.fetch('path')
        node = nodes[path]
        next "#{path}: not in the device tree" unless node
        next "#{path}: compatible #{node.fetch(:compatible)} does not name #{device.fetch('compatible')}" unless
          node.fetch(:compatible).include?(device.fetch('compatible'))

        tree = window(node, ranges)
        recorded = device.slice('base', 'size', 'line').transform_keys(&:to_sym)
        "#{path}: base, size or line #{recorded} differ from the tree's #{tree || 'unreadable reg or interrupts'}" if
          recorded != tree
      end
    end

    # A node's base on the CPU, size and line, or nil when its cells are not one bus
    # address and size and one GIC interrupt inside a range.
    def window(node, ranges)
      reg = node.fetch(:reg)
      type, number, = node.fetch(:interrupts)
      return nil unless reg.size == 2 && node.fetch(:interrupts).size == 3 && GIC_FIRST_LINE.key?(type)

      bus, size = reg
      range = ranges.find { |first, _, length| bus >= first && bus + size <= first + length }
      range && { base: range[1] + (bus - range[0]), size: size, line: GIC_FIRST_LINE.fetch(type) + number }
    end

    # Builds the board's tree, its overlays and the model's tree into build/board-tree/NAME,
    # replacing what was there.
    def build(root:, runner:, platform:, compiler: ENV.fetch('ERX_CLANG', ''))
      raise Error, 'the board tree needs ERX_CLANG, whose preprocessor reads Linux\'s tree' if compiler.empty?

      board = board(platform)
      tree = Dependencies.new(root: root, runner: runner).fetched_tree(SOURCE_ID)
      parent = OutputDirectory.prepare(root: root, path: File.join(root, OUTPUT))
      destination = File.join(parent, platform.name)
      Dir.mktmpdir(".#{platform.name}-", parent) do |work|
        output = File.join(work, 'out')
        FileUtils.mkdir_p(File.join(output, 'overlays'))
        compile = Compile.new(runner: runner)
        source = compile.preprocess(compiler: compiler, linux: tree, source: File.join(tree, board.source),
                                    output: File.join(output, source_file(board)))
        base = compile.dtc(source, File.join(output, board.file))
        overlays = board.overlays.to_h do |name, overlay|
          [name, compile.dtc(File.join(root, overlay), File.join(output, 'overlays', "#{name}.dtbo"))]
        end
        model = File.join(output, 'model.dtb')
        compile.run(['fdtoverlay', '-i', base, '-o', model, *overlays.values], 'fdtoverlay')
        cells = %w[#address-cells #size-cells].map { |name| compile.cell(model, '/', name) }
        compile.run(['fdtput', '-t', 'u', model, board.memory, 'reg',
                     *memory_cells(platform, address_cells: cells[0], size_cells: cells[1]).map(&:to_s)], 'fdtput-memory')
        compile.run(['fdtput', '-t', 's', model, '/chosen', 'stdout-path', stdout_path(platform)], 'fdtput-chosen')
        aliases = serial_aliases(platform, serial0: compile.text(model, '/aliases', 'serial0'),
                                           serial1: compile.text(model, '/aliases', 'serial1'))
        aliases.each { |name, path| compile.run(['fdtput', '-t', 's', model, '/aliases', name, path], 'fdtput-alias') }
        raise Error, "board tree output is a symbolic link: #{destination}" if File.symlink?(destination)

        FileUtils.rm_rf(destination)
        File.rename(output, destination)
      end
      Built.new(board: File.join(destination, board.file), source: File.join(destination, source_file(board)), model: File.join(destination, 'model.dtb'),
                overlays: board.overlays.keys.to_h { |name| [name, File.join(destination, 'overlays', "#{name}.dtbo")] })
    end

    # The preprocessed source shipped beside the board's tree: its name with .dts.
    def source_file(board) = "#{File.basename(board.file, '.dtb')}.dts"

    # The commands of one build, each under the runner's deadline and log.
    Compile = Data.define(:runner) do
      # Linux's tree through the C preprocessor, as its build runs it, into one source
      # file. -P leaves out line markers, which would carry this host's paths.
      def preprocess(compiler:, linux:, source:, output:)
        run([compiler, '-E', '-P', '-nostdinc', '-undef', '-D__DTS__', '-x', 'assembler-with-cpp',
             '-I', File.join(linux, 'include'), '-I', File.dirname(source), '-o', output, source], 'dts-cpp')
        output
      end

      def dtc(source, output)
        run(['dtc', '-q', '-@', '-I', 'dts', '-O', 'dtb', '-o', output, source], 'dtc')
        output
      end

      # A one-cell number property of the tree, as fdtget prints it.
      def cell(tree, node, property)
        log = run(['fdtget', '-t', 'u', tree, node, property], 'fdtget').fetch('log')
        text = BoundedFile.read(log, maximum: 64)
        raise Error, "#{node} #{property} is not one number" unless text.match?(/\A\d{1,10}\n?\z/)

        Integer(text, 10)
      end

      # A path property of the tree, as fdtget prints it.
      def text(tree, node, property)
        log = run(['fdtget', '-t', 's', tree, node, property], 'fdtget').fetch('log')
        text = BoundedFile.read(log, maximum: 256).chomp
        raise Error, "#{node} #{property} is not a node path" unless text.match?(%r{\A/[A-Za-z0-9,._+@/-]*\z})

        text
      end

      def run(argv, name) = runner.run(argv, name: "board-tree-#{name}", deadline: DEADLINE)
    end
  end
end
