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
# its release verified against its export's SHA-256 and every file it pins (the tool
# chain, ports' archives, tool packages) against its own, all published under a root of
# their own. A source cache stands in for the
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

  def toolchain(filename: 'genode-toolchain-25.05-debian-12.10.tar.xz')
    bytes = "tool chain\n"
    sha256 = Digest::SHA256.hexdigest(bytes)
    File.write(File.join(@cache, "genode-toolchain-#{sha256}.xz"), bytes)
    { 'id' => 'genode-toolchain', 'kind' => 'file', 'version' => '25.05', 'url' => "https://example.org/#{filename}",
      'sha256' => sha256, 'filename' => filename, 'license' => 'GPL-3.0', 'status' => 'permanent' }
  end

  # A file source the cache holds: a port's archive or a tool package.
  def file_source(id, filename, bytes: "#{id}\n")
    sha256 = Digest::SHA256.hexdigest(bytes)
    File.write(File.join(@cache, "#{id}-#{sha256}#{File.extname(filename)}"), bytes)
    { 'id' => id, 'kind' => 'file', 'version' => '1', 'url' => "https://example.org/#{filename}",
      'sha256' => sha256, 'filename' => filename, 'license' => 'BSD-2-Clause', 'status' => 'permanent' }
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

  # A port's archive is published under the name Genode's port tool asks for, and a tool
  # package beside it; both are verified against their pins like the release.
  def test_port_archives_and_tool_packages_are_verified_and_published
    write_lock([release, toolchain, file_source('genode-port-libc', 'src.txz'),
                file_source('genode-tool-flex', 'flex_amd64.deb')])
    assert_equal 4, fetch.size
    fetched = Erx::GenodeFetch.lock(root: @root, runner: @runner)
    assert_equal 'src.txz', File.basename(fetched.fetched_file('genode-port-libc'))
    assert_equal "genode-tool-flex\n", File.read(fetched.fetched_file('genode-tool-flex'))
  end

  # Beside the release and the tool chain the lock holds only ports' archives and amd64
  # tool packages: a source of another name, or a package of another architecture, is
  # refused before anything is fetched.
  def test_a_source_that_is_neither_a_port_nor_a_tool_package_is_refused
    write_lock([release, toolchain, file_source('genode-extra', 'extra.tar.gz')])
    assert_match(/pins genode-extra, which are neither/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release, toolchain, file_source('genode-tool-flex', 'flex_arm64.deb')])
    assert_match(/pins genode-tool-flex, which are neither/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release, toolchain, file_source('genode-extra', 'extra_amd64.deb')])
    assert_match(/pins genode-extra, which are neither/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release, toolchain, file_source('genode-tool-flex', 'bison_amd64.deb')])
    assert_match(/pins genode-tool-flex, which are neither/, assert_raises(Erx::Error) { fetch }.message)
    tree = release.merge('id' => 'genode-port-libc')
    write_lock([release, toolchain, tree])
    assert_match(/pins genode-port-libc, which are neither/, assert_raises(Erx::Error) { fetch }.message)
    refute File.exist?(File.join(@root, Erx::GenodeFetch::WORKSPACE, 'build/third_party/genode'))
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
    assert_match(/SHA-256 mismatch: genode-toolchain/, assert_raises(Erx::Error) { fetch }.message)
    refute File.exist?(File.join(@root, Erx::GenodeFetch::WORKSPACE, 'build/third_party/genode-toolchain'))
  end

  # The lock holds the release as a git source and the tool chain as a file, each once.
  def test_a_lock_that_does_not_pin_the_release_and_the_tool_chain_each_of_its_kind_is_refused
    write_lock([release])
    assert_match(/pins genode \(git\); Genode's lock pins/, assert_raises(Erx::Error) { fetch }.message)
    write_lock([release.merge('kind' => 'tar').except('commit'), toolchain])
    assert_match(/pins genode \(tar\), genode-toolchain \(file\); Genode's lock pins/, assert_raises(Erx::Error) { fetch }.message)
  end

  # The checked-in lock passes Genode's own rules and the lock schema, and erXos's own
  # lock pins nothing of Genode.
  def test_the_checked_in_lock_is_genodes_own
    root = File.expand_path('../..', __dir__)
    FileUtils.cp(File.join(root, Erx::GenodeFetch::LOCK), File.join(@root, Erx::GenodeFetch::LOCK))
    pinned = Erx::GenodeFetch.lock(root: @root, runner: @runner).sources
    named = pinned.select { |source| Erx::GenodeFetch::SOURCES.key?(source.fetch('id')) }
    assert_equal Erx::GenodeFetch::SOURCES, named.to_h { |source| [source.fetch('id'), source.fetch('kind')] }
    refute JSON.parse(File.read(File.join(root, 'deps.lock'))).fetch('sources').any? { |source| source['id'].start_with?('genode') },
           "erXos's own lock pins nothing of Genode"
  end
end
