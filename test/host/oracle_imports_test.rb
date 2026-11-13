# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rubygems/package'
require 'stringio'
require 'zlib'
require_relative '../../tools/import_origins'

class OracleImportsTest < Minitest::Test
  def fixture_import(project, bad_notice:, extra: {})
    FileUtils.mkdir_p(File.join(project, 'config/imports'))
    FileUtils.copy_file(File.expand_path('../../config/imports/otp.json', __dir__), File.join(project, 'config/imports/otp.json'))
    original = File.join(project, 'original/otp_src_29.1.2')
    FileUtils.mkdir_p(File.join(original, 'lib/kernel'))
    FileUtils.mkdir_p(File.join(original, 'lib/megaco'))
    File.write(File.join(original, 'lib/kernel/keep.erl'), bad_notice ? "%% SPDX-License-Identifier: NOASSERTION\n" : "%% SPDX-License-Identifier: Apache-2.0\n")
    File.write(File.join(original, 'lib/megaco/not-selected'), 'original')
    extra.each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(original, path)))
      File.write(File.join(original, path), bytes)
    end
    FileUtils.copy_entry(original, File.join(project, 'otp'))
    stream = StringIO.new(''.b)
    Gem::Package::TarWriter.new(stream) do |tar|
      Dir.glob(File.join(original, '**/*')).each do |path|
        relative = 'otp_src_29.1.2/' + path.delete_prefix(original + '/')
        if File.directory?(path)
          tar.mkdir(relative, 0o755)
        else
          bytes = File.binread(path)
          tar.add_file_simple(relative, 0o644, bytes.bytesize) { |file| file.write(bytes) }
        end
      end
    end
    compressed = StringIO.new(''.b)
    writer = Zlib::GzipWriter.new(compressed)
    writer.write(stream.string)
    writer.close
    hash = Digest::SHA256.hexdigest(compressed.string)
    lock = JSON.parse(File.read(File.expand_path('../../deps.lock', __dir__)))
    declaration = lock.fetch('sources').find { |source| source.fetch('id') == 'otp' }
    declaration['sha256'] = hash
    lock['sources'] = [declaration]
    File.write(File.join(project, 'deps.lock'), JSON.generate(lock))
    FileUtils.mkdir_p(File.join(project, 'build/downloads'))
    File.binwrite(File.join(project, 'build/downloads', "otp-#{hash}.tar.gz"), compressed.string)
  end

  def test_nested_vendor_file_keeps_reviewed_license
    profile = JSON.parse(File.read(File.expand_path('../../config/imports/otp.json', __dir__)))
    attribution = Erx::Attribution.for_file('lib/stdlib/test/re_SUITE_data/old_pcre1/testoutput1',
                                           bytes: 'fixture without a header', sidecar: nil, review: profile)
    assert_equal 'BSD-3-Clause', attribution.fetch('license')
  end

  # A re-import applies the profile's exclusions, so every exclusion otp/ORIGIN.md
  # records is one of them, or an application outside the profile's set, which the
  # import prunes on its own; otherwise a re-import would bring back the prebuilt
  # beams and boot scripts and record them as imported.
  def test_the_import_profile_excludes_what_the_origin_record_excludes
    profile = JSON.parse(File.read(File.expand_path('../../config/imports/otp.json', __dir__)))
    recorded = Erx::Origin.new(root: File.expand_path('../../otp', __dir__)).inventory.fetch('exclusions')
                          .map { |exclusion| exclusion.fetch('path') }
    pruned = recorded.select do |path|
      path.match?(%r{\Alib/[^/]+\z}) && !profile.fetch('applications').include?(File.basename(path))
    end
    assert_empty recorded - pruned - profile.fetch('exclusions').map { |exclusion| exclusion.fetch('path') }
    assert_includes recorded, 'erts/ebin'
  end

  # An excluded directory leaves the import whole, as an excluded file does.
  def test_an_excluded_directory_leaves_the_import
    Dir.mktmpdir('erx-otp-excluded-') do |project|
      fixture_import(project, bad_notice: false, extra: { 'erts/ebin/prim_file.beam' => 'prebuilt' })
      Erx::ImportOrigins.write(root: project, component: 'otp')
      refute File.exist?(File.join(project, 'otp/erts/ebin'))
      excluded = Erx::Origin.new(root: File.join(project, 'otp')).inventory.fetch('exclusions')
      assert_includes excluded.map { |exclusion| exclusion.fetch('path') }, 'erts/ebin'
    end
  end

  # An exclusion is removed at the path it names, never through a link in the
  # archive to another place, nor outside the tree.
  def test_an_exclusion_through_a_link_is_refused
    Dir.mktmpdir('erx-otp-exclusion-link-') do |root|
      FileUtils.mkdir_p(File.join(root, 'lib/kernel/ebin'))
      File.symlink('lib/kernel', File.join(root, 'erts'))
      error = assert_raises(Erx::Error) { Erx::ImportOrigins.send(:remove_exclusion, root, 'erts/ebin') }
      assert_match(/passes through a link/, error.message)
      assert File.directory?(File.join(root, 'lib/kernel/ebin'))
      assert_raises(Erx::Error) { Erx::ImportOrigins.send(:remove_exclusion, root, '../outside') }
      Erx::ImportOrigins.send(:remove_exclusion, root, 'absent/ebin')
    end
  end

  def test_mixed_musl_grants_are_recorded_together
    Dir.mktmpdir('erx-musl-review-') do |root|
      FileUtils.mkdir_p(File.join(root, 'src/math'))
      bytes = "/* software is freely granted, provided that this notice is preserved. */\n" \
              "/* purpose with or without fee is hereby granted */\n"
      File.write(File.join(root, 'src/math/mixed.c'), bytes)
      rule = Erx::ImportOrigins.musl_license_rules(root).find { |entry| entry.fetch('pattern') == 'src/math/mixed.c' }
      assert_equal 'SunPro AND ISC', rule.fetch('license')
    end
  end

  def test_target_application_selection_preserves_only_the_declared_set
    Dir.mktmpdir('erx-otp-selection-') do |root|
      %w[kernel stdlib megaco].each { |name| FileUtils.mkdir_p(File.join(root, 'lib', name)) }
      excluded = Erx::ImportOrigins.select_otp_applications(root, applications: %w[kernel stdlib])
      assert_equal %w[kernel stdlib], Dir.children(File.join(root, 'lib')).sort
      assert_equal ['lib/megaco'], excluded.map { |entry| entry.fetch('path') }
    end
  end

  def test_attribution_failure_does_not_prune_existing_import
    Dir.mktmpdir('erx-otp-atomic-') do |project|
      fixture_import(project, bad_notice: true)
      assert_raises(Erx::Error) { Erx::ImportOrigins.write(root: project, component: 'otp') }
      assert File.file?(File.join(project, 'otp/lib/megaco/not-selected'))
      refute File.exist?(File.join(project, 'otp/ORIGIN.md'))
    end
  end

  def test_missing_required_source_is_refused
    Dir.mktmpdir('erx-otp-missing-') do |project|
      fixture_import(project, bad_notice: false)
      File.unlink(File.join(project, 'otp/lib/kernel/keep.erl'))
      assert_raises(Erx::Error) { Erx::ImportOrigins.write(root: project, component: 'otp') }
      refute File.exist?(File.join(project, 'otp/ORIGIN.md'))
    end
  end
end
