# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/stack_proof_run'
require_relative 'stack_proof_claim'
require_relative '../fixtures/generated_tree'

# The stack proof over objects compiled for the target: seeded C fixtures
# that each break one rule at the level that shows it, and the C17 cores
# as the build proves them.
class StackProofRunTest < Minitest::Test
  include StackProofClaim

  ROOT = File.expand_path('../..', __dir__)
  FIXTURES = File.expand_path('../fixtures', __dir__)
  FLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic --target=aarch64-none-elf -ffreestanding
             -mgeneral-regs-only -mno-outline-atomics -fstack-usage -ffunction-sections].freeze
  BUDGET = Erx::StackProofInput::Budget.new(block_bytes: 8192, allowances: { 'call' => 2048, 'tick' => 1024 }.freeze,
                                            tick_entries: %w[bounded].freeze,
                                            leaves: { 'erx_fixture_leaf' => 32, 'erx_fixture_external' => 32 }.freeze)
  NO_TARGETS = Erx::StackProofInput::Targets.new(callers: {}.freeze)

  def setup
    @compiler = ENV.fetch('ERX_CLANG', '')
    skip 'ERX_CLANG is not set: the stack proof needs the LLVM 23 clang and its binary tools' if @compiler.empty?

    @directory = Dir.mktmpdir('erx-stack-proof-test-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @tools = Erx::StackGraph::Tools.beside(@compiler)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && passed? && File.directory?(@directory)
  end

  def test_a_frame_above_the_cap_fails_at_every_level
    %w[-O0 -O2].each do |level|
      assert_includes refusal('stack_proof/violations', level, %w[big_frame bounded]).message, 'exceeds the 1024-byte cap'
    end
  end

  def test_recursion_through_calls_fails_at_every_level
    %w[-O0 -O2].each do |level|
      assert_match(/cycle through a call: walk .* -> walk /, refusal('stack_proof/violations', level, %w[walk bounded]).message)
    end
  end

  def test_recursion_through_ordinary_tail_calls_fails_only_unoptimized
    assert_match(/cycle through a call: p[io]ng /, refusal('stack_proof/violations', '-O0', %w[ping bounded]).message)
    path = Erx::StackProof.render(depth(proof('stack_proof/violations', '-O2', %w[ping bounded]), 'ping').path)
    assert_match(/\Aping \(.* => pong \(.* => erx_fixture_leaf \(declared leaf, 32 bytes\)\z/, path)
  end

  # At -O0 the pair tail-jumps to each other (stack_graph_test pins the
  # edges), so the proof accepts a cycle of tail jumps there; -O2 may fold
  # it into a loop. Members of such a cycle are equally deep.
  def test_musttail_recursion_passes_at_both_levels
    %w[-O0 -O2].each do |level|
      report = proof('stack_graph/edges', level, %w[count_even count_odd forwarded], tick: 'forwarded')
      assert_equal depth(report, 'count_even').bytes, depth(report, 'count_odd').bytes, level
    end
    unoptimized = proof('stack_graph/edges', '-O0', %w[count_even count_odd forwarded], tick: 'forwarded')
    assert %w[count_even count_odd].any? { |name| depth(unoptimized, name).path.first.leaves_by == :tail }
  end

  def test_a_refusal_leaves_no_report
    output = File.join('build', 'tests', "stack-proof-refused-#{Process.pid}")
    report = File.join(Erx::OutputDirectory.prepare(root: ROOT, path: output), 'report.txt')
    File.write(report, "C17 cores: 1 bytes of the 2048-byte allowance; Fiasco's stack: unproven\n")
    assert_raises(Erx::StackGraphError) do
      Erx::StackProofRun.call(root: ROOT, compiler: File.join(@directory, 'no-clang'), runner: @runner, output: output)
    end
    refute File.exist?(report)
  ensure
    FileUtils.remove_entry(File.join(ROOT, output)) if output && File.directory?(File.join(ROOT, output))
  end

  def test_an_external_that_is_no_declared_leaf_fails
    budget = BUDGET.with(leaves: {}.freeze)
    assert_includes refusal('stack_proof/violations', '-O2', %w[bounded], budget: budget).message,
                    'calls erx_fixture_leaf, which is neither a function of the cores nor a declared leaf'
    assert_equal 'erx_fixture_leaf (declared leaf, 32 bytes)',
                 depth(proof('stack_proof/violations', '-O2', %w[bounded]), 'bounded').path.last.label
  end

  def test_an_unlisted_indirect_call_fails_and_a_listed_one_counts_its_targets
    %w[-O0 -O2].each do |level|
      assert_includes refusal('stack_graph/edges', level, %w[indirect_call forwarded], tick: 'forwarded').message,
                      'indirect_call ('
      targets = Erx::StackProofInput::Targets.new(callers: { 'indirect_call' => %w[plain_call] })
      report = proof('stack_graph/edges', level, %w[indirect_call forwarded], tick: 'forwarded', targets: targets)
      assert_includes Erx::StackProof.render(depth(report, 'indirect_call').path), 'plain_call ('
    end
  end

  # The run checks the call-graph rules on the graph of each level it
  # proves: a core that calls erx_cap_slot_clear from a function
  # cap-slot-clear-callers does not list is refused when the call is in
  # both levels' objects, and also when only the -O0 or only the -O2
  # object holds it, so neither level goes unchecked.
  def test_an_unlisted_caller_of_the_slot_clear_fails_at_each_level
    { 'both' => ['', ''], 'O0' => ['#ifndef __OPTIMIZE__', '#endif'],
      'O2' => ['#ifdef __OPTIMIZE__', '#endif'] }.each do |variant, (open, close)|
      root = rogue_tree(variant, open: open, close: close)
      error = assert_raises(Erx::Error, variant) do
        Erx::StackProofRun.call(root: root, compiler: @compiler, runner: @runner, output: 'proof')
      end
      assert_match(/chokepoint cap-slot-clear-callers: .*erx_rogue_clear calls erx_cap_slot_clear/, error.message,
                   variant)
    end
    # The same tree without the call proves.
    root = rogue_tree('none', open: '#if 0', close: '#endif')
    refute_empty Erx::StackProofRun.call(root: root, compiler: @compiler, runner: @runner, output: 'proof')
  end

  RNG_BURN_BYTES = Integer(File.read(File.join(ROOT, 'kernel/core/rng.c'))[/ERX_RNG_BURN_BYTES\s+(\d+)/, 1])

  # erx_rng_digest overwrites what BLAKE3 leaves on the stack, a secret when
  # the bytes are one. Its one burn frame, which the report shows as the deepest
  # chain, must reach as deep as the hash at each level the proof reads, measured
  # from the frame both are called from. The digest returns a value after the
  # burn, so the burn is never a tail call laid over that frame. The array alone
  # is compared: what else the frame holds, its index and alignment, nothing
  # writes over.
  def assert_the_generators_burn_covers_its_hash(lines)
    %w[-O0 -O2].each do |level|
      section = lines.drop_while { |line| line != "stack proof of the C17 cores at #{level}:" }.drop(1)
                     .take_while { |line| line.start_with?('  ') }
      hash_depth = Integer(section.find { |line| line.start_with?('  erx_blake3_hash_chunk (call): ') }[/: (\d+) bytes:/, 1])
      chain = section.find { |line| line.start_with?('  erx_rng_digest (call): ') }.split(': ').last.split(/ [-=]> /)
      names = chain.map { |frame| frame[/\A\w+/] }
      assert_equal %w[erx_rng_digest erx_rng_burn_stack], names, "the deepest chain at #{level}"
      assert_operator RNG_BURN_BYTES, :>=, hash_depth, "the burn against the hash at #{level}"
    end
  end

  def test_the_cores_pass_and_the_report_claims_their_bound_alone
    output = File.join('build', 'tests', "stack-proof-#{Process.pid}")
    lines = Erx::StackProofRun.call(root: ROOT, compiler: @compiler, runner: @runner, output: output)
    assert_equal lines.join("\n") + "\n", File.read(File.join(ROOT, output, 'report.txt'))
    summaries = lines.grep(/\AC17 cores: /)
    assert_equal 4, summaries.length
    %w[-O0 -O2].each do |level|
      assert summaries.any? { |line| line.end_with?("(call entries, #{level})") }
      assert summaries.any? { |line| line.end_with?("(tick hook entries, #{level})") }
    end
    assert_includes lines, 'outside the claim: kernel/core/pack.c, linked into bootstrap'
    assert lines.any? { |line| line.start_with?('  erx_watchdog_step (call, tick): ') }
    refute lines.any? { |line| line.include?('erx_pack_open') }
    assert_bounded_claim(lines)
    assert_the_generators_burn_covers_its_hash(lines)
  ensure
    FileUtils.remove_entry(File.join(ROOT, output)) if output && File.directory?(File.join(ROOT, output))
  end

  private

  def proof(fixture, level, entries, tick: 'bounded', budget: BUDGET, targets: NO_TARGETS)
    stem = "#{File.basename(fixture)}#{level}"
    object = File.join(@directory, "#{stem}.o")
    unless File.file?(object)
      @runner.run([@compiler, *FLAGS, level, '-c', File.join(FIXTURES, "#{fixture}.c"), '-o', object],
                  name: 'compile-stack-proof', deadline: 60)
    end
    graph = Erx::StackGraph.extract(inputs: [Erx::StackGraph::Input.beside(object)], tools: @tools, runner: @runner)
    Erx::StackProof.prove(graph: graph, entries: entries.map { |name| Erx::StackGraph::Name.new(name: name, object: nil) },
                          budget: budget.with(tick_entries: [tick].freeze), targets: targets, level: level)
  end

  def refusal(fixture, level, entries, **options)
    assert_raises(Erx::StackProofError) { proof(fixture, level, entries, **options) }
  end

  def depth(report, name) = report.depths.find { |entry| entry.entry.name == name }

  # A tree of two cores, the clear and a rogue caller whose call to it
  # sits between open and close, with a budget whose tick entry is the
  # rogue. The bootstrap core the archive requires is present but never
  # compiled.
  def rogue_tree(variant, open:, close:)
    root = File.join(@directory, "rogue-#{variant}")
    FileUtils.mkdir_p(File.join(root, 'kernel/core'))
    File.write(File.join(root, 'kernel/stack_fiasco.txt'),
               "block 8192\nallowance call 2048\nallowance tick 1024\ntick erx_rogue_clear\n")
    File.write(File.join(root, 'kernel/stack_targets.txt'), '')
    File.write(File.join(root, 'kernel/core/pack.c'), '')
    File.write(File.join(root, 'kernel/core/boot_place.c'), '')
    File.write(File.join(root, 'kernel/core/clear.c'), <<~C)
      void erx_cap_slot_clear(int *slot);

      void
      erx_cap_slot_clear(int *slot)
      {
      	*slot = 0;
      }
    C
    File.write(File.join(root, 'kernel/core/rogue.c'), <<~C)
      void erx_cap_slot_clear(int *slot);
      void erx_rogue_clear(int *slot);

      void
      erx_rogue_clear(int *slot)
      {
      #{open}
      	erx_cap_slot_clear(slot);
      #{close}
      	*slot += 1;
      }
    C
    root
  end
end
