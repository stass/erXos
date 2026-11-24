# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'set'
require_relative 'abi'
require_relative 'doc_links'
require_relative 'erlang_text'
require_relative 'error'
require_relative 'generation_plan'
require_relative 'manifest_frontend'
require_relative 'ns_writers'

module Erx
  # The table of cross-domain facets and the check that holds the code to it
  # (docs/design.md, "Chokepoint checks"; docs/design-abi.md, "Services, facets and
  # their parameter schemas"). A domain reaches a service of another domain only
  # through a facet, and every facet is declared in one place:
  #
  # * abi/services/*.txt declares each interface a facet can be of, and the first
  #   design citation in a file's header comment, (docs/<file>.md, "<heading>"), names the
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
  # * an interface file whose services cite no design section, or cite a section the
  #   document does not have;
  # * a manifest service whose interface no abi/services file declares, by name or by
  #   number;
  # * a facet name the Erlang sources use that is no manifest service's public name,
  #   under which its grantees hold its facets: a grant in a create spec handed to
  #   erx_domain:create/1 or in start_session/2's Start, less its display and
  #   default_display, which name services and are no facets, a lookup (erx:cap/1,
  #   erx_facets:find/1 and file_grant/2, erx_cmd:facet/2, a
  #   key read from erx:caps/0), a command's -erx_needs, a
  #   mount of {facet, Name}, a
  #   server's mint (erx_facet:provide/2 and serve/2, erx_driver_ctl's start_mint and
  #   mint_request, erx_fs_mint:start_link/3) and a mint request {erx_facet_mint, Tag, Name, ...}, each with its
  #   name written out. A session's lines, the interfaces abi/services declares served_by
  #   session, are no manifest service's and pass: a session provides each under its
  #   name and passes it to erx_domain:line/4, which mints it for the grantee the system
  #   domain names (docs/design-system.md, "A session's lines"). So do the interfaces
  #   declared served_by drive, whose grants are the manifest's drive window rows: the
  #   drive's serving domain provides a mint under the interface's name, and the media
  #   domain holds each facet as {drive, N} (docs/design-system.md, "A drive window as a
  #   grant"). Together they are the unrowed grants.
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
  # name is in that table: the funnel's one stopgap name, console, is a literal of its
  # own, pointing at the TODO.md item that declares it.
  # The manifests' own facet rows have no other line: the domain service trusts the
  # image's manifest and does not look its rows up at boot.
  module FacetNames
    SERVICES = 'abi/services/*.txt'
    MANIFESTS = 'config/manifest/*.txt'
    DOCS = 'docs/design*.md'
    SCOPE = ErlangText::SCOPE
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    # Facets the code uses with no abi/services interface: each one's TODO.md item,
    # which replaces or declares it, and the files that use it.
    Exemption = Data.define(:todo, :sites)
    APPS = 'erlang/apps'
    UNDECLARED = {
      'console' => Exemption.new(todo: 'docs/todo-domains.md, Bugs, "a facet of no manifest service": ' \
                                       'no system manifest service instantiates console',
                                 sites: ["#{APPS}/erx/src/erx_console.erl",
                                         "#{APPS}/erx_session/src/erx_session_tty.erl"]),
    }.freeze
    # The most names UNDECLARED may hold (exemption_violations/1).
    EXEMPTIONS_MAX = 1

    NAME = /[a-z][A-Za-z0-9_@]*/
    # The keys of start_session/2's Start that name services, not facets.
    START_SERVICES = %w[display default_display].freeze
    # The shapes of a use: each captures the facet name, or a list of them as names.
    USES = [
      /(?<![A-Za-z0-9_@])erx_domain\s*:\s*start_session\s*(?<args>\((?:[^()]|\g<args>)*\))/,
      /(?<![A-Za-z0-9_@])facets\s*=>\s*\#(?<map>\{(?:[^{}]|\g<map>)*\})/,
      /(?<![A-Za-z0-9_@])erx\s*:\s*cap\s*\(\s*(?<name>#{NAME})\s*\)/,
      /(?<![A-Za-z0-9_@])erx_facets\s*:\s*(?:find|file_grant)\s*\(\s*(?<name>#{NAME})\s*[,)]/,
      /(?<![A-Za-z0-9_@])erx_cmd\s*:\s*facet\s*\(\s*[A-Z_][A-Za-z0-9_@]*\s*,\s*(?<name>#{NAME})\s*\)/,
      /\#\{(?<names>[^{}]*?)\}\s*=\s*erx\s*:\s*caps\s*\(/,
      /\{\s*erx_facet_mint\s*,\s*[A-Za-z_][A-Za-z0-9_@]*\s*,\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])maps\s*:\s*(?:get|find|is_key)\s*\(\s*(?<name>#{NAME})\s*,\s*erx\s*:\s*caps\s*\(/,
      /(?<![A-Za-z0-9_@])erx_facet\s*:\s*(?:provide|serve)\s*\(\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])erx_driver_ctl\s*:\s*start_mint\s*\(\s*(?<name>#{NAME})\s*,/,
      /(?<![A-Za-z0-9_@])erx_fs_mint\s*:\s*start_link\s*\(\s*(?<name>#{NAME})\s*,/,
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
    # A design citation in an interface file's comment: (docs/<file>.md, "<heading>").
    CITATION = /(?<doc>docs\/[A-Za-z0-9_.-]+\.md),\s*"(?<heading>[^"]+)"/

    Interface = Data.define(:name, :number, :path, :line, :design)
    # A manifest facet row. Its grantee holds it under name, its service's public name
    # (docs/design-abi.md, "Services, facets and their parameter schemas"); label is the
    # row's own public name, unique per grantee, which no lookup uses.
    Facet = Data.define(:name, :label, :server, :interface, :grantee, :path, :line)
    # unrowed is the set of the names of the unrowed grants' interfaces (unrowed_names/1).
    Table = Data.define(:interfaces, :facets, :services, :unrowed) do
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
      found, violations = table(inputs, unrowed: unrowed_names(root))
      raise Error, "the facet table has violations:\n#{violations.join("\n")}" unless violations.empty?

      # A declared name keeps no exemption, so no waiver outlives its declaration, and
      # a name is a facet or a line, not both.
      both = found.names.to_a & (UNDECLARED.keys + found.unrowed.to_a)
      raise Error, "facet names both declared and exempt or unrowed: #{both.sort.join(', ')}" unless both.empty?

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
        %% Generated by tools/lib/erx/facet_names.rb from abi/services/*.txt,
        %% and config/manifest/*.txt. Do not edit this file.
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
    # the table's files, to its text; docs maps a design document's path to its text;
    # unrowed names the unrowed grants' interfaces (unrowed_names/1).
    def violations(files, docs:, unrowed:)
      table, table_violations = table(files, unrowed: unrowed)
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

    # The names of the unrowed grants' interfaces: those the ABI beneath root declares
    # served_by session, as the generated ?ERX_LINES names them.
    def unrowed_names(root)
      schema = ABI::Model.validate(ABI::Sources.read(root: root))
      (schema.session_lines + schema.drive_grants).to_set { |service| service.fetch(:name) }
    end

    # The table read from files, with lines, and the violations of its manifest's interfaces.
    def table(files, unrowed:)
      interfaces = files.select { |path, _| File.fnmatch?(SERVICES, path, GLOB_FLAGS) }.sort.flat_map do |path, text|
        interfaces_of(path, text)
      end
      records = files.select { |path, _| File.fnmatch?(MANIFESTS, path, GLOB_FLAGS) }.sort.flat_map do |path, text|
        Manifest::Frontend.records(text, path: path)
      end
      services = records.select { |record| record.kind == 'service' }.to_h { |record| [record.name, record] }
      unknown = services.values.reject { |record| interface_of(record, interfaces) }.map do |record|
        Violation.new(path: record.line.path, line: record.line.number,
                      detail: "service #{record.name}'s interface #{field(record, 'interface')} " \
                              'is no interface abi/services declares')
      end
      facets = records.select { |record| record.kind == 'facet' }.map { |record| facet_of(record, services, interfaces) }
      public_services = services.values.to_h { |record| [public_name(record), record] }
      [Table.new(interfaces: interfaces, facets: facets, services: public_services, unrowed: unrowed.to_set), unknown]
    end

    # An interface file's services, each with the file's first design citation.
    def interfaces_of(path, text)
      cited = text.each_line.take_while { |line| line.start_with?('#') }.join.gsub(/\n#\s*/, ' ')
      design = CITATION.match(cited)&.then { |found| [found[:doc], found[:heading]] }
      text.each_line.with_index(1).filter_map do |line, number|
        found = /\Aservice\s+(?<name>\S+)\s+(?<number>\d+)\s*\z/.match(line.strip)
        next unless found

        Interface.new(name: found[:name], number: Integer(found[:number], 10), path: path, line: number,
                      design: design)
      end
    end

    # The words of field in a manifest record (Manifest::Frontend.records), or nil when
    # it has none.
    def field(record, key) = record.properties[key]&.map(&:value)&.join(' ')

    # The name a manifest record's grantees hold it under: its name field, else its own.
    def public_name(record) = field(record, 'name') || record.name

    # The interface a manifest service names, by name or by number, or nil.
    def interface_of(record, interfaces)
      token = field(record, 'interface')
      interfaces.find { |interface| interface.name == token || interface.number.to_s == token }
    end

    def facet_of(record, services, interfaces)
      service = services[field(record, 'service').delete_prefix('@service.')]
      Facet.new(name: service && public_name(service), label: public_name(record),
                server: service && field(service, 'server'),
                interface: service && interface_of(service, interfaces)&.name,
                grantee: field(record, 'grantee'), path: record.line.path, line: record.line.number)
    end

    # The design citations of the interfaces: each must name a section of its document,
    # as every citation must (DocLinks).
    def design_violations(table, docs)
      table.interfaces.filter_map do |interface|
        doc, heading = interface.design
        if doc.nil?
          Violation.new(path: interface.path, line: interface.line,
                        detail: "service #{interface.name}'s file cites no design section " \
                                '(docs/<file>.md, "<heading>") in its header comment')
        elsif !DocLinks.sections(docs.fetch(doc, '')).named?(heading)
          Violation.new(path: interface.path, line: interface.line,
                        detail: "service #{interface.name} cites #{doc}, \"#{heading}\", which names no section")
        end
      end
    end

    # Each facet name path uses: [path, line, name].
    def uses(path, text)
      skeleton = NsWriters.blanked(ErlangText.code(text))
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
      return start_facets(found[:args]) if found.names.include?('args')

      list = found[:names]
      list.include?(':=') ? list.scan(KEY).flatten : list.scan(/(?<![A-Za-z0-9_@])#{NAME}/)
    end

    # The facets a start_session/2 call hands on: its Start map's keys less display and
    # default_display, as the domain service's funnel takes them (erx_domain_srv:session_start/3).
    def start_facets(args) = args[1..-2].scan(MAP).flat_map { |(map)| keys(map) } - START_SERVICES

    # The keys of a map literal, {...}, at its own level: nested groups are dropped
    # first, so a key of a facet's limits is no facet.
    def keys(map)
      inner = map[1..-2]
      inner = inner.gsub(NESTED, ' ') while inner.match?(NESTED)
      inner.scan(GRANT).flatten
    end

    # A name outside the table and the unrowed grants, or an exempt name used outside its listed
    # files.
    def use_violations(uses, table)
      allowed = table.names | table.unrowed
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
