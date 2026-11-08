# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'runner'

module Erx
  # The weak-memory gate, `make check-litmus` (docs/design-domains.md,
  # "Verification and testing", weak memory): every litmus test of
  # test/litmus/ runs under herd7 with its memory model and must give its
  # expected answer. A protocol with its fences or acquire loads must never
  # reach the outcome its `exists` clause names; the same protocol without
  # them must reach it, or the test would pass whatever the fences did.
  # herd7 is a development tool outside the tree (herdtools7, installed with
  # opam at the pinned version); a missing or other version fails with a
  # diagnostic, never a skip.
  class Litmus
    HERD_VERSION = '7.58'
    INSTALL = "install herdtools7 #{HERD_VERSION} with opam (`opam install herdtools7.#{HERD_VERSION}`) " \
              'and put herd7 on PATH, or set HERD7'
    # Each architecture's model, as herd7 names it in its library.
    MODELS = { 'AArch64' => 'aarch64.cat', 'C' => 'rc11.cat' }.freeze
    Case = Data.define(:name, :expect)
    # Never: the protocol holds. Sometimes: the broken protocol fails.
    CASES = [
      Case.new('lane-wake-fenced', 'Never'), Case.new('lane-wake-unfenced', 'Sometimes'),
      Case.new('lane-need-fenced', 'Never'), Case.new('lane-need-unfenced', 'Sometimes'),
      Case.new('lane-wpos-acquire', 'Never'), Case.new('lane-wpos-relaxed', 'Sometimes'),
      Case.new('lane-rpos-acquire', 'Never'), Case.new('lane-rpos-relaxed', 'Sometimes'),
      Case.new('lane-wpos-acquire-c11', 'Never'), Case.new('lane-wpos-relaxed-c11', 'Sometimes')
    ].freeze
    OBSERVATION = /^Observation (?<name>\S+) (?<answer>Always|Sometimes|Never)\b/
    MAX_TEST_BYTES = 64 * 1024

    def initialize(root:, program: ENV.fetch('HERD7', 'herd7'), runner: nil)
      @root = root
      @program = program
      @runner = runner || Runner.new(owner_root: root, log_dir: File.join(root, 'build/litmus/logs'))
    end

    # Runs every case and raises on the first wrong answer, naming it.
    def run
      check_tool
      CASES.each do |test|
        answer = self.class.answer(herd(test), name: test.name)
        next if answer == test.expect

        raise Error, "litmus #{test.name}: herd7 answered #{answer}, expected #{test.expect}"
      end
      CASES.size
    end

    # The answer herd7 printed for the test called name.
    def self.answer(output, name:)
      found = output.each_line.filter_map { |line| OBSERVATION.match(line) }
      raise Error, "litmus #{name}: herd7 printed no single observation" unless found.size == 1
      raise Error, "litmus #{name}: herd7 observed #{found.first[:name]}" unless found.first[:name] == name

      found.first[:answer]
    end

    # The release `herd7 -version` printed: its first MAJOR.MINOR, or nil.
    def self.version(output) = output[/\b\d+\.\d+\b/]

    # The architecture a litmus test's first line names, from those MODELS knows.
    def self.architecture(text, name:)
      arch, title = text.lines.first.to_s.split
      raise Error, "litmus #{name}: unknown architecture #{arch.inspect}" unless MODELS.key?(arch)
      raise Error, "litmus #{name}: its first line names #{title.inspect}" unless title == name

      arch
    end

    private

    def check_tool
      version = self.class.version(tool_output)
      raise Error, "herd7 is version #{version.inspect}, not #{HERD_VERSION}: #{INSTALL}" unless version == HERD_VERSION
    end

    def tool_output
      File.read(@runner.run([@program, '-version'], name: 'herd7-version', deadline: 60).fetch('log'))
    rescue Error => error
      raise Error, "herd7 cannot run (#{error.message}): #{INSTALL}"
    end

    def herd(test)
      path = File.join(@root, 'test/litmus', "#{test.name}.litmus")
      text = File.file?(path) ? File.read(path, MAX_TEST_BYTES + 1).to_s : ''
      raise Error, "litmus #{test.name}: missing, empty or past #{MAX_TEST_BYTES} bytes" unless (1..MAX_TEST_BYTES).cover?(text.size)

      model = MODELS.fetch(self.class.architecture(text, name: test.name))
      record = @runner.run([@program, '-model', model, path], name: 'herd7', deadline: 600)
      File.read(record.fetch('log'))
    end
  end
end
