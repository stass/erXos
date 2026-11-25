# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/linux_guest'
require_relative '../../tools/lib/erx/runner'

# Linux's guest (docs/design-bench.md, "Linux's guest"): its own lock, fetched on demand
# with musl-dev unpacked to the members its pin names, and the guest's refusals before a
# session boots it. A source cache stands in for the network.
class LinuxGuestTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @directory = Dir.mktmpdir('erx-linux-guest-')
    @root = File.join(@directory, 'tree')
    @cache = File.join(@directory, 'cache')
    FileUtils.mkdir_p([File.join(@root, 'bench/linux'), @cache])
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @pinned = JSON.parse(File.read(File.join(ROOT, Erx::LinuxGuest::LOCK))).fetch('sources')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # The checked-in pin of id with the cache's bytes for it in place of Alpine's.
  def cached(id, bytes)
    pin = @pinned.find { |source| source.fetch('id') == id }
    sha256 = Digest::SHA256.hexdigest(bytes)
    suffix = pin.fetch('kind') == 'tar' ? '.tar.gz' : File.extname(pin.fetch('filename'))
    File.binwrite(File.join(@cache, "#{id}-#{sha256}#{suffix}"), bytes)
    pin.merge('sha256' => sha256)
  end

  # A package laid out as musl-dev's: its metadata beside usr, and more of usr than the
  # build reads.
  def package
    staging = File.join(@directory, 'staging')
    files = { '.PKGINFO' => "pkgname = musl-dev\n", 'usr/include/stdio.h' => "/* stdio */\n",
              'usr/lib/crt1.o' => 'crt1', 'usr/lib/crti.o' => 'crti', 'usr/lib/crtn.o' => 'crtn',
              'usr/lib/libc.a' => 'libc', 'usr/lib/libc.so' => 'shared' }
    files.each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(staging, path)))
      File.binwrite(File.join(staging, path), bytes)
    end
    archive = File.join(@directory, 'musl-dev.apk')
    _, status = Open3.capture2e('tar', '-czf', archive, '-C', staging, *files.keys)
    raise 'tar failed' unless status.success?

    File.binread(archive)
  end

  def write_lock
    sources = [cached('alpine-kernel-config', "CONFIG_HZ=1000\n"), cached('alpine-musl-dev', package),
               cached('alpine-vmlinuz-virt', 'MZzimg')]
    File.write(File.join(@root, Erx::LinuxGuest::LOCK), JSON.generate('version' => 1, 'sources' => sources))
  end

  # The scratch root holds no platform records, so the guest takes the tree's own.
  def guest = Erx::LinuxGuest::Guest.new(root: @root, runner: @runner,
                                         platform: Erx::Platform.development(ROOT))

  def test_musl_dev_is_published_as_the_members_its_pin_names_and_nothing_else
    write_lock
    lines = Erx::LinuxGuest.fetch(root: @root, runner: @runner, cache: @cache)
    assert_equal 3, lines.size
    assert(lines.all? { |line| line.start_with?('linux: ') })
    usr = Erx::LinuxGuest.lock(root: @root, runner: @runner).fetched_tree(Erx::LinuxGuest::MUSL_DEV)
    assert_equal "/* stdio */\n", File.read(File.join(usr, 'include/stdio.h'))
    assert_equal %w[crt1.o crti.o crtn.o libc.a], Dir.children(File.join(usr, 'lib')).sort
    refute File.exist?(File.join(File.dirname(usr), '.PKGINFO'))
    refute File.exist?(File.join(@root, 'build/third_party')), "Linux's pins stay out of erXos's own"
  end

  # A session is refused before any boot, in the guest's words, at a profile its program
  # is not built for and while its lock is not fetched; once fetched, it is not.
  def test_the_guest_refuses_the_full_profile_and_an_unfetched_lock
    write_lock
    assert_match(/landing profiles only/, guest.refusal('full'))
    assert_equal "linux's guest needs alpine-kernel-config, alpine-musl-dev, alpine-vmlinuz-virt: " \
                 'run `ruby tools/erx fetch --linux`', guest.refusal('landing')
    Erx::LinuxGuest.fetch(root: @root, runner: @runner, cache: @cache)
    assert_nil guest.refusal('landing')
  end

  # The checked-in lock is Linux's own: no default fetch reads it.
  def test_the_checked_in_lock_shares_no_id_with_erxoss
    erxos = JSON.parse(File.read(File.join(ROOT, 'deps.lock'))).fetch('sources').map { |entry| entry.fetch('id') }
    assert_empty erxos & @pinned.map { |source| source.fetch('id') }
  end
end
