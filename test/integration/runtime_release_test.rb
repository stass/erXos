# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/native_runtime'
require_relative '../../tools/lib/erx/production_image'
require_relative '../../tools/lib/erx/release'

# The release as tools/erx build runtime packed it (docs/design-stopgap.md, "The archive
# has a root that never runs"). A second pack through the same steps gives the same bytes,
# and two archives holding the same release compare equal over their release files, the
# root, the manifest and the notices excepted. So do the hosted archive and the production
# image's, when both were built from the same sources.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime.
class RuntimeReleaseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)

  class << self
    attr_accessor :second
  end

  def setup
    Erx::Runtime.check_current(root: ROOT)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    path = File.join(File.dirname(OUTPUT.archive), 'second.pack')
    self.class.second ||= begin
      Erx::Release.new(root: ROOT, output: OUTPUT).build(output: path)
      path
    end
    @table = Erx::Release.file_table(archive: OUTPUT.archive, codec: @codec)
  end

  Minitest.after_run { FileUtils.rm_f(second) if second }

  def test_the_release_holds_its_applications_and_its_boot_script
    paths = @table.map(&:first)
    assert_includes paths, 'system/bin/start.boot'
    %w[kernel/ebin/kernel.app kernel/ebin/code_server.beam stdlib/ebin/stdlib.app stdlib/ebin/lists.beam
       erx/ebin/erx.app erx/ebin/erx_console.beam erx_files/ebin/erx_files.app erx_uart/ebin/erx_pl011.beam
       erx_blk/ebin/erx_blk.app erx_blk/ebin/erx_blk_write.beam compiler/ebin/compile.beam
       runtime_tools/ebin/dbg.beam].each do |file|
      application, rest = file.split('/', 2)
      assert(paths.any? { |path| path.match?(%r{\Asystem/lib/#{application}-[0-9.]+/#{Regexp.escape(rest)}\z}) }, file)
    end
    shipped = paths.filter_map { |path| path[%r{\Asystem/lib/([a-z_]+)-[^/]+/}, 1] }.uniq
    assert_equal %w[compiler erx erx_blk erx_files erx_hostlink erx_shell erx_uart kernel runtime_tools stdlib], shipped.sort,
                 'the release holds its applications and no more'
  end

  # Each of erXos's applications holds the modules of its sources and no other, and
  # OTP's applications hold none of erXos's.
  def test_erxos_modules_are_in_their_own_applications
    paths = @table.map(&:first)
    Erx::ErlangApps::APPLICATIONS.each do |application|
      sources = Dir.glob('src/**/*.erl', base: File.join(ROOT, Erx::ErlangApps.source(application)))
      beams = paths.filter_map { |path| path[%r{\Asystem/lib/#{application}-[^/]+/ebin/([^/]+\.beam)\z}, 1] }
      assert_equal sources.map { |source| "#{File.basename(source, '.erl')}.beam" }.sort, beams.sort, application
    end
    assert_empty paths.grep(%r{\Asystem/lib/(?:kernel|stdlib)-[^/]+/ebin/erx_}), 'OTP applications hold no erx_ module'
  end

  # Built here from the tree's sources, not the prebuilt beams otp/ tracks, and naming
  # no path of this checkout.
  def test_the_release_is_built_by_this_build_and_names_no_host_path
    bytes = File.binread(OUTPUT.archive)
    tracked = %w[kernel stdlib].flat_map { |application| Dir.glob(File.join(ROOT, 'otp/lib', application, 'ebin/*.beam')) }
    refute_empty tracked
    assert_empty tracked.select { |path| bytes.include?(File.binread(path)) }
    refute_includes bytes, ROOT.b
  end

  # What the native boot runs is what the hosted suites ran. The native build lives in
  # another gate, so an image of other sources says nothing and the run says so.
  def test_the_production_image_holds_the_same_release
    image = File.join(ROOT, 'build/production-image/boot/image.erxpack')
    sources = Erx::ProductionImage.sources_path(image)
    skip 'no production image of these sources: build one with the production_image suite' unless
      File.file?(image) && File.file?(sources) && File.read(sources) == File.read(Erx::Runtime.record_path(OUTPUT))

    assert_empty Erx::Release.differences(@table, Erx::Release.file_table(archive: image, codec: @codec))
  end

  def test_a_second_pack_is_byte_identical
    assert_equal File.binread(OUTPUT.archive), File.binread(self.class.second)
  end

  def test_the_two_archives_hold_the_same_release
    assert_empty Erx::Release.differences(@table, Erx::Release.file_table(archive: self.class.second, codec: @codec))
  end

  # The root, the manifest and the notices are left out; a file of the release never is.
  def test_the_comparison_names_a_changed_a_missing_and_an_added_file
    assert_equal %w[system/root system/manifest system/NOTICES], Erx::Release::NOT_RELEASE_FILES
    path, hash = @table.first
    changed = [[path, hash.tr('0-9', 'a')], *@table.drop(1)]
    assert_equal [path], Erx::Release.differences(@table, changed).map(&:first).uniq
    assert_equal [@table.last], Erx::Release.differences(@table, @table[0...-1])
    assert_equal [['system/added', 'ab']], Erx::Release.differences(@table, [*@table, ['system/added', 'ab']])
  end

  def test_each_file_is_read_back_by_its_index_and_the_manifest_holds_the_start
    manifest = Erx::Release.file_bytes(archive: OUTPUT.archive, path: 'system/manifest', codec: @codec)
    assert_includes manifest, "-boot\0/bin/start\0"
    assert_raises(Erx::Error) { Erx::Release.file_bytes(archive: OUTPUT.archive, path: 'system/none', codec: @codec) }
  end
end
