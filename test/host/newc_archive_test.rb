# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/newc_archive'

# The initramfs writer of Linux's guest (docs/design-bench.md, "Linux's guest"), read
# back by the host's libarchive (bsdtar), a reader independent of the writer.
class NewcArchiveTest < Minitest::Test
  Entry = Erx::NewcArchive::Entry

  def guest_entries
    [Entry.directory('dev'), Entry.directory('dev/shm'), Entry.character('dev/console', major: 5, minor: 1),
     Entry.directory('proc'), Entry.file('init', "\x7fELF payload".b, mode: 0o755)]
  end

  def listing(bytes)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'initramfs.cpio')
      File.binwrite(path, bytes)
      output, status = Open3.capture2e('tar', '-tvf', path, stdin_data: '')
      assert status.success?, output
      output.lines.map { |line| line.split.then { |words| [words.first, words.last] } }
    end
  end

  def test_the_guests_initramfs_reads_back_as_its_entries_and_modes
    assert_equal [%w[drwxr-xr-x dev], %w[drwxr-xr-x dev/shm], %w[crw------- dev/console], %w[drwxr-xr-x proc],
                  %w[-rwxr-xr-x init]], listing(Erx::NewcArchive.write(guest_entries))
  end

  def test_a_files_bytes_come_back_unchanged
    bytes = Erx::NewcArchive.write(guest_entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'initramfs.cpio')
      File.binwrite(path, bytes)
      output, status = Open3.capture2e('tar', '-xOf', path, 'init', stdin_data: '')
      assert status.success?
      assert_equal "\x7fELF payload".b, output.b
    end
  end

  def test_every_header_and_payload_is_aligned_to_four_bytes_and_the_trailer_ends_it
    bytes = Erx::NewcArchive.write([Entry.file('a', 'xyz'.b, mode: 0o644)])
    assert_equal 0, bytes.bytesize % 4
    assert bytes.start_with?('070701')
    assert_includes bytes, "TRAILER!!!\0"
  end

  def test_a_path_that_could_leave_the_archive_root_is_refused
    ['/init', '../init', 'dev/../init', 'dev//shm', '', 'dev/', "a\0b", 'a b'].each do |path|
      assert_raises(Erx::NewcArchive::Invalid, path.inspect) { Entry.directory(path) }
    end
  end

  # The names stock OTP's tree and its libraries use: a plus sign, and names as long as
  # a file system's.
  def test_a_library_and_a_long_name_of_the_otp_tree_are_plain_names
    ['lib/aarch64-linux-gnu/libstdc++.so.6', "lib/#{'n' * 255}"].each { |path| assert_equal path, Entry.directory(path).path }
    assert_raises(Erx::NewcArchive::Invalid) { Entry.directory('n' * 256) }
  end

  def test_an_entry_before_its_directory_or_twice_is_refused
    assert_raises(Erx::NewcArchive::Invalid) { Erx::NewcArchive.write([Entry.directory('dev/shm')]) }
    assert_raises(Erx::NewcArchive::Invalid) do
      Erx::NewcArchive.write([Entry.directory('dev'), Entry.directory('dev')])
    end
  end
end
