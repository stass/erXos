# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/fat_volumes'
require_relative '../../tools/lib/erx/fsimg'

# The FAT server's allocator (docs/design-storage.md, "Removable media: FAT"):
# test/erlang/erx_fat_alloc_tests.erl runs on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies) over volumes it builds and over the FAT16 and FAT32
# volumes fsimg writes of FatVolumes' tree, whose results fsimg's verify checks,
# against erx_fat_alloc as it is and against each seeded fault below, where the named
# case must fail.
class ErxFatAllocTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_alloc.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_alloc_tests.erl].freeze

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_fat_alloc; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'the allocation and publication steps swapped',
              from: '-define(STEPS, [allocation, publication, release]).',
              to: '-define(STEPS, [publication, allocation, release]).',
              caught_by: 'batches_keep_every_chain_whole_at_every_cut_test_'),
    Fault.new(name: 'a cluster freed in a batch allocated again in it',
              from: 'case not is_map_key(Cluster, Batch) andalso Value =:= ?FREE of',
              to: 'case freed(Alloc, Cluster) orelse (not is_map_key(Cluster, Batch) andalso Value =:= ?FREE) of',
              caught_by: 'a_freed_cluster_is_not_allocated_again_in_its_batch_test'),
    Fault.new(name: 'a new run written with the link that publishes it',
              from: 'step(true, _Value) -> allocation;', to: 'step(true, _Value) -> publication;',
              caught_by: 'batches_keep_every_chain_whole_at_every_cut_test_'),
    Fault.new(name: 'the release step merged into the publication step',
              from: 'step(_Fresh, ?FREE) -> release;', to: 'step(_Fresh, ?FREE) -> publication;',
              caught_by: 'batches_keep_every_chain_whole_at_every_cut_test_'),
    Fault.new(name: 'a copy of the FAT left unwritten',
              from: 'Copy <- lists:seq(0, Fats - 1)', to: 'Copy <- lists:seq(0, 0)',
              caught_by: 'batches_keep_every_chain_whole_at_every_cut_test_'),
    Fault.new(name: "FAT32's top bits dropped",
              from: 'encode(32, Old, Value) -> (Old band ?RESERVED_32) bor (Value band ?VALUE_32).',
              to: 'encode(32, _Old, Value) -> Value band ?VALUE_32.',
              caught_by: 'the_dirty_and_clean_steps_keep_the_top_bits_and_set_the_hints_test'),
    Fault.new(name: 'a link from the medium into a new run followed',
              from: '                orelse (fresh_cluster(Alloc, Next) andalso not is_map_key(Cluster, Batch)),',
              to: '                orelse false,', caught_by: 'two_chains_crossing_are_refused_test')
  ].freeze

  def self.images
    @images ||= Dir.mktmpdir('erx-fat-alloc-images').tap do |directory|
      FatVolumes.write(directory, root: ROOT)
      Minitest.after_run { FileUtils.rm_rf(directory) }
    end
  end

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\*failed\*/m, output, fault.name)
    end
  end

  private

  # Compiles the allocator as core_text, with erx_fat and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-fat-alloc-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      environment = { 'ERX_FAT_IMAGES' => self.class.images, 'ERX_FSIMG' => Erx::Fsimg.locate(root: ROOT) }
      Open3.capture2e(environment, 'gtimeout', '-k', '10', '900', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_fat_alloc_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
