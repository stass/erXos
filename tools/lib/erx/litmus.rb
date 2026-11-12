# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'bounded_file'
require_relative 'herd'
require_relative 'runner'

module Erx
  # The weak-memory gate, `make check-litmus` (docs/design-domains.md,
  # "Verification and testing", weak memory): every litmus test of
  # test/litmus/ runs under herd7 with its memory model and must give its
  # expected answer. A protocol with its fences, acquire loads or release
  # stores must never reach the outcome its `exists` clause names; the same
  # protocol without them must reach it, or the test would pass whatever the fences did.
  # herd7 is built for the host from deps.lock's herdtools7 pin (Erx::Herd),
  # whose build record ties it to that pin; asking it for its version first
  # checks that the built program still runs (a host library it links may
  # have changed) and still reports the pin, and fails with a diagnostic,
  # never a skip.
  class Litmus
    # Each architecture's model, as herd7 names it in its library.
    MODELS = { 'AArch64' => 'aarch64.cat', 'C' => 'rc11.cat' }.freeze
    Case = Data.define(:name, :expect)
    # Never: the protocol holds. Sometimes: the broken protocol fails.
    CASES = [
      Case.new('lane-wake-fenced', 'Never'), Case.new('lane-wake-unfenced', 'Sometimes'),
      Case.new('lane-need-fenced', 'Never'), Case.new('lane-need-unfenced', 'Sometimes'),
      Case.new('lane-wpos-acquire', 'Never'), Case.new('lane-wpos-relaxed', 'Sometimes'),
      Case.new('lane-rpos-acquire', 'Never'), Case.new('lane-rpos-relaxed', 'Sometimes'),
      Case.new('lane-wpos-acquire-c11', 'Never'), Case.new('lane-wpos-relaxed-c11', 'Sometimes'),
      Case.new('pipe-lock-waiters-fenced', 'Never'), Case.new('pipe-lock-waiters-unfenced', 'Sometimes'),
      Case.new('pipe-lock-cur-release', 'Never'), Case.new('pipe-lock-cur-relaxed', 'Sometimes'),
      Case.new('pipe-wends-acquire', 'Never'), Case.new('pipe-wends-relaxed', 'Sometimes')
    ].freeze
    OBSERVATION = /^Observation (?<name>\S+) (?<answer>Always|Sometimes|Never)\b/
    MAX_TEST_BYTES = 64 * 1024
    MAX_OUTPUT_BYTES = 1024 * 1024

    # herd is the Herd::Tool to run, which Herd.locate finds by default.
    def initialize(root:, herd: nil, runner: nil)
      @root = root
      @herd = herd || Herd.locate(root: root)
      @runner = runner || Runner.new(owner_root: root, log_dir: File.join(root, 'build/litmus/logs'))
    end

    # Runs every case and raises on the first wrong answer, naming it.
    def run
      check_version
      CASES.each do |test|
        answer = self.class.answer(observe(test), name: test.name)
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

    # The release `herd7 -version` printed, the field before ", Rev:"
    # ("7.58, Rev: exported"), or nil.
    def self.version(output) = output[/\A(\d+(?:\.\d+)+), Rev: /, 1]

    # The architecture a litmus test's first line names, from those MODELS knows.
    def self.architecture(text, name:)
      arch, title = text.lines.first.to_s.split
      raise Error, "litmus #{name}: unknown architecture #{arch.inspect}" unless MODELS.key?(arch)
      raise Error, "litmus #{name}: its first line names #{title.inspect}" unless title == name

      arch
    end

    private

    def check_version
      pinned = Herd.source_record(root: @root).fetch('version')
      output = begin
        herd_run(['-version'], name: 'herd7-version', deadline: 60)
      rescue Error => e
        raise Error, "herd7 does not run (#{e.message}); run tools/erx build herd7"
      end
      version = self.class.version(output)
      return if version == pinned

      raise Error, "herd7 is version #{version.inspect}, not deps.lock's #{pinned}; run tools/erx build herd7"
    end

    # What herd7 printed for test under its architecture's model.
    def observe(test)
      path = File.join(@root, 'test/litmus', "#{test.name}.litmus")
      text = File.file?(path) ? File.read(path, MAX_TEST_BYTES + 1).to_s : ''
      raise Error, "litmus #{test.name}: missing, empty or past #{MAX_TEST_BYTES} bytes" unless (1..MAX_TEST_BYTES).cover?(text.size)

      model = MODELS.fetch(self.class.architecture(text, name: test.name))
      herd_run(['-model', model, File.expand_path(path)], name: 'herd7', deadline: 600)
    end

    # herd7 searches the working directory, then $HERDLIB, then its built-in
    # library for a model and the files it includes, so it runs in its own
    # library with HERDLIB naming it: no file elsewhere can stand in for a model.
    def herd_run(arguments, name:, deadline:)
      record = @runner.run([@herd.program, *arguments], name: name, deadline: deadline, chdir: @herd.libdir,
                                                        env: { 'HERDLIB' => @herd.libdir })
      BoundedFile.read(record.fetch('log'), maximum: MAX_OUTPUT_BYTES)
    end
  end
end
