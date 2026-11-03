# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/stack_proof_input'

# The stack proof's declaration files are read whole or refused with the
# file and line, and the tree's own files read.
class StackProofInputTest < Minitest::Test
  Input = Erx::StackProofInput
  ROOT = File.expand_path('../..', __dir__)
  BUDGET = <<~TEXT
    # comment
    block 8192
    allowance call 2048   # trailing comment
    allowance tick 1024
    tick erx_watchdog_step
    leaf memcpy 64
    leaf erx_effect_store 0
  TEXT

  def test_a_budget_is_read
    budget = Input.budget(BUDGET, path: 'budget.txt')
    assert_equal 8192, budget.block_bytes
    assert_equal({ 'call' => 2048, 'tick' => 1024 }, budget.allowances)
    assert_equal %w[erx_watchdog_step], budget.tick_entries
    assert_equal({ 'memcpy' => 64, 'erx_effect_store' => 0 }, budget.leaves)
  end

  def test_malformed_budgets_are_refused
    {
      BUDGET.sub('block 8192', '') => 'budget.txt: no block declaration',
      "#{BUDGET}block 4096\n" => 'budget.txt:8: block is declared twice',
      BUDGET.sub('block 8192', 'block 8192 bytes') => 'budget.txt:2: block takes one value',
      BUDGET.sub('block 8192', 'block 08192') => '08192 is not a byte count',
      BUDGET.sub('block 8192', 'block 0') => '0 is not a byte count from 1',
      BUDGET.sub('leaf memcpy 64', 'leaf memcpy 99999999') => '99999999 is not a byte count',
      BUDGET.sub('allowance tick 1024', '') => 'budget.txt: no tick allowance',
      BUDGET.sub('allowance tick 1024', 'allowance call 1024') => 'the call allowance is declared twice',
      BUDGET.sub('allowance tick 1024', 'allowance irq 1024') => 'unknown role irq; the roles are call and tick',
      BUDGET.sub('allowance tick 1024', 'allowance tick 9000') => 'the tick allowance exceeds the 8192-byte block',
      BUDGET.sub('allowance tick 1024', 'allowance tick') => 'allowance takes a role and a byte count',
      BUDGET.sub('tick erx_watchdog_step', '') => 'budget.txt: no tick entry',
      "#{BUDGET}tick erx_watchdog_step\n" => 'tick entry erx_watchdog_step is declared twice',
      "#{BUDGET}leaf memcpy 8\n" => 'leaf memcpy is declared twice',
      "#{BUDGET}tick 9lives\n" => '9lives is not a C identifier',
      "#{BUDGET}leaf 9lives 8\n" => 'leaf 9lives is no erx_effect_* function, memcpy or memset',
      "#{BUDGET}leaf fiasco_anything 0\n" => 'leaf fiasco_anything is no erx_effect_* function',
      "#{BUDGET}stack 8\n" => 'budget.txt:8: unknown declaration stack',
      "#{BUDGET}leaf \e[31m 8\n" => 'not a printable ASCII file',
      BUDGET + ('#' * 70_000) => 'not a printable ASCII file of at most 65536 bytes'
    }.each do |text, expected|
      error = assert_raises(Erx::StackProofError, expected) { Input.budget(text, path: 'budget.txt') }
      assert_includes error.message, expected
    end
  end

  def test_targets_are_read
    targets = Input.targets("indirect erx_dispatch erx_sys_a erx_sys_b # handlers\n\n", path: 'targets.txt')
    assert_equal({ 'erx_dispatch' => %w[erx_sys_a erx_sys_b] }, targets.callers)
  end

  def test_malformed_targets_are_refused
    {
      "indirect erx_dispatch\n" => 'targets.txt:1: indirect needs a function and at least one target',
      "indirect erx_dispatch a\nindirect erx_dispatch b\n" => 'targets.txt:2: erx_dispatch is declared twice',
      "indirect erx_dispatch a a\n" => 'erx_dispatch lists a target twice',
      "indirect erx_dispatch a-b\n" => 'a-b is not a C identifier',
      "routine erx_entry 64\n" => 'targets.txt:1: unknown declaration routine'
    }.each do |text, expected|
      error = assert_raises(Erx::StackProofError, expected) { Input.targets(text, path: 'targets.txt') }
      assert_includes error.message, expected
    end
  end

  def test_the_trees_declarations_are_read
    budget = Input.budget(File.read(File.join(ROOT, 'kernel/stack_fiasco.txt')), path: 'kernel/stack_fiasco.txt')
    assert_equal 8192, budget.block_bytes
    assert_includes budget.tick_entries, 'erx_watchdog_step'
    assert_equal %w[memcpy memset], budget.leaves.keys.sort
    targets = Input.targets(File.read(File.join(ROOT, 'kernel/stack_targets.txt')), path: 'kernel/stack_targets.txt')
    assert_empty targets.callers
  end
end
