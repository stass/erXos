# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/l4re_build'

# `tools/erx build l4re` (docs/design-bench.md, "L4Re's guest"): the plan of docker
# commands that builds L4Re's guest in the oracle's container, the kernel configuration
# it is given, and the checks on the engine, the container and what it exports. The container itself runs only in
# the comparison session's build.
class L4ReBuildTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  ENDPOINT = 'unix:///run/engine.sock'

  def plan
    Erx::L4ReBuild.plan(endpoint: ENDPOINT, name: 'erx-l4re-build-1', image: 'example.org/image@sha256:' + 'a' * 64,
                        inputs: '/w/inputs', archive: '/w/out.tar', jobs: 8,
                        trees: Erx::L4ReFetch::LAYOUT.values.reverse.to_h { |path| [path, "/trees/#{path}"] })
  end

  # The container is created with the oracle's confinement flags, as the non-root user,
  # swap bounded by memory, and the script under env -i: what keeps L4Re's fetched code
  # from the network, the engine's host and the operator's environment.
  def test_the_container_is_created_with_the_oracles_confinement_as_a_non_root_user
    create = plan.fetch(:create).argv
    assert_equal ['docker', '--host', ENDPOINT, 'create'], create.first(4)
    confinement = Erx::OracleContainer::CONFINEMENT
    assert_equal confinement, create[create.index('--network'), confinement.size]
    {
      '--user' => '1000:1000', '--pull' => 'never', '--platform' => 'linux/arm64', '--memory' => '16g',
      '--memory-swap' => '16g', '--entrypoint' => '/usr/bin/env'
    }.each { |flag, value| assert_equal value, create[create.index(flag) + 1], flag }
    refute create.any? { |argument| argument.start_with?('--mount', '--volume', '-v', '--privileged', '--env') }
    image = create.index('example.org/image@sha256:' + 'a' * 64)
    assert_equal ['-i', *Erx::L4ReBuild::ENVIRONMENT, '/usr/bin/timeout', '-k', '10'], create[image + 1, Erx::L4ReBuild::ENVIRONMENT.size + 4]
    assert_equal ['/bin/sh', '/tmp/inputs/build.sh', '8'], create.last(3)
  end

  # docker cp creates only the last component of its destination, so mk, which holds
  # pkg, lands before every package. The attached run's log and the streamed archive of
  # /tmp/out are bounded as they are written, before anything of them reaches the host.
  def test_trees_are_copied_in_parents_first_and_the_run_and_the_outputs_are_bounded
    steps = plan
    copies = steps.fetch(:copies).map { |step| step.argv.last }
    assert_equal 'erx-l4re-build-1:/tmp/inputs', copies.first
    assert_operator copies.index('erx-l4re-build-1:/tmp/l4'), :<, copies.index('erx-l4re-build-1:/tmp/l4/pkg/ipcbench')
    assert_equal Erx::L4ReFetch::LAYOUT.size + 1, copies.size
    start = steps.fetch(:start)
    assert_equal ['docker', '--host', ENDPOINT, 'start', '--attach', 'erx-l4re-build-1'], start.argv
    assert_equal Erx::L4ReBuild::RUN_LOG_BYTES, start.limit
    export = steps.fetch(:export)
    assert_equal ['docker', '--host', ENDPOINT, 'cp', 'erx-l4re-build-1:/tmp/out', '-'], export.argv
    assert_equal [Erx::L4ReBuild::ARCHIVE_BYTES, '/w/out.tar'], [export.limit, export.stdout]
    assert_operator Erx::L4ReBuild::ARCHIVE_BYTES, :>, Erx::L4ReBuild::OUTPUTS.values.sum
  end

  # A context whose endpoint is not a local UNIX socket is refused before anything is
  # fetched or created: the endpoint names the engine every later command reaches.
  def test_a_context_whose_endpoint_is_not_a_local_unix_socket_is_refused_before_anything_runs
    Dir.mktmpdir('erx-l4re-build-') do |logs|
      seen = []
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, name:, **|
        seen << argv
        log = File.join(logs, name)
        File.write(log, argv.include?('inspect') ? "tcp://engine.example:2376\n" : "ctx\n")
        { 'log' => log }
      end
      error = assert_raises(Erx::Error) { Erx::L4ReBuild.build(root: ROOT, runner: runner, context: 'ctx', jobs: 2) }
      assert_match(/ctx is not an explicit local UNIX socket endpoint/, error.message)
      assert_equal [%w[docker context inspect ctx]], seen.map { |argv| argv.first(4) }
    end
  end

  # The engine's own view of the container: a dropped flag or an added mount is refused.
  def test_a_container_the_engine_holds_other_than_as_created_is_refused
    held = { 'HostConfig' => { 'NetworkMode' => 'none', 'Init' => true, 'Privileged' => false, 'CapDrop' => ['ALL'],
                               'CapAdd' => nil, 'SecurityOpt' => ['no-new-privileges'], 'Binds' => nil },
             'Config' => { 'User' => '1000:1000' }, 'Mounts' => [] }
    Erx::L4ReBuild.check_container(held)
    [held.merge('Mounts' => [{ 'Type' => 'bind' }]),
     held.merge('HostConfig' => held.fetch('HostConfig').merge('NetworkMode' => 'bridge')),
     held.merge('HostConfig' => held.fetch('HostConfig').merge('CapAdd' => ['SYS_ADMIN'])),
     held.merge('Config' => { 'User' => '' }), []].each do |value|
      assert_raises(Erx::Error) { Erx::L4ReBuild.check_container(value) }
    end
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

  # The archive docker cp streams of /tmp/out, written as the test's tar.
  def archive(path, entries)
    File.open(path, 'wb') do |io|
      Gem::Package::TarWriter.new(io) do |tar|
        tar.mkdir('out', 0o755)
        entries.each { |name, body| body == :link ? tar.add_symlink("out/#{name}", '/etc/hosts', 0o777) : tar.add_file_simple("out/#{name}", 0o644, body.bytesize) { |file| file.write(body) } }
      end
    end
  end

  # What the container exports is untrusted: exactly the expected regular files, each
  # within its bound, are written, and anything else refuses the whole archive.
  def test_an_archive_other_than_the_expected_regular_files_is_refused
    Dir.mktmpdir('erx-l4re-build-') do |work|
      expected = Erx::L4ReBuild::OUTPUTS.keys.to_h { |name| [name, "#{name}\n"] }
      archive(File.join(work, 'good.tar'), expected)
      Erx::L4ReBuild.unpack(archive: File.join(work, 'good.tar'), out: File.join(work, 'good'))
      assert_equal expected, expected.keys.to_h { |name| [name, File.read(File.join(work, 'good', name))] }
      {
        'extra' => expected.merge('extra' => ''),
        'link' => expected.merge('compiler' => :link),
        'oversized' => expected.merge('compiler' => 'x' * (Erx::L4ReBuild::OUTPUTS.fetch('compiler') + 1)),
        'missing' => expected.except('compiler')
      }.each do |label, entries|
        archive(File.join(work, "#{label}.tar"), entries)
        assert_raises(Erx::Error, label) { Erx::L4ReBuild.unpack(archive: File.join(work, "#{label}.tar"), out: File.join(work, label)) }
      end
      File.write(File.join(work, 'text.tar'), 'not a tar' * 100)
      assert_raises(Erx::Error) { Erx::L4ReBuild.unpack(archive: File.join(work, 'text.tar'), out: File.join(work, 'text')) }
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
