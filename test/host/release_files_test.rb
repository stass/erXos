# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_hosted'
require_relative '../../tools/lib/erx/release_files'

# What the system release and the oracle's hosted tree ship: each application's
# beams and resource file from its build, and its include/ headers from the tree,
# each header recorded as its own source, and no .appup, since an update replaces
# a whole slot.
class ReleaseFilesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  VERSION = '1.0'

  # Stands in for systools: writes the boot script the release names.
  class BootRunner
    def run(_argv, chdir:, **) = File.write(File.join(chdir, 'start.boot'), 'boot')
  end

  class Codec
    def member(_type, name) = name
  end

  class FakeOracle
    def erl_path(_flavour) = '/nonexistent/bin/erl'
  end

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-release-files-'))
    @otp = File.join(@scratch, 'otp')
    write(@otp, 'erts/vsn.mk', "VSN = 1.0\n")
    applications = Erx::ReleaseFiles::APPLICATIONS
    applications.each do |application|
      write(@otp, "lib/#{application}/ebin/#{application}.app", "{application,#{application},[{vsn,\"#{VERSION}\"}]}.\n")
      write(@otp, "lib/#{application}/ebin/#{application}.appup", "{\"#{VERSION}\",[],[]}.\n")
    end
    write(@otp, 'lib/runtime_tools/ebin/dbg.beam', 'beam')
  end

  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  def write(base, path, text)
    full = File.join(base, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def entries
    Erx::ReleaseFiles.new(root: ROOT, otp: @otp, directory: File.join(@scratch, 'release'), runner: BootRunner.new,
                          codec: Codec.new, oracle: FakeOracle.new).entries
  end

  def reference(path) = { 'path' => path, 'sha256' => Digest::SHA256.file(File.join(ROOT, path)).hexdigest }

  # Code compiled on erXos includes stdlib's headers through include_lib, as on stock.
  def test_the_release_ships_stdlibs_headers_each_its_own_source
    entry = entries.find { |candidate| candidate.fetch('path') == "system/lib/stdlib-#{VERSION}/include/qlc.hrl" }
    refute_nil entry, 'the release ships no stdlib/include/qlc.hrl'
    header = 'otp/lib/stdlib/include/qlc.hrl'
    assert_equal File.join(ROOT, header), entry.fetch('artifact')
    receipt = JSON.parse(File.read(entry.fetch('receipt')))
    assert_equal({ 'version' => 1, 'kind' => 'compiled', 'artifact' => reference(header), 'sources' => [reference(header)] },
                 receipt)
  end

  # A generated module's receipt names the file the build compiled, in build/gen.
  def test_a_generated_modules_receipt_names_its_generated_source
    Erx::Generated.ensure(root: ROOT)
    write(@otp, 'lib/erx/ebin/erx_manifest.beam', 'beam')
    entry = entries.find { |candidate| candidate.fetch('path') == "system/lib/erx-#{VERSION}/ebin/erx_manifest.beam" }
    source = 'build/gen/erlang/apps/erx/src/generated/erx_manifest.erl'
    assert_equal [reference(source)], JSON.parse(File.read(entry.fetch('receipt'))).fetch('sources')
  end

  def test_the_release_ships_every_header_of_kernel_and_stdlib
    paths = entries.map { |entry| entry.fetch('path') }
    %w[kernel stdlib].each do |application|
      Dir.glob('*.hrl', base: File.join(ROOT, 'otp/lib', application, 'include')).each do |name|
        assert_includes paths, "system/lib/#{application}-#{VERSION}/include/#{name}"
      end
    end
  end

  # The shell on erXos has c:c and dbg, as design-runtime.md keeps compiler and
  # runtime_tools, but neither starts at boot: start type load puts each on the boot
  # script's code path and loads its .app, and starts nothing, runtime_tools'
  # ttb_autostart included.
  def test_the_release_file_loads_compiler_and_runtime_tools_and_starts_neither
    paths = entries.map { |entry| entry.fetch('path') }
    assert_includes paths, "system/lib/compiler-#{VERSION}/ebin/compiler.app"
    assert_includes paths, "system/lib/runtime_tools-#{VERSION}/ebin/dbg.beam"
    release = File.read(File.join(@scratch, 'release/start.rel'))
    %w[compiler runtime_tools].each { |application| assert_includes release, "{#{application},\"#{VERSION}\",load}" }
    [*%w[kernel stdlib], *Erx::ErlangApps::APPLICATIONS].each do |application|
      assert_includes release, "{#{application},\"#{VERSION}\"}"
    end
  end

  def test_the_release_ships_no_appup
    assert_empty(entries.map { |entry| entry.fetch('path') }.grep(/\.appup\z/))
  end

  # The hosted tree carries runtime_tools, which design-runtime.md keeps, so dbg is
  # defined there as on stock.
  def test_the_hosted_tree_ships_runtime_tools
    files = Erx::OracleHosted.application_files(root: ROOT, otp: @otp)
    assert_equal File.join(@otp, 'lib/runtime_tools/ebin/dbg.beam'), files['lib/runtime_tools/ebin/dbg.beam']
    assert_includes files.keys, 'lib/runtime_tools/ebin/runtime_tools.app'
  end

  # The oracle tests what the image ships: each application the two share is laid out
  # the same, under its own directory.
  def test_the_hosted_tree_lays_out_each_application_as_the_release_does
    release = entries.map { |entry| entry.fetch('path') }.filter_map { |path| path[%r{\Asystem/lib/stdlib-#{VERSION}/(.*)}, 1] }
    tree = Erx::OracleHosted.application_files(root: ROOT, otp: @otp).keys.filter_map { |path| path[%r{\Alib/stdlib/(.*)}, 1] }
    assert_equal release.sort, tree.sort
  end

  # A link in include/ would ship another file's bytes under the header's name.
  def test_a_linked_header_is_refused
    include = File.join(@scratch, 'root/otp/lib/stdlib/include')
    FileUtils.mkdir_p(include)
    File.write(File.join(@scratch, 'other'), 'other')
    File.symlink(File.join(@scratch, 'other'), File.join(include, 'linked.hrl'))
    error = assert_raises(Erx::Error) { Erx::ReleaseFiles.headers(root: File.join(@scratch, 'root'), application: 'stdlib') }
    assert_includes error.message, 'linked.hrl is not a plain file'
  end

  def domain_entries(release)
    Erx::ReleaseFiles.new(root: ROOT, otp: @otp, directory: File.join(@scratch, 'domain'), runner: BootRunner.new,
                          codec: Codec.new, oracle: FakeOracle.new, release: release).entries
  end

  # A domain release is laid out as the system release is, under domains/<name>/, and
  # no file of it carries the system mark, which only the system release's files carry.
  def test_a_domain_release_lies_under_its_prefix_without_the_system_mark
    files = domain_entries(Erx::ReleaseFiles.domain('base', applications: %w[stdlib kernel]))
    paths = files.map { |entry| entry.fetch('path') }
    assert_includes paths, "domains/base/lib/kernel-#{VERSION}/ebin/kernel.app"
    assert_includes paths, "domains/base/lib/stdlib-#{VERSION}/include/qlc.hrl"
    assert_includes paths, 'domains/base/bin/start.boot'
    assert(paths.all? { |path| path.start_with?('domains/base/') }, paths.join(', '))
    assert_equal [0], files.map { |entry| entry.fetch('flags') }.uniq
    assert_equal ['system'], entries.map { |entry| entry.fetch('flags') }.uniq
  end

  # Its release file carries the domain's name and its applications alone, in the
  # system release's order whatever order they were asked in.
  def test_a_domain_release_file_names_the_domain_and_only_its_applications
    domain_entries(Erx::ReleaseFiles.domain('base', applications: %w[stdlib kernel]))
    release = File.read(File.join(@scratch, 'domain/start.rel'))
    assert_equal "{release,{\"base\",\"1\"},{erts,\"#{VERSION}\"},[{kernel,\"#{VERSION}\"},{stdlib,\"#{VERSION}\"}]}.\n", release
  end

  def test_a_domain_release_name_is_one_manifest_identifier
    ['', 'Base', '../x', 'a/b', '.hidden', 'x' * 64, :base].each do |name|
      assert_raises(Erx::Error, name.inspect) { Erx::ReleaseFiles.domain(name, applications: %w[kernel stdlib]) }
    end
    assert_equal 'domains/a.b-c_1/', Erx::ReleaseFiles.domain('a.b-c_1', applications: %w[kernel stdlib]).prefix
  end

  def test_a_domain_release_boots_through_kernel_and_stdlib_and_ships_only_what_is_built
    error = assert_raises(Erx::Error) { Erx::ReleaseFiles.domain('base', applications: %w[kernel]) }
    assert_includes error.message, 'stdlib'
    error = assert_raises(Erx::Error) { Erx::ReleaseFiles.domain('base', applications: %w[kernel stdlib mnesia]) }
    assert_includes error.message, 'mnesia'
  end

  # In an archive's sorted index each domain release is one run of whole entries,
  # between boot/'s files and the system release, which it does not split.
  def test_each_domain_release_is_one_run_of_the_sorted_index
    paths = ['boot/kernel', 'boot/sigma0', 'domains/a/bin/start.boot', 'domains/a/lib/x', 'domains/b/bin/start.boot',
             'runtimes/emu', 'system/bin/start.boot', 'system/root']
    assert_equal({ 'a' => { 'kind' => 'release', 'entry' => 2, 'files' => 2 },
                   'b' => { 'kind' => 'release', 'entry' => 4, 'files' => 1 } }, Erx::ReleaseFiles.domain_runs(paths))
    assert_empty Erx::ReleaseFiles.domain_runs(['boot/kernel', 'system/root'])
  end

  def test_a_domain_run_out_of_order_or_without_a_directory_is_refused
    assert_raises(Erx::Error) { Erx::ReleaseFiles.domain_runs(['domains/a/y', 'domains/a/x']) }
    assert_raises(Erx::Error) { Erx::ReleaseFiles.domain_runs(['domains/a/x', 'domains/a/x']) }
    error = assert_raises(Erx::Error) { Erx::ReleaseFiles.domain_runs(['domains/a', 'system/root']) }
    assert_includes error.message, 'not a release directory'
  end

  def test_the_hosted_tree_ships_headers_from_the_tree_and_no_appup
    files = Erx::OracleHosted.application_files(root: ROOT, otp: @otp)
    assert_equal File.join(ROOT, 'otp/lib/stdlib/include/qlc.hrl'), files['lib/stdlib/include/qlc.hrl']
    assert_empty files.keys.grep(/\.appup\z/)
  end
end
