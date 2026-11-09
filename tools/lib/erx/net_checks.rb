# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

module Erx
  # The build checks of the network stack's application, erx_net
  # (docs/design-network-stack.md, "Build checks"):
  #
  # * atoms: no module of erx_net names binary_to_atom, list_to_atom or
  #   binary_to_term, so no atom is ever made from packet data;
  # * seq-wrap: only erx_tcp_seq does sequence-space wrap arithmetic, so no
  #   other TCP module (erx_tcp and erx_tcp_*) spells 2^31, 2^32 - 1 or 2^32
  #   as an integer literal in any base, or shifts left by a literal 31 or 32;
  # * notices: the FreeBSD files a module's header names, one
  #   "%% FreeBSD: PATH" line each, are the files NOTICE-freebsd lists for
  #   that module, and the reverse; any other line naming "FreeBSD:" (a
  #   marker with more after the path, or one below the header) is refused,
  #   so a malformed claim never reads as no claim; the notice's commit and archive SHA-256
  #   are deps.lock's pin of freebsd-src.
  #
  # Like DeviceCallers these read the source text with comments removed, and
  # catch a slip, not a determined bypass that builds a name from pieces. The
  # atoms check keeps strings and quoted atoms, since `apply(erlang,
  # 'list_to_atom', ...)` names the function as surely as a call does; the
  # seq-wrap check blanks them, since a literal inside a string is no
  # arithmetic.
  module NetChecks
    APPLICATION = 'erlang/apps/erx_net'
    NOTICE = "#{APPLICATION}/NOTICE-freebsd"
    SCOPE = "#{APPLICATION}/**/*.{erl,hrl}"
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    LOCK_ID = 'freebsd-src'

    ATOM_MAKERS = /(?<![A-Za-z0-9_@])(binary_to_atom|list_to_atom|binary_to_term)(?![A-Za-z0-9_@])/
    # The TCP modules the seq-wrap rule covers, and the one module it lets do
    # the arithmetic.
    TCP_SOURCE = /\Aerx_tcp(?:_[a-z0-9_]+)?\.(?:erl|hrl)\z/
    SEQ_OWNER = 'erx_tcp_seq.erl'
    WRAP_VALUES = [2**31, 2**32 - 1, 2**32].freeze
    WRAP_SHIFTS = [31, 32].freeze
    # An Erlang integer literal (otp/lib/stdlib/src/erl_scan.erl): Base#Digits
    # or decimal digits, either with _ separators. It starts after no name
    # character, # or dot (so not inside a name, a based literal or a float's
    # fraction), and ends before no name character or # and before no dot
    # followed by a digit (a float); a dot ending a form still ends it.
    INTEGER = /
      (?<![A-Za-z0-9_@\#.])
      (?:(?<base>\d+)\#(?<based>[0-9A-Za-z]+(?:_[0-9A-Za-z]+)*) | (?<decimal>\d+(?:_\d+)*))
      (?![A-Za-z0-9_\#]|\.\d)
    /x
    # A left shift of an integer literal, through any spacing or line break
    # and an optional parenthesis.
    SHIFT = /\bbsl\b\s*\(?\s*(?=\d)/

    # A FreeBSD file named by a module's header, alone on its line.
    HEADER_MARK = /\A%+[ \t]*FreeBSD:[ \t]+(?<path>\S+)[ \t]*\z/
    FREEBSD_PATH = %r{\A[a-z0-9_]+(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)+\z}
    NOTICE_KEYS = %w[tag commit archive-sha256].freeze
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    Violation = Data.define(:rule, :path, :line, :detail) do
      def to_s = "chokepoint net-#{rule}: #{[path, line].compact.join(':')}: #{detail}"
    end

    # NOTICE-freebsd parsed: its header keys and, per module, the FreeBSD
    # files it derives from, each with the functions translated from it.
    Notice = Data.define(:keys, :modules)

    module_function

    # Whether a path is one the checks read: an erx_net source or the notice.
    def covers?(path) = path == NOTICE || File.fnmatch?(SCOPE, path, GLOB_FLAGS)

    # The violations among files, a map of path to source text holding every
    # covered file, given deps.lock's freebsd-src entry.
    def violations(files, lock:)
      sources = files.select { |path, _| File.fnmatch?(SCOPE, path, GLOB_FLAGS) }
      [*atom_violations(sources), *seq_violations(sources), *notice_violations(sources, notice: files[NOTICE], lock: lock)]
    end

    def atom_violations(sources)
      sources.flat_map do |path, text|
        DeviceCallers.code(text).each_line.with_index(1).filter_map do |line, number|
          next unless (name = line[ATOM_MAKERS, 1])

          Violation.new(rule: 'atoms', path: path, line: number,
                        detail: "#{name} in erx_net: no atom or term is made from packet data")
        end
      end
    end

    def seq_violations(sources)
      sources.flat_map do |path, text|
        name = File.basename(path)
        next [] unless TCP_SOURCE.match?(name) && name != SEQ_OWNER

        code = blank_literals(text)
        offsets = integers(code).filter_map { |offset, value| offset if WRAP_VALUES.include?(value) }
        shifts = code.to_enum(:scan, SHIFT).filter_map do
          after = Regexp.last_match.end(0)
          after if integers(code[after..]).first&.then { |offset, value| offset.zero? && WRAP_SHIFTS.include?(value) }
        end
        (offsets + shifts).map { |offset| code[0...offset].count("\n") + 1 }.uniq.sort.map do |line|
          Violation.new(rule: 'seq-wrap', path: path, line: line, detail: 'sequence-space wrap arithmetic outside erx_tcp_seq')
        end
      end
    end

    # Each integer literal of code as [offset, value]; a literal erlc would
    # refuse has no value and is skipped.
    def integers(code)
      code.to_enum(:scan, INTEGER).filter_map do
        match = Regexp.last_match
        value = if match[:decimal]
                  match[:decimal].delete('_').to_i
                elsif (2..36).cover?(match[:base].to_i)
                  Integer(match[:based].delete('_'), match[:base].to_i, exception: false)
                end
        [match.begin(0), value] if value
      end
    end

    # The text with each comment, string, quoted atom and character literal
    # blanked and every line kept.
    def blank_literals(text)
      text.b.gsub(DeviceCallers::LEXEME) { Regexp.last_match(0).gsub(/[^\n]/, ' ') }
    end

    def notice_violations(sources, notice:, lock:)
      return [] if sources.empty? && notice.nil?
      return [notice_violation(nil, 'erx_net has sources but no NOTICE-freebsd')] if notice.nil?

      parsed, malformed = parse_notice(notice)
      return malformed unless malformed.empty?

      [*pin_violations(parsed, lock: lock), *pairing_violations(sources, parsed)]
    end

    def pin_violations(notice, lock:)
      { 'commit' => 'version', 'archive-sha256' => 'sha256' }.filter_map do |key, field|
        next if notice.keys.fetch(key) == lock.fetch(field)

        notice_violation(nil, "#{key} #{notice.keys.fetch(key)} is not deps.lock's #{LOCK_ID} #{field} #{lock.fetch(field)}")
      end
    end

    # Each module's header against its notice entry, every notice entry
    # against a module that exists, and no two sources under one name.
    def pairing_violations(sources, notice)
      by_name = sources.group_by { |path, _| source_name(path) }
      twice = by_name.select { |_, entries| entries.size > 1 }.map do |name, entries|
        Violation.new(rule: 'notices', path: entries.first.first, line: nil,
                      detail: "#{entries.map(&:first).join(' and ')} share the name #{name}")
      end
      headers = by_name.transform_values { |entries| entries.first }
      from_headers = headers.flat_map do |name, (path, text)|
        files = header_files(text)
        listed = notice.modules.fetch(name, {}).keys
        mismatch = files.sort == listed.sort ? [] : [Violation.new(rule: 'notices', path: path, line: nil,
                                                                   detail: "the header names FreeBSD files #{files.sort.inspect} " \
                                                                           "but #{NOTICE} lists #{listed.sort.inspect} for #{name}")]
        mismatch + stray_markers(path, text)
      end
      orphans = (notice.modules.keys - headers.keys).map do |name|
        notice_violation(nil, "#{name} is listed but erx_net has no such module")
      end
      twice + from_headers + orphans
    end

    # The lines naming "FreeBSD:" that are not well-formed markers in the
    # leading comment block.
    def stray_markers(path, text)
      header = header_lines(text).size
      text.b.each_line.with_index(1).filter_map do |raw, number|
        line = raw.chomp
        next unless line.include?('FreeBSD:')
        next if number <= header && HEADER_MARK.match?(line)

        Violation.new(rule: 'notices', path: path, line: number,
                      detail: 'a FreeBSD marker is "%% FreeBSD: PATH" alone on a line of the leading comment block')
      end
    end

    # The module name of an .erl source, or the file name of an .hrl header.
    def source_name(path) = File.extname(path) == '.erl' ? File.basename(path, '.erl') : File.basename(path)

    # The leading comment block of a source: its lines up to the first that is
    # neither a comment nor blank.
    def header_lines(text) = text.b.each_line.map(&:chomp).take_while { |line| line.start_with?('%') || line.strip.empty? }

    # The FreeBSD files named in the leading comment block of a source.
    def header_files(text) = header_lines(text).filter_map { |line| line[HEADER_MARK, :path] }

    # The notice parsed, and its malformed lines. The format is line-based:
    # '#' starts a comment line; "tag", "commit" and "archive-sha256" each
    # appear once with one value; "module NAME" starts a module's entry, and
    # each indented line under it is a FreeBSD path and the names of the
    # functions translated from it.
    def parse_notice(text)
      keys = {}
      modules = {}
      current = nil
      problems = []
      text.b.each_line.with_index(1) do |raw, number|
        line = raw.chomp
        next if line.strip.empty? || line.start_with?('#')

        words = line.split
        problem =
          if line.start_with?(' ', "\t")
            add_file(modules, current, words)
          elsif words.first == 'module'
            add_module(modules, words).tap { |refusal| current = refusal ? nil : words[1] }
          elsif NOTICE_KEYS.include?(words.first)
            add_key(keys, words)
          else
            'not a key, a module or a file line'
          end
        problems << notice_violation(number, problem) if problem
      end
      missing = NOTICE_KEYS - keys.keys
      problems << notice_violation(nil, "missing #{missing.join(', ')}") unless missing.empty?
      [Notice.new(keys: keys.freeze, modules: modules.freeze), problems]
    end

    def add_key(keys, words)
      return "a #{words.first} line is \"#{words.first} VALUE\"" unless words.size == 2
      return "#{words.first} is given twice" if keys.key?(words.first)

      keys[words.first] = words[1]
      nil
    end

    # Each add_* helper records an accepted line in the table it is given and
    # returns nil, or returns why the line is refused.
    def add_module(modules, words)
      return 'a module line is "module NAME"' unless words.size == 2 && (NAME.match?(words[1]) || words[1].end_with?('.hrl'))
      return "module #{words[1]} is listed twice" if modules.key?(words[1])

      modules[words[1]] = {}
      nil
    end

    def add_file(modules, current, words)
      return 'a file line before any module' unless current && modules.key?(current)
      path, *functions = words
      return "#{path} is not a FreeBSD source path" unless FREEBSD_PATH.match?(path)
      return "#{path} is listed twice for #{current}" if modules.fetch(current).key?(path)
      bad = functions.find { |name| !NAME.match?(name) }
      return "#{bad} is not a function name" if bad

      modules.fetch(current)[path] = functions.freeze
      nil
    end

    def notice_violation(line, detail) = Violation.new(rule: 'notices', path: NOTICE, line: line, detail: detail)
  end
end
