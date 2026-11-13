# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/generated'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/web_stage'

# The web protocol's two codecs (docs/design-web.md, "Verification and
# testing"), generated into build/gen from abi/protocols/web.txt:
# erx_web_proto on stock's emulator (ERX_ERL and ERX_ERLC) and proto.ts
# under Node. Both read and write files of "MESSAGE HEX" lines and answer
# each with "ok HEX", the bytes their encoder writes back for what their
# decoder read, or "refused REASON TYPE", so their answers to one file must
# agree line for line: random messages of every kind from either side come
# back as the same bytes, mutated ones meet the same answer, and the probes
# below, each limit at its bound and one past it, are accepted or refused by
# both as they expect.
class ErxWebProtoTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  TESTS = %w[test/erlang/erx_web_proto_tests.erl].freeze
  WEB = Erx::ABI::Generator.plan(root: ROOT).schema.web
  # The sources the protocol hash covers, listed here independently of the
  # generator, so a generator that drops one fails.
  HASHED = %w[abi/protocols/web.txt abi/formats/ui.txt abi/inspection.txt abi/terminal.txt
              otp/lib/stdlib/uc_spec/UnicodeData.txt otp/lib/stdlib/uc_spec/DerivedCoreProperties.txt
              otp/lib/stdlib/uc_spec/EastAsianWidth.txt].freeze

  def test_random_erlang_messages_come_back_from_typescript_as_the_same_bytes
    in_erlang do |work|
      corpus = File.join(work, 'corpus')
      erlang!(work, "erx_web_proto_tests:corpus(\"#{corpus}\", 11, 3000)")
      lines = File.readlines(corpus, chomp: true)
      assert_equal %w[browser machine], lines.map { |line| line.split(' ').first }.uniq.sort
      assert_equal lines.map { |line| "ok #{line.split(' ').last}" }, typescript_answers(corpus)
    end
  end

  def test_random_typescript_messages_come_back_from_erlang_as_the_same_bytes
    in_erlang do |work|
      corpus = File.join(work, 'corpus')
      typescript_harness { |harness| run!(*harness, 'corpus', corpus, '13', '3000', chdir: work) }
      lines = File.readlines(corpus, chomp: true)
      assert_equal lines.map { |line| "ok #{line.split(' ').last}" }, erlang_answers(work, corpus)
    end
  end

  def test_mutated_messages_meet_the_same_answer_from_both
    in_erlang do |work|
      corpus = File.join(work, 'corpus')
      erlang!(work, "erx_web_proto_tests:corpus(\"#{corpus}\", 17, 2000)")
      random = Random.new(17)
      mutated = File.readlines(corpus, chomp: true).map do |line|
        message, hex = line.split(' ')
        "#{message} #{mutate([hex].pack('H*'), random).unpack1('H*').upcase}"
      end
      File.write(corpus, mutated.map { |line| "#{line}\n" }.join)
      erlang = erlang_answers(work, corpus)
      assert_operator erlang.count { |line| line.start_with?('ok') }, :>, 100
      assert_operator erlang.count { |line| line.start_with?('refused') }, :>, 500
      assert_equal erlang, typescript_answers(corpus)
    end
  end

  def test_each_limit_binds_both_codecs_at_its_bound
    in_erlang do |work|
      probes = File.join(work, 'probes')
      File.write(probes, PROBES.map { |message, bytes, _| "#{message} #{bytes.unpack1('H*').upcase}\n" }.join)
      erlang = erlang_answers(work, probes)
      PROBES.zip(erlang).each do |(_, bytes, expected), answer|
        if expected == :ok
          assert_equal "ok #{bytes.unpack1('H*').upcase}", answer
        else
          assert_equal "refused #{expected}", answer
        end
      end
      assert_equal erlang, typescript_answers(probes)
    end
  end

  def test_both_codecs_carry_the_hash_of_every_client_source
    expected = Digest::SHA256.hexdigest(HASHED.map do |path|
      "#{path} #{Digest::SHA256.hexdigest(File.binread(File.join(ROOT, path)))}\n"
    end.join)
    in_erlang do |work|
      assert_equal expected, erlang!(work, 'io:format("~s", [binary:encode_hex(erx_web_proto:hash(), lowercase)])')
    end
    typescript_harness { |harness| assert_equal "#{expected}\n", run!(*harness, 'hash', chdir: ROOT) }
  end

  # The probes: a message's bytes, built by hand, and what both codecs must
  # answer: :ok, or the reason and type of the refusal.
  def self.u8(value) = [value].pack('C')
  def self.u32(value) = [value].pack('V')
  def self.sized(bytes) = u32(bytes.bytesize) + bytes
  def self.list(items) = u32(items.size) + items.join
  def self.open_path(segments) = u8(2) + u32(1) + u8(1) + list(segments.map { |segment| sized(segment) })
  def self.trace(count) = u8(2) + u32(1) + u8(2) + list([sized('pid') + sized('<0.1.0>')] * count) + u8(1) + u8(0)
  def self.update(body) = u8(2) + u32(1) + body
  def self.entries(entries) = update(u8(2) + list(entries))
  def self.entry(datum, time: '1') = u8(1) + sized(time) + datum
  def self.int(digits) = u8(1) + sized(digits)
  def self.datum_list(items) = u8(5) + list(items)
  def self.nested(containers) = (1..containers).reduce(int('1')) { |inner, _| datum_list([inner]) }
  def self.record(reporter: u8(1), status: u8(1))
    attr = sized('used') + reporter + status + int('2')
    update(u8(1) + list([]) + sized('k') + int('1') + list([attr]) + u8(1) + list([]))
  end
  def self.ui_ops(*lengths) = update(u8(3) + list(lengths.map { |length| u32(length) + ('x' * length) }))

  STOPGAP = WEB.stopgaps.first
  PROBES = [
    ['browser', open_path(['a'] * 16), :ok],
    ['browser', open_path(['a'] * 17), 'too_many segments'],
    ['browser', open_path(['a' * 256]), :ok],
    ['browser', open_path(['a' * 257]), 'too_long segment'],
    ['browser', trace(16), :ok],
    ['browser', trace(17), 'too_many selection'],
    ['browser', u8(5) + u32(1) + u32(65_024) + ('e' * 65_024), :ok],
    ['browser', u8(5) + u32(1) + u32(65_025) + ('e' * 65_025), 'bad_value ui_op'],
    ['browser', u8(1) + sized('h' * 32), :ok],
    ['browser', u8(1) + sized('h' * 31), 'bad_value hash'],
    ['browser', u8(1) + sized('h' * 32) + u8(0), 'trailing browser'],
    ['browser', u8(6) + u32(1), 'bad_tag browser'],
    ['browser', u8(2) + u32(1) + u8(2) + list([]) + u8(2) + u8(0), 'bad_value boolean'],
    ['machine', u8(1) + sized('n' * 255) + sized('b' * 64), :ok],
    ['machine', u8(1) + sized('n' * 256) + sized('b'), 'too_long name'],
    ['machine', u8(1) + sized('n') + sized('b' * 65), 'too_long build_id'],
    ['machine', u8(3) + u32(1) + sized('r' * 255), :ok],
    ['machine', u8(3) + u32(1) + sized('r' * 256), 'too_long name'],
    ['machine', u8(4) + u8(6), :ok],
    ['machine', u8(4) + u8(7), 'bad_tag bye_reason'],
    ['machine', entries([u8(2) + u32(1)] * 1000), :ok],
    ['machine', entries([u8(2) + u32(1)] * 1001), 'too_many entries'],
    ['machine', update(u8(4) + list([u32(1) + sized('u')] * 256)), :ok],
    ['machine', update(u8(4) + list([u32(1) + sized('u')] * 257)), 'too_many uis'],
    ['machine', entries([entry(int('1'), time: "-#{'9' * 39}")]), :ok],
    ['machine', entries([entry(int('1'), time: '9' * 41)]), 'too_long int'],
    ['machine', entries([entry(int('007'))]), 'bad_value int'],
    ['machine', entries([entry(int('-0'))]), 'bad_value int'],
    ['machine', entries([entry(u8(7) + sized('p' * 4096))]), :ok],
    ['machine', entries([entry(u8(7) + sized('p' * 4097))]), 'too_long printed'],
    ['machine', entries([entry(datum_list([int('1')] * 1000))]), :ok],
    ['machine', entries([entry(datum_list([int('1')] * 1001))]), 'too_many datum_list'],
    ['machine', entries([entry(u8(6) + list([int('1')] * 16))]), :ok],
    ['machine', entries([entry(u8(6) + list([int('1')] * 17))]), 'too_many datum_tuple'],
    # Lists at levels 1 to 7 of datum's eight; one at the eighth is an unknown tag there.
    ['machine', entries([entry(nested(7))]), :ok],
    ['machine', entries([entry(nested(8))]), 'bad_tag datum'],
    ['machine', record, :ok],
    ['machine', record(reporter: u8(4) + sized(STOPGAP)), :ok],
    ['machine', record(reporter: u8(4) + sized('not_a_stopgap')), 'bad_value stopgap_name'],
    ['machine', record(status: u8(5) + u32(1)), :ok],
    ['machine', record(status: u8(5) + u32(0)), 'bad_value timeout_ms'],
    # One message of exactly web_message_max bytes, and one byte more.
    ['machine', ui_ops(65_000, 518), :ok],
    ['machine', ui_ops(65_000, 519), 'too_long machine']
  ].freeze

  private

  # Flips, insertions, deletions and length words set near a bound.
  def mutate(bytes, random)
    bytes = bytes.b
    (1 + random.rand(4)).times do
      at = random.rand(bytes.bytesize + 1)
      case random.rand(4)
      when 0 then bytes[at, 1] = random.rand(256).chr
      when 1 then bytes.insert(at, random.rand(256).chr)
      when 2 then bytes[at, 1 + random.rand(8)] = ''
      else bytes[at, 4] = [random.rand(1100)].pack('V')
      end
    end
    bytes
  end

  def erlang_answers(work, file)
    answers = File.join(work, 'answers')
    erlang!(work, "erx_web_proto_tests:reencode(\"#{file}\", \"#{answers}\")")
    File.readlines(answers, chomp: true)
  end

  def typescript_answers(file)
    typescript_harness do |harness|
      answers = "#{file}.ts"
      run!(*harness, 'reencode', file, answers, chdir: File.dirname(file))
      File.readlines(answers, chomp: true)
    end
  end

  def typescript_harness
    Erx::WebStage.with(root: ROOT) { |stage| yield [*Erx::WebStage::NODE, File.join(stage, 'test/proto_harness.ts')] }
  end

  def in_erlang
    Dir.mktmpdir('erx-web-proto-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS)
      yield work
    end
  end

  def erlang!(work, expression)
    run!(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval', "#{expression}, halt(0)", chdir: work)
  end

  def run!(*command, chdir:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '300', *command, chdir: chdir, stdin_data: '')
    assert status.success?, output
    output
  end
end
