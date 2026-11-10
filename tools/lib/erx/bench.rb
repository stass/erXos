# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require 'rbconfig'
require_relative 'bench_guest'
require_relative 'bench_guest_log'
require_relative 'bench_measurement'
require_relative 'oracle'
require_relative 'json_input'

module Erx
  class Bench
    WORKLOADS = { 'otp-pingpong' => 'pingpong', 'otp-ring' => 'ring', 'otp-spawn' => 'spawn',
                  'otp-switch' => 'switch' }.freeze
    # The bench module compiled once: stock OTP runs it with -pa on directory and the guest
    # loads bytes, so both measure the one file whose digest the report records.
    Beam = Data.define(:directory, :source, :bytes, :sha256)

    FLAGS = %w[+S 1 +SDcpu 1 +SDio 1 +A 1 +sbwt none -noshell -noinput -boot no_dot_erlang].freeze

    def initialize(root:, runner: nil)
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @oracle = Oracle.new(root: @root, runner: @runner)
    end

    # With beam, stock OTP runs that compiled module instead of compiling its own.
    def run(name, flavour: 'emu', iterations: 10_000, samples: 7, beam: nil)
      workload = WORKLOADS[name]
      raise Error, "unsupported benchmark: #{name}" unless workload
      unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000) &&
             samples.is_a?(Integer) && samples.between?(1, 100)
        raise Error, 'benchmark iterations or sample count is outside its bound'
      end

      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      directory = Dir.mktmpdir("#{name}-#{flavour}-", parent)
      @oracle.with_runtime(flavour) do |runtime|
        beam ||= compile(runtime, directory)
        expression = "io:format(\"~s~n\", [json:encode(erx_otp_bench:run(#{workload},#{iterations},#{samples}))]), halt()."
        argv = [runtime.fetch('erl'), *FLAGS, '-pa', beam.directory, '-eval', expression]
        command = @runner.run(argv, name: "bench-#{name}-#{flavour}", deadline: 120,
                              env: Oracle::CLEAN_ERLANG_ENV)
        bytes = File.binread(command.fetch('log'), 1024 * 1024 + 1)
        raise Error, 'benchmark result exceeds byte bound' if bytes.bytesize > 1024 * 1024
        measurement = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'benchmark result')
        BenchMeasurement.validate(measurement, flavour: flavour, samples: samples,
                                  iterations: iterations, workload: workload)
        report = { 'name' => name, 'kind' => 'host-baseline', 'accelerator' => 'native',
                   'qemu' => 'not applicable: host OTP process', 'baseline' => 'stock OTP 29.1.2',
                   'runtime_flags' => FLAGS, 'oracle_build' => runtime.fetch('build'),
                   'host_cpu' => host_cpu,
                   'workload_source_sha256' => Digest::SHA256.file(beam.source).hexdigest,
                   'beam_sha256' => beam.sha256,
                   'definition' => definition(name), 'measurement' => measurement,
                   'command' => command }
        path = File.join(directory, 'result.json')
        File.write(path, JSON.pretty_generate(report) + "\n")
        report.merge('report' => path)
      end
    end

    # A bench module's beam (bench/<name>.erl), compiled by the oracle's erlc.
    def compile_beam(flavour: 'emu', name: 'erx_otp_bench')
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      @oracle.with_runtime(flavour) { |runtime| compile(runtime, Dir.mktmpdir("beam-#{flavour}-", parent), name: name) }
    end

    # What stock OTP holds at a shell-less start, in the shape the guest's footprint line has.
    def footprint(flavour: 'emu')
      @oracle.with_runtime(flavour) do |runtime|
        expression = "#{BenchGuest::FOOTPRINT_EXPRESSION.chomp(".")}, halt()."
        command = @runner.run([runtime.fetch('erl'), *FLAGS, '-eval', expression], name: "bench-footprint-#{flavour}",
                              deadline: 60, env: Oracle::CLEAN_ERLANG_ENV)
        { 'measurement' => BenchGuestLog.parse_footprint(File.binread(command.fetch('log'))),
          'runtime_flags' => FLAGS, 'oracle_build' => runtime.fetch('build'), 'command' => command }
      end
    end

    # The host this runs on, as the first line of a report says it.
    def host_description
      "#{host_cpu}; #{RbConfig::CONFIG['host_os']}"
    end

    # The host's load average as the host states it, for a report to say how busy the host was.
    def load_average
      if RUBY_PLATFORM.include?('darwin')
        command = @runner.run(['sysctl', '-n', 'vm.loadavg'], name: 'bench-loadavg', deadline: 10)
        File.read(command.fetch('log')).strip
      elsif File.file?('/proc/loadavg')
        File.binread('/proc/loadavg', 4096).strip
      else
        'unknown'
      end
    end

    private

    def compile(runtime, directory, name: 'erx_otp_bench')
      source = File.join(directory, "#{name}.erl")
      FileUtils.copy_file(File.join(@root, "bench/#{name}.erl"), source)
      @runner.run([runtime.fetch('erlc'), '+warnings_as_errors', '+deterministic',
                   '-o', directory, source], name: 'bench-compile', deadline: 30, env: Oracle::CLEAN_ERLANG_ENV)
      bytes = File.binread(File.join(directory, "#{name}.beam"))
      Beam.new(directory: directory, source: source, bytes: bytes, sha256: Digest::SHA256.hexdigest(bytes))
    end

    def host_cpu
      if RUBY_PLATFORM.include?('darwin')
        command = @runner.run(['sysctl', '-n', 'machdep.cpu.brand_string'],
                              name: 'bench-host-cpu', deadline: 10)
        File.read(command.fetch('log')).strip
      elsif File.file?('/proc/cpuinfo')
        File.binread('/proc/cpuinfo', 1024 * 1024).lines.find do |line|
          line.match?(/\A(?:model name|Hardware|Processor)\s*:/)
        end.to_s.strip
      else
        'unknown'
      end
    end

    def definition(name)
      case name
      when 'otp-pingpong' then '64-byte forward message and sequence reply; one worker start/stop per sample included'
      when 'otp-ring' then 'a token sent around 10,000 processes; per send, ring set-up and tear-down excluded'
      when 'otp-switch' then 'two processes calling erlang:yield() alternately on one scheduler; per yield, one switch'
      else 'sequential process spawn, monitor and DOWN receipt'
      end
    end
  end
end
