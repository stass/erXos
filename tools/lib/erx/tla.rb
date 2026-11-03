# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'thread'
require 'tmpdir'
require 'strscan'
require_relative 'dependencies'

module Erx
  module TlcOutput
    MAX_LOG_BYTES = 16 * 1024 * 1024
    PHASES = [2262, 2219, 2185, 2186].freeze
    SUCCESS = 2193
    STATISTICS = 2199
    INITIAL_VIOLATION = 2107
    BEHAVIOR_VIOLATION = 2110
    TRACE_INTRODUCTION = 2121
    TRACE_STATE = 2217
    Message = Struct.new(:code, :level, :body, keyword_init: true)
    module_function

    # TLC's -tool framing separates diagnostics from parser progress text.
    # Missing, nested or mismatched frames are incomplete evidence.
    def parse(bytes)
      raise Error, 'TLC output must be bytes' unless bytes.is_a?(String)
      raise Error, 'TLC log exceeds reader bound' if bytes.bytesize > MAX_LOG_BYTES
      messages = []
      current = nil
      bytes.each_line do |line|
        if (start = /\A@!@!@STARTMSG ([0-9]{1,4}):([0-9]) @!@!@\r?\n\z/.match(line))
          raise Error, 'nested TLC message' if current
          current = { code: start[1].to_i, level: start[2].to_i, body: ''.b }
        elsif (ending = /\A@!@!@ENDMSG ([0-9]{1,4}) @!@!@\r?\n?\z/.match(line))
          unless current && current.fetch(:code) == ending[1].to_i
            raise Error, 'unmatched TLC message end'
          end
          messages << Message.new(code: current.fetch(:code), level: current.fetch(:level),
                                  body: current.fetch(:body).strip.freeze).freeze
          current = nil
        elsif line.include?('@!@!@')
          raise Error, 'malformed TLC message framing'
        elsif current
          current.fetch(:body) << line
        end
      end
      raise Error, 'incomplete TLC message' if current
      messages.freeze
    end

    def classify(bytes, command:, expectation:)
      messages = parse(bytes)
      codes = messages.map(&:code)
      phases = PHASES.map do |code|
        positions = codes.each_index.select { |index| codes[index] == code }
        positions.size == 1 ? positions.first : nil
      end
      unless phases.none?(&:nil?) && phases == phases.sort &&
             messages[phases.first].body.start_with?('TLC2 Version ') &&
             messages[phases.last].body.start_with?('Finished in ')
        return { 'state' => 'incomplete', 'reason' => 'missing TLC start or finish' }.freeze
      end
      errors = messages.select { |message| [1, 2].include?(message.level) }
      if expectation.fetch('kind') == 'pass'
        completed = messages.any? do |message|
          message.code == SUCCESS && message.body.start_with?('Model checking completed. No error has been found.')
        end
        statistics = messages.any? do |message|
          message.code == STATISTICS && message.body.match?(/\A[0-9,]+ states generated, [0-9,]+ distinct states found, 0 states left on queue\.\z/)
        end
        accepted = command.fetch('state') == 'succeeded' && command.fetch('exit_status') == 0 &&
                   completed && statistics && errors.empty?
      else
        property = expectation.fetch('property')
        violations = errors.select { |message| [INITIAL_VIOLATION, BEHAVIOR_VIOLATION].include?(message.code) }
        witness = if violations.size == 1 && violations.first.code == INITIAL_VIOLATION
                    violations.first.body.match?(/\AInvariant #{Regexp.escape(property)} is violated by the initial state:\n.+\z/m)
                  else
                    violations.size == 1 && codes.include?(TRACE_STATE) &&
                      violations.first.body == "Invariant #{property} is violated."
                  end
        accepted = command.fetch('state') == 'failed' &&
                   command.fetch('exit_status') == expectation.fetch('exit_status') &&
                   witness &&
                   errors.all? { |message| [INITIAL_VIOLATION, BEHAVIOR_VIOLATION, TRACE_INTRODUCTION].include?(message.code) }
      end
      { 'state' => accepted ? 'checked' : 'failed',
        'reason' => accepted ? 'expectation met' : 'tool outcome did not meet expectation' }.freeze
    rescue Error => error
      { 'state' => 'incomplete', 'reason' => error.message }.freeze
    end
  end

  module TlaRoster
    FIELDS = %w[id module config translation deadline deadlock scope expect].freeze
    MAX_INPUT_BYTES = 4 * 1024 * 1024
    MAX_TOTAL_INPUT_BYTES = 64 * 1024 * 1024
    MAX_INPUTS = 1024
    module_function

    def read(root)
      inputs = snapshot(root)
      parse(inputs.fetch('roster.json'), inputs: inputs)
    end

    def snapshot(root)
      root = File.expand_path(root)
      paths = (Dir.glob(File.join(root, '**/*.{tla,cfg}'), File::FNM_DOTMATCH) +
               [File.join(root, 'roster.json')]).sort
      raise Error, 'too many TLA inputs' if paths.size > MAX_INPUTS
      total = 0
      paths.to_h do |path|
        unless File.file?(path) && !File.symlink?(path)
          raise Error, "missing regular TLA input: #{path}"
        end
        bytes = File.binread(path, MAX_INPUT_BYTES + 1) || ''.b
        raise Error, 'TLA input exceeds reader bound' if bytes.bytesize > MAX_INPUT_BYTES
        total += bytes.bytesize
        raise Error, 'TLA input snapshot exceeds aggregate bound' if total > MAX_TOTAL_INPUT_BYTES
        [path.delete_prefix(root + '/').freeze, bytes.freeze]
      end.freeze
    end

    def parse(bytes, inputs:)
      raise Error, 'invalid TLA input snapshot' unless bytes.is_a?(String) && inputs.is_a?(Hash)
      data = JsonInput.parse(bytes, max_bytes: MAX_INPUT_BYTES, label: 'TLA roster')
      unless data.is_a?(Hash) && data.keys.sort == %w[entries version] &&
             data.fetch('version') == 1 && data.fetch('entries').is_a?(Array) && !data.fetch('entries').empty?
        raise Error, 'invalid TLA roster'
      end
      entries = data.fetch('entries')
      entries.each { |entry| validate(entry, inputs: inputs) }
      %w[id config].each do |field|
        values = entries.map { |entry| entry.fetch(field) }
        raise Error, "duplicate TLA #{field}" unless values.uniq == values
      end
      actual = inputs.keys.select { |name| name.end_with?('.cfg') }.sort
      unless actual == entries.map { |entry| entry.fetch('config') }.sort
        raise Error, 'missing or unregistered TLA configurations'
      end
      entries.map(&:freeze).freeze
    rescue JSON::ParserError => error
      raise Error, "invalid TLA roster JSON: #{error.message}"
    end

    def validate(entry, inputs:)
      unless entry.is_a?(Hash) && entry.keys.sort == FIELDS.sort &&
             entry.fetch('id').is_a?(String) && /\A[a-z][a-z0-9_-]*\z/.match?(entry.fetch('id')) &&
             entry.fetch('module').is_a?(String) && /\A[A-Za-z][A-Za-z0-9_]*\z/.match?(entry.fetch('module')) &&
             entry.fetch('config').is_a?(String) && /\A[A-Za-z0-9_-]+\.cfg\z/.match?(entry.fetch('config')) &&
             %w[tla pluscal].include?(entry.fetch('translation')) &&
             %w[check terminal].include?(entry.fetch('deadlock')) &&
             %w[finite constrained].include?(entry.fetch('scope')) &&
             entry.fetch('deadline').is_a?(Integer) && entry.fetch('deadline').between?(1, 3600)
        raise Error, 'invalid TLA roster entry'
      end
      %W[#{entry.fetch('module')}.tla #{entry.fetch('config')}].each do |name|
        raise Error, "missing TLA snapshot input: #{name}" unless inputs[name].is_a?(String)
      end
      expectation = entry.fetch('expect')
      raise Error, 'invalid TLA expectation' unless expectation.is_a?(Hash)
      case expectation['kind']
      when 'pass'
        raise Error, 'unexpected pass expectation fields' unless expectation.keys == ['kind']
      when 'counterexample'
        unless expectation.keys.sort == %w[exit_status kind property] &&
               expectation.fetch('property').is_a?(String) &&
               /\A[A-Za-z][A-Za-z0-9_]*\z/.match?(expectation.fetch('property')) &&
               expectation.fetch('exit_status') == 12
          raise Error, 'expected counterexample needs an exact invariant and safety exit status'
        end
      else
        raise Error, 'unknown TLA expectation kind'
      end
      constrained = constraint_keyword?(inputs.fetch(entry.fetch('config')))
      if constrained && entry.fetch('scope') != 'constrained'
        raise Error, 'TLA state constraints require an explicitly constrained scope'
      end
      expectation.freeze
    end
    private_class_method :validate

    # Identify only reserved configuration directives, ignoring strings and
    # comments. TLC remains responsible for the complete configuration syntax.
    def constraint_keyword?(bytes)
      scanner = StringScanner.new(bytes)
      depth = 0
      constrained = false
      until scanner.eos?
        if scanner.scan(/\(\*/)
          depth += 1
          raise Error, 'TLA configuration comment nesting exceeds bound' if depth > 64
        elsif depth.positive?
          if scanner.scan(/\*\)/)
            depth -= 1
          else
            scanner.getch
          end
        elsif scanner.scan(/\\\*[^\n]*/)
          next
        elsif scanner.scan(/"(?:\\.|[^"\\])*"/m)
          next
        elsif scanner.peek(1) == '"'
          raise Error, 'unterminated TLA configuration string'
        elsif (word = scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/))
          constrained = true if %w[CONSTRAINT CONSTRAINTS ACTION_CONSTRAINT ACTION_CONSTRAINTS].include?(word)
        else
          scanner.getch
        end
      end
      raise Error, 'unterminated TLA configuration comment' unless depth.zero?
      constrained
    end
    private_class_method :constraint_keyword?
  end

  class Tla
    CLEAN_JAVA_ENV = { 'JAVA_TOOL_OPTIONS' => nil, '_JAVA_OPTIONS' => nil,
                       'JDK_JAVA_OPTIONS' => nil, 'CLASSPATH' => nil,
                       'TLA_LIBRARY' => nil }.freeze
    DEFAULT_JAR = '/Applications/TLA+ Toolbox.app/Contents/Eclipse/tla2tools.jar'

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   java: ENV.fetch('JAVA', 'java'), jar: ENV['TLA_TOOLS_JAR'])
      @root = File.expand_path(root)
      @specs = File.join(@root, 'specs/tla')
      @runner = runner
      @java = java
      @pin = DependencySchema.parse(File.binread(File.join(@root, 'deps.lock')))
                             .find { |source| source.fetch('id') == 'tla-tools' }
      raise Error, 'TLA tool has no pinned dependency' unless @pin
      fetched = File.join(@root, 'build/third_party/tla-tools/tla2tools.jar')
      @jar = File.expand_path(jar || (File.file?(DEFAULT_JAR) ? DEFAULT_JAR : fetched))
    end

    def run(filter: nil, no_cache: ENV['TLA_NO_CACHE'] == '1')
      inputs = source_inputs
      entries = TlaRoster.parse(inputs.fetch('roster.json'), inputs: inputs)
      selected = filter ? entries.select { |entry| entry.fetch('id').include?(filter) } : entries
      raise Error, 'TLA filter matched no configurations' if selected.empty?
      settings = execution_settings
      validate_jar
      identity = java_identity
      queue = Queue.new
      selected.each { |entry| queue << entry }
      results = Queue.new
      mutex = Mutex.new
      cancelled = false
      stopped = -> { mutex.synchronize { cancelled } }
      workers = []
      failure = nil
      cancel = -> { mutex.synchronize { cancelled = true } }
      begin
        [settings.fetch('jobs'), selected.size].min.times do
          workers << Thread.new do
            Thread.current.report_on_exception = false
            loop do
              break if stopped.call
              begin
                entry = queue.pop(true)
              rescue ThreadError
                break
              end
              result = check_entry(entry, inputs: inputs, identity: identity,
                                   settings: settings, no_cache: no_cache, cancelled: stopped)
              results << result
              mutex.synchronize { cancelled = true } unless %w[checked cached].include?(result.fetch('state'))
            end
          end
        end
        workers.each do |worker|
          begin
            worker.join
          rescue Exception => error
            # Join failures are deferred until every child owner has finished.
            failure ||= error
            cancel.call
          end
        end
      rescue Exception => error
        failure ||= error
      ensure
        cancel.call
        workers.each do |worker|
          begin
            worker.join
          rescue Exception => error
            failure ||= error
          end
        end
      end
      raise failure if failure
      observed = []
      observed << results.pop until results.empty?
      by_id = observed.to_h { |result| [result.fetch('id'), result] }
      report = selected.map do |entry|
        by_id[entry.fetch('id')] || { 'id' => entry.fetch('id'), 'state' => 'cancelled',
                                     'reason' => 'not started after another failure' }
      end
      write_report(report)
      report.each { |result| Terminal.puts("#{result.fetch('id')}: #{result.fetch('state')}") }
      unless report.all? { |result| %w[checked cached].include?(result.fetch('state')) }
        raise Error, 'TLA gate failed; see build/tla/report.json and command logs'
      end
      report.freeze
    end

    private

    def execution_settings
      jobs = integer_setting('TLA_JOBS', default: 2, maximum: 32)
      workers = integer_setting('TLA_WORKERS', default: 1, maximum: 64)
      raw_memory = ENV.fetch('TLA_JVM_MEM', '512m')
      match = /\A([1-9][0-9]*)([mMgG]?)\z/.match(raw_memory)
      raise Error, 'TLA_JVM_MEM must be a positive MiB or GiB size' unless match
      memory = match[1].to_i * (match[2].downcase == 'g' ? 1024 : 1)
      unless memory.between?(16, 8192) && memory * jobs <= 8192
        raise Error, 'TLA aggregate Java heap exceeds 8192 MiB'
      end
      { 'jobs' => jobs, 'workers' => workers, 'heap_mib' => memory }.freeze
    end

    def integer_setting(name, default:, maximum:)
      text = ENV.fetch(name, default.to_s)
      unless /\A[1-9][0-9]*\z/.match?(text) && text.to_i <= maximum
        raise Error, "#{name} must be between 1 and #{maximum}"
      end
      text.to_i
    end

    def validate_jar
      raise Error, 'missing TLC jar; run make fetch or set TLA_TOOLS_JAR' unless File.file?(@jar)
      unless File.size(@jar) <= Sources::MAX_ARCHIVE_BYTES && Digest::SHA256.file(@jar).hexdigest == @pin.fetch('sha256')
        raise Error, 'TLC jar SHA-256 does not match deps.lock'
      end
    end

    def java_identity
      result = @runner.run([@java, '-version'], name: 'tla-java-version', deadline: 10, env: CLEAN_JAVA_ENV)
      text = (File.binread(result.fetch('log'), 16 * 1024) || ''.b).force_encoding(Encoding::UTF_8)
      raise Error, 'Java returned no valid version identity' if text.empty? || !text.valid_encoding?
      text.freeze
    rescue CommandError
      raise Error, 'Java setup failed; select an installed Homebrew JVM with JAVA'
    end

    def source_inputs
      TlaRoster.snapshot(@specs)
    end

    def check_entry(entry, inputs:, identity:, settings:, no_cache:, cancelled:)
      key_data = { 'entry' => entry, 'inputs' => inputs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                   'settings' => settings, 'java' => identity, 'jar' => @pin.fetch('sha256'),
                   'runner' => Digest::SHA256.file(__FILE__).hexdigest,
                   'process_runner' => Digest::SHA256.file(File.join(__dir__, 'runner.rb')).hexdigest }
      key = Digest::SHA256.hexdigest(JSON.generate(key_data))
      cached = find_cached_result(key, entry: entry, input_hashes: key_data.fetch('inputs')) unless no_cache
      return cached if cached

      directory = File.join(@root, 'build/tla/runs')
      directory = OutputDirectory.prepare(root: @root, path: directory)
      work = Dir.mktmpdir("#{entry.fetch('id')}-", directory)
      begin
        inputs.each do |name, bytes|
          path = File.join(work, name)
          OutputDirectory.prepare(root: work, path: File.dirname(path))
          File.binwrite(path, bytes)
        end
        jar = File.join(work, 'tla2tools.jar')
        FileUtils.copy_file(@jar, jar)
        unless Digest::SHA256.file(jar).hexdigest == @pin.fetch('sha256')
          raise Error, 'TLC jar changed while creating private snapshot'
        end
        temporary = File.join(work, 'tmp')
        Dir.mkdir(temporary)
        translate(entry, work: work, jar: jar, temporary: temporary, cancelled: cancelled, settings: settings)
        argv = [@java, "-Xmx#{settings.fetch('heap_mib')}m", '-Xms16m', '-XX:+UseParallelGC',
                "-Djava.io.tmpdir=#{temporary}", '-cp', jar, 'tlc2.TLC', '-tool',
                '-workers', settings.fetch('workers').to_s, '-seed', '0', '-fp', '0',
                '-noGenerateSpecTE', '-metadir', File.join(work, 'states'),
                '-config', entry.fetch('config')]
        argv << '-deadlock' if entry.fetch('deadlock') == 'terminal'
        argv << entry.fetch('module')
        begin
          command = @runner.run(argv, name: "tla-#{entry.fetch('id')}", deadline: entry.fetch('deadline'),
                                chdir: work, env: CLEAN_JAVA_ENV, cancelled: cancelled)
        rescue CommandError => error
          command = error.result
        end
        bytes = File.binread(command.fetch('log'), TlcOutput::MAX_LOG_BYTES + 1) || ''.b
        outcome = TlcOutput.classify(bytes, command: command, expectation: entry.fetch('expect'))
        outcome = outcome.merge('state' => command.fetch('state')) if %w[timed_out cancelled].include?(command.fetch('state'))
        result = outcome.merge('id' => entry.fetch('id'), 'scope' => entry.fetch('scope'),
                               'elapsed_seconds' => command.fetch('elapsed_seconds'),
                               'log' => command.fetch('log'), 'log_sha256' => Digest::SHA256.hexdigest(bytes),
                               'key' => key, 'java' => identity, 'settings' => settings,
                               'work' => work, 'input_sha256' => key_data.fetch('inputs'))
      ensure
        # Keep model/config snapshots as evidence; large search state and the
        # redundant pinned tool copy are disposable after their process exits.
        %w[states tmp tla2tools.jar].each do |name|
          path = File.join(work, name)
          FileUtils.remove_entry(path) if File.exist?(path) || File.symlink?(path)
        end
      end
      write_cache(key, result: result) if result.fetch('state') == 'checked'
      result.freeze
    rescue Error, SystemCallError => error
      { 'id' => entry.fetch('id'), 'state' => 'failed', 'reason' => error.message }.freeze
    end

    def translate(entry, work:, jar:, temporary:, cancelled:, settings:)
      return if entry.fetch('translation') == 'tla'

      original = File.binread(File.join(work, "#{entry.fetch('module')}.tla"))
      @runner.run([@java, "-Xmx#{settings.fetch('heap_mib')}m", '-Xms16m',
                   "-Djava.io.tmpdir=#{temporary}", '-cp', jar, 'pcal.trans', entry.fetch('module')],
                  name: "translate-#{entry.fetch('id')}", deadline: entry.fetch('deadline'),
                  chdir: work, env: CLEAN_JAVA_ENV, cancelled: cancelled)
      unless File.binread(File.join(work, "#{entry.fetch('module')}.tla")) == original
        raise Error, 'PlusCal translation differs from checked-in module'
      end
    end

    def cache_path(key)
      File.join(@root, 'build/tla/cache', "#{key}.json")
    end

    def find_cached_result(key, entry:, input_hashes:)
      path = cache_path(key)
      OutputDirectory.check(root: @root, path: File.dirname(path))
      return nil unless File.file?(path) && File.size(path) < 64 * 1024

      result = JSON.parse(File.read(path))
      return nil unless result.is_a?(Hash) && result['state'] == 'checked' && result['key'] == key &&
                        result['id'] == entry.fetch('id') && result['input_sha256'] == input_hashes
      work = result['work']
      runs = File.realpath(File.join(@root, 'build/tla/runs')) + '/'
      return nil unless work.is_a?(String) && !work.include?("\0") && File.realpath(work).start_with?(runs)
      input_hashes.each do |name, hash|
        path = File.join(work, name)
        return nil unless File.file?(path) && !File.symlink?(path) &&
                          File.realpath(path).start_with?(File.realpath(work) + '/') &&
                          Digest::SHA256.file(path).hexdigest == hash
      end
      log = result['log']
      logs = File.realpath(File.join(@root, 'build/logs')) + '/'
      return nil unless log.is_a?(String) && !log.include?("\0") && File.realpath(log).start_with?(logs)
      bytes = File.binread(log, TlcOutput::MAX_LOG_BYTES + 1) || ''.b
      return nil unless Digest::SHA256.hexdigest(bytes) == result['log_sha256']
      # Recheck original raw evidence rather than trusting a green JSON label.
      command_report = JSON.parse(File.read(log.sub(/\.log\z/, '.json')))
      return nil unless TlcOutput.classify(bytes, command: command_report,
                                           expectation: entry.fetch('expect')).fetch('state') == 'checked'
      result.merge('state' => 'cached').freeze
    rescue JSON::ParserError, KeyError, SystemCallError, Error
      nil
    end

    def write_cache(key, result:)
      path = cache_path(key)
      OutputDirectory.prepare(root: @root, path: File.dirname(path))
      Dir.mktmpdir('.cache-', File.dirname(path)) do |temporary|
        staged = File.join(temporary, 'result.json')
        File.write(staged, JSON.pretty_generate(result) + "\n")
        File.rename(staged, path)
      end
    end

    def write_report(results)
      directory = File.join(@root, 'build/tla')
      directory = OutputDirectory.prepare(root: @root, path: directory)
      path = File.join(directory, 'report.json')
      raise Error, 'TLA report is a symlink' if File.symlink?(path)
      Dir.mktmpdir('.report-', directory) do |temporary|
        staged = File.join(temporary, 'report.json')
        File.write(staged, JSON.pretty_generate(results) + "\n")
        File.rename(staged, path)
      end
    end
  end
end
