# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'set'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'json_input'

module Erx
  # The syntax-tree leg of the chokepoint checks (docs/design-kernel.md,
  # "Chokepoint checks"): clang's JSON dump of a C source's syntax tree, and
  # the writes it finds there to the members of the records a rule guards.
  #
  # The tree is the source after preprocessing, so a member a macro reaches,
  # a name it pastes together or a typedef of the record are all seen as
  # what they are. A write is any of:
  # * an assignment, compound assignment, ++ or -- of a member;
  # * taking a member's address, or letting an array member decay to a
  #   pointer, which lets anything write it later, except as the pointer an
  #   atomic load reads through or the base of a subscript;
  # * an initializer list of the record's type (a definition with an
  #   initializer, or a compound literal), which writes every member;
  # * an assignment of the whole record (a copy), which writes every member;
  # * a cast of a pointer to the record into another pointer type or an
  #   integer, after which a store at a hand-copied offset writes any member.
  # A record that holds a guarded one by value is its container: a copy of
  # a container, or a cast of a pointer to one, writes the guarded record
  # too, and so does a write to any member of a union that holds one.
  # A member reached through an array element or a nested struct of the
  # record counts as the record's member; one reached through a pointer the
  # record holds belongs to the record that pointer names.
  #
  # What it does not see, a residual for trusted code (TODO.md, kernel
  # chokepoints): a pointer passed through `...` or a union of pointers, a
  # declaration that disagrees with its definition in another file, an
  # inline assembly operand, a member selected by _Generic or
  # __builtin_choose_expr, an embedded record zero-filled by its
  # container's initializer, and code the dumped configuration compiles out.
  #
  # The dump is untrusted only in the sense that a bug in clang or a hostile
  # source could make it large, deep or oddly shaped: it is bounded in bytes
  # and nesting, a node not shaped as expected is passed over, and anything
  # not shaped as a translation unit is refused.
  module SyntaxTree
    MAX_TREE_BYTES = 128 << 20
    # Ten times the deepest dump of the cores (about 45 levels); the JSON
    # reader and this walk both recurse once per level.
    MAX_NESTING = 512
    DEADLINE = 120
    # The archive's flags that only a compile uses, which clang refuses as
    # unused (-Werror) with -fsyntax-only.
    COMPILE_ONLY_FLAGS = %w[-fstack-usage -ffunction-sections].freeze
    # -w: a warning would land in the dump's log beside the JSON; the
    # archive's own compile enforces the warnings.
    DUMP = %w[-w -fsyntax-only -Xclang -ast-dump=json].freeze
    HOW = %i[assignment increment address construction copy cast union].freeze

    Location = Data.define(:file, :line)

    # One write: the record's tag, the member (nil when the write reaches the
    # whole record), how it was written (one of HOW), the function it is in
    # (nil at file scope) and where. file is as clang names it, relative to
    # the compile's directory for the tree's own files.
    Write = Data.define(:record, :member, :how, :function, :file, :line) do
      def to_s = "#{record}#{member ? ".#{member}" : ''} #{how} in #{function || 'file scope'}"
    end

    module_function

    # The tree of source, compiled from root with flags in env. The dump goes
    # to the runner's log, which is read once, bounded, and removed once it
    # parses, since a core's tree with its headers runs to tens of
    # megabytes; a log that does not parse is kept for diagnosis.
    def dump(source:, root:, compiler:, flags:, runner:, env:)
      result = runner.run([compiler, *(flags - COMPILE_ONLY_FLAGS), *DUMP, source],
                          name: 'syntax-tree', deadline: DEADLINE, chdir: root, env: env,
                          output_limit: MAX_TREE_BYTES)
      log = result.fetch('log')
      begin
        tree = parse(BoundedFile.read(log, maximum: MAX_TREE_BYTES), source: source)
      rescue Error => error
        raise Error, "#{error.message}; log: #{log}"
      end
      File.unlink(log)
      tree
    end

    # The dump as a tree, through the one JSON reader, bounded in bytes and
    # depth.
    def parse(text, source:)
      tree = JsonInput.parse(text, max_bytes: MAX_TREE_BYTES, max_nesting: MAX_NESTING,
                                   label: "syntax tree of #{source}")
      unless tree.is_a?(Hash) && tree['kind'] == 'TranslationUnitDecl' && tree['inner'].is_a?(Array)
        raise Error, "syntax tree of #{source}: not a translation unit"
      end

      tree
    end

    # Every write in tree to a member of a record whose tag is in records.
    def writes(tree, records:) = Walk.new(records).call(tree)

    # The writes of records across sources, each dumped as dump does.
    def writes_in(sources, records:, **dump_options)
      sources.flat_map { |source| writes(dump(source: source, **dump_options), records: records) }
    end

    # One pass over a tree in document order. clang writes a location's file
    # and line only when they differ from the location written before it, so
    # the walk carries the last ones it saw and descends every list of child
    # nodes (an initializer's array_filler as well as inner) in order; and C
    # declares a record before any use of it, so the members of the guarded
    # records and their containers are known by the time an expression names
    # one.
    class Walk
      CASTS = %w[ImplicitCastExpr CStyleCastExpr].freeze
      # Casts after which the pointer no longer has the record's type.
      ESCAPING_CASTS = %w[BitCast PointerToIntegral].freeze
      # Casts that keep naming the same object on the way to a member.
      TRANSPARENT_CASTS = %w[ArrayToPointerDecay NoOp].freeze
      ATOMIC_LOADS = %w[__c11_atomic_load __atomic_load __atomic_load_n].freeze
      QUALIFIERS = /\b(?:const|volatile|restrict|_Atomic)\b/
      # A record, or an array of them, as a type spells it.
      RECORD_TYPE = /\A(?:struct|union) (\w+)(?: \[\d*\])*\z/
      RECORD_POINTER = /\A(?:struct|union) (\w+) \*\z/

      def initialize(records)
        @guarded = records.to_set.freeze
        # Each record tag holding a guarded record by value => that tag.
        @containers = {}
        # Each guarded member's FieldDecl id => [tag, member name or nil].
        @fields = {}
        # Nodes that read through a member's address: an atomic load's
        # pointer, a subscript's base.
        @reads = Set.new
        # Each typedef name => the type it names, as spelled.
        @typedefs = {}
        @file = nil
        @line = nil
        @found = []
      end

      def call(tree)
        visit(tree, function: nil, record: nil)
        @found.uniq.freeze
      end

      private

      # record is the tag of the record whose members are being declared.
      def visit(node, function:, record:)
        locate(node['loc'])
        named_at = here
        range = node['range']
        if range.is_a?(Hash)
          locate(range['begin'])
          begin_at = here
          locate(range['end'])
        end
        kind = node['kind']
        record = enter_record(node, record, function: function, at: named_at) if kind == 'RecordDecl'
        register_field(node, record) if kind == 'FieldDecl'
        register_typedef(node) if kind == 'TypedefDecl'
        function = node['name'] if kind == 'FunctionDecl' && node['name'].is_a?(String)
        note_writes(node, kind, function: function, at: begin_at || named_at)
        node.each_value do |value|
          next unless value.is_a?(Array)

          value.each { |child| visit(child, function: function, record: record) if child.is_a?(Hash) && child['kind'] }
        end
      end

      def here = Location.new(file: @file, line: @line)

      # A location is written bare, or as a spelling and an expansion when a
      # macro is involved; each part may carry a new file and line.
      def locate(location)
        return unless location.is_a?(Hash)

        if location.key?('spellingLoc') || location.key?('expansionLoc')
          locate(location['spellingLoc'])
          locate(location['expansionLoc'])
        elsif location.key?('offset')
          @file = location['file'] if location['file'].is_a?(String)
          @line = location['line'] if location['line'].is_a?(Integer)
        end
      end

      # A named record is its own; an anonymous one nested in a record lends
      # its members to that record. A record holding a guarded one by value
      # becomes its container. A union holding one is itself a write where
      # it is declared, since an initializer or a store through any of its
      # other members rewrites the guarded one, and it guards every member.
      def enter_record(node, enclosing, function:, at:)
        name = node['name']
        tag = name.is_a?(String) && !name.empty? ? name : enclosing
        held = children(node).filter_map { |child| guarded_tag(child['type'], RECORD_TYPE) if child['kind'] == 'FieldDecl' }
        return tag if held.empty?

        @containers[name] = held.first if name.is_a?(String) && !name.empty? && !@guarded.include?(name)
        if node['tagUsed'] == 'union'
          add(record: held.first, member: nil, how: :union, function: function, at: at)
          children(node).each { |child| @fields[child['id']] = [held.first, nil] if child['kind'] == 'FieldDecl' }
        end
        tag
      end

      def register_field(node, record)
        @fields[node['id']] ||= [record, node['name']] if record && @guarded.include?(record)
      end

      def register_typedef(node)
        name = node['name']
        spelled = spelling(node['type'])
        @typedefs[name] = spelled if name.is_a?(String) && spelled
      end

      def note_writes(node, kind, function:, at:)
        write = ->(tag, member, how) { add(record: tag, member: member, how: how, function: function, at: at) }
        case kind
        when 'BinaryOperator'
          return unless node['opcode'] == '='

          member_writes(first_child(node), how: :assignment, &write)
          copy = first_child(node) && guarded_tag(first_child(node)['type'], RECORD_TYPE)
          write.call(copy, nil, :copy) if copy
        when 'CompoundAssignOperator'
          member_writes(first_child(node), how: :assignment, &write)
        when 'UnaryOperator'
          case node['opcode']
          when '++', '--' then member_writes(first_child(node), how: :increment, &write)
          when '&' then member_writes(first_child(node), how: :address, &write) unless @reads.include?(node['id'])
          end
        when 'ArraySubscriptExpr'
          base = subscript_base(node)
          @reads << base['id'] if base
        when 'AtomicExpr'
          pointer = strip(first_child(node))
          @reads << pointer['id'] if ATOMIC_LOADS.include?(node['name']) && pointer
        when 'InitListExpr'
          tag = own_tag(node['type'])
          write.call(tag, nil, :construction) if tag
        when *CASTS
          operand = first_child(node)
          if node['castKind'] == 'ArrayToPointerDecay'
            member_writes(operand, how: :address, &write) unless @reads.include?(node['id'])
          elsif ESCAPING_CASTS.include?(node['castKind']) && operand
            tag = guarded_tag(operand['type'], RECORD_POINTER)
            # A pointer to the same record under other qualifiers, as a
            # comparison converts it, still has the record's type.
            write.call(tag, nil, :cast) if tag && guarded_tag(node['type'], RECORD_POINTER) != tag
          end
        end
      end

      # Each guarded member along the path from an lvalue to the object it is
      # in: through parentheses, __extension__, array elements and `.`
      # members, up to the first `->`, which leaves the object.
      def member_writes(expression, how:)
        node = expression
        while node
          case node['kind']
          when 'ParenExpr' then node = first_child(node)
          when 'UnaryOperator'
            break unless node['opcode'] == '__extension__'

            node = first_child(node)
          when 'ImplicitCastExpr'
            break unless TRANSPARENT_CASTS.include?(node['castKind'])

            node = first_child(node)
          when 'ArraySubscriptExpr' then node = subscript_base(node)
          when 'MemberExpr'
            tag, member = @fields[node['referencedMemberDecl']]
            yield tag, member, (member ? how : :union) if tag
            break if node['isArrow']

            node = first_child(node)
          else break
          end
        end
      end

      # The array side of a subscript, whichever operand it is (1[a] is a[1]).
      def subscript_base(node)
        children(node).find { |child| child.dig('type', 'qualType').to_s.include?('*') } || first_child(node)
      end

      def children(node) = node['inner'].is_a?(Array) ? node['inner'].grep(Hash) : []

      def first_child(node) = children(node).first

      def strip(node)
        node = first_child(node) while node && node['kind'] == 'ParenExpr'
        node
      end

      def add(record:, member:, how:, function:, at:)
        @found << Write.new(record: record, member: member, how: how, function: function, file: at.file, line: at.line)
      end

      # The guarded tag a type names, through typedefs, qualifiers and
      # containers: what a copy or a cast of that type writes.
      def guarded_tag(type, shape)
        tag = spelled_tag(type, shape)
        @guarded.include?(tag) ? tag : @containers[tag]
      end

      # The guarded tag a type names itself, not through a container: what
      # an initializer list builds.
      def own_tag(type)
        tag = spelled_tag(type, RECORD_TYPE)
        tag if @guarded.include?(tag)
      end

      def spelled_tag(type, shape)
        spelled = spelling(type)
        shape.match(spelled)&.[](1) if spelled
      end

      # A type as clang spells it, without qualifiers and with a leading
      # typedef name replaced by what it names: clang desugars erx_budget_t
      # but not erx_budget_t *. Typedefs are declared before use, and the
      # chain is bounded so a malformed dump cannot loop.
      def spelling(type)
        return nil unless type.is_a?(Hash)

        spelled = type['desugaredQualType'] || type['qualType']
        return nil unless spelled.is_a?(String)

        spelled = spelled.gsub(QUALIFIERS, ' ').squeeze(' ').strip
        8.times do
          name, rest = spelled.match(/\A(\w+)(.*)\z/)&.captures
          break unless name && @typedefs.key?(name) && !%w[struct union enum].include?(name)

          spelled = "#{@typedefs.fetch(name)}#{rest}".squeeze(' ')
        end
        spelled
      end
    end
  end
end
