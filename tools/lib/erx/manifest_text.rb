# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # How a harness reads or changes a number of a manifest's record: a field of a named record
  # read, grown or set, every other byte of the text, comments included, unchanged. A record starts
  # at a line of its own at the left margin ("machine", "principal system",
  # "runtime_limits system") and its fields are the two-space-indented lines below it,
  # each a name and a value, up to the first line that is not so indented (a blank or
  # comment line ends a record); the edit reaches a field only through its record, so a
  # field of the same name in another record is never touched. A record that is not in
  # the text exactly once, a field that is not in its record exactly once, or a value
  # that is not a decimal number is refused, so an edit is never silently lost.
  module ManifestText
    module_function

    # source with each [record, field] of growth grown by its number; a negative number
    # shrinks it.
    def grow(source, growth) = edit(source, growth) { |value, added| value + added }

    # The number of field in the one record named record, refused as an edit is.
    def value(source, record:, field:)
      lines = source.lines
      number(lines, field_index(lines, record: record, field: field), record: record, field: field)
    end

    # source with each [record, field] of values set to its number.
    def set(source, values) = edit(source, values) { |_value, given| given }

    # source with each [record, field] of changes replaced by what the block returns
    # for the field's value and the change's number, edited in order.
    def edit(source, changes)
      changes.reduce(source.lines) do |lines, ((record, field), change)|
        index = field_index(lines, record: record, field: field)
        result = yield number(lines, index, record: record, field: field), change
        raise Error, "the manifest's #{record} #{field} would be #{result}" unless result.is_a?(Integer) && !result.negative?

        lines.dup.tap { |edited| edited[index] = "  #{field} #{result}#{lines[index][/\n\z/]}" }
      end.join
    end

    # The index in lines of the one line of field in the one record named record.
    def field_index(lines, record:, field:)
      starts = lines.each_index.select { |index| lines[index].chomp == record }
      raise Error, "the manifest does not have exactly one #{record} record" unless starts.size == 1

      body = (starts.first + 1...lines.size).take_while { |index| lines[index].start_with?('  ') }
      found = body.select { |index| lines[index].start_with?("  #{field} ") }
      raise Error, "the manifest's #{record} record does not have exactly one #{field} field" unless found.size == 1

      found.first
    end

    # The decimal number on the line at index, field's line in record.
    def number(lines, index, record:, field:)
      value = lines[index].chomp.delete_prefix("  #{field} ")
      raise Error, "the manifest's #{record} #{field} is not a decimal number" unless value.match?(/\A[0-9]+\z/)

      Integer(value, 10)
    end
    private_class_method :field_index, :number
  end
end
