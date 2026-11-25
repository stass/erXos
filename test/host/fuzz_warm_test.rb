# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/fuzz_drivers'
require_relative '../../tools/lib/erx/fuzz_warm'

# Every Erlang fuzz driver compiles through Erx::FuzzWarm.compile, which adds the
# warm-up module and runs erlc under a deadline.
class FuzzWarmTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def with_erlc
    original = ENV.fetch('ERX_ERLC', nil)
    erlc = original || File.join(ROOT, 'build/oracle/jit/install/bin/erlc')
    skip 'no stock erlc (ERX_ERLC or the oracle build)' unless File.executable?(erlc)
    begin
      ENV['ERX_ERLC'] = erlc
      Dir.mktmpdir('erx-fuzz-warm-') { |work| yield work }
    ensure
      ENV['ERX_ERLC'] = original
    end
  end

  def test_compile_adds_the_warm_up_module_and_the_include_path
    with_erlc do |work|
      include_dir = File.join(work, 'inc')
      Dir.mkdir(include_dir)
      File.write(File.join(include_dir, 'k.hrl'), "-define(K, 7).\n")
      source = File.join(work, 'target_mod.erl')
      File.write(source, "-module(target_mod).\n-include(\"k.hrl\").\n-export([k/0]).\nk() -> ?K.\n")
      Erx::FuzzWarm.compile(work: work, sources: [source], include: include_dir)
      assert File.file?(File.join(work, 'target_mod.beam'))
      assert File.file?(File.join(work, 'erx_fuzz_warm.beam'))
    end
  end

  def test_compile_failure_raises_with_erlcs_output
    with_erlc do |work|
      source = File.join(work, 'broken_mod.erl')
      File.write(source, "-module(broken_mod).\nf( -> .\n")
      error = assert_raises(Erx::Error) { Erx::FuzzWarm.compile(work: work, sources: [source]) }
      assert_match(/broken_mod\.erl/, error.message)
    end
  end

  # A target that calls erx_fuzz_warm: is compiled by a driver that names it and that
  # reaches erlc only through compile: a driver that runs erlc itself can forget the
  # warm-up module, which shows only at check-fuzz. A target no driver names fails here.
  def test_warming_targets_compile_through_the_helper
    drivers = Erx::FuzzDrivers::DIRECTORIES.flat_map { |directory| Dir[File.join(ROOT, directory, '*.rb')] }
    warming_targets.each do |target|
      named_by = drivers.select { |driver| File.read(driver).include?(target) }
      refute_empty named_by, "no fuzz driver names #{target}"
      named_by.each do |driver|
        code = File.readlines(driver).grep_v(/\A\s*#/).join
        assert_includes code, 'Erx::FuzzWarm.compile', "#{driver} must compile through Erx::FuzzWarm.compile"
        refute_match(/ERX_ERLC/, code, "#{driver} must not run erlc itself")
      end
    end
  end

  # The fuzz targets (relative paths) that call the warm-up module.
  def warming_targets
    Dir[File.join(ROOT, 'test/erlang/*.erl')]
      .select { |path| File.read(path).include?('erx_fuzz_warm:') && File.basename(path) != 'erx_fuzz_warm.erl' }
      .map { |path| path.delete_prefix("#{ROOT}/") }
  end
end
