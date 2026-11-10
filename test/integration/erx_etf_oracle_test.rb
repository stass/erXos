# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/etf_generator'
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
#   those words when it holds nothing ERTS's size pass overestimates;
#   among them the terms that keep the most of erx_etf's scratch per byte,
#   checked with exactly the scratch their length promises.
#
# Two runs of the driver and one of erl serve the whole class.
class ErxEtfOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  SEED = Integer(ENV.fetch('ERX_ETF_SEED', '20261107'))
  GENERATED = 2500
  MUTATED = 2500
  # Maps inside a key, whose 2-byte pairs keep 32 bytes of scratch each,
  # with keys repeated and distinct, and a record's distinct field names.
  DENSE = [
    EtfWire.map([EtfWire.map(*Array.new(200) { [EtfWire.nil_, EtfWire.nil_] }), EtfWire.nil_]),
    EtfWire.map([EtfWire.map(*Array.new(200) { |key| [EtfWire.small(key), EtfWire.nil_] }), EtfWire.nil_]),
    EtfWire.record(Array.new(200) { |field| EtfWire.atom(field.to_s) }, Array.new(200) { EtfWire.nil_ })
  ].map { |bytes| EtfGenerator::Encoded.new(bytes, false, 0) }.freeze

  class << self
    def inputs
      @inputs ||= begin
        random = Random.new(SEED)
        generator = EtfGenerator.new(random, Random.new(SEED + 1))
        generated = Array.new(GENERATED) { generator.term(1 + random.rand(4)) } + DENSE
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
