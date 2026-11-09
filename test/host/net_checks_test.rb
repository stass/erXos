# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/dependencies'
require_relative '../../tools/lib/erx/net_checks'

# erx_net's build checks (tools/lib/erx/net_checks.rb): the tree passes, and
# each rule catches its seeded violation and leaves the allowed forms alone.
class NetChecksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SRC = 'erlang/apps/erx_net/src'
  LOCK = Erx::DependencySchema.parse(File.binread(File.join(ROOT, 'deps.lock')))
                              .find { |source| source.fetch('id') == 'freebsd-src' }
  PIN = <<~NOTICE
    tag release/15.1.0-p6
    commit #{LOCK.fetch('version')}
    archive-sha256 #{LOCK.fetch('sha256')}
  NOTICE
  DERIVED = <<~ERL
    %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
    %% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
    %%
    %% FreeBSD: sys/netinet/tcp_seq.h
    %%
    %% Copyright (c) 1982, 1986, 1993, 1995
    -module(erx_tcp_seq).
  ERL

  def violations(files, notice: PIN, lock: LOCK)
    Erx::NetChecks.violations(files.merge(Erx::NetChecks::NOTICE => notice).compact, lock: lock)
  end

  def rules(files, **options) = violations(files, **options).map { |violation| [violation.rule, violation.line] }

  def module_text(body) = "-module(m).\n#{body}\n"

  # The violations of one erx_net source with the pinned notice.
  def source_rules(path, body) = rules({ path => module_text(body) })

  def test_the_tree_passes
    paths = [Erx::NetChecks::NOTICE, *Dir.glob(Erx::NetChecks::SCOPE, base: ROOT)]
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::NetChecks.violations(files, lock: LOCK).map(&:to_s)
  end

  def test_atom_makers_fail_in_code_and_quoted_atoms
    { 'binary_to_atom(B, utf8)' => 2, "apply(erlang, 'list_to_atom', [L])" => 2,
      'fun erlang:binary_to_term/1' => 2 }.each do |body, line|
      assert_equal [['atoms', line]], source_rules("#{SRC}/erx_net_x.erl", body), body
    end
  end

  def test_atom_makers_pass_in_comments_and_longer_names
    body = "%% binary_to_atom is refused\nlist_to_existing_atom(L), my_binary_to_term_x(B)"
    assert_empty source_rules("#{SRC}/erx_net_x.erl", body)
  end

  def test_wrap_literals_and_shifts_fail_in_tcp_modules
    ['X band 16#ffffffff', 'X band 16#FFFF_FFFF', 'X rem 4294967296', 'X rem 4_294_967_296',
     '(1 bsl 32)', 'D bsl  31', 'D < 2147483648', 'X band 2#11111111111111111111111111111111',
     'w(X) -> X band 16#FFFFFFFF.', 'w() -> 4294967296.', '1 bsl 16#20', '1 bsl(32)', '1 bsl 3_2'].each do |body|
      %w[erx_tcp.erl erx_tcp_input.erl erx_tcp_fsm.hrl].each do |name|
        assert_equal [['seq-wrap', 2]], source_rules("#{SRC}/#{name}", body), "#{name}: #{body}"
      end
    end
  end

  def test_wrap_literals_pass_in_erx_tcp_seq_other_modules_comments_and_strings
    body = 'X band 16#ffffffff'
    assert_empty source_rules("#{SRC}/erx_tcp_seq.erl", body)
    assert_empty source_rules("#{SRC}/erx_net_route.erl", body)
    assert_empty source_rules("#{SRC}/erx_tcp_input.erl", "%% #{body}\n\"bsl 32\", 1.0e32, X bsl 3, 16#fffffff")
  end

  def test_a_shift_across_lines_fails_on_its_operand_line
    assert_equal [['seq-wrap', 3]], source_rules("#{SRC}/erx_tcp_input.erl", "w(X) -> X bsl\n  32.")
  end

  def test_malformed_or_misplaced_markers_fail
    notice = "#{PIN}module erx_tcp_seq\n  sys/netinet/tcp_seq.h\n"
    [DERIVED.sub('tcp_seq.h', 'tcp_seq.h (SEQ_LT)'), "#{DERIVED}%% FreeBSD: sys/netinet/tcp_var.h\n"].each do |text|
      refute_empty rules({ "#{SRC}/erx_tcp_seq.erl" => text }, notice: notice).select { |rule, line| rule == 'notices' && line }
    end
  end

  def test_two_sources_under_one_name_fail
    files = { "#{SRC}/erx_y.erl" => module_text(''), 'erlang/apps/erx_net/test/erx_y.erl' => module_text('') }
    assert_equal [['notices', nil]], rules(files)
  end

  def test_notice_pairs_with_headers
    notice = "#{PIN}module erx_tcp_seq\n  sys/netinet/tcp_seq.h SEQ_LT SEQ_GT\n"
    assert_empty rules({ "#{SRC}/erx_tcp_seq.erl" => DERIVED }, notice: notice)
    assert_equal [['notices', nil]], rules({ "#{SRC}/erx_tcp_seq.erl" => DERIVED }, notice: PIN)
    assert_equal [['notices', nil]],
                 rules({ "#{SRC}/erx_tcp_seq.erl" => DERIVED }, notice: "#{notice}  sys/netinet/tcp_var.h\n")
    assert_equal [['notices', nil]], rules({ "#{SRC}/erx_tcp.erl" => module_text('') }, notice: notice)
  end

  def test_notice_must_match_the_pin_and_parse
    assert_equal [['notices', nil]], rules({}, notice: PIN.sub(LOCK.fetch('sha256'), '0' * 64))
    assert_equal [['notices', nil]], rules({}, notice: PIN.sub(LOCK.fetch('version'), 'f' * 40))
    assert_equal [['notices', nil]], rules({}, notice: PIN.lines.drop(1).join)
    assert_equal [['notices', 4]], rules({}, notice: "#{PIN}tag again\n")
    assert_equal [['notices', 4]], rules({}, notice: "#{PIN}  sys/netinet/tcp.h\n")
    assert_equal [['notices', 5]], rules({}, notice: "#{PIN}module m\n  ../etc/passwd\n")
    assert_equal [['notices', 5]], rules({}, notice: "#{PIN}module m\nmodule m\n")
    assert_equal [['notices', nil]], rules({ "#{SRC}/m.erl" => module_text('') }, notice: nil)
  end
end
