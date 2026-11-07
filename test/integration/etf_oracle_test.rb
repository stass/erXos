# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/etf'
require_relative '../../tools/lib/erx/runner'

# The host tool's term codec against the host's stock OTP, its oracle. For
# each term of the corpus: what term_to_binary writes decodes in Ruby to
# the expected value; what Ruby writes, binary_to_term reads back as the
# same term; and without a map of two keys or more, whose key order
# term_to_binary picks, Ruby writes the very bytes term_to_binary does.
# Bytes outside the host grammar that stock OTP writes are refused, and
# bytes stock OTP refuses Ruby refuses too. All of it is one run of erl,
# made once for the whole class.
class EtfOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  Etf = Erx::Etf

  def self.atom(name) = Etf::Atom[name]
  def self.tuple(*elements) = Etf::Tuple[elements]
  def self.map(hash = {}) = Etf::Map.from_hash(hash)

  # Pairs of an Erlang expression and the Ruby value it is.
  ACCEPTED = [
    ['0', 0], ['255', 255], ['256', 256], ['-1', -1],
    ['2147483647', (2**31) - 1], ['-2147483648', -(2**31)],
    ['2147483648', 2**31], ['-2147483649', -(2**31) - 1],
    ['1 bsl 64', 2**64], ['-(1 bsl 64)', -(2**64)],
    ['(1 bsl 2040) - 1', (2**2040) - 1], ['1 bsl 2040', 2**2040],
    ['((1 bsl (65535 * 64 - 1)) - 1) * 2 + 1', (2**(65_535 * 64)) - 1],
    ['0.0', 0.0], ['-0.0', -0.0], ['1.5', 1.5], ['-1.0e300', -1.0e300],
    ['5.0e-324', 5.0e-324], ['1.7976931348623157e308', 1.7976931348623157e308],
    ['ok', atom('ok')], ["''", atom('')], ["'hello world'", atom('hello world')],
    ['list_to_atom([233])', atom("\u00e9")],
    ['list_to_atom(lists:duplicate(255, $a))', atom('a' * 255)],
    ['list_to_atom(lists:duplicate(255, 16#1F600))', atom("\u{1F600}" * 255)],
    ['<<>>', ''.b], ['<<1, 2, 3>>', "\x01\x02\x03".b],
    ['binary:copy(<<7>>, 70000)', ("\x07" * 70_000).b],
    ['<<1:1>>', Etf::Bitstring["\x80".b, 1]], ['<<255, 3:2>>', Etf::Bitstring["\xff\xc0".b, 2]],
    ['<<0:7>>', Etf::Bitstring["\x00".b, 7]],
    ['{}', tuple], ['{ok}', tuple(atom('ok'))],
    ['{a, 1, <<"x">>}', tuple(atom('a'), 1, 'x'.b)],
    ['list_to_tuple(lists:seq(1, 256))', Etf::Tuple[(1..256).to_a]],
    ['[]', []], ['[1, 2, 3]', [1, 2, 3]], ['"abc"', [97, 98, 99]], ['[256]', [256]],
    ['[1, a]', [1, atom('a')]], ['[a | b]', Etf::ImproperList[[atom('a')], atom('b')]],
    ['[1, 2 | 3]', Etf::ImproperList[[1, 2], 3]], ['[[]]', [[]]],
    ['[<<>> | <<>>]', Etf::ImproperList[[''.b], ''.b]],
    ['lists:duplicate(65535, 1)', [1] * 65_535], ['lists:duplicate(70000, 1)', [1] * 70_000],
    ['#{}', map], ['#{a => 1}', map(atom('a') => 1)],
    ['#{a => 1, b => [2]}', map(atom('a') => 1, atom('b') => [2])],
    ['#{1 => a, 1.0 => b}', map(1 => atom('a'), 1.0 => atom('b'))],
    ['#{0.0 => a, -0.0 => b}', Etf::Map[[[0.0, atom('a')], [-0.0, atom('b')]]]],
    ['#{[0.0] => a, [-0.0] => b}', Etf::Map[[[[0.0], atom('a')], [[-0.0], atom('b')]]]],
    ['#{{x} => #{y => z}}', map(tuple(atom('x')) => map(atom('y') => atom('z')))],
    ['maps:from_list([{K, K} || K <- lists:seq(1, 40)])', Etf::Map[(1..40).map { |key| [key, key] }]],
    ["{'$host_cap', 3}", tuple(atom('$host_cap'), 3)],
    ["{'$pid', <<\"<0.42.0>\">>}", tuple(atom('$pid'), '<0.42.0>'.b)],
    ['{reply, [{ok, #{name => <<"inspect">>}}, {error, system_limit}]}',
     tuple(atom('reply'), [tuple(atom('ok'), map(atom('name') => 'inspect'.b)),
                           tuple(atom('error'), atom('system_limit'))])]
  ].freeze

  # Right-nested tuples at the depth bound, and one level past it.
  def self.nested_source(depth) = "lists:foldl(fun(_, A) -> {x, A} end, nil, lists:seq(1, #{depth}))"
  DEEPEST = [nested_source(Etf::MAX_DEPTH),
             Etf::MAX_DEPTH.times.reduce(atom('nil')) { |inner, _| tuple(atom('x'), inner) }].freeze
  TOO_DEEP = nested_source(Etf::MAX_DEPTH + 1)

  # Native records, which no expression writes without a definition:
  # they go from Ruby to stock OTP and back.
  RECORDS = [
    Etf::Record[module_name: atom('erlang'), name: atom('ok'), exported: true,
                fields: { atom('a') => 1, atom('b') => tuple }],
    Etf::Record[module_name: atom('erlang'), name: atom('error'), exported: false, fields: {}],
    # The same fields in two orders are two records, so two keys.
    map(Etf::Record[module_name: atom('erlang'), name: atom('ok'), exported: true,
                    fields: { atom('a') => 1, atom('b') => 2 }] => 1,
        Etf::Record[module_name: atom('erlang'), name: atom('ok'), exported: true,
                    fields: { atom('b') => 2, atom('a') => 1 }] => 2)
  ].freeze

  # Terms stock OTP writes outside the host grammar: Ruby refuses each.
  OUTSIDE_GRAMMAR = [
    'term_to_binary(self())', 'term_to_binary(make_ref())',
    'term_to_binary(fun() -> ok end)', 'term_to_binary(fun erlang:abs/1)',
    'term_to_binary(list_to_port("#Port<0.1>"))',
    'term_to_binary(lists:duplicate(100, a), [compressed])',
    'term_to_binary(a, [{minor_version, 0}])', 'term_to_binary(1.5, [{minor_version, 0}])',
    'term_to_binary([self()])'
  ].freeze

  # Bytes stock OTP refuses, with the error Ruby raises for them. Bytes
  # after the term, which binary_to_term ignores and the host grammar
  # refuses, are test/host/etf_test.rb's.
  def self.wire(*bytes) = [131, *bytes].pack('C*')
  REFUSED = [
    ['', Etf::Malformed], [[130, 106].pack('C*'), Etf::Malformed],
    [wire(104, 2, 97, 1), Etf::Malformed],
    [wire(119, 1, 0xff), Etf::Malformed], [wire(119, 2, 0xc0, 0x80), Etf::Malformed],
    [wire(119, 3, 0xed, 0xa0, 0x80), Etf::Malformed],
    [[131, 70, 0x7f, 0xf8, 0, 0, 0, 0, 0, 0].pack('C*'), Etf::Malformed],
    [[131, 70, 0x7f, 0xf0, 0, 0, 0, 0, 0, 0].pack('C*'), Etf::Malformed],
    [wire(77, 0, 0, 0, 1, 0, 0xff), Etf::Malformed], [wire(77, 0, 0, 0, 1, 9, 0xff), Etf::Malformed],
    [wire(77, 0, 0, 0, 0, 3), Etf::Malformed],
    [wire(116, 0, 0, 0, 2, 97, 1, 97, 1, 97, 1, 97, 2), Etf::Malformed],
    [wire(67, 0, 0, 0, 0, 2, 119, 1, 109, 119, 1, 114), Etf::Malformed],
    [wire(67, 0, 0, 0, 2, 0, 119, 1, 109, 119, 1, 114, 119, 1, 102, 119, 1, 102, 97, 1, 97, 2), Etf::Malformed],
    [wire(108, 0, 0, 0, 2, 97, 1, 106), Etf::Malformed],
    [wire(109, 0, 0, 0, 5, 1, 2), Etf::Malformed],
    [[131, 118, 1, 0].pack('C*') + ('a' * 256), Etf::OverLimit],
    [[131, 111].pack('C*') + [(65_535 * 8) + 1, 0].pack('NC') + ("\x01" * ((65_535 * 8) + 1)), Etf::OverLimit]
  ].freeze

  # Bytes stock OTP accepts in forms term_to_binary never writes, with the
  # value they are.
  ODD_FORMS = [
    [wire(108, 0, 0, 0, 0, 106), []], [wire(108, 0, 0, 0, 0, 119, 1, 97), atom('a')],
    [wire(108, 0, 0, 0, 1, 97, 1, 108, 0, 0, 0, 1, 97, 2, 106), [1, 2]],
    [wire(108, 0, 0, 0, 1, 97, 1, 107, 0, 2, 2, 3), [1, 2, 3]],
    [wire(108, 0, 0, 0, 1, 97, 1, 107, 0, 0), [1]], [wire(107, 0, 0), []],
    [wire(77, 0, 0, 0, 2, 8, 1, 2), "\x01\x02".b], [wire(77, 0, 0, 0, 1, 1, 0xff), Etf::Bitstring["\x80".b, 1]],
    [wire(110, 2, 1, 0, 0), 0], [wire(110, 1, 7, 5), -5], [wire(118, 0, 2, 111, 107), atom('ok')],
    [wire(116, 0, 0, 0, 2, 97, 2, 106, 97, 1, 106), map(1 => [], 2 => [])]
  ].freeze

  class << self
    def answers
      @answers ||= Dir.mktmpdir('etf-oracle-') { |directory| run_oracle(directory) }
    end

    def requests
      @requests ||= [
        *ACCEPTED.flat_map { |source, value| accepted_requests(source, value) },
        "encode #{hex(DEEPEST.first)}", "encode #{hex(TOO_DEEP)}",
        *RECORDS.map { |record| "decode #{hex(Etf.encode(record))}" },
        *OUTSIDE_GRAMMAR.map { |source| "bytes #{hex(source)}" },
        *REFUSED.map { |bytes, _| "refuse #{hex(bytes)}" },
        *ODD_FORMS.map { |bytes, _| "decode #{hex(bytes)}" }
      ].freeze
    end

    def answer(request) = answers.fetch(requests.index(request))
    def hex(text) = text.unpack1('H*')

    private

    def accepted_requests(source, value)
      ["encode #{hex(source)}", "check #{hex(source)} #{hex(Etf.encode(value))}",
       "decode #{hex(Etf.encode(value))}"]
    end

    def run_oracle(directory)
      erl = ENV.fetch('ERX_ERL', File.join(ROOT, 'build/oracle/jit/install/bin/erl'))
      erlc = ENV.fetch('ERX_ERLC', File.join(ROOT, 'build/oracle/jit/install/bin/erlc'))
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      request_file = File.join(directory, 'requests')
      answer_file = File.join(directory, 'answers')
      File.write(request_file, requests.map { |line| "#{line}\n" }.join)
      runner.run(command(erlc, directory, ['-Werror', '-o', directory, File.join(ROOT, 'test/fixtures/etf_oracle.erl')]),
                 name: 'compile-etf-oracle', deadline: 60, chdir: directory)
      runner.run(command(erl, directory, ['-noshell', '-noinput', '-boot', 'no_dot_erlang', '-pa', directory,
                                          '-run', 'etf_oracle', 'main', request_file, answer_file]),
                 name: 'etf-oracle', deadline: 120, chdir: directory)
      File.read(answer_file).lines(chomp: true).tap do |lines|
        raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
      end.freeze
    end

    def command(program, directory, arguments)
      ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', "HOME=#{directory}", 'LANG=C',
       program, *arguments]
    end
  end

  def bytes_of(answer) = [answer].pack('H*')
  def answer(request) = self.class.answer(request)
  def hex(text) = self.class.hex(text)

  # Strict equality: eql? tells 1 from 1.0 at every level, where == does
  # not, and Map's tells 0.0 from -0.0; Float#eql? does not, so without a
  # map of several keys, whose order the bytes would show, the encodings
  # are compared too.
  def assert_same_term(expected, actual, context)
    assert expected.eql?(actual), -> { "#{context}: expected #{expected.inspect[0, 300]}, got #{actual.inspect[0, 300]}" }
    assert_equal Etf.encode(expected), Etf.encode(actual), context unless several_keys?(expected)
  end

  def test_stock_encodings_decode_to_the_expected_values
    ACCEPTED.each do |source, value|
      assert_same_term value, Etf.decode(bytes_of(answer("encode #{hex(source)}"))), source
    end
  end

  def test_stock_otp_reads_what_ruby_writes_as_the_same_term
    ACCEPTED.each do |source, value|
      encoded = hex(Etf.encode(value))
      assert_equal 'same', answer("check #{hex(source)} #{encoded}"), source
      assert_same_term value, Etf.decode(bytes_of(answer("decode #{encoded}"))), source
    end
  end

  def test_ruby_writes_the_bytes_term_to_binary_writes
    ACCEPTED.reject { |_, value| several_keys?(value) }.each do |source, value|
      assert_equal answer("encode #{hex(source)}"), hex(Etf.encode(value)).upcase, source
    end
  end

  def test_depth_bound_holds_against_stock_encodings
    source, value = DEEPEST
    stock = bytes_of(answer("encode #{hex(source)}"))
    assert_same_term value, Etf.decode(stock), 'deepest'
    assert_equal stock, Etf.encode(value)
    assert_raises(Etf::OverLimit) { Etf.decode(bytes_of(answer("encode #{hex(TOO_DEEP)}"))) }
  end

  def test_records_survive_stock_otp
    RECORDS.each do |record|
      encoded = Etf.encode(record)
      back = bytes_of(answer("decode #{hex(encoded)}"))
      assert_equal encoded, back
      assert_same_term record, Etf.decode(back), hex(encoded)[0, 80]
    end
  end

  def test_terms_outside_the_host_grammar_are_refused
    OUTSIDE_GRAMMAR.each do |source|
      bytes = bytes_of(answer("bytes #{hex(source)}"))
      assert_raises(Etf::Malformed, source) { Etf.decode(bytes) }
    end
  end

  def test_bytes_stock_otp_refuses_are_refused
    REFUSED.each do |bytes, error|
      assert_equal 'refused', answer("refuse #{hex(bytes)}"), hex(bytes)[0, 80]
      assert_raises(error, hex(bytes)[0, 80]) { Etf.decode(bytes) }
    end
  end

  def test_forms_term_to_binary_never_writes_decode_as_stock_otp_does
    ODD_FORMS.each do |bytes, value|
      decoded = Etf.decode(bytes)
      assert_same_term value, decoded, hex(bytes)
      assert_same_term value, Etf.decode(bytes_of(answer("decode #{hex(bytes)}"))), hex(bytes)
    end
  end

  private

  # Whether a value holds a map of two keys or more anywhere, by an
  # explicit stack, as the corpus's deep terms would overflow recursion.
  def several_keys?(value)
    stack = [value]
    until stack.empty?
      case stack.pop
      in Etf::Map(pairs:)
        return true if pairs.size > 1

        stack.concat(pairs.flatten(1))
      in Array => list then stack.concat(list)
      in Etf::Tuple(elements:) then stack.concat(elements)
      in Etf::ImproperList(elements:, tail:) then stack.push(*elements, tail)
      in Etf::Record(fields:) then stack.concat(fields.values)
      else nil
      end
    end
    false
  end
end
