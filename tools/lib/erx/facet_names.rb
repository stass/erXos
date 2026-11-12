# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'device_callers'
require_relative 'error'
require_relative 'generation_plan'
require_relative 'ns_writers'

module Erx
  # The table of cross-domain facets and the check that holds the code to it
  # (docs/design.md, "Chokepoint checks"; docs/design-abi.md, "Services, facets and
  # their parameter schemas"). A domain reaches a service of another domain only
  # through a facet, and every facet is declared in one place:
  #
  # * abi/services/*.txt declares each interface a facet can be of, and the first
  #   design citation in a file's header comment, (docs/FILE.md, "Heading"), names the
  #   section that justifies every interface the file declares;
  # * the system manifest, config/manifest/*.txt, instantiates them: a service row
  #   names its server and its interface, a facet row its grantee, its service and its
  #   public name.
  #
  # The table's rows are therefore the manifest's facets, each with its service's
  # server and interface and that interface's design section (table/1). The check
  # binds names, not grantees: which domain may hold a facet is the manifest reader's
  # to check (Manifest, normalize_facets). It refuses:
  #
  # * an interface file whose services cite no design section, or cite a heading the
  #   document does not have;
  # * a manifest service whose interface no abi/services file declares, by name or by
  #   number;
  # * a facet name the Erlang sources use that is no manifest service's public name,
  #   under which its grantees hold its facets: a grant in a create spec handed to
  #   erx_domain:create/1 or start_session/2, a lookup (erx:cap/1, erx_cmd:facet/2, a
  #   key read from erx:caps/0 or erx_facets:domain/0), a command's -erx_needs, a
  #   mount of {facet, Name}, a
  #   server's mint (erx_facet:provide/2 and serve/2, erx_driver_ctl's start_mint and
  #   mint_request) and a mint request {erx_facet_mint, Tag, Name, ...}, each with its
  #   name written out.
  #
  # UNDECLARED lists the facets the code uses that no interface declares, each with
  # its TODO.md item and the files that may use it; a use in another file fails, and so
  # does a listed file that no longer uses it. The list is a stopgap that only shrinks
  # (docs/design-domains.md, "Facets"): it holds exactly EXEMPTIONS_MAX names, a
  # bound lowered in the same change that removes an exemption and never raised. The
  # sources are
  # read with comments, strings and quoted atoms blanked, so
  # prose never counts as a use; like the other text rules this catches a slip, not a
  # name built at run time or passed in a variable.
  #
  # The check is the second line. The first is the domain service's funnel,
  # erx_domain_srv:facets/2, which refuses a key outside the table it is built with: the
  # manifests' public service names, generated into HEADER (generation/1). No exempt
  # name is in that table: the funnel's two stopgap names, console and log, are literals
  # of its own, each pointing at the TODO.md item that removes it.
  # The manifests' own facet rows have no other line: the domain service trusts the
  # image's manifest and does not look its rows up at boot.
  module FacetNames
    SERVICES = 'abi/services/*.txt'
    MANIFESTS = 'config/manifest/*.txt'
    DOCS = 'docs/design*.md'
    SCOPE = DeviceCallers::SCOPE
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    # Facets the code uses with no abi/services interface: each one's TODO.md item,
    # which replaces or declares it, and the files that use it.
    Exemption = Data.define(:todo, :sites)
    APPS = 'erlang/apps'
    UNDECLARED = {
      'log' => Exemption.new(todo: 'TODO.md, Bugs, "the inspect service": the kernel log is to be ' \
                                   'read as the inspection path [kernel, log] through the inspect facet',
                             sites: ["#{APPS}/erx/src/erx_log_records.erl"]),
      'console' => Exemption.new(todo: 'TODO.md, Bugs, "two facets of no declared interface": ' \
                                       'abi/services/console.txt declares no service',
                                 sites: ["#{APPS}/erx/src/erx_console.erl",
                                         "#{APPS}/erx_session/src/erx_session_tty.erl"]),
      'web_line' => Exemption.new(todo: 'TODO.md, Bugs, "two facets of no declared interface": an export of ' \
                                        'the session\'s line that rides the facet registry',
                                  sites: ["#{APPS}/erx_web_line/src/erx_web_line_app.erl"])
    }.freeze
    # The most names UNDECLARED may hold (exemption_violations/1).
    EXEMPTIONS_MAX = 3

    NAME = /[a-z][A-Za-z0-9_@]*/
    # The shapes of a use: each captures the facet name, or a list of them as names.
    USES = [
      /(?<![A-Za-z0-9_@])erx_domain\s*:\s*start_session\s*(?<args>\((?:[^()]|\g<args>)*\))/,
      /(?<![A-Za-z0-9_@])facets\s*=>\s*\#(?<map>\{(?:[^{}]|\g<map>)*\})/,
      /(?<![A-Za-z0-9_@])erx\s*:\s*cap\s*\(\s*(?<name>#{NAME})\s*\)/,
      /(?<![A-Za-z0-9_@])erx_cmd\s*:\s*facet\s*\(\s*[A-Z_][A-Za-z0-9_@]*\s*,\s*(?<name>#{NAME})\s*\)/,
      /(?<![A-Za-z0-9_@])maps\s*:\s*(?:get|find|is_key)\s*\(\s*(?<name>#{NAME})\s*,\s*erx_facets\s*:\s*domain\s*\(/,
      /\#\{(?<names>[^{}]*?)\}\s*=\s*erx_facets\s*:\s*domain\s*\(/,
      /\{\s*erx_facet_mint\s*,\s*[A-Za-z_][A-Za-z0-9_@]*\s*,\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])maps\s*:\s*(?:get|find|is_key)\s*\(\s*(?<name>#{NAME})\s*,\s*erx\s*:\s*caps\s*\(/,
      /(?<![A-Za-z0-9_@])erx_facet\s*:\s*(?:provide|serve)\s*\(\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])erx_driver_ctl\s*:\s*start_mint\s*\(\s*(?<name>#{NAME})\s*,/,
      /\{\s*erx_driver_ctl\s*,\s*start_mint\s*,\s*\[\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])erx_driver_ctl\s*:\s*mint_request\s*\(\s*[A-Za-z_][A-Za-z0-9_@]*\s*,\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])erx_ns\s*:\s*mount\s*\(\s*\{\s*facet\s*,\s*(?<name>#{NAME})\s*\}/,
      /^-erx_needs\s*\(\s*\[?(?<names>[^\])]*)\]?\s*\)/
    ].freeze
    # A map in a call's arguments, and a group nested in a map.
    MAP = /\#(?<map>\{(?:[^{}]|\g<map>)*\})/
    NESTED = /\{[^{}]*\}|\([^()]*\)/
    # A key of a map built in a create spec, Key => Value.
    GRANT = /(?<![A-Za-z0-9_@])(?<name>#{NAME})\s*=>/
    # A key of a map pattern, Key := Value.
    KEY = /(?<![A-Za-z0-9_@])(?<name>#{NAME})\s*:=/
    # A design citation in an interface file's comment: (docs/FILE.md, "Heading").
    CITATION = /(?<doc>docs\/[A-Za-z0-9_.-]+\.md),\s*"(?<heading>[^"]+)"/

    Interface = Data.define(:name, :number, :path, :line, :design)
    # A manifest facet row. Its grantee holds it under name, its service's public name
    # (docs/design-abi.md, "Services, facets and their parameter schemas"); label is the
    # row's own public name, unique per grantee, which no lookup uses.
    Facet = Data.define(:name, :label, :server, :interface, :grantee, :path, :line)
    Table = Data.define(:interfaces, :facets, :services) do
      # Every name a use may give: a manifest service's public name, under which its
      # grantees hold its facets and its server mints them.
      def names = services.keys.to_set
    end
    Violation = Data.define(:path, :line, :detail) do
      def to_s = "chokepoint facet-names: #{path}#{line ? ":#{line}" : ''}: #{detail}"
    end

    # The funnel's table, an Erlang header in erx_domain's generated include.
    HEADER = 'erlang/apps/erx_domain/include/generated/erx_facet_names.hrl'

    module_function

    # The plan Erx::Generated publishes into the build tree: HEADER, from the interfaces
    # and the manifests, which the globs discover. UNDECLARED, which is code and so in the
    # tree's stamp, adds no name to it. A table with a violation generates nothing.
    def generation(root:)
      root = File.expand_path(root)
      globs = [SERVICES, MANIFESTS].to_h { |glob| [glob, Dir.glob(glob, base: root).sort] }
      raise Error, "no system manifest matches #{MANIFESTS}" if globs.fetch(MANIFESTS).empty?

      inputs = globs.values.flatten.to_h { |relative| [relative, File.binread(File.join(root, relative))] }
      found, violations = table(inputs)
      raise Error, "the facet table has violations:\n#{violations.join("\n")}" unless violations.empty?

      # A declared name keeps no exemption, so no waiver outlives its declaration.
      both = found.names.to_a & UNDECLARED.keys
      raise Error, "facet names both declared and exempt in UNDECLARED: #{both.sort.join(', ')}" unless both.empty?

      GenerationPlan.new(files: { HEADER => header(found.names).freeze },
                         reads: inputs.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) },
                         globs: globs)
    rescue SystemCallError => error
      raise Error, "cannot read the facet table's files: #{error.message}"
    end

    # The header naming each of names once, sorted, as an Erlang list of quoted atoms, so
    # a name that is a reserved word is an atom too.
    def header(names)
      atoms = names.to_set.sort
      bad = atoms.grep_v(/\A#{NAME}\z/)
      raise Error, "facet names outside #{NAME.source}: #{bad.join(', ')}" unless bad.empty?

      <<~ERLANG
        %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
        %% SPDX-License-Identifier: BSD-2-Clause
        %% Generated by tools/lib/erx/facet_names.rb from abi/services/*.txt and
        %% config/manifest/*.txt. Do not edit this file.
        -ifndef(ERX_FACET_NAMES_HRL).
        -define(ERX_FACET_NAMES_HRL, true).

        %% The names a facet may enter a domain's table under (docs/design-domains.md,
        %% "Facets"): each system manifest service's public name, and no other.
        -define(ERX_FACET_NAMES, [#{atoms.map { |atom| "'#{atom}'" }.join(', ')}]).

        -endif.
      ERLANG
    end

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # Whether path is one of the table's own files.
    def table_file?(path) = [SERVICES, MANIFESTS].any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # Whether path is a design document a citation can name.
    def design_doc?(path) = File.fnmatch?(DOCS, path, GLOB_FLAGS)

    # The violations of the tree: files maps each path the check reads, sources and
    # the table's files, to its text; docs maps a design document's path to its text.
    def violations(files, docs:)
      table, table_violations = table(files)
      used = files.select { |path, _| covers?(path) }.flat_map { |path, text| uses(path, text) }
      table_violations + design_violations(table, docs) + use_violations(used, table) + stale_exemptions(used) +
        exemption_violations(UNDECLARED)
    end

    # A list of exemptions of any length but EXEMPTIONS_MAX, which is refused: the
    # exemptions are a stopgap that only shrinks, so a longer list needs its facet
    # declared instead, and a shorter one takes the bound down with it, leaving no room
    # for a later name.
    def exemption_violations(exemptions)
      return [] if exemptions.size == EXEMPTIONS_MAX

      advice = if exemptions.size > EXEMPTIONS_MAX
                 'the exemptions only shrink; declare the facet instead'
               else
                 'lower EXEMPTIONS_MAX to match'
               end
      [Violation.new(path: 'tools/lib/erx/facet_names.rb', line: nil,
                     detail: "UNDECLARED holds #{exemptions.size} names, not EXEMPTIONS_MAX (#{EXEMPTIONS_MAX}): #{advice}")]
    end

    # The table read from files, and the violations of its manifest's interfaces.
    def table(files)
      interfaces = files.select { |path, _| File.fnmatch?(SERVICES, path, GLOB_FLAGS) }.sort.flat_map do |path, text|
        interfaces_of(path, text)
      end
      records = files.select { |path, _| File.fnmatch?(MANIFESTS, path, GLOB_FLAGS) }.sort.flat_map do |path, text|
        records_of(path, text)
      end
      services = records.select { |record| record.fetch(:kind) == 'service' }.to_h do |record|
        [record.fetch(:alias), record]
      end
      unknown = services.values.reject { |record| interface_of(record, interfaces) }.map do |record|
        Violation.new(path: record.fetch(:path), line: record.fetch(:line),
                      detail: "service #{record.fetch(:alias)}'s interface #{record.fetch(:props)['interface']} " \
                              'is no interface abi/services declares')
      end
      facets = records.select { |record| record.fetch(:kind) == 'facet' }.map do |record|
        facet_of(record, services, interfaces)
      end
      public_services = services.values.to_h { |record| [record.fetch(:props).fetch('name', record.fetch(:alias)), record] }
      [Table.new(interfaces: interfaces, facets: facets, services: public_services), unknown]
    end

    # An interface file's services, each with the file's first design citation.
    def interfaces_of(path, text)
      cited = text.each_line.take_while { |line| line.start_with?('#') }.join.gsub(/\n#\s*/, ' ')
      design = CITATION.match(cited)&.then { |found| [found[:doc], found[:heading]] }
      text.each_line.with_index(1).filter_map do |line, number|
        found = /\Aservice\s+(?<name>\S+)\s+(?<number>\d+)\s*\z/.match(line.strip)
        found && Interface.new(name: found[:name], number: Integer(found[:number], 10), path: path, line: number,
                               design: design)
      end
    end

    # The manifest's service and facet records: a record starts in the first column,
    # its properties are indented, and a comment starts with #.
    def records_of(path, text)
      text.each_line.with_index(1).each_with_object([]) do |(line, number), records|
        next if line.strip.empty? || line.lstrip.start_with?('#')

        if line.start_with?(' ')
          key, value = line.strip.split(/\s+/, 2)
          records.last&.fetch(:props)&.store(key, value.to_s.delete_prefix('"').delete_suffix('"'))
        else
          kind, name = line.split
          records << { kind: kind, alias: name, path: path, line: number, props: {} }
        end
      end.select { |record| %w[service facet].include?(record.fetch(:kind)) }
    end

    # The interface a manifest service names, by name or by number, or nil.
    def interface_of(record, interfaces)
      token = record.fetch(:props)['interface']
      interfaces.find { |interface| interface.name == token || interface.number.to_s == token }
    end

    def facet_of(record, services, interfaces)
      props = record.fetch(:props)
      service = services[props['service'].to_s.delete_prefix('@service.')]
      Facet.new(name: service && service.fetch(:props).fetch('name', service.fetch(:alias)),
                label: props.fetch('name', record.fetch(:alias)),
                server: service&.fetch(:props)&.fetch('server', 'system'),
                interface: service && interface_of(service, interfaces)&.name,
                grantee: props['grantee'], path: record.fetch(:path), line: record.fetch(:line))
    end

    # The design citations of the interfaces: each must name a heading of its document.
    def design_violations(table, docs)
      table.interfaces.filter_map do |interface|
        doc, heading = interface.design
        if doc.nil?
          Violation.new(path: interface.path, line: interface.line,
                        detail: "service #{interface.name}'s file cites no design section " \
                                '(docs/FILE.md, "Heading") in its header comment')
        elsif !headings(docs.fetch(doc, '')).include?(plain(heading))
          Violation.new(path: interface.path, line: interface.line,
                        detail: "service #{interface.name} cites #{doc}, \"#{heading}\", which has no such heading")
        end
      end
    end

    # A document's headings, with code marks dropped as a citation writes them.
    def headings(text) = text.each_line.filter_map { |line| line[/\A#+\s+(.*?)\s*\z/, 1]&.then { plain(_1) } }.to_set

    def plain(heading) = heading.delete('`').squeeze(' ').strip

    # Each facet name path uses: [path, line, name].
    def uses(path, text)
      skeleton = NsWriters.blanked(DeviceCallers.code(text))
      USES.flat_map do |shape|
        skeleton.to_enum(:scan, shape).flat_map do
          found = Regexp.last_match
          line = skeleton[0, found.begin(0)].count("\n") + 1
          names_in(found).map { |name| [path, line, name] }
        end
      end.sort_by { |_, line, _| line }
    end

    def names_in(found)
      return [found[:name]] if found.names.include?('name')
      return keys(found[:map]) if found.names.include?('map')
      return found[:args][1..-2].scan(MAP).flat_map { |(map)| keys(map) } if found.names.include?('args')

      list = found[:names]
      list.include?(':=') ? list.scan(KEY).flatten : list.scan(/(?<![A-Za-z0-9_@])#{NAME}/)
    end

    # A name outside the table, or an exempt name used outside its listed files.
    # The keys of a map literal, {...}, at its own level: nested groups are dropped
    # first, so a key of a facet's limits is no facet.
    def keys(map)
      inner = map[1..-2]
      inner = inner.gsub(NESTED, ' ') while inner.match?(NESTED)
      inner.scan(GRANT).flatten
    end

    def use_violations(uses, table)
      allowed = table.names
      uses.reject { |path, _, name| allowed.include?(name) || UNDECLARED[name]&.sites&.include?(path) }
          .map do |path, line, name|
        detail = if UNDECLARED.key?(name)
                   "facet #{name} is undeclared and exempt only in its listed files (#{UNDECLARED[name].todo})"
                 else
                   "facet #{name} is no system manifest service of an abi/services interface: declare it with " \
                     'its design section'
                 end
        Violation.new(path: path, line: line, detail: detail)
      end
    end

    # A listed file of an exemption that no longer uses its name.
    def stale_exemptions(uses)
      used = uses.to_set { |path, _, name| [path, name] }
      UNDECLARED.flat_map do |name, exemption|
        exemption.sites.reject { |path| used.include?([path, name]) }.map do |path|
          Violation.new(path: 'tools/lib/erx/facet_names.rb', line: nil,
                        detail: "the undeclared facet #{name} is no longer used in #{path}: remove it from UNDECLARED")
        end
      end
    end
  end
end
