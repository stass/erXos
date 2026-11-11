# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Hand-encoded start frames of the program protocol (docs/design-abi.md#program-protocol,
# Fixtures), each with its verdict and, for an accepted frame, its fields written by hand.
# Each frame chooses its encodings byte by byte with the Etf helpers below, so the frames
# hold what no builder writes: every encoding of a value, map pairs out of order, a
# capability past 2^63 - 1, empty LIST_EXT wrappers and lists in several segments.
# test/host/prog_profile_test.rb runs them through liberx's C check and compares the
# fields its accessors read (written again by test/fixtures/prog_profile_driver.c and
# decoded by Etf.decode) with the ones here, and adds them to the differential corpus.
module ProgProfileFrames
  # A tuple in an expected value. An Integer is an integer, a Symbol an atom, a String a
  # binary, an Array a proper list and a Hash a map.
  Tuple = Data.define(:items)

  def self.t(*items) = Tuple.new(items: items)

  # name: a Symbol; bytes: the frame; verdict: "accept" or "REASON KIND", as the
  # differential corpus writes it; fields: the term an accepted frame decodes to.
  Fixture = Data.define(:name, :bytes, :verdict, :fields)

  # The external term format's tags, one writer per encoding a fixture uses.
  module Etf
    module_function

    NIL = "\x6a".b.freeze
    # An empty LIST_EXT, which ERTS's decoder reads as its tail.
    WRAPPER = "\x6c\x00\x00\x00\x00".b.freeze

    def frame(term) = "\x83".b + term
    def small(n) = [97, n].pack('CC')
    def int(n) = [98, n].pack('Cl>')
    def small_big(n) = [110, magnitude(n).bytesize, 0].pack('CCC') + magnitude(n)
    def large_big(n) = [111, magnitude(n).bytesize, 0].pack('CNC') + magnitude(n)
    def atom(name) = [119, name.bytesize].pack('CC') + name.b
    def long_atom(name) = [118, name.bytesize].pack('Cn') + name.b
    def binary(text) = [109, text.bytesize].pack('CN') + text.b
    def bits(text) = [77, text.bytesize, 8].pack('CNC') + text.b
    def tuple(*items) = [104, items.size].pack('CC') + items.join.b
    def large_tuple(*items) = [105, items.size].pack('CN') + items.join.b
    def list(items, tail = NIL) = [108, items.size].pack('CN') + items.join.b + tail
    def string(bytes) = [107, bytes.bytesize].pack('Cn') + bytes.b
    def wrapped(term, count) = (WRAPPER * count) + term

    # MAP_EXT with its pairs in the order given, each [key, value] already encoded.
    def map(pairs) = [116, pairs.size].pack('CN') + pairs.flatten.join.b

    def magnitude(n) = n.digits(256).pack('C*')

    # The term a frame holds, in the shape of a fixture's fields. Raises on bytes
    # outside the tags the driver's writer uses or the fixtures name.
    def decode(bytes)
      raise ArgumentError, 'no version byte' unless bytes.getbyte(0) == 131

      term, at = term(bytes.b, 1)
      raise ArgumentError, "#{bytes.bytesize - at} bytes after the term" unless at == bytes.bytesize

      term
    end

    def term(b, at)
      case b.getbyte(at)
      when 97 then [b.getbyte(at + 1), at + 2]
      when 98 then [b.byteslice(at + 1, 4).unpack1('l>'), at + 5]
      when 110 then big(b, at + 3, b.getbyte(at + 1), b.getbyte(at + 2))
      when 111 then big(b, at + 6, b.byteslice(at + 1, 4).unpack1('N'), b.getbyte(at + 5))
      when 118 then text(b, at + 3, b.byteslice(at + 1, 2).unpack1('n')).then { |s, n| [s.to_sym, n] }
      when 119 then text(b, at + 2, b.getbyte(at + 1)).then { |s, n| [s.to_sym, n] }
      when 109 then text(b, at + 5, b.byteslice(at + 1, 4).unpack1('N'))
      when 104 then items(b, at + 2, b.getbyte(at + 1)).then { |xs, n| [Tuple.new(items: xs), n] }
      when 105 then items(b, at + 5, b.byteslice(at + 1, 4).unpack1('N')).then { |xs, n| [Tuple.new(items: xs), n] }
      when 106 then [[], at + 1]
      when 107 then text(b, at + 3, b.byteslice(at + 1, 2).unpack1('n')).then { |s, n| [s.bytes, n] }
      when 108 then cons(b, at)
      when 116 then items(b, at + 5, 2 * b.byteslice(at + 1, 4).unpack1('N')).then { |xs, n| [xs.each_slice(2).to_h, n] }
      else raise ArgumentError, "tag #{b.getbyte(at).inspect} at byte #{at}"
      end
    end

    def big(b, at, count, sign)
      digits = b.byteslice(at, count) or raise ArgumentError, 'truncated'
      value = digits.bytes.reverse.reduce(0) { |acc, byte| (acc << 8) | byte }
      [sign.zero? ? value : -value, at + count]
    end

    def text(b, at, count)
      bytes = b.byteslice(at, count)
      raise ArgumentError, 'truncated' unless bytes&.bytesize == count

      [bytes, at + count]
    end

    def items(b, at, count)
      count.times.reduce([[], at]) { |(xs, n), _| term(b, n).then { |x, m| [xs + [x], m] } }
    end

    def cons(b, at)
      head, at = items(b, at + 5, b.byteslice(at + 1, 4).unpack1('N'))
      tail, at = term(b, at)
      raise ArgumentError, 'improper list' unless tail.is_a?(Array)

      [head + tail, at]
    end
  end

  extend Etf

  NIL = Etf::NIL
  WRAPPER = Etf::WRAPPER

  FRAME_MAX = 196_608
  ARGS_MAX = 131_072

  # The start map's pairs as builders encode them, and its fields.
  BASE_PAIRS = {
    pid: small(2), ppid: small(1), pgid: small(2),
    argv: list([binary('prog')]), env: list([binary('HOME=/')]), cwd: binary('/'),
    spawn: atom('false'), sigmask: NIL, sigignore: NIL, umask: small(18),
    data_area: tuple(small(100), small(4)),
    fds: list([tuple(small(0), tuple(atom('tty'), small(1), atom('read'))),
               tuple(small(1), tuple(atom('dup'), small(0)))])
  }.freeze
  BASE_FIELDS = {
    pid: 2, ppid: 1, pgid: 2, argv: ['prog'], env: ['HOME=/'], cwd: '/', spawn: :false,
    sigmask: [], sigignore: [], umask: 18, data_area: t(100, 4),
    fds: [t(0, t(:tty, 1, :read)), t(1, t(:dup, 0))]
  }.freeze

  def self.start(pairs) = frame(tuple(atom('erx_start'), small(1), map(pairs.map { |key, value| [atom(key.to_s), value] })))

  def self.accepted(name, pairs, fields)
    Fixture.new(name: name, bytes: start(pairs), verdict: 'accept', fields: t(:erx_start, 1, fields))
  end

  def self.refused(name, pairs, verdict) = Fixture.new(name: name, bytes: start(pairs), verdict: verdict, fields: nil)

  # Five descriptors, each a {fd, null} entry, in three LIST_EXT segments whose last tail is
  # an empty STRING_EXT; order gives the fds in the order they are written.
  def self.segmented(order)
    entries = order.map { |fd| tuple(small(fd), atom('null')) }
    list(entries[0, 2], list(entries[2, 2], list(entries[4, 1], string(''))))
  end

  # Every encoding of the wire grammar a value may take, with the map's pairs in reverse.
  ENCODINGS = accepted(:encodings, BASE_PAIRS.merge(
    pid: int(2), ppid: small_big(1), pgid: large_big(2),
    argv: list([bits('prog'), binary('a')]), env: NIL, cwd: bits('/home'), spawn: long_atom('true'),
    sigmask: list([long_atom('sigint'), atom('sigterm')]), sigignore: string(''),
    data_area: large_tuple(small(100), int(4)),
    fds: list([tuple(small(0), large_tuple(long_atom('tty'), int(1), long_atom('read'))),
               large_tuple(int(1), tuple(atom('dup'), int(0)))])
  ).to_a.reverse, BASE_FIELDS.merge(
    argv: %w[prog a], env: [], cwd: '/home', spawn: :true, sigmask: %i[sigint sigterm], data_area: t(100, 4)
  ))

  # Capability values that only a big integer holds.
  CAP_ABOVE_INT64 = accepted(:cap_above_int64, BASE_PAIRS.merge(
    data_area: tuple(small_big(2**63), small(4)), image: tuple(atom('object'), small_big(2**64 - 1))
  ), BASE_FIELDS.merge(data_area: t(2**63, 4), image: t(:object, 2**64 - 1)))

  # A field, a list, a list's element and a union's tuple, each behind more empty
  # LIST_EXT wrappers than the profile's 16 levels.
  WRAPPERS_PAST_DEPTH = accepted(:wrappers_past_depth, BASE_PAIRS.merge(
    pid: wrapped(small(2), 40),
    fds: wrapped(list([wrapped(tuple(small(0), wrapped(tuple(atom('tty'), small(1), atom('read')), 40)), 40),
                       tuple(small(1), tuple(atom('dup'), small(0)))]), 40)
  ), BASE_FIELDS)

  SEGMENTED = accepted(:segmented, BASE_PAIRS.merge(fds: segmented([0, 1, 2, 3, 4])),
                       BASE_FIELDS.merge(fds: (0..4).map { |fd| t(fd, :null) }))
  SEGMENTED_OUT_OF_ORDER = refused(:segmented_out_of_order, BASE_PAIRS.merge(fds: segmented([0, 2, 1, 3, 4])),
                                   'order fds')

  # A start frame of exactly FRAME_MAX bytes: one argument at the args total with its NUL,
  # the rest of the bound in empty wrappers around sigignore and in cwd's length.
  def self.at_frame_max(name, extra)
    arg = 'a' * (ARGS_MAX - 1)
    bare = start(BASE_PAIRS.merge(argv: list([binary(arg)]), env: NIL)).bytesize
    wrappers, cwd_bytes = (FRAME_MAX - bare).divmod(WRAPPER.bytesize)
    cwd = '/' + ('c' * (cwd_bytes + extra))
    pairs = BASE_PAIRS.merge(argv: list([binary(arg)]), env: NIL, cwd: binary(cwd), sigignore: wrapped(NIL, wrappers))
    return refused(name, pairs, 'size start') if extra.positive?

    accepted(name, pairs, BASE_FIELDS.merge(argv: [arg], env: [], cwd: cwd))
  end

  ALL = [ENCODINGS, CAP_ABOVE_INT64, WRAPPERS_PAST_DEPTH, SEGMENTED, SEGMENTED_OUT_OF_ORDER,
         at_frame_max(:at_frame_max, 0), at_frame_max(:past_frame_max, 1)].freeze
end
