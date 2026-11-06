# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_ramfs_tests.erl, the EUnit cases of /tmp's grant over its real tree,
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) against the sources
# as they are. Then each seeded fault of docs/design-tmp.md's "Fids and nodes" and "Grammar
# on the local route" items, applied to a copy of one module, must fail the case named for
# it, which shows that case runs the code the fault breaks.
class ErxRamfsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APP = 'erlang/apps/erx_files/src'
  SOURCES = %W[
    otp/erts/preloaded/src/erx_9p_grammar.erl
    #{APP}/erx_fs_grant.erl #{APP}/erx_fs.erl #{APP}/erx_fs_version.erl
    #{APP}/erx_ramfs.erl #{APP}/erx_ramfs_core.erl
  ].freeze
  TESTS = 'test/erlang/erx_ramfs_tests.erl'

  Fault = Data.define(:name, :file, :from, :to, :caught_by)

  FAULTS = [
    Fault.new(name: 'a tree that gives the next node a freed inode number', file: "#{APP}/erx_ramfs_core.erl",
              from: 'case decide(Request, Stamp, Now, Tree) of',
              to: 'case decide(Request, case Request of {make, _, _, _} -> map_size(Tree#tree.nodes) + 1; ' \
                  '_ -> Stamp end, Now, Tree) of',
              caught_by: 'a_fid_never_reaches_a_file_made_after_its_own_test'),
    Fault.new(name: 'a grant that skips the checks for a sender in its own domain', file: "#{APP}/erx_fs_grant.erl",
              from: "decode(Frame, #grant{client = Client, rights = Rights}) ->\n",
              to: "decode({erx_9p, Alias, Owner, Request}, #grant{}) when is_reference(Alias), is_pid(Owner), " \
                  "node(Alias) =:= node() ->\n    {admit, Alias, Owner, Request};\n" \
                  "decode(Frame, #grant{client = Client, rights = Rights}) ->\n",
              caught_by: 'names_that_break_the_grammar_are_refused_before_a_callback_test'),
    Fault.new(name: "a grant that does not clunk a dead owner's fids", file: "#{APP}/erx_fs_grant.erl",
              from: "            drain(lists:foldl(fun end_fid/2, Grant, maps:keys(Fids)));\n",
              to: "            _ = Fids,\n            {[], Grant};\n",
              caught_by: 'a_dead_owners_open_file_gives_back_what_it_held_test'),
    Fault.new(name: 'a grant that never forgets a walked node', file: "#{APP}/erx_fs_grant.erl",
              from: '    _ = [optional(Module, forget, [Node, Fs], ok) || Node <- Unnamed],',
              to: '    _ = Unnamed,',
              caught_by: 'clunking_every_fid_frees_a_nameless_file_test'),
    Fault.new(name: "a tree that keeps a dead grant's holds", file: "#{APP}/erx_ramfs.erl",
              from: '            {ok, Tree1} = step({forget_holder, Holder}, Root, Tree),',
              to: '            Tree1 = Tree,',
              caught_by: 'a_file_two_grants_hold_needs_both_to_let_go_test'),
    Fault.new(name: 'a walk that holds nothing', file: "#{APP}/erx_ramfs_core.erl",
              from: '{done, {ok, Ino, qid(Ino, Tree)}, hold(Ino, Holder, Tree)}',
              to: '{done, {ok, Ino, qid(Ino, Tree)}, Tree}',
              caught_by: 'a_stat_finds_a_name_renamed_over_between_its_walk_and_getattr_test')
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
      output, status = eunit(fault.file => original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}[^\n]*\*failed\*/, output, fault.name)
    end
  end

  private

  def eunit(replaced)
    Dir.mktmpdir('erx-ramfs-test') do |work|
      paths = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.write(path, replaced.fetch(source)) }
      end
      compile(work, paths, includes: [File.join(ROOT, 'erlang/apps/erx/include')], strict: replaced.empty?)
      compile(work, [File.join(ROOT, TESTS)], strict: true)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                      'logger:set_primary_config(level, none), ' \
                      'halt(case eunit:test(erx_ramfs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end

  def compile(work, paths, includes: [], strict:)
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), *(strict ? ['-Werror'] : []), '-pa', work,
                                     *includes.flat_map { |directory| ['-I', directory] }, '-o', work, *paths,
                                     stdin_data: '')
    assert status.success?, "erlc exit #{status.exitstatus} (124 is the deadline)\n#{output}"
  end
end
