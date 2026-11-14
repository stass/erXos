# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/libcrypto'

# When Libcrypto#build runs OpenSSL's Configure again: only when an input of its
# configuration changed. A runner that records the commands it is given stands in
# for Configure, make and llvm-nm, over a small tree shaped like openssl/.
class LibcryptoConfigureTest < Minitest::Test
  # Records each command's name; llvm-nm's log is a listing that keeps Imports' rules.
  class Recorder
    LISTING = <<~LISTING
      a:libcrypto-lib-armcap.o: U getauxval
      a:libdefault-lib-rand_unix.o: U getrandom
    LISTING

    attr_reader :names

    def initialize(directory)
      @names = []
      @log = File.join(directory, 'nm.log')
      File.write(@log, LISTING)
    end

    def run(_argv, name:, **)
      @names << name
      name == 'openssl-nm' ? { 'log' => @log } : {}
    end
  end

  def setup
    @root = Dir.mktmpdir('libcrypto-configure-')
    @tmpdir = ENV.fetch('TMPDIR', nil)
    @source = File.join(@root, 'openssl')
    { 'Configure' => '', 'VERSION.dat' => '', 'Configurations/10-main.conf' => '', 'crypto/build.info' => 'a',
      'util/perl/OpenSSL/Template.pm' => '', 'crypto/sha.c' => '' }.each { |path, text| write(path, text) }
    write(Erx::Libcrypto::TARGET_FILE, '', tree: :root)
    @compiler = File.join(@root, 'llvm/bin/clang')
    write('llvm/bin/clang', 'clang 1', tree: :root)
    @recorder = Recorder.new(@root)
  end

  def teardown
    ENV['TMPDIR'] = @tmpdir
    FileUtils.rm_rf(@root)
  end

  # Writes path under the root when tree is :root, else under the OpenSSL tree.
  def write(path, text, tree: :source)
    full = File.join(tree == :root ? @root : @source, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  # Builds, and returns how many times Configure ran over all builds so far.
  def build_and_count_configures
    Erx::Libcrypto.new(root: @root, runner: @recorder, compiler: @compiler, source: @source)
                  .build(directory: File.join(@root, 'obj'), sysroot: File.join(@root, 'sysroot'))
    @recorder.names.count('openssl-configure')
  end

  def test_an_unchanged_configuration_is_kept
    assert_equal 1, build_and_count_configures
    write('crypto/sha.c', 'int x;')

    assert_equal 1, build_and_count_configures
  end

  def test_a_changed_build_info_configures_again
    assert_equal 1, build_and_count_configures
    write('crypto/build.info', 'b')

    assert_equal 2, build_and_count_configures
  end

  def test_a_changed_configuration_configures_again
    assert_equal 1, build_and_count_configures
    write('Configurations/10-main.conf', 'changed')

    assert_equal 2, build_and_count_configures
  end

  def test_a_changed_perl_module_configures_again
    assert_equal 1, build_and_count_configures
    write('util/perl/OpenSSL/Template.pm', 'changed')

    assert_equal 2, build_and_count_configures
  end

  def test_a_changed_passed_variable_configures_again
    assert_equal 1, build_and_count_configures
    ENV['TMPDIR'] = File.join(@root, 'other')

    assert_equal 2, build_and_count_configures
  end

  def test_a_changed_target_file_configures_again
    assert_equal 1, build_and_count_configures
    write(Erx::Libcrypto::TARGET_FILE, 'changed', tree: :root)

    assert_equal 2, build_and_count_configures
  end

  def test_another_compiler_of_the_same_name_configures_again
    assert_equal 1, build_and_count_configures
    write('llvm/bin/clang', 'clang 2', tree: :root)

    assert_equal 2, build_and_count_configures
  end
end
