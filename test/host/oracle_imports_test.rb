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

  # otp/ORIGIN.md records what a re-import with the profile would exclude, each path
  # for the profile's reason and in the order the import records them: the import's
  # exclusions, run over a tree that holds every recorded path and every name an
  # exclusion keeps, record the same. Otherwise a re-import would bring back the
  # prebuilt beams, boot scripts and ASN.1 compiler and record them as imported.
  def test_the_import_profile_excludes_what_the_origin_record_excludes
    profile = JSON.parse(File.read(File.expand_path('../../config/imports/otp.json', __dir__)))
    recorded = Erx::Origin.new(root: File.expand_path('../../otp', __dir__)).inventory.fetch('exclusions')
    kept = profile.fetch('exclusions').flat_map do |exclusion|
      exclusion.fetch('keep', []).map { |name| "#{exclusion.fetch('path')}/#{name}" }
    end
    Dir.mktmpdir('erx-otp-replay-') do |root|
      [*recorded.map { |exclusion| exclusion.fetch('path') }, *kept].each do |relative|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        # The import prunes an application outside the profile's set only as a directory.
        relative.match?(%r{\Alib/[^/]+\z}) ? FileUtils.mkdir_p(path) : File.write(path, '')
      end
      assert_equal recorded, Erx::ImportOrigins.remove_exclusions(root, profile: profile, component: 'otp')
    end
    assert_includes recorded.map { |exclusion| exclusion.fetch('path') }, 'erts/ebin'
  end

  # The exclusions below are tried alone, without OTP's pruning of applications,
  # which remove_exclusions applies to the otp component only.
  def exclude(root, path:, **keep)
    profile = { 'exclusions' => [{ 'path' => path, **keep.transform_keys(&:to_s), 'reason' => 'the compiler' }] }
    Erx::ImportOrigins.remove_exclusions(root, profile: profile, component: 'openssl')
  end

  # An exclusion with keep takes each entry of its directory but those it names,
  # and the origin record lists each one that went.
  def test_an_exclusion_keeps_the_entries_it_names
    Dir.mktmpdir('erx-otp-keep-') do |root|
      FileUtils.mkdir_p(File.join(root, 'lib/asn1/src/deps'))
      %w[Makefile asn1rt_nif.erl asn1ct.erl].each { |name| File.write(File.join(root, 'lib/asn1/src', name), '') }
      assert_equal [{ 'path' => 'lib/asn1/src/asn1ct.erl', 'reason' => 'the compiler' },
                    { 'path' => 'lib/asn1/src/deps', 'reason' => 'the compiler' }],
                   exclude(root, path: 'lib/asn1/src', keep: %w[Makefile asn1rt_nif.erl])
      assert_equal %w[Makefile asn1rt_nif.erl], Dir.children(File.join(root, 'lib/asn1/src')).sort
    end
  end

  # A misspelt keep name or directory would bring back what the exclusion removes, so
  # the import refuses both; an exclusion under an application the archive lacks, or
  # the import pruned, records nothing.
  def test_an_exclusion_keeps_only_what_the_archive_holds
    Dir.mktmpdir('erx-otp-keep-missing-') do |root|
      FileUtils.mkdir_p(File.join(root, 'lib/asn1/src'))
      File.write(File.join(root, 'lib/asn1/src/Makefile'), '')
      error = assert_raises(Erx::Error) { exclude(root, path: 'lib/asn1/src', keep: %w[Makefile asn1rt_nif.erl]) }
      assert_match(/keeps asn1rt_nif.erl, which the archive lacks/, error.message)
      assert_raises(Erx::Error) { exclude(root, path: 'lib/asn1/scr', keep: %w[Makefile]) }
      assert_raises(Erx::Error) { exclude(root, path: 'lib/asn1', keep: %w[src/Makefile]) }
      assert_empty exclude(root, path: 'lib/megaco/src', keep: %w[Makefile])
      assert File.file?(File.join(root, 'lib/asn1/src/Makefile'))
    end
  end

  # An exclusion with keep takes the entries of a directory of the archive, never of
  # one a link in it names.
  def test_an_exclusion_keeps_nothing_through_a_link
    Dir.mktmpdir('erx-otp-keep-link-') do |root|
      FileUtils.mkdir_p(File.join(root, 'lib/empty'))
      File.symlink('empty', File.join(root, 'lib/link'))
      error = assert_raises(Erx::Error) { exclude(root, path: 'lib/link', keep: []) }
      assert_match(/something other than a directory of the archive/, error.message)
    end
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
      error = assert_raises(Erx::Error) { exclude(root, path: 'erts/ebin') }
      assert_match(/passes through a link/, error.message)
      assert File.directory?(File.join(root, 'lib/kernel/ebin'))
      assert_raises(Erx::Error) { exclude(root, path: '../outside') }
      exclude(root, path: 'absent/ebin')
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
