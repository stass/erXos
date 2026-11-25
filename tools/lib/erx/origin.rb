# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'runner'
require_relative 'json_input'
require_relative 'source_text'
require_relative 'bounded_file'
require_relative 'submodules'

module Erx
  # Import inventories record attribution decisions; they do not infer a
  # license merely because a file has no notice. Defaults require review.
  module Attribution
    ERXOS_LICENSE = 'BSD-2-Clause'
    # An XML file opens with its declaration alone on the first line, before any comment.
    XML_DECLARATION = /\A<\?xml[ \t][^<>]*\?>[ \t]*\r?\n?\z/n
    ERXOS_NOTICE = "SPDX-License-Identifier: #{ERXOS_LICENSE}".freeze
    ERXOS_COPYRIGHT = /Copyright \(c\) \d{4}(?:-\d{4})?, Stanislav Sedov <stas@deglitch\.com>/n
    # The comment forms attribution reads a license from. A declaration in any
    # other form is not read here; erxos_addition? refuses it by counting.
    # A declaration line holds its expression and at most a comment closer:
    # text after the closer would be a block the notice reader never sees.
    SPDX_LINE = %r{^[ \t]*(?:(?:[#%*;/]+|--)[ \t]*)?SPDX-License-Identifier:[ \t]*((?:(?!\*/|-->)[^\r\n])*?)[ \t]*(?:(?:\*/|-->)[ \t]*)?\r?$}n
    ERXOS_DECLARATION_LINE = /^[ \t]*(?:(?:[#%*;\/]+|--|<!--)[ \t]*)?#{ERXOS_NOTICE}[ \t]*(?:(?:\*\/|-->)[ \t]*)?\r?$/n
    # The license recorded for a file whose own notice names a license this
    # module does not recognise. It is not permissive, so the file enters no
    # build until a reviewed rule names it.
    UNRECOGNIZED_NOTICE = 'LicenseRef-unrecognized-notice'
    # A review profile, validated whole when it is read (Attribution.review):
    # the import it reviews (which scopes the notice table's pointers),
    # corrections of exact upstream SPDX declarations, judgements of single
    # files, each pinned to the SHA-256 of the bytes that were read, and
    # package rules, which carry a package's declared license to the files
    # of a tree that state none of their own. A judgement names its files and
    # their bytes, never a pattern, so it covers no file nobody read.
    Review = Data.define(:import, :corrections, :judgements, :packages, :default_license, :default_evidence)
    Correction = Data.define(:pattern, :declared, :license, :evidence)
    Judgement = Data.define(:sha256, :license, :evidence)
    Package = Data.define(:pattern, :license, :evidence)
    # One block of a file as the notice reader sees it: its normalised text
    # without SPDX declaration lines, whether it is a comment, whether it
    # lies in the file's header (before its first line of code), and the
    # SPDX declarations it held.
    Block = Data.define(:text, :comment, :header, :declarations)
    # What a file's blocks say: its one SPDX declaration, if any, and the
    # licenses its notices grant.
    Reading = Data.define(:declaration, :licenses)
    # A notice table entry: the license the block grants, or POINTER with
    # the imports in which it was reviewed as a pointer to the package
    # declaration, one row each.
    Notice = Data.define(:license, :imports)
    # The notice reader's one failure route, caught in for_file, which
    # records the file as UNRECOGNIZED_NOTICE with the reason.
    class Unrecognized < StandardError; end
    private_constant :Unrecognized

    # A notice is read in blocks: each /* comment that spans lines, whole
    # with its blank lines; each run of line comments (one-line /* comments
    # included, as in a boxed notice) with the blank lines between them; and
    # each run of other lines between comments, blank lines included, so a
    # notice whose clauses hold no license word is never read in part. A block's
    # normalised text is its words without comment leaders (runs of them, as
    # in `%%` or `##`), the comment closers and box characters ending its
    # lines, or its line breaks.
    COMMENT_LEADER = %r{^[ \t]*(?:/\*+|\*+/?|//+|[#;%!]+|--+|dnl\b)?[ \t]*}n
    COMMENT_TRAILER = %r{[ \t]*(?:\*+/|[*#]+)?[ \t]*$}n
    # A line opening a /* comment; a line opening with a comment leader; and
    # the comment delimiters, where an opener counts
    # at a line's start or after a space, not in a path such as `src/*.c`.
    COMMENT_LINE = %r{\A[ \t]*/\*}n
    LINE_COMMENT = %r{\A[ \t]*(?:/\*|//|[#;%!]|--|dnl\b)}n
    COMMENT_DELIMITER = %r{(?:^|(?<=[ \t]))/\*|\*/}n
    # Every word that can belong to a license notice: a block holding one is
    # a notice, which is recognised whole or leaves the file unrecognised. The
    # permissive notices' opening phrases are marks too, since some of them
    # hold no license word, and so is the X11 clause that follows an MIT
    # notice.
    # The copyleft families both marks below name.
    COPYLEFT_FAMILIES = /copyleft|CeCILL|\b(?:CDDL|MPL|EPL)\b|Mozilla Public|Eclipse Public|Creative Commons/in
    LICENSE_MARK = Regexp.union(
      /licen[cs]|public domain|proprietary|confidential|commercial/in, /\b[AL]?GPL/in,
      COPYLEFT_FAMILIES, /\bCC BY/in,
      /Permission is hereby granted|Permission to use, copy, modify/in,
      /Redistribution and use in source and binary forms|Copying and distribution of this file/in,
      /Except as contained in this notice/in
    )
    # The names of copyleft and other reciprocal licenses, which an erXos
    # file's prose may not hold unread (for_own_file). GPL is any word it
    # opens but the BCM2711's GPLEN and GPLEV registers.
    COPYLEFT_MARK = Regexp.union(
      COPYLEFT_FAMILIES, /General Public Licen[cs]e|\b[AL]?GPL(?!E[NV][0-9]*\b)/in,
      /\b(?:EUPL|GFDL|OSL|SSPL|APSL|CPL|MS-RL|ODbL|RPL)\b|Sleepycat|\bCC[ -]BY-SA/in,
      /Free Documentation|European Union Public|Open Software Licen|Server Side Public|Common Public Licen/in,
      /Common Development and Distribution|Apple Public Source|Reciprocal Public|Open Database Licen/in
    )
    # The blocks of an erXos file that are read: those of an imported file,
    # and every block naming a copyleft license.
    OWN_FILE_MARK = Regexp.union(LICENSE_MARK, COPYLEFT_MARK)
    # The reviewed notices: each row the SHA-256 of a notice block's
    # normalised text, the file it was reviewed in and the license it grants,
    # POINTER for the pointer to a package declaration, which grants nothing
    # itself. Only a listed block is read as a permissive notice; no pattern
    # recognises one, so a block that differs in any word is unrecognised.
    NOTICE_TABLE = File.expand_path('../../../config/imports/notices.txt', __dir__)
    POINTER = 'POINTER'
    NOTICE_ROW = %r{\A([0-9a-f]{64}) ([!-~]+) ([!-~](?:[ -~]*[!-~])?)\z}n

    # The block shapes that are not notices: copyright lines and a file's
    # description, which hold no word of a grant, a condition or a
    # restriction once the copyright phrases are taken out. Every comment
    # block in a file's header and every comment block beside a notice must
    # be a listed notice, a stock GNU notice or of this shape, so a
    # restriction worded without a license word is still a notice to read.
    COPYRIGHT_PHRASE = /\bCopyright\b|\(c\)|\bAll rights reserved\b\.?/in
    # Only words a technical description does not use: "permission", "must
    # not" or "forbid" describe capabilities and protocols in a kernel's
    # comments, so a restriction is caught by what it restricts instead.
    LEGAL_WORD = Regexp.union(
      LICENSE_MARK, /distribut|\bsell|\bsale|\bsold\b|resale|royalt|warrant|liab|indemn|patent|trademark/in,
      /sublicens|prohibit|\ball rights\b|terms and conditions|\bterms of (?:use|sale|this)|without (?:prior |written |express )*(?:permission|consent)/in
    )
    SPDX_MENTION = /SPDX-License-Identifier/in

    # A GNU notice is read sentence by sentence, a period ending a sentence
    # only before a space (not in "2.1", "gnu.org" or "Inc.,"). Its grant
    # and every other sentence holding a legal word must be one of the stock
    # wordings below, word for word, so a restriction, an exception or a
    # negated "any later version" added to one leaves the file unrecognised.
    SENTENCE = /(?:[^.]|\.(?! ))+\.?/n
    GNU_NAME = /GNU (?:General|Lesser General|Library General) Public License/n
    GNU_SUBJECT = /This (?:program|library|file)/n
    GNU_FREE = /#{GNU_SUBJECT} is free software; you can redistribute it and\/or modify it under the terms of the (#{GNU_NAME})/n
    # Each stock grant with the term it gives: the name, then the version.
    GNU_GRANTS = {
      /\A#{GNU_FREE} as published by the Free Software Foundation; either version (\d(?:\.\d)?)(?: of the License)?, or \(at your option\) any later version\.?\z/n => 'or-later',
      /\A#{GNU_FREE} as published by the Free Software Foundation; version (\d(?:\.\d)?)(?: of the License)?\.?\z/n => 'only',
      /\A#{GNU_FREE},? version (\d(?:\.\d)?),? as published by the Free Software Foundation\.?\z/n => 'only',
      /\AThis file is distributed under the terms of the (#{GNU_NAME}),?(?: version)? (\d(?:\.\d)?)\.?\z/n => 'only'
    }.freeze
    GNU_LICENSES = {
      ['General', '1'] => 'GPL-1.0', ['General', '2'] => 'GPL-2.0', ['General', '3'] => 'GPL-3.0',
      ['Library', '2'] => 'LGPL-2.0', ['Lesser', '2'] => 'LGPL-2.0', ['Lesser', '2.1'] => 'LGPL-2.1',
      ['Lesser', '3'] => 'LGPL-3.0'
    }.freeze
    # The stock sentences of a GNU notice that grant nothing beside its
    # grant; the FSF's postal address, the one free part, holds no legal word.
    GNU_BOILERPLATE = [
      /\A#{GNU_SUBJECT} is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY(?:; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE)?\.?\z/n,
      /\ASee the #{GNU_NAME} for more details\.?\z/n,
      /\AYou should have received a copy of the #{GNU_NAME} along with this (?:program|library|file)(?:; if not, write to the Free Software Foundation, Inc\., (?<address>[0-9A-Za-z ,-]+))?\.?\z/n,
      %r{\AIf not, see <https?://www\.gnu\.org/licenses/>\.?\z}n,
      /\APlease see the COPYING-GPL-\d file for details\.?\z/n
    ].freeze

    module_function

    def validate_expression(expression)
      unless expression.is_a?(String) && expression.ascii_only? && expression.bytesize.between?(1, 1024)
        raise Error, 'invalid source license expression'
      end
      tokens = expression.scan(/[A-Za-z0-9][A-Za-z0-9.+_:\-]*|[()]/)
      unless tokens.join == expression.gsub(/[ \t]/, '')
        raise Error, 'invalid source license tokens'
      end
      depth = 0
      needs_operand = true
      needs_exception = false
      can_take_exception = false
      tokens.each do |token|
        case token
        when '('
          raise Error, 'invalid license grouping' unless needs_operand && !needs_exception && depth < 32
          depth += 1
        when ')'
          raise Error, 'invalid license grouping' if needs_operand || depth.zero?
          depth -= 1
          can_take_exception = false
        when 'AND', 'OR'
          raise Error, 'missing license operand' if needs_operand
          needs_operand = true
          can_take_exception = false
        when 'WITH'
          raise Error, 'invalid license exception' unless !needs_operand && can_take_exception
          needs_operand = true
          needs_exception = true
          can_take_exception = false
        else
          raise Error, 'missing license operator' unless needs_operand
          raise Error, 'unresolved source license' if %w[NOASSERTION NONE].include?(token)
          needs_operand = false
          can_take_exception = !needs_exception
          needs_exception = false
        end
      end
      raise Error, 'incomplete license expression' if needs_operand || !depth.zero?
      expression
    end

    # A review profile read and validated whole: every rule's kind, shape
    # and license, before any file is attributed with it.
    def review(profile)
      corrections = []
      judgements = {}
      packages = []
      profile.fetch('rules').each do |rule|
        kind = rule.key?('declared_license') ? 'correction' : rule.fetch('kind', 'reviewed')
        license = validate_expression(rule.fetch('license'))
        evidence = rule.fetch('evidence')
        case kind
        when 'correction'
          corrections << Correction.new(pattern: rule.fetch('pattern'), declared: rule.fetch('declared_license'),
                                        license: license, evidence: evidence)
        when 'package'
          packages << Package.new(pattern: rule.fetch('pattern'), license: license, evidence: evidence)
        when 'reviewed'
          judged(rule).each do |path, sha256|
            raise Error, "two reviewed rules judge #{path}" if judgements.key?(path)

            judgements[path] = Judgement.new(sha256: sha256, license: license, evidence: evidence)
          end
        else
          raise Error, "unknown review rule kind #{kind}"
        end
      end
      Review.new(import: profile['import'], corrections: corrections.freeze, judgements: judgements.freeze,
                 packages: packages.freeze, default_license: profile.fetch('default_license'),
                 default_evidence: profile.fetch('default_evidence'))
    end

    # A reviewed rule's files, each with the SHA-256 of the bytes judged.
    def judged(rule)
      files = rule['files']
      unless !rule.key?('pattern') && files.is_a?(Hash) && !files.empty? &&
             files.all? { |path, sha256| path.is_a?(String) && sha256.is_a?(String) && sha256.match?(/\A[0-9a-f]{64}\z/) }
        raise Error, "reviewed rule #{rule.fetch('evidence')[0, 60].inspect} must name each file it judged " \
                     'with the SHA-256 of its bytes; a rule for a tree is a package rule'
      end
      files
    end
    private_class_method :judged

    # The order of evidence: a reviewed judgement of the file's exact bytes;
    # the file's one SPDX declaration (or its correction), or its sidecar's,
    # which must name every license the file's notices grant; the file's own
    # notices; a package rule; the default. A package declaration covers only
    # files without a notice of their own. Notices are those of the reviewed
    # table unless a caller names others.
    def for_file(path, bytes:, sidecar:, review:, notices: nil)
      judgement = review.judgements[path]
      if judgement
        raise Unrecognized, 'a reviewed rule judged other bytes' unless judgement.sha256 == Digest::SHA256.hexdigest(bytes)

        return { 'license' => judgement.license, 'evidence' => judgement.evidence, 'reviewed' => true }
      end

      notices ||= listed_notices
      reading = read_notices(bytes, reader: ->(text) { block_licenses(text, notices: notices, import: review.import) })
      declared = declaration(path, reading.declaration, review: review) || attached(path, sidecar)
      return within(declared, licenses: reading.licenses) if declared
      return notice_attribution(reading.licenses) unless reading.licenses.empty?

      package = review.packages.find { |candidate| File.fnmatch?(candidate.pattern, path, PATTERN_FLAGS) }
      return { 'license' => package.license, 'evidence' => package.evidence, 'reviewed' => true } if package

      { 'license' => review.default_license, 'evidence' => review.default_evidence, 'reviewed' => true }
    rescue Unrecognized => e
      unrecognized(e.message)
    end

    # An erXos file outside every import tree, written by hand or by one of
    # erXos's generators. The style guide gives it a copyright line and one
    # SPDX declaration in its header, which names every third-party license
    # the file carries (design.md, "Licenses and notices"); the rest of its comments
    # are erXos's prose, which discusses licenses, distribution and copyright
    # as subjects, so no other block is read as a notice to recognise whole.
    # What the declaration cannot understate is still read: a stock GNU grant
    # sentence or a block the reviewed table lists must be named by it, and a
    # block naming a copyleft license in any other words leaves the file
    # unrecognised. A file without a declaration takes the license those
    # notices grant, else NOASSERTION, which no build admits.
    def for_own_file(bytes:)
      notices = listed_notices
      reading = read_notices(bytes, mark: OWN_FILE_MARK, reader: ->(text) { prose_licenses(text, notices: notices) })
      return within(spdx_attribution(reading.declaration), licenses: reading.licenses) if reading.declaration
      return notice_attribution(reading.licenses) unless reading.licenses.empty?

      { 'license' => 'NOASSERTION', 'evidence' => 'no SPDX declaration', 'reviewed' => false }
    rescue Unrecognized => e
      unrecognized(e.message)
    end

    PATTERN_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    # The attribution of a file's SPDX declaration: its correction when a
    # reviewed one names the exact text, else the declaration itself.
    def declaration(path, expression, review:)
      return nil unless expression

      correction = review.corrections.find do |candidate|
        candidate.declared == expression && File.fnmatch?(candidate.pattern, path, PATTERN_FLAGS)
      end
      return { 'license' => correction.license, 'evidence' => correction.evidence, 'reviewed' => true } if correction

      spdx_attribution(expression)
    end
    private_class_method :declaration

    def spdx_attribution(expression) = { 'license' => declared_license(expression), 'evidence' => 'file SPDX', 'reviewed' => false }
    private_class_method :spdx_attribution

    def attached(path, sidecar)
      expression = spdx(sidecar)
      expression && { 'license' => declared_license(expression), 'evidence' => "#{path}.license", 'reviewed' => false }
    end
    private_class_method :attached

    # A license expression a file declares: one that does not parse is the
    # file's to answer for, so it leaves the file unrecognised rather than
    # failing the whole inventory.
    def declared_license(expression)
      validate_expression(expression)
    rescue Error
      raise Unrecognized, 'an SPDX declaration that is not a license expression'
    end
    private_class_method :declared_license

    # A declaration stands only if it names every license the file's
    # notices grant.
    def within(declared, licenses:)
      outside = licenses.flat_map { |license| license_ids(license) } - license_ids(declared.fetch('license'))
      raise Unrecognized, "a notice grants #{outside.first}, which the SPDX declaration does not name" unless outside.empty?

      declared
    end
    private_class_method :within

    def license_ids(expression) = expression.scan(/[A-Za-z0-9][A-Za-z0-9.+_:-]*/n) - %w[AND OR WITH]
    private_class_method :license_ids

    # The licenses of a file's notices joined by AND, each compound one
    # bracketed so its OR or WITH never reaches across the AND.
    def notice_attribution(licenses)
      expression = if licenses.size == 1
                     licenses.first
                   else
                     licenses.map { |license| license.match?(/\A[A-Za-z0-9.+_:-]+\z/n) ? license : "(#{license})" }.join(' AND ')
                   end
      { 'license' => validate_expression(expression), 'evidence' => 'file notice', 'reviewed' => false }
    end
    private_class_method :notice_attribution

    # What a file's own blocks say (Reading). A file holding a NUL byte (a
    # binary, or UTF-16 text) is not read: one whose text, with its NUL
    # bytes removed, holds a license mark is unrecognised. A file may hold
    # one SPDX declaration, on a line of its own in its header, and no other
    # mention of one. Every block that holds a license mark, every comment
    # block of the header and every comment block beside a marked one is
    # read by READER, which gives the licenses one block's text grants
    # (block_licenses, or prose_licenses for an erXos file, whose MARK also
    # reads every block naming a copyleft license).
    def read_notices(bytes, reader:, mark: LICENSE_MARK)
      bytes = bytes.b
      if bytes.include?("\0")
        words = bytes.delete("\0").scan(LICENSE_MARK).size
        raise Unrecognized, "#{words} license words in a file holding NUL bytes" if words.positive?

        return Reading.new(declaration: nil, licenses: [])
      end

      blocks = notice_blocks(bytes)
      declarations = blocks.flat_map(&:declarations)
      mentions = bytes.scan(SPDX_MENTION).size
      unless mentions == declarations.size && mentions <= 1 && blocks.all? { |block| block.header || block.declarations.empty? }
        raise Unrecognized, "#{mentions} SPDX mentions; one declaration line in the header is read"
      end

      licenses = read_blocks(blocks, mark: mark).flat_map { |block| reader.call(block.text) }
      Reading.new(declaration: declarations.first, licenses: licenses.uniq)
    end
    private_class_method :read_notices

    # The blocks the reader must account for: each holding a license mark,
    # each comment block of the header and each comment block beside a
    # marked one.
    def read_blocks(blocks, mark: LICENSE_MARK)
      marked = blocks.map { |block| block.text.match?(mark) }
      blocks.each_with_index.select do |block, index|
        beside = (index.positive? && marked[index - 1]) || marked[index + 1]
        marked[index] || (block.comment && (block.header || beside))
      end.map(&:first)
    end
    private_class_method :read_blocks

    # The licenses one read block grants: a listed notice's, none for a
    # pointer reviewed in this import or a block of no legal word, a stock
    # GNU notice's; any other block leaves the file unrecognised.
    def block_licenses(text, notices:, import:)
      row = notices[Digest::SHA256.hexdigest(text)]
      if row
        return [row.license] unless row.license == POINTER
        return [] if row.imports.include?(import)

        raise Unrecognized, 'a pointer not reviewed in this import'
      end
      gnu = gnu_licenses(text)
      return gnu if gnu
      return [] if plain?(text)

      raise Unrecognized, 'a block neither a reviewed notice, a stock GNU notice nor free of legal words'
    end
    private_class_method :block_licenses

    # The licenses one block of an erXos file's prose grants: a listed
    # notice's, and each stock GNU grant sentence's, wherever it stands among
    # other sentences. Any other sentence that names a copyleft license, and
    # is not stock GNU boilerplate, is a notice no reader recognises, so it
    # leaves the file unrecognised, as does a pointer to a package's
    # declaration, which a file outside every package cannot defer to.
    def prose_licenses(text, notices:)
      row = notices[Digest::SHA256.hexdigest(text)]
      raise Unrecognized, 'a pointer to a package declaration in a file of no package' if row&.license == POINTER
      return [row.license] if row

      text.scan(SENTENCE).map(&:strip).filter_map do |sentence|
        grant = gnu_grant(sentence)
        if grant.nil? && sentence.match?(COPYLEFT_MARK) && !gnu_boilerplate?(sentence)
          raise Unrecognized, 'a sentence names a copyleft license in words no reader recognises'
        end

        grant
      end
    end
    private_class_method :prose_licenses

    # The texts of a file's read blocks that only the notice table can
    # account for: neither stock GNU notices nor free of legal words. These
    # are what a reviewer reads before listing a row.
    def unread_blocks(bytes)
      return [] if bytes.b.include?("\0")

      read_blocks(notice_blocks(bytes)).map(&:text).reject { |text| gnu_licenses(text) || plain?(text) }
    end

    # Whether a block or sentence holds no legal word once its copyright
    # phrases are taken out.
    def plain?(text) = !text.gsub(COPYRIGHT_PHRASE, '').match?(LEGAL_WORD)
    private_class_method :plain?

    # A file's blocks (Block). Each line is labelled with its block's kind:
    # the number of the multi-line comment it lies in, :line_comments,
    # :text, or :blank for a blank line that ends a multi-line comment's
    # block or opens the file; every other blank line continues the run
    # before it. A C preprocessor line (#define, #include) opens with a
    # comment leader and is labelled a comment line, so a block it joins is
    # read whole, which can only leave a file unrecognised.
    def notice_blocks(bytes)
      inside = false
      comments = 0
      kind = :blank
      labelled = bytes.b.gsub(/\r\n?/n, "\n").lines.map do |line|
        started_inside = inside
        inside = line.scan(COMMENT_DELIMITER).reduce(inside) { |open, mark| open ? mark != '*/' : mark == '/*' }
        comments += 1 if inside && !started_inside
        kind = if started_inside || (inside && line.match?(COMMENT_LINE)) then comments
               elsif line.match?(LINE_COMMENT) then :line_comments
               elsif line.match?(/\S/n) then :text
               elsif kind.is_a?(Integer) then :blank
               else kind
               end
        [kind, line]
      end
      header = true
      labelled.slice_when { |(before, _), (after, _)| before != after }
              .reject { |run| run.first.first == :blank }
              .map do |run|
                comment = run.first.first != :text
                header &&= comment
                declared, lines = run.map(&:last).partition { |line| line.match?(SPDX_LINE) }
                Block.new(text: normalise(lines.join), comment: comment, header: header,
                          declarations: declared.map { |line| declared_expression(line) })
              end
    end

    # A block's words without comment leaders, closers, box characters or
    # line breaks: the text a notice table row hashes.
    def normalise(text)
      text.gsub(COMMENT_LEADER, '').gsub(COMMENT_TRAILER, '').gsub(/\s+/n, ' ').strip
    end
    private_class_method :normalise

    def unrecognized(reason)
      { 'license' => UNRECOGNIZED_NOTICE, 'reviewed' => false,
        'evidence' => "unrecognized license notice (#{reason}); review the file" }
    end
    private_class_method :unrecognized

    # The reviewed notice table, read once: SHA-256 to Notice.
    def listed_notices
      @listed_notices ||= notice_table(BoundedFile.read(NOTICE_TABLE, maximum: 1_048_576))
    end

    # A notice table's rows, refused whole at the first malformed, unsorted
    # or repeated one. A license is kept in canonical spacing. A pointer
    # belongs to the import its example names first, and the same pointer
    # text has one row for each import it was reviewed in.
    def notice_table(bytes)
      rows = bytes.b.lines.map(&:chomp).reject { |line| line.empty? || line.start_with?('#') }
      table = rows.each_with_object({}) do |row, read|
        sha256, example, license = NOTICE_ROW.match(row)&.captures
        raise Error, "malformed notice table row: #{row[0, 80].inspect}" unless sha256

        known = read[sha256]
        if license == POINTER && (known.nil? || known.license == POINTER)
          imports = (known&.imports || []) + [example.split('/').first]
          raise Error, "notice table repeats #{sha256} for #{imports.last}" unless imports.uniq == imports

          read[sha256] = Notice.new(license: POINTER, imports: imports.freeze)
        else
          raise Error, "notice table repeats #{sha256}" if known

          read[sha256] = Notice.new(license: canonical(validate_expression(license)), imports: [].freeze)
        end
      end
      raise Error, 'notice table rows are not sorted by hash' unless rows.sort == rows

      table.freeze
    end
    private_class_method :notice_table

    # A license expression with one space between operands and operators
    # and none inside brackets.
    def canonical(expression)
      expression.scan(/[A-Za-z0-9][A-Za-z0-9.+_:-]*|[()]/n).join(' ').gsub('( ', '(').gsub(' )', ')')
    end
    private_class_method :canonical

    # The licenses of one block's GNU notice, or nil unless it holds a stock
    # grant and every other sentence is a stock one or holds no legal word.
    def gnu_licenses(block)
      grants = block.scan(SENTENCE).map(&:strip).each_with_object([]) do |sentence, found|
        grant = gnu_grant(sentence)
        if grant
          found << grant
        elsif !gnu_boilerplate?(sentence) && !plain?(sentence)
          return nil
        end
      end
      grants.empty? ? nil : grants
    end
    private_class_method :gnu_licenses

    # The license of one stock GNU grant sentence, or nil.
    def gnu_grant(sentence)
      GNU_GRANTS.each do |form, term|
        match = form.match(sentence)
        next unless match

        family = match[1][/Lesser|Library/n] || 'General'
        base = GNU_LICENSES[[family, match[2].delete_suffix('.0')]]
        return base && "#{base}-#{term}"
      end
      nil
    end
    private_class_method :gnu_grant

    def gnu_boilerplate?(sentence)
      GNU_BOILERPLATE.any? do |form|
        match = form.match(sentence)
        match && (!match.names.include?('address') || match[:address].nil? || plain?(match[:address]))
      end
    end
    private_class_method :gnu_boilerplate?

    # Whether a file in an imported tree with no inventory row is erXos's own
    # code: its header holds erXos's notice, and neither a license declaration
    # nor a copyright holder appears anywhere but in erXos's own lines. Every
    # mention of either word is counted instead of recognising forms of a second
    # declaration, so a form this test does not know fails closed. Content
    # cannot prove who wrote a file: this refuses a third-party file as it
    # arrives, not one whose notices someone rewrote. Origin#check admits a new
    # file on this test and PackProvenance admits one on it, then attributes
    # it by for_own_file, which this test's lines make BSD-2-Clause or
    # unrecognised.
    def erxos_addition?(bytes)
      bytes = bytes.b
      return false if bytes.include?("\0")

      header_notice?(bytes, notice: ERXOS_NOTICE) &&
        only_in?(bytes, word: /SPDX-License-Identifier/ni, form: ERXOS_DECLARATION_LINE) &&
        only_in?(bytes, word: /copyright/ni, form: ERXOS_COPYRIGHT)
    end

    # Whether the file has the form, and has the word nowhere outside it.
    def only_in?(bytes, word:, form:)
      found = bytes.scan(form).size
      found.positive? && bytes.scan(word).size == found
    end
    private_class_method :only_in?

    # Whether the file's opening comment lines, within the read bound, hold the
    # notice. Any line opening with a comment leader of a language counts, and so
    # does a first line that is an XML declaration, which must precede any comment,
    # and every line inside an XML comment that was opened in the header. This
    # reads XML files of an import tree, so that an erXos file added to one is
    # attributed; a file outside every import tree never comes here.
    def header_notice?(bytes, notice:)
      inside_xml_comment = false
      bytes.byteslice(0, 8192).lines.each_with_index do |line, number|
        stripped = line.lstrip
        next if stripped.strip.empty?
        next if number.zero? && line.match?(XML_DECLARATION)
        return false unless inside_xml_comment || stripped.start_with?('#', '%', ';', '//', '/*', '*', '<!--', '--')
        # A closing `*/` alone on its line leaves no text before it.
        comment = stripped.split('*/', 2).first.split('-->', 2).first.to_s
        return true if comment.include?(notice)

        inside_xml_comment = (inside_xml_comment || stripped.start_with?('<!--')) && !stripped.include?('-->')
      end
      false
    end

    # The expression of an SPDX declaration line, without a comment closer.
    def declared_expression(line) = line[SPDX_LINE, 1].sub(/[ \t]*(?:\*\/|-->).*\z/n, '').strip
    private_class_method :declared_expression

    # A sidecar's SPDX declaration.
    def spdx(bytes)
      return nil if bytes.nil? || bytes.include?("\0")

      line = bytes.b[SPDX_LINE]
      line && declared_expression(line)
    end
    private_class_method :spdx
  end

  class Origin
    # Git submodules: upstream trees pinned by the commit the superproject
    # records, whose text is not erXos's and is not scanned. Each records its
    # origin in an ORIGIN.md in the directory that holds it, outside the
    # submodule, which Checks requires. That directory is not an import root:
    # the submodule is, and what erXos keeps beside it (display/lvgl's
    # erx_lvgl.c and lv_conf.h) is erXos's code (PackProvenance#find_origin).
    # The examples' submodules (Submodules#examples) are listed too: a clone does not
    # check them out, and no gate reads them.
    SUBMODULES = Submodules::TREE.paths
    INVENTORY_MARKER = "\n```json\n"
    # Each inventory field and the class of its value; the one list of the
    # fields, from which the reader names a missing or mistyped one.
    PAYLOAD_FIELDS = { 'version' => Integer, 'repository' => String, 'revision' => String,
                       'archive_sha256' => String, 'exclusions' => Array, 'removed' => Array,
                       'files' => Hash, 'changes' => Hash }.freeze
    MODIFIED_NOTICE = 'Modified by erXos'

    def initialize(root:, read_bytes: nil, authorize: nil, known_hash: nil)
      @root = File.expand_path(root)
      @read_bytes = read_bytes
      @authorize = authorize
      @known_hash = known_hash
    end

    def write(repository:, revision:, archive_sha256:, review:, exclusions: [])
      output = File.join(@root, 'ORIGIN.md')
      raise Error, "origin already exists: #{output}" if File.exist?(output) || File.symlink?(output)
      raise Error, 'invalid import SHA-256' unless /\A[0-9a-f]{64}\z/.match?(archive_sha256)

      review = Attribution.review(review)
      inventory = files.to_h do |path|
        [path, inventory_entry(path, review: review)]
      end
      payload = { 'version' => 1, 'repository' => repository, 'revision' => revision,
                  'archive_sha256' => archive_sha256, 'exclusions' => exclusions, 'removed' => [],
                  'files' => inventory, 'changes' => {} }
      validate_inventory(payload)
      text = "# Source origin\n\nRepository: #{repository}\n\nRevision: #{revision}\n\n" \
             "The inventory records the imported bytes and their license evidence.\n" \
             "Third-party notices remain in their original files.\n"
      File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write(text + INVENTORY_MARKER + JSON.pretty_generate(payload) + "\n```\n")
      end
    end

    def check
      payload = read
      original = payload.fetch('files')
      current = files
      removed = payload.fetch('removed').map { |removal| removal.fetch('path') }
      restored = removed & current
      raise Error, "imported file recorded as removed is present: #{restored.first}" unless restored.empty?
      required = (original.keys - removed) | payload.fetch('changes').keys
      missing = required - current
      raise Error, "imported source file is missing: #{missing.first}" unless missing.empty?
      # The one refusal gathered over the whole tree rather than raised at the
      # first file: an edit of upstream code often touches many files at once.
      unnoticed = []
      current.each do |path|
        absolute = File.join(@root, path)
        @authorize.call(absolute) if @authorize
        baseline = original[path]
        if File.symlink?(absolute)
          raise Error, "an imported link cannot have a changes row: #{path}" if payload.fetch('changes').key?(path)

          validate_link(absolute)
          hash = Digest::SHA256.hexdigest("symlink\0" + File.readlink(absolute))
          unless baseline && baseline.fetch('kind') == 'symlink' && baseline.fetch('sha256') == hash
            raise Error, "changed imported link requires an explicit origin entry: #{path}"
          end
          next
        end
        if baseline && baseline.fetch('kind') != 'file'
          raise Error, "imported file type differs from its source record: #{path}"
        end
        # A changes row records the exact bytes erXos put at its path, so the
        # file must still be those bytes; a source among them also passes the
        # notice and ASCII checks below; a file of any other kind needs no more.
        explicit_change = payload.fetch('changes')[path]
        if explicit_change
          bytes = read_content(absolute)
          unless explicit_change.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
            raise Error, "file differs from its changes row; re-review its license and evidence: #{path}"
          end
          next unless source?(path, bytes: bytes)
        else
          # Only an immutable input-tree owner supplies this callback, after its
          # complete byte/path verification. Unchanged files need no second read;
          # modified files still pass the ordinary notice and ASCII checks below.
          next if baseline && @known_hash && @known_hash.call(absolute) == baseline.fetch('sha256')

          bytes = read_content(absolute)
          next if baseline && baseline.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
        end
        if baseline
          unnoticed << path unless Attribution.header_notice?(bytes, notice: MODIFIED_NOTICE)
        else
          check_addition(path, bytes: bytes, exclusions: payload.fetch('exclusions'))
        end
        next unless source?(path, bytes: bytes)

        permitted = baseline ? baseline.fetch('non_ascii_lines', []).dup : []
        bytes.lines.reject(&:ascii_only?).each do |line|
          hash = Digest::SHA256.hexdigest(line)
          index = permitted.index(hash)
          raise Error, "non-ASCII erXos addition to imported source: #{path}" unless index
          permitted.delete_at(index)
        end
      end
      raise Error, "imported files lack their erXos change notice: #{unnoticed.join(', ')}" unless unnoticed.empty?
      payload
    rescue Error => error
      raise naming_record(error)
    end

    def inventory
      read
    rescue Error => error
      raise naming_record(error)
    end

    # The inventory's row for a file as imported, which a removed file keeps; nil
    # for a file it does not list.
    def imported_file(path)
      read.fetch('files')[path]
    rescue Error => error
      raise naming_record(error)
    end

    private

    # A refusal from a public reader names the record it concerns, since its
    # own message gives paths relative to the record's tree; the error keeps
    # its class and backtrace.
    def naming_record(error)
      error.exception("#{File.join(@root, 'ORIGIN.md')}: #{error.message}")
    end

    # A path the import removed for a recorded reason does not come back as
    # erXos's code, whatever its header says.
    def check_addition(path, bytes:, exclusions:)
      excluded = exclusions.any? do |exclusion|
        path == exclusion.fetch('path') || path.start_with?(exclusion.fetch('path') + '/')
      end
      raise Error, "new file restores a path its import excluded: #{path}" if excluded
      return if Attribution.erxos_addition?(bytes)

      raise Error, "new file in an imported tree is not plainly erXos's own: #{path}"
    end

    def inventory_entry(path, review:)
      absolute = File.join(@root, path)
      if File.symlink?(absolute)
        validate_link(absolute)
        target = File.readlink(absolute)
        attribution = Attribution.for_file(path, bytes: ''.b, sidecar: nil, review: review)
        return attribution.merge('sha256' => Digest::SHA256.hexdigest("symlink\0" + target),
                                 'kind' => 'symlink', 'target' => target)
      end

      bytes = read_content(absolute)
      sidecar = "#{absolute}.license"
      attribution = Attribution.for_file(path, bytes: bytes,
                                         sidecar: File.file?(sidecar) ? read_content(sidecar) : nil,
                                         review: review)
      non_ascii = source?(path, bytes: bytes) ? bytes.lines.reject(&:ascii_only?).map { |line| Digest::SHA256.hexdigest(line) } : []
      attribution.merge('sha256' => Digest::SHA256.hexdigest(bytes),
                        'kind' => 'file', 'non_ascii_lines' => non_ascii)
    end

    def validate_link(path)
      root = File.realpath(@root)
      resolved = File.realpath(path)
      unless resolved == root || resolved.start_with?(root + '/')
        raise Error, "import link escapes its source tree: #{path}"
      end
    rescue Errno::ENOENT, Errno::ELOOP => error
      raise Error, "unresolved import link: #{error.message}"
    end

    def source?(path, bytes:)
      SourceText.source?(path, bytes: bytes)
    end

    def files
      Dir.glob(File.join(@root, '**/*'), File::FNM_DOTMATCH).each_with_object([]) do |path, selected|
        next if ['.', '..'].include?(File.basename(path))
        next unless File.file?(path) || File.symlink?(path)
        relative = path.delete_prefix(@root + '/')
        next if relative == 'ORIGIN.md'
        selected << relative
      end.sort
    end

    def read
      path = File.join(@root, 'ORIGIN.md')
      raise Error, 'source origin record must not be a symbolic link' if File.symlink?(path)
      bytes = read_content(path, maximum: 64 * 1024 * 1024 + 65_536)
      _prose, marker, tail = bytes.partition(INVENTORY_MARKER)
      raise Error, 'origin inventory is missing' if marker.empty?
      data, ending, rest = tail.partition("\n```\n")
      raise Error, 'origin inventory framing is invalid' if ending.empty? || !rest.empty?
      payload = JsonInput.parse(data, max_bytes: 64 * 1024 * 1024, label: 'origin inventory')
      validate_inventory(payload)
      payload
    rescue KeyError => error
      raise Error, "invalid origin inventory: #{error.message}"
    end

    # The fields are named from PAYLOAD_FIELDS, never from the input: an
    # unknown field is counted, so no unchecked text reaches the message.
    def validate_inventory(payload)
      raise Error, 'origin inventory is not an object' unless payload.is_a?(Hash)
      missing = PAYLOAD_FIELDS.keys - payload.keys
      raise Error, "origin inventory lacks fields: #{missing.join(', ')}" unless missing.empty?
      unknown = payload.size - PAYLOAD_FIELDS.size
      raise Error, "origin inventory has #{unknown} unknown field(s)" unless unknown.zero?
      mistyped = PAYLOAD_FIELDS.find { |field, type| !payload.fetch(field).is_a?(type) }
      raise Error, "origin inventory field #{mistyped.first} is not of class #{mistyped.last}" if mistyped
      raise Error, 'origin inventory version is not 1' unless payload.fetch('version') == 1
      %w[repository revision].each { |field| validate_text(payload.fetch(field)) }
      validate_hash(payload.fetch('archive_sha256'))
      payload.fetch('exclusions').each do |exclusion|
        unless exclusion.is_a?(Hash) && exclusion.keys.sort == %w[path reason]
          raise Error, 'invalid import exclusion'
        end
        validate_path(exclusion.fetch('path'))
        validate_text(exclusion.fetch('reason'))
      end
      payload.fetch('files').each { |path, entry| validate_entry(path, entry: entry) }
      validate_removals(payload)
      validate_copies(payload.fetch('files'), exclusions: payload.fetch('exclusions'))
      payload.fetch('changes').each do |path, change|
        validate_path(path)
        unless change.is_a?(Hash) && change.keys.sort == %w[evidence license sha256]
          raise Error, 'invalid explicit import change'
        end
        Attribution.validate_expression(change.fetch('license'))
        validate_text(change.fetch('evidence'))
        validate_hash(change.fetch('sha256'))
      end
    end

    # An imported file erXos deleted but whose bytes the tree still carries
    # elsewhere (a copy's row names it) is listed under removed with a one-line
    # reason. It names a file the inventory records, once, and no explicit
    # change, so its row and license evidence stay on record. A path no erXos
    # build uses is an exclusion instead: its rows leave the inventory, and
    # check_addition keeps it from coming back.
    def validate_removals(payload)
      paths = payload.fetch('removed').map do |removal|
        raise Error, 'invalid import removal' unless removal.is_a?(Hash) && removal.keys.sort == %w[path reason]

        validate_path(removal.fetch('path'))
        validate_text(removal.fetch('reason'))
        removal.fetch('path')
      end
      unknown = paths.reject { |path| payload.fetch('files').key?(path) }
      raise Error, "import removal names no imported file: #{unknown.first}" unless unknown.empty?
      changed = paths.select { |path| payload.fetch('changes').key?(path) }
      raise Error, "import removal names a file with an explicit change: #{changed.first}" unless changed.empty?
      raise Error, 'import removal is listed twice' unless paths.uniq.size == paths.size
    end

    def read_content(path, maximum: nil)
      @authorize.call(path) if @authorize
      return @read_bytes.call(path) if @read_bytes
      maximum ? BoundedFile.read(path, maximum: maximum) : File.binread(path)
    end

    # A copy's row repeats the row of the imported file it came from, so its license
    # evidence and baseline are that file's and the ordinary checks apply to it.
    def validate_copies(files, exclusions:)
      files.each do |path, entry|
        next unless entry.key?('copied_from')

        from = entry.fetch('copied_from')
        validate_path(from)
        source = files[from]
        unless source && !source.key?('copied_from') && source == entry.except('copied_from')
          raise Error, "copied file's row does not repeat the row of an imported file: #{path}"
        end
        if exclusions.any? { |exclusion| path == exclusion.fetch('path') || path.start_with?(exclusion.fetch('path') + '/') }
          raise Error, "new file restores a path its import excluded: #{path}"
        end
      end
    end

    def validate_entry(path, entry:)
      validate_path(path)
      raise Error, 'invalid origin file entry' unless entry.is_a?(Hash)
      common = %w[license evidence reviewed sha256 kind]
      case entry['kind']
      when 'file'
        expected = common + %w[non_ascii_lines]
        expected += %w[copied_from] if entry.key?('copied_from')
        lines = entry['non_ascii_lines']
        raise Error, 'invalid original source line hashes' unless lines.is_a?(Array)
        lines.each { |hash| validate_hash(hash) }
      when 'symlink'
        expected = common + %w[target]
        validate_text(entry['target'])
      else
        raise Error, 'invalid origin file kind'
      end
      raise Error, 'invalid origin entry fields' unless entry.keys.sort == expected.sort
      Attribution.validate_expression(entry.fetch('license'))
      validate_text(entry.fetch('evidence'))
      validate_hash(entry.fetch('sha256'))
      unless [true, false].include?(entry.fetch('reviewed'))
        raise Error, 'invalid origin review marker'
      end
    end

    def validate_path(path)
      validate_text(path)
      if path.start_with?('/') || path.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
        raise Error, 'invalid origin-relative path'
      end
    end

    def validate_text(value)
      unless value.is_a?(String) && value.valid_encoding? && !value.empty? && !value.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'invalid origin text'
      end
    end

    def validate_hash(value)
      raise Error, 'invalid origin SHA-256' unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
    end
  end
end
