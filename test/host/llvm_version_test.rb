# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/llvm_version'

# Erx::LlvmVersion (tools/lib/erx/llvm_version.rb): a development build takes
# any LLVM from the minimum on and names the version it ran; only release
# images need the exact release version.
class LlvmVersionTest < Minitest::Test
  def clang(version) = "Homebrew clang version #{version}\n"
  def lld(version) = "Homebrew LLD #{version} (compatible with GNU linkers)\n"

  def test_parse_takes_the_digits_of_each_vendor_line
    assert_equal '23.1.2', Erx::LlvmVersion.parse(tool: 'clang', first_line: clang('23.1.2'))
    assert_equal '23.1.4', Erx::LlvmVersion.parse(tool: 'lld', first_line: lld('23.1.4'))
    assert_equal '23.1.3', Erx::LlvmVersion.parse(tool: 'clang', first_line: "clang version 23.1.3\n")
    assert_equal '24.1.0', Erx::LlvmVersion.parse(tool: 'clang', first_line: 'Ubuntu clang version 24.1.0 (1ubuntu1)')
    assert_equal '23.1.3', Erx::LlvmVersion.parse(tool: 'lld', first_line: 'Debian LLD 23.1.3 (compatible with GNU linkers)')
  end

  def test_parse_refuses_what_is_not_an_llvm_release_line
    ['Apple clang version 23.1.3 (clang-2300.0.1)', 'clang version 23.1', '', "clang version 23.1.3x\n",
     "clang version 23.1.3\e]8;;x\a", 'gcc (Homebrew GCC 16.2.0) 16.2.0', 'clang version 12345.1.3',
     "junk\nclang version 23.1.3", 'Vendor With Spaces clang version 23.1.3'].each do |line|
      error = assert_raises(Erx::Error) { Erx::LlvmVersion.parse(tool: 'clang', first_line: line) }
      assert_equal 'clang --version does not name an LLVM release', error.message
    end
    assert_raises(Erx::Error) { Erx::LlvmVersion.parse(tool: 'gcc', first_line: clang('23.1.3')) }
  end

  def test_the_release_version_builds_without_a_note
    assert_nil Erx::LlvmVersion.admit(tool: 'clang', version: Erx::LlvmVersion::RELEASE)
  end

  def test_another_patch_release_builds_and_is_named
    assert_equal 'note: building with clang 23.1.2; release images are built with LLVM 23.1.3',
                 Erx::LlvmVersion.admit(tool: 'clang', version: '23.1.2')
    assert_equal 'note: building with lld 23.1.0; release images are built with LLVM 23.1.3',
                 Erx::LlvmVersion.admit(tool: 'lld', version: '23.1.0')
  end

  def test_a_newer_release_builds_with_an_untested_note
    %w[23.2.0 24.1.0 30.0.1].each do |version|
      assert_equal "note: building with clang #{version}, newer than the LLVM 23.1 series the tree is tested with; " \
                   'release images are built with LLVM 23.1.3',
                   Erx::LlvmVersion.admit(tool: 'clang', version: version)
    end
  end

  def test_an_older_release_is_refused_naming_the_minimum
    %w[22.1.3 22.9.0 23.0.9 18.1.8].each do |version|
      error = assert_raises(Erx::Error) { Erx::LlvmVersion.admit(tool: 'lld', version: version) }
      assert_equal "lld #{version} is older than LLVM 23.1.0, the oldest a build takes", error.message
    end
  end

  # What a build record names is what --version of each program it ran says.
  def test_toolchain_names_the_versions_the_programs_report
    Dir.mktmpdir('erx-llvm-version-') do |directory|
      lines = { 'probe-clang-version' => clang('23.1.2'), 'probe-lld-version' => lld('23.1.4') }
      seen = []
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, name:, **|
        seen << argv
        path = File.join(directory, name)
        File.write(path, lines.fetch(name))
        { 'state' => 'succeeded', 'log' => path }
      end
      toolchain = Erx::LlvmVersion.toolchain(compiler: '/llvm/clang', linker: '/llvm/ld.lld', runner: runner, name: 'probe')
      assert_equal({ 'clang' => '23.1.2', 'lld' => '23.1.4' }, toolchain)
      assert toolchain.frozen?
      assert_equal [['/llvm/clang', '--version'], ['/llvm/ld.lld', '--version']], seen
    end
  end
end
