# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The device-tree reader over libfdt with every check on (FDT_ASSUME_MASK=0). An
# input is a tree's bytes, handed over in a buffer of exactly their length. The
# seeds are small trees in the shapes test/host/dt_test.rb covers, written here
# by FdtSeed: a device under a bus with one-cell dma-ranges over the two-cell
# root, the same under a gap without dma-ranges, a PCIe bridge, coherence marks,
# hardware addresses, a framebuffer, a nested chain, and a truncated tree.
# libfdt's writers (fdt_rw.c, fdt_wip.c) link only because fdt_addresses.c holds
# one; the reader writes nothing.
module FdtSeed
  module_function

  MAGIC = 0xd00dfeed
  HEADER = 40

  # A node: name, properties as name => bytes, children.
  Node = Data.define(:name, :props, :children)

  def node(name, props = {}, children = []) = Node.new(name: name, props: props, children: children)
  def cells(*values) = values.pack('N*')
  def string(text) = "#{text}\0".b

  # The flattened tree of root: header, empty reservation map, structure, strings.
  def blob(root)
    strings = +''.b
    offsets = {}
    structure = emit(root, strings, offsets) + cells(9)
    reserve = "\0".b * 16
    total = HEADER + reserve.bytesize + structure.bytesize + strings.bytesize
    [MAGIC, total, HEADER + reserve.bytesize, HEADER + reserve.bytesize + structure.bytesize, HEADER, 17, 16, 0,
     strings.bytesize, structure.bytesize].pack('N*') + reserve + structure + strings
  end

  def emit(tree, strings, offsets)
    name = string(tree.name)
    head = cells(1) + name + ("\0".b * ((4 - (name.bytesize % 4)) % 4))
    props = tree.props.map do |key, value|
      offset = offsets[key] ||= strings.bytesize.tap { strings << string(key) }
      cells(3, value.bytesize, offset) + value + ("\0".b * ((4 - (value.bytesize % 4)) % 4))
    end
    head + props.join.b + tree.children.map { |child| emit(child, strings, offsets) }.join.b + cells(2)
  end

  def root(*children)
    node('', { '#address-cells' => cells(2), '#size-cells' => cells(1) },
         [node('memory@0', { 'device_type' => string('memory'), 'reg' => cells(0, 0, 0x4000_0000) }), *children])
  end

  def bus(name, ranges, children) = node(name, { '#address-cells' => cells(1), '#size-cells' => cells(1), 'dma-ranges' => ranges }, children)
end

seeds = {
  'translated' => FdtSeed.root(FdtSeed.bus('bus', FdtSeed.cells(0, 0, 0, 0x1000_0000), [FdtSeed.node('dev', { 'dma-coherent' => '' })])),
  'nested' => FdtSeed.root(FdtSeed.bus('outer', FdtSeed.cells(0x1000_0000, 0, 0, 0x4000_0000),
                                       [FdtSeed.bus('inner', FdtSeed.cells(0x8000_0000, 0x1000_0000, 0x100_0000), [FdtSeed.node('dev')])])),
  'gap' => FdtSeed.root(FdtSeed.bus('outer', FdtSeed.cells(0, 0, 0, 0x1000_0000), [FdtSeed.node('inner', {}, [FdtSeed.node('dev')])])),
  'pcie' => FdtSeed.root(FdtSeed.node('pcie', { '#address-cells' => FdtSeed.cells(3), '#size-cells' => FdtSeed.cells(2),
                                                'dma-ranges' => FdtSeed.cells(0x200_0000, 0, 0, 0, 0, 0, 0x4000_0000) })),
  'marks' => FdtSeed.root(FdtSeed.node('dev', { 'dma-coherent' => FdtSeed.cells(0), 'dma-noncoherent' => '',
                                                'local-mac-address' => [2, 0x11, 0x22, 0x33, 0x44, 0x55].pack('C*') })),
  'framebuffer' => FdtSeed.root(FdtSeed.node('chosen', {}, [FdtSeed.node('framebuffer@7e000000', {
    'compatible' => FdtSeed.string('simple-framebuffer'), 'reg' => FdtSeed.cells(0, 0x7e00_0000, 0x40_0000),
    'width' => FdtSeed.cells(1920), 'height' => FdtSeed.cells(480), 'stride' => FdtSeed.cells(7680),
    'format' => FdtSeed.string('x8r8g8b8')
  })])),
  'deep' => FdtSeed.root((1..8).to_a.reverse.reduce(nil) { |child, n| FdtSeed.node("n#{n}", {}, [child].compact) })
}.transform_values { |tree| FdtSeed.blob(tree) }
seeds['truncated'] = seeds.fetch('translated').byteslice(0, 60)
seeds['header-only'] = seeds.fetch('translated').byteslice(0, 8)

Erx::PackFuzz.declare_target(
  sources: ['kernel/core/dt.c', *%w[fdt.c fdt_ro.c fdt_check.c fdt_addresses.c fdt_rw.c fdt_wip.c].map { |name| "fiasco/libfdt/lib/contrib/#{name}" }],
  includes: [*Erx::PackFuzz::INCLUDES, 'fiasco/libfdt/lib/contrib'],
  defines: ['FDT_ASSUME_MASK=0'],
  seeds: seeds
)
