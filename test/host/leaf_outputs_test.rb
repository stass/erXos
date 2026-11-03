# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/import_origins'
require_relative '../../tools/fuzz/run_pack'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

class LeafOutputsTest < Minitest::Test
  class ImportDependencies
    def initialize(**); end

    def archive_for(_id)
      [{ 'sha256' => 'a' * 64, 'directory' => 'musl-fixture' }, '/verified/fixture.tar']
    end
  end

  ImportSources = Struct.new(:source) do
    def unpack(**options)
      target = options.fetch(:destination)
      FileUtils.mkdir_p(target)
      File.binwrite(File.join(target, 'fixture.c'), source)
    end
  end

  REPOSITORY = File.expand_path('../..', __dir__).freeze

  def setup
    @directory = Dir.mktmpdir('erx-leaf-outputs-')
    @root = File.join(@directory, 'project')
    Dir.mkdir(@root)
    @outside = File.join(@directory, 'outside')
    File.binwrite(@outside, 'outside stays unchanged')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def old_corpus(component, directory:, seed:)
    corpus = File.join(@root, 'build/fuzz', component, directory)
    FileUtils.mkdir_p(corpus)
    File.symlink(@outside, File.join(corpus, seed))
    File.binwrite(File.join(corpus, 'leftover'), 'old corpus stays unchanged')
    corpus
  end

  def assert_old_corpus(corpus, seed:)
    assert File.binread(@outside) == 'outside stays unchanged', 'outside sentinel was modified'
    assert File.symlink?(File.join(corpus, seed))
    assert_equal 'old corpus stays unchanged', File.binread(File.join(corpus, 'leftover'))
  end

  # The CLI uses its repository constant. Restore this test-only substitution
  # even when a regression fails; unrelated tests keep the original root.
  def in_project
    original = Erx::ROOT
    Erx.send(:remove_const, :ROOT)
    Erx.const_set(:ROOT, @root)
    yield
  ensure
    Erx.send(:remove_const, :ROOT)
    Erx.const_set(:ROOT, original)
  end

  def fake_fuzz_runner(failure: nil)
    actual = @runner
    Object.new.tap do |runner|
      runner.define_singleton_method(:run) do |argv, **options|
        if options.fetch(:name) == 'abi-fuzz-corpus'
          actual.run([RbConfig.ruby, File.join(REPOSITORY, 'test/fuzz/abi_corpus.rb'), argv.last],
                     name: 'write-abi-corpus', deadline: 30)
        end
        if options.fetch(:name) == failure
          artifact = argv.find { |argument| argument.start_with?('-artifact_prefix=') }
          path = artifact.delete_prefix('-artifact_prefix=')
          File.binwrite(File.join(path, 'crash-fixture'), 'bounded crash input')
          File.binwrite(File.join(path, 'crash-oversized'), 'x' * 65_537)
          raise Erx::CommandError, { 'state' => 'failed', 'log' => '/retained/command.log' }
        end
        { 'state' => 'succeeded' }
      end
    end
  end

  def test_musl_profile_publication_does_not_follow_a_final_symlink
    directory = File.join(@root, 'musl')
    FileUtils.mkdir_p([directory, File.join(@root, 'config/imports')])
    source = "/* SPDX-License-Identifier: MIT */\nint fixture;\n"
    File.binwrite(File.join(directory, 'fixture.c'), source)
    profile_path = File.join(@root, 'config/imports/musl.json')
    File.symlink(@outside, profile_path)
    Erx::ImportOrigins.write(root: @root, component: 'musl',
                             dependencies: ImportDependencies, sources: ImportSources.new(source))
    assert File.binread(@outside) == 'outside stays unchanged', 'outside sentinel was modified'
    refute File.symlink?(profile_path)
    assert_equal 'v1.2.6', JSON.parse(File.binread(profile_path)).fetch('revision')
  end

  def test_direct_abi_seed_writer_refuses_an_existing_final_symlink
    corpus = old_corpus('abi', directory: 'corpus', seed: 'manifest')
    error = assert_raises(Erx::CommandError) do
      @runner.run([RbConfig.ruby, File.join(REPOSITORY, 'test/fuzz/abi_corpus.rb'), corpus],
                  name: 'direct-seed-writer', deadline: 30)
    end
    assert_includes File.binread(error.result.fetch('log')), 'cannot create ABI corpus'
    assert_old_corpus(corpus, seed: 'manifest')
  end

  def test_abi_fuzz_uses_a_fresh_workspace_and_preserves_old_corpus
    corpus = old_corpus('abi', directory: 'corpus', seed: 'manifest')
    in_project do
      Erx::CLI.send(:fuzz_c, runner: fake_fuzz_runner, environment: { 'ERX_CLANG' => 'clang' }, runs: 1, seed: 1)
    end
    assert_old_corpus(corpus, seed: 'manifest')
    assert_equal ['corpus'], Dir.children(File.dirname(corpus)).sort
  end

  def test_pack_fuzz_uses_a_fresh_workspace_and_preserves_old_corpus
    corpus = old_corpus('pack', directory: 'pack-corpus', seed: 'valid')
    Erx::PackFuzz.run(root: @root, runner: fake_fuzz_runner, runs: 1)
    assert_old_corpus(corpus, seed: 'valid')
    assert_equal ['pack-corpus'], Dir.children(File.dirname(corpus)).sort
  end

  def test_abi_fuzz_failure_keeps_only_bounded_crash_inputs
    in_project do
      error = assert_raises(Erx::CommandError) do
        Erx::CLI.send(:fuzz_c, runner: fake_fuzz_runner(failure: 'abi-fuzz'),
                      environment: { 'ERX_CLANG' => 'clang' }, runs: 1, seed: 1)
      end
      assert_equal '/retained/command.log', error.result.fetch('log')
    end
    assert_bounded_failure('abi')
  end

  def test_pack_fuzz_failure_keeps_only_bounded_crash_inputs
    error = assert_raises(Erx::CommandError) do
      Erx::PackFuzz.run(root: @root, runner: fake_fuzz_runner(failure: 'pack-fuzz'), runs: 1)
    end
    assert_equal '/retained/command.log', error.result.fetch('log')
    assert_bounded_failure('pack')
  end

  def assert_bounded_failure(component)
    runs = Dir.children(File.join(@root, 'build/fuzz', component))
    assert_equal 1, runs.size
    directory = File.join(@root, 'build/fuzz', component, runs.first)
    assert_equal ['artifacts'], Dir.children(directory)
    artifacts = File.join(directory, 'artifacts')
    assert_equal ['crash-fixture'], Dir.children(artifacts)
    assert_equal 'bounded crash input', File.binread(File.join(artifacts, 'crash-fixture'))
  end
end
