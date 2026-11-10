# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/net_checks'

# erx_net's build checks (tools/lib/erx/net_checks.rb): the tree passes, and
# each rule catches its seeded violation and leaves the allowed forms alone.
class NetChecksTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SRC = 'erlang/apps/erx_net/src'
  CLIENT = 'erlang/apps/erx_net_client/src'
  PIN = <<~NOTICE
    tag main-n285245
    commit 975e3605ebb15cbaf5a25c1c9d1f51aed41291d0
    archive-sha256 f71de70a45f84130e235b067f76bd9eefcc691bb02db054e01863981c2f74588
    release-tag release/15.1.0-p6
    release-commit 95719d8a895bf8170851e9844d9b4092b1d2b6fe
    release-archive-sha256 016e7c86ea4dfbb17bd8a7b1136a7af5a7ce4d9e6de5a559e73dc7336824b998
    port 4e28874a6048f3c5a72a42b5bcfcfc7e71cad8a6 sys/netinet/tcp_ecn.c tcp_ecn_input_segment
  NOTICE
  # The line number of the first line after PIN.
  NEXT = PIN.lines.size + 1
  DERIVED = <<~ERL
    %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
    %% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
    %%
    %% FreeBSD: sys/netinet/tcp_seq.h
    %%
    %% Copyright (c) 1982, 1986, 1993, 1995
    -module(erx_tcp_seq).
  ERL

  def violations(files, notice: PIN)
    Erx::NetChecks.violations(files.merge(Erx::NetChecks::NOTICE => notice).compact)
  end

  def rules(files, **options) = violations(files, **options).map { |violation| [violation.rule, violation.line] }

  def module_text(body) = "-module(m).\n#{body}\n"

  # The violations of one erx_net source with the pinned notice.
  def source_rules(path, body) = rules({ path => module_text(body) })

  def test_the_tree_passes
    paths = [Erx::NetChecks::NOTICE, *Dir.glob([Erx::NetChecks::SCOPE, Erx::NetChecks::CLIENT_SCOPE], base: ROOT)]
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::NetChecks.violations(files).map(&:to_s)
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

  # The design's seeded failure: a step that takes its value from rand:uniform/1.
  def test_rand_crypto_and_stray_entropy_calls_fail
    { 'rand:uniform(6)' => 2, "apply('crypto', strong_rand_bytes, [16])" => 2,
      "erx_bytes:\n  entropy(16)" => 2, 'fun erx_bytes:entropy/1' => 2 }.each do |body, line|
      assert_equal [['random', line]], source_rules("#{SRC}/erx_net_x.erl", body), body
    end
  end

  # Only the portable erx_bytes may name crypto, and it may not name rand either.
  def test_crypto_passes_only_in_the_portable_erx_bytes
    portable = 'erlang/apps/erx_net/portable/erx_bytes.erl'
    assert_empty source_rules(portable, 'crypto:strong_rand_bytes(N)')
    assert_equal [['random', 2]], source_rules(portable, 'rand:bytes(N)')
    assert_equal [['random', 2]], source_rules("#{SRC}/erx_bytes.erl", 'crypto:strong_rand_bytes(N)')
    assert_equal [['random', 2]], source_rules('erlang/apps/erx_net/portable/erx_net_local.erl', 'crypto:hash(sha256, B)')
  end

  def test_entropy_passes_in_the_clock_and_rand_in_comments_strings_and_names
    assert_empty source_rules("#{SRC}/erx_net_clock.erl", 'erx_bytes:entropy(16)')
    # The design's seeded failure: an interface that draws its key directly.
    assert_equal [['random', 2]], source_rules("#{SRC}/erx_net_if.erl", 'erx_bytes:entropy(16)')
    body = "%% rand is not used\n-doc \"\"\"\nNot `rand`.\n\"\"\".\nerx_net_rand:new(K), \"crypto\""
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

  def test_notice_must_parse
    assert_equal [['notices', nil]], rules({}, notice: PIN.lines.drop(1).join)
    without_release = PIN.lines.reject { |line| line.start_with?('release-commit') }.join
    assert_equal [['notices', nil]], rules({}, notice: without_release)
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}tag again\n")
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}  sys/netinet/tcp.h\n")
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}port 4e28874a6048f3c5a72a42b5bcfcfc7e71cad8a6 sys/netinet/tcp_ecn.c\n")
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}port ../tcp_ecn.c tcp_ecn_input_segment\n")
    # A port line without its commit, or with a short or upper-case one, is refused.
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}port sys/netinet/tcp_ecn.c tcp_ecn_input_segment\n")
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}port 4e28874a6048 sys/netinet/tcp_ecn.c tcp_ecn_input_segment\n")
    assert_equal [['notices', NEXT]], rules({}, notice: "#{PIN}port 4E28874A6048F3C5A72A42B5BCFCFC7E71CAD8A6 sys/netinet/tcp_ecn.c tcp_ecn_input_segment\n")
    assert_equal [['notices', NEXT + 1]], rules({}, notice: "#{PIN}module m\n  ../etc/passwd\n")
    assert_equal [['notices', NEXT + 1]], rules({}, notice: "#{PIN}module m\nmodule m\n")
    assert_equal [['notices', nil]], rules({ "#{SRC}/m.erl" => module_text('') }, notice: nil)
  end

  # The design's test 12: an iolist_to_binary/1 added to erx_tcp_output fails, as does
  # every other copying call in a module a payload passes through.
  def test_payload_copies_fail_outside_their_sites
    { 'out(P) -> iolist_to_binary(P).' => 2, "out(P) ->\n  erlang:list_to_binary(P)." => 3,
      'out(P) -> binary:copy(P).' => 2, "out(P) -> 'binary':list_to_bin(P)." => 2,
      'out(P) -> erlang:iolist_to_iovec(P).' => 2, 'out() -> fun iolist_to_binary/1.' => 2 }.each do |body, line|
      assert_equal [['payload-copy', line]], source_rules("#{SRC}/erx_tcp_output.erl", body), body
    end
    assert_equal [['payload-copy', 3]], source_rules("#{SRC}/erx_net_if.erl", "a(X) -> X.\nb(P) -> iolist_to_binary(P).")
    assert_equal [['payload-copy', 2]], source_rules("#{SRC}/erx_tcp_conn.erl", 'take(Q) -> iolist_to_binary(Q).')
    assert_equal [['payload-copy', 2]], source_rules("#{CLIENT}/erx_gen_tcp_core.erl", 'take(L, H) -> iolist_to_binary(H).')
    assert_equal [['payload-copy', 2]], source_rules("#{CLIENT}/erx_gen_tcp.erl", 'recv(B) -> binary:copy(B).')
  end

  def test_payload_copies_pass_at_their_sites_in_comments_and_other_modules
    assert_empty source_rules("#{SRC}/erx_tcp_conn.erl", "compact(B) ->\n  binary:copy(B).")
    assert_empty source_rules("#{SRC}/erx_tcp_reass.erl", 'hold(D) -> binary:copy(D).')
    assert_empty source_rules("#{CLIENT}/erx_gen_tcp_core.erl", 'split(L, P) -> iolist_to_binary(P).')
    assert_empty source_rules("#{CLIENT}/erx_gen_tcp.erl", 'send(S, D) -> iolist_to_binary(D).')
    assert_empty source_rules("#{SRC}/erx_tcp_output.erl", "%% iolist_to_binary(P)\nout(P) -> my_iolist_to_binary(P).")
    assert_empty source_rules("#{SRC}/erx_udp.erl", 'out(P) -> iolist_to_binary(P).')
    assert_empty source_rules("#{CLIENT}/erx_gen_udp.erl", 'send(S, P) -> iolist_to_binary(P).')
  end

  # The design's seeded failure: a backend that reads the grant key itself
  # and so calls the grant past erx_sock_admit.
  def test_grant_key_reads_fail_outside_erx_inet
    { 'application:get_env(erx_net_client, grant)' => 2, "'application':get_all_env()" => 2,
      "fun application:\n  get_env/2" => 2, 'application:get_key(erx_net_client, env)' => 2,
      '{ok, G, _} = erx_net:local_grant()' => 2, 'whereis(erx_net_grant)' => 2 }.each do |body, line|
      assert_equal [['grant-key', line]], source_rules("#{CLIENT}/erx_gen_tcp.erl", body), body
    end
  end

  def test_grant_key_reads_pass_in_erx_inet_comments_and_the_stack
    body = 'application:get_env(erx_net_client, grant, {erx_net, local_grant, []})'
    assert_empty source_rules("#{CLIENT}/erx_inet.erl", body)
    assert_empty source_rules("#{CLIENT}/erx_gen_udp.erl", "%% application:get_env is erx_inet's\nmy_application:get_env(k)")
    assert_empty source_rules("#{SRC}/erx_net_app.erl", 'application:get_env(erx_net, interfaces)')
  end

  # The design's seeded failure: the resolver loader's watch_resolver call
  # with a timeout of 5000 ms.
  def test_calls_without_the_literal_infinity_fail
    { 'gen_server:call(Grant, watch_resolver, 5000)' => 2, 'gen_server:call(Grant, watch_resolver)' => 2,
      'gen_statem:call(S, r, ?TIMEOUT)' => 2, "gen:call(P, '$gen_call', r)" => 2, 'fun gen_server:call/3' => 2,
      "x(),\n  'gen_server':call(P, {a, b}, Timeout)" => 3, 'gen_server:call(P, r, {infinity})' => 2,
      'gen_server:call(P, fun() -> a, b end, infinity)' => 2, 'gen_server:call(P, r' => 2 }.each do |body, line|
      assert_equal [['call-timeout', line]], source_rules("#{CLIENT}/erx_inet.erl", body), body
      assert_equal [['call-timeout', line]], source_rules("#{SRC}/erx_net_if.erl", body), body
    end
  end

  def test_calls_with_the_literal_infinity_pass
    body = "gen_server:call(P, {a, [b, c], <<1, 2>>, \#{k => v}}, infinity),\n" \
           "gen_statem:call(P, r,\n    infinity), gen:call(P, '$gen_call', r, 'infinity'),\n" \
           "%% gen_server:call(P, r)\nmy_gen_server:call(P, r), gen_server:call_x(P), \"gen_server:call(P, r)\""
    assert_empty source_rules("#{CLIENT}/erx_gen_tcp.erl", body)
    assert_empty source_rules("#{SRC}/erx_net_if.erl", body)
  end
end
