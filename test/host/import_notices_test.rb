# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/pack_provenance'

class ImportNoticesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  # A synthetic link record isolates attribution of real imported bytes. This
  # fixture neither builds nor executes the object it names.
  def record_for(relative)
    base = File.join(ROOT, 'build/test')
    FileUtils.mkdir_p(base)
    Dir.mktmpdir('import-notices-', base) do |directory|
      source = File.join(ROOT, relative)
      artifact = File.join(directory, 'image')
      object = File.join(directory, 'object.o')
      map = File.join(directory, 'map')
      dependency = File.join(directory, 'object.d')
      File.binwrite(artifact, 'fixture image')
      File.binwrite(object, 'fixture object')
      File.write(map, "10000 10000 4 4 #{object}:(.text)\n")
      File.write(dependency, "#{object}: #{source}\n")
      reference = lambda { |path| { 'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest } }
      receipt = { 'version' => 1, 'kind' => 'linked', 'artifact' => reference.call(artifact),
                  'linker_map' => reference.call(map).merge('format' => 'lld', 'directory' => '.'),
                  'compiles' => [{ 'object' => reference.call(object), 'dependency' => reference.call(dependency),
                                   'directory' => '.', 'sources' => [reference.call(source)] }],
                  'archives' => [], 'inputs' => [] }
      path = File.join(directory, 'record.json')
      File.write(path, JSON.generate(receipt))
      catalog = Erx::BuildInputs.pack(root: ROOT, paths: [artifact, object, map, dependency, path])
      resolver = Erx::PackProvenance.new(root: ROOT, catalog: catalog,
                                         imports: { 'musl' => 'permanent', 'otp' => 'permanent' })
      return resolver.resolve(receipt: path, artifact: artifact, build_kind: 'release').first
    end
  end

  def test_musl_contains_the_complete_project_permission_and_copyright_notice
    record = record_for('musl/src/string/strlen.c')
    assert_equal 'MIT', record.fetch('license')
    assert_includes record.fetch('notice'), File.binread(File.join(ROOT, 'musl/COPYRIGHT'))
    assert_includes record.fetch('notice'), 'Permission is hereby granted'
    assert record.fetch('notice_documents').any? { |doc| doc.fetch('path') == 'musl/COPYRIGHT' }
  end

  def test_file_erxos_added_to_musl_is_erxos_code_and_not_musl_code
    record = record_for('musl/src/thread/erxos/clone.c')
    assert_equal 'BSD-2-Clause', record.fetch('license')
    assert_equal 'file SPDX', record.fetch('evidence')
    assert_equal 'permanent', record.fetch('status')
    assert_includes record.fetch('notice'), File.binread(File.join(ROOT, 'LICENSE'))
    refute_includes record.fetch('notice'), File.binread(File.join(ROOT, 'musl/COPYRIGHT'))
    assert_equal ['LICENSE'], record.fetch('notice_documents').map { |doc| doc.fetch('path') }
  end

  def test_musl_file_erxos_modified_stays_musl_code
    record = record_for('musl/src/thread/pthread_cond_timedwait.c')
    assert_equal 'MIT', record.fetch('license')
    assert_includes record.fetch('notice'), File.binread(File.join(ROOT, 'musl/COPYRIGHT'))
  end

  def test_nested_zstd_package_uses_only_the_selected_bsd_grant
    record = record_for('otp/erts/emulator/zstd/common/zstd_common.c')
    assert_equal 'BSD-3-Clause', record.fetch('license')
    assert_equal 'BSD-3-Clause OR GPL-2.0-only', record.fetch('declared_license')
    assert_includes record.fetch('notice'), File.binread(File.join(ROOT, 'otp/erts/emulator/zstd/LICENSE'))
    refute_includes record.fetch('notice'), File.binread(File.join(ROOT, 'otp/erts/emulator/zstd/COPYING'))
    assert_equal ['otp/erts/emulator/zstd/LICENSE'], record.fetch('notice_documents').map { |doc| doc.fetch('path') }
  end
end
