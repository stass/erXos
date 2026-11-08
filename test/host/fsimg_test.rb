# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/fsimg'

# The fsimg pin's Ruby side (Erx::Fsimg): the manifests it writes, whose paths cannot
# open a comment, split a word or start a keyword, and the refusal of a build that is
# missing or was made from another pin or recipe. test/host/release_medium_test.rb
# runs the built fsimg itself.
class FsimgTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Entry = Erx::Fsimg::Entry

  def test_a_manifest_names_each_entry_with_its_keywords_in_order
    text = Erx::Fsimg.mtree([Entry.new(path: 'lib', keywords: { 'type' => 'dir', 'uid' => 0 }),
                             Entry.new(path: 'lib/a.beam', keywords: { 'type' => 'file', 'size' => 3, 'contents' => 'x/y' })])
    assert_equal "#mtree\n./lib type=dir uid=0\n./lib/a.beam type=file size=3 contents=x/y\n", text
  end

  def test_a_keyword_or_value_that_could_split_a_line_is_refused
    ['time', 'type ', 'uname'].each do |key|
      assert_raises(Erx::Error) { Erx::Fsimg.mtree([Entry.new(path: 'a', keywords: { key => '1' })]) }
    end
    ["file\n./b type=file", 'file x', 'a\\b', ''].each do |value|
      assert_raises(Erx::Error) { Erx::Fsimg.mtree([Entry.new(path: 'a', keywords: { 'type' => value })]) }
    end
  end

  def test_every_byte_that_means_something_to_mtree_is_encoded
    assert_equal '\\043\\040\\075\\134\\012\\052\\077\\133', Erx::Fsimg.encode("# =\\\n*?[")
    assert_equal 'a-b_c.d/E9', Erx::Fsimg.encode('a-b_c.d/E9')
    assert_equal '\\303\\251', Erx::Fsimg.encode("\xC3\xA9".b)
    line = Erx::Fsimg.mtree([Entry.new(path: 'odd name', keywords: { 'type' => 'link', 'link' => '../t #x' })]).lines.last
    assert_equal "./odd\\040name type=link link=../t\\040\\043x\n", line
  end

  def test_a_build_that_is_missing_or_from_another_pin_is_refused
    Dir.mktmpdir('erx-fsimg-') do |root|
      FileUtils.cp(File.join(ROOT, 'deps.lock'), root)
      assert_raises(Erx::Fsimg::MissingBuild) { Erx::Fsimg.locate(root: root) }

      output = File.join(root, Erx::Fsimg::OUTPUT)
      FileUtils.mkdir_p(output)
      File.write(File.join(output, 'fsimg'), '')
      source = Erx::Fsimg.source_record(root: root)
      [{ 'source' => source.merge('commit' => '0' * 40), 'recipe' => Erx::Fsimg::Build::RECIPE },
       { 'source' => source, 'recipe' => '0' * 64 }].each do |stamp|
        File.write(File.join(output, Erx::Fsimg::STAMP), JSON.generate(stamp))
        assert_raises(Erx::Fsimg::StaleBuild) { Erx::Fsimg.locate(root: root) }
      end
      File.write(File.join(output, Erx::Fsimg::STAMP), '{')
      assert_raises(Erx::Fsimg::StaleBuild) { Erx::Fsimg.locate(root: root) }

      File.write(File.join(output, Erx::Fsimg::STAMP), JSON.generate('source' => source, 'recipe' => Erx::Fsimg::Build::RECIPE))
      assert_equal File.join(output, 'fsimg'), Erx::Fsimg.locate(root: root)
    end
  end
end
