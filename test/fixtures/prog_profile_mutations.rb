# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'prog_profile_frames'

# The differential test's mutations generated from the program protocol's model
# (docs/design-abi.md#program-protocol): for each kind and each rule the kind carries,
# one start frame whose first broken rule, for a reader in stream order, is that rule, at
# the kind's last value in BASE (the last non-empty one for a list), with the refusal both
# checks must give as "REASON KIND". Both checks stop at the first refusal, so a value past
# a range may also break a frame-wide rule judged later.
# The frame-wide rules (unique, refers, each total) and two wire faults (a map key
# repeated in each map, a truncated frame), which both checks name by the frame, join
# them. A rule no frame within the bound reaches first (a list maximum past what its keys
# or the frame bound allow), and a kind BASE does not hold, give no mutation; the skipped
# list names each.
module ProgProfileMutations
  Tuple = ProgProfileFrames::Tuple
  Etf = ProgProfileFrames::Etf

  # name: a String; bytes: the frame; verdict: "REASON KIND".
  Mutation = Data.define(:name, :bytes, :verdict)
  # A map written with its pairs in this order, which may repeat a key, as no Hash can.
  Pairs = Data.define(:pairs)

  # The first of the fresh unique values a list past its maximum takes, above BASE's.
  FRESH = 1000
  BASE_MAX = { 'u8' => 0xff, 'u16' => 0xffff, 'u32' => 0xffff_ffff, 'u64' => 0xffff_ffff_ffff_ffff }.freeze

  def self.t(*items) = Tuple.new(items: items)

  # A start value that holds every kind of the start frame, each list sorted as a
  # builder sorts it; test/erlang/erx_prog_profile_diff.erl's base/0.
  BASE = {
    pid: 2, ppid: 1, pgid: 2, argv: %w[prog a], env: ['HOME=/'], cwd: '/home/u',
    spawn: true, sigmask: %i[sigint sigterm], sigignore: [], umask: 0o22, data_area: t(100, 4),
    fds: [t(0, t(:tty, 1, :read)), t(1, t(:tty, 1, :write)), t(2, t(:dup, 1)),
          t(3, t(:pipe, :write, t(1, 2), { wend: 1, ring: 101, rpage: 102, size: 16_384, readers: [t(0, 103)] })),
          t(4, t(:pipe, :read, t(2, 3), { rix: 0, lock: 104, wends: 1,
                                          writers: [t(1, 105, 106, 65_536, 107, :open)], readers: [] })),
          t(5, t(:socketpair, t(3, 1), { rix: 1, lock: 108, wends: 2, writers: [], readers: [t(0, 109)] },
                 t(4, 1), { wend: 2, ring: 110, rpage: 111, size: 65_536, readers: [] })),
          t(6, t(:file, 7, :read_write)), t(7, t(:dir, 8)), t(8, t(:socket, 9)), t(9, :null)],
    image: t(:object, 0xffff_ffff_ffff_ff00)
  }.freeze

  module_function

  # The mutations of protocol (the erx_prog model of Erx::ABI), and the rules skipped.
  def from(protocol)
    Generator.new(protocol).results.partition { |result| result.is_a?(Mutation) }.then do |mutations, skips|
      [mutations, skips.map(&:why)]
    end
  end

  def frame(value) = Etf.frame(encode(t(:erx_start, 1, value)))

  def encode(value)
    case value
    in Integer if value.between?(0, 255) then Etf.small(value)
    in Integer if value.between?(-(2**31), (2**31) - 1) then Etf.int(value)
    in Integer if value.positive? then Etf.small_big(value)
    in String then Etf.binary(value)
    in Symbol | true | false then Etf.atom(value.to_s)
    in [] then Etf::NIL
    in Array then Etf.list(value.map { |item| encode(item) })
    in Tuple then Etf.tuple(*value.items.map { |item| encode(item) })
    in Hash then encode(Pairs.new(pairs: value.to_a))
    in Pairs then Etf.map(value.pairs.map { |key, item| [encode(key), encode(item)] })
    end
  end

  # The walk over BASE and the rules of each kind. A place is a kind with the path to
  # one of its values: list indexes, tuple positions and map keys.
  class Generator
    Place = Data.define(:kind, :path)
    # A rule no frame within the bound breaks alone, and why.
    Skip = Data.define(:why)
    public_constant :Skip

    def initialize(protocol)
      @protocol = protocol
      @kinds = protocol.fetch(:kinds)
      @frame_max = protocol.dig(:frame_max, :value)
      @places = places('start', BASE, [])
    end

    # Each Mutation, and a Skip for each rule or kind that gives none.
    def results
      kinds = @places.map(&:kind).uniq
      unreached = (@kinds.keys - kinds).map { |kind| Skip.new(why: "#{kind}: BASE holds no value of it") }
      [*kinds.flat_map { |kind| kind_mutations(kind) }, *frame_wide, *wire_faults, *unreached]
    end

    private

    def places(kind, value, path)
      inner = case @kinds[kind]&.fetch(:form)
              when 'list' then value.each_with_index.map { |item, i| [@kinds[kind].fetch(:element), item, path + [i]] }
              when 'tuple' then @kinds[kind].fetch(:elements).each_with_index.map { |k, i| [k, value.items[i], path + [i]] }
              when 'map'
                @kinds[kind].fetch(:fields).filter_map do |key, k|
                  [k, value[key.to_sym], path + [key.to_sym]] if value.key?(key.to_sym)
                end
              when 'union' then union_fields(@kinds[kind], value, path)
              else []
              end
      [Place.new(kind: kind, path: path), *inner.flat_map { |k, item, at| places(k, item, at) }]
    end

    # The fields of the case value takes, each with its kind and path.
    def union_fields(kind, value, path)
      return [] unless value.is_a?(Tuple)

      item = kind.fetch(:cases).find do |c|
        atoms = c.fetch(:atoms).map(&:to_sym)
        value.items.size == atoms.size + c.fetch(:fields).size && value.items.first(atoms.size) == atoms
      end
      item.fetch(:fields).each_with_index.map do |k, i|
        at = item.fetch(:atoms).size + i
        [k, value.items[at], path + [at]]
      end
    end

    def at(value, path) = path.reduce(value) { |item, step| item.is_a?(Tuple) ? item.items[step] : item[step] }

    def put(value, path, new)
      return new if path.empty?

      step, *rest = path
      case value
      in Tuple then Tuple.new(items: value.items.dup.tap { |items| items[step] = put(items[step], rest, new) })
      in Array then value.dup.tap { |items| items[step] = put(items[step], rest, new) }
      in Hash then value.merge(step => put(value[step], rest, new))
      end
    end

    # Where a kind's rules apply: its last place, or for a list its last non-empty one.
    def place(kind)
      all = @places.select { |item| item.kind == kind }
      all.reverse.find { |item| !(at(BASE, item.path).is_a?(Array) && at(BASE, item.path).empty?) } || all.last
    end

    def mutation(name, value, verdict) = Mutation.new(name: name, bytes: ProgProfileMutations.frame(value), verdict: verdict)

    # One mutation for each rule of kind, each replacing its value at its place.
    def kind_mutations(kind)
      where = place(kind)
      value = at(BASE, where.path)
      rules(kind, value).map do |rule, new, reason|
        next Skip.new(why: "#{kind} #{rule}: #{new.why}") if new.is_a?(Skip)

        # Bytes that are no term are named by the frame, whatever kind they hold.
        verdict = reason == 'malformed' ? 'malformed start' : "#{reason} #{kind}"
        mutation("#{kind}_#{rule}", put(BASE, where.path, new), verdict)
      end
    end

    # [rule, value breaking it, reason] for each rule of kind; the value is a Skip
    # for a rule no frame within the bound breaks alone.
    def rules(kind, value)
      model = @kinds[kind]
      case model&.fetch(:form) || kind
      when 'integer' then integer_rules(model)
      when 'text' then text_rules(model)
      when 'list' then list_rules(kind, model, value)
      when 'tuple' then [[:arity, Tuple.new(items: value.items[0...-1]), 'shape']]
      when 'map' then map_rules(model, value)
      when 'union' then [[:no_case, :erlang, 'no_case'], [:shape, 1, 'shape']]
      when 'boolean' then [[:shape, :undefined, 'shape']]
      when 'signal' then [[:unknown, :erlang, 'range'], [:shape, 1, 'shape']]
      else []
      end
    end

    def integer_rules(model)
      values = model[:values]&.map { |item| item.fetch(:value) }
      low = model.dig(:min, :value) || 0
      high = model.dig(:max, :value) || BASE_MAX.fetch(model.fetch(:base))
      rules = [[:shape, :erlang, 'shape']]
      rules << [:value, (low..high).find { |n| !values.include?(n) }, 'range'] if values
      rules << [:below, low - 1, 'range'] if !values && low.positive?
      rules << [:above, high + 1, 'range'] if !values && high < BASE_MAX.fetch(model.fetch(:base))
      rules << [:except, model.dig(:except, :value), 'range'] if model[:except]
      rules
    end

    def text_rules(model)
      max = model.dig(:max, :value)
      lead = if model.fetch(:path) then '/'
             elsif model.fetch(:assign) then 'a='
             else ''
             end
      rules = [[:shape, 1, 'shape'], [:length, lead + ('c' * (max + 1 - lead.size)), 'length']]
      rules << [:utf8, "#{lead}c\xff".b, 'utf8'] if model.fetch(:utf8)
      rules << [:nul, "#{lead}c\0", 'text'] if model.fetch(:refuse).include?('nul')
      rules += [[:no_name, '=x', 'text'], [:no_assign, 'x', 'text']] if model.fetch(:assign)
      rules += [[:relative, 'c/d', 'text'], [:dotdot, '/c/../d', 'text']] if model.fetch(:path)
      rules
    end

    def list_rules(kind, model, value)
      rules = [[:shape, 1, 'shape'], [:length, longest(kind, model, value), 'length']]
      if model.fetch(:ascending) && !value.empty?
        rules << [:order, value + [fresh(model.fetch(:element), value.last, (FRESH..).each)], 'order']
      end
      rules
    end

    # The list one element past its maximum, its first max elements in order: an
    # ascending list's keys counting up from its key kind's least value.
    def longest(kind, model, value)
      max = model.dig(:max, :value)
      return Skip.new(why: 'no element to copy') if value.empty?

      items = if model.fetch(:ascending)
                key = (@kinds[model.fetch(:element)] || {})[:elements]&.first
                low = @kinds.dig(key, :min, :value)
                high = @kinds.dig(key, :max, :value)
                return Skip.new(why: 'its keys are no integers to count up') if low.nil? || high.nil?
                return Skip.new(why: "keys run out at #{high - low + 1}") if high - low + 1 < max

                (0...max).map { |i| put(value.last, [0], low + i) } + [value.last]
              else
                Array.new(max + 1, value.last)
              end
      numbers = (FRESH..).each
      items = items.map { |item| fresh(model.fetch(:element), item, numbers) }
      size = ProgProfileMutations.frame(put(BASE, place(kind).path, items)).bytesize
      size > @frame_max ? Skip.new(why: "#{size} bytes, past the frame bound") : items
    end

    # item with each value of the unique kind a fresh number, so its copies break no
    # unique rule, which the Erlang grammar judges at each value and the C check at the end.
    def fresh(kind, item, numbers)
      unique = @protocol.fetch(:unique)
      places(kind, item, []).select { |where| where.kind == unique }.reduce(item) do |value, where|
        put(value, where.path, numbers.next)
      end
    end

    def map_rules(model, value)
      required = model.fetch(:fields).map(&:first) - model.fetch(:optional)
      pairs = value.to_a
      # The second pair under the first pair's key: a key repeated, which no decoder accepts.
      repeated = Pairs.new(pairs: [pairs[0], [pairs[0][0], pairs[1][1]], *pairs[2..]])
      [[:shape, 1, 'shape'], [:key_missing, value.reject { |key, _| key == required.first.to_sym }, 'key'],
       [:key_unknown, value.merge(erlang: 1), 'key'], [:key_repeated, repeated, 'malformed']]
    end

    # unique: a value of the unique kind repeated; refers: a key its list lacks; each
    # total: the last text summed into it grown until the sum is one past its maximum.
    def frame_wide
      [*unique, *@protocol.fetch(:refers).map { |rule| refers(rule) }, *@protocol.fetch(:totals).keys.map { |name| total(name) }]
    end

    def unique
      name = @protocol.fetch(:unique)
      return [] unless name

      all = @places.select { |item| item.kind == name }
      [mutation("#{name}_unique", put(BASE, all.last.path, at(BASE, all.first.path)), "unique #{name}")]
    end

    def refers(rule)
      keys = at(BASE, place(rule.fetch(:list)).path).map { |item| item.items.first }
      absent = (rule.fetch(:low)...(rule.fetch(:low) + rule.fetch(:range))).find { |key| !keys.include?(key) }
      mutation("#{rule.fetch(:kind)}_refers", put(BASE, place(rule.fetch(:kind)).path, absent), "refers #{rule.fetch(:kind)}")
    end

    def total(name)
      summed = @places.select { |item| @kinds.dig(item.kind, :sum) == name }
      sum = summed.sum { |item| at(BASE, item.path).bytesize + 1 }
      last = summed.last
      text = at(BASE, last.path) + ('c' * (@protocol.dig(:totals, name, :value) - sum + 1))
      if text.bytesize > @kinds.dig(last.kind, :max, :value)
        return Skip.new(why: "#{name} total: its last text would pass its own maximum")
      end

      mutation("#{name}_total", put(BASE, last.path, text), "total #{name}")
    end

    # Bytes no term of the wire grammar: the frame cut short by a byte.
    def wire_faults
      bytes = ProgProfileMutations.frame(BASE)
      [Mutation.new(name: 'truncated', bytes: bytes[0...-1], verdict: 'malformed start')]
    end
  end
end
