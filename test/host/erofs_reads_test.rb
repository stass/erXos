# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/erofs_reads'

# The chokepoint that the EROFS reader reaches an image only through
# erx_verity:read/3 and that no other module reaches erx_verity's store
# (docs/design-storage.md, invariant E1): the tree passes, and each seeded way
# around the funnel fails.
class ErofsReadsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  READER = 'otp/erts/preloaded/src/erx_erofs.erl'
  SERVICE = 'erlang/apps/erx_files/src/seeded.erl'

  def lines_of(files) = Erx::ErofsReads.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_the_reader_uses_the_funnel
    paths = Erx::ErofsReads::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::ErofsReads.violations(files).map(&:to_s)
    assert_match(/erx_verity:read\(Image, First, Count\)/, files.fetch(READER))
  end

  def test_another_module_naming_the_funnel_fails
    text = "f(I) -> erx_verity:read(I, 0, 1).\ng() -> 'erx_verity'.\nh() -> \"erx_verity\".\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2], [SERVICE, 3]], lines_of(SERVICE => text)
  end

  def test_the_reader_may_only_read_through_the_funnel
    assert_empty lines_of(READER => "f(I) -> erx_verity:read(I, 0, 1).\n-type t() :: erx_verity:image().\n")
    text = "f(I) -> erx_verity:open(F, 1).\ng(I) -> erx_verity:close(I).\n"
    assert_equal [[READER, 1], [READER, 2]], lines_of(READER => text)
  end

  def test_the_reader_calls_no_module_that_reaches_state
    text = "f(I) -> persistent_term:get(I).\ng(I) -> 'ets':lookup(t, I).\nh(M, I) -> M:read(I).\n" \
           "i(I) -> apply(persistent_term, get, [I]).\nj() -> fun file:read_file/1.\nk() -> ?MODULE:f(1).\nl() -> lists:seq(1, 2).\n"
    assert_equal (1..7).map { |line| [READER, line] }, lines_of(READER => text)
  end

  def test_comments_strings_and_binaries_in_the_reader_pass
    text = "%% persistent_term:get(x)\nf(<<V:16/little, _/binary>>) -> \"file:read(x)\", binary:at(<<1>>, V).\n" \
           "g() -> try ok catch throw:{x, Y} -> Y end.\nh() -> \#{a := b} = \#{a => b}.\n"
    assert_empty lines_of(READER => text)
  end

  def test_the_funnel_itself_and_files_outside_the_scope_pass
    call = "f(I) -> persistent_term:get(I), erx_verity:read(I, 0, 1).\n"
    assert_empty lines_of('otp/erts/preloaded/src/erx_verity.erl' => call, 'test/erlang/seeded_tests.erl' => call)
  end

  # The source check runs the rule over the files git lists, OTP's included.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(READER)))
      File.write(File.join(root, READER), "f(I) -> persistent_term:get(I).\n")
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_erofs_reads, [READER, 'README.md']) }
      assert_match "#{READER}:1", error.message
    end
  end
end
