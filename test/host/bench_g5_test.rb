# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench_g5'

# Gate G5's report from a guest's serial log (tools/lib/erx/bench_g5.rb): a run is complete
# only when every domain measured and halted with status 0, and a speedup is unknown, never
# a number, where a flavour did not report. Nothing boots here.
class BenchG5Test < Minitest::Test
  G5 = Erx::BenchG5
  PLAN = G5::Plan.new(accel: 'tcg', length: 10, samples: 3, rounds: 1, wait_seconds: 1)
  EMU = "{g5,emu,900,120,5000,80,0,30,6,16,13,[40,42,41],[10,10,10],[20,20,20],[90,95,91]}\r\n"
  JIT = "{g5,jit,1500,120,5000,300,0,40,6,26,13,[10,11,10],[5,5,5],[10,10,10],[30,30,30]}\r\n"
  HALTED = "G5DONE [{domain_down,9,{halt,0}},{domain_down,10,{halt,0}}]\r\n"

  def report(text)
    G5.report(plan: PLAN, guest: G5.read_log(text.b), build: {}, host: 'host', load: {}, now: Time.at(0).utc)
  end

  def test_a_run_whose_domains_measured_and_halted_is_complete_with_its_speedups
    result = report("Eshell V16\r\n#{EMU}#{JIT}#{HALTED}")
    assert result.fetch('complete')
    assert_equal({ 'sort' => 4.1, 'json_encode' => 2.0, 'json_decode' => 2.0, 'scan' => 3.03 }, result.fetch('speedup'))
    assert_equal 300, result.dig('medians', 'jit', 'prepare_us')
  end

  def test_a_domain_that_did_not_halt_or_was_refused_leaves_the_run_incomplete
    ['G5DONE [{domain_down,9,{halt,0}},timeout]', 'G5DONE [{domain_down,9,{halt,0}},{domain_down,10,crash}]',
     'G5DONE [{domain_down,9,{halt,0}},{error,quota}]', 'G5DONE [{domain_down,9,{halt,0}}]'].each do |done|
      refute report("#{EMU}#{JIT}#{done}\r\n").fetch('complete'), done
    end
    refute report("#{EMU}#{JIT}").fetch('complete'), 'no G5DONE line'
    refute report("#{EMU}#{JIT.sub(',300,0,', ',300,2,')}#{HALTED}").fetch('complete'), 'a refused prepare'
  end

  def test_a_missing_flavour_or_an_empty_sample_list_is_unknown_not_a_number
    result = report("#{EMU}#{JIT.sub('[30,30,30]', '[]')}#{HALTED}")
    refute result.fetch('complete')
    assert_nil result.dig('medians', 'jit')
    assert_equal [nil], result.fetch('speedup').values.uniq
    assert_equal '{domain_down,9,?}', G5.read_log("G5DONE {domain_down,9,\xff}\n".b).fetch('ends')
  end
end
