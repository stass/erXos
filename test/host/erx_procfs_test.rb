# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# /proc (docs/design-live.md, "The /proc tree"): test/erlang/erx_procfs_tests.erl runs on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) against the sources as
# they are, with the inspector and its renderer, and against each seeded fault below, where
# the named case must fail. erx_object_info is compiled but its NIF is never loaded: no case
# reads a kernel record.
class ErxProcfsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  # erx_fs first: the tree names it as its behaviour.
  BEHAVIOUR = %w[erlang/apps/erx_files/src/erx_fs.erl].freeze
  SOURCES = %w[
    erlang/apps/erx/src/generated/erx_schema.erl
    erlang/apps/erx/src/erx_text_tables.erl
    erlang/apps/erx/src/erx_text.erl
    erlang/apps/erx/src/erx_object_info.erl
    erlang/apps/erx/src/erx_kernel_records.erl
    erlang/apps/erx/src/erx_process_records.erl
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
              from: '{error, scope} -> {error, enoent};', to: '{error, scope} -> {ok, {dir, Path}};',
              caught_by: 'walk_reads_scope_as_no_entry_test'),
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
      original = File.read(File.join(ROOT, fault.file))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit({ fault.file => original.sub(fault.from) { fault.to } })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      # EUnit's verbose line for one test: its name, then its verdict on the same line.
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*(?:failed|timed out)\*/, output, fault.name)
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
    return File.join(ROOT, source) unless replaced.key?(source)

    File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
  end

  def compile(work, paths)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work, '-I', INCLUDE,
                                     '-o', work, *paths, stdin_data: '')
    assert status.success?, output
  end
end
