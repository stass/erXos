# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_suites'

# Stock's per-suite results come from the stock cache when nothing they
# depend on changed, so stock runs only the suites the cache lacks.
class OracleStockCacheTest < Minitest::Test
  BUILD = { 'version' => '29.1.2', 'source_sha256' => 'ab', 'flavour' => 'jit',
            'configure' => ['--prefix=/worktree/build/oracle/jit/install', '--enable-jit'],
            'compiler' => { 'identity' => 'clang' } }.freeze

  # Stands in for stock erl: records the suites each stock run was handed
  # and returns a complete side with one passing case per suite.
  class CountingSuites < Erx::OracleSuites
    attr_reader :runs

    def run_stock_suites(_tree, directory, **)
      suites = Dir.glob('*_SUITE.beam', base: directory).map { |file| File.basename(file, '.beam') }.sort
      (@runs ||= []) << suites
      cases = suites.to_h do |suite|
        [Erx::OracleComparison::CaseKey.new(suite: suite, group: [], testcase: 'works', attempt: 1), 'passed']
      end
      Erx::OracleComparison::Side.new(state: 'complete', cases: cases, seconds: 5)
    end
  end

  def test_a_second_run_takes_the_cache_and_a_changed_input_or_new_suite_runs_on_stock
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'source')
      suites = File.join(directory, 'tree/test/ct/suites')
      FileUtils.mkdir_p([source, suites])
      File.write(File.join(source, 'a_SUITE.erl'), "-module(a_SUITE).\n")
      %w[a_SUITE b_SUITE].each { |suite| File.write(File.join(suites, "#{suite}.beam"), '') }
      cache = Erx::OracleStockCache.new(directory: File.join(directory, 'cache'))
      run = lambda do
        oracle = CountingSuites.new(root: File.expand_path('../..', __dir__), out: directory, runner: nil, deadline: 1,
                                    group: 'stdlib', source: source, stock_cache: cache)
        side = oracle.run_stock(File.join(directory, 'tree'), erl: '/stock/bin/erl', build: BUILD, schedulers: 1)
        [oracle.runs, side]
      end

      first_runs, first = run.call
      assert_equal [%w[a_SUITE b_SUITE]], first_runs
      second_runs, second = run.call
      assert_nil second_runs
      assert_equal first.cases, second.cases
      assert_equal 'complete', second.state
      assert_match(/2 of 2 suites from the cache/, second.notes.join)

      File.write(File.join(suites, 'c_SUITE.beam'), '')
      assert_equal [%w[c_SUITE]], run.call.first
      File.write(File.join(source, 'a_SUITE.erl'), "-module(a_SUITE). %% changed\n")
      assert_equal [%w[a_SUITE b_SUITE c_SUITE]], run.call.first
    end
  end
end
