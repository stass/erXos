# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../../tools/lib/erx/build_memo'
require_relative '../../tools/lib/erx/compile_memo'
require_relative '../../tools/lib/erx/core_archive'

# A step runs again when any input its key names changes, and only then. Each test
# below changes one input in turn; an input left out of a key fails its test.
class BuildMemoTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir('erx-memo-'))
    # Reuse itself is tested on every host, whether or not this host reuses records.
    @memo = Erx::BuildMemo.new(root: @root, reuse: true)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # A host that reuses no record runs every step, unchanged inputs or not.
  def test_without_reuse_every_step_runs
    output = File.join(@root, 'out/a')
    memo = Erx::BuildMemo.new(root: @root, reuse: false)
    key = Erx::BuildMemo.key('source' => 'one')
    runs = 0
    2.times do
      assert(memo.in_place('step', key: key, outputs: [output]) do
        runs += 1
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, 'made')
      end)
    end
    assert_equal 2, runs
  end

  def test_in_place_step_runs_again_only_for_another_key_or_changed_output
    output = File.join(@root, 'out/a')
    runs = 0
    step = lambda do |key|
      @memo.in_place('step', key: key, outputs: [output]) do
        runs += 1
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, 'made')
      end
    end
    first = Erx::BuildMemo.key('source' => 'one')
    assert step.call(first)
    refute step.call(first)
    assert step.call(Erx::BuildMemo.key('source' => 'two'))
    File.write(output, 'edited')
    assert step.call(Erx::BuildMemo.key('source' => 'two'))
    File.delete(output)
    assert step.call(Erx::BuildMemo.key('source' => 'two'))
    assert_equal 4, runs
  end

  def test_stored_outputs_come_back_after_their_directory_is_cleared
    output = File.join(@root, 'image/x.o')
    key = Erx::BuildMemo.key('source' => 'one')
    refute @memo.restore('step', key: key, outputs: [output])
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, 'object')
    @memo.store('step', key: key, outputs: [output])
    FileUtils.rm_rf(File.dirname(output))
    assert @memo.restore('step', key: key, outputs: [output])
    assert_equal 'object', File.read(output)
    refute @memo.restore('step', key: Erx::BuildMemo.key('source' => 'two'), outputs: [output])
  end

  def test_a_record_of_another_shape_is_refused
    FileUtils.mkdir_p(File.join(@root, 'build/memo/step'))
    File.write(File.join(@root, 'build/memo/step/current.json'), '{"version":0}')
    error = assert_raises(Erx::Error) do
      @memo.in_place('step', key: Erx::BuildMemo.key('a' => 'b'), outputs: []) { nil }
    end
    assert_match(/invalid build memo record/, error.message)
  end

  def test_key_does_not_depend_on_the_order_parts_are_named_in
    assert_equal Erx::BuildMemo.key('a' => '1', 'b' => { 'c' => 2, 'd' => 3 }),
                 Erx::BuildMemo.key('b' => { 'd' => 3, 'c' => 2 }, 'a' => '1')
  end

  def test_tree_digest_follows_a_link_to_the_content_it_reaches
    FileUtils.mkdir_p(File.join(@root, 'tree'))
    File.write(File.join(@root, 'real.h'), "one\n")
    File.symlink(File.join(@root, 'real.h'), File.join(@root, 'tree/link.h'))
    before = Erx::BuildMemo.tree_digest(File.join(@root, 'tree'))
    File.write(File.join(@root, 'real.h'), "two\n")
    refute_equal before, Erx::BuildMemo.tree_digest(File.join(@root, 'tree'))
  end

  def test_tree_digest_refuses_a_link_to_a_directory
    FileUtils.mkdir_p(File.join(@root, 'tree'))
    FileUtils.mkdir_p(File.join(@root, 'elsewhere'))
    File.symlink(File.join(@root, 'elsewhere'), File.join(@root, 'tree/sub'))
    error = assert_raises(Erx::Error) { Erx::BuildMemo.tree_digest(File.join(@root, 'tree')) }
    assert_match(/link to a directory/, error.message)
  end

  def test_in_place_output_directory_is_checked_by_content
    header = File.join(@root, 'out/include/a.h')
    runs = 0
    step = lambda do
      @memo.in_place('step', key: Erx::BuildMemo.key('source' => 'one'), outputs: [File.dirname(header)]) do
        runs += 1
        FileUtils.mkdir_p(File.dirname(header))
        File.write(header, 'made')
      end
    end
    assert step.call
    refute step.call
    File.write(header, 'edited')
    assert step.call
    assert_equal 2, runs
  end

  def test_root_spelled_through_a_link_names_the_same_outputs
    File.symlink(@root, "#{@root}-link")
    memo = Erx::BuildMemo.new(root: "#{@root}-link", reuse: true)
    output = File.join("#{@root}-link", 'out/a')
    made = memo.in_place('step', key: Erx::BuildMemo.key('a' => 'b'), outputs: [output]) do
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, 'made')
    end
    assert made
    refute memo.in_place('step', key: Erx::BuildMemo.key('a' => 'b'), outputs: [File.join(@root, 'out/a')]) { nil }
  ensure
    FileUtils.rm_f("#{@root}-link")
  end

  def test_program_identity_names_the_libraries_of_its_install
    FileUtils.mkdir_p(File.join(@root, 'tool/bin'))
    FileUtils.mkdir_p(File.join(@root, 'tool/lib'))
    program = File.join(@root, 'tool/bin/cc')
    File.write(program, "#!/bin/sh\n")
    File.write(File.join(@root, 'tool/lib/libcompiler.dylib'), 'one')
    before = Erx::BuildMemo.program_identity(program)
    File.write(File.join(@root, 'tool/lib/libcompiler.dylib'), 'two')
    refute_equal before, Erx::BuildMemo.program_identity(program)
  end

  # A directory shared by many packages (FreeBSD's /usr/local/bin) is named program by program,
  # each with its install's libraries.
  def test_directory_identities_name_every_executable_and_the_install_libraries
    FileUtils.mkdir_p(File.join(@root, 'shared/bin'))
    FileUtils.mkdir_p(File.join(@root, 'shared/lib'))
    %w[cc as].each do |name|
      File.write(File.join(@root, 'shared/bin', name), "#!/bin/sh\n")
      File.chmod(0o755, File.join(@root, 'shared/bin', name))
    end
    File.write(File.join(@root, 'shared/bin/data'), 'not a program')
    File.write(File.join(@root, 'shared/lib/libshared.so'), 'one')
    before = Erx::BuildMemo.directory_identities(File.join(@root, 'shared/bin'))
    assert_equal %w[as cc], before.keys
    assert_equal Erx::BuildMemo.program_identity(File.join(@root, 'shared/bin/cc')), before.fetch('cc')
    File.write(File.join(@root, 'shared/lib/libshared.so'), 'two')
    refute_equal before, Erx::BuildMemo.directory_identities(File.join(@root, 'shared/bin'))
  end

  # A program reached through a link names the libraries beside its real install, not those
  # beside the link (Homebrew's bin, FreeBSD's /usr/local/bin).
  def test_a_linked_program_names_the_libraries_of_its_real_install
    %w[install/bin install/lib links].each { |name| FileUtils.mkdir_p(File.join(@root, name)) }
    program = File.join(@root, 'install/bin/cc')
    File.write(program, "#!/bin/sh\n")
    File.chmod(0o755, program)
    File.symlink(program, File.join(@root, 'links/cc'))
    File.write(File.join(@root, 'install/lib/libcc.so'), 'one')
    before = Erx::BuildMemo.directory_identities(File.join(@root, 'links')).fetch('cc')
    File.write(File.join(@root, 'install/lib/libcc.so'), 'two')
    refute_equal before, Erx::BuildMemo.directory_identities(File.join(@root, 'links')).fetch('cc')
  end

  # A program this user cannot read (setuid sudo, mode --x, in a PATH directory) is named by
  # its state and mode, marked unreadable, instead of failing every build.
  def test_an_unreadable_program_is_named_by_its_state
    skip 'root reads every file' if Process.uid.zero?
    FileUtils.mkdir_p(File.join(@root, 'shared/bin'))
    program = File.join(@root, 'shared/bin/sudo')
    File.write(program, 'one')
    File.chmod(0o111, program)
    before = Erx::BuildMemo.directory_identities(File.join(@root, 'shared/bin')).fetch('sudo')
    assert_includes before, 'unreadable 100111'
    File.chmod(0o4111, program)
    refute_equal before, Erx::BuildMemo.directory_identities(File.join(@root, 'shared/bin')).fetch('sudo')
  end

  # The C17 cores the Fiasco build links compile as the memo's compiles do.
  def test_core_compiles_see_only_the_tool_environment_and_no_configuration_file
    assert_equal Erx::BuildMemo.tool_environment, Erx::CoreArchive.environment
    assert_includes Erx::CoreArchive::FLAGS, '--no-default-config'
  end

  def test_a_program_named_without_a_path_is_refused
    assert_raises(Erx::Error) { Erx::BuildMemo.program_identity('clang') }
  end

  def test_a_malformed_key_is_refused_when_storing
    assert_raises(Erx::Error) { @memo.store('step', key: '../escape', outputs: []) }
    assert_raises(Erx::Error) { @memo.write_note('step', '../escape', []) }
  end
end

# The compile memo against a real clang: a tree of a source, a header it includes from
# an -I directory and a system header, compiled, then compiled again after each change.
class CompileMemoTest < Minitest::Test
  def setup
    clang = ENV.fetch('ERX_CLANG', '')
    skip 'ERX_CLANG is not set: the compile memo test runs the LLVM clang' if clang.empty?

    @root = File.realpath(Dir.mktmpdir('erx-compile-memo-'))
    # A wrapper the test can change, standing for the compiler itself, and a library of
    # its install, standing for the code a driver loads.
    @compiler = File.join(@root, 'toolchain/bin/cc')
    write('toolchain/lib/libcompiler.dylib', 'one')
    write('toolchain/bin/cc', "#!/bin/sh\nexec #{clang} \"$@\"\n")
    File.chmod(0o755, @compiler)
    write('src/main.c', %(#include "local.h"\n#include "inc.h"\n#include <sys.h>\nint f(void) { return LOCAL + INC + SYS; }\n))
    write('src/local.h', "#define LOCAL 1\n")
    write('inc/inc.h', "#define INC 2\n")
    write('sys/sys.h', "#define SYS 3\n")
    FileUtils.mkdir_p(File.join(@root, 'first'))
    @runner = Erx::Runner.new(owner_root: @root, log_dir: File.join(@root, 'logs'))
    @flags = %w[--target=aarch64-none-elf -ffreestanding -O2 -I first -I inc -isystem sys]
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def write(relative, text)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  # Compiles into a directory cleared first, as an image's is; returns whether clang ran.
  def compile
    out = File.join(@root, 'out')
    FileUtils.rm_rf(out)
    FileUtils.mkdir_p(out)
    object = File.join(out, 'main.o')
    argv = [@compiler, *@flags, '-MMD', '-MF', "#{object}.d", '-c', 'src/main.c', '-o', object]
    memo = Erx::CompileMemo.new(root: @root, runner: @runner, memo: Erx::BuildMemo.new(root: @root, reuse: true))
    memo.compile(argv, chdir: @root, object: object, depfile: "#{object}.d") do |command, environment|
      @seen = { command: command, environment: environment }
      system(environment, *command, chdir: @root, exception: true)
    end.tap { assert File.file?(object) }
  end

  def assert_reruns_after(&change)
    assert compile, 'the first compile runs'
    refute compile, 'an unchanged compile is reused'
    change.call
    assert compile, 'a changed input runs the compile again'
    refute compile, 'and the new outputs are reused after that'
  end

  def test_source_content
    assert_reruns_after { write('src/main.c', File.read(File.join(@root, 'src/main.c')) + "int g;\n") }
  end

  def test_included_header_content
    assert_reruns_after { write('inc/inc.h', "#define INC 4\n") }
  end

  def test_system_header_content
    assert_reruns_after { write('sys/sys.h', "#define SYS 5\n") }
  end

  def test_flags
    assert_reruns_after { @flags = [*@flags, '-DEXTRA'] }
  end

  def test_compiler
    assert_reruns_after { File.write(@compiler, "#{File.read(@compiler)}# changed\n") }
  end

  def test_compiler_library
    assert_reruns_after { write('toolchain/lib/libcompiler.dylib', 'two') }
  end

  # The compile sees only the environment its key names, and no clang configuration file.
  def test_compiles_run_in_a_constructed_environment_without_default_configuration
    compile
    assert_includes @seen.fetch(:command), '--no-default-config'
    environment = @seen.fetch(:environment)
    assert_equal Erx::CompileMemo::ENVIRONMENT, environment.compact
    assert ENV.keys.all? { |name| environment.key?(name) }, 'every ambient variable is unset or replaced'
  end

  def test_system_header_reached_through_a_link
    write('real/sys.h', "#define SYS 3\n")
    File.delete(File.join(@root, 'sys/sys.h'))
    File.symlink(File.join(@root, 'real/sys.h'), File.join(@root, 'sys/sys.h'))
    assert_reruns_after { write('real/sys.h', "#define SYS 8\n") }
  end

  def test_quoted_include_in_a_subdirectory_shadowed_beside_its_includer
    write('inc/sub/q.h', "#define Q 1\n")
    write('src/sub/other.h', "#define OTHER 1\n")
    write('src/main.c', %(#include "sub/q.h"\nint f(void) { return Q; }\n))
    assert_reruns_after { write('src/sub/q.h', "#define Q 2\n") }
  end

  # A compile that asks whether a header exists depends on a file its dependency list
  # does not name, so it is never reused.
  def test_a_compile_that_probes_for_a_header_is_not_reused
    write('src/main.c', %(#if __has_include("later.h")\n#include "later.h"\n#endif\nint f(void) { return 0; }\n))
    assert compile
    assert compile
  end

  # A compiler whose -v output has no search list would leave the system headers out of
  # every key; it is refused rather than read as searching nothing.
  def test_a_search_listing_of_another_shape_is_refused
    write('toolchain/bin/cc', "#!/bin/sh\necho silent\n")
    error = assert_raises(Erx::Error) { compile }
    assert_match(/listed no header search directories/, error.message)
  end

  def test_header_shadowed_in_an_earlier_include_directory
    assert_reruns_after { write('first/inc.h', "#define INC 6\n") }
  end

  def test_system_header_shadowed_in_an_include_directory
    assert_reruns_after { write('inc/sys.h', "#define SYS 7\n") }
  end

  def test_quoted_include_shadowed_beside_its_includer
    write('inc/quoted.h', "#define Q 1\n")
    write('src/main.c', %(#include "quoted.h"\nint f(void) { return Q; }\n))
    assert_reruns_after { write('src/quoted.h', "#define Q 2\n") }
  end

  def test_going_back_to_an_earlier_source_reuses_its_outputs
    assert compile
    original = File.read(File.join(@root, 'src/main.c'))
    write('src/main.c', "#{original}int g;\n")
    assert compile
    write('src/main.c', original)
    refute compile
  end
end
