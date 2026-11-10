# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

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
  # A service's modules are its applications' modules, read from the listing, each of
  # which counts wherever its name stands as an atom: in a call, a remote fun or type,
  # an -import or an apply. The OTP modules and functions through which any domain
  # reaches the service count as Module:Function: for the network stack, the socket
  # modules, net and the resolver, whose sockets erXos's inet backend opens through the
  # stack (docs/design-network-stack.md, "The backend"), and inet's functions that
  # resolve names or read the interfaces. Comments, strings and quoted atoms are left
  # out, so 'erx_net':f() and an OTP function named through apply get past it, as do a
  # name built from pieces and a call a command makes through a helper of another
  # application: like the other text rules it catches a slip. It is no boundary either:
  # a session's authority rests on its domain, whose release ships no service module
  # and whose sends to the system domain's registered names are dropped.
  module CommandNeeds
    SHELL = 'erlang/apps/erx_shell/src'
    SCOPE = %w[erlang/apps/*/src/*.erl].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    Service = Data.define(:applications, :modules, :functions)
    SERVICES = {
      'net' => Service.new(applications: %w[erlang/apps/erx_net erlang/apps/erx_net_client],
                           modules: %w[gen_tcp gen_udp gen_sctp socket net inet_res],
                           functions: %w[inet:getaddr inet:getaddrs inet:gethostbyname inet:gethostbyaddr
                                         inet:getifaddrs])
    }.freeze
    COMMAND = /^-erx_command\s*\(/
    # -erx_needs([a, b]) or -erx_needs(a), as the compiler keeps either.
    NEEDS = /^-erx_needs\s*\(\s*\[?(?<names>[^\])]*)\]?\s*\)/
    ATOM = /(?<![A-Za-z0-9_@?])(?<atom>[a-z][A-Za-z0-9_@]*)(?![A-Za-z0-9_@])/
    CALL = /(?<![A-Za-z0-9_@?])(?<module>[a-z][A-Za-z0-9_@]*)\s*:\s*(?<function>[a-z][A-Za-z0-9_@]*)/
    # Where a module names a service: the service's facet, the line and the name.
    Reach = Data.define(:facet, :line, :name)
    # Each service's facet by the names that reach it: its applications' modules as
    # atoms, and the OTP names as Module or Module:Function before a call.
    Names = Data.define(:atoms, :calls)

    Violation = Data.define(:path, :line, :detail) do
      def to_s = "chokepoint command-needs: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # Whether the check reads path: a module it checks, or one of a service's.
    def reads?(path) = covers?(path) || !service_of(path).nil?

    # The facet of the service whose application holds the module at path, nil for none.
    def service_of(path)
      return nil unless File.extname(path) == '.erl'

      SERVICES.find { |_, service| service.applications.any? { |root| path.start_with?("#{root}/") } }&.first
    end

    # The violations among files, a map of path to source text. The services' modules
    # come from the same map, so it holds their applications' sources too.
    def violations(files)
      names = names_of(files.keys)
      files.select { |path, _| covers?(path) }.flat_map do |path, text|
        skeleton = blanked(DeviceCallers.code(text))
        if skeleton.match?(COMMAND)
          undeclared(path, skeleton, names)
        elsif File.dirname(path) == SHELL
          reaches(skeleton, names).map do |reach|
            Violation.new(path: path, line: reach.line,
                          detail: "names #{reach.name}, of the #{reach.facet} service, and is no command")
          end
        else
          []
        end
      end
    end

    def names_of(paths)
      atoms = paths.filter_map { |path| service_of(path)&.then { |facet| [File.basename(path, '.erl'), facet] } }
      calls = SERVICES.flat_map { |facet, service| [*service.modules, *service.functions].map { |name| [name, facet] } }
      Names.new(atoms: atoms.to_h, calls: calls.to_h)
    end

    # The first reach of each service whose facet the command does not declare.
    def undeclared(path, skeleton, names)
      declared = skeleton.to_enum(:scan, NEEDS).flat_map { Regexp.last_match[:names].split(',').map(&:strip) }
      reaches(skeleton, names).reject { |reach| declared.include?(reach.facet) }.uniq(&:facet).map do |reach|
        Violation.new(path: path, line: reach.line,
                      detail: "names #{reach.name}, of the #{reach.facet} service, without -erx_needs([#{reach.facet}])")
      end
    end

    # Every place the skeleton names a service, in line order.
    def reaches(skeleton, names)
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
      (atoms + calls).sort_by(&:line)
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
      code.gsub(DeviceCallers::LEXEME) { Regexp.last_match(0).gsub(/[^\n]/, ' ') }
    end
  end
end
