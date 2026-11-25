# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/genode_fetch'
require_relative '../../tools/lib/erx/runner'

# `tools/erx fetch --genode` (docs/design-bench.md, "Genode's guest"): Genode's own lock,
# its release verified against its export's SHA-256 and its tool chain against the
# archive's, both published under a root of their own. A source cache stands in for the
# network, so nothing is downloaded.
class GenodeFetchTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-genode-fetch-')
    @root = File.join(@directory, 'tree')
    @cache = File.join(@directory, 'cache')
    FileUtils.mkdir_p([File.join(@root, 'bench/genode'), @cache])
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # The release as a git source whose export, a tar of one file, the cache holds.
  def release
    directory = 'genode-0000000'
    staging = File.join(@directory, 'staging')
    FileUtils.mkdir_p(File.join(staging, directory))
    File.write(File.join(staging, directory, 'README'), "genode\n")
    tar = File.join(staging, 'export.tar')
    _, status = Open3.capture2e('tar', '-cf', tar, '-C', staging, directory)
    raise 'tar failed' unless status.success?

    sha256 = Digest::SHA256.file(tar).hexdigest
    FileUtils.cp(tar, File.join(@cache, "genode-#{sha256}.tar.gz"))
    { 'id' => 'genode', 'kind' => 'git', 'version' => '26.08', 'url' => 'https://example.org/genode.git',
      'commit' => '0' * 40, 'sha256' => sha256, 'directory' => directory, 'license' => 'AGPL-3.0',
      'status' => 'permanent' }
  end

  def toolchain(filename: 'genode-toolchain-25.05-ubuntu-24.04.tar.xz')
    bytes = "tool chain\n"
    sha256 = Digest::SHA256.hexdigest(bytes)
    File.write(File.join(@cache, "genode-toolchain-#{sha256}.xz"), bytes)
    { 'id' => 'genode-toolchain', 'kind' => 'file', 'version' => '25.05', 'url' => "https://example.org/#{filename}",
      'sha256' => sha256, 'filename' => filename, 'license' => 'GPL-3.0', 'status' => 'permanent' }
  end

  def write_lock(sources) = File.write(File.join(@root, Erx::GenodeFetch::LOCK), JSON.generate('version' => 1, 'sources' => sources))

  def fetch = Erx::GenodeFetch.fetch(root: @root, runner: @runner, cache: @cache)

  def test_the_release_and_the_tool_chain_are_verified_and_published_under_their_own_root
    write_lock([release, toolchain])
    assert_equal 2, fetch.size
    fetched = Erx::GenodeFetch.lock(root: @root, runner: @runner)
    assert_equal "genode\n", File.read(File.join(fetched.fetched_tree('genode'), 'README'))
    assert_equal "tool chain\n", File.read(fetched.fetched_file('genode-toolchain'))
    refute File.exist?(File.join(@root, 'build/third_party')), "Genode stays out of erXos's own sources"
  end

  def test_an_unfetched_source_names_genodes_own_fetch
    write_lock([release, toolchain])
    fetched = Erx::GenodeFetch.lock(root: @root, runner: @runner)
    error = assert_raises(Erx::Error) { fetched.fetched_tree('genode') }
    assert_match(%r{not fetched; run `ruby tools/erx fetch --genode`}, error.message)
  end

  def test_a_tool_chain_that_does_not_match_its_pin_is_refused
    pinned = toolchain
    write_lock([release, pinned])
    File.write(File.join(@cache, "genode-toolchain-#{pinned.fetch('sha256')}.xz"), 'tampered')
    assert_raises(Erx::Error) { fetch }
    refute File.exist?(File.join(@root, Erx::GenodeFetch::WORKSPACE, 'build/third_party/genode-toolchain'))
  end

  # The lock holds the release as a git source and the tool chain as Genode's
  # pre-compiled archive, and nothing else the build would not use.
  def test_a_lock_without_exactly_the_release_and_the_tool_chain_is_refused
    write_lock([release])
    assert_match(/pins genode \(git\); Genode's lock pins/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release.merge('kind' => 'tar').except('commit'), toolchain])
    assert_match(/Genode's lock pins/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release, toolchain(filename: 'genode-toolchain-25.05-debian-12.10.tar.xz')])
    assert_match(/not Genode's pre-compiled tool chain for Ubuntu 24.04/, assert_raises(Erx::Error) { fetch }.message)
  end

  # The checked-in lock is Genode's own: the release and the tool chain, at real pins.
  def test_the_checked_in_lock_is_genodes_own
    root = File.expand_path('../..', __dir__)
    sources = JSON.parse(File.read(File.join(root, Erx::GenodeFetch::LOCK))).fetch('sources')
    assert_equal({ 'genode' => 'git', 'genode-toolchain' => 'file' }, sources.to_h { |source| [source['id'], source['kind']] })
    refute JSON.parse(File.read(File.join(root, 'deps.lock'))).fetch('sources').any? { |source| source['id'].start_with?('genode') },
           "erXos's own lock pins nothing of Genode"
  end
end
