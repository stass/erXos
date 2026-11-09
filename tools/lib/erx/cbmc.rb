# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'etc'
require 'fileutils'
require 'json'
require 'time'
require 'tmpdir'
require_relative 'error'
require_relative 'generated'
require_relative 'json_input'
require_relative 'output_directory'
require_relative 'runner'

module Erx
  # The CBMC harness roster, test/cbmc/roster.json: the pinned tool version,
  # the checks every harness runs with, each harness with its bounds,
  # assumptions and unsupported constructs, and the seeded defects the
  # harnesses must catch. Parsing validates the whole roster before any run.
  module CbmcRoster
    TOP_FIELDS = %w[version cbmc_version solver checks harnesses mutants].freeze
    # The SAT solvers the pinned cbmc builds in.
    SOLVERS = %w[cadical minisat2].freeze
    HARNESS_FIELDS = %w[id source core deadline unwind bounds assumptions unsupported].freeze
    HARNESS_OPTIONAL = %w[unwindset object_bits defines].freeze
    MUTANT_FIELDS = %w[id harness defect file original replacement fails].freeze
    ID = /\A[a-z][a-z0-9_-]{0,63}\z/
    # The checks a roster may enable. Nothing else reaches the command line
    # from the roster, so no entry can weaken CBMC's defaults.
    CHECKS = %w[--bounds-check --pointer-check --pointer-overflow-check --pointer-primitive-check
                --signed-overflow-check --unsigned-overflow-check --conversion-check
                --undefined-shift-check --div-by-zero-check --enum-range-check].freeze
    # A seeded defect's pattern matches one failing property; its match is
    # bounded in time, since a pattern is input.
    PATTERN_TIMEOUT = 1.0
    LOOP = /\A[A-Za-z_][A-Za-z0-9_]*\.[0-9]+\z/
    MACRO = /\A[A-Z][A-Z0-9_]*\z/
    VERSION = /\A[0-9]+\.[0-9]+\.[0-9]+\z/
    MAX_DEADLINE = 3600
    MAX_ROSTER_BYTES = 1024 * 1024

    module_function

    def read(root) = parse(File.binread(File.join(root, 'test/cbmc/roster.json')), root: root)

    def parse(bytes, root:)
      roster = JsonInput.parse(bytes, max_bytes: MAX_ROSTER_BYTES, label: 'CBMC roster')
      raise Error, 'CBMC roster is not an object' unless roster.is_a?(Hash)
      exact_fields(roster, TOP_FIELDS, [], 'CBMC roster')
      raise Error, 'CBMC roster version must be 1' unless roster.fetch('version') == 1
      raise Error, 'CBMC roster pins no valid cbmc version' unless VERSION.match?(roster.fetch('cbmc_version').to_s)
      raise Error, 'CBMC roster names an unknown solver' unless SOLVERS.include?(roster.fetch('solver'))
      checks = roster.fetch('checks')
      unless checks.is_a?(Array) && !checks.empty? && checks.uniq.size == checks.size &&
             checks.all? { |check| CHECKS.include?(check) }
        raise Error, "CBMC roster checks must be distinct options of #{CHECKS.join(' ')}"
      end
      harnesses = list(roster, 'harnesses').map { |entry| harness(entry, root: root) }
      unique(harnesses, 'harness')
      by_id = harnesses.to_h { |entry| [entry.fetch('id'), entry] }
      mutants = list(roster, 'mutants').map { |entry| mutant(entry, root: root, harnesses: by_id) }
      unique(mutants, 'mutant')
      deep_freeze(roster)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |item| deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def harness(entry, root:)
      exact_fields(entry, HARNESS_FIELDS, HARNESS_OPTIONAL, 'CBMC harness')
      id = identifier(entry, 'harness')
      source = source_file(root, File.join('test/cbmc', entry.fetch('source')), "harness #{id} source")
      core = source_file(root, entry.fetch('core'), "harness #{id} core")
      # The harness checks the core the roster names, and only that one.
      unless File.dirname(entry.fetch('core')) == 'kernel/core' &&
             File.binread(source).scan(/^\s*#\s*include\s+"[^"]*\.c"/) == ["#include \"#{File.basename(core)}\""]
        raise Error, "harness #{id} must include its core, kernel/core/#{File.basename(core)}, and no other"
      end
      bounded(entry.fetch('deadline'), 1, MAX_DEADLINE, "harness #{id} deadline")
      bounded(entry.fetch('unwind'), 1, 1 << 16, "harness #{id} unwind")
      bounded(entry['object_bits'], 1, 32, "harness #{id} object_bits") if entry.key?('object_bits')
      text(entry.fetch('bounds'), "harness #{id} bounds")
      %w[assumptions unsupported].each do |field|
        values = entry.fetch(field)
        raise Error, "harness #{id} #{field} must be a list" unless values.is_a?(Array)
        values.each { |value| text(value, "harness #{id} #{field}") }
      end
      table(entry.fetch('unwindset', {}), LOOP, "harness #{id} unwindset") do |value|
        bounded(value, 1, 1 << 16, "harness #{id} unwindset")
      end
      table(entry.fetch('defines', {}), MACRO, "harness #{id} defines") do |value|
        raise Error, "harness #{id} defines must be integers" unless value.is_a?(Integer) && value.between?(0, 1 << 62)
      end
      entry
    end

    def mutant(entry, root:, harnesses:)
      exact_fields(entry, MUTANT_FIELDS, [], 'CBMC mutant')
      id = identifier(entry, 'mutant')
      harness = harnesses.fetch(entry.fetch('harness')) { raise Error, "mutant #{id} names an unknown harness" }
      # The harness includes its core, so only an edit of that core reaches it.
      raise Error, "mutant #{id} must edit its harness's core" unless entry.fetch('file') == harness.fetch('core')
      text(entry.fetch('defect'), "mutant #{id} defect")
      path = source_file(root, entry.fetch('file'), "mutant #{id} file")
      %w[original fails].each { |field| text(entry.fetch(field), "mutant #{id} #{field}") }
      # An empty replacement deletes the original: a removed check.
      raise Error, "mutant #{id} replacement must be text" unless entry.fetch('replacement').is_a?(String)
      count = File.binread(path).scan(entry.fetch('original')).size
      unless count == 1
        raise Error, "mutant #{id} must edit exactly one place of #{entry.fetch('file')}, found #{count}"
      end
      pattern(entry)
      entry
    rescue RegexpError
      raise Error, "mutant #{id} fails is not a regular expression"
    end

    # A seeded defect's failure pattern, compiled with a match deadline.
    def pattern(mutant) = Regexp.new(mutant.fetch('fails'), timeout: PATTERN_TIMEOUT)

    def exact_fields(entry, required, optional, what)
      raise Error, "#{what} is not an object" unless entry.is_a?(Hash)
      missing = required - entry.keys
      unknown = entry.keys - required - optional
      raise Error, "#{what} lacks #{missing.join(', ')}" unless missing.empty?
      raise Error, "#{what} has unknown fields #{unknown.join(', ')}" unless unknown.empty?
    end

    def list(roster, field)
      values = roster.fetch(field)
      raise Error, "CBMC roster #{field} must be a non-empty list" unless values.is_a?(Array) && !values.empty?
      values
    end

    def identifier(entry, what)
      id = entry.fetch('id')
      raise Error, "invalid CBMC #{what} id" unless ID.match?(id.to_s)
      id
    end

    def unique(entries, what)
      repeated = entries.map { |entry| entry.fetch('id') }.tally.select { |_, count| count > 1 }.keys
      raise Error, "CBMC #{what} ids repeat: #{repeated.join(', ')}" unless repeated.empty?
    end

    # A relative path to a regular file inside the tree, with no .. step.
    def source_file(root, relative, what)
      unless relative.is_a?(String) && !relative.start_with?('/') && !relative.split('/').include?('..')
        raise Error, "#{what} must be a path inside the tree"
      end
      path = File.join(root, relative)
      raise Error, "#{what} #{relative} is not a regular file" unless File.file?(path) && !File.symlink?(path)
      # No symlinked directory on the way leads out of the tree.
      unless File.realpath(path).start_with?("#{File.realpath(root)}/")
        raise Error, "#{what} #{relative} resolves outside the tree"
      end
      path
    end

    def bounded(value, low, high, what)
      return if value.is_a?(Integer) && value.between?(low, high)

      raise Error, "#{what} must be an integer from #{low} to #{high}"
    end

    def text(value, what)
      raise Error, "#{what} must be non-empty text" unless value.is_a?(String) && !value.strip.empty?
    end

    def table(value, key_pattern, what, &check)
      raise Error, "#{what} must be an object" unless value.is_a?(Hash)
      value.each do |key, item|
        raise Error, "#{what} has an invalid key" unless key_pattern.match?(key)
        check.call(item)
      end
    end
  end

  # Reads what one CBMC run printed: the status of each property, the
  # tool's warnings, and its verdict. Pure. The runner reads CBMC's plain
  # output rather than its JSON, which carries a full counterexample trace
  # for every failed property and grows past any useful bound; the raw log
  # keeps everything CBMC said.
  module CbmcOutput
    Result = Data.define(:verdict, :properties, :failures, :warnings)
    # The runner caps a log at this size, so every log it keeps is read.
    MAX_OUTPUT_BYTES = 64 * 1024 * 1024
    # One property's line of CBMC's results: [id] description: STATUS.
    PROPERTY = /\A\[(?<id>[^\]\s]+)\] (?<description>.*): (?<status>SUCCESS|FAILURE|UNKNOWN|ERROR)\z/
    # The closing count of CBMC's results.
    TALLY = /\A\*\* (?<failed>[0-9]+) of (?<total>[0-9]+) failed/
    # Warnings that mean CBMC checked something other than the code: a
    # function it has no body for returns any value and does nothing, so a
    # run that reports one proves nothing about its caller.
    MISSING_CODE = [/function '[^']*' is not declared\z/, /no body for (?:callee|function) /].freeze

    module_function

    # exit_status: CBMC's own, 0 when every property holds, 10 when one
    # fails. Anything else, output whose property lines disagree with its
    # closing count, or a warning of missing code is a tool error.
    def classify(bytes, exit_status:)
      return unreadable unless bytes.bytesize <= MAX_OUTPUT_BYTES

      lines = bytes.dup.force_encoding(Encoding::BINARY).lines.map { |line| line.chomp.force_encoding(Encoding::UTF_8) }
      return unreadable unless lines.all?(&:valid_encoding?)

      properties = lines.filter_map { |line| PROPERTY.match(line) }
      tally = lines.filter_map { |line| TALLY.match(line) }.last
      failures = properties.select { |property| property[:status] == 'FAILURE' }
                           .map { |property| "#{property[:id]}: #{property[:description]}" }
      return unreadable unless tally && Integer(tally[:total]) == properties.size &&
                               Integer(tally[:failed]) == failures.size

      warnings = lines.select { |line| MISSING_CODE.any? { |pattern| pattern.match?(line) } }.uniq
      Result.new(verdict: verdict(exit_status, properties: properties, failures: failures, warnings: warnings),
                 properties: properties.size, failures: failures, warnings: warnings)
    end

    def unreadable = Result.new(verdict: 'error', properties: 0, failures: [], warnings: ['output is not CBMC results'])

    def verdict(exit_status, properties:, failures:, warnings:)
      return 'error' unless warnings.empty?
      # A property CBMC left undecided is no proof: a run verifies only when
      # every property holds. A failing run may leave some undecided.
      return 'verified' if exit_status.zero? && !properties.empty? &&
                           properties.all? { |property| property[:status] == 'SUCCESS' }
      return 'failed' if exit_status == 10 && !failures.empty?

      'error'
    end
  end

  # The CBMC gate, `make check-cbmc` (docs/design-verification.md, "CBMC
  # harnesses and runner"). It checks the installed cbmc against the
  # roster's pinned version, runs every harness, which must verify, and
  # every seeded defect, each of which its harness must catch with a failure
  # matching the roster's pattern, and writes build/cbmc/report.json and
  # report.txt. Raw CBMC output stays in build/logs.
  class Cbmc
    OUTPUT_LIMIT = CbmcOutput::MAX_OUTPUT_BYTES
    VERSION_DEADLINE = 30
    REPORTS = %w[report.json report.txt].freeze
    # The include path, in search order. The stdatomic shim goes ahead of
    # the host's header; a mutant's directory goes ahead of kernel/core, so
    # the harness's include of its core reads the mutant, and kernel/core
    # ahead of everything else, so no other file of the core's name can
    # stand in for it; the generated tree supplies erx/abi.h and the cores'
    # private slot accessors.
    INCLUDES = ['test/cbmc/include', :mutant, 'kernel/core', 'build/gen', 'build/gen/include', 'include',
                'build/gen/kernel/generated'].freeze

    # One run of a harness: CBMC's verdict on it, its wall time and its log.
    Run = Data.define(:result, :wall_seconds, :log)

    # prepare brings the generated headers the harnesses include up to date.
    def initialize(root:, runner: nil, program: ENV.fetch('CBMC', 'cbmc'), clock: -> { Time.now.utc },
                   prepare: ->(tree) { Generated.ensure(root: tree) }, jobs: nil)
      @jobs = jobs
      @root = File.expand_path(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @program = program
      @clock = clock
      @prepare = prepare
    end

    def run(filter: nil)
      # A run that stops early leaves no earlier report to be read as its own.
      remove_reports
      jobs = @jobs || Cbmc.jobs
      roster = CbmcRoster.read(@root)
      harnesses = roster.fetch('harnesses').select { |entry| filter.nil? || entry.fetch('id').include?(filter) }
      raise Error, 'CBMC filter matched no harness' if harnesses.empty?

      tool = tool_identity(roster.fetch('cbmc_version'))
      @prepare.call(@root)
      settings = roster.slice('solver', 'checks')
      by_id = harnesses.to_h { |entry| [entry.fetch('id'), entry] }
      selected = roster.fetch('mutants').select { |mutant| by_id.key?(mutant.fetch('harness')) }
      checks = harnesses.map { |entry| -> { check_harness(entry, tool: tool, settings: settings) } } +
               selected.map do |mutant|
                 harness = by_id.fetch(mutant.fetch('harness'))
                 -> { check_mutant(mutant, harness: harness, tool: tool, settings: settings) }
               end
      values = Cbmc.concurrently(checks, jobs: jobs)
      results = values.first(harnesses.size)
      mutants = values.drop(harnesses.size)
      report = Cbmc.report(tool: tool, settings: settings, jobs: jobs, filter: filter, harnesses: results, mutants: mutants,
                           date: @clock.call.iso8601)
      write_report(report)
      Cbmc.summary(report).each_line { |line| Terminal.puts(line.chomp) }
      raise Error, 'CBMC gate failed; see build/cbmc/report.txt' unless report.fetch('state') == 'passed'

      report
    end

    MAX_JOBS = 256

    # How many CBMC runs go at once: CBMC_JOBS when set to a positive count,
    # else the host's CPUs. Each run is single-threaded and holds its own
    # SAT state, so the count also bounds the memory the gate may use, and
    # each run's wall time includes the slowdown of the runs beside it.
    def self.jobs(environment: ENV, cpus: Etc.nprocessors)
      requested = environment['CBMC_JOBS']
      return cpus if requested.nil? || requested.empty?

      unless /\A[1-9][0-9]*\z/.match?(requested) && requested.to_i <= MAX_JOBS
        raise Error, "CBMC_JOBS must be between 1 and #{MAX_JOBS}"
      end

      requested.to_i
    end

    # Calls every check, at most jobs at a time, and returns their values in
    # the order of checks, whatever order they finish in. A check that
    # raises stops the others from starting; the runs already going finish
    # (each is bounded by its deadline) and the first error is raised.
    def self.concurrently(checks, jobs:)
      raise Error, 'CBMC jobs must be a positive integer' unless jobs.is_a?(Integer) && jobs.positive?

      pending = Queue.new
      checks.each_with_index { |check, index| pending << [check, index] }
      values = Array.new(checks.size)
      failure = nil
      lock = Mutex.new
      workers = Array.new([jobs, checks.size].min) do
        Thread.new do
          loop do
            break if lock.synchronize { failure }

            check, index = begin
              pending.pop(true)
            rescue ThreadError
              break
            end
            begin
              values[index] = check.call
            rescue StandardError => error
              lock.synchronize { failure ||= error }
            end
          end
        end
      end
      workers.each(&:join)
      raise failure if failure

      values
    end

    # The command line of one harness run, a pure function of the roster
    # entry and the resolved tool. mutant_dir, when given, takes its place
    # in INCLUDES.
    def self.argv(entry, program:, root:, settings:, mutant_dir: nil)
      unwindset = entry.fetch('unwindset', {}).map { |loop_id, bound| "#{loop_id}:#{bound}" }.join(',')
      includes = INCLUDES.map { |path| path == :mutant ? mutant_dir : path }.compact
      [program, File.join(root, 'test/cbmc', entry.fetch('source')), '--function', 'harness',
       '--sat-solver', settings.fetch('solver'), *settings.fetch('checks'),
       '--unwinding-assertions', '--unwind', entry.fetch('unwind').to_s,
       *(unwindset.empty? ? [] : ['--unwindset', unwindset]),
       *(entry.key?('object_bits') ? ['--object-bits', entry.fetch('object_bits').to_s] : []),
       *entry.fetch('defines', {}).flat_map { |name, value| ['-D', "#{name}=#{value}"] },
       *includes.flat_map { |path| ['-I', File.expand_path(path, root)] }]
    end

    # A mutant is caught when its harness fails on a property its pattern
    # names; a failure elsewhere is a wrong catch, a pass is a miss, and a
    # run that ends without a verdict is reported as it ended.
    def self.mutant_state(result, pattern:)
      pattern_state(result, pattern: pattern)
    rescue Regexp::TimeoutError
      'error'
    end

    def self.pattern_state(result, pattern:)
      case result.verdict
      in 'verified' then 'missed'
      in 'failed' then result.failures.any? { |failure| pattern.match?(failure) } ? 'caught' : 'wrong_failure'
      in 'timed_out' | 'error' then result.verdict
      end
    end

    private_class_method :pattern_state

    def self.report(tool:, settings:, jobs:, filter:, harnesses:, mutants:, date:)
      passed = harnesses.all? { |result| result.fetch('state') == 'verified' } &&
               mutants.all? { |result| result.fetch('state') == 'caught' }
      { 'date' => date, 'state' => passed ? 'passed' : 'failed', 'filter' => filter, 'tool' => tool,
        'jobs' => jobs, 'solver' => settings.fetch('solver'), 'checks' => settings.fetch('checks'),
        'harnesses' => harnesses, 'mutants' => mutants }
    end

    def self.summary(report)
      tool = report.fetch('tool')
      lines = ["CBMC #{tool.fetch('version')} (#{tool.fetch('path')}, sha256 #{tool.fetch('sha256')})",
               "solver: #{report.fetch('solver')}; jobs: #{report.fetch('jobs')}; checks: #{report.fetch('checks').join(' ')}"]
      lines << "filter: #{report.fetch('filter')}" if report.fetch('filter')
      report.fetch('harnesses').each do |result|
        lines << format('%-16s %-9s %6d properties %8.1fs  %s', result.fetch('id'), result.fetch('state'),
                        result.fetch('properties'), result.fetch('wall_seconds'), result.fetch('bounds'))
        result.fetch('failures').first(5).each { |failure| lines << "  failed: #{failure}" }
        result.fetch('unsupported').each { |item| lines << "  unsupported: #{item}" }
      end
      report.fetch('mutants').each do |result|
        lines << format('mutant %-30s %-13s %8.1fs  %s (%s)', result.fetch('id'), result.fetch('state'),
                        result.fetch('wall_seconds'), result.fetch('defect'), result.fetch('harness'))
      end
      lines << "state: #{report.fetch('state')}"
      "#{lines.join("\n")}\n"
    end

    private

    # The tool's identity: the executable's real path, which every run then
    # names, its version, which must be the pinned one, and its SHA-256. A
    # missing tool or another version fails the gate here, before any
    # harness runs.
    def tool_identity(pinned)
      path = locate(@program)
      unless path
        raise Error, "cbmc not found (#{@program}); install cbmc #{pinned} with Homebrew or set CBMC to its path"
      end

      real = File.realpath(path)
      record = begin
        @runner.run([real, '--version'], name: 'cbmc-version', deadline: VERSION_DEADLINE)
      rescue CommandError => error
        raise Error, "cbmc at #{real} did not report its version; log: #{error.result.fetch('log')}"
      end
      reported = File.binread(record.fetch('log'), 256).to_s.lines.first.to_s.strip
      version = reported[/\A[0-9]+\.[0-9]+\.[0-9]+/]
      unless version == pinned
        raise Error, "cbmc at #{real} is version #{version || 'unknown'}; test/cbmc/roster.json pins #{pinned}"
      end
      { 'path' => real, 'version' => reported, 'sha256' => Digest::SHA256.file(real).hexdigest }
    end

    # program as the shell would find it, from an absolute PATH directory;
    # a name with a slash is taken as a path.
    def locate(program)
      executable = ->(candidate) { File.file?(candidate) && File.executable?(candidate) }
      return (executable.call(program) ? File.expand_path(program) : nil) if program.include?('/')

      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).select { |dir| dir.start_with?('/') }
         .map { |dir| File.join(dir, program) }.find(&executable)
    end

    def check_harness(entry, tool:, settings:)
      run = execute(entry, tool: tool, settings: settings, name: "cbmc-#{entry.fetch('id')}")
      { 'id' => entry.fetch('id'), 'source' => File.join('test/cbmc', entry.fetch('source')),
        'core' => entry.fetch('core'), 'state' => run.result.verdict, 'properties' => run.result.properties,
        'failures' => run.result.failures, 'wall_seconds' => run.wall_seconds.round(2),
        'bounds' => entry.fetch('bounds'), 'unwind' => entry.fetch('unwind'),
        'unwindset' => entry.fetch('unwindset', {}), 'defines' => entry.fetch('defines', {}),
        'object_bits' => entry['object_bits'], 'assumptions' => entry.fetch('assumptions'),
        'unsupported' => entry.fetch('unsupported'), 'tool_warnings' => run.result.warnings, 'log' => run.log }
    end

    def check_mutant(mutant, harness:, tool:, settings:)
      run = execute(harness, tool: tool, settings: settings, name: "cbmc-mutant-#{mutant.fetch('id')}",
                             mutant_dir: mutant_source(mutant))
      { 'id' => mutant.fetch('id'), 'harness' => mutant.fetch('harness'), 'defect' => mutant.fetch('defect'),
        'file' => mutant.fetch('file'),
        'state' => Cbmc.mutant_state(run.result, pattern: CbmcRoster.pattern(mutant)),
        'failures' => run.result.failures, 'wall_seconds' => run.wall_seconds.round(2), 'log' => run.log }
    end

    # The core with the mutant's one edit, alone in a directory emptied for
    # it under build/cbmc/mutants, so nothing an earlier run left there can
    # shadow a header; the tree's core is never written.
    def mutant_source(mutant)
      path = OutputDirectory.check(root: @root, path: File.join(@root, 'build/cbmc/mutants', mutant.fetch('id')))
      FileUtils.rm_rf(path)
      directory = OutputDirectory.prepare(root: @root, path: path)
      source = File.binread(File.join(@root, mutant.fetch('file')))
      File.binwrite(File.join(directory, File.basename(mutant.fetch('file'))),
                    source.sub(mutant.fetch('original')) { mutant.fetch('replacement') })
      directory
    end

    def execute(entry, tool:, settings:, name:, mutant_dir: nil)
      argv = Cbmc.argv(entry, program: tool.fetch('path'), root: @root, settings: settings, mutant_dir: mutant_dir)
      record = begin
        @runner.run(argv, name: name, deadline: entry.fetch('deadline'), chdir: @root, output_limit: OUTPUT_LIMIT)
      rescue CommandError => error
        error.result
      end
      result = case record.fetch('state')
               in 'succeeded' | 'failed'
                 CbmcOutput.classify(File.binread(record.fetch('log')), exit_status: record.fetch('exit_status'))
               in 'timed_out'
                 CbmcOutput::Result.new(verdict: 'timed_out', properties: 0, failures: [], warnings: [])
               else
                 CbmcOutput::Result.new(verdict: 'error', properties: 0, failures: [], warnings: [])
               end
      Run.new(result: result, wall_seconds: record.fetch('elapsed_seconds'), log: record.fetch('log'))
    end

    def remove_reports
      directory = OutputDirectory.check(root: @root, path: File.join(@root, 'build/cbmc'))
      REPORTS.each { |name| FileUtils.rm_f(File.join(directory, name)) }
    end

    def write_report(report)
      directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/cbmc'))
      bodies = { 'report.json' => "#{JSON.pretty_generate(report)}\n", 'report.txt' => Cbmc.summary(report) }
      bodies.each do |name, body|
        path = File.join(directory, name)
        raise Error, "CBMC #{name} is a symlink" if File.symlink?(path)

        Dir.mktmpdir('.report-', directory) do |temporary|
          staged = File.join(temporary, name)
          File.write(staged, body)
          File.rename(staged, path)
        end
      end
    end
  end
end
