# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/app_pack'
require_relative '../../tools/lib/erx/example_lists'
require_relative '../../tools/lib/erx/package_key'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/sdk'
# build/gen brought up to date at process entry, for the applications' generated headers.
require_relative '../fixtures/generated_tree'

# The SDK (docs/design-packaging.md, "The SDK", "Examples" and "Verification and testing"):
# sdk/public.txt's reader, the export's Erlang half and SDK.txt, the boundary check
# test/erlang/erx_sdk_boundary.erl over an app of test/fixtures/sdk_app with its seeded
# fault (a call of erx_ui:start/1, exported by a public module but not public), and the
# check that no list names an example with its (erx_dashboard added to
# ErlangApps::APPLICATIONS), and the native half: test/fixtures/sdk_hello built with the SDK
# alone, packed and planned as the loader plans it, with its seeded faults.
class SdkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PROBE = File.join(ROOT, 'test/fixtures/sdk_app/lib/erx_sdk_probe/src/erx_sdk_probe.erl')
  BOUNDARY = File.join(ROOT, 'test/erlang/erx_sdk_boundary.erl')
  HELLO = File.join(ROOT, 'test/fixtures/sdk_hello')
  DEADLINE = %w[gtimeout -k 10 300].freeze

  # One export per test process: compiling the public applications is the slow part.
  def self.sdk
    @sdk ||= begin
      directory = File.join(Dir.mktmpdir('erx-sdk-test-'), 'sdk')
      runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
      Erx::Sdk.new(root: ROOT, runner: runner, erlc: ENV.fetch('ERX_ERLC'), compiler: ENV.fetch('ERX_CLANG'),
                    linker: ENV.fetch('ERX_LLD')).export(directory)
    end
  end

  def sdk = self.class.sdk

  def test_public_txt_is_read_strictly
    assert_equal [Erx::Sdk::Function.new(module_name: 'a', function: 'f', arity: 1), Erx::Sdk::WholeModule.new(module_name: 'b')],
                 Erx::Sdk.entries("# comment\n\na:f/1\nb\n")
    { "b\na:f/1\n" => /sorted/, "a:f/1\na:f/1\n" => /sorted/, "a:F/1\n" => /:1: not/, "a:f/01\n" => /:1: not/,
      "a:f\n" => /:1: not/, "a:f/1/2\n" => /:1: not/ }.each do |text, message|
      assert_raises(Erx::Error, text) { Erx::Sdk.entries(text) }.then { assert_match message, it.message }
    end
  end

  def test_a_whole_module_expands_to_its_exports_without_module_info
    entries = Erx::Sdk.entries("a:f/1\nb\n")
    assert_equal ['a:f/1', 'b:g/0', 'b:h/2'],
                 Erx::Sdk.expand(entries, exports: { 'a' => [['f', 1]], 'b' => [['module_info', 0], ['h', 2], ['g', 0], ['module_info', 1]] })
  end

  def test_a_listed_function_the_module_does_not_export_is_refused
    error = assert_raises(Erx::Error) { Erx::Sdk.expand(Erx::Sdk.entries("a:f/2\n"), exports: { 'a' => [['f', 1]] }) }
    assert_match(/a:f\/2 is not exported/, error.message)
  end

  def test_the_boundary_refuses_an_erxos_function_of_a_stock_module
    seeded = File.read(PROBE).sub('erx_ui:close(Window)', 'prim_file:erx_mounts()')
    assert_equal '{[{{erx_sdk_probe,run,1},{prim_file,erx_mounts,0}}],[]}', outside(seeded)
  end

  def test_the_applications_are_the_public_modules_and_their_erxos_dependencies
    owners = { 'm' => 'erx_ui', 'n' => 'erx_win' }
    depends = { 'erx_ui' => %w[kernel stdlib erx], 'erx_win' => %w[kernel erx erx_memdraw], 'erx' => %w[kernel stdlib],
                'erx_memdraw' => %w[kernel erx] }
    assert_equal %w[erx erx_memdraw erx_win erx_ui], Erx::Sdk.applications(Erx::Sdk.entries("m\nn\n"), owners: owners, depends: depends)
    error = assert_raises(Erx::Error) { Erx::Sdk.applications(Erx::Sdk.entries("erx_draw\n"), owners: owners, depends: depends) }
    assert_match(/erx_draw is in no erXos application/, error.message)
  end

  def test_the_export_holds_the_public_applications_their_functions_and_its_record
    assert_equal %w[erx erx_bt_client erx_memdraw erx_ui erx_win], Dir.children(File.join(sdk, 'erlang/lib')).sort
    assert File.file?(File.join(sdk, 'erlang/lib/erx_ui/ebin/erx_ui.beam'))
    assert File.file?(File.join(sdk, 'erlang/lib/erx_ui/ebin/erx_ui.app'))
    assert File.file?(File.join(sdk, 'erlang/lib/erx/include/generated/erx_abi.hrl'))
    public = File.readlines(File.join(sdk, 'erlang/public.txt'), chomp: true)
    assert_equal public.sort, public
    assert_includes public, 'erx_ui:open/1'
    assert_includes public, 'erx_win:open/2'
    assert_includes public, 'erx_prog_handler:start/1'
    refute_includes public, 'erx_ui:start/1'
    assert(public.none? { it.include?('module_info') })
    record = File.readlines(File.join(sdk, 'SDK.txt'), chomp: true).to_h { it.split(' ', 2) }
    assert_equal %w[abi_version arch commit otp], record.keys.sort
    assert_equal '29.1.2', record.fetch('otp')
    assert_match(/\A\h{40}(-dirty)?\z/, record.fetch('commit'))
    assert File.file?(File.join(sdk, 'host/erlang/ebin/erx_bytes.beam'))
    assert File.file?(File.join(sdk, 'host/erlang/ebin/erx_verity_tree.beam'))
  end

  # An SDK is handed to others, so it carries no private key: its packer makes its own
  # development key on the host that uses it.
  def test_an_exported_sdk_holds_no_private_key
    keys = Dir.glob('**/*', File::FNM_DOTMATCH, base: sdk).select do |name|
      path = File.join(sdk, name)
      File.file?(path) && File.binread(path).include?('PRIVATE KEY-----')
    end
    assert_empty keys
  end

  def test_an_app_that_keeps_to_the_sdk_passes_the_boundary
    assert_equal '{[],[]}', outside(File.read(PROBE))
  end

  def test_the_boundary_refuses_a_function_of_a_public_module_that_is_not_public
    seeded = File.read(PROBE).sub('erx_ui:open(Options)', 'erx_ui:start(Options)')
    assert_equal '{[{{erx_sdk_probe,run,1},{erx_ui,start,1}}],[]}', outside(seeded)
  end

  def test_the_boundary_refuses_a_module_the_sdk_does_not_carry
    seeded = File.read(PROBE).sub('erx_ui:close(Window)', 'erx_starter:packages(Window, [])')
    assert_equal '{[{{erx_sdk_probe,run,1},{erx_starter,packages,2}}],[]}', outside(seeded)
  end

  # A call through a variable module could reach any function, so the check answers it
  # apart, and an app that keeps to the SDK makes none.
  def test_the_boundary_answers_a_call_through_a_variable_module
    seeded = File.read(PROBE).sub('erx_ui:close(Window)', '(maps:get(ui, Options)):close(Window)')
    assert_equal "{[],[{{erx_sdk_probe,run,1},{'$M_EXPR',close,1}}]}", outside(seeded)
  end

  def test_no_list_names_an_example
    listed = Open3.capture2('git', '-C', ROOT, 'ls-files', '-z', stdin_data: '').first.split("\0")
    files = listed.select { Erx::ExampleLists.covers?(it) }.to_h { [it, File.binread(File.join(ROOT, it))] }
    assert_empty Erx::ExampleLists.violations(files, applications: Erx::ExampleLists.applications(root: ROOT))
  end

  def test_an_example_named_by_a_list_is_found
    apps = 'tools/lib/erx/erlang_apps.rb'
    seeded = File.read(File.join(ROOT, apps)).sub('APPLICATIONS = %w[erx ', 'APPLICATIONS = %w[erx erx_dashboard ')
    line = seeded.lines.index { it.include?('erx_dashboard') } + 1
    assert_equal [[apps, line, 'erx_dashboard']], Erx::ExampleLists.violations({ apps => seeded }, applications: ['erx_dashboard'])
    assert_equal [['config/manifest/x.txt', 1, 'examples/']],
                 Erx::ExampleLists.violations({ 'config/manifest/x.txt' => "input examples/dashboard\n" }, applications: [])
    refute Erx::ExampleLists.covers?('tools/lib/erx/example_lists.rb')
  end

  # The kiosk cell's files pack the dashboard through the SDK, as the design names them;
  # a tools file the exemptions do not list is found for the same line.
  def test_only_an_exempt_file_names_an_example
    named = "APP = 'examples/dashboard'\n"
    files = %w[tools/lib/erx/kiosk.rb tools/lib/erx/qemu_suites/kiosk.rb tools/lib/erx/production_image.rb]
            .to_h { [it, named] }
    assert_equal [['tools/lib/erx/production_image.rb', 1, 'examples/']],
                 Erx::ExampleLists.violations(files, applications: ['erx_dashboard'])
  end

  def test_the_applications_are_the_examples_directories
    Dir.mktmpdir('erx-examples-') do |root|
      FileUtils.mkdir_p(File.join(root, 'examples/dashboard/lib/erx_dashboard'))
      assert_equal ['erx_dashboard'], Erx::ExampleLists.applications(root: root)
    end
  end

  # The hello program builds out of the tree with the SDK alone: its compile and link name
  # only the SDK's files, and the executable is linked at task.ld's fixed base, as the boot
  # image's programs are. Packed, its program passes the planner the loader uses.
  def test_a_c_program_built_with_the_sdk_alone_packs
    Dir.mktmpdir('erx-sdk-hello-') do |work|
      recipe = File.read(File.join(sdk, 'share/erxos/sdk.mk'))
      refute_includes recipe, ROOT
      directory = hello(File.join(work, 'hello'))
      program = File.binread(File.join(directory, 'bin/hello'))
      assert_equal [2, Erx::AppPackage.codec.constant('exec_window_base')], [program.unpack1('v', offset: 16), first_load(program)]
      path = Erx::AppPack.pack(directory: directory, sdk: app_sdk, signer: signer, output_directory: work, runner: runner, root: ROOT,
                               compiler: ENV.fetch('ERX_CLANG'))
      assert File.file?(path)
    end
  end

  # Every library the SDK ships carries its license notices in share/licenses/LIB, copies
  # of the tree's notice files, L4Re's user libraries under the notices the image ships
  # them under (Fiasco#user_library_notices); a seeded SDK with one library's notices
  # dropped is caught.
  def test_every_shipped_library_carries_its_notices
    libraries = Dir.children(File.join(sdk, 'sysroot/aarch64/lib')).select { it.end_with?('.a') }.sort
    assert_equal %w[libboot_cores.a libc.a libclang_rt.builtins.a liberx_program.a libl4sys.p.a libsigma0.a], libraries
    assert_empty unattributed(sdk)
    assert_equal File.read(File.join(ROOT, 'musl/COPYRIGHT')), File.read(File.join(sdk, 'share/licenses/libc.a/COPYRIGHT'))
    fiasco = Erx::Fiasco.new(root: ROOT)
    Erx::Fiasco::USER_LIBRARIES.each_key do |name|
      shipped = File.join(sdk, 'share/licenses', name)
      assert_equal fiasco.user_library_notices(name).to_h { [File.basename(it), File.binread(File.join(ROOT, it))] },
                   Dir.children(shipped).to_h { [it, File.binread(File.join(shipped, it))] }, "#{name} ships under the image's notices"
    end
    Dir.mktmpdir('erx-sdk-notices-') do |work|
      FileUtils.cp_r(File.join(sdk, 'sysroot'), work)
      FileUtils.mkdir_p(File.join(work, 'share'))
      FileUtils.cp_r(File.join(sdk, 'share/licenses'), File.join(work, 'share'))
      FileUtils.rm_rf(File.join(work, 'share/licenses/libsigma0.a'))
      assert_equal ['libsigma0.a'], unattributed(work)
    end
  end

  # Seeded faults: the program made position-independent, an ET_DYN at the task script's
  # base, and with its code segment made writable, are each refused before a package is
  # made. (The recipe cannot link a PIE: task.ld names no dynamic section, and the link
  # refuses an orphan.)
  def test_a_pie_or_a_writable_code_segment_is_refused
    Dir.mktmpdir('erx-sdk-hello-') do |work|
      pie = seeded(File.join(work, 'pie')) { |program, _| program[16, 2] = [3].pack('v') }
      assert_match(%r{\Abin/hello is not a program the loader accepts: pie_origin at byte [0-9]+\z}, refusal(pie))
      writable = seeded(File.join(work, 'wx')) do |program, table|
        assert_equal [1, 5], program.unpack('V2', offset: table)
        program[table + 4, 4] = [7].pack('V')
      end
      assert_match(%r{\Abin/hello is not a program the loader accepts: load_protection_or_size at byte 0\z}, refusal(writable))
    end
  end

  private

  def runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
  def app_sdk = Erx::AppPack::Sdk.new(root: sdk, erlc: ENV.fetch('ERX_ERLC'))
  def signer = self.class.signer

  def self.signer
    @signer ||= Erx::PackageKey.ensure(directory: Erx::PackageKey.directory(home: Dir.mktmpdir('erx-sdk-home-')))
  end

  # A copy of the hello fixture in directory, built with the SDK's recipe by make.
  def hello(directory)
    FileUtils.mkdir_p(File.dirname(directory))
    FileUtils.cp_r(HELLO, directory)
    output, status = Open3.capture2e(*DEADLINE, 'gmake', '-C', directory, "SDK=#{sdk}", "ERX_CC=#{ENV.fetch('ERX_CLANG')}",
                                     "ERX_LD=#{ENV.fetch('ERX_LLD')}", stdin_data: '')
    assert status.success?, output
    directory
  end

  # The hello program built in directory, its bytes changed by the block, which is given
  # them and the offset of the program header table.
  def seeded(directory)
    path = File.join(hello(directory), 'bin/hello')
    program = File.binread(path)
    yield program, program.unpack1('Q<', offset: 32)
    File.binwrite(path, program)
    directory
  end

  # The virtual address of an executable's first program header, a load.
  def first_load(program) = program.unpack1('Q<', offset: program.unpack1('Q<', offset: 32) + 16)

  # The libraries of an SDK's lib/ with no non-empty notice in share/licenses/LIB.
  def unattributed(directory)
    Dir.children(File.join(directory, 'sysroot/aarch64/lib')).select { it.end_with?('.a') }.sort.reject do |library|
      notices = File.join(directory, 'share/licenses', library)
      File.directory?(notices) && !Dir.children(notices).empty? &&
        Dir.children(notices).all? { File.size(File.join(notices, it)).positive? }
    end
  end

  # The packer's refusal of the app in directory.
  def refusal(directory)
    assert_raises(Erx::Error) do
      Erx::AppPack.pack(directory: directory, sdk: app_sdk, signer: signer, output_directory: File.dirname(directory),
                        runner: runner, root: ROOT, compiler: ENV.fetch('ERX_CLANG'))
    end.message
  end

  # The boundary check's answer for the probe app compiled from source, printed by Erlang.
  def outside(source)
    Dir.mktmpdir('erx-sdk-boundary-') do |work|
      app = File.join(work, 'app')
      FileUtils.mkdir_p(app)
      File.write(File.join(work, 'erx_sdk_probe.erl'), source)
      compile(['+debug_info', '-o', app, File.join(work, 'erx_sdk_probe.erl')])
      compile(['-o', work, BOUNDARY])
      ebins = Dir.glob(File.join(sdk, 'erlang/lib/*/ebin')).flat_map { ['-pa', it] }
      expression = "io:format(\"~w~n\", [erx_sdk_boundary:outside([#{app.inspect}], #{File.join(sdk, 'erlang/public.txt').inspect})]), halt()."
      output, status = Open3.capture2e(*DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, *ebins, '-eval', expression,
                                       stdin_data: '')
      assert status.success?, output
      output.strip
    end
  end

  def compile(arguments)
    output, status = Open3.capture2e(*DEADLINE, ENV.fetch('ERX_ERLC'), '-Werror', *arguments, stdin_data: '')
    assert status.success?, output
  end
end
