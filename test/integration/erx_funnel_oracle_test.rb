# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/etf_generator'
require_relative '../fixtures/funnel_wire'

# liberx's funnel grammar against the host's stock OTP, its oracle:
#
# * every control term erx_funnel_control accepts, among random control
#   terms of every operation in random encodings and the same terms
#   mutated, binary_to_term/1 decodes to the tuple the control record
#   names, element by element;
# * every payload erx_funnel_payload accepts, among EtfGenerator's random
#   terms, is charged exactly the words ERTS's own size pass charges it,
#   measured on stock OTP's distribution input (test/fixtures/funnel_oracle.erl
#   says how), including the terms whose size ERTS overestimates.
#
# One run of the driver and one of erl serve the whole class.
class ErxFunnelOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  SEED = Integer(ENV.fetch('ERX_FUNNEL_SEED', '20261108'))
  CONTROLS = 1500
  MUTATED = 1500
  PAYLOADS = 2000

  # Random control terms of every operation, each element in a random
  # encoding of a random value of its kind.
  class ControlGenerator
    include EtfWire

    NODES = %w[web@erxos system@erxos a_1@erxos].freeze
    PAYLOAD = [22, 24, 26, 28, 29, 33].freeze

    def initialize(random) = @random = random

    # The control term's bytes and the payload length its frame declares.
    def control
      number = [1, 7, 19, 20, 22, 24, 26, 28, 29, 31, 33, 35, 36].sample(random: @random)
      ["\x83".b + tuple(integer(number), *elements(number)), PAYLOAD.include?(number) ? 9 : 0]
    end

    private

    def elements(number)
      case number
      when 1, 7, 22, 24, 26 then [a_pid, a_pid]
      when 19, 20, 28 then [a_pid, a_pid, a_ref]
      when 29 then [a_ref, a_pid, a_pid, tuple(an_atom, an_atom, integer(@random.rand(256))), an_option_list]
      when 31 then [a_ref, a_pid, integer(@random.rand(1 << 27)), @random.rand(2).zero? ? a_pid : an_atom]
      when 33 then [a_pid, a_ref]
      else [integer(1 + @random.rand((1 << 64) - 1)), a_pid, a_pid]
      end
    end

    def a_pid = pid(NODES.sample(random: @random), *Array.new(3) { @random.rand(1 << 32) })
    def a_ref = ref(NODES.sample(random: @random), @random.rand(1 << 32), Array.new(4) { @random.rand(1 << 32) })
    def an_atom = [method(:atom), method(:long_atom)].sample(random: @random).call(%w[m f link badarg].sample(random: @random))

    def an_option_list
      options = Array.new(@random.rand(4)) do
        case @random.rand(4)
        when 0 then an_atom
        when 1 then tuple(an_atom, an_atom)
        when 2 then tuple(an_atom, integer(@random.rand(1 << 40)))
        else tuple(an_atom, map([atom('size'), integer(@random.rand(1000))], [atom('kill'), atom('true')]))
        end
      end
      options.empty? ? [nil_, string('')].sample(random: @random) : list(options)
    end

    # value in each wire form that holds it.
    def integer(value)
      forms = []
      forms << small(value) if value.between?(0, 255)
      forms << int(value) if value.between?(-(2**31), (2**31) - 1)
      digits = value.abs.digits(256)
      forms << small_big(value.negative? ? 1 : 0, digits + Array.new(@random.rand(2), 0))
      forms.sample(random: @random)
    end
  end

  class << self
    def answers = (@answers ||= Dir.mktmpdir('erx-funnel-oracle-') { |directory| compare(directory) })

    private

    def inputs
      random = Random.new(SEED)
      generator = ControlGenerator.new(random)
      controls = Array.new(CONTROLS) { generator.control }
      mutated = Array.new(MUTATED) do
        bytes, payload_len = controls[random.rand(CONTROLS)]
        [mutate(random, bytes), payload_len]
      end
      terms = EtfGenerator.new(random, Random.new(SEED + 1))
      { controls: controls + mutated, payloads: Array.new(PAYLOADS) { "\x83".b + terms.term(1 + random.rand(4)).bytes } }
    end

    def mutate(random, bytes)
      out = bytes.dup
      at = 1 + random.rand(out.bytesize - 1)
      case random.rand(3)
      when 0 then out.setbyte(at, random.rand(256))
      when 1 then out.insert(at, random.rand(256).chr)
      else out.slice!(at)
      end
      out
    end

    def compare(directory)
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      driver = FunnelDriver.new(root: ROOT, runner: runner, directory: directory)
      given = inputs
      requests = given.fetch(:controls).map { |bytes, payload_len| "control #{payload_len} #{bytes.unpack1('H*')}" } +
                 given.fetch(:payloads).map { |bytes| "payload 0 1024 100000000 #{bytes.unpack1('H*')}" }
      checked = driver.check(requests)
      oracle = oracle_requests(given, checked)
      { checked: checked, oracle: oracle.zip(run_oracle(directory, runner, oracle.map(&:first))) }
    end

    # For each accepted input, what to ask stock OTP and what it must say.
    def oracle_requests(given, checked)
      inputs = given.fetch(:controls).map(&:first) + given.fetch(:payloads)
      inputs.zip(checked).filter_map do |bytes, answer|
        case answer.split(' ', 2)
        in ['ok', text] then ["control #{bytes.unpack1('H*')} #{text.unpack1('H*')}", 'same']
        in ['accepted', words] then ["words #{bytes.unpack1('H*')}", "words #{words}"]
        else nil
        end
      end
    end

    def run_oracle(directory, runner, requests)
      erl = ENV.fetch('ERX_ERL', File.join(ROOT, 'build/oracle/jit/install/bin/erl'))
      erlc = ENV.fetch('ERX_ERLC', File.join(ROOT, 'build/oracle/jit/install/bin/erlc'))
      request_file = File.join(directory, 'oracle-requests')
      answer_file = File.join(directory, 'oracle-answers')
      File.write(request_file, requests.map { |line| "#{line}\n" }.join)
      runner.run(command(erlc, directory, ['-Werror', '-o', directory, File.join(ROOT, 'test/fixtures/funnel_oracle.erl')]),
                 name: 'compile-funnel-oracle', deadline: 60, chdir: directory)
      runner.run(command(erl, directory, ['-noshell', '-noinput', '-boot', 'no_dot_erlang', '-sname', 'funnel_oracle',
                                          '-epmd_module', 'funnel_oracle', '-dist_listen', 'false', '-pa', directory,
                                          '-run', 'funnel_oracle', 'main', request_file, answer_file]),
                 name: 'funnel-oracle', deadline: 300, chdir: directory)
      File.read(answer_file).lines(chomp: true).tap do |lines|
        raise Erx::Error, "#{lines.size} answers to #{requests.size} requests" unless lines.size == requests.size
      end
    end

    def command(program, directory, arguments)
      ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin:/usr/sbin:/sbin', "HOME=#{directory}", 'LANG=C', program, *arguments]
    end
  end

  def answers = self.class.answers

  def test_every_accepted_control_term_decodes_to_what_the_control_record_names
    answers.fetch(:checked).first(CONTROLS).each_with_index do |answer, index|
      assert_match(/\Aok /, answer, "generated control term #{index}")
    end
    controls = answers.fetch(:oracle).select { |(request, _), _| request.start_with?('control ') }
    controls.each { |(request, expected), got| assert_equal expected, got, request }
  end

  def test_every_accepted_payload_is_charged_the_words_erts_size_pass_charges
    words = answers.fetch(:oracle).select { |(request, _), _| request.start_with?('words ') }
    assert_operator words.size, :>=, PAYLOADS * 9 / 10, 'most generated payloads are accepted'
    words.each { |(request, expected), got| assert_equal expected, got, request[0, 200] }
  end
end
