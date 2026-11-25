# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Fiasco's preprocess writes the source file names of its #line directives
# through its -m maps, so the kernel's generated sources, and the MD5 checksums
# of them that the compiler's DWARF 5 line tables keep, do not depend on where
# the checkout is.
class FiascoPreprocessTest < Minitest::Test
  PREPROCESS = File.expand_path('../../fiasco/kernel/tool/preprocess/src/preprocess', __dir__)

  # A module that reaches each writer of a #line directive: the class
  # declaration and the function definition (print_lineno), the public
  # function's declaration in the header (print_lineno_sans_empty_lines), and
  # the class extended with a base in a later section (to_line_directive).
  MODULE = <<~CPP
    INTERFACE:

    class Base {};

    class Thing
    {
    public:
      int value() const;
    };

    IMPLEMENTATION:

    EXTENSION class Thing : public Base
    {
      int _v;
    };

    PUBLIC
    int
    Thing::value() const
    { return _v; }
  CPP

  def test_every_line_directive_names_the_source_through_the_map
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'some/root')
      out = preprocess(directory, write_module(root, 'thing.cpp'), "-m#{root}=.")
      assert_match %r{^#line \d+ "\./thing\.cpp"$}, out
      refute_includes out, root
    end
  end

  def test_the_longest_of_several_maps_applies
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'some/root')
      out = preprocess(directory, write_module(File.join(root, 'kern'), 'thing.cpp'),
                       '-m', "#{root}=.", '-m', "#{root}/kern=k")
      assert_match %r{^#line \d+ "k/thing\.cpp"$}, out
      refute_includes out, root
    end
  end

  # A map's <old> is a whole directory: a sibling whose name only starts with it
  # keeps its name.
  def test_a_map_matches_only_at_a_directory_boundary
    Dir.mktmpdir do |directory|
      root = File.join(directory, 'some/root')
      source = write_module("#{root}x", 'thing.cpp')
      out = preprocess(directory, source, "-m#{root}=.")
      assert_match(/^#line \d+ "#{Regexp.escape(source)}"$/, out)
    end
  end

  def test_a_malformed_map_is_refused
    ['no-equals', '=.', '/a/=.', '/a=b"c', "/a=b\nc"].each do |map|
      _out, err, status = Open3.capture3('perl', PREPROCESS, '-m', map, '-c', 'thing', 'x.cpp', stdin_data: '')
      refute status.success?, "-m #{map} was accepted"
      assert_includes err, "-m '#{map}' must be <old>=<new>"
    end
  end

  private

  def write_module(directory, name)
    FileUtils.mkdir_p(directory)
    File.join(directory, name).tap { |path| File.write(path, MODULE) }
  end

  # The generated header, inline header and source, concatenated.
  def preprocess(directory, source, *maps)
    _out, err, status = Open3.capture3('perl', PREPROCESS, *maps, '-c', 'thing', source,
                                       chdir: directory, stdin_data: '')
    assert status.success?, "preprocess failed: #{err}"
    %w[thing.h thing_i.h thing.cc].map { |name| File.read(File.join(directory, name)) }.join
  end
end
