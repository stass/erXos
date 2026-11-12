# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/board_tree'

# The Raspberry Pi 4's device trees (Erx::BoardTree): the firmware's edits computed from
# the platform record, and the trees built from Linux's pinned sources, the board's with
# config.txt's overlay applied and the model's with the firmware's edits written too.
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

  def test_stdout_path_names_the_records_console
    assert_equal '/soc/serial@7e215040:115200n8', Erx::BoardTree.stdout_path(PI)
  end

  def test_the_console_becomes_serial0_and_trades_places
    assert_equal({ 'serial0' => '/soc/serial@7e215040', 'serial1' => '/soc/serial@7e201000' },
                 Erx::BoardTree.serial_aliases(PI, serial0: '/soc/serial@7e201000', serial1: '/soc/serial@7e215040'))
    assert_equal({ 'serial0' => '/soc/serial@7e215040', 'serial1' => '/x' },
                 Erx::BoardTree.serial_aliases(PI, serial0: '/soc/serial@7e215040', serial1: '/x'))
  end

  def test_builds_the_board_and_model_trees
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::BoardTree.build(root: ROOT, runner: runner, platform: PI, compiler: ENV.fetch('ERX_CLANG', 'clang'))

    # The board's tree leaves the memory node and the console to the firmware.
    assert_equal '0 0 0', fdtget(built.board, '/memory@0', 'reg')
    assert_equal 'serial1:115200n8', fdtget(built.board, '/chosen', 'stdout-path')
    assert_equal "0 0 #{0x3b400000}", fdtget(built.model, '/memory@0', 'reg')
    assert_equal '/soc/serial@7e215040:115200n8', fdtget(built.model, '/chosen', 'stdout-path')
    # BL31 points stdout-path at serial0, which the firmware makes the console.
    assert_equal '/soc/serial@7e201000', fdtget(built.board, '/aliases', 'serial0')
    assert_equal '/soc/serial@7e215040', fdtget(built.model, '/aliases', 'serial0')
    assert_equal '/soc/serial@7e201000', fdtget(built.model, '/aliases', 'serial1')
    # The board's tree ships as Linux's source compiles it, which the firmware overlays;
    # the model's has config.txt's overlay applied.
    assert_equal 'disabled', fdtget(built.board, '/soc/serial@7e201600', 'status')
    assert_equal 'okay', fdtget(built.model, '/soc/serial@7e201600', 'status'), 'UART3 is on'
    assert_equal 'disabled', fdtget(built.model, '/soc/serial@7e201400', 'status'), 'UART2 stays off'
    source = File.read(built.source)
    assert_includes source, 'serial@7e215040'
    refute_includes source, ROOT, 'the shipped source carries no host path'
    assert_equal ['uart3'], built.overlays.keys
    assert File.file?(built.overlays.fetch('uart3'))
  end

  private

  def fdtget(tree, node, property)
    text, status = Open3.capture2e('fdtget', '-t', property == 'reg' ? 'u' : 's', tree, node, property, stdin_data: '')
    assert status.success?, text
    text.strip
  end
end
