# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'
require_relative 'abi'
require_relative 'bounded_file'
require_relative 'generation_plan'

module Erx
  # The USB mass-storage quirk table (docs/design-usb.md, "Device quirks"): the file
  # abi/formats/usb_quirks.txt, read and checked whole, becomes the generated Erlang
  # module erx_usb_quirks, whose lookup/3 the claim table calls with a device's vendor,
  # product and bcdDevice, and whose has/2 every consumer asks whether a device has a
  # kind. A row's kinds are members of the enum usb_quirk of abi/formats/usb.txt, so a
  # row can name only a behaviour the stack has, and has/2's contract takes only those
  # members, so Dialyzer refuses a consumer that names another; its citations name only
  # a source the file declares, in the form that source declares. The file's own header
  # states its grammar.
  module UsbQuirks
    class TableError < Error; end

    TABLE = 'abi/formats/usb_quirks.txt'
    OUTPUT = 'erlang/apps/erx_usb/src/erx_usb_quirks.erl'
    GENERATOR = 'tools/lib/erx/usb_quirks.rb'
    MAX_TABLE_BYTES = 262_144
    KIND_ENUM = 'usb_quirk'
    NAME = /\A[a-z][a-z0-9_]{0,31}\z/
    ID = /\A(\h{4}):(\h{4}|\*)\z/
    RANGE = /\A(\h{4})-(\h{4})\z/
    CITE = /\A([a-z][a-z0-9_]{0,31})(?::([1-9][0-9]{0,6}))?\z/
    COMMIT = /\A\h{12,40}\z/
    # How a source's rows cite it: by the line a row comes from, or by the name alone.
    CITE_FORMS = %w[line bare].freeze
    # The notice the table's header reproduces, indented: its first copyright line, and its
    # disclaimer's last.
    NOTICE_FIRST = /\A# {3}Copyright /
    NOTICE_LAST = '#   SUCH DAMAGE.'
    # Dialyzer widens a union of more atoms than this to atom() (erl_types.erl, SET_LIMIT),
    # and has/2's contract would then refuse no kind.
    MAX_KINDS = 13
    ERXOS_COPYRIGHT = 'Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>'

    # One row: vendor, product (nil for every product of the vendor), the inclusive
    # bcdDevice range, its kinds as the enum's members and its citations as written.
    Row = Data.define(:vendor, :product, :low, :high, :kinds, :cites) do
      # Rows sort by vendor, then a vendor's every-product row first, then range.
      def key = [vendor, product ? product + 1 : 0, low, high]
    end

    module_function

    # The plan Erx::Generated publishes into the build tree. It reads the table and every
    # ABI source, which the enum of kinds comes from.
    def generation(root:)
      root = File.realpath(root)
      sources = ABI::Sources.read(root: root)
      kinds = kinds(ABI::Model.validate(sources))
      text = BoundedFile.read(File.join(root, TABLE), maximum: MAX_TABLE_BYTES)
      rows = parse(text: text, kinds: kinds)
      reads = sources.inputs.merge(TABLE => text).transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
      GenerationPlan.new(files: { OUTPUT => erlang(rows, kinds, notice(text)).freeze }, reads: reads)
    end

    # The enum's members in the order of their values.
    def kinds(schema)
      type = schema.types[KIND_ENUM]
      raise TableError, "the ABI declares no enum #{KIND_ENUM}" unless type.is_a?(ABI::EnumType) && !type.flags

      raise TableError, "the enum #{KIND_ENUM} has more than #{MAX_KINDS} members" if type.members.size > MAX_KINDS

      type.members.sort_by { |_member, value| value }.map(&:first).freeze
    end

    # The notice the table's header reproduces, copyright lines, conditions and disclaimer,
    # without its comment leader, which the generated module carries after erXos's own.
    def notice(text)
      lines = text.b.split("\n")
      first = lines.index { |line| line.match?(NOTICE_FIRST) }
      last = lines.index(NOTICE_LAST)
      raise TableError, "#{TABLE}: the header reproduces no notice" unless first && last && first < last

      lines[first..last].map { |line| line.delete_prefix('#') }
    end
    private_class_method :notice

    # The rows of the table's text, or a TableError naming the line and what is wrong there.
    def parse(text:, kinds:)
      sources = {}
      rows = []
      text.b.split("\n", -1).each.with_index(1) do |line, number|
        where = "#{TABLE}:#{number}"
        refuse_bytes(line, where: where)
        tokens = line.partition('#').first.strip.split(/ +/)
        case tokens
        in []
          next
        in ['source', name, _release, commit, form]
          raise TableError, "#{where}: a source after the first quirk row" unless rows.empty?
          raise TableError, "#{where}: #{name.inspect} is not a source name" unless name.match?(NAME)
          raise TableError, "#{where}: source #{name} is declared already" if sources.key?(name)
          raise TableError, "#{where}: #{commit.inspect} is not a commit" unless commit.match?(COMMIT) && commit == commit.downcase
          raise TableError, "#{where}: #{form.inspect} is not one of #{CITE_FORMS.join(', ')}" unless CITE_FORMS.include?(form)

          sources[name] = form
        in ['quirk', *]
          row = row(tokens.drop(1), kinds: kinds, sources: sources, where: where)
          if rows.any? && (rows.last.key <=> row.key) >= 0
            raise TableError, "#{where}: #{tokens[1]} #{tokens[2]} " \
                              "#{rows.last.key == row.key ? 'has a row already' : 'is out of order'}"
          end

          rows << row
        in ['source', *]
          raise TableError, "#{where}: source takes a name, a release, a commit and a form"
        in [keyword, *]
          raise TableError, "#{where}: #{keyword} is not a line of the table"
        end
      end
      raise TableError, "#{TABLE}: no quirk row" if rows.empty?

      rows.freeze
    end

    # Only printable ASCII and the space reach the tokenizer.
    def refuse_bytes(line, where:)
      byte = line.each_byte.find { |candidate| candidate > 0x7e || candidate < 0x20 }
      return unless byte

      kind = byte > 0x7f ? 'a byte above 0x7f' : 'a control byte'
      raise TableError, format('%s: %s, 0x%02x', where, kind, byte)
    end
    private_class_method :refuse_bytes

    # A quirk row's tokens after the keyword: the device, its range, kinds, from, citations.
    def row(tokens, kinds:, sources:, where:)
      id, range, *rest = tokens
      split = rest.index('from')
      raise TableError, "#{where}: a quirk row names its citations after from" unless split

      named = rest.take(split)
      cites = rest.drop(split + 1)
      vendor, product = device(id, where: where)
      low, high = range(range, where: where)
      raise TableError, "#{where}: a quirk row names no kind" if named.empty?
      raise TableError, "#{where}: a quirk row cites no source" if cites.empty?

      cites.each { |cite| cite(cite, sources: sources, where: where) }
      Row.new(vendor: vendor, product: product, low: low, high: high,
              kinds: kinds_of(named, kinds: kinds, where: where), cites: cites.freeze)
    end
    private_class_method :row

    def device(id, where:)
      match = ID.match(id.to_s)
      raise TableError, "#{where}: #{id.inspect} is not VVVV:PPPP" unless match && id == id.downcase

      [match[1].hex, match[2] == '*' ? nil : match[2].hex]
    end
    private_class_method :device

    def range(range, where:)
      match = RANGE.match(range.to_s)
      raise TableError, "#{where}: #{range.inspect} is not LLLL-HHHH" unless match && range == range.downcase

      low, high = match.captures.map(&:hex)
      raise TableError, "#{where}: the range #{range} ends before it starts" if low > high

      [low, high]
    end
    private_class_method :range

    def kinds_of(named, kinds:, where:)
      named.each do |kind|
        raise TableError, "#{where}: #{kind} is not a member of the enum #{KIND_ENUM}" unless kinds.include?(kind)
      end
      repeated = named.find { |kind| named.count(kind) > 1 }
      raise TableError, "#{where}: #{repeated} is named twice" if repeated

      named.freeze
    end
    private_class_method :kinds_of

    def cite(cite, sources:, where:)
      match = CITE.match(cite)
      raise TableError, "#{where}: #{cite.inspect} is not NAME or NAME:LINE" unless match

      form = sources.fetch(match[1]) { raise TableError, "#{where}: #{match[1]} is not a declared source" }
      raise TableError, "#{where}: #{cite} names no line of #{match[1]}" if form == 'line' && !match[2]
      raise TableError, "#{where}: #{cite} names a line of #{match[1]}, cited bare" if form == 'bare' && match[2]
    end
    private_class_method :cite

    # erx_usb_quirks: lookup/3, over one clause of rows/2 for each vendor and product the
    # table names and one of vendor_rows/1 for each vendor with an every-product row.
    def erlang(rows, kinds, notice)
      by_product, by_vendor = rows.partition(&:product)
      product_clauses = by_product.group_by { |row| [row.vendor, row.product] }.map do |(vendor, product), group|
        format("rows(16#%04x, 16#%04x) ->\n    %s", vendor, product, ranges(group))
      end
      vendor_clauses = by_vendor.group_by(&:vendor).map do |vendor, group|
        format("vendor_rows(16#%04x) ->\n    %s", vendor, ranges(group))
      end
      <<~ERLANG
        %% #{ERXOS_COPYRIGHT}
        %% SPDX-License-Identifier: BSD-2-Clause
        %% Rows derived from FreeBSD's sys/dev/usb/quirk/usb_quirk.c, under the notices
        %% #{TABLE} reproduces:
        #{notice.map { |line| "%%#{line}".rstrip }.join("\n")}
        %% Generated by #{GENERATOR} from #{TABLE}; do not edit.
        -module(erx_usb_quirks).
        -moduledoc """
        The quirks of USB mass-storage devices (docs/design-usb.md, "Device
        quirks"): each device the table names, by vendor, product and bcdDevice
        range, with the behaviours of the stack it needs. erx_usb_claim calls
        lookup/3 once for a device, and hands its mass-storage function the kinds.
        """.

        -export([lookup/3, has/2]).
        -export_type([kind/0]).

        -type kind() :: #{kinds.join("\n              | ")}.

        -doc "Every kind of every row that names the device Vendor:Product at bcdDevice Release, sorted.".
        -spec lookup(0..16#ffff, 0..16#ffff, 0..16#ffff) -> [kind()].
        lookup(Vendor, Product, Release) ->
            lists:usort([Kind || {Low, High, Kinds} <- rows(Vendor, Product) ++ vendor_rows(Vendor),
                                 Low =< Release, Release =< High,
                                 Kind <- Kinds]).

        -doc """
        Whether Kinds, a device's lookup/3, holds Kind. Every consumer asks through
        has/2, whose contract takes only a member of kind(), so Dialyzer refuses a
        consumer that names a kind the enum does not have, as a renamed member would.
        """.
        -spec has(kind(), [kind()]) -> boolean().
        has(Kind, Kinds) ->
            lists:member(Kind, Kinds).

        %% The rows of a vendor and product, each its range and kinds.
        #{(product_clauses + ["rows(_Vendor, _Product) ->\n    []"]).join(";\n")}.

        %% The rows of every product of a vendor.
        #{(vendor_clauses + ["vendor_rows(_Vendor) ->\n    []"]).join(";\n")}.
      ERLANG
    end
    private_class_method :erlang

    def ranges(group)
      entries = group.map { |row| format('{16#%04x, 16#%04x, [%s]}', row.low, row.high, row.kinds.join(', ')) }
      "[#{entries.join(",\n     ")}]"
    end
    private_class_method :ranges
  end
end
