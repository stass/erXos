#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../../tools/lib/erx/oracle_container'

module Erx
  module OracleContainerProof
    module_function

    def wait_for(deadline:, worker: nil)
      ends = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        raise Error, 'owned operator fixture exited before the proof finished' if worker && !worker.alive?
        value = yield
        return value if value
        raise Error, 'owned container proof readiness deadline expired' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= ends
        sleep 0.05
      end
    end

    def call(root:, context:, resources: OracleContainer::RESOURCES)
      adapter = OracleContainer.new(root: root, context: context, resources: resources)
      initial = adapter.probe
      stop = Queue.new
      announced = Queue.new
      ready = Queue.new
      heartbeats = Queue.new
      operator = Thread.new do
        adapter.detached_fixture(cancelled: -> { !stop.empty? }, started: ->(record) { announced << record },
                                 ready: -> { ready << :ready }, heartbeat: ->(count) { heartbeats << count })
      end
      operator.report_on_exception = false
      begin
        status = wait_for(deadline: 30, worker: operator) { announced.pop(true) unless announced.empty? }
        wait_for(deadline: 15, worker: operator) { ready.pop(true) unless ready.empty? }
        before = adapter.fixture_witness(status)
        initial_count = wait_for(deadline: 5, worker: operator) { heartbeats.pop(true) unless heartbeats.empty? }
        cancelled = adapter.detached_fixture(cancel_when_ready: true)
        unless cancelled.fetch('state') == 'cancelled' && cancelled.fetch('cleanup_verified') &&
               File.file?(File.join(cancelled.fetch('workspace'), 'parent-finished'))
          raise Error, 'detached-child cancellation did not remove its owned container'
        end
        replacement = adapter.probe
        after = adapter.fixture_witness(status)
        later_count = wait_for(deadline: 5, worker: operator) do
          count = heartbeats.pop(true) unless heartbeats.empty?
          count if count && count > initial_count
        end
        proof = { 'state' => 'completed', 'initial' => initial.fetch('report'),
                  'detached_cancelled' => cancelled.fetch('report'), 'replacement' => replacement.fetch('report'),
                  'operator_fixture_unchanged' => true, 'operator_cid' => status.fetch('cid'),
                  'operator_witnesses' => [before, after], 'operator_heartbeats' => [initial_count, later_count] }
      ensure
        stop << :stop
        cleanup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1200
        until operator.join(30)
          Terminal.puts('owned operator fixture is exporting evidence and cleaning its resources')
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= cleanup_deadline
            raise Error, 'owned operator fixture did not stop within its export/cleanup deadline'
          end
        end
      end
      stopped = operator.value
      unless stopped.fetch('cleanup_verified') && stopped.fetch('state') == 'cancelled'
        raise Error, 'owned operator fixture did not finish by the requested cancellation and cleanup'
      end
      heartbeat = File.join(stopped.fetch('workspace'), 'detached-heartbeat')
      unless File.file?(heartbeat) && File.read(heartbeat).to_i.positive?
        raise Error, 'separate owned operator fixture produced no continuing heartbeat evidence'
      end
      proof['operator_cleanup'] = stopped.fetch('report')
      output = File.join(root, 'build/oracle/linux/cleanup-proof.json')
      File.write(output, JSON.pretty_generate(proof) + "\n")
      Terminal.puts("container isolation and detached cleanup proof passed: #{output}")
      proof
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path('../..', __dir__) }
  parser = OptionParser.new do |arguments|
    arguments.on('--context NAME') { |value| options[:context] = value }
    arguments.on('--root DIRECTORY') { |value| options[:root] = value }
  end
  begin
    remaining = parser.parse(ARGV)
    raise OptionParser::MissingArgument, '--context' unless options[:context]
    raise OptionParser::InvalidArgument, 'unexpected arguments' unless remaining.empty?
    Erx::OracleContainerProof.call(**options)
  rescue OptionParser::ParseError => error
    Erx::Terminal.puts(error.message)
    exit 2
  rescue Erx::Error, SystemCallError => error
    Erx::Terminal.puts(error.message)
    exit 1
  end
end
