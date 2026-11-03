# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/stack_proof'
require_relative 'stack_proof_claim'

# The stack proof's analysis over hand-built call graphs: how depth adds up
# along calls and tail jumps, and one seeded graph per rule it refuses.
class StackProofTest < Minitest::Test
  include StackProofClaim

  Graph = Erx::StackGraph
  Budget = Erx::StackProofInput::Budget
  Targets = Erx::StackProofInput::Targets

  BUDGET = Budget.new(block_bytes: 8192, allowances: { 'call' => 2048, 'tick' => 1024 }.freeze,
                      tick_entries: %w[tick_entry].freeze, leaves: { 'erx_effect_store' => 96 }.freeze)
  NO_TARGETS = Targets.new(callers: {}.freeze)

  def test_a_call_keeps_the_frame_and_a_tail_jump_replaces_it
    graph = graph_of(fn('entry', 32, calls: %w[middle]), fn('middle', 48, tails: %w[last]), fn('last', 16),
                     fn('tick_entry', 0))
    depth = depth_of(prove(graph), 'entry')
    assert_equal 80, depth.bytes
    assert_equal 'entry (core.c:1, 32 bytes) -> middle (core.c:2, 48 bytes)', Erx::StackProof.render(depth.path)

    jumping = graph_of(fn('entry', 32, calls: %w[middle]), fn('middle', 8, tails: %w[last]), fn('last', 64),
                       fn('tick_entry', 0))
    depth = depth_of(prove(jumping), 'entry')
    assert_equal 96, depth.bytes
    assert_equal 'entry (core.c:1, 32 bytes) -> middle (core.c:2, 8 bytes) => last (core.c:3, 64 bytes)',
                 Erx::StackProof.render(depth.path)
  end

  def test_the_deepest_callee_decides
    graph = graph_of(fn('entry', 16, calls: %w[shallow deep]), fn('shallow', 8), fn('deep', 200, calls: %w[shallow]),
                     fn('tick_entry', 0))
    assert_equal 16 + 200 + 8, depth_of(prove(graph), 'entry').bytes
  end

  def test_a_declared_leaf_counts_its_declared_cost
    graph = graph_of(fn('entry', 16, calls: %w[erx_effect_store]), fn('tick_entry', 0))
    depth = depth_of(prove(graph), 'entry')
    assert_equal 16 + 96, depth.bytes
    assert_equal 'erx_effect_store (declared leaf, 96 bytes)', depth.path.last.label
  end

  def test_a_call_outside_the_graph_that_is_no_declared_leaf_is_refused
    graph = graph_of(fn('entry', 16, calls: %w[fiasco_internal]), fn('tick_entry', 0))
    assert_includes refusal(graph).message,
                    'entry (core.c:1, 16 bytes) calls fiasco_internal, which is neither a function of the cores ' \
                    'nor a declared leaf of kernel/stack_fiasco.txt'
  end

  def test_a_frame_above_the_cap_is_refused_and_one_at_the_cap_is_not
    at_cap = graph_of(fn('entry', 1024), fn('tick_entry', 0))
    assert_equal 1024, depth_of(prove(at_cap), 'entry').bytes
    over = graph_of(fn('entry', 16, calls: %w[large]), fn('large', 1025), fn('tick_entry', 0))
    assert_includes refusal(over).message, 'large (core.c:2, 1025 bytes): frame of 1025 bytes exceeds the 1024-byte cap'
  end

  def test_functions_no_entry_reaches_are_not_judged
    graph = graph_of(fn('entry', 16), fn('tick_entry', 0), fn('unused', 4096, calls: %w[unused nowhere]))
    assert_equal 16, depth_of(prove(graph, entries: %w[entry tick_entry]), 'entry').bytes
  end

  def test_an_unlisted_indirect_call_or_branch_is_refused
    graph = graph_of(fn('entry', 16, indirect_calls: 1), fn('tick_entry', 0))
    assert_includes refusal(graph).message,
                    'entry (core.c:1, 16 bytes)+0x40: indirect call or branch whose targets kernel/stack_targets.txt ' \
                    'does not list'
    branching = graph_of(fn('entry', 16, indirect_branches: 1), fn('tick_entry', 0))
    assert_includes refusal(branching).message, 'indirect call or branch whose targets'
  end

  def test_listed_targets_make_indirect_calls_calls_and_indirect_branches_tail_jumps
    targets = Targets.new(callers: { 'dispatch' => %w[erx_sys_a erx_sys_b] })
    calling = graph_of(fn('dispatch', 64, indirect_calls: 1), fn('erx_sys_a', 32), fn('erx_sys_b', 128),
                       fn('tick_entry', 0))
    assert_equal 64 + 128, depth_of(prove(calling, targets: targets, entries: %w[dispatch tick_entry]), 'dispatch').bytes
    branching = graph_of(fn('dispatch', 64, indirect_branches: 1), fn('erx_sys_a', 32), fn('erx_sys_b', 128),
                         fn('tick_entry', 0))
    depth = depth_of(prove(branching, targets: targets, entries: %w[dispatch tick_entry]), 'dispatch')
    assert_equal 128, depth.bytes
    assert_equal :tail, depth.path.first.leaves_by
  end

  def test_a_listed_target_must_name_one_function_or_a_leaf
    graph = graph_of(fn('dispatch', 64, indirect_calls: 1), fn('helper', 8, object: 'a.o'),
                     fn('helper', 8, object: 'b.o'), fn('tick_entry', 0))
    unknown = refusal(graph, targets: Targets.new(callers: { 'dispatch' => %w[missing] }), entries: %w[dispatch tick_entry])
    assert_includes unknown.message, 'listed target missing names no function or declared leaf'
    shared = refusal(graph, targets: Targets.new(callers: { 'dispatch' => %w[helper] }), entries: %w[dispatch tick_entry])
    assert_includes shared.message, 'listed target helper names more than one function'
    leaf = prove(graph, targets: Targets.new(callers: { 'dispatch' => %w[erx_effect_store] }),
                        entries: %w[dispatch tick_entry])
    assert_equal 64 + 96, depth_of(leaf, 'dispatch').bytes
  end

  def test_recursion_through_a_call_is_refused
    itself = graph_of(fn('entry', 16, calls: %w[entry]), fn('tick_entry', 0))
    assert_includes refusal(itself).message,
                    'cycle through a call: entry (core.c:1, 16 bytes) -> entry (core.c:1, 16 bytes)'
    mutual = graph_of(fn('entry', 16, calls: %w[even]), fn('even', 32, tails: %w[odd]), fn('odd', 48, calls: %w[even]),
                      fn('tick_entry', 0))
    assert_includes refusal(mutual).message,
                    'cycle through a call: odd (core.c:3, 48 bytes) -> even (core.c:2, 32 bytes) -> odd (core.c:3, 48 bytes)'
  end

  def test_recursion_through_tail_jumps_alone_is_as_deep_as_its_deepest_member
    graph = graph_of(fn('entry', 16, calls: %w[even]), fn('even', 32, tails: %w[odd]),
                     fn('odd', 48, tails: %w[even], calls: %w[erx_effect_store]), fn('tick_entry', 0))
    proof = prove(graph)
    depth = depth_of(proof, 'entry')
    assert_equal 16 + 48 + 96, depth.bytes
    assert_equal 'entry (core.c:1, 16 bytes) -> even (core.c:2, 32 bytes) => odd (core.c:3, 48 bytes) -> ' \
                 'erx_effect_store (declared leaf, 96 bytes)', Erx::StackProof.render(depth.path)
  end

  def test_an_entry_deeper_than_its_allowance_is_refused_with_its_path
    graph = graph_of(fn('entry', 1000, calls: %w[next_one]), fn('next_one', 1000, calls: %w[last]), fn('last', 100),
                     fn('tick_entry', 0))
    assert_includes refusal(graph).message,
                    'entry: 2100 bytes exceed the 2048-byte allowance of call entries: entry (core.c:1, 1000 bytes) -> ' \
                    'next_one (core.c:2, 1000 bytes) -> last (core.c:3, 100 bytes)'
  end

  def test_a_tick_entry_is_held_to_the_tick_allowance_as_well
    graph = graph_of(fn('entry', 16), fn('tick_entry', 1000, calls: %w[deeper]), fn('deeper', 100))
    message = refusal(graph).message
    assert_includes message, 'tick_entry: 1100 bytes exceed the 1024-byte allowance of tick hook entries'
    refute_includes message, 'allowance of call entries'
  end

  def test_a_tick_entry_must_be_an_exported_function_of_the_cores
    graph = graph_of(fn('entry', 16), fn('tick_entry', 0))
    assert_includes refusal(graph, entries: %w[entry]).message, 'tick entry tick_entry is no exported function of the cores'
  end

  def test_every_violation_is_reported_at_once
    graph = graph_of(fn('entry', 2000, calls: %w[fiasco_internal], indirect_calls: 1), fn('tick_entry', 0))
    message = refusal(graph).message
    assert_includes message, 'frame of 2000 bytes exceeds'
    assert_includes message, 'calls fiasco_internal'
    assert_includes message, 'indirect call or branch'
  end

  def test_tool_text_in_a_diagnostic_is_escaped
    graph = graph_of(fn('entry', 2000, location: "core.c\e]0;owned\a:1"), fn('tick_entry', 0))
    message = refusal(graph).message
    refute_match(/[\x00-\x1f]/, message.delete("\n"))
    assert_includes message, 'core.c\u{1b}]0;owned\u{7}:1'
  end

  def test_the_report_claims_a_bound_for_the_cores_only
    graph = graph_of(fn('entry', 32, calls: %w[erx_effect_store]), fn('tick_entry', 16))
    lines = prove(graph).lines
    assert_equal ["C17 cores: 128 bytes of the 2048-byte allowance; Fiasco's stack: unproven (call entries, -O2)",
                  "C17 cores: 16 bytes of the 1024-byte allowance; Fiasco's stack: unproven (tick hook entries, -O2)"],
                 lines.grep(/\AC17 cores: /)
    assert_includes lines, '  tick_entry (call, tick): 16 bytes: tick_entry (core.c:2, 16 bytes)'
    assert_bounded_claim(lines)
  end

  def test_the_claim_check_catches_a_line_that_names_the_kernel_stack
    assert_raises(Minitest::Assertion) { assert_bounded_claim(['kernel stack: 128 bytes of 8192']) }
    assert_raises(Minitest::Assertion) { assert_bounded_claim(["Fiasco's stack: 4096 bytes"]) }
    assert_raises(Minitest::Assertion) { assert_bounded_claim(['C17 cores: 128 bytes of the 2048-byte allowance']) }
  end

  def test_components_are_found_without_recursion
    chain = (0...50_000).to_a
    components = Erx::StackProof.components([0]) { |node| node + 1 < chain.length ? [node + 1] : [] }
    assert_equal 50_000, components.length
    assert_equal [49_999], components.first
    cycle = Erx::StackProof.components([0]) { |node| [(node + 1) % 3] }
    assert_equal [[0, 1, 2]], cycle
  end

  def test_an_entry_must_be_an_exported_function_of_the_graph
    graph = graph_of(fn('entry', 16, object: 'core.o'), fn('tick_entry', 0))
    static = Graph::Name.new(name: 'entry', object: 'core.o')
    error = assert_raises(Erx::StackProofError) do
      Erx::StackProof.prove(graph: graph, entries: [static, global('tick_entry')], budget: BUDGET,
                            targets: NO_TARGETS, level: '-O2')
    end
    assert_includes error.message, 'an entry is not an exported function of the graph'
    assert_includes refusal(graph, entries: %w[missing tick_entry]).message, 'an entry is not an exported function'
  end

  def test_a_tail_jump_to_a_declared_leaf_costs_the_leaf_alone
    large = graph_of(fn('entry', 200, tails: %w[erx_effect_store]), fn('tick_entry', 0))
    assert_equal 200, depth_of(prove(large), 'entry').bytes
    small = graph_of(fn('entry', 16, tails: %w[erx_effect_store]), fn('tick_entry', 0))
    depth = depth_of(prove(small), 'entry')
    assert_equal 96, depth.bytes
    assert_equal 'entry (core.c:1, 16 bytes) => erx_effect_store (declared leaf, 96 bytes)',
                 Erx::StackProof.render(depth.path)
  end

  def test_a_caller_name_two_functions_share_is_refused
    graph = graph_of(fn('entry', 16, calls: %w[dispatch]), fn('dispatch', 16, indirect_calls: 1),
                     fn('dispatch', 16, indirect_calls: 1, object: 'b.o'), fn('cheap', 8), fn('tick_entry', 0))
    assert_includes refusal(graph, targets: Targets.new(callers: { 'dispatch' => %w[cheap] })).message,
                    'kernel/stack_targets.txt names its indirect sites by dispatch, which names more than one function'
  end

  def test_components_are_listed_after_every_component_they_reach
    successors = { 0 => [1, 3], 1 => [2], 2 => [1, 4], 3 => [2], 4 => [] }
    components = Erx::StackProof.components([0]) { |node| successors.fetch(node) }
    position = components.each_with_index.flat_map { |members, index| members.map { |member| [member, index] } }.to_h
    successors.each do |node, targets|
      targets.each { |target| assert_operator position.fetch(target), :<=, position.fetch(node), "#{node} -> #{target}" }
    end
    assert_equal [[4], [1, 2], [3], [0]], components.map(&:sort)
  end

  private

  # One hand-made function: its name, frame, and edges by target name.
  Spec = Data.define(:name, :object, :location, :frame, :calls, :tails, :indirect_calls, :indirect_branches)

  def fn(name, frame, calls: [], tails: [], indirect_calls: 0, indirect_branches: 0, object: nil, location: nil)
    sites = ->(names) { names.each_with_index.map { |target, index| Graph::Site.new(offset: 4 * index, target: global(target)) } }
    indirect = ->(count) { Array.new(count) { |index| Graph::IndirectSite.new(offset: 0x40 + 4 * index, register: 'x8') } }
    Spec.new(name: name, object: object, location: location, frame: frame, calls: sites.call(calls),
             tails: sites.call(tails), indirect_calls: indirect.call(indirect_calls),
             indirect_branches: indirect.call(indirect_branches))
  end

  # Functions in the order given; each one's source line is its position.
  def graph_of(*specs)
    functions = specs.each_with_index.to_h do |spec, index|
      id = Graph::Name.new(name: spec.name, object: spec.object)
      [id, Graph::Function.new(id: id, object: spec.object || 'core.o', location: spec.location || "core.c:#{index + 1}",
                               frame_bytes: spec.frame, calls: spec.calls, tail_jumps: spec.tails,
                               indirect_calls: spec.indirect_calls, indirect_branches: spec.indirect_branches)]
    end
    Graph::Graph.new(functions: functions.freeze, externals: [].freeze)
  end

  def global(name) = Graph::Name.new(name: name, object: nil)

  def prove(graph, targets: NO_TARGETS, entries: %w[entry tick_entry])
    Erx::StackProof.prove(graph: graph, entries: entries.map { |name| global(name) }, budget: BUDGET,
                          targets: targets, level: '-O2')
  end

  def refusal(graph, **options)
    assert_raises(Erx::StackProofError) { prove(graph, **options) }
  end

  def depth_of(report, name) = report.depths.find { |depth| depth.entry.name == name }
end
