# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bl31'
require_relative 'error'
require_relative 'qemu'

module Erx
  # The raspi4b suite's stand-in for the Pi firmware's framebuffer setup
  # (docs/design-platforms.md, "The firmware's framebuffer under QEMU"). Test harness only:
  # nothing of erXos links, packs or ships what it builds.
  #
  # On the board the firmware asks the VideoCore for an HDMI framebuffer and describes it in
  # the tree it hands on, a simple-framebuffer node under /chosen; QEMU's raspi4b model runs no
  # firmware. The stand-in plays that part in two halves: build writes the node into a copy of
  # the model's tree with placeholder cells, and compiles test/raspi4b/firmware_fb.c, the
  # program CPU 0 runs before BL31, with the address of each placeholder cell in the tree as
  # QEMU loads it. The program asks the model's mailbox property interface for FORMAT's screen
  # of WIDTH by HEIGHT and writes the base, size, width, height and pitch it answers into those
  # cells, so the tree holds what the model gave, as the firmware's would.
  module Raspi4bFirmwareFb
    SOURCE = 'test/raspi4b/firmware_fb.c'
    PROGRAM = 'firmware-fb.elf'
    TREE = 'firmware-fb.dtb'
    # Where CPU 0 starts (the ELF's entry, QEMU's generic loader with cpu-num): past the tree's
    # address and the 1 MiB BL31 grows it into, so neither the files QEMU loads nor the tree
    # BL31 opens meet the program, whose stack grows down from its first byte.
    ADDRESS = 0x8200000
    # A small screen, so the screen's flushes are cheap under TCG.
    WIDTH = 640
    HEIGHT = 480
    # The pixel order the program asks for, BGR (the property interface's "Set pixel order",
    # 0), and the simple-framebuffer format of its 32-bit pixels as the model shows them: a
    # probe's word 0x00ff0000 shows red under BGR and blue under RGB, so BGR's words hold red
    # in bits 23:16, green in 15:8 and blue in 7:0, which is x8r8g8b8.
    ORDER = 0
    FORMAT = 'x8r8g8b8'
    PARENT = '/chosen'
    NODE = "#{PARENT}/framebuffer".freeze
    # The words the program overwrites. Each is unique in the tree (cell_addresses checks), and
    # left in place they name a framebuffer far outside any window, which the root refuses.
    PLACEHOLDERS = { reg: [0xfbfb0001, 0xfbfb0002, 0xfbfb0003], width: [0xfbfb0004],
                     height: [0xfbfb0005], stride: [0xfbfb0006] }.freeze
    Built = Data.define(:program, :tree)

    module_function

    # The fdtput argument vectors, after the program's name, that add the node to tree: /chosen's
    # cell sizes, which reg's three cells follow, and the binding's properties, its four
    # numbers as placeholders.
    def node_edits(tree)
      cells = PLACEHOLDERS.transform_values { |words| words.map(&:to_s) }
      [['-t', 'u', tree, PARENT, '#address-cells', '2'],
       ['-t', 'u', tree, PARENT, '#size-cells', '1'],
       ['-c', tree, NODE],
       ['-t', 's', tree, NODE, 'compatible', 'simple-framebuffer'],
       ['-t', 'u', tree, NODE, 'reg', *cells.fetch(:reg)],
       ['-t', 'u', tree, NODE, 'width', *cells.fetch(:width)],
       ['-t', 'u', tree, NODE, 'height', *cells.fetch(:height)],
       ['-t', 'u', tree, NODE, 'stride', *cells.fetch(:stride)],
       ['-t', 's', tree, NODE, 'format', FORMAT]].map(&:freeze).freeze
    end

    # Each placeholder's first cell as an address in the tree loaded at load: bytes is the tree
    # file. Raises unless each placeholder occurs once, on a cell's 4-byte boundary.
    def cell_addresses(bytes, load:)
      PLACEHOLDERS.to_h do |name, words|
        needle = words.pack('N*')
        at = bytes.b.index(needle)
        raise Error, "firmware framebuffer: the tree holds no #{name} placeholder" if at.nil?
        raise Error, "firmware framebuffer: the tree holds the #{name} placeholder twice" if bytes.b.index(needle, at + 1)
        raise Error, "firmware framebuffer: the #{name} placeholder is off a cell boundary" unless (at % 4).zero?

        [name, load + at]
      end
    end

    # The program's macros for the cells at addresses (cell_addresses).
    def defines(addresses)
      { 'FB_WIDTH' => WIDTH, 'FB_HEIGHT' => HEIGHT, 'FB_ORDER' => ORDER,
        'FB_REG_CELLS' => addresses.fetch(:reg), 'FB_WIDTH_CELL' => addresses.fetch(:width),
        'FB_HEIGHT_CELL' => addresses.fetch(:height), 'FB_STRIDE_CELL' => addresses.fetch(:stride) }
        .map { |name, value| format('-D%s=0x%xu', name, value) }.freeze
    end

    # The compile and link argument vectors for the program at output, its object at object.
    def build_argvs(compiler:, linker:, source:, object:, output:, defines:)
      [[compiler, '--target=aarch64-none-elf', '-std=c17', '-ffreestanding', '-fno-pic', '-mgeneral-regs-only',
        '-O2', '-Wall', '-Werror', *defines, '-c', source, '-o', object],
       [linker, '-static', '-nostdlib', '-N', '-Ttext', format('0x%x', ADDRESS),
        '-e', 'firmware_fb_entry', object, '-o', output]].map(&:freeze).freeze
    end

    # Writes the node into a copy of model and builds the program for it, in directory.
    def build(root:, runner:, compiler:, linker:, model:, directory:)
      raise Error, 'the firmware framebuffer stand-in needs ERX_CLANG and ERX_LLD' if compiler.empty? || linker.empty?

      loads = QemuPlan::MACHINES.fetch('raspi4b').loads
      raise Error, 'the firmware framebuffer stand-in lies inside the tree BL31 grows' if ADDRESS < loads.dtb + Bl31::DTB_WINDOW

      tree = File.join(directory, TREE)
      FileUtils.cp(model, tree)
      node_edits(tree).each_with_index do |edit, index|
        runner.run(['fdtput', *edit], name: "raspi4b-firmware-fb-node-#{index}", deadline: 30)
      end
      program = File.join(directory, PROGRAM)
      argvs = build_argvs(compiler: compiler, linker: linker, source: File.join(root, SOURCE),
                          object: File.join(directory, 'firmware-fb.o'), output: program,
                          defines: defines(cell_addresses(File.binread(tree), load: loads.dtb)))
      argvs.zip(%w[compile link]).each { |argv, step| runner.run(argv, name: "raspi4b-firmware-fb-#{step}", deadline: 60) }
      Built.new(program: program, tree: tree)
    end
  end
end
