# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The attachment-fields chokepoint (docs/design-kernel.md, "Objects and
  # capabilities" and "Chokepoint checks"): every attachment field of an
  # object record has its one insert in kernel/core/attach.c and its walk in
  # the deletion core's teardown, so a field added to a record without
  # either fails the build, field by field.
  #
  # An attachment field is a member whose name begins with att_ in a struct
  # of a core's private header (kernel/core/*_impl.h), the only place an
  # object record is defined. For a field att_NAME of the record in
  # STEM_impl.h the check requires:
  # * an exported function erx_attach_STEM_NAME defined in attach.c, whose first
  #   call is erx_object_state, so it reads the object's state before it
  #   links anything;
  # * a call of the field's reader erx_STEM_NAME in delete.c, the teardown's
  #   walk of the field.
  # It also refuses an exported function of attach.c that inserts into no
  # declared field. The sources are read as C with comments removed; like the
  # other text rules it catches a slip, not a name pasted together by a macro.
  module AttachFields
    ATTACH = 'kernel/core/attach.c'
    DELETE = 'kernel/core/delete.c'
    RECORDS = 'kernel/core/*_impl.h'
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    FIELD = /\batt_([a-z0-9_]+)\s*(?:\[[^\]]*\]\s*)?;/
    # An exported definition: a name at the start of a line, then its
    # parameters and a body that opens on a later line.
    DEFINITION = /^(erx_[a-z0-9_]+)\(([^;{]*?)\)\s*\{(.*?)^\}/m
    CALL = /\b([a-z_][a-z0-9_]*)\s*\(/
    # Words that read as calls but are not.
    NOT_CALLS = %w[if while for switch return sizeof].freeze

    Field = Data.define(:path, :line, :stem, :name)

    Violation = Data.define(:rule, :path, :line, :detail) do
      def to_s = "chokepoint #{rule}: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = [ATTACH, DELETE].include?(path) || File.fnmatch?(RECORDS, path, GLOB_FLAGS)

    # The violations in files, a map from root-relative path to contents.
    def violations(files)
      fields = files.select { |path, _| File.fnmatch?(RECORDS, path, GLOB_FLAGS) }.flat_map { |path, text| fields_of(path, text) }
      inserts = definitions(strip(files.fetch(ATTACH, '')))
      teardown = strip(files.fetch(DELETE, ''))
      fields.flat_map { |field| field_violations(field, inserts, teardown) } + orphan_inserts(fields, inserts)
    end

    def fields_of(path, text)
      stem = File.basename(path, '_impl.h')
      strip(text).each_line.with_index(1).flat_map do |line, number|
        line.scan(FIELD).map { |(name)| Field.new(path: path, line: number, stem: stem, name: name) }
      end
    end

    def field_violations(field, inserts, teardown)
      insert = "erx_attach_#{field.stem}_#{field.name}"
      reader = "erx_#{field.stem}_#{field.name}"
      found = []
      body = inserts[insert]
      if body.nil?
        found << violation(field, "att_#{field.name} has no insert #{insert} in #{ATTACH}")
      elsif first_call(body) != 'erx_object_state'
        found << violation(field, "#{insert} does not call erx_object_state before anything else")
      end
      found << violation(field, "att_#{field.name} has no walk (#{reader}) in #{DELETE}") unless teardown.match?(/\b#{reader}\s*\(/)
      found
    end

    def orphan_inserts(fields, inserts)
      declared = fields.map { |field| "erx_attach_#{field.stem}_#{field.name}" }
      (inserts.keys - declared).map do |name|
        Violation.new(rule: 'attachment-fields', path: ATTACH, line: nil,
                      detail: "#{name} inserts into no declared attachment field")
      end
    end

    def violation(field, detail) = Violation.new(rule: 'attachment-fields', path: field.path, line: field.line, detail: detail)

    # The exported functions of text, by name, to their bodies.
    def definitions(text) = text.scan(DEFINITION).to_h { |name, _, body| [name, body] }

    def first_call(body) = body.scan(CALL).flatten.find { |name| !NOT_CALLS.include?(name) }

    # C text with comments removed and line breaks kept.
    def strip(text)
      text.gsub(%r{/\*.*?\*/}m) { |comment| "\n" * comment.count("\n") }.gsub(%r{//[^\n]*}, '')
    end
  end
end
