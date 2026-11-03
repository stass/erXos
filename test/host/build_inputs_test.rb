# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/build_inputs'

class BuildInputsTest < Minitest::Test
  def test_exact_catalog_does_not_grant_a_project_directory
    Dir.mktmpdir('build-inputs-') do |root|
      file = File.join(root, 'source.c')
      secret = File.join(root, 'local-values.yml')
      File.write(file, 'registered bytes')
      File.write(secret, 'private bytes')
      catalog = Erx::BuildInputs.capture(root: root, paths: [file])
      assert_equal 'registered bytes', catalog.read(file, maximum: 100)
      assert_raises(Erx::Error) { catalog.read(secret, maximum: 100) }
      assert_raises(Erx::Error) { catalog.merge('paths' => [secret]) }
      assert catalog.frozen?
      assert_raises(NoMethodError) { Erx::BuildInputs.new }
    end
  end

  def test_changed_alias_missing_input_and_changed_bytes_are_refused
    Dir.mktmpdir('build-input-alias-') do |root|
      first = File.join(root, 'first')
      second = File.join(root, 'second')
      link = File.join(root, 'alias')
      File.write(first, 'first bytes')
      File.write(second, 'second bytes')
      File.symlink(first, link)
      catalog = Erx::BuildInputs.capture(root: root, paths: [link, second])
      File.unlink(link)
      File.symlink(second, link)
      assert_raises(Erx::Error) { catalog.verify_all }
      File.unlink(link)
      File.symlink(first, link)
      File.write(first, 'changed bytes')
      assert_raises(Erx::Error) { catalog.verify(first) }
      File.unlink(first)
      assert_raises(Erx::Error) { catalog.verify(first) }
    end
  end

  def test_registered_import_uses_origin_checks_and_rejects_unknown_files
    Dir.mktmpdir('build-import-') do |root|
      source = File.join(root, 'source.c')
      File.write(source, "/* SPDX-License-Identifier: BSD-2-Clause */\nint source;\n")
      Erx::Origin.new(root: root).write(repository: 'https://example.invalid/source', revision: 'fixture',
        archive_sha256: 'a' * 64,
        review: { 'rules' => [], 'default_license' => 'BSD-2-Clause', 'default_evidence' => 'fixture' })
      catalog = Erx::BuildInputs.imported(root: root)
      assert catalog.find_import(root)
      assert catalog.verify(source)
      File.write(File.join(root, 'local-values.yml'), "# SPDX-License-Identifier: BSD-2-Clause\nprivate: value\n")
      error = assert_raises(Erx::Error) { Erx::BuildInputs.imported(root: root) }
      assert_match(/absent from its reviewed inventory/, error.message)
    end
  end
end
