# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/ns_writers'

# The chokepoints that only erx_ns's process writes the namespace's persistent term and
# only prim_file:set_cwd/1 calls erx_set_cwd_nif (docs/design.md, "Chokepoint checks"):
# the tree passes, and each seeded violation the design names fails.
class NsWritersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PRIM_FILE = Erx::NsWriters::PRIM_FILE
  SERVICE = 'erlang/apps/erx_files/src/seeded.erl'

  def found(files) = Erx::NsWriters.violations(files).map { |violation| [violation.rule, violation.path, violation.line] }

  def test_the_tree_passes_and_both_sites_hold_what_they_guard
    paths = Erx::NsWriters::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::NsWriters.violations(files).map(&:to_s)
    assert_match Erx::NsWriters::TABLE_WRITE, files.fetch(Erx::NsWriters::WRITER)
    assert_match(/^\s+\{ok, _Place\} -> erx_set_cwd_nif\(Reached\);/, files.fetch(PRIM_FILE))
  end

  # The design's seed: a put of the table's key added to prim_file.
  def test_a_put_or_erase_of_the_key_outside_erx_ns_fails
    text = "f(T) ->\n    persistent_term:put(erx_ns, T).\ng() -> persistent_term:erase( 'erx_ns' ).\n"
    assert_equal [['ns-table-writer', PRIM_FILE, 2], ['ns-table-writer', PRIM_FILE, 3]], found(PRIM_FILE => text)
  end

  def test_another_key_a_comment_and_a_read_pass
    text = "%% persistent_term:put(erx_ns, T)\nf(T) -> persistent_term:put(erx_ns_other, T), persistent_term:get(erx_ns).\n"
    assert_empty found(SERVICE => text)
  end

  # The design's seed: a call of erx_set_cwd_nif/1 added to another function of prim_file.
  def test_a_call_from_another_function_of_prim_file_fails
    text = "-nifs([erx_set_cwd_nif/1]).\nset_cwd(P) ->\n    erx_set_cwd_nif(P).\n" \
           "delete(P) ->\n    erx_set_cwd_nif(P).\nerx_set_cwd_nif(_P) ->\n    erlang:nif_error(undef).\n"
    assert_equal [['cwd-writer', PRIM_FILE, 5]], found(PRIM_FILE => text)
  end

  def test_a_string_that_looks_like_set_cwd_does_not_open_a_site
    text = "-doc \"\"\"\nset_cwd(P) is the only caller.\n\"\"\".\nother() ->\n    erx_set_cwd_nif(<<\"/\">>).\n"
    assert_equal [['cwd-writer', PRIM_FILE, 5]], found(PRIM_FILE => text)
  end

  def test_any_mention_outside_prim_file_fails
    text = "f() -> prim_file:erx_set_cwd_nif(<<\"/\">>).\ng() -> fun prim_file:erx_set_cwd_nif/1.\n"
    assert_equal [['cwd-writer', SERVICE, 1], ['cwd-writer', SERVICE, 2]], found(SERVICE => text)
  end

  # The source check runs the rules over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(PRIM_FILE)))
      File.write(File.join(root, PRIM_FILE), "f(T) -> persistent_term:put(erx_ns, T).\n")
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_ns_writers, [PRIM_FILE, 'README.md']) }
      assert_match "#{PRIM_FILE}:1", error.message
    end
  end
end
