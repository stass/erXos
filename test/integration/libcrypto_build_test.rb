# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/libcrypto'
require_relative '../../tools/lib/erx/runner'

# The import's configure check (docs/design-crypto.md, Verification): OpenSSL's
# Configure with erXos's options succeeds on the imported tree, and the build makes
# libcrypto.a for erxos-aarch64, whose imports keep the seed path. Each seeded fault
# runs on a copy of openssl/: ssl/build.info left out, so Configure fails, and
# rand_unix.c without its edit, so the import check finds the weak getentropy.
#
# `make check-openssl` runs this. It is excused from `make check`, since it builds
# musl and OpenSSL. ERX_CLANG names the clang.
class LibcryptoBuildTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  RAND_UNIX = 'providers/implementations/rands/seeding/rand_unix.c'
  RAND_UNIX_OBJECT = 'providers/implementations/rands/seeding/libdefault-lib-rand_unix.o'
  JOBS = 8

  def setup
    # Resolved as `tools/erx build openssl` resolves it, so the two share one configuration.
    @compiler = File.realpath(ENV.fetch('ERX_CLANG') { flunk 'set ERX_CLANG to the installed LLVM clang' })
    @runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    @sysroot = Erx::Libcrypto.sysroot(root: ROOT, runner: @runner, compiler: @compiler, jobs: JOBS)
  end

  def libcrypto(source: File.join(ROOT, 'openssl'))
    Erx::Libcrypto.new(root: ROOT, runner: @runner, compiler: @compiler, source: source)
  end

  # A copy of openssl/ under the build tree, with fault applied to it, and its own build directory.
  def with_seeded_copy(fault)
    parent = File.join(ROOT, 'build/tmp')
    FileUtils.mkdir_p(parent)
    Dir.mktmpdir('openssl-seeded-', parent) do |directory|
      source = File.join(directory, 'openssl')
      FileUtils.cp_r(File.join(ROOT, 'openssl'), source)
      fault.call(source)
      yield source, File.join(directory, 'obj')
    end
  end

  def test_libcrypto_builds_for_erxos_and_keeps_its_imports
    archive = libcrypto.build(directory: File.join(ROOT, Erx::Libcrypto::BASE, 'obj'), sysroot: @sysroot, jobs: JOBS)

    assert_equal File.join(ROOT, Erx::Libcrypto::BASE, 'obj/libcrypto.a'), archive
    assert_operator File.size(archive), :>, 1024 * 1024
  end

  def test_configure_fails_on_a_tree_without_a_build_info_it_reads
    with_seeded_copy(->(source) { File.delete(File.join(source, 'ssl/build.info')) }) do |source, objects|
      error = assert_raises(Erx::Error) { libcrypto(source: source).build(directory: objects, sysroot: @sysroot, jobs: JOBS) }

      assert_match(/Configure failed/, error.message)
      log = error.message[/log: (\S+)\z/, 1]
      assert_includes File.read(log), 'ssl/build.info'
    end
  end

  # Without its edit, syscall_random looks getentropy up weakly and never calls getrandom.
  def test_import_check_finds_rand_unix_without_its_edit
    unedit = lambda do |source|
      path = File.join(source, RAND_UNIX)
      text = File.read(path)
      File.write(path, text.gsub('defined(__erxos__)', 'defined(__erxos_seeded_fault__)'))
    end
    with_seeded_copy(unedit) do |source, objects|
      error = assert_raises(Erx::Error) do
        libcrypto(source: source).build(directory: objects, sysroot: @sysroot, jobs: JOBS, target: RAND_UNIX_OBJECT)
      end

      assert_includes error.message, 'libdefault-lib-rand_unix.o references getentropy (w)'
      assert_includes error.message, 'libdefault-lib-rand_unix.o does not reference getrandom strongly'
    end
  end
end
