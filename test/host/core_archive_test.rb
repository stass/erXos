# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/core_archive'

# The C17 cores' archive as the stopgap kernel links it: its members, its
# build records, its seam copy, its undefined-symbol allowlist, and its
# reuse of an unchanged build.
class CoreArchiveTest < Minitest::Test
  def setup
    @compiler = ENV.fetch('ERX_CLANG', '')
    @directory = File.realpath(Dir.mktmpdir('erx-core-archive-test-'))
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_a_symbol_one_member_defines_is_not_undefined
    listing = "erx_a T 0 4\nerx_b U\nerx_b T 0 4\nmemcpy U\nerx_effect_tick U\nlocal t 0 4\n"
    assert_equal %w[erx_effect_tick memcpy], Erx::CoreArchive.undefined_symbols(listing)
  end

  # A weak reference is a reference, and a static of the same name in
  # another member does not satisfy one.
  def test_weak_references_and_statics_do_not_hide_an_external
    assert_equal %w[fiasco_fn fiasco_var], Erx::CoreArchive.undefined_symbols("fiasco_var w 0 0\nfiasco_fn v 0 0\n")
    assert_equal %w[fiasco_thing], Erx::CoreArchive.undefined_symbols("fiasco_thing d 0 4\nfiasco_thing U\n")
  end

  def test_a_global_outside_the_erx_names_is_refused
    compiler!
    tree(core: "int memcmp(const void *a, const void *b, unsigned long n) { (void)a; (void)b; return (int)n; }\n")
    error = assert_raises(Erx::Error) { build(output: File.join(@directory, 'build/cores')) }
    assert_includes error.message, 'global memcmp is not named erx_'
  end

  def test_an_unreadable_symbol_name_is_refused
    assert_raises(Erx::Error) { Erx::CoreArchive.undefined_symbols("erx\e[31m U\n") }
  end

  # The seam copy takes each header from the tree or from the generated tree,
  # and refuses one both hold, so neither stands in for the other.
  def test_a_seam_header_both_trees_hold_is_refused
    tree(core: "int erx_core_value(void) { return 0; }\n")
    root = File.join(@directory, 'tree')
    assert_equal({ 'seam.h' => 'include/erx/core/seam.h' }, Erx::CoreArchive.seam_headers(root))
    FileUtils.mkdir_p(File.join(root, 'build/gen/include/erx/core'))
    File.write(File.join(root, 'build/gen/include/erx/core/seam.h'), "#define ERX_SEAM_VALUE 4\n")
    error = assert_raises(Erx::Error) { Erx::CoreArchive.seam_headers(root) }
    assert_match(%r{include/erx/core/seam.h is at the path of a generated seam header}, error.message)
  end

  def test_the_kernel_cores_leave_out_the_bootstrap_ones
    root = File.expand_path('../..', __dir__)
    sources = Erx::CoreArchive.sources(root)
    assert_includes Erx::CoreArchive::BOOTSTRAP_SOURCES, 'kernel/core/pack.c'
    assert_empty sources & Erx::CoreArchive::BOOTSTRAP_SOURCES
    # Every other core and every imported primitive links with the cores.
    # gate_baseline_test.rb pins the ones in the tree against deletion.
    expected = Dir.glob('kernel/{core,sched,crypto/*}/*.c', base: root) - Erx::CoreArchive::BOOTSTRAP_SOURCES
    assert_empty expected - sources
    assert_equal sources.sort, sources
  end

  def test_the_archive_holds_the_cores_with_their_records_and_an_unchanged_build_is_kept
    compiler!
    tree(core: "#include \"erx/core/seam.h\"\nint erx_core_value(void) { return ERX_SEAM_VALUE; }\n")
    output = File.join(@directory, 'build/cores')
    checked = nil
    built = build(output: output, check: ->(objects) { checked = objects })
    assert_equal ['kernel/core/value.c'], checked.keys
    assert_equal "value.o\n", File.read(File.join(output, Erx::CoreArchive::MEMBERS))
    record = File.read(File.join(output, '.value.o.d'))
    assert record.start_with?('value.o:'), record
    assert_includes record, File.join(@directory, 'tree/kernel/core/value.c')
    assert_includes record, File.join(@directory, 'tree/include/erx/core/seam.h')
    assert File.file?(File.join(output, 'value.su'))
    assert_equal File.read(File.join(@directory, 'tree/include/erx/core/seam.h')),
                 File.read(File.join(built.seam, 'erx/core/seam.h'))
    assert_equal ['erx'], Dir.children(built.seam)
    listing = @runner.run([File.join(File.dirname(File.realpath(@compiler)), 'llvm-ar'), 't', built.archive],
                          name: 'list', deadline: 30)
    assert_equal "value.o\n", File.read(listing.fetch('log'))

    stamp = Time.at(1_000_000)
    File.utime(stamp, stamp, built.archive)
    build(output: output)
    assert_equal stamp, File.mtime(built.archive), 'an unchanged build must keep the installed archive'
  end

  def test_a_call_outside_the_allowlist_is_refused_and_installs_nothing
    compiler!
    tree(core: "int printf(const char *, ...);\nint erx_core_value(void) { return printf(\"x\"); }\n")
    output = File.join(@directory, 'build/cores')
    error = assert_raises(Erx::Error) { build(output: output) }
    assert_includes error.message, 'undefined symbol printf'
    refute File.exist?(output)
  end

  def test_a_failed_check_installs_nothing
    compiler!
    tree(core: "int erx_core_value(void) { return 1; }\n")
    output = File.join(@directory, 'build/cores')
    assert_raises(Erx::Error) { build(output: output, check: ->(_objects) { raise Erx::Error, 'refused' }) }
    refute File.exist?(output)
  end

  private

  def compiler!
    skip 'ERX_CLANG is not set: the cores need the LLVM 23 clang and its binary tools' if @compiler.empty?
  end

  # A tree laid out as the repository is, with one kernel core, the
  # bootstrap core the archive leaves out, and one seam header.
  def tree(core:)
    root = File.join(@directory, 'tree')
    %w[kernel/core kernel/generated include/erx/core].each { |path| FileUtils.mkdir_p(File.join(root, path)) }
    File.write(File.join(root, 'kernel/core/value.c'), core)
    File.write(File.join(root, 'kernel/core/pack.c'), "int erx_bootstrap_only(void) { return 2; }\n")
    File.write(File.join(root, 'kernel/core/boot_place.c'), "int erx_bootstrap_place_only(void) { return 3; }\n")
    File.write(File.join(root, 'include/erx/core/seam.h'), "#define ERX_SEAM_VALUE 3\n")
  end

  def build(output:, check: ->(_objects) {})
    Erx::CoreArchive.build(root: File.join(@directory, 'tree'), compiler: @compiler, runner: @runner,
                           output: output, project: @directory, check: check)
  end
end
