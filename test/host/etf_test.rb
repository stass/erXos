# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/etf'
require_relative '../../tools/fuzz/etf'

# The host tool's term codec on its own: each bound of the host grammar is
# met at its limit and refused one past it; values outside the grammar are
# refused; decoding never recurses, so a hostile key cannot overflow a
# Fiber's stack; decoded values are frozen and atoms never become Symbols.
# Agreement with stock OTP is test/integration/etf_oracle_test.rb's.
class EtfTest < Minitest::Test
  Etf = Erx::Etf

  def atom(name) = Etf::Atom[name]
  def map(hash = {}) = Etf::Map.from_hash(hash)
  def wire(*bytes) = [131, *bytes].pack('C*')
  def record(fields) = Etf::Record[module_name: atom('m'), name: atom('r'), exported: true, fields: fields]

  # A tuple {{...{x, x}..., x}, x} whose inner tuples are each the first
  # element of the next: `depth` levels of nesting around the innermost x.
  def left_nested(depth) = depth.times.reduce(atom('x')) { |inner, _| Etf::Tuple[[inner, atom('x')]] }
  def left_nested_bytes(depth) = wire(*([104, 2] * depth), *([119, 1, 120] * (depth + 1)))

  def test_round_trip_of_each_kind
    value = Etf::Tuple[[atom('ok'), -3, 2**100, 1.5, 'b'.b, [1, 2], [atom('a'), 300],
                        Etf::ImproperList[[1], atom('t')], map(atom('k') => []), Etf::Bitstring["\xa5".b, 4],
                        record(atom('f') => 1)]]
    assert value.eql?(Etf.decode(Etf.encode(value)))
  end

  def test_decoded_values_are_frozen_and_atoms_are_not_symbols
    value = Etf.decode(Etf.encode(Etf::Tuple[[atom('fresh_atom_name'), 'b'.b, [1, 300], map(1 => 'v'.b)]]))
    name, binary, list, decoded_map = value.elements
    assert_instance_of Etf::Atom, name
    assert_equal 'fresh_atom_name', name.name
    assert [value, value.elements, name.name, binary, list, decoded_map, decoded_map.pairs, decoded_map.fetch(1)].all?(&:frozen?)
    assert_equal Encoding::UTF_8, name.name.encoding
    assert_equal Encoding::BINARY, binary.encoding
  end

  def test_map_equality_is_exact_and_ignores_order
    assert_equal map(atom('a') => 1, atom('b') => 2), map(atom('b') => 2, atom('a') => 1)
    refute_equal map(1 => 1), map(1.0 => 1)
    refute_equal Etf::Map[[[0.0, 1]]], Etf::Map[[[-0.0, 1]]]
    assert_equal 2, Etf::Map[[[0.0, 1], [-0.0, 2]]].fetch(-0.0)
    assert_raises(KeyError) { map(1 => 1).fetch(1.0) }
  end

  def test_record_field_order_is_part_of_the_value
    refute record(atom('a') => 1, atom('b') => 2).eql?(record(atom('b') => 2, atom('a') => 1))
    assert record(atom('a') => 1).eql?(record(atom('a') => 1))
  end

  def test_encoded_size_bound
    limit = Etf::MAX_BYTES - 6
    assert_equal Etf::MAX_BYTES, Etf.encode('a' * limit).bytesize
    assert_raises(Etf::OverLimit) { Etf.encode('a' * (limit + 1)) }
    assert_raises(Etf::OverLimit) { Etf.decode(Etf.encode('a' * limit) + "\x00") }
  end

  # 2 words of binary header plus the bytes in words: the largest binary
  # within the decoded bound, and one byte more.
  def test_decoded_size_bound
    largest = (Etf::MAX_DECODED_WORDS - 2) * 8
    assert_equal largest, Etf.decode(Etf.encode('a' * largest)).bytesize
    assert_raises(Etf::OverLimit) { Etf.decode(Etf.encode('a' * (largest + 1))) }
    empties = wire(108, *[1_100_000].pack('N').bytes) + ([104, 0].pack('C*') * 1_100_000) + [106].pack('C')
    assert_raises(Etf::OverLimit) { Etf.decode(empties) }
  end

  # Every position counts: first and last elements, map keys and values,
  # record fields, list elements and improper tails. Each wrapper adds the
  # levels it is paired with; the tail one, a list around a tuple, two.
  def test_depth_bound_in_every_position
    wrappers = [
      [->(inner) { Etf::Tuple[[inner, atom('x')]] }, 1], [->(inner) { Etf::Tuple[[atom('x'), inner]] }, 1],
      [->(inner) { map(inner => 1) }, 1], [->(inner) { map(1 => inner) }, 1], [->(inner) { [inner] }, 1],
      [->(inner) { Etf::ImproperList[[inner], 1] }, 1],
      [->(inner) { Etf::ImproperList[[1], Etf::Tuple[[inner]]] }, 2],
      [->(inner) { record(atom('f') => inner) }, 1]
    ]
    wrappers.each_with_index do |(wrap, levels), index|
      deepest = Array.new(Etf::MAX_DEPTH / levels) { wrap }.reduce(atom('x')) { |inner, step| step.call(inner) }
      encoded = Etf.encode(deepest)
      assert_equal encoded, Etf.encode(Etf.decode(encoded)), "wrapper #{index}"
      assert_raises(Etf::OverLimit, "wrapper #{index}") { Etf.encode(wrap.call(deepest)) }
    end
  end

  def test_depth_bound_on_decoding
    assert left_nested(Etf::MAX_DEPTH).eql?(Etf.decode(left_nested_bytes(Etf::MAX_DEPTH)))
    assert_raises(Etf::OverLimit) { Etf.decode(left_nested_bytes(Etf::MAX_DEPTH + 1)) }
  end

  # A map whose one key is 1,023 nested tuples: the decoder fingerprints
  # it bottom up, so even a Fiber's small stack decodes it.
  def test_a_deep_map_key_decodes_on_a_fiber
    bytes = wire(116, 0, 0, 0, 1, *([104, 1] * (Etf::MAX_DEPTH - 1)), 106, 97, 0)
    decoded = Fiber.new { Etf.decode(bytes) }.resume
    assert_equal 1, decoded.size
  end

  # Nested map keys are fingerprinted once each, not once per enclosing map.
  def test_nested_map_keys_cost_linear_time
    inner = wire(*([116, 0, 0, 0, 1] * 500), 108, *[200_000].pack('N').bytes)
              .then { |head| head + ([106].pack('C') * 200_000) + [106].pack('C') + ([97, 0].pack('C*') * 500) }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Etf.decode(inner)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  def test_a_chain_of_list_tails_is_one_flat_list
    count = 200_000
    chain = wire(*([108, 0, 0, 0, 1, 97, 1] * count), 106)
    assert_equal [1] * count, Etf.decode(chain)
  end

  def test_atom_length_bound
    assert_equal 'a' * 255, Etf.decode(Etf.encode(atom('a' * 255))).name
    assert_raises(Etf::OverLimit) { atom('a' * 256) }
    assert_raises(Etf::OverLimit) { Etf.decode(wire(118, 1, 0) + ('a' * 256)) }
    assert_raises(Etf::Malformed) { atom("\xff".b) }
    assert_raises(Etf::Unencodable) { atom(42) }
  end

  def test_tuple_arity_bound
    assert_raises(Etf::OverLimit) { Etf.decode(wire(105, 1, 0, 0, 0)) }
    assert_raises(Etf::Malformed) { Etf.decode(wire(105, 0, 255, 255, 255)) }
  end

  def test_record_field_bound
    fields = Array.new(Etf::MAX_RECORD_FIELDS) { |index| [atom("f#{index}"), 0] }.to_h
    assert_equal Etf::MAX_RECORD_FIELDS, Etf.decode(Etf.encode(record(fields))).fields.size
    assert_raises(Etf::OverLimit) { Etf.decode(wire(67, 0, 1, 0, 0, 0)) }
    assert_raises(Etf::OverLimit) { record(fields.merge(atom('one_more') => 0)) }
  end

  def test_integer_size_bound
    largest = (2**(Etf::MAX_BIG_BYTES * 8)) - 1
    assert_equal largest, Etf.decode(Etf.encode(largest))
    assert_equal(-largest, Etf.decode(Etf.encode(-largest)))
    assert_raises(Etf::OverLimit) { Etf.encode(largest + 1) }
    assert_raises(Etf::OverLimit) { Etf.decode(wire(111) + [Etf::MAX_BIG_BYTES + 1, 0].pack('NC')) }
  end

  def test_counts_past_the_bytes_left_are_refused_before_reading
    [wire(108, 255, 255, 255, 255), wire(116, 0, 0, 0, 1, 97), wire(104, 3, 97, 1),
     wire(109, 255, 255, 255, 255), wire(107, 0, 9, 1)].each do |bytes|
      assert_raises(Etf::Malformed) { Etf.decode(bytes) }
    end
  end

  def test_bytes_after_the_term_are_refused
    assert_raises(Etf::Malformed) { Etf.decode(wire(106, 106)) }
  end

  def test_values_outside_the_grammar_are_not_encoded
    [Float::NAN, Float::INFINITY, :ok, nil, true, Object.new, 1r, [Float::NAN]].each do |value|
      assert_raises(Etf::Unencodable, value.inspect) { Etf.encode(value) }
    end
    assert_raises(Etf::Unencodable) { Etf::ImproperList[[], 1] }
    assert_raises(Etf::Unencodable) { Etf::ImproperList[[1], [2]] }
    assert_raises(Etf::Unencodable) { Etf::Bitstring['a'.b, 8] }
    assert_raises(Etf::Unencodable) { Etf::Bitstring[''.b, 1] }
    assert_raises(Etf::Unencodable) { Etf::Map[[[1]]] }
    assert_raises(Etf::Unencodable) { Etf.decode(:not_bytes) }
  end

  def test_bitstring_unused_bits_are_cleared
    assert_equal "\xe0".b, Etf::Bitstring["\xff".b, 3].bytes
    assert_equal Etf::Bitstring["\xe0".b, 3], Etf.decode(wire(77, 0, 0, 0, 1, 3, 0xff))
  end

  def test_repeated_keys_are_refused_whatever_their_wire_form
    small_and_big_zero = wire(116, 0, 0, 0, 2, 97, 0, 97, 1, 110, 0, 0, 97, 2)
    string_and_list = wire(116, 0, 0, 0, 2, 107, 0, 1, 7, 97, 1, 108, 0, 0, 0, 1, 97, 7, 106, 97, 2)
    [small_and_big_zero, string_and_list].each do |bytes|
      assert_raises(Etf::Malformed) { Etf.decode(bytes) }
    end
  end

  def test_fuzz_target_runs_its_seeds
    assert_operator Erx::EtfFuzz.run(seconds: 1, seed: 7), :>, 0
  end
end
