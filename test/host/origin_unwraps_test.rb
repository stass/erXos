# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/origin_unwraps'

# The chokepoint that in OTP's applications only the owners of the protocols that cross
# domains name erx_origin, the envelope of a message from another domain (docs/design.md,
# "Chokepoint checks"; D18): the tree passes, gen, io and erx_file_remote hold their
# unwraps, and the design's seeded extra site, sys taking the envelope apart, fails, as
# does the same unwrap in a preloaded module that owns no protocol.
class OriginUnwrapsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SYS = 'otp/lib/stdlib/src/sys.erl'
  GEN = 'otp/lib/stdlib/src/gen.erl'
  FILE_REMOTE = 'otp/erts/preloaded/src/erx_file_remote.erl'
  UNWRAP = '{erx_origin, _, {erx_9p, Alias, Reply}} -> {reply, Reply}'

  def found(files) = Erx::OriginUnwraps.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_gen_io_and_erx_file_remote_unwrap_replies
    paths = Erx::OriginUnwraps::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::OriginUnwraps.violations(files).map(&:to_s)
    assert_match(/^ +\{erx_origin, _, \{\[alias \| Mref\], Reply\}\} ->$/, files.fetch(GEN))
    assert_match(/^\t\{erx_origin, _, \{io_reply, Mref, Reply\}\} ->$/, files.fetch('otp/lib/stdlib/src/io.erl'))
    assert_equal 2, files.fetch(FILE_REMOTE).scan(UNWRAP).size
  end

  # erx_file_remote's unwrap in erx_verity, a preloaded client that owns no protocol
  # crossing domains, is an unlisted site.
  def test_the_file_reply_unwrap_outside_its_owner_fails
    verity = 'otp/erts/preloaded/src/erx_verity.erl'
    assert_equal [[verity, 2]], found(verity => "answers(Alias) ->\n    receive #{UNWRAP} end.\n")
    assert_empty found(FILE_REMOTE => "reply(Alias) ->\n    receive #{UNWRAP} end.\n")
  end

  # The design's seed: sys's loop taking a system message out of its envelope.
  def test_a_match_in_sys_fails
    text = "handle({erx_origin, _D, {system, From, Req}}) ->\n    req(From, Req);\n" \
           "handle({'erx_origin', _, M}) -> M.\n"
    assert_equal [[SYS, 1], [SYS, 3]], found(SYS => text)
  end

  def test_an_owner_a_comment_a_string_and_a_longer_atom_pass
    text = "%% {erx_origin, D, Msg}\nf() -> \"erx_origin\", erx_origins, 'erx_origin_x', $e.\n"
    assert_empty found(SYS => text)
    assert_empty found(GEN => "f({erx_origin, _, M}) -> M.\n")
    assert_empty found('erlang/apps/erx_net/src/erx_net.erl' => "f({erx_origin, D, M}) -> {D, M}.\n")
  end

  # The source check runs the rule over the files git lists, OTP's imports included.
  def test_the_source_check_refuses_a_seeded_extra_site
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(SYS)))
      File.write(File.join(root, SYS), "f({erx_origin, _, M}) -> M.\n")
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_origin_unwraps, [SYS, 'README.md']) }
      assert_match "#{SYS}:1", error.message
    end
  end
end
