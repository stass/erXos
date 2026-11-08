# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'chokepoints_helper'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/syntax_tree'

# The syntax-tree rules (Chokepoints::Writers) and the reader they stand
# on (SyntaxTree), fed real clang dumps of small sources.
class ChokepointsSyntaxTreeTest < Minitest::Test
  include ChokepointsHelper

  FLAGS = %w[-std=c17 --target=aarch64-none-elf -ffreestanding].freeze

  def setup
    @directory = Dir.mktmpdir('erx-syntax-tree-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown = FileUtils.rm_rf(@directory)

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  # The writes of records in source, compiled at path below a fresh root;
  # files maps further paths (headers) to their text.
  def writes_of(path, source, records:, files: {})
    root = File.join(@directory, "tree-#{rand(1 << 32)}")
    { path => source, **files }.each do |name, text|
      FileUtils.mkdir_p(File.dirname(File.join(root, name)))
      File.write(File.join(root, name), text)
    end
    Erx::SyntaxTree.writes_in([path], records: records, root: root, compiler: compiler, flags: FLAGS,
                                      runner: @runner, env: {})
  end

  # Every syntax-tree rule catches every file of its seed, each alone.
  def test_every_syntax_tree_rule_fails_on_each_seeded_file
    refute_empty Rules::SYNTAX_TREE
    Rules::SYNTAX_TREE.each do |writers|
      writers.seed.each do |path, source|
        found = writers.violations_in_writes(writes_of(path, source, records: [writers.record]))
        refute_empty found, "#{writers.name} missed its seed #{path}"
        assert_equal [path], found.map(&:path).uniq, "#{writers.name} blamed another file for #{path}"
      end
    end
  end

  def test_the_named_rules_are_read_from_syntax_trees
    names = Rules::SYNTAX_TREE.map(&:name)
    assert_empty %w[budget-counters rights-built-in-cap cap-table-writers object-state-writers cap-slot-writers] - names
    assert_empty Chokepoints.violations(Rules::SYNTAX_TREE, names: ['kernel/core/cap.c'], imported: ->(_) { false },
                                                            read: ->(_) { flunk('a syntax-tree rule read text') })
  end

  # An atomic load reads; every other atomic operation on the member writes.
  def test_an_atomic_load_is_a_read_and_an_atomic_store_a_write
    source = "#include <stdatomic.h>\nstruct erx_object { _Atomic unsigned state; };\n" \
             "unsigned get(const struct erx_object *o) { return atomic_load_explicit(&o->state, memory_order_acquire); }\n" \
             "void put(struct erx_object *o) { atomic_store_explicit(&o->state, 2u, memory_order_release); }\n"
    writes = writes_of('kernel/core/object.c', source, records: ['erx_object'])
    assert_equal [['put', 'state', :address]], writes.map { |write| [write.function, write.member, write.how] }
  end

  # A rights value copied outside the capability core builds nothing new;
  # one written member by member does.
  def test_a_copy_is_a_write_only_where_the_rule_counts_copies
    source = "struct erx_rights { unsigned bits; };\nstruct view { struct erx_rights rights; };\n" \
             "void keep(struct view *v, struct erx_rights r) { v->rights = r; }\n"
    writes = writes_of('kernel/core/attach.c', source, records: ['erx_rights'])
    assert_equal [[:copy]], writes.map { |write| [write.how] }
    assert_empty rule('rights-built-in-cap').violations_in_writes(writes)
  end

  # A member reached through a nested record or an array element is the
  # outer record's; one reached through a pointer the record holds is not.
  def test_members_follow_dots_and_elements_but_stop_at_arrows
    source = "struct other { int used; };\n" \
             "struct erx_budget { struct { int used; } now; int lent[2]; struct other *peer; };\n" \
             "void f(struct erx_budget *b) { b->now.used = 1; b->lent[1]++; b->peer->used = 2; }\n"
    writes = writes_of('kernel/core/page.c', source, records: ['erx_budget'])
    assert_equal [['used', :assignment], ['now', :assignment], ['lent', :increment]],
                 writes.map { |write| [write.member, write.how] }
  end

  # clang writes a location's file only when it changes, so a write in a
  # header's inline function is blamed on the header, and one after it on
  # the source again.
  def test_a_write_is_blamed_on_the_file_it_is_in
    header = "struct erx_budget { int used; };\nstatic inline void h(struct erx_budget *b) { b->used = 1; }\n"
    source = "#include \"budget_view.h\"\nvoid f(struct erx_budget *b) { b->used = 2; }\n"
    writes = writes_of('kernel/core/page.c', source, records: ['erx_budget'],
                                                     files: { 'kernel/core/budget_view.h' => header })
    assert_equal [['kernel/core/budget_view.h', 2, 'h'], ['kernel/core/page.c', 2, 'f']],
                 writes.map { |write| [write.file, write.line, write.function] }
  end

  RIGHTS = "#include <stddef.h>\n#include <stdint.h>\nvoid *memcpy(void *, const void *, unsigned long);\n" \
           "typedef struct erx_rights { uint32_t bits; } erx_rights_t;\n" \
           "typedef struct erx_cap_view { uint64_t oid; erx_rights_t rights; } erx_cap_view_t;\n"

  # A record that holds rights by value is no way around the rule: not a
  # union over them, a store at the holder's offset, a copy of raw bytes
  # over the holder, nor an array initializer whose other elements clang
  # fills in.
  def test_a_holder_of_a_guarded_record_does_not_get_past_it
    {
      'union' => "void f(erx_cap_view_t *v) { union { erx_rights_t r; uint32_t u; } x = { .u = ~0u }; v->rights = x.r; }\n",
      'offset' => "void f(erx_cap_view_t *v) { *(uint32_t *)((char *)v + offsetof(erx_cap_view_t, rights)) = ~0u; }\n",
      'bytes' => "void f(erx_cap_view_t *v, const void *raw) { memcpy(v, raw, sizeof *v); }\n",
      'filler' => "void f(void) { erx_cap_view_t vs[3] = { [0].rights.bits = ~0u }; (void)vs; }\n"
    }.each do |shape, body|
      writes = writes_of('kernel/core/attach.c', RIGHTS + body, records: ['erx_rights'])
      refute_empty rule('rights-built-in-cap').violations_in_writes(writes), "missed the #{shape} shape"
    end
  end

  # Only = and the compound assignments write; a comparison reads. An array
  # member's decay outside a subscript is its address, on either side of
  # the brackets.
  def test_only_assignments_write_and_a_decayed_array_is_an_address
    source = "struct erx_budget { unsigned long lent[2]; };\n" \
             "int cmp(const struct erx_budget *b, const unsigned long *p) { return b->lent == p && b->lent[1] == 0; }\n" \
             "void rev(struct erx_budget *b) { 1[b->lent] = 7; }\n" \
             "void ext(struct erx_budget *b) { __extension__ b->lent[0] = 1; }\n" \
             "void esc(struct erx_budget *b) { unsigned long *p = b->lent; p[0] = 1; }\n"
    writes = writes_of('kernel/core/page.c', source, records: ['erx_budget'])
    assert_equal [['cmp', :address], ['rev', :assignment], ['ext', :assignment], ['esc', :address]],
                 writes.map { |write| [write.function, write.how] }
  end

  # Outside a closed set of reads, every use of a guarded member is a
  # write: a shape the walk names no write of is an unknown write, never a
  # pass. A load, sizeof and a cast to void read.
  def test_a_use_the_walk_does_not_know_is_a_write
    record = "struct erx_budget { unsigned long used, lent; };\n"
    {
      'generic' => "void f(struct erx_budget *b) { _Generic(0, int: b->used) = 1; }\n",
      'choose' => "void f(struct erx_budget *b) { __builtin_choose_expr(1, b->used, b->lent) = 1; }\n",
      'asm' => "void f(struct erx_budget *b) { __asm__ volatile(\"\" : \"=r\"(b->used)); }\n"
    }.each do |shape, body|
      writes = writes_of('kernel/core/page.c', record + body, records: ['erx_budget'])
      refute_empty writes, "missed the #{shape} shape"
      assert_equal [:unknown], writes.map(&:how).uniq, "the #{shape} shape"
    end
    reads = "unsigned long g(const struct erx_budget *b) { (void)b->lent; return sizeof b->used + b->lent; }\n"
    assert_empty writes_of('kernel/core/page.c', record + reads, records: ['erx_budget'])
  end

  def test_a_site_allows_only_its_functions
    site = Chokepoints::WriterSite.new(glob: 'kernel/core/budget.c', functions: %w[level_apply])
    write = ->(file, function) { Erx::SyntaxTree::Write.new(record: 'erx_budget', member: 'used', how: :assignment,
                                                             function: function, file: file, line: 1) }
    assert site.allows?(write.call('kernel/core/budget.c', 'level_apply'))
    refute site.allows?(write.call('kernel/core/budget.c', 'erx_reserve_charge'))
    refute site.allows?(write.call('kernel/core/page.c', 'level_apply'))
    caster = Chokepoints::WriterSite.new(glob: 'kernel/core/budget.c', functions: %w[budget_step], hows: %i[cast])
    refute caster.allows?(write.call('kernel/core/budget.c', 'budget_step'))
    assert caster.allows?(write.call('kernel/core/budget.c', 'budget_step').with(member: nil, how: :cast))
  end

  def test_a_writers_rule_without_a_seed_cannot_be_declared
    error = assert_raises(Erx::Error) do
      Chokepoints::Writers.new(name: 'unseeded', rule: 'x', design: 'x', record: 'r', sites: [], seed: {})
    end
    assert_match(/no seeded violation/, error.message)
  end

  def test_a_dump_that_is_not_a_translation_unit_is_refused
    ['[]', '{"kind":"FunctionDecl"}', '{"kind":"TranslationUnitDecl"}', '{', "#{'[' * 600}#{']' * 600}"].each do |text|
      assert_raises(Erx::Error) { Erx::SyntaxTree.parse(text, source: 'x.c') }
    end
  end

  def test_a_source_clang_refuses_fails_the_dump
    assert_raises(Erx::Error) { writes_of('kernel/core/page.c', "int f( {\n", records: ['erx_budget']) }
  end
end
