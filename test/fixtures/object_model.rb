# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# An independent model of the object store (kernel/core/object.c), written
# from docs/design-kernel.md, "Objects and capabilities": the object id
# permutation with its inverse, and one header's life as a value that each
# operation maps to its result and next value.
module ObjectModel
  LIVE = 1
  RELEASED = 2
  DELETED = 3
  OK = 0
  ESTALE = -2
  ELIMIT = -7
  MASK32 = 0xffff_ffff
  MASK64 = 0xffff_ffff_ffff_ffff
  COUNTER_END = MASK64
  # The encodings the ABI reserves: zero, "no object".
  RESERVED = [0].freeze

  module_function

  # murmur3's 64-bit finalizer over the half, doubled, and the round's key.
  def round(half, key)
    x = ((half << 32) | half) ^ key
    x ^= x >> 33
    x = (x * 0xff51afd7ed558ccd) & MASK64
    x ^= x >> 33
    x = (x * 0xc4ceb9fe1a85ec53) & MASK64
    x ^= x >> 33
    x & MASK32
  end

  def permute(key, counter)
    left = counter >> 32
    right = counter & MASK32
    key.each { |k| left, right = right, left ^ round(right, k) }
    (left << 32) | right
  end

  # The counter whose id is oid: the rounds undone in reverse order.
  def invert(key, oid)
    left = oid >> 32
    right = oid & MASK32
    key.reverse_each { |k| left, right = right ^ round(left, k), left }
    (left << 32) | right
  end

  # The id the store issues at counter, and the counter after it, or
  # [ELIMIT, nil, counter] once the counter is spent.
  def mint(key, counter)
    loop do
      return [ELIMIT, nil, counter] if counter == COUNTER_END

      oid = permute(key, counter)
      counter += 1
      return [OK, oid, counter] unless RESERVED.include?(oid)
    end
  end

  # One header's counts.
  Header = Data.define(:state, :ncaps, :refs) do
    def line(result) = "= #{result} #{state} #{ncaps} #{refs}"
  end

  FRESH = Header.new(state: LIVE, ncaps: 0, refs: 1)

  # The result of op on header and the header after it. Operations whose
  # precondition fails trap in the core and are not modelled here.
  def step(header, op)
    case op
    in 'add'
      return [ESTALE, header] unless header.state == LIVE
      return [ELIMIT, header] if header.ncaps == MASK32

      [OK, header.with(ncaps: header.ncaps + 1)]
    in 'remove'
      ncaps = header.ncaps - 1
      released = ncaps.zero?
      state = released && header.state == LIVE ? RELEASED : header.state
      [released ? 1 : 0, header.with(ncaps: ncaps, state: state)]
    in 'close'
      [header.state == DELETED ? 0 : 1, header.with(state: DELETED)]
    in 'ref'
      [0, header.with(refs: header.refs + 1)]
    in 'put'
      [header.refs == 1 ? 1 : 0, header.with(refs: header.refs - 1)]
    end
  end

  # Whether op keeps to its contract on header: a removal needs a counted
  # slot, and a reference is taken and dropped only on a record that
  # still has one.
  def allowed?(header, op)
    case op
    in 'remove' then header.ncaps.positive?
    in 'ref' | 'put' then header.refs.positive?
    in 'add' | 'close' then true
    end
  end
end
