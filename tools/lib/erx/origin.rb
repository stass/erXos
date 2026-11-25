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
    SPDX_LINE = /^[ \t]*(?:(?:[#%*;\/]+|--)[ \t]*)?SPDX-License-Identifier:[ \t]*([^\r\n]+)/n
    ERXOS_DECLARATION_LINE = /^[ \t]*(?:(?:[#%*;\/]+|--|<!--)[ \t]*)?#{ERXOS_NOTICE}[ \t]*(?:(?:\*\/|-->)[ \t]*)?\r?$/n
    # The license recorded for a file whose own notice names a license this
    # module does not recognise. It is not permissive, so the file enters no
    # build until a reviewed rule names it.
    UNRECOGNIZED_NOTICE = 'LicenseRef-unrecognized-notice'
    # What a review rule is. A reviewed rule records a judgement about the
    # files it names, by path or a brace list of paths but never a wildcard,
    # and precedes their own notices; a package rule carries a package's
    # declared license to the files of a whole tree that state none of their own.
    RULE_KINDS = %w[reviewed package].freeze

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
    LICENSE_MARK = Regexp.union(
      /licen[cs]|public domain|copyleft|CeCILL|proprietary|confidential|commercial/in, /\b[AL]?GPL/in,
      /\b(?:CDDL|MPL|EPL)\b|Mozilla Public|Eclipse Public|Creative Commons|\bCC BY/in,
      /Permission is hereby granted|Permission to use, copy, modify/in,
      /Redistribution and use in source and binary forms|Copying and distribution of this file/in,
      /Except as contained in this notice/in
    )
    # The reviewed notices: each row the SHA-256 of a notice block's
    # normalised text, the file it was reviewed in and the license it grants,
    # POINTER for the pointer to a package declaration, which grants nothing
    # itself. Only a listed block is read as a permissive notice; no pattern
    # recognises one, so a block that differs in any word is unrecognised.
    NOTICE_TABLE = File.expand_path('../../../config/imports/notices.txt', __dir__)
    POINTER = 'POINTER'
    NOTICE_ROW = %r{\A([0-9a-f]{64}) ([!-~]+) ([!-~](?:[ -~]*[!-~])?)\z}n

    # A GNU notice is read sentence by sentence, a period ending a sentence
    # only before a space (not in "2.1", "gnu.org" or "Inc.,").
    SENTENCE = /(?:[^.]|\.(?! ))+\.?/n
    GNU_NAMES = {
      'General' => Regexp.union(/GNU General Public License/in, /\bGPL/n),
      'Lesser' => Regexp.union(/GNU Lesser General Public License/in, /\bLGPL/n),
      'Library' => /GNU Library General Public License/in
    }.freeze
    GNU_NAME = Regexp.union(GNU_NAMES.values)
    GNU_VERSION = /(?:\bversion|Public License,?|GPL)[ -]?v?(\d(?:\.\d)?)\b/in
    GNU_LATER = /any later version|or later|\dv?(?:\.\d)?\+/in
    GNU_LICENSES = {
      ['General', '1'] => 'GPL-1.0', ['General', '2'] => 'GPL-2.0', ['General', '3'] => 'GPL-3.0',
      ['Library', '2'] => 'LGPL-2.0', ['Lesser', '2'] => 'LGPL-2.0', ['Lesser', '2.1'] => 'LGPL-2.1',
      ['Lesser', '3'] => 'LGPL-3.0'
    }.freeze
    # The sentences of a GNU notice that grant nothing beside its grant.
    GNU_BOILERPLATE = %r{\A ?(?:See the GNU|You should have received a copy of the GNU|If not, see <?https?://www\.gnu\.org/licenses/?>?\.?\z)}in
    # The GCC Runtime Library Exception is the one exception recognised; any
    # other exception leaves the file unrecognised.
    GCC_EXCEPTION = /\A ?Under Section 7 of GPL version 3, you are granted additional permissions described in the GCC Runtime Library Exception, version 3\.1/in
    OTHER_EXCEPTION = /special exception|additional permission|Library Exception|linking exception/in


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

    # The order of evidence: a correction of the file's exact upstream SPDX
    # declaration, the file's SPDX line, its sidecar's, a reviewed rule, the
    # file's own license notice, then a package rule and the default. A
    # package declaration covers only files without a notice of their own.
    # Notices are those of the reviewed table unless a caller names others.
    def for_file(path, bytes:, sidecar:, review:, notices: nil)
      explicit = spdx(bytes)
      correction = review.fetch('rules').find do |rule|
        rule['declared_license'] && rule.fetch('declared_license') == explicit && matches_path?(rule, path)
      end
      return reviewed(correction) if correction
      if explicit
        validate_expression(explicit)
        return { 'license' => explicit, 'evidence' => 'file SPDX', 'reviewed' => false }
      end

      attached = spdx(sidecar)
      if attached
        validate_expression(attached)
        return { 'license' => attached, 'evidence' => "#{path}.license", 'reviewed' => false }
      end

      by_kind = review.fetch('rules').reject { |candidate| candidate.key?('declared_license') }
                      .group_by { |candidate| candidate.fetch('kind', 'reviewed') }
      raise Error, "unknown review rule kind #{(by_kind.keys - RULE_KINDS).first}" unless (by_kind.keys - RULE_KINDS).empty?

      wildcard = by_kind.fetch('reviewed', []).find { |candidate| candidate.fetch('pattern').match?(/[*?\[]/) }
      raise Error, "reviewed rule #{wildcard.fetch('pattern')} has a wildcard; a rule for a tree is a package rule" if wildcard

      named = by_kind.fetch('reviewed', []).find { |candidate| matches_path?(candidate, path) }
      return reviewed(named) if named

      own = notice(bytes, notices: notices || listed_notices)
      return own if own

      package = by_kind.fetch('package', []).find { |candidate| matches_path?(candidate, path) }
      return reviewed(package) if package

      { 'license' => review.fetch('default_license'),
        'evidence' => review.fetch('default_evidence'), 'reviewed' => true }
    end

    def matches_path?(rule, path)
      File.fnmatch?(rule.fetch('pattern'), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
    private_class_method :matches_path?

    def reviewed(rule)
      { 'license' => validate_expression(rule.fetch('license')), 'evidence' => rule.fetch('evidence'),
        'reviewed' => true }
    end
    private_class_method :reviewed

    # The license a file's own notice grants: nil when the file has no
    # notice, or only pointers to a package declaration; UNRECOGNIZED_NOTICE
    # when a notice block is neither in the table nor read as a GNU notice;
    # otherwise every license granted, joined by AND, the listed notices'
    # first. A file holding a NUL byte (a binary, or UTF-16 text) is not
    # read: one whose text, with its NUL bytes removed, holds a license mark
    # is unrecognised.
    def notice(bytes, notices:)
      bytes = bytes.b
      if bytes.include?("\0")
        words = bytes.delete("\0").scan(LICENSE_MARK).size
        return words.positive? ? unrecognized("#{words} license words in a file holding NUL bytes") : nil
      end

      marked = notice_blocks(bytes).select { |block| block.match?(LICENSE_MARK) }
      # The table's license of each listed block, POINTER included; nil collects the unlisted.
      by_license = marked.group_by { |block| notices[Digest::SHA256.hexdigest(block)] }
      unlisted = by_license.delete(nil) || []
      gnu = unlisted.map { |block| gnu_licenses(block) }
      return unrecognized("#{gnu.count(nil)} notice blocks neither reviewed nor GNU") if gnu.include?(nil)

      licenses = (by_license.keys - [POINTER] + gnu.flatten).uniq
      return nil if licenses.empty?

      # Each license is one operand, so an OR in one never reaches across the AND.
      expression = licenses.map { |license| license.include?(' OR ') ? "(#{license})" : license }.join(' AND ')
      { 'license' => validate_expression(expression), 'evidence' => 'file notice', 'reviewed' => false }
    end
    private_class_method :notice

    # The normalised text of each block of a file (COMMENT_LEADER above).
    # Each line is labelled with its block's kind: the number of the
    # multi-line comment it lies in, :line_comments, :text, or :blank for a
    # blank line that ends a multi-line comment's block or opens the file;
    # every other blank line continues the run before it.
    def notice_blocks(bytes)
      inside = false
      comments = 0
      kind = :blank
      labelled = bytes.b.gsub(/\r\n?/n, "\n").lines.map do |line|
        started_inside = inside
        inside = line.scan(COMMENT_DELIMITER).reduce(inside) { |open, mark| open ? mark != '*/' : mark == '/*' }
        comments += 1 if inside && !started_inside
        kind = case line
               when ->(_) { started_inside || (inside && line.match?(COMMENT_LINE)) } then comments
               when LINE_COMMENT then :line_comments
               when /\S/n then :text
               else kind.is_a?(Integer) ? :blank : kind
               end
        [kind, line]
      end
      labelled.slice_when { |(before, _), (after, _)| before != after }
              .reject { |run| run.first.first == :blank }
              .map { |run| normalise(run.map(&:last).join) }
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

    # The reviewed notice table, read once: SHA-256 to license.
    def listed_notices
      @listed_notices ||= notice_table(BoundedFile.read(NOTICE_TABLE, maximum: 1_048_576))
    end

    # A notice table's rows, refused whole at the first malformed, unsorted
    # or repeated one.
    def notice_table(bytes)
      rows = bytes.b.lines.map(&:chomp).reject { |line| line.empty? || line.start_with?('#') }
      table = rows.each_with_object({}) do |row, read|
        sha256, _example, license = NOTICE_ROW.match(row)&.captures
        raise Error, "malformed notice table row: #{row[0, 80].inspect}" unless sha256
        raise Error, "notice table repeats #{sha256}" if read.key?(sha256)

        read[sha256] = license == POINTER ? POINTER : validate_expression(license)
      end
      raise Error, 'notice table rows are not sorted by hash' unless rows.sort == rows

      table.freeze
    end
    private_class_method :notice_table

    # The licenses of one block's GNU notice, or nil unless every sentence
    # holding a license mark is a grant naming one GNU license and one
    # version, with "any later version" or not, and nothing else, a
    # boilerplate sentence, or the GCC Runtime Library Exception to the
    # block's GPL-3.0-or-later grants.
    def gnu_licenses(block)
      grants = []
      exception = false
      block.scan(SENTENCE).each do |sentence|
        if sentence.match?(GCC_EXCEPTION)
          exception = true
        elsif sentence.match?(GNU_BOILERPLATE)
          next
        elsif sentence.match?(OTHER_EXCEPTION)
          return nil
        elsif sentence.match?(LICENSE_MARK)
          license = gnu_license(sentence)
          return nil unless license

          grants << license
        end
      end
      return nil if grants.empty? || (exception && grants.any? { |grant| grant != 'GPL-3.0-or-later' })

      exception ? grants.map { |grant| "#{grant} WITH GCC-exception-3.1" } : grants
    end
    private_class_method :gnu_licenses

    # Whether one notice block reads as a GNU notice.
    def gnu_notice?(block) = !gnu_licenses(block).nil?

    # The license of one GNU grant sentence, or nil when it names no GNU
    # license, more than one GNU license or version, or a pair GNU_LICENSES
    # does not hold.
    def gnu_license(sentence)
      names = GNU_NAMES.select { |_, name| sentence.match?(name) }.keys
      versions = sentence.scan(GNU_VERSION).map { |(version)| version.delete_suffix('.0') }.uniq
      return nil unless names.size == 1 && versions.size == 1
      return nil if sentence.gsub(GNU_NAME, '').gsub(/\blicen[cs]e[ds]?\b/in, '').match?(LICENSE_MARK)

      base = GNU_LICENSES[[names.first, versions.first]]
      base && "#{base}-#{sentence.match?(GNU_LATER) ? 'or-later' : 'only'}"
    end
    private_class_method :gnu_license

    # Whether a file in an imported tree with no inventory row is erXos's own
    # code: its header holds erXos's notice, and neither a license declaration
    # nor a copyright holder appears anywhere but in erXos's own lines. Every
    # mention of either word is counted instead of recognising forms of a second
    # declaration, so a form this test does not know fails closed. Content
    # cannot prove who wrote a file: this refuses a third-party file as it
    # arrives, not one whose notices someone rewrote. Origin#check admits a new
    # file on this test and PackProvenance attributes one on it, so the two
    # cannot disagree.
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

    def spdx(bytes)
      return nil if bytes.nil? || bytes.include?("\0")

      match = bytes.match(SPDX_LINE)
      return nil unless match

      expression = match[1].sub(/[ \t]*(?:\*\/|-->).*\z/n, '').strip
      expression
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
