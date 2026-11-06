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
    applications = [*Erx::ReleaseFiles::APPLICATIONS, *Erx::OracleHosted::ERXOS_APPLICATIONS].uniq
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

  def test_the_release_ships_every_header_of_kernel_and_stdlib
    paths = entries.map { |entry| entry.fetch('path') }
    %w[kernel stdlib].each do |application|
      Dir.glob('*.hrl', base: File.join(ROOT, 'otp/lib', application, 'include')).each do |name|
        assert_includes paths, "system/lib/#{application}-#{VERSION}/include/#{name}"
      end
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

  def test_the_hosted_tree_ships_headers_from_the_tree_and_no_appup
    files = Erx::OracleHosted.application_files(root: ROOT, otp: @otp)
    assert_equal File.join(ROOT, 'otp/lib/stdlib/include/qlc.hrl'), files['lib/stdlib/include/qlc.hrl']
    assert_empty files.keys.grep(/\.appup\z/)
  end
end
