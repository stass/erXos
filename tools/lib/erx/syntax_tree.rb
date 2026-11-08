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
  # what they are. Every use of a guarded member is a write but those in a
  # closed set of reads: a load of its value, an atomic load's pointer, the
  # operand of sizeof or _Alignof, and a cast to void. The walk climbs from
  # the member through what keeps naming the same object (parentheses,
  # __extension__, a `.` member, a subscript's array, a qualifier
  # conversion) to the use, and names the writes it knows (an assignment,
  # a compound assignment, ++ or --, taking the address, an array member's
  # decay); any other use, such as a member selected by _Generic or
  # __builtin_choose_expr or an inline assembly operand, is an unknown
  # write, so a shape the walk does not know fails a rule instead of
  # passing it. The record as a whole is written by:
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
  # chokepoints): a record pointer passed through `...` or a union of
  # pointers, a declaration that disagrees with its definition in another
  # file, an embedded record zero-filled by its container's initializer,
  # and code the dumped configuration compiles out.
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
    HOW = %i[assignment increment address unknown construction copy cast union].freeze

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
    # nodes (an initializer's array_filler and a _Generic's associations as
    # well as inner) in order; and C
    # declares a record before any use of it, so the members of the guarded
    # records and their containers are known by the time an expression names
    # one.
    class Walk
      CASTS = %w[ImplicitCastExpr CStyleCastExpr].freeze
      # Casts after which the pointer no longer has the record's type.
      ESCAPING_CASTS = %w[BitCast PointerToIntegral].freeze
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
        # The nodes enclosing the one visited, outermost first.
        @ancestors = []
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
        @ancestors.push(node)
        each_child(node) { |child| visit(child, function: function, record: record) }
        @ancestors.pop
      end

      # The child nodes in document order: those of every list, and those
      # of an entry with no kind of its own (a _Generic association), which
      # belong to the node that holds the entry.
      def each_child(node, &block)
        node.each_value do |value|
          next unless value.is_a?(Array)

          value.each do |child|
            next unless child.is_a?(Hash)

            child['kind'] ? block.call(child) : each_child(child, &block)
          end
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

          copy = first_child(node) && guarded_tag(first_child(node)['type'], RECORD_TYPE)
          write.call(copy, nil, :copy) if copy
        when 'MemberExpr'
          tag, member = @fields[node['referencedMemberDecl']]
          how = tag && use_of(node)
          write.call(tag, member, member ? how : :union) if how
        when 'InitListExpr'
          tag = own_tag(node['type'])
          write.call(tag, nil, :construction) if tag
        when *CASTS
          operand = first_child(node)
          if ESCAPING_CASTS.include?(node['castKind']) && operand
            tag = guarded_tag(operand['type'], RECORD_POINTER)
            # A pointer to the same record under other qualifiers, as a
            # comparison converts it, still has the record's type.
            write.call(tag, nil, :cast) if tag && guarded_tag(node['type'], RECORD_POINTER) != tag
          end
        end
      end

      # What the use of a guarded member does: nil for a read, otherwise how
      # it writes. The climb passes what keeps naming the member's object
      # and stops at the first use; a use outside the closed sets below is
      # :unknown.
      def use_of(member)
        above = @ancestors.reverse
        child = member
        above.each_with_index do |parent, index|
          use = use_in(parent, child, above.drop(index + 1))
          return use unless use == :same
          child = parent
        end
        :unknown
      end

      # How parent uses child: :same when it still names child's object,
      # nil when it reads it, otherwise how it writes it. outer holds the
      # nodes above parent, nearest first.
      def use_in(parent, child, outer)
        left = first_child(parent).equal?(child)
        case parent['kind']
        when 'ParenExpr' then :same
        when 'MemberExpr' then parent['isArrow'] ? :unknown : :same
        when 'ArraySubscriptExpr' then subscript_base(parent).equal?(child) ? :same : :unknown
        when 'UnaryOperator' then unary_use(parent, outer)
        when 'ImplicitCastExpr' then implicit_cast_use(parent, outer.first)
        when 'CStyleCastExpr' then parent['castKind'] == 'ToVoid' ? nil : :unknown
        when 'UnaryExprOrTypeTraitExpr' then nil
        when 'BinaryOperator' then parent['opcode'] == '=' && left ? :assignment : :unknown
        when 'CompoundAssignOperator' then left ? :assignment : :unknown
        else :unknown
        end
      end

      def unary_use(parent, outer)
        case parent['opcode']
        when '__extension__' then :same
        when '++', '--' then :increment
        when '&' then atomic_load_pointer?(parent, outer) ? nil : :address
        else :unknown
        end
      end

      # A load reads the value; a qualifier conversion keeps the object; an
      # array decays to a pointer that writes it unless a subscript takes
      # the element.
      def implicit_cast_use(cast, enclosing)
        case cast['castKind']
        when 'LValueToRValue' then nil
        when 'NoOp' then :same
        when 'ArrayToPointerDecay'
          subscript = enclosing && enclosing['kind'] == 'ArraySubscriptExpr'
          subscript && subscript_base(enclosing).equal?(cast) ? :same : :address
        else :unknown
        end
      end

      # Whether address is the pointer an atomic load reads through,
      # through parentheses.
      def atomic_load_pointer?(address, outer)
        child = address
        outer.each do |node|
          return ATOMIC_LOADS.include?(node['name']) && first_child(node).equal?(child) if node['kind'] == 'AtomicExpr'
          return false unless node['kind'] == 'ParenExpr'

          child = node
        end
        false
      end

      # The array side of a subscript, whichever operand it is (1[a] is a[1]).
      def subscript_base(node)
        children(node).find { |child| child.dig('type', 'qualType').to_s.include?('*') } || first_child(node)
      end

      def children(node) = node['inner'].is_a?(Array) ? node['inner'].grep(Hash) : []

      def first_child(node) = children(node).first

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
