# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'erlang_text'
require_relative 'ns_places'

module Erx
  # The chokepoint that only a command declaring a service's facet reaches that service
  # (docs/design-shell.md, SH1; docs/design.md, "Chokepoint checks"). A command module,
  # an Erlang source of erlang/apps that declares -erx_command, that names a module of a
  # service of the system domain declares the service's facet with -erx_needs, so the
  # shell refuses it with no_facet before it starts in a session that lacks the facet,
  # and it never runs to crash on a module the session's release does not ship. Every
  # other module of the command shell's application, erx_shell, names no such module at
  # all, since neither the shell nor its helpers have authority of their own.
  #
  # A service's modules are the modules of its sources, path globs read from the
  # listing: the network stack's applications as erXos builds them (not erx_net/portable,
  # built only outside erXos, whose erx_bytes stands in for the erx application's), the
  # start service's application behind `start`, and the machine tree with its coordinator, the two modules of the domain
  # service behind `machine`. Each counts wherever its name stands as an atom: in a
  # call, a remote fun or type, an -import or an apply. The OTP modules and functions
  # through which any domain reaches the service count as Module:Function: for the
  # network stack, the socket modules, net and the resolver, whose sockets erXos's
  # inet backend opens through the stack (docs/design-network-stack.md, "The
  # backend"), and inet's functions that resolve names or read the interfaces. A
  # service whose tree erx_ns mounts (erx_ns:place/1, read through NsPlaces) is reached
  # by path too: a string literal that is the tree's mount point or a path beneath it,
  # as "/data/x" is of data's, counts as a name of the service; prose is never exactly
  # a path. A service of the svc interface, start and machine, is reached through
  # erx_svc_client, the one route to /svc (docs/design-app-trees.md, AT6): a call of its
  # read, command or open whose first argument is a string literal naming the service,
  # as reboot's erx_svc_client:command(<<"machine">>, ...) is, counts as a name of it.
  # Comments, other strings and quoted atoms are left out, so
  # 'erx_net':f(), an OTP function named through apply, and a path built from pieces
  # or written as a quoted atom, a triple-quoted string or another sigil form get past
  # it, as
  # do a name built from pieces and a call a command makes through a helper of another
  # application: like the other text rules it catches a slip. It is no boundary either:
  # a session's authority rests on its domain, whose release ships no service module
  # and whose sends to the system domain's registered names are dropped.
  module CommandNeeds
    SHELL = 'erlang/apps/erx_shell/src'
    SCOPE = %w[erlang/apps/*/src/*.erl].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    Service = Data.define(:sources, :modules, :functions)
    SERVICES = {
      'net' => Service.new(sources: %w[erlang/apps/erx_net/{src,erxos}/**/*.erl erlang/apps/erx_net_client/**/*.erl],
                           modules: %w[gen_tcp gen_udp gen_sctp socket net inet_res],
                           functions: %w[inet:getaddr inet:getaddrs inet:gethostbyname inet:gethostbyaddr
                                         inet:getifaddrs]),
      'start' => Service.new(sources: %w[erlang/apps/erx_starter/**/*.erl], modules: [], functions: []),
      'machine' => Service.new(sources: %w[erlang/apps/erx_domain/src/erx_machine{,_fs}.erl], modules: [],
                               functions: [])
    }.freeze
    COMMAND = /^-erx_command\s*\(/
    # -erx_needs([a, b]) or -erx_needs(a), as the compiler keeps either.
    NEEDS = /^-erx_needs\s*\(\s*\[?(?<names>[^\])]*)\]?\s*\)/
    ATOM = /(?<![A-Za-z0-9_@?])(?<atom>[a-z][A-Za-z0-9_@]*)(?![A-Za-z0-9_@])/
    CALL = /(?<![A-Za-z0-9_@?])(?<module>[a-z][A-Za-z0-9_@]*)\s*:\s*(?<function>[a-z][A-Za-z0-9_@]*)/
    # Where a module names a service: the service's facet, the line and the name.
    Reach = Data.define(:facet, :line, :name)
    # Each service's facet by the names that reach it: its sources' modules as
    # atoms, the OTP names as Module or Module:Function before a call, and its tree's
    # mount point as the start of a path.
    Names = Data.define(:atoms, :calls, :points)
    # A plain string literal, or one of the sigils ~, ~b and ~s with double quotes,
    # that holds an absolute path.
    PATH_LITERAL = %r{\A(?:~[bs]?)?"(?<path>/[^"\\]*)"\z}
    # A call of erx_svc_client that names a tree, in the skeleton, and the literal of
    # the tree's name that starts its arguments, in the code at the same offset.
    SVC_CALL = /(?<![A-Za-z0-9_@?])erx_svc_client\s*:\s*(?:read|command|open)\s*\(/
    SVC_NAME = /\G\s*(?:<<\s*)?(?:~[bs]?)?"(?<name>[^"\\]*)"/

    Violation = Data.define(:path, :line, :detail) do
      def to_s = "chokepoint command-needs: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # Whether the check reads path: a module it checks, or one of a service's.
    def reads?(path) = covers?(path) || !service_of(path).nil?

    # The facet of the service whose sources hold the module at path, nil for none.
    def service_of(path)
      return nil unless File.extname(path) == '.erl'

      SERVICES.find { |_, service| service.sources.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) } }&.first
    end

    # The violations among files, a map of path to source text. The services' modules
    # and erx_ns's places come from the same map, so it holds their sources too; a map
    # without erx_ns.erl, a test's own tree, has no paths to see, and the tree's own
    # seed (reboot without its declaration, in command_needs_test) proves the real
    # tree's erx_ns is read.
    def violations(files)
      names = names_of(files)
      files.select { |path, _| covers?(path) }.flat_map do |path, text|
        code = ErlangText.code(text)
        skeleton = blanked(code)
        if skeleton.match?(COMMAND)
          undeclared(path, code, skeleton, names)
        elsif File.dirname(path) == SHELL
          reaches(code, skeleton, names).map do |reach|
            Violation.new(path: path, line: reach.line,
                          detail: "names #{reach.name}, of the #{reach.facet} service, and is no command")
          end
        else
          []
        end
      end
    end

    def names_of(files)
      atoms = files.keys.filter_map { |path| service_of(path)&.then { |facet| [File.basename(path, '.erl'), facet] } }
      calls = SERVICES.flat_map { |facet, service| [*service.modules, *service.functions].map { |name| [name, facet] } }
      ns = files[NsPlaces::SOURCE]
      points = ns ? NsPlaces.points(ns).slice(*SERVICES.keys).invert : {}
      Names.new(atoms: atoms.to_h, calls: calls.to_h, points: points)
    end

    # The first reach of each service whose facet the command does not declare.
    def undeclared(path, code, skeleton, names)
      declared = skeleton.to_enum(:scan, NEEDS).flat_map { Regexp.last_match[:names].split(',').map(&:strip) }
      reaches(code, skeleton, names).reject { |reach| declared.include?(reach.facet) }.uniq(&:facet).map do |reach|
        Violation.new(path: path, line: reach.line,
                      detail: "names #{reach.name}, of the #{reach.facet} service, without -erx_needs([#{reach.facet}])")
      end
    end

    # Every place the code names a service, in line order: by a name in the skeleton, by
    # a path in one of the code's string literals, or by a tree erx_svc_client reaches.
    def reaches(code, skeleton, names)
      atoms = matches(skeleton, ATOM).filter_map do |found, line|
        facet = names.atoms[found[:atom]]
        next unless facet

        Reach.new(facet: facet, line: line, name: found[:atom])
      end
      calls = matches(skeleton, CALL).filter_map do |found, line|
        name = [found[:module], "#{found[:module]}:#{found[:function]}"].find { |candidate| names.calls.key?(candidate) }
        next unless name

        Reach.new(facet: names.calls.fetch(name), line: line, name: name)
      end
      paths = matches(code, ErlangText::LEXEME).filter_map do |found, line|
        path = PATH_LITERAL.match(found[:kept].to_s)&.[](:path)
        facet = path && facet_at(path, names.points)
        next unless facet

        Reach.new(facet: facet, line: line, name: path)
      end
      trees = matches(skeleton, SVC_CALL).filter_map do |found, line|
        name = SVC_NAME.match(code, found.end(0))&.[](:name)
        next unless SERVICES.key?(name)

        Reach.new(facet: name, line: line, name: "/svc/#{name}")
      end
      (atoms + calls + paths + trees).sort_by(&:line)
    end

    # The facet whose tree's mount point, among points, is path or a directory above it,
    # nil for none.
    def facet_at(path, points)
      points.find { |point, _| path == point || path.start_with?("#{point}/") }&.last
    end

    # Each match of pattern in text with the line it starts on.
    def matches(text, pattern)
      text.to_enum(:scan, pattern).map do
        found = Regexp.last_match
        [found, text[0, found.begin(0)].count("\n") + 1]
      end
    end

    # The code with every string, quoted atom and character blanked, lines kept, so
    # neither a name in a string nor a quoted needs list counts.
    def blanked(code)
      code.gsub(ErlangText::LEXEME) { Regexp.last_match(0).gsub(/[^\n]/, ' ') }
    end
  end
end
