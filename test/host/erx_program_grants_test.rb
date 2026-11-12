# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'

# What each frame erx_program:send/2 writes gives the program's credit
# (docs/design-programs.md, "Credit"), walked over the program protocol itself
# (abi/protocols/prog.txt): every case of a union a frame to the program carries, a
# startup message's descriptor or a report, is built with distinct numbers and every
# case of each union inside it, and erx_program:grants/1 (otp/erts/preloaded/src/
# erx_program.erl, compiled with export_all and run on stock's emulator, ERX_ERL and
# ERX_ERLC) must answer for each what RULES says. grants/1 has a clause for every kind
# and none falls through, so a kind the protocol gains fails here until erx_program.erl
# has its rule; and a kind that names a pipe end fails here until RULES says what it
# grants, so neither side can leave a new kind's notices undue.
class ErxProgramGrantsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE = File.join(ROOT, 'otp/erts/preloaded/src/erx_program.erl')
  # The reply slot send/2 names for a frame that answers no request (erx_program.erl, ?NO_REPLY).
  NO_REPLY = 255
  # The kinds that name a pipe end, directly in a case's fields.
  PIPE_KINDS = %w[pipe_end pipe_id].freeze
  # The unions of the frames to the program that have a case naming a pipe end: a startup
  # message's descriptor, inside its fds, and a report, which is the report frame's term.
  WALKED = %w[descriptor report].freeze

  # A sample term: a tuple or a list of terms. An Integer is an integer, a Symbol an
  # atom and a Hash a map.
  Tuple = Data.define(:items)
  List = Data.define(:items)
  # One sample of a union's case: the case's C name and its term.
  Sample = Data.define(:union, :name, :term)

  def self.closed((pipe, end_id)) = Tuple.new(items: [:closed, pipe, end_id])
  def self.drained(pipe, end_id, writer) = Tuple.new(items: [:drained, pipe, end_id, writer])

  # The writers of a read end, a map, that are gone: each a drained key of that end.
  def self.gone(pipe_end, read_end)
    read_end.fetch(:writers).items.filter_map do |writer|
      drained(*pipe_end.items, writer.items.first) if writer.items.last == :gone
    end
  end

  # What each case naming a pipe end grants, from its term's items (the case's atoms
  # first): the design's rule, written out once more as the oracle grants/1 must agree with.
  RULES = {
    'pipe_write' => ->(items) { [closed(items[2].items)] },
    'pipe_read' => ->(items) { [closed(items[2].items), *gone(items[2], items[3])] },
    'socketpair' => ->(items) { [closed(items[1].items), closed(items[3].items), *gone(items[1], items[2])] },
    'pipe_writer' => ->(items) { items.last == :gone ? [drained(*items[1, 3])] : [] },
    'pipe_writer_gone' => ->(items) { [drained(*items[1, 3])] },
    'pipe_reader' => ->(_) { [] },
    'pipe_reader_gone' => ->(_) { [] },
    'pipe_lost' => ->(_) { [] }
  }.freeze

  def setup
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT))
    @protocol = schema.protocols.find { |protocol| protocol[:name] == 'erx_prog' }
    @kinds = @protocol.fetch(:kinds)
    @next = 0
  end

  def test_every_kind_a_frame_to_the_program_carries_has_its_grants
    roots = @protocol.fetch(:frames).select { |frame| frame[:direction] == 'to' }.map { |frame| frame[:kind] }
    assert_equal WALKED.sort, pipe_unions(roots).sort, 'the walk builds frames for every union that names a pipe end'
    samples = WALKED.flat_map { |union| union_samples(union) }
    pipe_cases = samples.select { |sample| names_pipe_end?(sample) }.map(&:name).uniq
    assert_includes pipe_cases, 'socketpair', 'the walk reached the descriptors that give pipe ends'
    assert_empty pipe_cases - RULES.keys, 'each kind naming a pipe end has a rule in RULES'
    want = samples.map { |sample| [sample.name, render(Tuple.new(items: [NO_REPLY, List.new(items: expected(sample))]))] }
    assert_equal want, grants(samples)
  end

  private

  # The unions reachable from roots, each kind once, that have a case naming a pipe end.
  def pipe_unions(roots)
    seen = []
    queue = roots.dup
    until queue.empty?
      name = queue.shift
      next if seen.include?(name) || !@kinds.key?(name)

      seen << name
      queue.concat(inner_kinds(@kinds.fetch(name)))
    end
    seen.select do |name|
      @kinds.fetch(name)[:form] == 'union' && @kinds.fetch(name)[:cases].any? { |c| c[:fields].intersect?(PIPE_KINDS) }
    end
  end

  def inner_kinds(kind)
    case kind[:form]
    when 'union' then kind[:cases].flat_map { |c| c[:fields] }
    when 'tuple' then kind[:elements]
    when 'list' then [kind[:element]]
    when 'map' then kind[:fields].map(&:last)
    else []
    end
  end

  def names_pipe_end?(sample)
    @kinds.fetch(sample.union).fetch(:cases).find { |c| c[:c_name] == sample.name }
          .fetch(:fields).intersect?(PIPE_KINDS)
  end

  def expected(sample)
    rule = RULES[sample.name]
    rule.nil? ? [] : rule.call(sample.term.is_a?(Tuple) ? sample.term.items : [sample.term])
  end

  # A sample of every case of union, each with every combination of the unions inside it.
  def union_samples(union)
    @kinds.fetch(union).fetch(:cases).flat_map do |c|
      case_terms(c).map { |term| Sample.new(union: union, name: c[:c_name], term: term) }
    end
  end

  def case_terms(c)
    atoms = c[:atoms].map(&:to_sym)
    return [atoms.first] if c[:fields].empty? && atoms.size == 1

    combinations(c[:fields]).map { |fields| Tuple.new(items: atoms + fields) }
  end

  def combinations(kinds)
    kinds.reduce([[]]) { |acc, kind| acc.product(variants(kind)).map { |done, term| done + [term] } }
  end

  # Every sample of kind: one for each case of a union inside it, and a list holding
  # every sample of its element. Each integer is a number no other integer has.
  def variants(name)
    kind = @kinds.fetch(name)
    case kind[:form]
    when 'integer' then [number(kind)]
    when 'union' then kind[:cases].flat_map { |c| case_terms(c) }
    when 'tuple' then combinations(kind[:elements]).map { |items| Tuple.new(items: items) }
    when 'list' then [List.new(items: variants(kind[:element]))]
    when 'map'
      fields = kind[:fields].map(&:first).map(&:to_sym)
      combinations(kind[:fields].map(&:last)).map { |values| fields.zip(values).to_h }
    else flunk("the walk does not build #{name}, a #{kind[:form]}")
    end
  end

  def number(kind)
    return kind[:values].first[:value] if kind[:values]

    @next += 1
    min = kind.dig(:min, :value) || 1
    max = kind.dig(:max, :value) || ((1 << 64) - 1)
    min + ((@next - 1) % (max - min + 1))
  end

  # The term as Erlang's ~0p prints it, which is also Erlang source.
  def render(term)
    case term
    when Integer, Symbol then term.to_s
    when Tuple then "{#{term.items.map { |item| render(item) }.join(',')}}"
    when List then "[#{term.items.map { |item| render(item) }.join(',')}]"
    when Hash then "\#{#{term.map { |key, value| "#{key} => #{render(value)}" }.join(',')}}"
    end
  end

  # Each sample's name and what grants/1 answered for its frame, or its failure.
  def grants(samples)
    frames = samples.map do |sample|
      frame = sample.union == 'descriptor' ? "{erx_start,1,\#{fds => [{0,#{render(sample.term)}}]}}" :
                                             "{erx_prog,1,#{render(sample.term)}}"
      "{\"#{sample.name}\",#{frame}}"
    end
    erlang = <<~ERLANG
      [io:format("~s~n~0p~n", [Name, try erx_program:grants(Frame) catch C:R -> {C, R} end])
       || {Name, Frame} <- [#{frames.join(",\n")}]],
      halt().
    ERLANG
    Dir.mktmpdir('erx-program-grants-') do |dir|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '+export_all', '+nowarn_export_all', '-o', dir, MODULE,
                                       stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', dir,
                                       '-eval', erlang, stdin_data: '')
      assert status.success?, output
      output.lines.map(&:chomp).each_slice(2).to_a
    end
  end
end
