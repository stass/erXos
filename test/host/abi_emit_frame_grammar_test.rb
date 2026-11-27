# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/abi_emit_frame_grammar'

# sort_list/5 ends in each order a sorter passes and in no other: a list that is not
# ascending but holds sorting elements passes false, and without its clause the
# builder would hand back the list with its elements unsorted.
class AbiEmitFrameGrammarTest < Minitest::Test
  Emitter = Erx::ABI::FrameGrammarEmitter

  def sort_list(kinds) = Emitter.new({ kinds: kinds, frames: [], refers: [] }, frame_max: 1).send(:sort_list).join

  def test_each_order_a_sorter_passes_has_its_end_clause
    kinds = { 'ids' => { form: 'list', ascending: true, element: 'u8' },
              'groups' => { form: 'list', ascending: false, element: 'ids' } }
    clauses = sort_list(kinds)
    assert_includes clauses, "sort_list(_, true, [], _, Done) ->\n    lists:sort(Done);"
    assert_includes clauses, "sort_list(_, false, [], _, Done) ->\n    lists:reverse(Done);"
  end

  def test_an_order_no_sorter_passes_has_no_clause
    clauses = sort_list({ 'ids' => { form: 'list', ascending: true, element: 'u8' } })
    refute_includes clauses, 'sort_list(_, false'
  end

  def test_no_sorting_list_needs_no_sort_list
    assert_equal '', sort_list({ 'bytes' => { form: 'list', ascending: false, element: 'u8' } })
  end
end
