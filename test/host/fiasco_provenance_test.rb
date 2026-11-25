# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/fiasco_provenance'
require_relative '../fixtures/link_inputs'

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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
      auditor.instance_variable_set(:@sources, {})
      logical = 'fiasco/l4re-core/libc/musl/contrib/musl/COPYRIGHT'
      expected = Digest::SHA256.file(copyright).hexdigest
      auditor.instance_variable_set(:@generation, { 'recipes' => { logical => expected } })
      auditor.send(:attribute, source)
      record = auditor.instance_variable_get(:@sources).fetch(source)
      assert_equal 'release', record.fetch('status'), 'l4re-core is a part of Fiasco, a release component'
      notice = record.fetch('notices').first
      assert_equal logical, notice.fetch('path')
      assert_equal expected, notice.fetch('sha256')
    end
  end
  # A file of each part is recorded under its part's status (docs/design.md's dependency
  # table): libfdt, which outlives Fiasco, permanent; Fiasco's own parts release.
  def test_each_part_records_its_files_under_its_own_status
    { 'libfdt' => 'permanent', 'kernel' => 'release', 'drivers-frst' => 'release' }.each do |name, status|
      Dir.mktmpdir do |temporary|
        root = File.realpath(temporary)
        part = File.join(root, 'fiasco', name)
        FileUtils.mkdir_p(part)
        source = File.join(part, 'fixture.c')
        File.write(source, "/* SPDX-License-Identifier: MIT */\nint fixture;\n")
        Erx::Origin.new(root: part).write(repository: 'https://example.invalid/fixture', revision: 'fixture', archive_sha256: 'a' * 64,
          review: { 'rules' => [], 'default_license' => 'MIT', 'default_evidence' => 'fixture package grant' })
        auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
        auditor.instance_variable_set(:@sources, {})
        auditor.send(:attribute, source)
        assert_equal status, auditor.instance_variable_get(:@sources).fetch(source).fetch('status'), name
      end
    end
  end

  def test_missing_build_metadata_is_a_domain_error
    Dir.mktmpdir do |root|
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
      assert_raises(Erx::Error) { auditor.audit }
    end
  end

  def test_gpl_notice_selection_does_not_match_lgpl_identifiers
    Dir.mktmpdir do |root|
      directory = File.join(root, 'fiasco/kernel/tool/preprocess')
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, 'COPYING'), 'GPL text')
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
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
      inputs = { config => { 'mode' => 'text', 'sha256' => Digest::SHA256.hexdigest('CONFIG_FEATURE=y') } }
      # The release kernel's copies of the generated files, with other bytes and
      # their own configuration, which no hash in the profile holds.
      FileUtils.mkdir_p(File.join(root, 'build/fiasco/kernel-release'))
      File.write(File.join(root, 'build/fiasco/kernel-release/config'), 'CONFIG_FEATURE=n')
      (1..8).each { |index| File.write(File.join(root, "build/fiasco/kernel-release/header#{index}.h"), 'release configuration') }
      profile = { 'version' => 1, 'recipes' => { 'fiasco/kernel/tool/generator' => Digest::SHA256.file(recipe).hexdigest },
                  Erx::BuildKind::DEVELOPMENT => { 'profiles' => profiles, 'compile_dependencies' => {}, 'inputs' => inputs,
                                                   'image' => { 'entry' => 'banner', 'qemu_command' => 'fixed command' } } }
      File.write(File.join(root, 'config/provenance/fiasco-generation.json'), JSON.generate(profile))
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
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
    end
  end

  # A release audit reads the development kernel's generated-file entries in
  # its own kernel directory, without the development build's hashes: neither
  # the generated bytes nor the configuration the profile pins hold a release
  # kernel, and a development audit does not know the release directory.
  def test_a_release_audit_reads_the_kernel_entries_in_its_own_directory_unpinned
    generation_fixture do |root, _auditor, _recipe|
      output = File.join(root, 'build/fiasco/kernel-release/header1.h')
      release = Erx::FiascoProvenance.new(root: root, runner: nil, kind: Erx::BuildKind::RELEASE)
      release.instance_variable_set(:@sources, {})
      release.send(:load_generation_profiles)
      record = release.send(:fixed_generation, output)
      assert_equal 'configuration', record.fetch('role')
      assert_equal ['build/fiasco/kernel-release/config'], record.fetch('configuration').map { |input| input.fetch('path') }
      development = Erx::FiascoProvenance.new(root: root, runner: nil, kind: Erx::BuildKind::DEVELOPMENT)
      development.send(:load_generation_profiles)
      assert_nil development.send(:fixed_generation, output)
    end
  end

  def test_an_audit_has_no_default_build_kind
    assert_raises(ArgumentError) { Erx::FiascoProvenance.new(root: __dir__, runner: nil) }
  end

  # Every build kind's audit reads every executable a boot image carries: its
  # own kernel, from the kind's kernel directory, and the bootstrap and sigma0
  # both kinds' images share. Only a development build's audit also reads the
  # image the build packed.
  def test_every_audit_reads_each_executable_a_boot_image_carries
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      users = Erx::FiascoProvenance::USER_EXECUTABLES.transform_values do |path|
        [File.join(root, 'build/fiasco', path), File.join(root, 'build/fiasco', "#{path}.inputs")]
      end
      { Erx::BuildKind::RELEASE => 'kernel-release', Erx::BuildKind::DEVELOPMENT => 'kernel' }.each do |kind, directory|
        auditor = Erx::FiascoProvenance.new(root: root, runner: nil, kind: kind)
        kernel = %w[fiasco fiasco.inputs].map { |name| File.join(root, 'build/fiasco', directory, name) }
        assert_equal({ 'kernel' => kernel }.merge(users), auditor.executable_links, kind)
        assert_equal Erx::BuildKind.development?(kind), auditor.instance_variable_get(:@plan).image, kind
      end
    end
  end


  # The seeded fault the release audit of the users exists for: a source under
  # the LGPL in bootstrap's link closure. A fixture closure (a bootstrap whose
  # one object compiles a header an import inventory records as LGPL-2.1-only)
  # is audited as a release; the gate refuses the release and names the header.
  def test_a_release_refuses_a_non_permissive_source_in_bootstraps_closure
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      header = 'build/fiasco/inputs/fiasco/l4re-core/fixture/include/lgpl.h'
      sources = [{ 'path' => header, 'license' => 'LGPL-2.1-only', 'status' => 'release', 'source' => header,
                   'original_source' => 'fiasco/l4re-core/fixture/include/lgpl.h' },
                 { 'path' => 'kip.cpp', 'license' => 'MIT' }]
      directory = File.join(root, 'build/fiasco/kernel-release')
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, 'fiasco'), 'kernel bytes')
      auditor = Erx::FiascoProvenance.new(root: root, runner: nil, kind: Erx::BuildKind::RELEASE)
      auditor.define_singleton_method(:capture_construction) {}
      read = auditor.executable_links.keys
      auditor.define_singleton_method(:audit) do
        { 'state' => 'complete', 'unresolved' => [], 'sources' => read.include?('bootstrap') ? sources : sources.drop(1),
          'executables' => read.map { |name| { 'name' => name, 'artifact' => send(:reference, File.join(directory, 'fiasco')) } } }
      end
      error = assert_raises(Erx::Error) { auditor.certify }
      assert_includes error.message, "#{header} (LGPL-2.1-only)"
      refute File.exist?(File.join(directory, Erx::FiascoProvenance::PASS_RECORD))
    end
  end

  # The seeded fault the release check exists for: jdb_object.cpp linked into
  # a release kernel, under the license its row in fiasco/kernel/ORIGIN.md
  # records, is refused by name; permissive terms, the FSF All Permissive
  # License, a choice with a permissive branch, an exception to a permissive
  # license and each of GCC's three headers, from a GCC include directory under
  # the label its registration gives it, pass, as LicenseCheck passes them
  # for the image check. A record without a license passes only as configuration
  # or as a file made from other records of the closure (a module's sources, a
  # generator's code and the sources of the objects it reads); one made from
  # nothing the closure records is refused as having no license.
  def test_a_release_kernel_refuses_each_source_a_release_may_not_carry
    repository = File.expand_path('../..', __dir__)
    license = Erx::Origin.new(root: File.join(repository, 'fiasco/kernel')).imported_file('src/kern/jdb_object.cpp').fetch('license')
    # The report names the kernel build's copy; the build read the staged input.
    jdb = 'build/fiasco/kernel-release/src/jdb_object.cpp'
    staged = 'build/fiasco/inputs/fiasco/kernel/src/kern/jdb_object.cpp'
    sources = [{ 'path' => jdb, 'license' => license, 'status' => 'release',
                 'source' => staged, 'original_source' => 'fiasco/kernel/src/kern/jdb_object.cpp' },
               { 'path' => 'kip.cpp', 'license' => 'MIT' },
               { 'path' => 'kip_addr.S', 'license' => 'FSFAP' },
               { 'path' => 'fdt.c', 'license' => '(GPL-2.0-or-later OR BSD-2-Clause)' },
               { 'path' => 'stddef.h', 'license' => 'Apache-2.0 WITH LLVM-exception' },
               { 'path' => 'build/fiasco/kernel-release/auto/main.cc', 'generated_from' => [{ 'path' => 'kip.cpp' }] },
               { 'path' => 'build/fiasco/kernel-release/globalconfig.h', 'role' => 'configuration', 'code' => [] },
               { 'path' => 'build/fiasco/kernel-release/tcboffset.h', 'role' => 'code', 'code' => [],
                 'objects' => [{ 'object' => { 'path' => 'tcboffset.o' }, 'sources' => [{ 'path' => 'fdt.c' }] }] }]
    assert_equal [[jdb, 'GPL-2.0-only']], Erx::FiascoProvenance.non_permissive(sources, build_kind: 'release', registered: {})
    assert_empty Erx::FiascoProvenance.non_permissive(sources, build_kind: 'development', registered: {})
    orphan = { 'path' => 'orphan.h', 'role' => 'code', 'code' => [], 'objects' => [] }
    unrecorded = { 'path' => 'unrecorded.h', 'generated_from' => [{ 'path' => 'elsewhere.cpp' }] }
    unresolved = { 'path' => 'unresolved.c', 'state' => 'unresolved' }
    assert_equal [['orphan.h', 'no license'], ['unrecorded.h', 'no license'], ['unresolved.c', 'no license']],
                 Erx::FiascoProvenance.non_permissive(sources.drop(1) + [orphan, unrecorded, unresolved],
                                                      build_kind: 'release', registered: {})

    auditor = Erx::FiascoProvenance.new(root: repository, runner: nil, kind: Erx::BuildKind::RELEASE)
    report = { 'state' => 'complete', 'unresolved' => [], 'sources' => sources.first(1) }
    error = assert_raises(Erx::Error) { auditor.check_permissive(report) }
    assert_includes error.message, "#{jdb} (GPL-2.0-only)"
    blocked = report.merge('state' => 'blocked', 'unresolved' => ['source has no origin: fixture.c'])
    assert_includes assert_raises(Erx::Error) { auditor.check_permissive(blocked) }.message, 'fixture.c'
  end

  # No build takes a compiler header under GCC's terms: the toolchain is LLVM's,
  # whose headers are permissive, so GCC's exception is refused in every build
  # kind, whatever label a toolchain registration gives the header, as on a GCC
  # runtime file of l4re-core.
  def test_no_build_takes_gccs_exception
    gcc = 'GPL-3.0-or-later WITH GCC-exception-3.1'
    include = '/opt/cross/lib/gcc/aarch64-elf/16.2.0/include'
    crtstuff = 'build/fiasco/inputs/fiasco/l4re-core/libgcc/contrib/gcc-16/libgcc/crtstuff.c'
    refused = [[{ 'path' => "#{include}/stdarg.h" }, 'toolchain/gcc-16.2.0/stdarg.h'],
               [{ 'path' => "#{include}/stdarg.h" }, nil],
               [{ 'path' => crtstuff, 'source' => crtstuff,
                  'original_source' => 'fiasco/l4re-core/libgcc/contrib/gcc-16/libgcc/crtstuff.c' }, nil]]
    refused.product(%w[development release]).each do |(fields, label), kind|
      source = { 'license' => gcc, 'status' => 'release' }.merge(fields)
      registered = label ? { source.fetch('path') => label } : {}
      assert_equal [[source.fetch('path'), gcc]], Erx::FiascoProvenance.non_permissive([source], build_kind: kind, registered:),
                   [source, label, kind].inspect
    end
  end

  # A release kernel that passes gets the record that it passed, which names
  # its build kind and the bytes the audit read; one that fails gets none.
  # (Fiasco#build_release_kernel removes the kernel; fiasco_test.rb covers it.)
  def test_only_a_release_kernel_that_passes_gets_a_pass_record
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      directory = File.join(root, 'build/fiasco/kernel-release')
      FileUtils.mkdir_p(directory)
      kernel = File.join(directory, 'fiasco')
      record = File.join(directory, Erx::FiascoProvenance::PASS_RECORD)
      certify = lambda do |sources|
        File.write(kernel, 'kernel bytes')
        auditor = Erx::FiascoProvenance.new(root: root, runner: nil, kind: Erx::BuildKind::RELEASE)
        auditor.define_singleton_method(:capture_construction) {}
        auditor.define_singleton_method(:audit) do
          { 'state' => 'complete', 'unresolved' => [], 'sources' => sources,
            'executables' => [{ 'name' => 'kernel', 'artifact' => send(:reference, kernel) }] }
        end
        auditor.certify
      end
      assert_equal record, certify.call([{ 'path' => 'kip.cpp', 'license' => 'MIT' }])
      passed = JSON.parse(File.read(record))
      assert_equal Erx::BuildKind::RELEASE, passed.fetch('build_kind')
      assert_equal({ 'path' => 'build/fiasco/kernel-release/fiasco', 'sha256' => Digest::SHA256.hexdigest('kernel bytes') },
                   passed.fetch('kernel'))
      error = assert_raises(Erx::Error) { certify.call([{ 'path' => 'jdb_object.cpp', 'license' => 'GPL-2.0-only' }]) }
      FileUtils.rm_f(record)
      error = assert_raises(Erx::Error) { certify.call([{ 'path' => 'jdb_object.cpp', 'license' => 'GPL-2.0-only' }]) }
      assert_includes error.message, 'jdb_object.cpp (GPL-2.0-only)'
      refute File.exist?(record)
    end
  end

  def test_stale_generator_or_missing_profile_is_refused
    generation_fixture do |root, auditor, recipe|
      File.write(recipe, 'changed generator')
      assert_raises(Erx::Error) { auditor.send(:load_generation_profiles) }
      File.unlink(File.join(root, 'config/provenance/fiasco-generation.json'))
      assert_raises(Erx::Error, Errno::ENOENT) { Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil).send(:load_generation_profiles) }
    end
  end

  # A development build on a host whose tools make other bytes than the profile
  # pins (another cross toolchain) passes, and its report names each such build
  # input and generated file with the pinned hash and the host's.
  def test_a_development_audit_records_what_differs_from_the_pins
    generation_fixture do |root, auditor, _recipe|
      File.write(File.join(root, 'build/fiasco/kernel/config'), 'CONFIG_FEATURE=n')
      output = File.join(root, 'build/fiasco/kernel/header1.h')
      File.write(output, 'host generated output')
      auditor.send(:load_generation_profiles)
      assert_equal 'configuration', auditor.send(:fixed_generation, output).fetch('role')
      sha = ->(bytes) { Digest::SHA256.hexdigest(bytes) }
      assert_equal [{ 'path' => 'build/fiasco/kernel/config', 'pinned' => sha.call('CONFIG_FEATURE=y'), 'sha256' => sha.call('CONFIG_FEATURE=n') },
                    { 'path' => 'build/fiasco/kernel/header1.h', 'pinned' => sha.call('generated configuration'),
                      'sha256' => sha.call('host generated output') }],
                   auditor.send(:host_generated)
    end
  end

  # A development build whose bytes match the pins records nothing, and a release
  # audit, which reads no pin, records nothing either, though its bytes differ.
  def test_only_a_development_audit_compares_with_the_pins
    generation_fixture do |root, auditor, _recipe|
      auditor.send(:load_generation_profiles)
      auditor.send(:fixed_generation, File.join(root, 'build/fiasco/kernel/header1.h'))
      assert_equal [], auditor.send(:host_generated)
      release = Erx::FiascoProvenance.new(root: root, runner: nil, kind: Erx::BuildKind::RELEASE)
      release.instance_variable_set(:@sources, {})
      release.send(:load_generation_profiles)
      release.send(:fixed_generation, File.join(root, 'build/fiasco/kernel-release/header1.h'))
      assert_equal [], release.send(:host_generated)
    end
  end

  def test_literal_project_marker_cannot_replace_a_real_project_path
    generation_fixture do |root, auditor, _recipe|
      config = 'build/fiasco/kernel/config'
      File.write(File.join(root, config), '${PROJECT_ROOT}/path')
      path = File.join(root, 'config/provenance/fiasco-generation.json')
      profile = JSON.parse(File.read(path))
      profile.fetch(Erx::BuildKind::DEVELOPMENT).fetch('inputs').fetch(config)['sha256'] = Digest::SHA256.hexdigest('${PROJECT_ROOT}/path')
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
      programs = { compiler: 'llvm/bin/clang', linker: 'lld/bin/ld.lld' }.transform_values do |relative|
        FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
        File.write(File.join(root, relative), '')
        File.chmod(0o755, File.join(root, relative))
        File.join(root, relative)
      end
      toolchain = Erx::FiascoToolchain.new(**programs)
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil, toolchain: toolchain)
      auditor.define_singleton_method(:load_build_inputs) {}
      auditor.define_singleton_method(:load_generation_profiles) { @generation_profile = path }
      auditor.define_singleton_method(:tool_identity) do |program, **options|
        { 'program' => options.fetch(:role, program), 'path' => "/tools/versioned-#{File.basename(program)}-1" }
      end
      auditor.define_singleton_method(:audit_executable) { |name, *_paths| { 'name' => name } }
      auditor.define_singleton_method(:audit_image) { |_executables| {} }
      auditor.audit
      assert_equal '/tools/versioned-llvm-objcopy-1', auditor.instance_variable_get(:@image_objcopy)
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
      assert_raises(Erx::Error) { auditor.send(:archive_member_hash, archive, member: 'member.o') }
      refute invoked
    end
  end
  def test_each_audit_snapshots_current_artifacts
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      build = File.join(root, 'build/fiasco')
      Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil).executable_links.each_value do |artifact_path, inputs_path|
        FileUtils.mkdir_p(File.dirname(inputs_path))
        File.binwrite(artifact_path, 'first artifact')
        File.binwrite(File.join(File.dirname(inputs_path), 'root.o'), 'object')
        File.write(inputs_path, LinkInputsFixture.text('root.o'))
      end
      version = File.join(build, 'version.log')
      File.write(version, 'fixture archive tool')
      runner = Object.new
      runner.define_singleton_method(:run) { |_argv, **_options| { 'log' => version } }
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner, archive_program: '/usr/bin/true')
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
      assert_raises(Erx::Error) { auditor.send(:audit_object, object) }
    end
  end

  def test_unknown_external_file_is_not_hashed
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        path = File.join(outside, 'unknown.h')
        File.write(path, 'unregistered external source')
        auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
        assert_raises(Erx::Error) { auditor.send(:digest, path) }
      end
    end
  end

  # An executable whose input list names nothing would audit nothing, so the audit
  # refuses it rather than certify an empty contribution list: an empty list, and a
  # list that is not LLD's --trace output, such as a link map.
  def test_an_executable_with_no_audited_contribution_is_refused
    Dir.mktmpdir do |root|
      root = File.realpath(root)
      list = File.join(root, 'build/fiasco/image.inputs')
      FileUtils.mkdir_p(File.dirname(list))
      { '' => /does not end with a newline/,
        "Linker script and memory map\n .text 0x10000 0x4 root.o\n" => /not an input name/ }.each do |bytes, message|
        File.write(list, bytes)
        # The audit reads each input once, so each list gets an auditor of its own.
        auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: nil)
        error = assert_raises(Erx::Error, bytes.inspect) { auditor.send(:audit_executable, 'fixture', list, list) }
        assert_match message, error.message, bytes.inspect
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
      inputs = File.join(build, 'image.inputs')
      File.write(inputs, LinkInputsFixture.text('lib.a(member.o)'))
      runner = Object.new
      extracted = File.join(build, 'one/member.o')
      listing = File.join(build, 'archive-list.log')
      File.write(listing, "member.o\n")
      runner.define_singleton_method(:run) { |argv, **_options| { 'log' => argv[1] == 't' ? listing : extracted } }
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      auditor.send(:audit_executable, 'fixture', archive, inputs)
      assert auditor.instance_variable_get(:@unresolved).any? { |message| message.include?('ambiguous archive') }
      File.write(File.join(build, '.erx-archive-inputs'), 'one/member.o')
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      result = auditor.send(:audit_executable, 'fixture', archive, inputs)
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
      inputs = File.join(build, 'image.inputs')
      File.binwrite(object, 'object')
      File.binwrite(archive, "!<arch>\noriginal archive")
      File.write(inputs, LinkInputsFixture.text('lib.a(member.o)'))
      extracted_from = nil
      listing = File.join(build, 'archive-list.log')
      File.write(listing, "member.o\n")
      runner = Object.new
      runner.define_singleton_method(:run) do |argv, **_options|
        extracted_from = argv[-2] if argv[1] == 'p'
        File.binwrite(archive, 'replacement archive')
        { 'log' => argv[1] == 't' ? listing : object }
      end
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
      auditor.instance_variable_set(:@unresolved, [])
      auditor.instance_variable_set(:@sources, {})
      result = auditor.send(:audit_executable, 'fixture', object, inputs)
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
      auditor = Erx::FiascoProvenance.new(root: root, kind: Erx::BuildKind::DEVELOPMENT, runner: runner)
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
