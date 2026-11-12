# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/board_tree'

# The Raspberry Pi 4's device trees (Erx::BoardTree): the memory node computed from the
# platform record, the console checked against the card's serial0, and the trees built
# from Linux's pinned sources, the card's with its alias edit and the model's with
# config.txt's overlay and the memory node the firmware fills.
class BoardTreeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PI = Erx::Platform.load(root: ROOT, name: 'raspi4b')

  def record(**fields) = Erx::Platform.new(name: 'raspi4b', record: PI.record.merge(fields.transform_keys(&:to_s)))

  def test_memory_cells_split_each_number_into_the_trees_cells
    assert_equal [0, 0, 0x3b400000], Erx::BoardTree.memory_cells(PI, address_cells: 2, size_cells: 1)
    high = record(ram_first: 0x1_4000_0000, ram_bytes: 0x1_0000_0000)
    assert_equal [1, 0x4000_0000, 1, 0], Erx::BoardTree.memory_cells(high, address_cells: 2, size_cells: 2)
    assert_raises(Erx::Error) { Erx::BoardTree.memory_cells(high, address_cells: 2, size_cells: 1) }
    assert_raises(Erx::Error) { Erx::BoardTree.memory_cells(PI, address_cells: 3, size_cells: 1) }
  end

  # Seeded fault: a console the card's tree does not name serial0, such as the PL011
  # UART0 that Linux's tree names so, is refused before anything is built.
  def test_a_console_other_than_serial0_is_refused
    assert_equal '/soc/serial@7e215040', Erx::BoardTree.console_board(PI).aliases.fetch('serial0')
    pl011 = record(console: '/soc/serial@7e201000')
    assert_raises(Erx::Error) { Erx::BoardTree.console_board(pl011) }
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    assert_raises(Erx::Error) { Erx::BoardTree.build(root: ROOT, runner: runner, platform: pl011, compiler: 'clang') }
  end

  def test_builds_the_board_and_model_trees
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: PI, compiler: ENV.fetch('ERX_CLANG', 'clang'))

    # The board's tree leaves the memory node to the firmware, which the model's has filled.
    assert_equal '0 0 0', fdtget(built.board, '/memory@0', 'reg')
    assert_equal "0 0 #{0x3b400000}", fdtget(built.model, '/memory@0', 'reg')
    # BL31 points stdout-path at serial0, so the record's console must be the UART the
    # card's tree names serial0; the model's keeps the card's aliases and stdout-path.
    %w[board model].each do |tree|
      assert_equal PI.record.fetch('console'), fdtget(built.public_send(tree), '/aliases', 'serial0'), tree
      assert_equal '/soc/serial@7e201000', fdtget(built.public_send(tree), '/aliases', 'serial1'), tree
      assert_equal 'serial1:115200n8', fdtget(built.public_send(tree), '/chosen', 'stdout-path'), tree
    end
    # The board's tree ships as Linux's source compiles it, which the firmware overlays;
    # the model's has config.txt's overlay applied.
    assert_equal 'disabled', fdtget(built.board, '/soc/serial@7e201600', 'status')
    assert_equal 'okay', fdtget(built.model, '/soc/serial@7e201600', 'status'), 'UART3 is on'
    assert_equal 'disabled', fdtget(built.model, '/soc/serial@7e201400', 'status'), 'UART2 stays off'
    source = File.read(built.source)
    assert_includes source, 'serial@7e215040'
    assert_includes source, Erx::BoardTree.alias_source(Erx::BoardTree.board(PI)), 'the shipped source carries the alias edit'
    refute_includes source, ROOT, 'the shipped source carries no host path'
    assert_equal ['uart3'], built.overlays.keys
    assert File.file?(built.overlays.fetch('uart3'))
  end

  # The record's units, the mini UART's page and the PL011s', against the board's tree: each
  # device's path, compatible string, base on the CPU, size and line, as the production
  # image suite checks QEMU virt's record against QEMU's tree.
  def test_the_records_devices_match_the_board_tree
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: PI, compiler: ENV.fetch('ERX_CLANG', 'clang'))
    paths = PI.record.fetch('units').flat_map { |unit| unit.fetch('devices') }.map { |device| device.fetch('path') }
    nodes = paths.to_h do |path|
      [path, { compatible: fdtget(built.board, path, 'compatible').split, reg: cells(built.board, path, 'reg'),
               interrupts: cells(built.board, path, 'interrupts') }]
    end
    ranges = cells(built.board, '/soc', 'ranges').each_slice(4).map { |bus, high, low, size| [bus, (high << 32) | low, size] }
    assert_equal [], Erx::BoardTree.device_problems(PI, nodes: nodes, ranges: ranges)

    # Seeded faults: a line one off, a base a page off and a path the tree lacks.
    uart = PI.record.fetch('units').first.fetch('devices').first
    { 'line' => uart.fetch('line') - 1, 'base' => uart.fetch('base') + 4096, 'path' => '/soc/serial@7e215000' }
      .each do |field, value|
        units = PI.record.fetch('units').each_with_index.map do |unit, at|
          at.zero? ? unit.merge('devices' => [uart.merge(field => value), *unit.fetch('devices').drop(1)]) : unit
        end
        refute_empty Erx::BoardTree.device_problems(record(units: units), nodes: nodes, ranges: ranges), field
      end
  end

  private

  def fdtget(tree, node, property)
    text, status = Open3.capture2e('fdtget', '-t', property == 'reg' ? 'u' : 's', tree, node, property, stdin_data: '')
    assert status.success?, text
    text.strip
  end

  def cells(tree, node, property)
    text, status = Open3.capture2e('fdtget', '-t', 'u', tree, node, property, stdin_data: '')
    assert status.success?, text
    text.split.map { |cell| Integer(cell, 10) }
  end
end
