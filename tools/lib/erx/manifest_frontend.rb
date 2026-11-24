# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_source'
require_relative 'error'

module Erx
  # The system manifest's one reader and printer (Frontend), and the records it reads.
  # It stands apart from the manifest check (manifest.rb), which needs the generated
  # ABI, so the build's own generators read the manifest with it too (FacetNames).
  module Manifest
    # A manifest the check refuses: field names what the refusal is about, a record and
    # field of the manifest, or context.NAME for the build's checked context, and the
    # message says what is wrong with it.
    class Invalid < Erx::Error
      attr_reader :field

      def initialize(message, field:)
        @field = field.freeze
        super("manifest #{field}: #{message}")
      end
    end

    # The form of a field Record#decimal reads: digits, no sign, no base prefix.
    DECIMAL = /\A[0-9]+\z/.freeze
    # One record of a manifest as Frontend reads it: its kind, its name (nil for NAMELESS
    # kinds and a directive), each field's tokens, a facet's parameters and its first
    # line. A field is read as one value of a type, and a field that is absent or holds
    # anything else is refused, so a reader never mistakes one form for another.
    Record = Struct.new(:kind, :name, :properties, :parameters, :line, keyword_init: true) do
      # The record's first line, its kind then its name or a directive's arguments:
      # "machine", "principal system", "introduce @domain.a @domain.b".
      def header = [kind, name || properties['targets']&.map(&:value)&.join(' ')].compact.join(' ')

      # The decimal number of field.
      def decimal(field)
        token = one(field, 'a decimal number') { |only| !only.quoted && only.value.match?(DECIMAL) }
        Integer(token.value, 10)
      end

      # The one quoted token of field, as a string.
      def string(field) = one(field, 'one string', &:quoted).value

      # The one unquoted token of field, as a string: a reference (@kind.name) or a word.
      def reference(field) = one(field, 'one reference') { |only| !only.quoted }.value

      private

      def one(field, form)
        tokens = properties.fetch(field) { raise Error, "the manifest's #{header} record has no #{field} field" }
        raise Error, "the manifest's #{header} #{field} is not #{form}" unless tokens.size == 1 && yield(tokens.first)

        tokens.first
      end
    end
    Source = Struct.new(:version, :machine, :records, keyword_init: true)

    module Frontend
      FIELDS = {
        'machine' => %w[flags host console hostlink platform root_memory system_baseline system_share users_share system_principal max_domains max_connections system_lane system_queue peer_held system_reserve sealing system_runtime_limits native_limits system_args boot_timeout_s],
        'share' => %w[quota_ns period_ns cpuset capacity_mcpu capacity_first slice_us grace_us base ceiling flags],
        'principal' => %w[memory grant domains names default_limits ceiling_limits],
        'runtime_limits' => %w[max_frame max_message_heap funnel_depth exports tmp overlay atoms foreign_atoms processes],
        'limits' => %w[memory outer grant spaces lane connections crash flags runtime_limits band peer_held peer_held_total],
        'lane_class' => %w[lane],
        'domain' => %w[principal limits kind flags runtime release restarts restart_period_s args env],
        'session' => %w[limits runtime release args env],
        'unit' => %w[placement holder],
        'window' => %w[holder device role partition rights image drive],
        'service' => %w[name server interface],
        'facet' => %w[name grantee service operations max_request in_flight reductions period_ns max_heap_size queue],
        'image' => %w[device input salt],
        'partial_boot' => %w[image],
        'start' => %w[enable display restarts restart_period_s],
        'display' => %w[policy idle_dim_s idle_off_s palette],
        'apps' => %w[memory services max gatt],
        'package' => %w[input enable],
        'signer' => %w[key],
        'system_image' => %w[input]
      }.freeze
      OPTIONAL = { 'machine' => %w[system_args boot_timeout_s], 'domain' => %w[args env], 'session' => %w[args env], 'service' => %w[name],
                   'facet' => %w[name queue], 'image' => %w[salt], 'window' => %w[partition drive],
                   'start' => %w[enable display restarts restart_period_s],
                   'apps' => %w[services max gatt], 'package' => %w[enable], 'display' => %w[palette] }.freeze
      # The declarations that carry no source alias: the one machine, the one apps row
      # (docs/design-packaging.md, "The apps row") and the one system_image row
      # (docs/design-fiasco.md, "The booted slot").
      NAMELESS = %w[machine apps system_image].freeze
      DIRECTIVES = { 'introduce' => 2, 'liveness' => 1, 'shell_principal' => 1 }.freeze
      IDENTIFIER = /\A[a-z0-9][a-z0-9_-]{0,62}\z/.freeze
      module_function

      # The manifest bytes declare, refused unless it is version.
      def parse(bytes, version:) = read(bytes, version: version)

      # The manifest bytes declare. With version, a header naming another is refused
      # before any record is read; without, the header names it: what a harness edits
      # (Manifest::Edit) before the edited text is admitted, which checks it (parse).
      def read(bytes, version: nil)
        declarations = ABI::Syntax.parse(bytes, path: 'config/manifest')
        headers = declarations.select { |item| item.kind == 'manifest' }
        header = headers.first if headers.size == 1 && headers.first.args.size == 1 && headers.first.members.empty?
        declared = header && ABI::Syntax.integer(header.args.first, line: header.line)
        unless declared && (version.nil? || declared == version)
          raise Invalid.new('one supported manifest version is required', field: 'version')
        end
        records = record_list(declarations).group_by(&:kind)
        raise Invalid.new('one machine declaration is required', field: 'machine') unless
          records.fetch('machine', []).size == 1
        # Property 19's first clause (docs/design-packaging.md, "The build's check").
        raise Invalid.new('at most one apps row', field: 'apps') if records.fetch('apps', []).size > 1
        raise Invalid.new('at most one system_image row', field: 'system_image') if records.fetch('system_image', []).size > 1

        records.each do |kind, list|
          next if kind == 'machine' || DIRECTIVES.key?(kind)
          unless list.map(&:name).uniq.size == list.size
            raise Invalid.new('duplicate source alias', field: kind)
          end
        end
        machine = records.delete('machine').first
        Source.new(version: declared, machine: machine,
                   records: records.transform_values { |list| list.freeze }.freeze).freeze
      end

      # The records of one part of a manifest, the bytes of the file at path, in order,
      # each checked as read checks it: a board's development manifest is the common part
      # followed by the board's (Platform#manifest_source), and neither is a manifest
      # alone, so what only the whole has (its one header, its one machine, names unique
      # per kind) is not asked of a part. Each record's line names path, so a reader of
      # the files (FacetNames) points at a record's own file and line.
      def records(bytes, path:) = record_list(ABI::Syntax.parse(bytes, path: path)).freeze

      # The record of each declaration but the header, in order.
      def record_list(declarations)
        declarations.reject { |declaration| declaration.kind == 'manifest' }.map { |declaration| record(declaration) }
      end

      def record(declaration)
        kind = declaration.kind
        if DIRECTIVES.key?(kind)
          unless declaration.args.size == DIRECTIVES.fetch(kind) && declaration.members.empty?
            declaration.fail!('invalid manifest directive')
          end
          return Record.new(kind: kind, name: nil,
                            properties: { 'targets' => declaration.line.tokens.drop(1).freeze }.freeze,
                            parameters: [].freeze, line: declaration.line).freeze
        end
        fields = FIELDS[kind] || declaration.fail!('unknown manifest declaration')
        if NAMELESS.include?(kind)
          declaration.fail!("#{kind} has no source alias") unless declaration.args.empty?
          name = nil
        else
          declaration.fail!('named declaration needs one identifier') unless declaration.args.size == 1 && declaration.args.first.match?(IDENTIFIER)
          name = declaration.args.first
        end
        properties = {}
        parameters = []
        declaration.members.each do |line|
          line.fail!('manifest properties have two-space indentation') unless line.indent == 2
          key = line.words.first
          if kind == 'facet' && key == 'parameter'
            line.fail!('parameter needs a key and value') unless line.tokens.size == 3
            parameters << line.tokens.drop(1).freeze
            next
          end
          line.fail!('unknown or duplicate manifest property') unless fields.include?(key) && !properties.key?(key)
          properties[key] = line.tokens.drop(1).freeze
        end
        required = fields - OPTIONAL.fetch(kind, [])
        declaration.fail!('missing required manifest property') unless (required - properties.keys).empty?
        Record.new(kind: kind, name: name, properties: properties.freeze,
                   parameters: parameters.freeze, line: declaration.line).freeze
      end

      # The manifest text of source, which read reads back to the same records: the
      # header, the machine, then every other record, kind by kind in the order read
      # found them, each with its properties and then its facet parameters. Comments are
      # not kept; the encoder sorts every table, so the order of records is not the
      # manifest's either.
      def render(source)
        "manifest #{source.version}\n#{records_text([source.machine, *source.records.values.flatten])}"
      end

      # The text of records, each as render writes it, in order: what a harness that adds
      # records read from one manifest to another appends (ProductionImage.sessions).
      def records_text(records) = records.map { |record| record_text(record) }.join

      def record_text(record)
        return "#{[record.kind, *record.properties.fetch('targets').map { |token| token_text(token) }].join(' ')}\n" if
          DIRECTIVES.key?(record.kind)

        members = [*record.properties.map { |key, tokens| [key, *tokens] },
                   *record.parameters.map { |tokens| ['parameter', *tokens] }]
        lines = [[record.kind, record.name].compact.join(' '),
                 *members.map { |key, *tokens| "  #{[key, *tokens.map { |token| token_text(token) }].join(' ')}" }]
        "#{lines.join("\n")}\n"
      end

      # A token as ABI::Syntax reads it back: a quoted one with its quote and backslash
      # escaped, and any byte outside printable ASCII as \xNN.
      def token_text(token)
        return token.value unless token.quoted

        escaped = token.value.each_byte.map do |byte|
          case byte
          when 34, 92 then "\\#{byte.chr}"
          when 32..126 then byte.chr
          else format('\\x%02x', byte)
          end
        end
        "\"#{escaped.join}\""
      end
      private_class_method :record_list, :record, :record_text, :token_text
    end
  end
end
