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
  APPLICATION_REASON = 'outside the shipped OTP application set in the runtime design'

  def fixture_import(project, bad_file:, extra: {})
    FileUtils.mkdir_p(File.join(project, 'config/imports'))
    FileUtils.copy_file(File.expand_path('../../config/imports/otp.json', __dir__), File.join(project, 'config/imports/otp.json'))
    original = File.join(project, 'original/otp_src_29.1.2')
    FileUtils.mkdir_p(File.join(original, 'lib/kernel'))
    FileUtils.mkdir_p(File.join(original, 'lib/megaco'))
    File.write(File.join(original, 'lib/kernel/keep.erl'), "%% SPDX-License-Identifier: Apache-2.0\n")
    # A name the inventory cannot record fails the write after the selection.
    File.write(File.join(original, "lib/kernel/bad\x01name.erl"), "%% SPDX-License-Identifier: Apache-2.0\n") if bad_file
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
                                           bytes: 'fixture without a header', sidecar: nil,
                                           review: Erx::Attribution.review(profile))
    assert_equal 'BSD-3-Clause', attribution.fetch('license')
  end

  # otp/ORIGIN.md records what a re-import with the profile would exclude, each path
  # for the profile's reason and in the order the import records them: the import's
  # exclusions, run over a tree that holds every recorded path, every name an
  # exclusion keeps and public_key's ASN.1 specifications, record the same.
  # Otherwise a re-import would bring back the prebuilt beams, boot scripts, ASN.1
  # compiler and generated ASN.1 modules and record them as imported.
  def test_the_import_profile_excludes_what_the_origin_record_excludes
    profile = JSON.parse(File.read(File.expand_path('../../config/imports/otp.json', __dir__)))
    recorded = Erx::Origin.new(root: File.expand_path('../../otp', __dir__)).inventory.fetch('exclusions')
    kept = profile.fetch('exclusions').flat_map do |exclusion|
      exclusion.fetch('keep', []).map { |name| "#{exclusion.fetch('path')}/#{name}" }
    end + profile.fetch('excluded_names').fetch('keep')
    Dir.mktmpdir('erx-otp-replay-') do |root|
      # The import prunes an application outside the profile's set only as a directory,
      # so a path recorded for that reason is one; every other is a file.
      applications = recorded.select { |exclusion| exclusion.fetch('reason') == APPLICATION_REASON }
                             .map { |exclusion| exclusion.fetch('path') }
      [*recorded.map { |exclusion| exclusion.fetch('path') }, *kept].each do |relative|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        applications.include?(relative) ? FileUtils.mkdir_p(path) : File.write(path, '')
      end
      FileUtils.cp_r(File.expand_path('../../otp/lib/public_key/asn1', __dir__), File.join(root, 'lib/public_key'))
      assert_equal recorded, Erx::ImportOrigins.remove_exclusions(root, profile: profile, component: 'otp')
    end
    assert_includes recorded.map { |exclusion| exclusion.fetch('path') }, 'erts/ebin'
  end

  # The tree holds no entry the profile's excluded names take: each of OTP's doc,
  # examples and internal_doc entries is gone but for the files the build reads.
  def test_no_excluded_name_is_left_in_the_tree_but_what_the_build_reads
    rule = JSON.parse(File.read(File.expand_path('../../config/imports/otp.json', __dir__))).fetch('excluded_names')
    otp = File.expand_path('../../otp', __dir__)
    files = Erx::Origin.new(root: otp).inventory.fetch('files').keys
    named = files.select { |path| path.split('/').any? { |part| rule.fetch('names').include?(part) } }
    assert_equal rule.fetch('keep').sort, named.sort
  end

  def exclude_names(root, keep: [])
    rule = { 'names' => %w[doc examples], 'keep' => keep, 'reason' => 'documentation' }
    Erx::ImportOrigins.remove_exclusions(root, profile: { 'exclusions' => [], 'excluded_names' => rule }, component: 'openssl')
  end

  def write_files(root, paths)
    paths.each do |relative|
      FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
      File.write(File.join(root, relative), '')
    end
  end

  # An excluded name takes its entries at any depth, files and links among them,
  # each recorded once; a directory that holds a kept file leaves but for the way
  # to it, and each entry that went is recorded.
  def test_excluded_names_leave_wherever_they_lie_but_for_what_they_keep
    Dir.mktmpdir('erx-otp-names-') do |root|
      write_files(root, %w[erts/doc/a.md erts/doc/src/b.md erts/doc/src/keep.md erts/doc/src/more/c.md
                           lib/x/examples/e.erl lib/x/src/x.erl lib/x/src/doc lib/x/docs/d.md])
      File.symlink('../doc', File.join(root, 'lib/x/doc'))
      # Directories that hold no file leave unrecorded, as the inventory lists none.
      %w[erts/doc/empty/deeper lib/y/examples].each { |directory| FileUtils.mkdir_p(File.join(root, directory)) }
      recorded = exclude_names(root, keep: %w[erts/doc/src/keep.md])
      refute File.exist?(File.join(root, 'lib/y/examples'))
      assert_equal %w[erts/doc/a.md erts/doc/src/b.md erts/doc/src/more lib/x/doc lib/x/examples lib/x/src/doc],
                   recorded.map { |exclusion| exclusion.fetch('path') }
      assert_equal ['documentation'], recorded.map { |exclusion| exclusion.fetch('reason') }.uniq
      assert_equal %w[erts/doc/src/keep.md lib/x/docs/d.md lib/x/src/x.erl],
                   Dir.glob('**/*', base: root).select { |path| File.file?(File.join(root, path)) }.sort
    end
  end

  # A kept path the archive lacks, or one no excluded name holds, is refused, so a
  # misspelt row can neither keep what it does not name nor bring documentation back.
  def test_excluded_names_keep_only_files_beneath_them
    Dir.mktmpdir('erx-otp-names-keep-') do |root|
      write_files(root, %w[erts/doc/src/keep.md lib/x/src/x.erl])
      error = assert_raises(Erx::Error) { exclude_names(root, keep: %w[erts/doc/src/kept.md]) }
      assert_match(/keep erts\/doc\/src\/kept.md, which the archive lacks/, error.message)
      error = assert_raises(Erx::Error) { exclude_names(root, keep: %w[lib/x/src/x.erl]) }
      assert_match(/beneath none of doc, examples/, error.message)
      assert_raises(Erx::Error) { exclude_names(root, keep: %w[erts/doc/src]) }
      assert File.file?(File.join(root, 'erts/doc/src/keep.md'))
      # An application the archive lacks keeps nothing and refuses nothing.
      assert_equal [{ 'path' => 'erts/doc', 'reason' => 'documentation' }], exclude_names(root, keep: %w[lib/y/doc/z.md])
    end
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
      fixture_import(project, bad_file: false, extra: { 'erts/ebin/prim_file.beam' => 'prebuilt' })
      Erx::ImportOrigins.write(root: project, component: 'otp')
      refute File.exist?(File.join(project, 'otp/erts/ebin'))
      excluded = Erx::Origin.new(root: File.join(project, 'otp')).inventory.fetch('exclusions')
      assert_includes excluded.map { |exclusion| exclusion.fetch('path') }, 'erts/ebin'
    end
  end

  # What the ASN.1 compiler wrote for each module the specifications make, a new
  # one included, leaves the import without a row in the profile: a set's module
  # goes, and a hand-written module named after one of the set's members stays.
  def test_generated_asn1_modules_leave_the_import
    notice = "%% SPDX-License-Identifier: Apache-2.0\n"
    asn1 = 'lib/public_key/asn1'
    source = 'lib/public_key/src'
    Dir.mktmpdir('erx-otp-asn1-') do |project|
      fixture_import(project, bad_file: false,
                              extra: { "#{asn1}/New-2030.asn1" => "-- SPDX-License-Identifier: Apache-2.0\n",
                                       "#{asn1}/Member.asn1" => "-- SPDX-License-Identifier: Apache-2.0\n",
                                       "#{asn1}/Frame.set.asn" => "#{notice}\nMember.asn1\n",
                                       "#{source}/New-2030.erl" => notice, "#{source}/New-2030.asn1db" => 'db',
                                       "#{source}/Frame.erl" => notice, "#{source}/Frame.hrl" => notice,
                                       "#{source}/Member.erl" => notice, "#{source}/public_key.erl" => notice })
      Erx::ImportOrigins.write(root: project, component: 'otp')
      excluded = Erx::Origin.new(root: File.join(project, 'otp')).inventory.fetch('exclusions')
                            .select { |exclusion| exclusion.fetch('path').start_with?("#{source}/") }
      assert_equal %W[#{source}/pubkey_moduli.hrl #{source}/Frame.erl #{source}/Frame.hrl #{source}/New-2030.erl
                       #{source}/New-2030.asn1db],
                   excluded.map { |exclusion| exclusion.fetch('path') }
      assert_equal %w[Member.erl public_key.erl], Dir.children(File.join(project, 'otp', source)).sort
    end
  end

  # The compiler's output is found from an asn1 directory of the archive and the plain
  # files its sets name, never through a link to other specifications, and a set that
  # names anything else fails the import with a diagnostic.
  def test_generated_asn1_modules_come_from_the_archive_s_own_specifications
    Dir.mktmpdir('erx-otp-asn1-link-') do |root|
      FileUtils.mkdir_p([File.join(root, 'lib/public_key/src'), File.join(root, 'lib/other')])
      File.write(File.join(root, 'lib/other/DSS.asn1'), 'spec')
      File.write(File.join(root, 'lib/public_key/src/DSS.erl'), 'hand-written')
      File.symlink('../other', File.join(root, 'lib/public_key/asn1'))
      profile = { 'applications' => %w[other public_key], 'exclusions' => [] }
      error = assert_raises(Erx::Error) { Erx::ImportOrigins.remove_exclusions(root, profile: profile, component: 'otp') }
      assert_match(/lib\/public_key\/asn1 is something other than a directory/, error.message)
      assert File.file?(File.join(root, 'lib/public_key/src/DSS.erl'))
      ["x\0y.asn1\n", "../other/DSS.asn1\n", ".hidden\n"].each do |set|
        File.write(File.join(root, 'lib/other/Frame.set.asn'), set)
        assert_raises(Erx::Error) { Erx::Asn1Specifications.modules(File.join(root, 'lib/other')) }
      end
      File.unlink(File.join(root, 'lib/other/Frame.set.asn'))
      File.symlink('DSS.asn1', File.join(root, 'lib/other/Frame.set.asn'))
      assert_raises(Erx::Error) { Erx::Asn1Specifications.modules(File.join(root, 'lib/other')) }
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

  def test_target_application_selection_preserves_only_the_declared_set
    Dir.mktmpdir('erx-otp-selection-') do |root|
      %w[kernel stdlib megaco].each { |name| FileUtils.mkdir_p(File.join(root, 'lib', name)) }
      excluded = Erx::ImportOrigins.select_otp_applications(root, applications: %w[kernel stdlib])
      assert_equal %w[kernel stdlib], Dir.children(File.join(root, 'lib')).sort
      assert_equal ['lib/megaco'], excluded.map { |entry| entry.fetch('path') }
    end
  end

  def test_a_failed_inventory_does_not_prune_existing_import
    Dir.mktmpdir('erx-otp-atomic-') do |project|
      fixture_import(project, bad_file: true)
      assert_raises(Erx::Error) { Erx::ImportOrigins.write(root: project, component: 'otp') }
      assert File.file?(File.join(project, 'otp/lib/megaco/not-selected'))
      refute File.exist?(File.join(project, 'otp/ORIGIN.md'))
    end
  end

  def test_missing_required_source_is_refused
    Dir.mktmpdir('erx-otp-missing-') do |project|
      fixture_import(project, bad_file: false)
      File.unlink(File.join(project, 'otp/lib/kernel/keep.erl'))
      assert_raises(Erx::Error) { Erx::ImportOrigins.write(root: project, component: 'otp') }
      refute File.exist?(File.join(project, 'otp/ORIGIN.md'))
    end
  end
end
