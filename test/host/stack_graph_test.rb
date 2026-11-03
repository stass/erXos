# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/core_archive'
require_relative '../../tools/lib/erx/stack_graph'

# Extracts the stack graph from small C fixtures compiled for the target,
# each holding one edge or one refusal, and from the three C17 cores at
# -O0 and -O2. The fixtures pin the edges the proof's cycle rule rests on:
# an ordinary tail call is a call at -O0 and a jump at -O2, and a musttail
# call is a jump at both.
class StackGraphTest < Minitest::Test
  FIXTURES = File.expand_path('../fixtures/stack_graph', __dir__)
  TARGET_FLAGS = %w[-std=c17 -Wall -Wextra -Werror -pedantic --target=aarch64-none-elf -ffreestanding
                    -mgeneral-regs-only -mno-outline-atomics -fstack-usage].freeze
  # Sources that use no effect and call out only to memcpy and memset: the
  # pure cores and primitives, and the generated ABI reader the pack
  # validator calls. A floor: a new core needs no entry, since the graph of
  # every core below holds it to the archive's own allowlist.
  PURE_SOURCES = %w[kernel/core/pack.c kernel/core/rng.c kernel/core/tlb_plan.c kernel/core/watchdog.c
                    kernel/crypto/chacha20/chacha.c kernel/crypto/sha2/sha256c.c
                    kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
                    liberx/generated/abi_reader.c].freeze

  # The archive's sources, the bootstrap core it leaves out, and the reader.
  def core_sources
    [*Erx::CoreArchive.sources(@root), *Erx::CoreArchive::BOOTSTRAP_SOURCES, 'liberx/generated/abi_reader.c']
  end

  Name = Erx::StackGraph::Name

  def setup
    @compiler = ENV.fetch('ERX_CLANG', '')
    skip 'ERX_CLANG is not set: the stack graph needs the LLVM 23 clang and its binary tools' if @compiler.empty?

    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-stack-graph-test-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @tools = Erx::StackGraph::Tools.beside(@compiler)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && passed? && File.directory?(@directory)
  end

  def test_unoptimized_edges
    graph = graph_of('edges', '-O0')
    assert_equal [site_target('scaled', 'edges-O0')], targets(graph, 'plain_call', :calls)
    assert_equal [external], targets(graph, 'ordinary_tail', :calls)
    assert_empty targets(graph, 'ordinary_tail', :tail_jumps)
    assert_equal [external], targets(graph, 'forwarded', :tail_jumps)
    assert_empty targets(graph, 'forwarded', :calls)
    assert_equal [Name.new(name: 'count_odd', object: nil)], targets(graph, 'count_even', :tail_jumps)
    assert_equal [Name.new(name: 'count_even', object: nil)], targets(graph, 'count_odd', :tail_jumps)
    assert_equal 1, function(graph, 'indirect_call').indirect_calls.length
    assert_equal 1, function(graph, 'indirect_tail').indirect_calls.length
    assert_equal [external], graph.externals
  end

  def test_optimized_edges
    graph = graph_of('edges', '-O2')
    assert_equal [site_target('scaled', 'edges-O2')], targets(graph, 'plain_call', :calls)
    assert_equal [external], targets(graph, 'ordinary_tail', :tail_jumps)
    assert_empty targets(graph, 'ordinary_tail', :calls)
    assert_equal [external], targets(graph, 'forwarded', :tail_jumps)
    assert_empty targets(graph, 'count_even', :calls)
    assert_equal [external], targets(graph, 'summed', :calls)
    assert_equal 1, function(graph, 'indirect_call').indirect_calls.length
    assert_equal 1, function(graph, 'indirect_tail').indirect_branches.length
    assert_empty function(graph, 'indirect_tail').indirect_calls
  end

  def test_frames_come_from_the_stack_usage_records
    graph = graph_of('edges', '-O0')
    stack_usage = File.read(File.join(@directory, 'edges-O0.su'))
    graph.functions.each_value do |function|
      assert_includes stack_usage, "#{function.id.name}\t#{function.frame_bytes}\tstatic"
      assert_match(/edges\.c:\d+\z/, function.location)
    end
    assert_operator function(graph, 'plain_call').frame_bytes, :>, 0
  end

  def test_static_functions_are_named_by_their_object
    graph = graph_of('edges', '-O0')
    scaled = graph.fetch_function(site_target('scaled', 'edges-O0'))
    refute scaled.id.global?
    assert_equal [external], scaled.calls.map(&:target)
  end

  def test_a_static_call_without_function_sections_keeps_no_relocation
    error = refusal('edges', '-O0', function_sections: false)
    assert_includes error.message, 'plain_call+0x'
    assert_includes error.message, 'call without a relocation naming its target'
  end

  def test_a_call_without_its_relocation_is_refused
    error = refusal('missing_relocation', '-O2')
    assert_includes error.message, 'unrelocated_call+0x'
    assert_includes error.message, 'call without a relocation naming its target'
  end

  def test_a_branch_into_the_middle_of_a_function_is_refused
    error = refusal('into_middle', '-O2')
    assert_includes error.message, 'into_middle+0x'
    assert_includes error.message, 'branch into the middle of middle_target+0x4'
  end

  def test_a_conditional_branch_out_of_its_function_is_refused
    error = refusal('conditional_exit', '-O2')
    assert_includes error.message, 'conditional_exit+0x'
    assert_includes error.message, 'conditional instruction with relocation R_AARCH64_CONDBR19'
  end

  def test_a_branch_out_of_its_function_without_a_relocation_is_refused
    error = refusal('branch_out', '-O2')
    assert_includes error.message, 'branch_out+0x0: branch leaves its function without a call or jump relocation'
  end

  def test_a_function_that_runs_off_its_end_is_refused
    error = refusal('falls_off', '-O2')
    assert_includes error.message, 'falls_off+0x0: body ends in a plain instruction'
  end

  def test_a_dynamic_frame_is_refused
    error = refusal('dynamic_frame', '-O2')
    assert_includes error.message, 'dynamic_frame: dynamic frame (dynamic)'
  end

  def test_a_function_without_a_frame_record_is_refused
    error = refusal('unknown_frame', '-O2')
    assert_includes error.message, 'unrecorded+0x0: no recorded frame size'
  end

  def test_an_unknown_instruction_is_refused
    error = refusal('unknown_instruction', '-O2')
    assert_includes error.message, 'unknown_instruction+0x'
    assert_includes error.message, 'unknown instruction d69f03e0'
  end

  def test_the_cores_yield_one_graph_at_each_level
    %w[-O0 -O2].each do |level|
      inputs = core_sources.to_h do |source|
        [source, compile(File.join(@root, source), "#{File.basename(source, '.c')}#{level}", level)]
      end
      graph = Erx::StackGraph.extract(inputs: inputs.values, tools: @tools, runner: @runner)
      # A sample of the entries. A new core needs none, since the graph's
      # every function is checked below.
      %w[erx_pack_open erx_tlb_plan erx_watchdog_step erx_watchdog_parse erx_manifest_open erx_rng_read
         erx_rng_mix erx_chacha20_xor erx_sha256_final
         erx_blake3_update erx_blake3_final erx_blake3_compress_in_place].each do |entry|
        function = graph.fetch_function(Name.new(name: entry, object: nil))
        assert_kind_of Integer, function.frame_bytes, "#{entry} #{level}"
      end
      refute graph.functions.each_key.all?(&:global?), "the cores' static functions appear at #{level}"
      assert_empty graph.externals.map(&:name).grep_v(Erx::CoreArchive::UNDEFINED),
                   "the cores' calls outside themselves at #{level}"
      pure = Erx::StackGraph.extract(inputs: inputs.fetch_values(*PURE_SOURCES), tools: @tools, runner: @runner)
      assert_empty pure.externals.map(&:name) - %w[memcpy memset], "the pure cores' calls outside themselves at #{level}"
      graph.functions.each_value do |function|
        assert_kind_of Integer, function.frame_bytes, "#{function.id} #{level}"
        assert_empty function.indirect_calls + function.indirect_branches, "#{function.id} #{level}"
      end
    end
  end

  def test_an_object_given_twice_is_refused
    input = compile(File.join(FIXTURES, 'edges.c'), 'edges-O2', '-O2')
    error = assert_raises(Erx::StackGraphError) do
      Erx::StackGraph.extract(inputs: [input, input], tools: @tools, runner: @runner)
    end
    assert_includes error.message, 'is given twice'
  end

  def test_a_global_defined_twice_is_refused
    first = compile(File.join(FIXTURES, 'edges.c'), 'edges-first', '-O2')
    second = compile(File.join(FIXTURES, 'edges.c'), 'edges-second', '-O2')
    error = assert_raises(Erx::StackGraphError) do
      Erx::StackGraph.extract(inputs: [first, second], tools: @tools, runner: @runner)
    end
    assert_match(/plain_call is defined in both .*edges-first\.o and .*edges-second\.o/, error.message)
  end

  private

  def external = Name.new(name: 'erx_fixture_external', object: nil)

  def site_target(name, stem) = Name.new(name: name, object: File.join(@directory, "#{stem}.o"))

  def function(graph, name) = graph.fetch_function(Name.new(name: name, object: nil))

  def targets(graph, name, kind) = function(graph, name).public_send(kind).map(&:target)

  def graph_of(fixture, level, function_sections: true)
    input = compile(File.join(FIXTURES, "#{fixture}.c"), "#{fixture}#{level}", level,
                    function_sections: function_sections)
    Erx::StackGraph.extract(inputs: [input], tools: @tools, runner: @runner)
  end

  def refusal(fixture, level, function_sections: true)
    error = assert_raises(Erx::StackGraphError) { graph_of(fixture, level, function_sections: function_sections) }
    assert_includes error.message, "#{fixture}#{level}.o: "
    error
  end

  def compile(source, stem, level, function_sections: true)
    object = File.join(@directory, "#{stem}.o")
    @runner.run([@compiler, *TARGET_FLAGS, level, *(function_sections ? ['-ffunction-sections'] : []),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/generated'),
                 '-I', File.join(@root, 'kernel/crypto'), '-c', source,
                 '-o', object],
                name: 'compile-stack-graph', deadline: 60)
    Erx::StackGraph::Input.beside(object)
  end
end
