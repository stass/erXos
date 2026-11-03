# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'

class ChecksTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('erx-checks-')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_source_ascii_and_markdown_exemption
    File.binwrite(File.join(@root, 'source.c'), "int value;\n")
    File.binwrite(File.join(@root, 'README.md'), "prose \xc3\xa9\n".b)
    assert Erx::Checks.new(root: @root, required_imports: []).run
    File.binwrite(File.join(@root, 'source.c'), "/* \xc3\xa9 */\n".b)
    error = assert_raises(Erx::Error) { Erx::Checks.new(root: @root, required_imports: []).run }
    assert_match(/source.c:1/, error.message)
  end

  def test_import_provenance_is_required
    assert_raises(Erx::Error) { Erx::Checks.new(root: @root, required_imports: ['missing']).run }
  end

  def test_imported_unicode_is_checked_against_its_baseline
    path = File.join(@root, 'import')
    Dir.mkdir(path)
    source = File.join(path, 'source.c')
    File.binwrite(source, "/* upstream \xc3\xa9 */\n".b)
    Erx::Origin.new(root: path).write(repository: 'https://example.org/source', revision: '1',
                                      archive_sha256: 'a' * 64,
                                      review: { 'default_license' => 'MIT',
                                                'default_evidence' => 'reviewed fixture', 'rules' => [] })
    assert Erx::Checks.new(root: @root, required_imports: ['import']).run
    File.binwrite(source, "int changed;\n")
    assert_raises(Erx::Error) { Erx::Checks.new(root: @root, required_imports: ['import']).run }
  end

  def test_build_and_agent_state_are_not_source_inputs
    %w[build .codex .agents .aws].each do |directory|
      Dir.mkdir(File.join(@root, directory))
      File.binwrite(File.join(@root, directory, 'state.rb'), "\xff".b)
    end
    assert Erx::Checks.new(root: @root, required_imports: []).run
  end
end
