# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'stack_graph'
require_relative 'stack_proof_input'

module Erx
  # The analysis half of the stack proof (docs/design-kernel.md#stack-proof):
  # given one optimization level's call graph from StackGraph, the entries
  # and the declarations of StackProofInput, the worst-case stack depth of
  # each entry and the path that reaches it, or a StackProofError listing
  # every rule the graph breaks. Pure: it reads nothing but its arguments.
  #
  # The depth of a function is its own frame plus the deepest function it
  # calls, or the depth of a function it tail-jumps to, whichever is more,
  # since a tail jump replaces the jumping function's frame. A function
  # outside the graph counts only as a declared leaf of its declared cost.
  # An indirect call or branch reaches the functions kernel/stack_targets.txt
  # lists for the function that holds it, as a call or a tail jump.
  #
  # Over the functions the entries reach, the proof refuses
  #
  # * a frame above FRAME_CAP_BYTES;
  # * an indirect call or branch in a function the targets file does not
  #   list, or a listed target that names no function or leaf;
  # * a call or jump to a function outside the graph that is not a declared
  #   leaf;
  # * a cycle with a call in it: only tail jumps may recur, and since an
  #   ordinary tail call is a call at -O0, running the proof at -O0 and at
  #   -O2 leaves only musttail recursion passing both;
  # * an entry deeper than the allowance of any role it plays.
  #
  # Functions no entry reaches are not judged: no stack holds their frames.
  # A cycle of tail jumps holds one frame at a time, so each of its members
  # is as deep as its deepest member.
  module StackProof
    FRAME_CAP_BYTES = 1024

    # A declared function outside the graph, with its declared cost.
    Leaf = Data.define(:name, :bytes) do
      def to_s = "#{name} (declared leaf, #{bytes} bytes)"
    end
    # kind is :call or :tail; target is a StackGraph::Name or a Leaf.
    Edge = Data.define(:kind, :target)
    # One function of a deepest path and how the path leaves it: :call keeps
    # its frame under the next one, :tail replaces it, nil ends the path.
    Step = Data.define(:label, :leaves_by)
    # The deepest path from one entry. roles are the roles the entry plays.
    EntryDepth = Data.define(:entry, :roles, :bytes, :path)
    Report = Data.define(:level, :depths, :allowances) do
      # Per entry its depth and deepest path, then per role the deepest
      # entry against its allowance. Every line names the C17 cores' scope
      # and none claims a bound on Fiasco's own stack (B8).
      def lines
        entries = depths.map do |depth|
          "  #{depth.entry.name} (#{depth.roles.join(', ')}): #{depth.bytes} bytes: #{StackProof.render(depth.path)}"
        end
        summaries = allowances.map do |role, allowance|
          deepest = depths.select { |depth| depth.roles.include?(role) }.map(&:bytes).max
          "C17 cores: #{deepest} bytes of the #{allowance}-byte allowance; Fiasco's stack: unproven " \
            "(#{StackProofInput::ROLES.fetch(role)}, #{level})"
        end
        ["stack proof of the C17 cores at #{level}:", *entries, *summaries]
      end
    end

    module_function

    # entries are the StackGraph::Names of the cores' exported functions;
    # each plays the call role, and those budget.tick_entries names play the
    # tick role as well.
    def prove(graph:, entries:, budget:, targets:, level:)
      Proof.new(graph: graph, budget: budget, targets: targets, level: level).report(entries)
    end

    # A path as text: "->" after a function whose frame stays under the
    # next, "=>" after one whose tail jump replaces it.
    def render(path)
      path.map { |step| step.label + { call: ' -> ', tail: ' => ', nil => '' }.fetch(step.leaves_by) }.join
    end

    # One proof over one graph. It owns the edges it derives from the graph
    # and the declarations, and the violations it collects on the way, so
    # every rule is reported at once rather than one per build.
    class Proof
      Depth = Data.define(:bytes, :path)

      def initialize(graph:, budget:, targets:, level:)
        @graph = graph
        @budget = budget
        @targets = targets
        @level = level
        @leaves = budget.leaves.to_h { |name, bytes| [name, Leaf.new(name: name, bytes: bytes)] }
        @violations = []
        @edges = {}
      end

      def report(entries)
        roles = entry_roles(entries)
        reached = reachable(roles.keys)
        fail_on_violations
        function_depths = depths_of(reached)
        entry_depths = roles.map do |entry, played|
          deepest = function_depths.fetch(entry)
          EntryDepth.new(entry: entry, roles: played, bytes: deepest.bytes, path: deepest.path)
        end
        check_allowances(entry_depths)
        fail_on_violations
        Report.new(level: @level, depths: entry_depths.freeze, allowances: @budget.allowances)
      end

      private

      def entry_roles(entries)
        unless entries.all? { |entry| entry.global? && @graph.functions.key?(entry) }
          raise StackProofError, "stack proof at #{@level}: an entry is not an exported function of the graph"
        end
        names = entries.map(&:name)
        @budget.tick_entries.reject { |name| names.include?(name) }.each do |name|
          @violations << "tick entry #{name} is no exported function of the cores"
        end
        entries.to_h { |entry| [entry, @budget.tick_entries.include?(entry.name) ? %w[call tick] : %w[call]] }
      end

      def fail_on_violations
        return if @violations.empty?

        raise StackProofError, (["stack proof at #{@level} refuses the graph:"] + @violations.uniq.map { "  #{_1}" })
          .join("\n")
      end

      # The functions the entries reach, in the order first reached, judging
      # each one's frame and edges as it is reached.
      def reachable(entries)
        seen = {}
        pending = entries.dup
        until pending.empty?
          id = pending.shift
          next if seen.key?(id)

          seen[id] = true
          function = @graph.fetch_function(id)
          if function.frame_bytes > FRAME_CAP_BYTES
            @violations << "#{label(id)}: frame of #{function.frame_bytes} bytes exceeds the " \
                           "#{FRAME_CAP_BYTES}-byte cap"
          end
          pending.concat(edges(function).map(&:target).grep(StackGraph::Name))
        end
        seen.keys
      end

      # The function's direct edges, then those its indirect sites reach.
      # Each target is a function of the graph or a declared Leaf; a target
      # that is neither is a violation and contributes no edge.
      def edges(function)
        @edges[function.id] ||= begin
          direct = [[:call, function.calls], [:tail, function.tail_jumps]].flat_map do |kind, sites|
            sites.map(&:target).uniq.filter_map { |target| direct_edge(function, kind, target) }
          end
          (direct + indirect_edges(function)).uniq.freeze
        end
      end

      def direct_edge(function, kind, target)
        return Edge.new(kind: kind, target: target) if @graph.functions.key?(target)
        return Edge.new(kind: kind, target: @leaves.fetch(target.name)) if target.global? && @leaves.key?(target.name)

        @violations << "#{label(function.id)} calls #{target.name}, which is neither a function of the cores " \
                       'nor a declared leaf of kernel/stack_fiasco.txt'
        nil
      end

      # A BLR is a call and a BR a tail jump to each listed target.
      def indirect_edges(function)
        kinds = { call: function.indirect_calls, tail: function.indirect_branches }.reject { |_kind, sites| sites.empty? }
        return [] if kinds.empty?

        if @graph.functions.each_key.count { |id| id.name == function.id.name } > 1
          @violations << "#{label(function.id)}: kernel/stack_targets.txt names its indirect sites by " \
                         "#{function.id.name}, which names more than one function"
          return []
        end
        listed = @targets.callers[function.id.name]
        unless listed
          first = kinds.values.flatten.min_by(&:offset)
          @violations << "#{label(function.id)}+0x#{first.offset.to_s(16)}: indirect call or branch whose " \
                         'targets kernel/stack_targets.txt does not list'
          return []
        end
        reached = listed.filter_map { |name| listed_target(function, name) }
        kinds.keys.flat_map { |kind| reached.map { |target| Edge.new(kind: kind, target: target) } }
      end

      # A listed target by name: the one function of the graph so named, or
      # a declared leaf. A name two functions share is refused rather than
      # guessed.
      def listed_target(function, name)
        named = @graph.functions.each_key.select { |id| id.name == name }
        return named.first if named.length == 1
        return @leaves.fetch(name) if named.empty? && @leaves.key?(name)

        @violations << "#{label(function.id)}: listed target #{name} " \
                       "#{named.empty? ? 'names no function or declared leaf' : 'names more than one function'}"
        nil
      end

      # Depth of every reached function, visiting the strongly connected
      # components of the call graph so that each is finished after every
      # component it reaches.
      def depths_of(reached)
        components = StackProof.components(reached) { |id| successors(id) }
        components.each { |members| check_cycle(members) }
        fail_on_violations
        components.each_with_object({}) do |members, function_depths|
          function_depths.merge!(component_depths(members, function_depths))
        end
      end

      def successors(id) = edges(@graph.fetch_function(id)).map(&:target).grep(StackGraph::Name).uniq

      # Edges of the given kinds from a member of a component to another.
      def inside_edges(id, inside, kinds:)
        edges(@graph.fetch_function(id)).select { |edge| kinds.include?(edge.kind) && inside.key?(edge.target) }
      end

      # A component recurs if it has more than one member or a member that
      # reaches itself; it may do so only through tail jumps, so any call
      # between two of its members closes a forbidden cycle. One witness
      # cycle per component is reported.
      def check_cycle(members)
        inside = members.to_h { |id| [id, true] }
        caller = members.find { |id| inside_edges(id, inside, kinds: %i[call]).any? }
        return unless caller

        callee = inside_edges(caller, inside, kinds: %i[call]).first.target
        cycle = [caller, *path_between(callee, caller, inside, kinds: %i[call tail])]
        @violations << "cycle through a call: #{cycle.map { |member| label(member) }.join(' -> ')}"
      end

      # Every member of a component that recurs through tail jumps holds one
      # frame at a time, so each is as deep as the deepest one: its path
      # jumps there and continues as that member's own path.
      def component_depths(members, finished)
        inside = members.to_h { |id| [id, true] }
        own = members.to_h { |id| [id, own_depth(id, inside, finished)] }
        deepest = members.max_by { |id| own.fetch(id).bytes }
        toward = next_jumps_toward(deepest, members, inside)
        members.to_h do |id|
          jumps = []
          member = id
          until member == deepest
            jumps << Step.new(label: label(member), leaves_by: :tail)
            member = toward.fetch(member)
          end
          [id, Depth.new(bytes: own.fetch(deepest).bytes, path: (jumps + own.fetch(deepest).path).freeze)]
        end
      end

      # For each member but target, the member its shortest chain of tail
      # jumps to target goes through next: one search back from target
      # along the component's tail jumps. Once the cycle check has passed,
      # the members of a component reach one another through tail jumps
      # alone.
      def next_jumps_toward(target, members, inside)
        jumpers = Hash.new { |table, id| table[id] = [] }
        members.each do |id|
          inside_edges(id, inside, kinds: %i[tail]).each { |edge| jumpers[edge.target] << id }
        end
        toward = {}
        frontier = [target]
        until frontier.empty?
          reached = []
          frontier.each do |id|
            jumpers[id].each do |jumper|
              next if jumper == target || toward.key?(jumper)

              toward[jumper] = id
              reached << jumper
            end
          end
          frontier = reached
        end
        unreached = members.find { |id| id != target && !toward.key?(id) }
        raise StackProofError, "stack proof at #{@level}: #{label(unreached)} does not reach #{label(target)}" if unreached

        toward
      end

      # A member's depth through its own frame and its edges out of the
      # component; finished holds the depth of every function outside it.
      def own_depth(id, inside, finished)
        function = @graph.fetch_function(id)
        alone = Depth.new(bytes: function.frame_bytes, path: [Step.new(label: label(id), leaves_by: nil)])
        onward = edges(function).reject { |edge| inside.key?(edge.target) }.map do |edge|
          target = target_depth(edge.target, finished)
          kept = edge.kind == :call ? function.frame_bytes : 0
          Depth.new(bytes: kept + target.bytes, path: [Step.new(label: label(id), leaves_by: edge.kind), *target.path])
        end
        [alone, *onward].max_by(&:bytes)
      end

      def target_depth(target, finished)
        return Depth.new(bytes: target.bytes, path: [Step.new(label: target.to_s, leaves_by: nil)]) if target.is_a?(Leaf)

        finished.fetch(target)
      end

      # A shortest path from one member of a component to another, both
      # included, over edges of the given kinds that stay inside it; [from]
      # when they are the same. Members of a component reach one another.
      def path_between(from, to, inside, kinds:)
        previous = { from => nil }
        frontier = [from]
        until previous.key?(to) || frontier.empty?
          reached = []
          frontier.each do |id|
            inside_edges(id, inside, kinds: kinds).map(&:target).each do |target|
              next if previous.key?(target)

              previous[target] = id
              reached << target
            end
          end
          frontier = reached
        end
        raise StackProofError, "stack proof at #{@level}: #{label(from)} does not reach #{label(to)}" unless previous.key?(to)

        path = [to]
        path.unshift(previous.fetch(path.first)) until path.first == from
        path
      end

      def check_allowances(depths)
        depths.each do |depth|
          depth.roles.each do |role|
            allowance = @budget.allowances.fetch(role)
            next if depth.bytes <= allowance

            @violations << "#{depth.entry.name}: #{depth.bytes} bytes exceed the #{allowance}-byte allowance of " \
                           "#{StackProofInput::ROLES.fetch(role)}: #{StackProof.render(depth.path)}"
          end
        end
      end

      # A function as the report names it: its name and source position,
      # escaped since both come from tool output, and its frame.
      def label(id)
        function = @graph.fetch_function(id)
        "#{function.id.name} (#{Terminal.escape(function.location)}, #{function.frame_bytes} bytes)"
      end
    end

    # The strongly connected components of the graph the block's successors
    # describe, reached from roots, each listed after every component it
    # reaches (Tarjan's algorithm, iterative so that no input drives the
    # recursion depth).
    # One node on the search's path, with the next of its successors to
    # look at.
    Visit = Struct.new(:node, :successors, :position)

    def components(roots, &successors_of)
      index = {}
      low = {}
      stack = []
      on_stack = {}
      found = []
      roots.each do |root|
        next if index.key?(root)

        work = []
        enter = lambda do |node|
          index[node] = low[node] = index.size
          stack.push(node)
          on_stack[node] = true
          work.push(Visit.new(node, successors_of.call(node), 0))
        end
        enter.call(root)
        until work.empty?
          visit = work.last
          node = visit.node
          if visit.position < visit.successors.length
            successor = visit.successors[visit.position]
            visit.position += 1
            if !index.key?(successor)
              enter.call(successor)
            elsif on_stack[successor]
              low[node] = [low[node], index[successor]].min
            end
            next
          end
          work.pop
          low[work.last.node] = [low[work.last.node], low[node]].min unless work.empty?
          next unless low[node] == index[node]

          component = []
          loop do
            member = stack.pop
            on_stack.delete(member)
            component << member
            break if member == node
          end
          found << component.reverse.freeze
        end
      end
      found
    end
  end
end
