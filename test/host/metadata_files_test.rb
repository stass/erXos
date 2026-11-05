# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/bounded_file'
require_relative '../../tools/lib/erx/sources'

class MetadataFilesTest < Minitest::Test
  def setup
    @repository = File.expand_path('../..', __dir__)
    @root = Dir.mktmpdir('erx-metadata-files-')
    @runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@root) if passed?
  end

  def fifo(relative)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    @runner.run(['mkfifo', path], name: 'create-metadata-fifo', deadline: 5)
    path
  end

  def assert_prompt_rejection(command)
    error = assert_raises(Erx::CommandError) do
      @runner.run(command, name: 'reject-metadata-fifo', deadline: 1)
    end
    assert_equal 'failed', error.result.fetch('state')
    assert_equal 1, error.result.fetch('exit_status')
    error
  end

  def test_hardware_source_rejects_fifo_before_parsing
    fifo('hw/svd/input.svd')
    assert_prompt_rejection([RbConfig.ruby, File.join(@repository, 'tools/gen_hw.rb'), '--root', @root])
  end

  def test_architecture_policy_rejects_fifo_before_parsing
    fifo('hw/arch_terms/aarch64.txt')
    assert_prompt_rejection([RbConfig.ruby, '-I', File.join(@repository, 'tools/lib'), '-rerx/arch_terms',
                             '-e', 'Erx::ArchTerms.check(root: ARGV.fetch(0))', @root])
  end

  def test_toolchain_profile_rejects_fifo_before_parsing
    profile = fifo('profile.json')
    assert_prompt_rejection([RbConfig.ruby, '-I', File.join(@repository, 'tools/lib'), '-rerx/toolchain_provenance',
                             '-e', 'Erx::ToolchainProvenance.registry(profile: ARGV.fetch(0), installation: ARGV.fetch(1))',
                             profile, @root])
  end

  def test_origin_record_rejects_fifo_before_parsing
    fifo('ORIGIN.md')
    assert_prompt_rejection([RbConfig.ruby, '-I', File.join(@repository, 'tools/lib'), '-rerx/origin',
                             '-e', 'Erx::Origin.new(root: ARGV.fetch(0)).check', @root])
  end

  def test_source_archive_rejects_fifo_before_snapshot_copy
    archive = fifo('input.tar')
    command = [RbConfig.ruby, '-I', File.join(@repository, 'tools/lib'), '-rerx/sources', '-e',
               'Erx::Sources.unpack(archive: ARGV.fetch(0), sha256: "a" * 64, destination: ARGV.fetch(1), owner_root: ARGV.fetch(2), source_directory: ".", runner: nil)',
               archive, File.join(@root, 'unpacked'), @root]
    error = assert_prompt_rejection(command)
    assert_includes File.binread(error.result.fetch('log')), 'regular file'
  end

  def test_extracted_links_cannot_depend_on_the_temporary_directory_name
    archive = File.join(@root, 'fixture.tar')
    bytes = 'fixture archive'
    File.binwrite(archive, bytes)
    extractor = Object.new
    extractor.define_singleton_method(:run) do |arguments, **_options|
      tree = arguments.fetch(arguments.index('-C') + 1)
      File.binwrite(File.join(tree, 'payload'), 'fixture data')
      File.symlink(File.join(tree, 'payload'), File.join(tree, 'link'))
    end
    destination = File.join(@root, 'unpacked')
    assert_raises(Erx::Error) do
      Erx::Sources.unpack(archive: archive, sha256: Digest::SHA256.hexdigest(bytes),
                          destination: destination, owner_root: @root, source_directory: '.', runner: extractor)
    end
    refute File.exist?(destination)
  end

  def test_relative_links_cannot_leave_and_reenter_the_temporary_root
    assert_movable_link_rejected(source_directory: '.', target: '../tree/payload')
  end

  def test_links_are_validated_against_the_selected_package_root
    assert_movable_link_rejected(source_directory: 'package', target: '../package/payload')
  end

  def test_link_prefix_checks_follow_directory_aliases
    assert_movable_link_rejected(source_directory: '.', target: 'alias/../tree/payload', directory_alias: true)
  end

  def assert_movable_link_rejected(source_directory:, target:, directory_alias: false)
    archive = File.join(@root, 'fixture.tar')
    bytes = 'fixture archive'
    File.binwrite(archive, bytes)
    extractor = Object.new
    extractor.define_singleton_method(:run) do |arguments, **_options|
      tree = arguments.fetch(arguments.index('-C') + 1)
      selected = source_directory == '.' ? tree : File.join(tree, source_directory)
      Dir.mkdir(selected) unless selected == tree
      File.binwrite(File.join(selected, 'payload'), 'fixture data')
      File.symlink('.', File.join(selected, 'alias')) if directory_alias
      File.symlink(target, File.join(selected, 'link'))
    end
    destination = File.join(@root, 'unpacked')
    assert_raises(Erx::Error) do
      Erx::Sources.unpack(archive: archive, sha256: Digest::SHA256.hexdigest(bytes),
                          destination: destination, owner_root: @root,
                          source_directory: source_directory, runner: extractor)
    end
    refute File.exist?(destination)
  end

  def test_relative_parent_link_within_selected_package_survives_publication
    archive = File.join(@root, 'fixture.tar')
    bytes = 'fixture archive'
    File.binwrite(archive, bytes)
    extractor = Object.new
    extractor.define_singleton_method(:run) do |arguments, **_options|
      tree = arguments.fetch(arguments.index('-C') + 1)
      selected = File.join(tree, 'package')
      Dir.mkdir(selected)
      Dir.mkdir(File.join(selected, 'inner'))
      File.binwrite(File.join(selected, 'payload'), 'fixture data')
      File.symlink('../payload', File.join(selected, 'inner/link'))
    end
    destination = File.join(@root, 'published-name')
    Erx::Sources.unpack(archive: archive, sha256: Digest::SHA256.hexdigest(bytes),
                        destination: destination, owner_root: @root,
                        source_directory: 'package', runner: extractor)
    assert_equal 'fixture data', File.binread(File.join(destination, 'inner/link'))
  end

  def test_bounded_read_preserves_exact_immutable_bytes
    path = File.join(@root, 'bytes')
    File.binwrite(path, "\x00\xff\n".b)
    bytes = Erx::BoundedFile.read(path, maximum: 3)
    assert_equal "\x00\xff\n".b, bytes
    assert_equal Encoding::BINARY, bytes.encoding
    assert bytes.frozen?
    assert_raises(Erx::Error) { Erx::BoundedFile.read(path, maximum: 2) }
    [0, -1, 1.5, 1 << 100].each do |maximum|
      assert_raises(Erx::Error) { Erx::BoundedFile.read(path, maximum: maximum) }
    end
    assert_raises(Erx::Error) { Erx::BoundedFile.read("bad\0path", maximum: 3) }
  end

  # Records what a file read asks for, and runs a test's action before each read and
  # after each stat.
  module ReadWatch
    class << self
      attr_accessor :lengths, :before_read, :after_stat
    end

    def read(*arguments)
      ReadWatch.lengths&.push(arguments.first)
      ReadWatch.before_read&.call
      super
    end

    def stat
      super.tap { ReadWatch.after_stat&.call }
    end
  end
  File.prepend(ReadWatch)

  def watching_reads(before_read: nil, after_stat: nil)
    ReadWatch.lengths = []
    ReadWatch.before_read = before_read
    ReadWatch.after_stat = after_stat
    yield
  ensure
    ReadWatch.lengths = nil
    ReadWatch.before_read = nil
    ReadWatch.after_stat = nil
  end

  # Ruby allocates what a read asks for before reading, so asking for the bound would
  # make every small file cost a 64 MiB allocation.
  def test_bounded_read_asks_for_what_the_file_holds_and_not_its_bound
    path = File.join(@root, 'small')
    File.binwrite(path, 'small')
    watching_reads do
      assert_equal 'small', Erx::BoundedFile.read(path, maximum: 64 * 1024 * 1024)
      assert_equal [6], ReadWatch.lengths
    end
  end

  # A file's size is taken once: a file that grows far past the bound after that check
  # changes neither what the read asks for nor the typed refusal.
  def test_bounded_read_asks_for_the_size_it_checked
    path = File.join(@root, 'huge')
    File.binwrite(path, 'ab')
    grow = lambda do
      ReadWatch.after_stat = nil
      File.binwrite(path, 'x' * 1000, mode: 'ab')
    end
    watching_reads(after_stat: grow) do
      assert_raises(Erx::Error) { Erx::BoundedFile.read(path, maximum: 6) }
      assert_equal [3, 4], ReadWatch.lengths
    end
  end

  def test_bounded_read_follows_a_file_that_grows_and_still_enforces_the_bound
    path = File.join(@root, 'growing')
    File.binwrite(path, 'ab')
    grow = lambda do
      ReadWatch.before_read = nil
      File.binwrite(path, 'cdef', mode: 'ab')
    end
    watching_reads(before_read: grow) { assert_equal 'abcdef', Erx::BoundedFile.read(path, maximum: 6) }
    File.binwrite(path, 'ab')
    grow = lambda do
      ReadWatch.before_read = nil
      File.binwrite(path, 'cdefg', mode: 'ab')
    end
    watching_reads(before_read: grow) { assert_raises(Erx::Error) { Erx::BoundedFile.read(path, maximum: 6) } }
  end
end
