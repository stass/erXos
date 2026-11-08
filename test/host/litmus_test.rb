# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require 'json'
require_relative '../../tools/lib/erx/litmus'

# The weak-memory gate's runner (tools/lib/erx/litmus.rb) over a stand-in
# herd7 that answers from each test's name, so the runner's logic is tested
# without building herdtools7: the roster's files exist and name themselves,
# the right answers pass, a wrong one fails naming the test, a missing or
# other herd7 fails with a diagnostic, and herd7 runs in its own library.
# Erx::Herd's refusal of a missing or stale build is tested here too;
# `make check-litmus` runs the real herd7.
class LitmusTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  PINNED = Erx::Herd.source_record(root: ROOT).fetch('version')

  def setup
    @directory = Dir.mktmpdir('erx-litmus-')
    @library = File.join(@directory, 'library')
    Dir.mkdir(@library)
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
    assert_equal '7.58', Erx::Litmus.version("7.58, Rev: exported\n")
    assert_equal '7.56.3', Erx::Litmus.version("7.56.3, Rev: abc\n")
    assert_nil Erx::Litmus.version("7.58+01, Rev: abc\n")
    assert_nil Erx::Litmus.version("unknown\n")
  end

  def test_right_answers_pass
    assert_equal Erx::Litmus::CASES.size, litmus(fake(wrong: nil)).run
  end

  def test_a_wrong_answer_names_the_test
    error = assert_raises(Erx::Error) { litmus(fake(wrong: 'lane-need-unfenced')).run }
    assert_match(/litmus lane-need-unfenced: herd7 answered Never, expected Sometimes/, error.message)
  end

  def test_a_missing_or_other_herd7_fails
    assert_raises(Erx::Error) { litmus(File.join(@directory, 'absent')).run }
    error = assert_raises(Erx::Error) { litmus(fake(wrong: nil, version: '7.50')).run }
    assert_match(/herd7 is version "7\.50", not deps.lock's #{Regexp.escape(PINNED)}; run tools\/erx build herd7/,
                 error.message)
  end

  # herd7 looks for a model in its working directory and $HERDLIB before its
  # own library, so both must be the built library.
  def test_herd7_runs_in_its_library
    litmus(fake(wrong: nil)).run
    assert_equal [[File.realpath(@library), @library]] * (Erx::Litmus::CASES.size + 1),
                 File.readlines(File.join(@directory, 'where')).map { |line| line.chomp.split(' ', 2) }
  end

  def test_a_build_that_is_missing_or_from_another_pin_is_refused
    root = File.join(@directory, 'root')
    FileUtils.mkdir_p(root)
    FileUtils.cp(File.join(ROOT, 'deps.lock'), root)
    assert_raises(Erx::Herd::MissingBuild) { Erx::Herd.locate(root: root) }

    output = File.join(root, Erx::Herd::OUTPUT)
    FileUtils.mkdir_p([File.join(output, 'bin'), File.join(output, Erx::Herd::LIBRARY)])
    File.write(File.join(output, Erx::Herd::PROGRAM), '')
    source = Erx::Herd.source_record(root: root)
    [{ 'source' => source.merge('version' => '7.57'), 'recipe' => Erx::Herd::Build::RECIPE },
     { 'source' => source, 'recipe' => '0' * 64 }].each do |stamp|
      File.write(File.join(output, Erx::Herd::STAMP), JSON.generate(stamp))
      assert_raises(Erx::Herd::StaleBuild) { Erx::Herd.locate(root: root) }
    end
    File.write(File.join(output, Erx::Herd::STAMP), '{')
    assert_raises(Erx::Herd::StaleBuild) { Erx::Herd.locate(root: root) }

    File.write(File.join(output, Erx::Herd::STAMP), JSON.generate('source' => source, 'recipe' => Erx::Herd::Build::RECIPE))
    assert_equal Erx::Herd::Tool.new(program: File.join(output, Erx::Herd::PROGRAM), libdir: File.join(output, Erx::Herd::LIBRARY)),
                 Erx::Herd.locate(root: root)
  end

  def test_a_build_path_is_written_as_an_ocaml_string
    assert_equal '"/a/b\\\\c\\"d/"', Erx::Herd.ocaml_string('/a/b\\c"d/')
    assert_raises(Erx::Error) { Erx::Herd.ocaml_string("/a\nb") }
  end

  private

  def litmus(program)
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    Erx::Litmus.new(root: ROOT, herd: Erx::Herd::Tool.new(program: program, libdir: @library), runner: runner)
  end

  # A herd7 that answers Sometimes for the broken twins and Never otherwise,
  # but for the one test named wrong, which it gets backwards. Each run
  # appends its working directory and $HERDLIB to the file `where`.
  def fake(wrong:, version: PINNED)
    path = File.join(@directory, "herd7-#{wrong || 'right'}-#{version}")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      File.write(#{File.join(@directory, 'where').inspect}, "\#{Dir.pwd} \#{ENV['HERDLIB']}\\n", mode: 'a')
      if ARGV == ['-version']
        puts '#{version}, Rev: test'
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
