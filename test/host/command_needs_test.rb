# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/command_needs'

# The chokepoint that only a command declaring a service's facet reaches that service of
# the system domain (docs/design.md, "Chokepoint checks"; SH1 of docs/design-shell.md):
# the tree passes and its network commands declare net, and the design's seed, the
# declaration dropped from ifconfig, fails, as does a reach from a helper of erx_shell.
class CommandNeedsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  IFCONFIG = 'erlang/apps/erx_shell/src/erx_cmd_ifconfig.erl'
  STACK = { 'erlang/apps/erx_net/src/erx_net.erl' => "-module(erx_net).\n" }.freeze

  def tree
    paths = Dir.glob('erlang/apps/**/*.erl', base: ROOT).select { |path| Erx::CommandNeeds.reads?(path) }
    paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
  end

  def found(files) = Erx::CommandNeeds.violations(STACK.merge(files)).map { |violation| [violation.path, violation.line] }

  def command(body, needs: nil)
    ["-module(erx_cmd_seeded).\n-erx_command(seeded).\n-erx_usage(\"seeded\").\n",
     needs && "-erx_needs([#{needs}]).\n", body].join
  end

  def test_the_tree_passes_and_its_network_commands_declare_net
    files = tree
    assert_empty Erx::CommandNeeds.violations(files).map(&:to_s)
    %w[ifconfig ping host].each do |name|
      assert_match(/^-erx_needs\(\[net\]\)\.$/, files.fetch("erlang/apps/erx_shell/src/erx_cmd_#{name}.erl"))
    end
  end

  # The design's seed: -erx_needs dropped from ifconfig, which then reaches the stack
  # from a session that lacks the facet.
  def test_ifconfig_without_its_declaration_fails
    files = tree
    seeded = files.fetch(IFCONFIG).sub(/^-erx_needs\(\[net\]\)\.\n/, '')
    refute_equal files.fetch(IFCONFIG), seeded
    violations = Erx::CommandNeeds.violations(files.merge(IFCONFIG => seeded))
    assert_equal [IFCONFIG], violations.map(&:path)
    assert_match(/names erx_inet, of the net service, without -erx_needs\(\[net\]\)/, violations.first.to_s)
  end

  def test_socket_modules_resolver_functions_and_a_remote_fun_count
    path = 'erlang/apps/erx_shell/src/erx_cmd_seeded.erl'
    assert_equal [[path, 5]], found(path => command("run(_, _) ->\n    gen_udp:open(0).\n"))
    assert_equal [[path, 4]], found(path => command("run(_, _) -> inet:getaddr(\"h\", inet).\n"))
    assert_equal [[path, 5]], found(path => command("run(_, _) ->\n    F = fun erx_net :interfaces/0, F().\n"))
    assert_equal [[path, 4]], found(path => command("run(_, _) -> net:getaddrinfo(\"h\"), inet:getifaddrs().\n"))
  end

  def test_an_import_and_an_apply_of_a_stack_module_count
    path = 'erlang/apps/erx_shell/src/erx_cmd_seeded.erl'
    assert_equal [[path, 4]], found(path => command("-import(erx_net, [interfaces/0]).\nrun(_, _) -> interfaces().\n"))
    assert_equal [[path, 4]], found(path => command("run(_, _) -> apply(erx_net, interfaces, []).\n"))
    assert_empty found(path => command("run(_, _) -> apply(erx_net, interfaces, []).\n", needs: 'net').sub('[net]', 'net'))
  end

  def test_a_declared_facet_a_comment_a_string_and_a_pure_inet_call_pass
    path = 'erlang/apps/erx_session/src/erx_cmd_seeded.erl'
    assert_empty found(path => command("run(_, _) -> erx_net:interfaces().\n", needs: 'inspect, net'))
    body = "%% erx_net:interfaces()\nrun(_, _) -> io:put_chars(\"erx_net:x\"), inet:ntoa({1, 2, 3, 4}).\n"
    assert_empty found(path => command(body))
  end

  def test_a_module_of_erx_shell_that_is_no_command_fails_and_one_elsewhere_passes
    helper = "-module(seeded).\nf() -> erx_icmp_sock:open(#{}).\n"
    stack = { 'erlang/apps/erx_net/src/erx_icmp_sock.erl' => '' }
    assert_equal [['erlang/apps/erx_shell/src/seeded.erl', 2]],
                 found(stack.merge('erlang/apps/erx_shell/src/seeded.erl' => helper))
    assert_empty found(stack.merge('erlang/apps/erx/src/seeded.erl' => helper))
  end
end
