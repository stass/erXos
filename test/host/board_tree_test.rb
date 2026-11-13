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

  # A source revision, as SourceRevision reads one from git.
  REVISION = Erx::SourceRevision::Revision.new(count: 42, hash: '0123456789ab', commit: "0123456789ab#{'0' * 28}",
                                               dirty: false, committed_at: Time.utc(2026, 11, 12, 23, 30))

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
    assert_raises(Erx::Error) { Erx::BoardTree.build(root: ROOT, runner: runner, platform: pl011, compiler: 'clang', revision: REVISION) }
  end

  def test_builds_the_board_and_model_trees
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: PI, compiler: ENV.fetch('ERX_CLANG', 'clang'),
                                 revision: REVISION)

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
    # GPL-2.0, section 2(a): the changed file opens with a notice of the change and its
    # date, the commit's; it keeps Linux's licence lines, and Linux's GPL-2.0 text ships
    # beside it.
    assert source.start_with?(Erx::BoardTree.edit_notice(Erx::BoardTree.board(PI), revision: REVISION))
    assert_includes source, "Changed by erXos on 2026-11-12, at erXos source revision n42-0123456789ab: this file is " \
                            "Linux's arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts"
    assert_includes source, 'SPDX-License-Identifier: GPL-2.0'
    assert_match(/GNU GENERAL PUBLIC LICENSE\s+Version 2, June 1991/, File.read(built.licence))
    assert_equal 'LICENCE.linux-dts', File.basename(built.licence)
    assert_equal ['uart3'], built.overlays.keys
    assert File.file?(built.overlays.fetch('uart3'))
  end

  # A tree that is no git checkout has no revision, and the notice says its date is not
  # recorded rather than give one.
  def test_a_build_without_a_revision_records_no_date
    notice = Erx::BoardTree.edit_notice(Erx::BoardTree.board(PI), revision: nil)
    assert_includes notice, 'on a date this build does not record'
    refute_match(/\d{4}-\d\d-\d\d/, notice)
  end

  # The record's units, the mini UART's page, the PL011s', GENET's, the SD controllers' and the
  # framebuffer's, against the board's
  # tree: each device's path, compatible string, base on the CPU, size and line, as the
  # production image suite checks QEMU virt's record against QEMU's tree. GENET sits on
  # /scb and EMMC2 on /emmc2bus, whose two address cells and ranges differ from /soc's.
  def test_the_records_devices_match_the_board_tree
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: PI, compiler: ENV.fetch('ERX_CLANG', 'clang'),
                                 revision: REVISION)
    devices = PI.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
    paths = devices.reject { |device| device.fetch('role') == 'framebuffer' }.map { |device| device.fetch('path') }
    buses = paths.map { |path| File.dirname(path) }.uniq.to_h do |bus|
      [bus, { address_cells: cells(built.board, bus, '#address-cells').first, size_cells: cells(built.board, bus, '#size-cells').first }]
    end
    nodes = paths.to_h do |path|
      [path, { compatible: fdtget(built.board, path, 'compatible').split, reg: cells(built.board, path, 'reg'),
               interrupts: cells(built.board, path, 'interrupts'), **buses.fetch(File.dirname(path)) }]
    end
    root_cells = cells(built.board, '/', '#address-cells').first
    ranges = buses.to_h do |bus, shape|
      child = shape.fetch(:address_cells)
      [bus, cells(built.board, bus, 'ranges').each_slice(child + root_cells + shape.fetch(:size_cells)).map do |row|
        [row.take(child), row[child, root_cells], row.drop(child + root_cells)].map { |part| join_cells(part) }
      end]
    end
    assert_equal %w[/emmc2bus /scb /soc], buses.keys.sort
    # The framebuffer row's node, /chosen, which the firmware adds its framebuffer under: of
    # it the check asks only that the tree has it.
    assert_equal ['/chosen'], devices.filter_map { |device| device.fetch('path') if device.fetch('role') == 'framebuffer' }
    children, status = Open3.capture2e('fdtget', '-l', built.board, '/', stdin_data: '')
    assert status.success?, children
    nodes['/chosen'] = { compatible: [] } if children.split.include?('chosen')
    assert_equal [], Erx::BoardTree.device_problems(PI, nodes: nodes, ranges: ranges)

    # Seeded faults, on the mini UART's unit, GENET's and EMMC2's: a line one off, a base a page
    # off, a path the tree lacks, and GENET's second line in place of its first.
    seeds = { 'console-uart' => [line_off_by_one, page_off, path('/soc/serial@7e215000')],
              'net' => [line_off_by_one, page_off, path('/scb/ethernet@7d590000'), second_line],
              'sd' => [line_off_by_one, page_off, path('/emmc2bus/mmc@7e350000')] }
    seeds.each do |key, faults|
      faults.each do |name, fault|
        refute_empty Erx::BoardTree.device_problems(first_device_changed(key, &fault), nodes: nodes, ranges: ranges),
                     "#{key}: #{name}"
      end
    end
  end

  # The cells of a bus with two address cells, as /scb has: a high cell counts, and a reg
  # or interrupts property of the wrong length gives no window.
  def test_a_window_reads_every_address_cell
    scb = { address_cells: 2, size_cells: 1, compatible: [] }
    ranges = [[0x7c000000, 0xfc000000, 0x03800000], [0x6_0000_0000, 0x6_0000_0000, 0x40000000]]
    genet = scb.merge(reg: [0, 0x7d580000, 0x10000], interrupts: [0, 157, 4, 0, 158, 4])
    assert_equal({ base: 0xfd580000, size: 0x10000, line: 189 }, Erx::BoardTree.window(genet, ranges))
    assert_equal 0x6_0000_0000, Erx::BoardTree.window(genet.merge(reg: [6, 0, 0x1000]), ranges).fetch(:base)
    assert_nil Erx::BoardTree.window(genet.merge(reg: [1, 0x7d580000, 0x10000]), ranges)
    assert_nil Erx::BoardTree.window(genet.merge(reg: [0x7d580000, 0x10000]), ranges)
    assert_nil Erx::BoardTree.window(genet.merge(interrupts: [0, 157, 4, 0]), ranges)
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

  # Named faults for a device record, each a name and the change it makes.
  def line_off_by_one = ['line one off', ->(device) { device.merge('line' => device.fetch('line') - 1) }]
  def page_off = ['base a page off', ->(device) { device.merge('base' => device.fetch('base') + 4096) }]
  def path(missing) = ["path #{missing}", ->(device) { device.merge('path' => missing) }]
  def second_line = ['the second line', ->(device) { device.merge('line' => device.fetch('line') + 1) }]

  # The Pi's record with the first device of the unit named key changed by the block.
  def first_device_changed(key)
    units = PI.record.fetch('units').map do |unit|
      next unit unless unit.fetch('key') == key

      first, *rest = unit.fetch('devices')
      unit.merge('devices' => [yield(first), *rest])
    end
    record(units: units)
  end

  # The number a run of 32-bit cells holds, most significant first.
  def join_cells(cells) = cells.reduce(0) { |value, cell| (value << 32) | cell }
end
