# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../../tools/lib/erx/cross_toolchain'

# CrossToolchain.find over a PATH of fixture directories, each holding the
# cross programs a test installs in it.
class CrossToolchainTest < Minitest::Test
  HOMEBREW = 'aarch64-elf-'
  PORT = 'aarch64-none-elf-'

  def setup
    @directory = File.realpath(Dir.mktmpdir)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  # A directory named name holding an executable for each of programs.
  def installed(name, programs)
    directory = File.join(@directory, name)
    FileUtils.mkdir_p(directory)
    programs.each do |program|
      path = File.join(directory, program)
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
    end
    directory
  end

  def toolchain(prefix) = %w[gcc g++ as].map { |program| prefix + program }

  def find(*directories) = Erx::CrossToolchain.find(path: directories.join(File::PATH_SEPARATOR))

  def test_homebrew_prefix_alone
    found = find(installed('homebrew', toolchain(HOMEBREW)))
    assert_equal HOMEBREW, found.prefix
    assert_equal 'aarch64-elf-nm', found.program('nm')
    assert_equal 'aarch64-elf', found.target
  end

  def test_port_prefix_alone
    found = find(installed('port', toolchain(PORT)))
    assert_equal PORT, found.prefix
    assert_equal 'aarch64-none-elf-objcopy', found.program('objcopy')
    assert_equal 'aarch64-none-elf', found.target
  end

  def test_homebrew_prefix_wins_when_both_are_installed
    port = installed('port', toolchain(PORT))
    homebrew = installed('homebrew', toolchain(HOMEBREW))
    assert_equal HOMEBREW, find(port, homebrew).prefix
  end

  def test_gcc_and_binutils_may_live_in_different_directories
    gcc = installed('gcc', ["#{PORT}gcc", "#{PORT}g++"])
    binutils = installed('binutils', ["#{PORT}as"])
    assert_equal PORT, find(gcc, binutils).prefix
  end

  def test_neither_prefix_is_refused_naming_both
    error = assert_raises(Erx::Error) { find(installed('empty', [])) }
    assert_includes error.message, 'aarch64-elf-gcc, aarch64-elf-g++ and aarch64-elf-as'
    assert_includes error.message, 'aarch64-none-elf-gcc, aarch64-none-elf-g++ and aarch64-none-elf-as'
  end

  def test_a_gcc_without_its_binutils_does_not_count
    gcc_only = installed('homebrew', ["#{HOMEBREW}gcc", "#{HOMEBREW}g++"])
    assert_equal PORT, find(gcc_only, installed('port', toolchain(PORT))).prefix
    assert_raises(Erx::Error) { find(gcc_only) }
  end

  # A relative or empty PATH entry names another directory once a build
  # changes into its own, so a toolchain planted under one is never chosen.
  def test_relative_and_empty_path_entries_are_passed_over
    planted = installed('planted', toolchain(HOMEBREW))
    port = installed('port', toolchain(PORT))
    Dir.chdir(@directory) { assert_equal PORT, find('planted', port).prefix }
    Dir.chdir(planted) { assert_equal PORT, find('', port).prefix }
  end

  def test_a_toolchain_has_only_a_known_prefix
    assert_raises(Erx::Error) { Erx::CrossToolchain::Toolchain.new(prefix: 'x86_64-elf-') }
  end

  def test_a_directory_or_unexecutable_file_is_no_program
    directory = installed('fake', [])
    FileUtils.mkdir_p(File.join(directory, "#{HOMEBREW}gcc"))
    File.write(File.join(directory, "#{HOMEBREW}as"), "#!/bin/sh\n")
    assert_raises(Erx::Error) { find(directory) }
  end
end
