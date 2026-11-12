# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'etf_wire'

# Random terms of the domain grammar as wire bytes. Two sources of
# randomness drive it: values draws what the term is, encodings how it is
# written (which integer form, short or long atoms, where a list's
# LIST_EXT and STRING_EXT tails cut it, BIT_BINARY_EXT for whole bytes,
# garbage in a bitstring's unused bits, the order of a map's pairs, a
# fun's old index, old uniq and creator, which ERTS discards). A map key
# is made from a seed of its own for values, and a later key sometimes
# reuses an earlier key's seed, so it is the same term written in fresh
# encodings, and OTP decides whether the two are equal.
#
# Each term reports whether ERTS's size pass counts it exactly (bigs, maps
# over 32 pairs, records, funs and binaries over 64 bytes it
# overestimates), how many exports it holds (an export decodes to its
# entry's fun, a literal that takes no heap, though erts_debug:flat_size/1
# counts it as 2 words) and whether the host grammar admits it, that is,
# whether it holds no pid, reference, fun or export.
class EtfGenerator
  include EtfWire

  NODES = %w[web@erxos system@erxos a_1@erxos].freeze
  NAMES = ['ok', 'a', 'b', 'error', '', "\u00e9t\u00e9", "\u{1F600}", 'x' * 255].freeze
  INTEGERS = [0, 1, 255, 256, -1, (2**31) - 1, -(2**31), 2**31, (2**59) - 1, 2**59, 2**63, -(2**63), 2**64].freeze

  Encoded = Data.define(:bytes, :exact, :exports, :host_grammar)

  def initialize(values, encodings, key_seeds = [])
    @values = values
    @encodings = encodings
    @key_seeds = key_seeds
  end

  def term(depth)
    kind = depth.zero? ? value_pick(LEAVES) : value_pick(LEAVES + CONTAINERS)
    send(kind, depth)
  end

  private

  LEAVES = %i[integer integer float atom_term binary_term bitstring nil_term pid_term ref_term string_term].freeze
  CONTAINERS = %i[tuple_term list_term list_term map_term map_term fun_term export_term record_term].freeze

  def value_pick(list) = list[@values.rand(list.size)]
  def encoding_pick(list) = list[@encodings.rand(list.size)]
  def leaf(bytes, exact: true, exports: 0, host_grammar: true) = Encoded.new(bytes, exact, exports, host_grammar)
  def children(depth, count) = Array.new(count) { term(depth - 1) }
  def container(bytes, parts, exact: true, host_grammar: true)
    Encoded.new(bytes, exact && parts.all?(&:exact), parts.sum(&:exports), host_grammar && parts.all?(&:host_grammar))
  end

  # An integer in one of the encodings that hold it, and whether ERTS's
  # size pass counts that encoding exactly.
  def integer_bytes(value)
    encodings = []
    encodings << [small(value), true] if value.between?(0, 255)
    encodings << [int(value), true] if value.between?(-(2**31), (2**31) - 1)
    magnitude = value.abs.digits(256) + ([0] * @encodings.rand(3))
    encodings << [small_big(value.negative? ? 1 + @encodings.rand(9) : 0, magnitude), false]
    encodings << [large_big(value.negative? ? 1 : 0, magnitude), false]
    encoding_pick(encodings)
  end

  def integer(_depth)
    value = @values.rand(3).zero? ? @values.rand(2**200) - (2**199) : value_pick(INTEGERS + [@values.rand(1000) - 500])
    bytes, exact = integer_bytes(value)
    leaf(bytes, exact: exact)
  end

  def float(_depth) = leaf(EtfWire.float(value_pick([0.0, -0.0, 1.0, 1.5, -2.25e300, 5.0e-324, @values.rand])))
  def atom_bytes(name) = @encodings.rand(2).zero? ? atom(name) : long_atom(name)
  def atom_term(_depth) = leaf(atom_bytes(value_pick(NAMES)))
  def nil_term(_depth) = leaf(encoding_pick([nil_, string(''), list([])]))

  def pid_term(_depth)
    leaf(pid(value_pick(NODES), @values.rand(2**32), @values.rand(2**32), @values.rand(2**32)), host_grammar: false)
  end

  def ref_term(_depth)
    leaf(ref(value_pick(NODES), @values.rand(2**32), Array.new(4) { @values.rand(2**32) }), host_grammar: false)
  end

  def string_term(_depth) = leaf(string(@values.bytes(@values.rand(40))))

  def binary_term(_depth)
    bytes = @values.bytes(value_pick([0, 1, 7, 64, 65, 200]))
    encoded = bytes.empty? || @encodings.rand(2).zero? ? binary(bytes) : bits(bytes, 8)
    leaf(encoded, exact: bytes.bytesize <= 64)
  end

  # The unused low bits of the last byte are garbage, which ERTS ignores.
  def bitstring(_depth)
    bytes = @values.bytes(1 + @values.rand(9))
    trailing = 1 + @values.rand(7)
    last = (bytes.getbyte(-1) & (0xff << (8 - trailing)) & 0xff) | @encodings.rand(1 << (8 - trailing))
    leaf(bits(bytes.byteslice(0, bytes.bytesize - 1) + last.chr, trailing))
  end

  def tuple_term(depth)
    parts = children(depth, @values.rand(5))
    container(@encodings.rand(4).zero? ? large_tuple(*parts.map(&:bytes)) : tuple(*parts.map(&:bytes)), parts)
  end

  # A list of random elements, then either a tail of any term or, for a
  # proper list, a run of bytes that is written as a STRING_EXT tail or as
  # small-integer elements.
  def list_term(depth)
    parts = children(depth, @values.rand(6))
    if @values.rand(4).zero?
      tail = term(depth - 1)
      return container(segments(parts.map(&:bytes), tail.bytes), [*parts, tail])
    end
    run = @values.rand(3).zero? ? @values.bytes(1 + @values.rand(4)) : ''
    return container(segments(parts.map(&:bytes), string(run)), parts) if !run.empty? && @encodings.rand(2).zero?

    container(segments(parts.map(&:bytes) + run.bytes.map { |byte| small(byte) }, nil), parts)
  end

  # Elements cut into LIST_EXT segments, each the tail of the one before,
  # ending in tail, or in [] written as NIL_EXT or an empty STRING_EXT.
  def segments(elements, tail)
    ending = tail || encoding_pick([nil_, string('')])
    return ending if elements.empty? && @encodings.rand(3).positive?

    cut = elements.empty? ? 0 : @encodings.rand(elements.size + 1)
    rest = elements.drop(cut)
    list(elements.first(cut), rest.empty? ? ending : segments(rest, tail))
  end

  def map_term(depth)
    pairs = Array.new(value_pick([0, 1, 2, 3, 33])) { [key(depth), term(depth - 1)] }
    written = pairs.shuffle(random: @encodings)
    container(map(*written.map { |key, value| [key.bytes, value.bytes] }), pairs.flatten, exact: pairs.size <= 32)
  end

  def key(depth)
    seed = @values.rand(5).zero? && !@key_seeds.empty? ? value_pick(@key_seeds) : [@values.rand(2**32), [depth - 1, 1].min]
    @key_seeds << seed
    EtfGenerator.new(Random.new(seed.first), @encodings, []).term(seed.last)
  end

  def fun_term(depth)
    free = children(depth, @values.rand(3))
    bytes = fun(module_name: atom_bytes(value_pick(NAMES)), old_index: small(@encodings.rand(256)),
                old_uniq: int(@encodings.rand(2**31)), creator: pid(encoding_pick(NODES)), free: free.map(&:bytes),
                uniq: @values.bytes(16), index: @values.rand(4), arity: @values.rand(3))
    container(bytes, free, exact: false, host_grammar: false)
  end

  def export_term(_depth)
    arity, exact = integer_bytes(@values.rand(256))
    bytes = export(atom_bytes(value_pick(NAMES)), atom_bytes(value_pick(NAMES)), arity)
    leaf(bytes, exact: exact, exports: 1, host_grammar: false)
  end

  def record_term(depth)
    names = NAMES.reject(&:empty?).sample(@values.rand(4), random: @values)
    values = children(depth, names.size)
    container(record(names.map { |name| atom_bytes(name) }, values.map(&:bytes), module_name: atom('erlang'),
                                                                                 flags: @values.rand(2)),
              values, exact: false)
  end
end
