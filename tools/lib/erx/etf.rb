# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'

module Erx
  # Erlang's external term format, limited to the host grammar of the host
  # link (docs/design-live.md, "Decoding"): the system grammar of
  # docs/design-domains.md ("The grammars") less pids and references. The
  # host tool builds calls with `encode` and reads the target's replies with
  # `decode`; to the host the target is untrusted, so `decode` checks every
  # byte against the grammar and its bounds before it builds a value.
  #
  # Terms map to Ruby values one to one:
  #
  #   integer             Integer
  #   float (finite)      Float
  #   atom                Atom, never a Symbol: no decoded name becomes one
  #   binary              String, binary encoding, frozen
  #   bitstring           Bitstring, for a bit length not a multiple of 8
  #   tuple               Tuple
  #   proper list         Array, frozen; a string is a list of integers
  #   improper list       ImproperList
  #   map                 Map (encoding also takes a Hash)
  #   record              Record
  #
  # A map is a Map, not a Hash: a Hash would hash its keys with Ruby's
  # recursive #hash and would merge 0.0 and -0.0, which exact equality
  # keeps apart. Two keys are the same key when their fingerprints are
  # equal (Fingerprint, a SHA-256 digest equal exactly when the terms are
  # equal under =:=).
  #
  # Bounds on decoding: at most MAX_BYTES of input; as the target bounds a
  # payload at 16 MiB decoded, at most MAX_DECODED_WORDS of an estimate of
  # ERTS's heap words (Budget); no term inside more than MAX_DEPTH
  # containers, in any position (a list continued by LIST_EXT or STRING_EXT
  # tails is one list, and a list of up to 65,535 bytes, which
  # term_to_binary writes as STRING_EXT, is a leaf); atoms of at most
  # MAX_ATOM_CHARACTERS characters; tuples of at most MAX_TUPLE_ARITY
  # elements; records of at most MAX_RECORD_FIELDS fields; integers of at
  # most MAX_BIG_BYTES bytes of magnitude (ERTS's BIG_ARITY_MAX words).
  # Every count is checked against the bytes left before anything is read
  # for it, and bytes after the term are refused, which binary_to_term does
  # not do. Encoding holds the tool's calls to the byte, depth and per-term
  # bounds; the target checks their decoded size.
  #
  # Neither direction recurses: each keeps an explicit stack, and the
  # decoder fingerprints map keys bottom up as it builds them. Ruby's own
  # ==, eql?, hash and inspect on a decoded Tuple, Array or Record do
  # recurse; MAX_DEPTH keeps them within the main thread's stack (where
  # they overflow between 3,000 and 10,000 levels; on a Fiber from about
  # 250), so code that compares or prints a decoded value does it on the
  # main thread. Map's own equality is iterative.
  module Etf
    class Error < Erx::Error; end
    # Bytes, or a value, outside the grammar.
    class Malformed < Error; end
    # A term inside the grammar but past one of its bounds.
    class OverLimit < Error; end
    # A Ruby object that is no term, handed to the encoder or to a value
    # type: a mistake of the calling code, not of the target.
    class Unencodable < Error; end

    MAX_BYTES = 16 * 1024 * 1024
    MAX_DECODED_WORDS = MAX_BYTES / 8
    MAX_DEPTH = 1_024
    MAX_ATOM_CHARACTERS = 255
    MAX_TUPLE_ARITY = (1 << 24) - 1
    MAX_RECORD_FIELDS = 65_535
    MAX_BIG_BYTES = 65_535 * 8
    MAX_STRING_EXT = 65_535

    VERSION = 131
    module Tag
      NEW_FLOAT = 70
      BIT_BINARY = 77
      RECORD = 67
      SMALL_INTEGER = 97
      INTEGER = 98
      SMALL_TUPLE = 104
      LARGE_TUPLE = 105
      NIL = 106
      STRING = 107
      LIST = 108
      BINARY = 109
      SMALL_BIG = 110
      LARGE_BIG = 111
      MAP = 116
      ATOM_UTF8 = 118
      SMALL_ATOM_UTF8 = 119
    end

    # An atom, named by its text. Building one checks the text, so an Atom
    # in hand is always encodable. A decoded name is untrusted text: it
    # reaches a terminal only through the line escape.
    Atom = Data.define(:name) do
      def initialize(name:)
        text = name.is_a?(Symbol) ? name.name : name
        raise Unencodable, "an atom is named by a String or Symbol, not #{name.class}" unless text.is_a?(String)

        text = text.dup.force_encoding(Encoding::UTF_8)
        raise Malformed, 'an atom name is not valid UTF-8' unless text.valid_encoding?
        raise OverLimit, "an atom of #{text.length} characters" if text.length > MAX_ATOM_CHARACTERS

        super(name: text.freeze)
      end
    end

    Tuple = Data.define(:elements) do
      def initialize(elements:)
        raise Unencodable, "tuple elements are an Array, not #{elements.class}" unless elements.is_a?(Array)
        raise OverLimit, "a tuple of #{elements.size} elements" if elements.size > MAX_TUPLE_ARITY

        super(elements: elements.frozen? ? elements : elements.dup.freeze)
      end
    end

    # A list whose last tail is not []: at least one element, and a tail
    # that is not itself a list.
    ImproperList = Data.define(:elements, :tail) do
      def initialize(elements:, tail:)
        unless elements.is_a?(Array) && !elements.empty?
          raise Unencodable, 'an improper list has a nonempty Array of elements'
        end
        raise Unencodable, 'an improper list tail is not a list' if tail.is_a?(Array) || tail.is_a?(ImproperList)

        super(elements: elements.frozen? ? elements : elements.dup.freeze, tail: tail)
      end
    end

    # A bitstring of bytes.bytesize - 1 whole bytes and trailing_bits (1 to 7)
    # high bits of the last byte; the unused low bits are kept zero, so
    # equal bitstrings are equal values. Whole bytes are a String instead.
    Bitstring = Data.define(:bytes, :trailing_bits) do
      def initialize(bytes:, trailing_bits:)
        raise Unencodable, 'bitstring bytes are a nonempty String' unless bytes.is_a?(String) && !bytes.empty?
        unless trailing_bits.is_a?(Integer) && trailing_bits.between?(1, 7)
          raise Unencodable, 'a bitstring has 1 to 7 trailing bits'
        end

        kept = bytes.b
        kept.setbyte(-1, kept.getbyte(-1) & (0xff << (8 - trailing_bits)) & 0xff)
        super(bytes: kept.freeze, trailing_bits: trailing_bits)
      end

      def bit_size = ((bytes.bytesize - 1) * 8) + trailing_bits
    end

    # A native record: its defining module and name, whether it is
    # exported, and its fields in order, from field-name Atom to value.
    # Field order is part of the value, as in ERTS, so equality compares
    # the fields as ordered pairs.
    Record = Data.define(:module_name, :name, :exported, :fields) do
      def initialize(module_name:, name:, exported:, fields:)
        raise Unencodable, 'a record module and name are Atoms' unless module_name.is_a?(Atom) && name.is_a?(Atom)
        raise Unencodable, 'a record is exported or not' unless [true, false].include?(exported)
        raise Unencodable, 'record fields are a Hash' unless fields.is_a?(Hash)
        raise Unencodable, 'record field names are Atoms' unless fields.each_key.all?(Atom)
        raise OverLimit, "a record of #{fields.size} fields" if fields.size > MAX_RECORD_FIELDS

        super(module_name: module_name, name: name, exported: exported,
              fields: fields.frozen? ? fields : fields.dup.freeze)
      end

      def eql?(other) = other.is_a?(Record) && identity.eql?(other.identity)
      def ==(other) = other.is_a?(Record) && identity == other.identity
      def hash = identity.hash

      protected

      def identity = [module_name, name, exported, fields.to_a]
    end

    # A map, as its key-value pairs in the order they were written. A Map
    # built by hand is not checked for repeated keys; the target refuses
    # one that repeats a key. Equality is exact (1 and 1.0 differ, so do
    # 0.0 and -0.0) and ignores order.
    Map = Data.define(:pairs) do
      def initialize(pairs:)
        unless pairs.is_a?(Array) && pairs.all? { |pair| pair.is_a?(Array) && pair.size == 2 }
          raise Unencodable, 'map pairs are an Array of [key, value] Arrays'
        end

        super(pairs: pairs.frozen? ? pairs : pairs.map { |pair| pair.dup.freeze }.freeze)
      end

      def self.from_hash(hash) = new(pairs: hash.to_a)

      def size = pairs.size
      def keys = pairs.map(&:first)

      # The value under the key equal to `key` under exact equality.
      def fetch(key)
        wanted = Fingerprint.of(key)
        pair = pairs.find { |candidate, _| Fingerprint.of(candidate) == wanted }
        raise KeyError, 'no such key in the map' unless pair

        pair.last
      end

      def eql?(other) = other.is_a?(Map) && Fingerprint.of(self) == Fingerprint.of(other)
      def ==(other) = eql?(other)
      def hash = Fingerprint.of(self).hash
    end

    module_function

    # The external term format of a value, VERSION byte first.
    def encode(term) = Encoder.new.run(term)

    # The term encoded in bytes, which must hold exactly one term.
    def decode(bytes)
      raise Unencodable, "decoding takes a String, not #{bytes.class}" unless bytes.is_a?(String)
      raise OverLimit, "an encoded term of #{bytes.bytesize} bytes" if bytes.bytesize > MAX_BYTES

      reader = Reader.new(bytes.b)
      raise Malformed, 'no version byte 131' unless reader.u8 == VERSION

      term = Decoder.new(reader).run
      raise Malformed, "#{reader.remaining} bytes after the term" unless reader.remaining.zero?

      term
    end

    module Bounds
      def self.check_depth(depth)
        raise OverLimit, "a term inside #{depth} containers" if depth > MAX_DEPTH
      end
    end

    # A digest of a term, equal for two terms exactly when they are equal
    # under =:=: integers by value, floats by their bits (0.0 and -0.0
    # differ, as in OTP 27 and later), a list by its elements and tail
    # whatever its wire form, a map by its pairs sorted by key digest, a
    # record by its fields in order. `of` walks a whole value with an
    # explicit stack; the decoder builds the same digests bottom up from
    # `leaf`, `container`, `list` and `map`.
    module Fingerprint
      module_function

      def digest(text) = Digest::SHA256.digest(text)

      EMPTY_LIST = Digest::SHA256.digest('n')

      def leaf(value)
        case value
        when Integer then digest("i#{value.negative? ? '-' : '+'}#{value.abs.to_s(16)}")
        when Float then digest("f#{[value].pack('G')}")
        when Atom then digest("a#{value.name.b}")
        when String then digest("b#{value.b}")
        when Bitstring then digest("s#{value.trailing_bits.chr}#{value.bytes}")
        when Array then list(value.map { |element| leaf(element) }, EMPTY_LIST)
        else raise Unencodable, "no term for a #{value.class}"
        end
      end

      def container(kind, digests) = digest("#{kind}#{[digests.size].pack('N')}#{digests.join}")
      def list(elements, tail) = elements.empty? ? tail : container('l', [*elements, tail])
      def map(pairs) = container('m', pairs.map(&:join).sort)
      def record(exported, digests) = container(exported ? 'R' : 'r', digests)

      # Children before parents: a container is pushed back with the count
      # of its children, whose digests are on `done` when it pops again.
      def of(value)
        done = []
        stack = [[value, nil]]
        until stack.empty?
          item, count = stack.pop
          children = children_of(item)
          if children.nil?
            done << leaf(item)
          elsif count.nil?
            stack << [item, children.size]
            children.reverse_each { |child| stack << [child, nil] }
          else
            done << combine(item, done.pop(count))
          end
        end
        done.fetch(0)
      end

      # The parts of a container in digest order, or nil for a leaf
      # (including []).
      def children_of(value)
        case value
        when Array then value.empty? ? nil : value
        when Tuple then value.elements
        when ImproperList then [*value.elements, value.tail]
        when Map then value.pairs.flatten(1)
        when Hash then value.to_a.flatten(1)
        when Record then [value.module_name, value.name, *value.fields.to_a.flatten(1)]
        end
      end

      def combine(value, digests)
        case value
        when Array then list(digests, EMPTY_LIST)
        when Tuple then container('t', digests)
        when ImproperList then list(digests[0...-1], digests.last)
        when Map, Hash then map(digests.each_slice(2).to_a)
        when Record then record(value.exported, digests)
        end
      end
    end

    # Writes a value depth first. The stack holds what is left to write:
    # values with their depth, and literal bytes such as a list's closing
    # NIL. A container pushes its parts in reverse so they pop in order.
    class Encoder
      Pending = Data.define(:value, :depth)

      def initialize
        @out = String.new(capacity: 64, encoding: Encoding::BINARY) << VERSION.chr
      end

      def run(term)
        stack = [Pending.new(term, 0)]
        until stack.empty?
          case stack.pop
          in String => literal then @out << literal
          in Pending(value:, depth:) then write(value, depth, stack)
          end
          raise OverLimit, "an encoded term over #{MAX_BYTES} bytes" if @out.bytesize > MAX_BYTES
        end
        @out.freeze
      end

      private

      def write(value, depth, stack)
        Bounds.check_depth(depth)
        case value
        when Integer then integer(value)
        when Float then float(value)
        when Atom then atom(value)
        when String then @out << [Tag::BINARY, value.bytesize].pack('CN') << value.b
        when Bitstring then @out << [Tag::BIT_BINARY, value.bytes.bytesize, value.trailing_bits].pack('CNC') << value.bytes
        when Tuple then tuple(value, depth, stack)
        when Array then list(value, depth, stack)
        when ImproperList then improper_list(value, depth, stack)
        when Map then map(value.pairs, depth, stack)
        when Hash then map(value.to_a, depth, stack)
        when Record then record(value, depth, stack)
        else raise Unencodable, "no term for a #{value.class}"
        end
      end

      # The smallest form, as term_to_binary chooses it.
      def integer(value)
        if value.between?(0, 255)
          @out << [Tag::SMALL_INTEGER, value].pack('CC')
        elsif value.between?(-(1 << 31), (1 << 31) - 1)
          @out << [Tag::INTEGER, value].pack('Cl>')
        else
          hex = value.abs.to_s(16)
          magnitude = [hex.rjust(hex.size + (hex.size % 2), '0')].pack('H*').reverse
          raise OverLimit, "an integer of #{magnitude.bytesize} bytes" if magnitude.bytesize > MAX_BIG_BYTES

          sign = value.negative? ? 1 : 0
          header = if magnitude.bytesize <= 255
                     [Tag::SMALL_BIG, magnitude.bytesize, sign].pack('CCC')
                   else
                     [Tag::LARGE_BIG, magnitude.bytesize, sign].pack('CNC')
                   end
          @out << header << magnitude
        end
      end

      def float(value)
        raise Unencodable, "no term for the float #{value}" unless value.finite?

        @out << [Tag::NEW_FLOAT, value].pack('CG')
      end

      def atom(value)
        text = value.name.b
        @out << if text.bytesize <= 255
                  [Tag::SMALL_ATOM_UTF8, text.bytesize].pack('CC')
                else
                  [Tag::ATOM_UTF8, text.bytesize].pack('Cn')
                end
        @out << text
      end

      def tuple(value, depth, stack)
        arity = value.elements.size
        @out << (arity <= 255 ? [Tag::SMALL_TUPLE, arity].pack('CC') : [Tag::LARGE_TUPLE, arity].pack('CN'))
        push_parts(value.elements, depth, stack)
      end

      def list(value, depth, stack)
        if value.empty?
          @out << Tag::NIL.chr
        elsif value.size <= MAX_STRING_EXT && value.all? { |element| element.is_a?(Integer) && element.between?(0, 255) }
          @out << [Tag::STRING, value.size].pack('Cn') << value.pack('C*')
        else
          @out << [Tag::LIST, value.size].pack('CN')
          stack << Tag::NIL.chr
          push_parts(value, depth, stack)
        end
      end

      def improper_list(value, depth, stack)
        @out << [Tag::LIST, value.elements.size].pack('CN')
        push_parts([*value.elements, value.tail], depth, stack)
      end

      def map(pairs, depth, stack)
        @out << [Tag::MAP, pairs.size].pack('CN')
        push_parts(pairs.flatten(1), depth, stack)
      end

      def record(value, depth, stack)
        @out << [Tag::RECORD, value.fields.size, value.exported ? 1 : 0].pack('CNC')
        [value.module_name, value.name, *value.fields.keys].each { |name| atom(name) }
        push_parts(value.fields.values, depth, stack)
      end

      def push_parts(parts, depth, stack)
        parts.reverse_each { |part| stack << Pending.new(part, depth + 1) }
      end
    end

    # Bounds-checked reads from the bytes of one encoded term.
    class Reader
      def initialize(bytes)
        @bytes = bytes
        @position = 0
      end

      def remaining = @bytes.bytesize - @position
      def offset = @position

      def peek
        need(1)
        @bytes.getbyte(@position)
      end

      def u8 = read(1, 'C')
      def u16 = read(2, 'n')
      def u32 = read(4, 'N')

      def take(length)
        need(length)
        slice = @bytes.byteslice(@position, length)
        @position += length
        slice
      end

      # A count of one or four bytes, of items that each take at least
      # `unit` bytes: over `limit` it is past a bound, and more than what is
      # left can hold it is malformed, both before any item is read.
      def count(width, unit:, limit: nil)
        value = width == 1 ? u8 : u32
        raise OverLimit, "#{value} items at offset #{@position}, over #{limit}" if limit && value > limit
        if value * unit > remaining
          raise Malformed, "#{value} items at offset #{@position} need more than the #{remaining} bytes left"
        end

        value
      end

      private

      def read(length, format)
        need(length)
        value = @bytes.unpack1(format, offset: @position)
        @position += length
        value
      end

      def need(length)
        raise Malformed, "the term ends at offset #{@position}, #{length} more bytes needed" if length > remaining
      end
    end

    # The decoded size so far, in an estimate of ERTS's heap words: a cons
    # cell 2, a tuple 1 plus its arity, a map 3 plus 2 per pair, a record 2
    # plus 1 per field, a float 2, a binary 2 plus its bytes in words, a
    # big integer 1 plus its bytes in words; small integers, atoms, [], and
    # the empty tuple and map nothing.
    class Budget
      def initialize
        @words = 0
      end

      def charge(words)
        @words += words
        raise OverLimit, "a term of more than #{MAX_DECODED_WORDS} words decoded" if @words > MAX_DECODED_WORDS
      end

      def self.words_of(bytes) = (bytes + 7) / 8
    end

    # Reads one term. A leaf becomes a value at once; a container becomes a
    # frame on an explicit stack, so the stack's size is the depth of the
    # next term. A frame takes its parts through `accept` and says through
    # `next_part` whether it needs another (:part) or is complete (:done),
    # when its value goes to the frame below it. Inside a map key every
    # value is handed up with its fingerprint, so the map refuses a
    # repeated key without walking the key again.
    class Decoder
      def initialize(reader)
        @reader = reader
        @budget = Budget.new
        @atoms = {}
      end

      def run
        stack = []
        loop do
          Bounds.check_depth(stack.size)
          keyed = !stack.empty? && stack.last.keyed_part?
          item = leaf_or_frame(keyed)
          if item.is_a?(Frame)
            stack << item
          elsif stack.empty?
            return item
          else
            stack.last.accept(item, keyed ? Fingerprint.leaf(item) : nil)
          end
          while stack.last.next_part(@reader) == :done
            frame = stack.pop
            return frame.value if stack.empty?

            stack.last.accept(frame.value, frame.digest)
          end
        end
      end

      private

      def leaf_or_frame(keyed)
        offset = @reader.offset
        case (tag = @reader.u8)
        when Tag::SMALL_INTEGER then @reader.u8
        when Tag::INTEGER then @reader.take(4).unpack1('l>')
        when Tag::SMALL_BIG then big(@reader.u8)
        when Tag::LARGE_BIG then big(@reader.u32)
        when Tag::NEW_FLOAT then float
        when Tag::SMALL_ATOM_UTF8, Tag::ATOM_UTF8 then atom_after(tag)
        when Tag::BINARY then binary(@reader.u32)
        when Tag::BIT_BINARY then bitstring
        when Tag::NIL then EMPTY_LIST
        when Tag::STRING then string(@reader.u16)
        when Tag::SMALL_TUPLE then tuple(@reader.count(1, unit: 1), keyed)
        when Tag::LARGE_TUPLE then tuple(@reader.count(4, unit: 1, limit: MAX_TUPLE_ARITY), keyed)
        when Tag::LIST then list(@reader.count(4, unit: 1), keyed)
        when Tag::MAP then map(@reader.count(4, unit: 2), keyed)
        when Tag::RECORD then record(keyed)
        else raise Malformed, "tag #{tag} at offset #{offset} is outside the host grammar"
        end
      end

      # Sign byte (any nonzero is negative, as in ERTS), then the magnitude's
      # bytes, least significant first.
      def big(length)
        raise OverLimit, "an integer of #{length} bytes" if length > MAX_BIG_BYTES

        negative = @reader.u8 != 0
        @budget.charge(1 + Budget.words_of(length))
        magnitude = @reader.take(length).reverse.unpack1('H*').to_i(16)
        negative ? -magnitude : magnitude
      end

      def float
        value = @reader.take(8).unpack1('G')
        raise Malformed, "the float #{value} is not finite" unless value.finite?

        @budget.charge(2)
        value
      end

      # One Atom per name in a term, so many equal atoms cost one.
      def atom_after(tag)
        length = tag == Tag::SMALL_ATOM_UTF8 ? @reader.u8 : @reader.u16
        text = @reader.take(length)
        @atoms[text] ||= Atom.new(name: text)
      end

      def atom
        tag = @reader.u8
        raise Malformed, "tag #{tag} where an atom belongs" unless [Tag::SMALL_ATOM_UTF8, Tag::ATOM_UTF8].include?(tag)

        atom_after(tag)
      end

      def binary(length)
        bytes = @reader.take(length)
        @budget.charge(2 + Budget.words_of(length))
        bytes.freeze
      end

      def string(length)
        bytes = @reader.take(length)
        @budget.charge(2 * length)
        length.zero? ? EMPTY_LIST : bytes.bytes.freeze
      end

      # Length, trailing bits, then the bytes. Eight trailing bits are whole
      # bytes, which ERTS accepts and decodes to a binary.
      def bitstring
        length = @reader.u32
        trailing_bits = @reader.u8
        unless length.positive? && trailing_bits.between?(1, 8)
          raise Malformed, "a bitstring of #{length} bytes and #{trailing_bits} trailing bits"
        end

        bytes = binary(length)
        trailing_bits == 8 ? bytes : Bitstring.new(bytes: bytes, trailing_bits: trailing_bits)
      end

      def tuple(arity, keyed)
        @budget.charge(1 + arity) if arity.positive?
        TupleFrame.new(arity, keyed: keyed)
      end

      def list(count, keyed)
        @budget.charge(2 * count)
        ListFrame.new(count, keyed: keyed, budget: @budget)
      end

      def map(arity, keyed)
        @budget.charge(3 + (2 * arity)) if arity.positive?
        MapFrame.new(arity, keyed: keyed)
      end

      # Field count, flags (0, or 1 for exported), module, name and the
      # distinct field names; the values follow as the frame's parts.
      def record(keyed)
        count = @reader.count(4, unit: 3, limit: MAX_RECORD_FIELDS)
        flags = @reader.u8
        raise Malformed, "record flags #{flags}" unless [0, 1].include?(flags)

        @budget.charge(2 + count)
        module_name = atom
        name = atom
        names = Array.new(count) { atom }
        raise Malformed, 'a record with a repeated field name' unless names.uniq.size == count

        RecordFrame.new(module_name: module_name, name: name, exported: flags == 1, names: names, keyed: keyed)
      end
    end

    EMPTY_LIST = [].freeze
    EMPTY_TUPLE = Tuple.new(elements: EMPTY_LIST)
    EMPTY_MAP = Map.new(pairs: EMPTY_LIST)

    # A container being decoded. Inside a map key (`keyed`) it keeps its
    # parts' fingerprints, through `note`, and gives its own from them.
    class Frame
      def initialize(keyed:)
        @keyed = keyed
        @digests = []
      end

      # Whether the next part is read inside a map key.
      def keyed_part? = @keyed
      def digest = @keyed ? own_digest : nil

      private

      def note(digest)
        @digests << digest if @keyed
      end
    end

    class TupleFrame < Frame
      def initialize(arity, keyed:)
        super(keyed: keyed)
        @arity = arity
        @elements = []
      end

      def accept(value, digest)
        note(digest)
        @elements << value
      end

      def next_part(_reader) = @elements.size < @arity ? :part : :done
      def value = @arity.zero? ? EMPTY_TUPLE : Tuple.new(elements: @elements.freeze)

      private

      def own_digest = Fingerprint.container('t', @digests)
    end

    # Parts alternate key and value. Every key is read keyed, and a key
    # whose fingerprint the map already holds is refused as it is read.
    class MapFrame < Frame
      def initialize(arity, keyed:)
        super(keyed: keyed)
        @arity = arity
        @pairs = []
        @key_digests = {}
        @key = nil
        @key_read = false
      end

      def keyed_part? = @keyed || !@key_read

      def accept(value, digest)
        note(digest)
        if @key_read
          @pairs << [@key, value].freeze
          @key_read = false
        else
          raise Malformed, 'a map with a repeated key' if @key_digests.key?(digest)

          @key_digests[digest] = true
          @key = value
          @key_read = true
        end
      end

      def next_part(_reader) = @pairs.size < @arity ? :part : :done
      def value = @arity.zero? ? EMPTY_MAP : Map.new(pairs: @pairs.freeze)

      private

      def own_digest = Fingerprint.map(@digests.each_slice(2).to_a)
    end

    class RecordFrame < Frame
      def initialize(module_name:, name:, exported:, names:, keyed:)
        super(keyed: keyed)
        @module_name = module_name
        @name = name
        @exported = exported
        @names = names
        @values = []
      end

      def accept(value, digest)
        note(digest)
        @values << value
      end

      def next_part(_reader) = @values.size < @names.size ? :part : :done

      def value
        Record.new(module_name: @module_name, name: @name, exported: @exported,
                   fields: @names.zip(@values).to_h.freeze)
      end

      private

      def own_digest
        heads = [@module_name, @name].map { |atom| Fingerprint.leaf(atom) }
        fields = @names.zip(@digests).flat_map { |name, digest| [Fingerprint.leaf(name), digest] }
        Fingerprint.record(@exported, heads + fields)
      end
    end

    # A list's elements, then its tail. Besides answering whether a part
    # is due, `next_part` reads a tail that is itself a list (NIL,
    # STRING_EXT or another LIST_EXT) here, into the same elements, so a
    # chain of LIST_EXT tails costs no depth and no copying and the value
    # is the one list ERTS decodes; any other tail it asks for as a part.
    # LIST_EXT with a count of 0 is only a wrapper around its tail
    # (otp/erts/emulator/beam/external.c, dec_term).
    class ListFrame < Frame
      def initialize(count, keyed:, budget:)
        super(keyed: keyed)
        @remaining = count
        @budget = budget
        @elements = []
        @tail = nil # [the tail] once known, so a tail of any value fits
        @tail_digest = nil
      end

      def accept(value, digest)
        if @remaining.positive?
          note(digest)
          @elements << value
          @remaining -= 1
        else
          @tail = [value]
          @tail_digest = digest
        end
      end

      def next_part(reader)
        return :part if @remaining.positive?
        return :done if @tail

        list_tail(reader)
      end

      # A proper list, the tail alone when there are no elements, or an
      # improper list.
      def value
        if @tail.equal?(EMPTY_LIST)
          @elements.freeze
        elsif @elements.empty?
          @tail.first
        else
          ImproperList.new(elements: @elements.freeze, tail: @tail.first)
        end
      end

      private

      def own_digest = Fingerprint.list(@digests, @tail_digest)

      def list_tail(reader)
        loop do
          case reader.peek
          when Tag::NIL
            reader.u8
            return end_proper
          when Tag::STRING
            reader.u8
            bytes = reader.take(reader.u16).bytes
            @budget.charge(2 * bytes.size)
            bytes.each { |byte| note(Fingerprint.leaf(byte)) } if @keyed
            @elements.concat(bytes)
            return end_proper
          when Tag::LIST
            reader.u8
            @remaining = reader.count(4, unit: 1)
            @budget.charge(2 * @remaining)
            return :part if @remaining.positive?
          else
            return :part
          end
        end
      end

      def end_proper
        @tail = EMPTY_LIST
        @tail_digest = Fingerprint::EMPTY_LIST
        :done
      end
    end

    private_constant :Tag, :Bounds, :Fingerprint, :Encoder, :Reader, :Budget, :Decoder,
                     :Frame, :TupleFrame, :MapFrame, :RecordFrame, :ListFrame
  end
end
