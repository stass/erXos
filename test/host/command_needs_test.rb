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
  NS = "place(data) -> {<<\"/data\">>, [rw]};\nplace(_Name) -> none.\n"
  STACK = { 'erlang/apps/erx_net/src/erx_net.erl' => "-module(erx_net).\n", Erx::NsPlaces::SOURCE => NS }.freeze

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

  # The system domain's own services count as the network stack does: reboot, which
  # reaches the machine by its path, fails without its machine declaration, as does a
  # helper of erx_shell that names the start service's tree, while a module of the
  # domain service beside the machine tree's two is no reach of machine.
  def test_the_machine_and_start_services_count
    files = tree
    reboot = 'erlang/apps/erx_shell/src/erx_cmd_reboot.erl'
    seeded = files.fetch(reboot).sub(/^-erx_needs\(\[machine\]\)\.\n/, '')
    refute_equal files.fetch(reboot), seeded
    violations = Erx::CommandNeeds.violations(files.merge(reboot => seeded))
    assert_equal [reboot], violations.map(&:path)
    assert_match(%r{names /svc/machine, of the machine service, without -erx_needs\(\[machine\]\)},
                 violations.first.to_s)
    helper = "-module(seeded).\nf() -> erx_starter_fs:control(<<>>).\n"
    starter = { 'erlang/apps/erx_starter/src/erx_starter_fs.erl' => '' }
    assert_equal [['erlang/apps/erx_shell/src/seeded.erl', 2]],
                 found(starter.merge('erlang/apps/erx_shell/src/seeded.erl' => helper))
    coordinator = { 'erlang/apps/erx_domain/src/erx_machine.erl' => '' }
    assert_equal [['erlang/apps/erx_shell/src/seeded.erl', 2]],
                 found(coordinator.merge('erlang/apps/erx_shell/src/seeded.erl' =>
                                           "-module(seeded).\nf() -> erx_machine:request(reboot, system).\n"))
    domain = { 'erlang/apps/erx_domain/src/erx_domain.erl' => '' }
    assert_empty found(domain.merge('erlang/apps/erx_shell/src/seeded.erl' => "-module(seeded).\nf() -> erx_domain:f().\n"))
  end

  # A path in a string literal reaches the service whose tree erx_ns mounts at its
  # place, the mount point itself included, from a command or a helper of erx_shell; a
  # declared facet, a doc string, a comment, a longer name and a path below none do not.
  # A tree of the svc interface is reached through erx_svc_client by its name, which
  # counts in any of the literal's forms; another name, a name held in a variable and a
  # comment do not.
  def test_a_path_under_a_services_mount_point_counts
    path = 'erlang/apps/erx_shell/src/erx_cmd_seeded.erl'
    # A place the fixture gives start, which has none in the tree, since start is reached
    # through /svc.
    places = { Erx::NsPlaces::SOURCE => "place(start) -> {<<\"/start\">>, [rw]};\nplace(_Name) -> none.\n" }
    assert_equal [[path, 5]], found(places.merge(path => command("run(_, _) ->\n    file:write_file(<<\"/start/ctl\">>, <<>>).\n")))
    assert_equal [[path, 4]], found(places.merge(path => command("run(_, _) -> file:list_dir(~\"/start\").\n")))
    assert_empty found(places.merge(path => command("run(_, _) -> file:read_file(\"/start/ctl\").\n", needs: 'start')))
    quiet = "-doc \"\"\"\nWrites `/start/ctl`.\n\"\"\".\n%% \"/start/ctl\"\n" \
            "run(_, _) -> file:read_file(\"/started\"), file:read_file(\"/data/x\").\n"
    assert_empty found(places.merge(path => command(quiet)))
    assert_equal [[path, 4]], found(path => command("run(_, _) -> erx_svc_client:command(<<\"machine\">>, <<>>, 0).\n"))
    assert_equal [[path, 5]], found(path => command("run(_, _) ->\n    erx_svc_client:read(~\"start\", <<\"status\">>, 1, 0).\n"))
    assert_equal [['erlang/apps/erx_shell/src/seeded.erl', 2]],
                 found('erlang/apps/erx_shell/src/seeded.erl' => "-module(seeded).\nf() -> erx_svc_client:open(\"machine\", <<\"ctl\">>, []).\n")
    assert_empty found(path => command("run(_, _) -> erx_svc_client:command(<<\"machine\">>, <<>>, 0).\n", needs: 'machine'))
    other = "%% erx_svc_client:command(<<\"start\">>, L, 0)\n" \
            "run(_, _) -> erx_svc_client:command(<<\"bluetooth\">>, <<>>, 0), erx_svc_client:command(N, <<>>, 0).\n"
    assert_empty found(path => command(other))
  end
end
