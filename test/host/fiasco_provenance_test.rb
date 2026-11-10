# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/fiasco_provenance'

class FiascoProvenanceTest < Minitest::Test
  # The part of FiascoInputs the attribution of a captured source reads.
  CapturedTree = Data.define(:tree) do
    def find_captured_path(path) = path
    def read(path, maximum: nil) = File.binread(path)
  end

  # Attributes a copy of a file beside BLAKE3's real ORIGIN.md, as a captured source.
  def attribute_beside_origin(name, content)
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      tree = File.join(root, 'build/fiasco/capture')
      directory = File.join(tree, 'kernel/crypto/blake3')
      FileUtils.mkdir_p(directory)
      repository = File.expand_path('../..', __dir__)
      FileUtils.cp(File.join(repository, 'kernel/crypto/blake3/ORIGIN.md'), directory)
      source = File.join(directory, name)
      File.write(source, content)
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      auditor.instance_variable_set(:@sources, {})
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@inputs, CapturedTree.new(tree))
      auditor.send(:attribute_erxos, source, captured: source)
      yield auditor.instance_variable_get(:@sources).fetch(source), auditor.instance_variable_get(:@unresolved)
    end
  end

  def test_an_imported_file_is_recorded_under_the_license_of_its_origin_row
    attribute_beside_origin('blake3.c', "int fixture;\n") do |record, unresolved|
      assert_empty unresolved
      assert_equal 'Apache-2.0 WITH LLVM-exception', record.fetch('license')
      assert_equal 'imported', record.fetch('status')
      assert_includes record.fetch('evidence'), 'BLAKE3'
    end
  end

  def test_a_file_beside_an_origin_record_without_a_row_needs_the_erxos_notice
    attribute_beside_origin('unlisted.c', "int fixture;\n") do |record, unresolved|
      assert_equal 'unresolved', record.fetch('state')
      assert_includes unresolved.first, 'unlisted.c'
    end
    attribute_beside_origin('unlisted.c', "// #{Erx::FiascoProvenance::ERXOS_NOTICE}\n") do |record, unresolved|
      assert_empty unresolved
      assert_equal 'erxos', record.fetch('status')
    end
  end

  def test_embedded_musl_source_records_name_the_full_package_notice
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      part = File.join(root, 'fiasco/l4re-core')
      base = File.join(part, 'libc/musl/contrib/musl')
      FileUtils.mkdir_p(File.join(base, 'src/string'))
      source = File.join(base, 'src/string/strlen.c')
      copyright = File.join(base, 'COPYRIGHT')
      File.write(source, "/* SPDX-License-Identifier: MIT */\nint fixture;\n")
      File.write(copyright, "Full package permission grant fixture\n")
      Erx::Origin.new(root: part).write(repository: 'https://example.invalid/fixture', revision: 'fixture', archive_sha256: 'a' * 64,
        review: { 'rules' => [], 'default_license' => 'MIT', 'default_evidence' => 'fixture package grant' })
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      auditor.instance_variable_set(:@sources, {})
      logical = 'fiasco/l4re-core/libc/musl/contrib/musl/COPYRIGHT'
      expected = Digest::SHA256.file(copyright).hexdigest
      auditor.instance_variable_set(:@generation, { 'recipes' => { logical => expected } })
      auditor.send(:attribute, source)
      notice = auditor.instance_variable_get(:@sources).fetch(source).fetch('notices').first
      assert_equal logical, notice.fetch('path')
      assert_equal expected, notice.fetch('sha256')
    end
  end
  def test_missing_build_metadata_is_a_domain_error
    Dir.mktmpdir do |root|
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      assert_raises(Erx::Error) { auditor.audit }
    end
  end

  def test_gpl_notice_selection_does_not_match_lgpl_identifiers
    Dir.mktmpdir do |root|
      directory = File.join(root, 'fiasco/kernel/tool/preprocess')
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, 'COPYING'), 'GPL text')
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      auditor.instance_variable_set(:@sources, { 'fixture' => { 'license' => 'LGPL-2.0-only' } })
      assert_empty auditor.send(:license_notices)
    end
  end
  def test_image_check_never_executes_the_generated_makefile
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      build = File.join(root, 'build/fiasco')
      FileUtils.mkdir_p([File.join(build, 'images'), File.join(build, 'users/bin/arm64_armv8a/std/l4f'), File.join(root, 'config/fiasco')])
      File.write(File.join(build, 'users/Makefile'), '$(error unreviewed generated code)')
      File.write(File.join(build, 'images/bootstrap.raw'), 'final image')
      File.write(File.join(build, 'users/bin/arm64_armv8a/std/l4f/sigma0'), 'installed sigma')
      File.write(File.join(root, 'config/fiasco/modules.list'), 'fixed module list')
      FileUtils.mkdir_p(File.join(root, 'fiasco/mk/tool/bin'))
      File.write(File.join(root, 'fiasco/mk/tool/bin/l4image'), 'reviewed image-builder fixture')
      inputs = %w[kernel bootstrap sigma0].map do |name|
        path = "build/fiasco/#{name}.elf"
        File.write(File.join(root, path), 'linked input')
        { 'name' => name, 'artifact' => { 'path' => path, 'sha256' => Digest::SHA256.hexdigest('linked input') } }
      end
      commands = []
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, **_options|
        commands << argv
        # The replay of the flat image, whose arguments end in its output.
        File.write(argv.last, 'final image')
        {}
      end
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      auditor.instance_variable_set(:@generation, { 'image' => { 'entry' => 'banner', 'qemu_command' => 'fixed command' } })
      auditor.send(:audit_image, inputs)
      refute commands.any? { |argv| argv.first == 'gmake' }
    end
  end
  def generation_fixture
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      FileUtils.mkdir_p(File.join(root, 'config/provenance'))
      FileUtils.mkdir_p(File.join(root, 'fiasco/kernel/tool'))
      FileUtils.mkdir_p(File.join(root, 'build/fiasco/kernel'))
      recipe = File.join(root, 'fiasco/kernel/tool/generator')
      File.write(recipe, 'reviewed generator')
      config = 'build/fiasco/kernel/config'
      File.write(File.join(root, config), 'CONFIG_FEATURE=y')
      profiles = (1..8).to_h do |index|
        relative = "kernel/header#{index}.h"
        File.write(File.join(root, 'build/fiasco', relative), 'generated configuration')
        [relative, { 'role' => 'configuration', 'output_sha256' => Digest::SHA256.hexdigest('generated configuration'),
                     'code' => [], 'configuration' => [config], 'metadata' => [],
                     'object_list' => [], 'objects' => [], 'tools' => ['fiasco/kernel/tool/generator'] }]
      end
      profile = { 'version' => 1, 'recipes' => { 'fiasco/kernel/tool/generator' => Digest::SHA256.file(recipe).hexdigest },
                  'profiles' => profiles, 'compile_dependencies' => {},
                  'inputs' => { config => { 'mode' => 'text', 'sha256' => Digest::SHA256.hexdigest('CONFIG_FEATURE=y') } },
                  'image' => { 'entry' => 'banner', 'qemu_command' => 'fixed command' } }
      File.write(File.join(root, 'config/provenance/fiasco-generation.json'), JSON.generate(profile))
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      auditor.instance_variable_set(:@sources, {})
      yield root, auditor, recipe
    end
  end

  def test_fixed_profile_binds_recipe_and_output_without_inventing_a_license
    generation_fixture do |root, auditor, _recipe|
      auditor.send(:load_generation_profiles)
      output = File.join(root, 'build/fiasco/kernel/header1.h')
      record = auditor.send(:fixed_generation, output)
      assert_equal 'configuration', record.fetch('role')
      refute record.key?('license')
      assert_equal 1, record.fetch('tools').size
      File.write(output, 'unreviewed generated output')
      other = Erx::FiascoProvenance.new(root: root, runner: nil)
      other.send(:load_generation_profiles)
      assert_raises(Erx::Error) { other.send(:fixed_generation, output) }
    end
  end

  def test_stale_generator_or_missing_profile_is_refused
    generation_fixture do |root, auditor, recipe|
      File.write(recipe, 'changed generator')
      assert_raises(Erx::Error) { auditor.send(:load_generation_profiles) }
      File.unlink(File.join(root, 'config/provenance/fiasco-generation.json'))
      assert_raises(Erx::Error, Errno::ENOENT) { Erx::FiascoProvenance.new(root: root, runner: nil).send(:load_generation_profiles) }
    end
  end

  def test_changed_configuration_is_refused_even_when_generated_bytes_are_unchanged
    generation_fixture do |root, auditor, _recipe|
      File.write(File.join(root, 'build/fiasco/kernel/config'), 'CONFIG_FEATURE=n')
      assert_raises(Erx::Error) { auditor.send(:load_generation_profiles) }
    end
  end

  def test_literal_project_marker_cannot_replace_a_real_project_path
    generation_fixture do |root, auditor, _recipe|
      config = 'build/fiasco/kernel/config'
      File.write(File.join(root, config), '${PROJECT_ROOT}/path')
      path = File.join(root, 'config/provenance/fiasco-generation.json')
      profile = JSON.parse(File.read(path))
      profile.fetch('inputs').fetch(config)['sha256'] = Digest::SHA256.hexdigest('${PROJECT_ROOT}/path')
      File.write(path, JSON.generate(profile))
      assert_raises(Erx::Error) { auditor.send(:load_generation_profiles) }
    end
  end

  def test_recorded_tool_roles_survive_versioned_executable_names
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      FileUtils.mkdir_p(File.join(root, 'build/fiasco'))
      path = File.join(root, 'build/fiasco/profile.json')
      File.write(path, 'profile')
      port = Erx::CrossToolchain::Toolchain.new(prefix: 'aarch64-none-elf-')
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil, cross: port)
      auditor.define_singleton_method(:load_build_inputs) {}
      auditor.define_singleton_method(:load_generation_profiles) { @generation_profile = path }
      auditor.define_singleton_method(:tool_identity) do |program, **options|
        { 'program' => options.fetch(:role, program), 'path' => "/tools/versioned-#{File.basename(program)}-1" }
      end
      auditor.define_singleton_method(:audit_executable) { |name, *_paths| { 'name' => name } }
      auditor.define_singleton_method(:audit_image) { |_executables| {} }
      auditor.audit
      assert_equal '/tools/versioned-aarch64-none-elf-objcopy-1', auditor.instance_variable_get(:@image_objcopy)
      assert_equal '/tools/versioned-perl-1', auditor.instance_variable_get(:@image_perl)
    end
  end

  def test_thin_archive_is_refused_before_ar_can_read_external_members
    Dir.mktmpdir do |root|
      build = File.join(root, 'build/fiasco')
      FileUtils.mkdir_p(build)
      archive = File.join(build, 'thin.a')
      File.binwrite(archive, "!<thin>\n/host/private/member.o\n")
      invoked = false
      runner = Object.new
      runner.define_singleton_method(:run) { |*_args, **_options| invoked = true }
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      assert_raises(Erx::Error) { auditor.send(:archive_member_hash, archive, member: 'member.o') }
      refute invoked
    end
  end
  def test_each_audit_snapshots_current_artifacts
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      build = File.join(root, 'build/fiasco')
      Erx::FiascoProvenance::MAPS.each_value do |artifact, map|
        artifact_path = File.join(build, artifact)
        map_path = File.join(build, map)
        FileUtils.mkdir_p(File.dirname(map_path))
        File.binwrite(artifact_path, 'first artifact')
        File.binwrite(File.join(File.dirname(map_path), 'root.o'), 'object')
        File.write(map_path, "Linker script and memory map\n .text 0x10 0x4 root.o\n")
      end
      version = File.join(build, 'version.log')
      File.write(version, 'fixture archive tool')
      runner = Object.new
      runner.define_singleton_method(:run) { |_argv, **_options| { 'log' => version } }
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner, archive_program: '/usr/bin/true')
      auditor.define_singleton_method(:load_build_inputs) {}
      auditor.define_singleton_method(:load_generation_profiles) { @generation_profile = version }
      first = auditor.audit.fetch('executables').first.fetch('artifact').fetch('sha256')
      File.binwrite(File.join(build, 'kernel/fiasco'), 'second artifact')
      second = auditor.audit.fetch('executables').first.fetch('artifact').fetch('sha256')
      refute_equal first, second
    end
  end

  def test_generated_module_cannot_have_an_empty_source_witness
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      kernel = File.join(root, 'build/fiasco/kernel')
      FileUtils.mkdir_p(File.join(kernel, 'auto'))
      output = File.join(kernel, 'auto/file.h')
      File.write(output, 'generated header')
      File.write(File.join(kernel, '.Modules.deps'), "auto/file.h: auto/stamp.ready\nauto/stamp.ready:\n")
      File.write(File.join(kernel, '.erx-vpath'), 'kern')
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      auditor.send(:attribute_kernel_generated, output)
      assert_equal 'unresolved', auditor.instance_variable_get(:@sources).fetch(output).fetch('state')
    end
  end

  def test_duplicate_compiler_assignments_are_refused
    input = command_record('/source/header.h') + "source_src/root.o := /other/source.c\n"
    assert_raises(Erx::Error) { Erx::FiascoProvenance.recorded_compile(input, object: 'src/root.o') }
  end

  def test_compound_object_cycle_is_a_typed_refusal
    Dir.mktmpdir do |root|
      directory = File.join(root, 'build/fiasco/kernel')
      FileUtils.mkdir_p(directory)
      object = File.join(directory, 'jdb_compound.o')
      File.binwrite(object, 'object')
      File.write(File.join(directory, '.jdb_compound.o.deps'), 'jdb_compound.o')
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
      assert_raises(Erx::Error) { auditor.send(:audit_object, object) }
    end
  end

  def test_unknown_external_file_is_not_hashed
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        path = File.join(outside, 'unknown.h')
        File.write(path, 'unregistered external source')
        auditor = Erx::FiascoProvenance.new(root: root, runner: nil)
        assert_raises(Erx::Error) { auditor.send(:digest, path) }
      end
    end
  end

  def test_identical_archive_candidates_remain_ambiguous
    Dir.mktmpdir do |root|
      build = File.join(root, 'build/fiasco')
      %w[one two].each do |variant|
        FileUtils.mkdir_p(File.join(build, variant))
        File.binwrite(File.join(build, variant, 'member.o'), 'same object')
      end
      archive = File.join(build, 'lib.a')
      File.binwrite(archive, "!<arch>\narchive")
      map = File.join(build, 'image.map')
      File.write(map, "Linker script and memory map\n .text 0x10 0x4 lib.a(member.o)\n")
      runner = Object.new
      extracted = File.join(build, 'one/member.o')
      listing = File.join(build, 'archive-list.log')
      File.write(listing, "member.o\n")
      runner.define_singleton_method(:run) { |argv, **_options| { 'log' => argv[1] == 't' ? listing : extracted } }
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      auditor.send(:audit_executable, 'fixture', archive, map)
      assert auditor.instance_variable_get(:@unresolved).any? { |message| message.include?('ambiguous archive') }
      File.write(File.join(build, '.erx-archive-inputs'), 'one/member.o')
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      result = auditor.send(:audit_executable, 'fixture', archive, map)
      refute auditor.instance_variable_get(:@unresolved).any? { |message| message.include?('ambiguous archive') }
      member = result.fetch('contributions').first.fetch('compiles').first
      assert_equal 'build/fiasco/one/member.o', member.fetch('object').fetch('path')
    end
  end

  def test_archive_member_is_read_from_a_private_bound_snapshot
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      build = File.join(root, 'build/fiasco')
      FileUtils.mkdir_p(build)
      object = File.join(build, 'member.o')
      archive = File.join(build, 'lib.a')
      map = File.join(build, 'image.map')
      File.binwrite(object, 'object')
      File.binwrite(archive, "!<arch>\noriginal archive")
      File.write(map, "Linker script and memory map\n .text 0x10 0x4 lib.a(member.o)\n")
      extracted_from = nil
      listing = File.join(build, 'archive-list.log')
      File.write(listing, "member.o\n")
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, **_options|
        extracted_from = argv[-2] if argv[1] == 'p'
        File.binwrite(archive, 'replacement archive')
        { 'log' => argv[1] == 't' ? listing : object }
      end
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      result = auditor.send(:audit_executable, 'fixture', object, map)
      refute_equal archive, extracted_from
      assert_equal Digest::SHA256.hexdigest("!<arch>\noriginal archive"), result.fetch('contributions').first.fetch('archive').fetch('sha256')
    end
  end

  # One audit asks an archive for all its members, and listing it once is enough; the
  # listing still refuses a member it does not hold or holds twice, and other bytes are
  # listed again.
  def test_an_audit_lists_each_archive_once
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      build = File.join(root, 'build/fiasco')
      FileUtils.mkdir_p(build)
      archive = File.join(build, 'lib.a')
      File.binwrite(archive, "!<arch>\nfixture")
      listing = File.join(build, 'list.log')
      File.write(listing, "one.o\ntwo.o\ntwo.o\n")
      member = File.join(build, 'member.log')
      File.write(member, 'member bytes')
      commands = []
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, **_options|
        commands << argv[1]
        { 'log' => argv[1] == 't' ? listing : member }
      end
      auditor = Erx::FiascoProvenance.new(root: root, runner: runner)
      auditor.instance_variable_set(:@archive_program, 'ar')
      hash = ->(name) { auditor.send(:archive_member_hash, archive, member: name) }
      assert_equal Digest::SHA256.hexdigest('member bytes'), hash.call('one.o')
      hash.call('one.o')
      assert_equal %w[t p p], commands
      assert_raises(Erx::Error) { hash.call('absent.o') }
      assert_raises(Erx::Error) { hash.call('two.o') }
      assert_equal %w[t p p], commands
      File.binwrite(archive, "!<arch>\nother bytes")
      auditor.instance_variable_set(:@bytes, {})
      hash.call('one.o')
      assert_equal %w[t p p t p], commands
    end
  end

  def command_record(dependencies)
    "savedcmd_src/root.o := gcc -c root.c -o src/root.o\n" \
      "source_src/root.o := /source/root.c\n" \
      "deps_src/root.o := #{dependencies}\n"
  end

  def test_recorded_compile_reads_literal_dependencies_without_execution
    input = command_record("\\\n /source/root.h \\\n $(wildcard $(OBJ_BASE)/include/config/MMU) /source/space\\ header.h")
    result = Erx::FiascoProvenance.recorded_compile(input, object: 'src/root.o')
    assert_equal ['/source/root.c', '/source/root.h', '/source/space header.h'], result.fetch('sources')
    assert_equal 'gcc -c root.c -o src/root.o', result.fetch('command')
  end

  def test_recorded_compile_rejects_make_expansion_and_missing_records
    ['$(shell touch /tmp/forbidden)', '$(wildcard /arbitrary/*)', '/source/root.h # hidden'].each do |dependency|
      assert_raises(Erx::Error) do
        Erx::FiascoProvenance.recorded_compile(command_record(dependency), object: 'src/root.o')
      end
    end
    assert_raises(Erx::Error) do
      Erx::FiascoProvenance.recorded_compile(command_record('/source/root.h'), object: 'other.o')
    end
  end
end
