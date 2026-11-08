# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/litmus'

# The weak-memory gate's runner (tools/lib/erx/litmus.rb) over a stand-in
# herd7 that answers from each test's name, since herd7 itself is a
# development tool outside the tree: the roster's files exist and name
# themselves, the right answers pass, a wrong one fails naming the test,
# and a missing or other herd7 fails with the install diagnostic.
class LitmusTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('erx-litmus-')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_every_case_has_a_test_that_names_itself
    Erx::Litmus::CASES.each do |test|
      text = File.read(File.join(ROOT, 'test/litmus', "#{test.name}.litmus"))
      assert_includes Erx::Litmus::MODELS.keys, Erx::Litmus.architecture(text, name: test.name)
      assert_match(/^exists \(/, text)
    end
    assert_equal Erx::Litmus::CASES.map(&:name).sort,
                 Dir.glob('*.litmus', base: File.join(ROOT, 'test/litmus')).map { |f| f.delete_suffix('.litmus') }.sort
  end

  # Every protocol is paired with its broken form, which must fail.
  def test_each_protocol_has_its_broken_twin
    expects = Erx::Litmus::CASES.to_h { |test| [test.name, test.expect] }
    expects.each do |name, expect|
      next unless expect == 'Never'

      broken = name.sub('-fenced', '-unfenced').sub('-acquire', '-relaxed')
      assert_equal 'Sometimes', expects.fetch(broken), "#{name} has no broken twin"
    end
  end

  def test_answers_are_parsed_exactly
    assert_equal 'Never', Erx::Litmus.answer("Test x Allowed\nObservation x Never 0 4\n", name: 'x')
    assert_raises(Erx::Error) { Erx::Litmus.answer("Observation y Never 0 4\n", name: 'x') }
    assert_raises(Erx::Error) { Erx::Litmus.answer("no observation\n", name: 'x') }
    assert_raises(Erx::Error) { Erx::Litmus.answer("Observation x Never 0 4\nObservation x Never 0 4\n", name: 'x') }
    assert_raises(Erx::Error) { Erx::Litmus.architecture("PPC x\n", name: 'x') }
    assert_raises(Erx::Error) { Erx::Litmus.architecture("AArch64 y\n", name: 'x') }
    assert_equal '7.58', Erx::Litmus.version("7.58+01, Rev: abc\n")
    assert_nil Erx::Litmus.version("unknown\n")
  end

  def test_right_answers_pass
    assert_equal Erx::Litmus::CASES.size, litmus(fake(wrong: nil)).run
  end

  def test_a_wrong_answer_names_the_test
    error = assert_raises(Erx::Error) { litmus(fake(wrong: 'lane-need-unfenced')).run }
    assert_match(/litmus lane-need-unfenced: herd7 answered Never, expected Sometimes/, error.message)
  end

  def test_a_missing_or_other_herd7_names_the_install
    error = assert_raises(Erx::Error) { litmus(File.join(@directory, 'absent')).run }
    assert_match(/opam install herdtools7\.#{Regexp.escape(Erx::Litmus::HERD_VERSION)}/, error.message)
    error = assert_raises(Erx::Error) { litmus(fake(wrong: nil, version: '7.50')).run }
    assert_match(/herd7 is version "7\.50"/, error.message)
  end

  private

  def litmus(program)
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    Erx::Litmus.new(root: ROOT, program: program, runner: runner)
  end

  # A herd7 that answers Sometimes for the broken twins and Never otherwise,
  # but for the one test named wrong, which it gets backwards.
  def fake(wrong:, version: Erx::Litmus::HERD_VERSION)
    path = File.join(@directory, "herd7-#{wrong || 'right'}-#{version}")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV == ['-version']
        puts '#{version}+00, Rev: test'
        exit 0
      end
      name = File.basename(ARGV.last, '.litmus')
      broken = name.include?('unfenced') || name.include?('relaxed')
      broken = !broken if name == #{wrong.inspect}
      puts "Observation \#{name} \#{broken ? 'Sometimes' : 'Never'} 1 3"
    RUBY
    File.chmod(0o755, path)
    path
  end
end
