# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/etf_wire'

# liberx's erx_etf against binary_to_term/1 of the host's stock OTP, its
# oracle. Random terms of the domain grammar, each written in randomly
# chosen encodings (integers in every form that holds them, atoms short
# and long, lists split across LIST_EXT and STRING_EXT tails, whole-byte
# bitstrings as BIT_BINARY_EXT, garbage in a bitstring's unused bits, maps
# that sometimes repeat a key in fresh encodings), and the same terms
# mutated. For each input:
#
# * a term erx_etf accepts, stock OTP decodes, using every byte, to a term
#   exactly equal (=:=) to what erx_etf's reader and writer copy it to;
# * a generated term, unmutated, erx_etf accepts exactly when stock OTP
#   decodes it, so map keys are refused exactly when OTP refuses them, and
#   its decoded heap is at most the words erx_etf counted, and exactly
#   those words when it holds nothing ERTS's size pass overestimates.
#
# Two runs of the driver and one of erl serve the whole class.
class ErxEtfOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  SEED = Integer(ENV.fetch('ERX_ETF_SEED', '20261107'))
  GENERATED = 2500
  MUTATED = 2500

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
  # overestimates) and how many exports it holds: an export decodes to its
  # entry's fun, a literal that takes no heap, though erts_debug:flat_size/1
  # counts it as 2 words.
  class Generator
    include EtfWire

    NODES = %w[web@erxos system@erxos a.1@erxos].freeze
    NAMES = ['ok', 'a', 'b', 'error', '', "\u00e9t\u00e9", "\u{1F600}", 'x' * 255].freeze
    INTEGERS = [0, 1, 255, 256, -1, (2**31) - 1, -(2**31), 2**31, (2**59) - 1, 2**59, 2**63, -(2**63), 2**64].freeze

    Encoded = Data.define(:bytes, :exact, :exports)

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
    def leaf(bytes, exact: true, exports: 0) = Encoded.new(bytes, exact, exports)
    def children(depth, count) = Array.new(count) { term(depth - 1) }
    def container(bytes, parts, exact: true) = Encoded.new(bytes, exact && parts.all?(&:exact), parts.sum(&:exports))

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
    def pid_term(_depth) = leaf(pid(value_pick(NODES), @values.rand(2**32), @values.rand(2**32), @values.rand(2**32)))
    def ref_term(_depth) = leaf(ref(value_pick(NODES), @values.rand(2**32), Array.new(4) { @values.rand(2**32) }))
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
      Generator.new(Random.new(seed.first), @encodings, []).term(seed.last)
    end

    def fun_term(depth)
      free = children(depth, @values.rand(3))
      bytes = fun(module_name: atom_bytes(value_pick(NAMES)), old_index: small(@encodings.rand(256)),
                  old_uniq: int(@encodings.rand(2**31)), creator: pid(encoding_pick(NODES)), free: free.map(&:bytes),
                  uniq: @values.bytes(16), index: @values.rand(4), arity: @values.rand(3))
      container(bytes, free, exact: false)
    end

    def export_term(_depth)
      arity, exact = integer_bytes(@values.rand(256))
      leaf(export(atom_bytes(value_pick(NAMES)), atom_bytes(value_pick(NAMES)), arity), exact: exact, exports: 1)
    end

    def record_term(depth)
      names = NAMES.reject(&:empty?).sample(@values.rand(4), random: @values)
      values = children(depth, names.size)
      container(record(names.map { |name| atom_bytes(name) }, values.map(&:bytes), module_name: atom('erlang'),
                                                                                   flags: @values.rand(2)),
                values, exact: false)
    end
  end

  class << self
    def inputs
      @inputs ||= begin
        random = Random.new(SEED)
        generator = Generator.new(random, Random.new(SEED + 1))
        generated = Array.new(GENERATED) { generator.term(1 + random.rand(4)) }
        mutated = Array.new(MUTATED) { mutate(random, "\x83".b + generated[random.rand(GENERATED)].bytes) }
        { generated: generated.map { |term| ["\x83".b + term.bytes, term] }, mutated: mutated }
      end
    end

    def answers = (@answers ||= Dir.mktmpdir('erx-etf-oracle-') { |directory| compare(directory) })

    private

    # One to three edits: a byte changed, inserted or deleted, or the
    # input cut short.
    def mutate(random, bytes)
      out = bytes.dup
      (1 + random.rand(3)).times do
        at = random.rand(out.bytesize)
        case random.rand(4)
        when 0 then out.setbyte(at, random.rand(256))
        when 1 then out.insert(at, random.rand(256).chr)
        when 2 then out.slice!(at) if out.bytesize > 1
        else out = out.byteslice(0, at + 1)
        end
      end
      out
    end

    def compare(directory)
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      driver = EtfDriver.new(root: ROOT, runner: runner, directory: directory)
      all = inputs.fetch(:generated).map(&:first) + inputs.fetch(:mutated)
      checked = driver.check(all.map { |bytes| "d 1 1024 100000000 #{bytes.unpack1('H*')}" })
      copies = checked.zip(all).filter_map do |answer, bytes|
        "same #{bytes.unpack1('H*')} #{answer.split.fetch(2)}" if answer.start_with?('accepted ')
      end
      oracle = run_oracle(directory, runner, all.map { |bytes| "term #{bytes.unpack1('H*')}" } + copies)
      { checked: checked, terms: oracle.first(all.size), same: oracle.drop(all.size) }
    end

    def run_oracle(directory, runner, requests)
      erl = ENV.fetch('ERX_ERL', File.join(ROOT, 'build/oracle/jit/install/bin/erl'))
      erlc = ENV.fetch('ERX_ERLC', File.join(ROOT, 'build/oracle/jit/install/bin/erlc'))
      request_file = File.join(directory, 'oracle-requests')
      answer_file = File.join(directory, 'oracle-answers')
      File.write(request_file, requests.map { |line| "#{line}\n" }.join)
      runner.run(command(erlc, directory, ['-Werror', '-o', directory, File.join(ROOT, 'test/fixtures/etf_oracle.erl')]),
                 name: 'compile-etf-oracle', deadline: 60, chdir: directory)
      runner.run(command(erl, directory, ['-noshell', '-noinput', '-boot', 'no_dot_erlang', '-pa', directory,
                                          '-run', 'etf_oracle', 'main', request_file, answer_file]),
                 name: 'etf-oracle', deadline: 300, chdir: directory)
      File.read(answer_file).lines(chomp: true).tap do |lines|
        raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
      end
    end

    def command(program, directory, arguments)
      ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', "HOME=#{directory}", 'LANG=C', program, *arguments]
    end
  end

  def inputs = self.class.inputs
  def answers = self.class.answers
  def all_inputs = inputs.fetch(:generated).map(&:first) + inputs.fetch(:mutated)

  def test_every_accepted_term_decodes_in_stock_otp_to_its_copy
    same = answers.fetch(:same).each
    accepted = 0
    answers.fetch(:checked).zip(answers.fetch(:terms), all_inputs).each do |checked, oracle, bytes|
      next unless checked.start_with?('accepted ')

      accepted += 1
      context = bytes.unpack1('H*')[0, 120]
      verdict, used, = oracle.split
      assert_equal 'ok', verdict, context
      assert_equal bytes.bytesize, Integer(used), context
      assert_equal 'same', same.next, context
    end
    assert_operator accepted, :>, GENERATED / 2
  end

  def test_a_generated_term_is_accepted_exactly_when_stock_otp_decodes_it
    refused_keys = 0
    inputs.fetch(:generated).each_with_index do |(bytes, term), index|
      checked = answers.fetch(:checked).fetch(index)
      verdict, _, flat = answers.fetch(:terms).fetch(index).split
      context = bytes.unpack1('H*')[0, 120]
      if verdict == 'ok'
        assert checked.start_with?('accepted '), "#{context}: #{checked}"
        words = Integer(checked.split.fetch(1))
        heap = Integer(flat) - (2 * term.exports)
        assert_operator words, :>=, heap, context
        assert_equal heap, words, context if term.exact
      else
        assert_equal 'malformed map_key', checked.split[0, 2].join(' '), context
        refused_keys += 1
      end
    end
    # The corpus did repeat keys, and not only.
    assert_operator refused_keys, :>, 0
    assert_operator refused_keys, :<, GENERATED / 4
  end
end
