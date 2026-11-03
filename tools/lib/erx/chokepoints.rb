# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'strscan'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'stack_graph'

module Erx
  # The chokepoint checks: every rule of the form "only X does Y" as data
  # (docs/design-kernel.md, "Chokepoint checks"; docs/design-stopgap.md,
  # "Verification and testing"). A rule names the files it reads, what it
  # forbids there and the sites allowed to do it anyway. The rules
  # themselves are declared in chokepoint_rules.rb; this file is the
  # machinery that evaluates them.
  #
  # The kinds form a closed set:
  # * Forbidden: a pattern that may match only at an allowed site, over the
  #   C view of each file in scope (comments removed, strings kept, so
  #   inline assembly and header names stay visible).
  # * IncludeForm: every include directive in scope names a header by a
  #   plain path, so no computed include or included non-header can carry
  #   text past a Forbidden rule.
  # * Pending: a rule whose sites do not exist yet. It checks nothing, and
  #   it fails the moment a file it awaits appears, so the code it polices
  #   cannot land before its check.
  # * Elsewhere: a rule another check enforces; the registry names that
  #   check and the test that seeds its violation, which must be listed.
  # * Callers: only listed functions call a function, read from the cores'
  #   call graph rather than from text; the stack proof evaluates it on the
  #   graph of every level it proves.
  #
  # Every active and call-graph rule carries a seeded violation, and the
  # host test feeds each seed to its rule and requires a failure
  # (test/host/chokepoints_test.rb).
  module Chokepoints
    # The extensions a C, C++ or assembler build reads. IncludeForm keeps
    # anything else out of a compile.
    # Extensions compare in lower case, as a case-insensitive file system
    # and the compiler driver see them.
    C_FAMILY = %w[.c .h .s .sx .cpp .cc .cxx .cp .c++ .hh .hpp .inc].freeze
    CPP = %w[.cpp .cc .cxx .cp .c++ .hh .hpp].freeze

    def self.extension(path) = File.extname(path).downcase
    MAX_FILE_BYTES = 16 * 1024 * 1024
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    # The opening of an include directive in every spelling a compiler
    # accepts, up to its operand; every rule about includes starts here.
    INCLUDE_PREFIX = /\A\s*(?:#|%:)\s*(?:include|include_next|import)\b\s*/
    DIRECTIVE = /#{INCLUDE_PREFIX}(?<operand>.*)\z/m
    # A header by name: a quoted or bracketed path of plain segments ending
    # in .h; C++ files may also name one of the listed standard headers,
    # whose files are the toolchain's, not the tree's.
    HEADER_PATH = %r{[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*\.h}
    PLAIN_INCLUDE = /\A\s*(?:"#{HEADER_PATH}"|<#{HEADER_PATH}>)\s*\z/
    STANDARD_CPP_HEADERS = %w[atomic cstdarg cstddef cstdint cstdio cstdlib cstring climits initializer_list limits
                              new type_traits utility].freeze
    STANDARD_CPP_INCLUDE = /\A\s*<(?:#{STANDARD_CPP_HEADERS.join('|')})>\s*\z/

    Violation = Data.define(:rule, :path, :line, :detail) do
      def to_s = "chokepoint #{rule}: #{path}#{line ? ":#{line}" : ''}: #{detail}"
    end

    # The files a rule reads: erXos's own C-family sources (own), plus any
    # listed file matching an extra glob, minus any matching an except glob.
    Scope = Data.define(:own, :extra, :except) do
      def initialize(own:, extra: [], except: [])
        super(own: own, extra: extra.freeze, except: except.freeze)
      end

      def covers?(path, imported:)
        return false unless C_FAMILY.include?(Chokepoints.extension(path))
        return false if except.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

        (own && !imported) || extra.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }
      end
    end

    # An allowed site: files matching glob may hold a match, and when
    # permits is a pattern, only a match the whole of which it accepts.
    Site = Data.define(:glob, :permits) do
      def initialize(glob:, permits: nil) = super

      def allows?(path, text)
        File.fnmatch?(glob, path, GLOB_FLAGS) && (permits.nil? || permits.match?(text))
      end
    end

    # A seed is the violation a rule must catch: path => text for a text
    # rule, function => reach for a call-graph rule (Callers).
    module Seeded
      def validate_seed!
        return if seed.is_a?(Hash) && !seed.empty? &&
                  seed.all? { |path, text| path.is_a?(String) && text.is_a?(String) }

        raise Error, "chokepoint #{name} has no seeded violation"
      end
    end

    Forbidden = Data.define(:name, :rule, :design, :scope, :pattern, :sites, :seed) do
      include Seeded

      def initialize(name:, rule:, design:, scope:, pattern:, seed:, sites: [])
        super(name: name, rule: rule, design: design, scope: scope, pattern: pattern, sites: sites.freeze,
              seed: seed.freeze)
        validate_seed!
      end

      def violations(path, view)
        view.lines.flat_map do |line|
          Chokepoints.matches(line.text, pattern).filter_map do |found|
            next if sites.any? { |site| site.allows?(path, found) }

            Violation.new(rule: name, path: path, line: line.number, detail: "forbidden here: #{found.strip}")
          end
        end
      end
    end

    IncludeForm = Data.define(:name, :rule, :design, :scope, :seed) do
      include Seeded

      def initialize(name:, rule:, design:, scope:, seed:)
        super
        validate_seed!
      end

      def violations(path, view)
        view.lines.filter_map do |line|
          match = DIRECTIVE.match(line.text)
          next unless match

          operand = match[:operand]
          next if PLAIN_INCLUDE.match?(operand) && !operand.include?('..')
          next if CPP.include?(Chokepoints.extension(path)) && STANDARD_CPP_INCLUDE.match?(operand)

          Violation.new(rule: name, path: path, line: line.number,
                        detail: "include names no plain header path: #{operand.strip}")
        end
      end
    end

    # awaits are the globs of the scope a pending rule polices; existing
    # lists the files already there that it does not yet check. Any other
    # file in its scope fails, and so does an existing entry no longer
    # listed, so the list only shrinks.
    Pending = Data.define(:name, :rule, :design, :awaits, :existing, :reason) do
      def initialize(name:, rule:, design:, awaits:, reason:, existing: [])
        raise Error, "pending chokepoint #{name} awaits nothing" if awaits.empty?

        super(name: name, rule: rule, design: design, awaits: awaits.freeze, existing: existing.freeze,
              reason: reason)
      end

      def violations_in(names)
        landed = names.filter_map do |path|
          next if existing.include?(path)
          next unless awaits.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS | File::FNM_DOTMATCH) }

          Violation.new(rule: name, path: path, line: nil,
                        detail: "a site of this pending rule exists; land its check with it (#{reason})")
        end
        stale = (existing - names).map do |path|
          Violation.new(rule: name, path: path, line: nil, detail: 'an exempt existing file is no longer listed')
        end
        landed + stale
      end
    end

    Elsewhere = Data.define(:name, :rule, :design, :check, :test) do
      def violations_in(names)
        return [] if names.include?(test)

        [Violation.new(rule: name, path: test, line: nil,
                       detail: "the test that seeds this rule's violation (#{check}) is not in the tree")]
      end
    end

    # How a Callers seed function reaches its callee.
    CALLER_REACHES = %w[call tail_jump].freeze

    # Callers: only the listed exported functions call or tail-jump to
    # callee. It reads the cores' call graph, which the stack proof builds
    # from the relocations of every core at each optimisation level, so a
    # call that inlining hides at one level shows at -O0; a call through a
    # pointer is refused by the stack proof unless its targets are listed.
    # The text evaluation passes over it, and the stack proof hands each
    # level's graph to enforce_call_graph. Its seed maps each function it
    # must refuse, spelled "object:name" when file-local, to how that
    # function reaches callee: "call" or "tail_jump".
    Callers = Data.define(:name, :rule, :design, :callee, :callers, :seed) do
      include Seeded

      def initialize(name:, rule:, design:, callee:, callers:, seed:)
        super(name: name, rule: rule, design: design, callee: callee, callers: callers.freeze, seed: seed.freeze)
        validate_seed!
        raise Error, "chokepoint #{name} seeds an unknown reach" unless (seed.values - CALLER_REACHES).empty?
      end

      def violations_in_graph(graph)
        graph.functions.each_value.filter_map do |function|
          targets = function.calls + function.tail_jumps
          next unless targets.any? { |site| site.target.global? && site.target.name == callee }
          next if function.id.global? && callers.include?(function.id.name)

          Violation.new(rule: name, path: function.location, line: nil, detail: "#{function.id} calls #{callee}")
        end
      end
    end

    # One logical source line: its text after splicing and comment removal,
    # and the physical line it starts on.
    Line = Data.define(:number, :text)

    # The C view of a file: translation phases 1 to 3 as far as a text check
    # needs them. Backslash-newlines are spliced, so no rule can be split
    # across lines, then comments become a space. String and character
    # literals stay, since header names and inline assembly live in them;
    # inside them the escapes \n \t \r \v \f read as a space, so "nop\n\tsvc"
    # shows its instruction, and literals adjacent on a line are joined as
    # the compiler joins them. Identifiers are read whole, so a literal
    # prefix (u8'a', L"x") or a digit inside a name opens nothing, and a
    # number may hold C++ digit separators (0xffff'0000).
    #
    # Where the view and a compiler could disagree, the view refuses the
    # file rather than guess, so a misreading can fail a rule but not hide
    # code from one: an unterminated comment or literal, a raw string
    # literal of any prefix, and any trigraph sequence (C17 has trigraphs
    # and C++20 does not, and a header can be read as either).
    class CView
      TOKEN = %r{
        (?<comment>//[^\n]*|/\*.*?\*/)
        | (?<literal>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
        | (?<raw>(?:u8|u|U|L)?R"[^\s()\\"]{0,16}\()
        | (?<identifier>[A-Za-z_][A-Za-z0-9_]*)
        | (?<number>[0-9](?:[0-9A-Za-z_.]|'(?=[0-9A-Za-z_]))*)
        | (?<open>/\*|["'])
        | (?<text>[^/"'A-Za-z0-9_]+|.)
      }mx
      TRIGRAPH = %r{\?\?[=/'()!<>-]}n
      ESCAPE = /\\[ntrvf]/n
      ADJACENT_LITERALS = /"[ \t]*"/n

      attr_reader :lines, :errors

      # A .S or .sx file keeps its comments, whose syntax is the target's
      # (Fiasco's 32-bit sources use @, and a quote there opens nothing); a
      # .s file is read by no preprocessor, so it is neither spliced nor
      # stripped.
      def self.for(bytes, path:)
        kind = case File.extname(path)
               when '.s' then :assembler
               when '.S', '.sx' then :preprocessed_assembler
               else :c
               end
        new(bytes, kind: kind)
      end

      def initialize(bytes, kind:)
        bytes = bytes.b
        text, starts = kind == :assembler ? [bytes, (1..(bytes.count("\n") + 1)).to_a] : splice(bytes)
        @errors = []
        @errors << Line.new(number: starts.first, text: 'trigraph sequence') if TRIGRAPH.match?(text)
        text = strip_comments(text, starts: starts) if kind == :c
        @lines = split_lines(text, starts: starts).freeze
      end

      private

      # Joins each backslash-newline's lines. Returns the joined text and,
      # for every logical line, the physical line it starts on.
      def splice(text)
        starts = [1]
        physical = 1
        output = +''.b
        text.split(/(\\[ \t\r]*\n|\n)/n).each do |piece|
          if piece.start_with?('\\') && piece.end_with?("\n")
            physical += 1
          elsif piece == "\n"
            physical += 1
            output << "\n"
            starts << physical
          else
            output << piece
          end
        end
        [output, starts]
      end

      def strip_comments(text, starts:)
        scanner = StringScanner.new(text)
        output = +''.b
        until scanner.eos?
          scanner.scan(TOKEN)
          if scanner[:comment]
            output << ' ' << ("\n" * scanner[:comment].count("\n"))
          elsif scanner[:literal]
            output << scanner[:literal].gsub(ESCAPE, ' ')
          elsif scanner[:raw]
            refuse(text, scanner, 'C++ raw string literal', starts: starts)
            output << scanner[:raw]
          elsif scanner[:open]
            refuse(text, scanner, "unterminated #{scanner[:open] == '/*' ? 'comment' : 'literal'}", starts: starts)
            output << scanner[:open]
          else
            output << scanner.matched
          end
        end
        output.gsub(ADJACENT_LITERALS, '')
      end

      def refuse(text, scanner, what, starts:)
        line = text.byteslice(0, scanner.pos).count("\n")
        @errors << Line.new(number: starts.fetch(line, starts.last), text: what)
      end

      def split_lines(text, starts:)
        text.split("\n", -1).each_with_index.map do |line, index|
          Line.new(number: starts.fetch(index, starts.last), text: line)
        end
      end
    end

    module_function

    # Every whole match of pattern in text, left to right.
    def matches(text, pattern)
      found = []
      position = 0
      while position <= text.bytesize && (match = pattern.match(text, position))
        found << match[0]
        position = match.end(0) > match.begin(0) ? match.end(0) : match.end(0) + 1
      end
      found
    end

    # The violations of rules over the listed names. imported answers whether
    # a name is an imported upstream file; read returns a name's bytes. Pure
    # given read, so tests evaluate rules over files held in memory.
    def violations(rules, names:, imported:, read:)
      views = {}
      view_of = lambda do |path|
        views[path] ||= CView.for(read.call(path), path: path)
      end
      rules.flat_map do |rule|
        case rule
        in Forbidden | IncludeForm
          names.select { |path| rule.scope.covers?(path, imported: imported.call(path)) }.flat_map do |path|
            view = view_of.call(path)
            view.errors.map do |error|
              Violation.new(rule: rule.name, path: path, line: error.number, detail: "cannot read as C: #{error.text}")
            end + rule.violations(path, view)
          end
        in Pending | Elsewhere
          rule.violations_in(names)
        in Callers
          # Read from the call graph by the stack proof, not from text.
          []
        end
      end.uniq
    end

    # The violations of the call-graph rules over one level's graph.
    def call_graph_violations(rules, graph)
      rules.flat_map { |rule| rule.violations_in_graph(graph) }.uniq
    end

    # Raises Error listing every call-graph violation; the stack proof calls
    # it on each level's graph before proving it.
    def enforce_call_graph(rules, graph)
      found = call_graph_violations(rules, graph)
      return true if found.empty?

      raise Error, (["#{found.size} chokepoint violation(s):"] + found.first(50).map(&:to_s)).join("\n")
    end

    # A call graph of functions, given as {"name" or "object:name" => reach},
    # each reaching callee once by that reach.
    def seeded_graph(functions, callee:)
      target = StackGraph::Name.new(name: callee, object: nil)
      site = [StackGraph::Site.new(offset: 0, target: target)].freeze
      nodes = functions.to_h do |spec, reach|
        object, name = spec.include?(':') ? spec.split(':', 2) : [nil, spec]
        id = StackGraph::Name.new(name: name, object: object)
        [id, StackGraph::Function.new(id: id, object: object || 'seeded.o', location: 'seeded.c:1', frame_bytes: 16,
                                      calls: reach == 'call' ? site : [], tail_jumps: reach == 'tail_jump' ? site : [],
                                      indirect_calls: [], indirect_branches: [])]
      end
      StackGraph::Graph.new(functions: nodes.freeze, externals: [target].freeze)
    end

    # Enforces rules over a checkout's listed names, reading each file once
    # through a guard: a listed link must resolve, inside the root, to a
    # listed regular file, and every file is bounded. Diagnostics carry raw
    # names; the CLI's sink escapes them.
    def enforce(rules, root:, names:, imported:)
      canonical = File.realpath(root)
      listed = names.to_h { |name| [name, true] }
      read = lambda do |path|
        target = File.realpath(File.join(root, path))
        relative = target.delete_prefix("#{canonical}/")
        unless target.start_with?("#{canonical}/") && listed.key?(relative) && File.file?(target)
          raise Error, "chokepoint input is not a listed regular file: #{path}"
        end

        BoundedFile.read(target, maximum: MAX_FILE_BYTES)
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise Error, "chokepoint input does not resolve: #{path}"
      end
      present = names.select { |name| File.exist?(File.join(root, name)) || File.symlink?(File.join(root, name)) }
      found = violations(rules, names: present, imported: imported, read: read)
      return true if found.empty?

      raise Error, (["#{found.size} chokepoint violation(s):"] + found.first(50).map(&:to_s)).join("\n")
    end
  end
end
