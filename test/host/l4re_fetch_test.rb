# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/l4re_fetch'
require_relative '../../tools/lib/erx/runner'

# `tools/erx fetch --l4re` (docs/design-bench.md, "L4Re's guest"): L4Re's own lock, its
# git sources verified against their archives' SHA-256 and published under their own
# root. A source cache stands in for each clone's export, so nothing reaches the network.
class L4ReFetchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('erx-l4re-fetch-')
    @root = File.join(@directory, 'tree')
    @cache = File.join(@directory, 'cache')
    FileUtils.mkdir_p([File.join(@root, 'bench/l4re'), File.join(@root, 'fiasco/kernel'), @cache])
    File.write(File.join(@root, Erx::L4ReFetch::ORIGIN), "Repository: x\n\nRevision: #{'0' * 40}\n")
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # A git source for id whose export, a tar of one file, the cache holds.
  def source(id)
    directory = "#{id}-0000000"
    staging = File.join(@directory, 'staging', id)
    FileUtils.mkdir_p(File.join(staging, directory))
    File.write(File.join(staging, directory, 'README'), "#{id}\n")
    tar = File.join(staging, 'export.tar')
    _, status = Open3.capture2e('tar', '-cf', tar, '-C', staging, directory)
    raise 'tar failed' unless status.success?

    sha256 = Digest::SHA256.file(tar).hexdigest
    FileUtils.cp(tar, File.join(@cache, "#{id}-#{sha256}.tar.gz"))
    { 'id' => id, 'kind' => 'git', 'version' => '0' * 40, 'url' => "https://example.org/#{id}.git", 'commit' => '0' * 40,
      'sha256' => sha256, 'directory' => directory, 'license' => 'MIT', 'status' => 'permanent' }
  end

  # A Debian package source named filename whose bytes the cache holds.
  def package(id, filename: "#{id}_arm64.deb")
    bytes = "#{id} package\n"
    sha256 = Digest::SHA256.hexdigest(bytes)
    File.write(File.join(@cache, "#{id}-#{sha256}.deb"), bytes)
    { 'id' => id, 'kind' => 'file', 'version' => '1.0-1', 'url' => "https://example.org/#{filename}", 'sha256' => sha256,
      'filename' => filename, 'license' => 'MIT', 'status' => 'permanent' }
  end

  def write_lock(sources) = File.write(File.join(@root, Erx::L4ReFetch::LOCK), JSON.generate('version' => 1, 'sources' => sources))

  def fetch = Erx::L4ReFetch.fetch(root: @root, runner: @runner, cache: @cache)

  def test_every_pinned_source_is_verified_and_published_under_its_own_root
    write_lock(Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) })
    lines = fetch
    assert_equal Erx::L4ReFetch::LAYOUT.size, lines.size
    fetched = Erx::L4ReFetch.lock(root: @root, runner: @runner)
    Erx::L4ReFetch::LAYOUT.each_key do |id|
      assert_equal "#{id}\n", File.read(File.join(fetched.fetched_tree(id), 'README'))
    end
    refute File.exist?(File.join(@root, 'build/third_party')), "L4Re's trees stay out of erXos's own"
  end

  # A tree L4Re's lock pins but no fetch published names L4Re's own fetch, the one
  # that reads that lock.
  def test_an_unfetched_source_names_l4res_own_fetch
    write_lock(Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) })
    fetched = Erx::L4ReFetch.lock(root: @root, runner: @runner)
    error = assert_raises(Erx::Error) { fetched.fetched_tree(Erx::L4ReFetch::LAYOUT.keys.first) }
    assert_match(/not fetched; run `ruby tools\/erx fetch --l4re`/, error.message)
  end

  def test_an_archive_that_does_not_match_its_pin_is_refused
    sources = Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) }
    write_lock(sources)
    File.write(File.join(@cache, "l4re-ipcbench-#{sources.last.fetch('sha256')}.tar.gz"), 'tampered')
    assert_raises(Erx::Error) { fetch }
    refute File.exist?(File.join(@root, Erx::L4ReFetch::WORKSPACE, 'build/third_party/l4re-ipcbench'))
  end

  def test_a_lock_missing_a_source_of_the_layout_or_pinning_another_kind_is_refused
    write_lock(Erx::L4ReFetch::LAYOUT.keys.drop(1).map { |id| source(id) })
    assert_match(/pins git sources/, assert_raises(Erx::Error) { fetch }.message)
    tarball = source('l4re-mk').merge('kind' => 'tar').except('commit')
    write_lock([tarball, *Erx::L4ReFetch::LAYOUT.keys.drop(1).map { |id| source(id) }])
    assert_match(/pins git sources/, assert_raises(Erx::Error) { fetch }.message)
  end

  # The build's tools beyond the image come as Debian arm64 packages, fetched beside the
  # trees; any other file is refused, so the lock cannot carry something the build does
  # not unpack.
  def test_tool_packages_are_fetched_beside_the_trees_and_nothing_else_is
    write_lock([*Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) }, package('l4re-tool-flex')])
    assert_equal Erx::L4ReFetch::LAYOUT.size + 1, fetch.size
    packages = Erx::L4ReFetch.packages(Erx::L4ReFetch.lock(root: @root, runner: @runner))
    assert_equal ["l4re-tool-flex package\n"], packages.map { |file| File.read(file) }
    write_lock([*Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) }, package('l4re-tool-x', filename: 'x_amd64.deb')])
    assert_match(/l4re-tool-x, which are neither/, assert_raises(Erx::Error) { fetch }.message)
  end

  # Upstream Fiasco at another commit than the fork's would compare two revisions.
  def test_a_lock_pinning_upstream_fiasco_off_the_forks_revision_is_refused
    write_lock(Erx::L4ReFetch::LAYOUT.keys.map { |id| source(id) })
    File.write(File.join(@root, Erx::L4ReFetch::ORIGIN), "Revision: #{'1' * 40}\n")
    assert_match(/not the fork's revision/, assert_raises(Erx::Error) { fetch }.message)
    refute File.exist?(File.join(@root, Erx::L4ReFetch::WORKSPACE, 'build/third_party'))
  end

  # The checked-in lock pins exactly the layout, and no default fetch reads it.
  def test_the_checked_in_lock_is_l4res_own
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    pinned = Erx::L4ReFetch.lock(root: ROOT, runner: runner)
    trees = pinned.sources.select { |source| source.fetch('kind') == 'git' }
    assert_equal Erx::L4ReFetch::LAYOUT.keys.sort, trees.map { |source| source.fetch('id') }.sort
    erxos = JSON.parse(File.read(File.join(ROOT, 'deps.lock'))).fetch('sources').map { |entry| entry.fetch('id') }
    assert_empty erxos & pinned.sources.map { |source| source.fetch('id') }
  end
end
