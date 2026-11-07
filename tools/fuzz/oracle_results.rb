#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/oracle_results'

options = { seconds: 3, seed: 1 }
parser = OptionParser.new do |arguments|
  arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
  arguments.on('--seed N', Integer) { |value| options[:seed] = value }
end
begin
  remaining = parser.parse(ARGV)
  raise OptionParser::InvalidArgument, 'unexpected arguments' unless remaining.empty?
  unless options.fetch(:seconds).between?(1, 300)
    raise OptionParser::InvalidArgument, 'seconds must be between 1 and 300'
  end
  seed = '<testsuites><testsuite name="fuzz_SUITE" errors="0" tests="1" failures="0" skipped="0">' \
         '<testcase name="one" group="nested.group" log="one.html" time="0.1"/>' \
         '</testsuite></testsuites>'
  random = Random.new(options.fetch(:seed))
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options.fetch(:seconds)
  iterations = 0
  event_seed = [{ 'event' => 'test_start' },
                { 'event' => 'selection_begin', 'id' => '#Ref<9.0.0>' },
                { 'event' => 'job_selected', 'selection' => '#Ref<9.0.0>', 'id' => '#Ref<9.0.1>', 'name' => 'fixture' },
                { 'event' => 'selection_seal', 'id' => '#Ref<9.0.0>', 'count' => 1 },
                { 'event' => 'job_admitted', 'id' => '#Ref<9.0.1>' },
                { 'event' => 'job_worker', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>' },
                { 'event' => 'case_start', 'id' => '#Ref<0.1.2>', 'suite' => 'fuzz_SUITE',
                  'testcase' => 'one', 'groups' => [{ 'id' => '#Ref<0.1.3>', 'name' => 'nested' }], 'log' => 'one.html', 'worker' => '<0.1.0>' },
                { 'event' => 'tc_start', 'suite' => 'fuzz_SUITE', 'testcase' => 'one', 'group' => 'nested' },
                { 'event' => 'tc_done', 'suite' => 'fuzz_SUITE', 'testcase' => 'one', 'group' => 'nested',
                  'result' => 'passed', 'detail' => 'ok' },
                { 'event' => 'case_finish', 'id' => '#Ref<0.1.2>', 'status' => 'passed', 'number' => 1, 'detail' => 'ok' },
                { 'event' => 'test_stats', 'passed' => 1, 'failed' => 0,
                  'user_skip' => 0, 'auto_skip' => 0 },
                { 'event' => 'job_traversed', 'worker' => '<0.1.0>' },
                { 'event' => 'job_exit', 'id' => '#Ref<9.0.1>', 'worker' => '<0.1.0>', 'normal' => true },
                { 'event' => 'selection_close', 'id' => '#Ref<9.0.0>', 'normal' => true },
                { 'event' => 'test_done' }].map { |record| JSON.generate(record) + "\n" }.join
  skip_xml = '<testsuites><testsuite name="previous_SUITE" errors="0" tests="1" failures="0" skipped="1">' \
             '<testcase name="all" group="" log="" time="0.1"><skipped>{tc_user_skip,"Benchmarks only"}</skipped></testcase>' \
             '</testsuite></testsuites>'
  skip_events = [{ 'event' => 'test_start' },
                 { 'event' => 'tc_user_skip', 'suite' => 'skipped_SUITE', 'testcase' => 'all',
                   'group' => nil, 'detail' => '"Benchmarks only"' },
                 { 'event' => 'test_stats', 'passed' => 0, 'failed' => 0, 'user_skip' => 1, 'auto_skip' => 0 },
                 { 'event' => 'test_done' }].map { |record| JSON.generate(record) + "\n" }.join
  seeds = [[seed, event_seed], [skip_xml, skip_events]]
  Dir.mktmpdir('erx-oracle-fuzz-') do |directory|
    xml = File.join(directory, 'junit.xml')
    events = File.join(directory, 'events.jsonl')
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      mutate_xml = random.rand(2).zero?
      xml_seed, records_seed = seeds.fetch(random.rand(seeds.size))
      bytes = (mutate_xml ? xml_seed : records_seed).dup.b
      random.rand(1..8).times { bytes.setbyte(random.rand(bytes.bytesize), random.rand(256)) }
      File.binwrite(xml, mutate_xml ? bytes : xml_seed)
      lost = random.rand(2)
      # A stream that lost lines is missing whole ones, as a torn frame leaves it.
      bytes = bytes.lines.tap { |lines| lines.delete_at(random.rand(lines.size)) }.join if lost.positive? && !mutate_xml
      File.binwrite(events, mutate_xml ? records_seed : bytes)
      begin
        # Exercise the production event reducer, whole or with lines lost, and
        # the optional XML decoder.
        result = Erx::OracleResults.read(xml: xml, events: events, command: { 'state' => 'succeeded' },
                                         lost: lost)
        JSON.generate(result)
      rescue Erx::Error
        # Invalid inputs are an ordinary parser result; other exceptions fail.
      end
      iterations += 1
    end
  end
  Erx::Terminal.puts("oracle XML fuzz: #{iterations} inputs, seed #{options.fetch(:seed)}")
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
