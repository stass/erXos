# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/l4re_build'

# `tools/erx build l4re` (docs/design-bench.md, "L4Re's guest"): the plan of docker
# commands that builds L4Re's guest in the oracle's container, the kernel configuration
# it is given, and the checks on what it copies out. The container itself runs only in
# the comparison session's build.
class L4ReBuildTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def plan
    Erx::L4ReBuild.plan(context: 'ctx', name: 'erx-l4re-build-1', image: 'example.org/image@sha256:' + 'a' * 64,
                        inputs: '/w/inputs', out: '/w/out', jobs: 8,
                        trees: Erx::L4ReFetch::LAYOUT.values.reverse.to_h { |path| [path, "/trees/#{path}"] })
  end

  # The container is offline, unprivileged and non-root, and runs the pinned image as it
  # is cached: what keeps L4Re's fetched code from the network and the engine's host.
  def test_the_container_is_created_offline_without_capabilities_as_a_non_root_user
    create = plan.first
    assert_equal %w[docker --context ctx create], create.first(4)
    {
      '--network' => 'none', '--cap-drop' => 'ALL', '--security-opt' => 'no-new-privileges',
      '--user' => '1000:1000', '--pull' => 'never', '--platform' => 'linux/arm64'
    }.each { |flag, value| assert_equal value, create[create.index(flag) + 1], flag }
    refute create.any? { |argument| argument.start_with?('--mount', '--volume', '-v', '--privileged') }
    assert_equal ['example.org/image@sha256:' + 'a' * 64, '-k', '10'], create[create.index('/usr/bin/timeout') + 1, 3]
    assert_equal ['/bin/sh', '/tmp/inputs/build.sh', '8'], create.last(3)
  end

  # docker cp creates only the last component of its destination, so mk, which holds
  # pkg, lands before every package, and the outputs come back after the attached run.
  def test_inputs_and_trees_are_copied_in_parents_first_and_the_outputs_copied_out_last
    steps = plan
    copies = steps.select { |argv| argv[3] == 'cp' }.map(&:last)
    assert_equal 'erx-l4re-build-1:/tmp/inputs', copies.first
    assert_operator copies.index('erx-l4re-build-1:/tmp/l4'), :<, copies.index('erx-l4re-build-1:/tmp/l4/pkg/ipcbench')
    assert_equal Erx::L4ReFetch::LAYOUT.size + 2, copies.size
    assert_equal %w[docker --context ctx start --attach erx-l4re-build-1], steps[-2]
    assert_equal %w[docker --context ctx cp erx-l4re-build-1:/tmp/out /w/out], steps.last
  end

  def test_only_the_compiler_lines_of_the_kernel_defconfig_change
    text = File.read(File.join(ROOT, Erx::L4ReBuild::KERNEL_DEFCONFIG))
    built = Erx::L4ReBuild.kernel_defconfig(text)
    changed = built.lines - text.lines
    assert_equal ["CONFIG_CC=\"gcc\"\n", "CONFIG_CXX=\"g++\"\n", "CONFIG_LD=\"ld\"\n"], changed
    assert_equal text.lines.size, built.lines.size
  end

  # A defconfig that drops or repeats a compiler line would build with a compiler the
  # record does not name.
  def test_a_defconfig_without_exactly_one_line_per_compiler_is_refused
    assert_match(/CONFIG_LD 0 times/, assert_raises(Erx::Error) { Erx::L4ReBuild.kernel_defconfig("CONFIG_CC=\"a\"\nCONFIG_CXX=\"b\"\n") }.message)
    twice = "CONFIG_CC=\"a\"\nCONFIG_CC=\"a\"\nCONFIG_CXX=\"b\"\nCONFIG_LD=\"c\"\n"
    assert_match(/CONFIG_CC 2 times/, assert_raises(Erx::Error) { Erx::L4ReBuild.kernel_defconfig(twice) }.message)
  end

  # The record's difference says which of erXos's settings upstream Fiasco did not keep.
  def test_the_difference_lists_each_setting_the_resolved_configuration_does_not_keep
    defconfig = "CONFIG_A=y\n# CONFIG_B is not set\nCONFIG_C=\"x\"\nCONFIG_D=y\n"
    resolved = "CONFIG_A=y\nCONFIG_B=y\nCONFIG_C=\"x\"\nCONFIG_E=y\n"
    assert_equal ['CONFIG_B: defconfig n, resolved y', 'CONFIG_D: defconfig y, resolved n'],
                 Erx::L4ReBuild.difference(defconfig: defconfig, resolved: resolved)
    assert_empty Erx::L4ReBuild.difference(defconfig: defconfig.sub("CONFIG_D=y\n", ''), resolved: resolved.sub('B=y', 'B=n'))
  end

  # What the container copies out is untrusted: exactly the expected regular files.
  def test_outputs_other_than_the_expected_regular_files_are_refused
    Dir.mktmpdir('erx-l4re-build-') do |out|
      Erx::L4ReBuild::OUTPUTS.each_key { |name| File.write(File.join(out, name), "#{name}\n") }
      Erx::L4ReBuild.check_outputs(out)
      File.write(File.join(out, 'extra'), '')
      assert_match(/exported .*extra/, assert_raises(Erx::Error) { Erx::L4ReBuild.check_outputs(out) }.message)
      File.delete(File.join(out, 'extra'))
      File.delete(File.join(out, 'compiler'))
      File.symlink('/etc/hosts', File.join(out, 'compiler'))
      assert_match(/compiler as other than a regular file/, assert_raises(Erx::Error) { Erx::L4ReBuild.check_outputs(out) }.message)
      File.delete(File.join(out, 'compiler'))
      File.write(File.join(out, 'compiler'), 'x' * (Erx::L4ReBuild::OUTPUTS.fetch('compiler') + 1))
      assert_raises(Erx::Error) { Erx::L4ReBuild.check_outputs(out) }
    end
  end

  # The record names every pin and the ELF by its hash, as L4ReBench::Build reads it back.
  def test_the_record_names_the_pins_the_compiler_and_the_elf_it_describes
    Dir.mktmpdir('erx-l4re-build-') do |out|
      File.write(File.join(out, 'globalconfig.out'), "CONFIG_A=y\n")
      File.write(File.join(out, 'l4re.kconfig'), "CONFIG_BUILD_ARCH_arm64=y\n")
      File.write(File.join(out, 'compiler'), "gcc (Debian 12.2.0-14+deb12u1) 12.2.0\nCopyright\n")
      File.write(File.join(out, 'bootstrap.elf'), "\x7FELF")
      sources = [{ 'id' => 'l4re-mk', 'kind' => 'git', 'commit' => 'c' * 40 },
                 { 'id' => 'l4re-tool-flex', 'kind' => 'file', 'sha256' => 'f' * 64 }]
      record = Erx::L4ReBuild.record(sources: sources, image: 'i', out: out, defconfig: "CONFIG_A=y\n# CONFIG_B is not set\n")
      assert_equal({ 'l4re-mk' => 'c' * 40, 'l4re-tool-flex' => 'f' * 64 }, record.fetch('sources'))
      assert_equal 'gcc (Debian 12.2.0-14+deb12u1) 12.2.0', record.fetch('compiler')
      assert_empty record.fetch('fiasco_config_difference')
      assert_equal Digest::SHA256.hexdigest("\x7FELF"), record.fetch('bootstrap_sha256')
      File.write(File.join(out, 'build-record.json'), JSON.generate(record))
      assert_equal record, Erx::L4ReBench::Build.new(directory: out).record
      # A control sequence in an output would reach the record and the terminal.
      File.write(File.join(out, 'compiler'), "gcc \e]0;x\a\n")
      assert_match(/compiler with bytes other than printable ASCII/,
                   assert_raises(Erx::Error) { Erx::L4ReBuild.record(sources: sources, image: 'i', out: out, defconfig: '') }.message)
    end
  end
end
