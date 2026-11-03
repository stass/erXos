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

  def test_host_tooling_parses_json_only_through_json_input
    FileUtils.mkdir_p(File.join(@root, 'tools/lib/erx'))
    File.binwrite(File.join(@root, 'tools/lib/erx/json_input.rb'), "value = JSON.parse(text)\n")
    File.binwrite(File.join(@root, 'tools/lib/erx/writer.rb'),
                  "text = JSON.generate(value)\ntext = JSON . pretty_generate(value)\n" \
                  "error = JsonInput::Unsupported\n# reads JSON: never through a raw parser\n")
    File.binwrite(File.join(@root, 'tools/notes.txt'), "JSON.parse is documented here\n")
    assert Erx::Checks.new(root: @root, required_imports: []).run
    { 'tools/lib/erx/reader.rb' => "# reader\nvalue = JSON.parse(text)\n",
      'tools/erx' => "#!/usr/bin/env ruby\nvalue = ::JSON.load(text)\n",
      'tools/fuzz/target.rb' => "value = JSON::Parser.new(text).parse\n",
      'tools/lib/erx/coder.rb' => "value = JSON::Coder.new.load(text)\n",
      'tools/lib/erx/restore.rb' => "value = JSON.restore(text)\n",
      'tools/lib/erx/rescue.rb' => "rescue JSON::ParserError\n",
      'tools/lib/erx/kernel.rb' => "value = JSON(text)\n",
      'tools/lib/erx/index.rb' => "value = JSON[text]\n",
      'tools/lib/erx/addition.rb' => "value = String.from_json(text)\n" }.each do |relative, source|
      path = File.join(@root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, source)
      error = assert_raises(Erx::Error) { Erx::Checks.new(root: @root, required_imports: []).run }
      assert_equal 'JSON used other than to write, outside tools/lib/erx/json_input.rb: ' \
                   "#{relative}:#{source.lines.size}", error.message
      File.unlink(path)
    end
  end

  def test_build_and_agent_state_are_not_source_inputs
    %w[build .codex .agents .aws].each do |directory|
      Dir.mkdir(File.join(@root, directory))
      File.binwrite(File.join(@root, directory, 'state.rb'), "\xff".b)
    end
    assert Erx::Checks.new(root: @root, required_imports: []).run
  end
end
