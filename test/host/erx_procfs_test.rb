# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# /proc (docs/design-live.md, "The /proc tree"): test/erlang/erx_procfs_tests.erl runs on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) against the sources as
# they are, with the inspector and its renderer, and against each seeded fault below, where
# the named case must fail. erx_object_info is compiled but its NIF is never loaded: no case
# reads a kernel record.
class ErxProcfsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  # The sources below that build/gen holds rather than the tree.
  GENERATED = %w[erlang/apps/erx/src/generated/erx_schema.erl erlang/apps/erx/src/erx_text_tables.erl].freeze
  # erx_fs first: the tree names it as its behaviour.
  BEHAVIOUR = %w[erlang/apps/erx_files/src/erx_fs.erl].freeze
  SOURCES = %w[
    erlang/apps/erx/src/generated/erx_schema.erl
    erlang/apps/erx/src/erx_text_tables.erl
    erlang/apps/erx/src/erx_text.erl
    erlang/apps/erx/src/erx_object_info.erl
    erlang/apps/erx/src/erx_kernel_records.erl
    erlang/apps/erx/src/erx_process_records.erl
    erlang/apps/erx/src/erx.erl
    erlang/apps/erx/src/erx_facets.erl
    erlang/apps/erx/src/erx_inspect_worker.erl
    erlang/apps/erx/src/erx_inspector.erl
    erlang/apps/erx_shell/src/erx_render.erl
    erlang/apps/erx_files/src/erx_procfs_core.erl
    erlang/apps/erx_files/src/erx_procfs.erl
    test/erlang/erx_procfs_tests.erl
  ].freeze
  CORE = 'erlang/apps/erx_files/src/erx_procfs_core.erl'
  TREE = 'erlang/apps/erx_files/src/erx_procfs.erl'

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  # Each fault replaces one passage of one source; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a field written without the field escape', file: CORE,
              from: '[erx_text:escape_field(Field) || Field <- Fields]', to: 'Fields',
              caught_by: 'fields_escape_and_round_trip_test'),
    Fault.new(name: 'a stopgap reporter written as the kernel', file: CORE,
              from: '{ok, Label} = erx_schema:reporter_label(Reporter),',
              to: '{ok, Label} = erx_schema:reporter_label(element(1, {kernel, Reporter})),',
              caught_by: 'every_status_kind_is_written_as_itself_test'),
    Fault.new(name: 'a status that is not ok written as a value', file: CORE,
              from: 'erx_render:value(Attr), Label]',
              to: "erx_render:value(setelement(2, Attr, {ok, <<\"0\">>})), Label]",
              caught_by: 'every_status_kind_is_written_as_itself_test'),
    Fault.new(name: 'an unsupported answer written as an empty record', file: CORE,
              from: "status({error, unsupported}, _Build) ->\n    <<\"[unsupported]\\n\">>;",
              to: "status({error, unsupported}, _Build) ->\n    <<>>;",
              caught_by: 'an_answer_without_a_record_says_why_test'),
    Fault.new(name: 'a path outside the scope walked into', file: CORE,
              from: 'named({error, scope}) -> false;', to: 'named({error, scope}) -> true;',
              caught_by: 'walk_reads_scope_as_no_entry_test'),
    Fault.new(name: 'a domain without the facet shown a tree', file: CORE,
              from: 'named({error, no_facet}) -> false;', to: 'named({error, no_facet}) -> true;',
              caught_by: 'a_domain_without_the_facet_has_an_empty_tree_test'),
    Fault.new(name: 'a literal child listed without asking the inspector', file: CORE,
              from: '{ok, Node} <- [exists(Path ++ [Literal], Lookup)]]', to: 'Node <- [path_node(Path ++ [Literal])], Lookup =/= none]',
              caught_by: 'root_lists_what_the_scope_reaches_test'),
    Fault.new(name: 'a partial listing shown whole', file: CORE,
              from: "listed(Path, {partial, Ids}) -> ids(Path, Ids) ++ [{<<\".partial\">>, {partial, Path}}];",
              to: 'listed(Path, {partial, Ids}) -> ids(Path, Ids);',
              caught_by: 'a_listing_lists_its_ids_and_markers_test'),
    Fault.new(name: 'a name with a slash read as one name', file: CORE,
              from: '        _ -> error' + "\n    end;\nchild(_Path, _Name) ->",
              to: '        _ -> resolved(length(Path) + 1, erx_schema:resolve_text(text(Path, Name)))' \
                  "\n    end;\nchild(_Path, _Name) ->",
              caught_by: 'child_refuses_names_outside_the_encoding_test'),
    Fault.new(name: 'a record cut past 64 KiB', file: CORE,
              from: '-define(MAX_RECORD, 65536).', to: '-define(MAX_RECORD, 70000).',
              caught_by: 'a_record_over_64_kib_is_cut_at_a_line_test'),
    Fault.new(name: 'a log line written without the field escape', file: CORE,
              from: '[erx_text:escape_field(Value), $\n]', to: '[Value, $\n]',
              caught_by: 'log_lines_escape_and_round_trip_test'),
    Fault.new(name: 'a log entry missing from the sequence left unsaid', file: CORE,
              from: '{missing(Seen, Sequence) ++ [entry_line(Value)], Sequence + 1}',
              to: '{[entry_line(Value) || Seen >= 0], Sequence + 1}',
              caught_by: 'log_lines_show_what_is_lost_test'),
    Fault.new(name: 'a stopped-short log shown whole', file: CORE,
              from: '{partial, []} -> [?CUT_LINE];', to: '{partial, []} -> [];',
              caught_by: 'log_lines_never_fabricate_test'),
    Fault.new(name: 'snapshots without a bound', file: TREE,
              from: '-define(MAX_SNAPSHOTS, 256).', to: '-define(MAX_SNAPSHOTS, 1000).',
              caught_by: 'the_257th_snapshot_is_refused_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(located(fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.file => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose report of one test: its name, then its verdict before the next
      # test's name; a process's error report may come between them.
      assert_match(/#{Regexp.escape(fault.caught_by)}\.\.\.(?:(?!erx_procfs_tests: ).)*?\*(?:failed|timed out)\*/m,
                   output, fault.name)
    end
  end

  private

  # Compiles the sources, with any replaced by the given text, and runs the suite.
  def eunit(replaced)
    Dir.mktmpdir('erx-procfs-test') do |work|
      compile(work, BEHAVIOUR.map { |source| File.join(ROOT, source) })
      compile(work, SOURCES.map { |source| source_path(work, source, replaced) })
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'halt(case eunit:test(erx_procfs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  def source_path(work, source, replaced)
    return located(source) unless replaced.key?(source)

    File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
  end

  # Where a source of SOURCES is: build/gen for a generated one, otherwise the tree.
  def located(source) =
    GENERATED.include?(source) ? Erx::Generated.path(source, root: ROOT) : File.join(ROOT, source)

  def compile(work, paths)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work, '-I', INCLUDE,
                                     '-o', work, *paths, stdin_data: '')
    assert status.success?, output
  end
end
