# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'oracle'
require_relative 'json_input'

module Erx
  class Bench
    WORKLOADS = { 'otp-pingpong' => 'pingpong', 'otp-spawn' => 'spawn' }.freeze
    FLAGS = %w[+S 1 +SDcpu 1 +SDio 1 +A 1 +sbwt none -noshell -noinput -boot no_dot_erlang].freeze

    def initialize(root:, runner: nil)
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @oracle = Oracle.new(root: @root, runner: @runner)
    end

    def run(name, flavour: 'emu', iterations: 10_000, samples: 7)
      workload = WORKLOADS[name]
      raise Error, "unsupported benchmark: #{name}" unless workload
      unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000) &&
             samples.is_a?(Integer) && samples.between?(1, 100)
        raise Error, 'benchmark iterations or sample count is outside its bound'
      end

      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      directory = Dir.mktmpdir("#{name}-#{flavour}-", parent)
      @oracle.with_runtime(flavour) do |runtime|
        source = File.join(directory, 'erx_otp_bench.erl')
        FileUtils.copy_file(File.join(@root, 'bench/erx_otp_bench.erl'), source)
        @runner.run([runtime.fetch('erlc'), '+warnings_as_errors', '+deterministic',
                     '-o', directory, source], name: 'bench-compile', deadline: 30,
                    env: Oracle::CLEAN_ERLANG_ENV)
        expression = "io:format(\"~s~n\", [json:encode(erx_otp_bench:run(#{workload},#{iterations},#{samples}))]), halt()."
        argv = [runtime.fetch('erl'), *FLAGS, '-pa', directory, '-eval', expression]
        command = @runner.run(argv, name: "bench-#{name}-#{flavour}", deadline: 120,
                              env: Oracle::CLEAN_ERLANG_ENV)
        bytes = File.binread(command.fetch('log'), 1024 * 1024 + 1)
        raise Error, 'benchmark result exceeds byte bound' if bytes.bytesize > 1024 * 1024
        measurement = JsonInput.parse(bytes, max_bytes: 1024 * 1024, label: 'benchmark result')
        validate_measurement(measurement, flavour: flavour, samples: samples,
                             iterations: iterations, workload: workload)
        report = { 'name' => name, 'kind' => 'host-baseline', 'accelerator' => 'native',
                   'qemu' => 'not applicable: host OTP process', 'baseline' => 'stock OTP 29.1.2',
                   'runtime_flags' => FLAGS, 'oracle_build' => runtime.fetch('build'),
                   'host_cpu' => host_cpu,
                   'workload_source_sha256' => Digest::SHA256.file(source).hexdigest,
                   'definition' => definition(name), 'measurement' => measurement,
                   'command' => command }
        path = File.join(directory, 'result.json')
        File.write(path, JSON.pretty_generate(report) + "\n")
        report.merge('report' => path)
      end
    end

    private

    def validate_measurement(value, flavour:, samples:, iterations:, workload:)
      unless value.is_a?(Hash) && value['emu_flavor'] == flavour &&
             value['iterations'] == iterations && value['workload'] == workload &&
             value['samples'] == samples && value['ns_per_operation'].is_a?(Array) &&
             value.fetch('ns_per_operation').size == samples &&
             value.fetch('ns_per_operation').all? { |sample| sample.is_a?(Numeric) && sample.finite? && sample >= 0 }
        raise Error, 'benchmark result does not match its requested workload'
      end
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
      if name == 'otp-pingpong'
        '64-byte forward message and sequence reply; one worker start/stop per sample included'
      else
        'sequential process spawn, monitor and DOWN receipt'
      end
    end
  end
end
