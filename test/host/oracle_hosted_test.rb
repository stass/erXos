# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle_hosted'

# The hosted runtime's command line, which no run is needed to check.
class OracleHostedTest < Minitest::Test
  def command = Erx::OracleHosted.erxos_command(beam: '/b/beam.emu', archive: '/a/release.pack')

  def code_paths = command.each_cons(2).filter_map { |flag, value| value if flag == '-pa' }

  def test_no_directory_is_given_twice_with_pa
    assert_equal code_paths.uniq, code_paths
  end

  # The code server lists every application under /lib itself, so a -pa for one puts it on the
  # path a second time and code_SUITE's set_path, add_path and add_paths fail.
  def test_no_application_under_lib_is_given_with_pa
    assert_empty code_paths.select { |path| path.start_with?('/lib/') }
  end

  # erx_ct_oracle runs every suite the suite directory holds, so none is named,
  # with the work directory under /tmp and the logs on a tree of their own.
  def test_the_reporter_and_the_suite_directory_are_passed
    assert_includes code_paths, '/test/ct/reporter'
    assert_equal %W[main /test/ct/suites /tmp/ct /ct-logs 268435456], command.last(5)
  end
end

# The tree's boot script, written by systools on the stock host build from the tree's
# own .app files, as stock's start_clean is: it starts kernel and stdlib at the versions
# the tree ships, so application:which_applications() on erXos names those versions,
# and their code paths are where the tree holds them.
class OracleHostedBootScriptTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  VERSIONS = { 'kernel' => '99.0.1', 'stdlib' => '99.0.2' }.freeze
  DEADLINE = 120

  def setup
    @scratch = File.realpath(Dir.mktmpdir('erx-oracle-boot-'))
    @tree = File.join(@scratch, 'tree')
    VERSIONS.each do |application, version|
      source = File.read(File.join(ROOT, 'otp/lib', application, 'src', "#{application}.app.src"))
      ebin = File.join(@tree, 'lib', application, 'ebin')
      FileUtils.mkdir_p(ebin)
      File.write(File.join(ebin, "#{application}.app"), source.gsub('%VSN%', version))
    end
    @runner = Erx::Runner.new(owner_root: @scratch, log_dir: File.join(@scratch, 'logs'))
    @erl = Erx::Oracle.new(root: ROOT, runner: @runner).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)
    directory = File.join(@scratch, 'boot')
    FileUtils.mkdir_p(directory)
    @boot = Erx::OracleHosted.write_boot_script(tree: @tree, otp: File.join(ROOT, 'otp'), erl: @erl, runner: @runner,
                                                directory: directory)
  end

  def teardown
    FileUtils.remove_entry(@scratch) if @scratch
  end

  # The boot script as stock's binary_to_term reads it: each application with the version
  # its embedded .app names (kernel's goes to application_controller:start, the others'
  # to application:load), the applications it starts, and its code path entries.
  def script
    listing = File.join(@scratch, 'script.txt')
    expression = <<~ERLANG.tr("\n", ' ')
      {ok,B}=file:read_file(#{Erx::ReleaseFiles.erlang_string(@boot)}), {script,_,L}=binary_to_term(B),
      K=[{N,P} || {kernelProcess,_,{application_controller,start,[{application,N,P}]}} <- L],
      O=[{N,P} || {apply,{application,load,[{application,N,P}]}} <- L],
      A=[io_lib:format("app ~s ~s~n",[N,proplists:get_value(vsn,P)]) || {N,P} <- K ++ O],
      S=[io_lib:format("start ~s~n",[N]) || {apply,{application,start_boot,[N|_]}} <- L],
      D=[io_lib:format("path ~s~n",[X]) || X <- lists:usort([X || {path,Xs} <- L, X <- Xs])],
      R=[io_lib:format("rc~n",[]) || {apply,{c,erlangrc,[]}} <- L],
      ok=file:write_file(#{Erx::ReleaseFiles.erlang_string(listing)},[A,S,D,R]), halt().
    ERLANG
    @runner.run([@erl, '-boot', 'no_dot_erlang', '-noshell', '-noinput', '-eval', expression],
                name: 'read-boot-script', deadline: DEADLINE, env: Erx::Oracle::CLEAN_ERLANG_ENV)
    File.readlines(listing, chomp: true).map(&:split)
  end

  def test_the_boot_script_starts_kernel_and_stdlib_at_the_trees_versions
    applications = script.filter_map { |kind, name, version| [name, version] if kind == 'app' }.to_h
    assert_equal VERSIONS, applications
  end

  # erXos's own applications are on the code path through /lib, and the system's own boot
  # script would start their services; this one starts what stock's start_clean starts.
  def test_the_boot_script_starts_kernel_and_stdlib_alone
    assert_equal VERSIONS.keys, script.filter_map { |kind, name| name if kind == 'start' }
  end

  # Stock's start_clean reads .erlang (c:erlangrc), and so does the tree's.
  def test_the_boot_script_reads_dot_erlang_as_stocks_does
    assert_includes script, %w[rc]
  end

  def test_the_boot_script_finds_each_application_where_the_tree_holds_it
    paths = script.filter_map { |kind, path| path if kind == 'path' }
    assert_equal %w[$ROOT/lib/kernel/ebin $ROOT/lib/stdlib/ebin], paths
  end
end
