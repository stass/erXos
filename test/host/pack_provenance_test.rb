# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/pack_provenance'

class PackProvenanceTest < Minitest::Test
  # Each catalog class closes over the caller's record, including instances
  # built by BuildInputs#merge. Both read operations record their requests.
  def tracking_inputs_class(requested_paths)
    Class.new(Erx::BuildInputs) do
      define_method(:read) do |path, **options|
        requested_paths << File.realpath(path)
        super(path, **options)
      end

      define_method(:verify) do |path|
        requested_paths << File.realpath(path)
        super(path)
      end
    end
  end

  class ReadTracking < Erx::PackProvenance
    attr_reader :opened_paths

    private

    def bounded_read(path, **options)
      (@opened_paths ||= []) << File.realpath(path)
      super
    end
  end
  def archive_fixture(bytes:, &on_run)
    archive = write('root.a', bytes)
    File.write(@map, "10000 10000 4 4 root.a(root.o):(.text)\n")
    @receipt['linker_map'] = reference(@map).merge('format' => 'lld', 'directory' => '.')
    @receipt['archives'] = [reference(archive).merge('members' => [
      { 'name' => 'root.o', 'sha256' => reference(@object).fetch('sha256'), 'object_path' => 'root.o' }
    ])]
    object = @object
    listing = write('archive-members.txt', "root.o\n")
    runner = Object.new
    runner.define_singleton_method(:run) do |argv, **options|
      next({ 'log' => listing }) if argv[1] == 't'
      on_run.call(argv, options)
      { 'log' => object }
    end
    @resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, runner: runner)
    archive
  end

  def test_generic_archive_check_refuses_thin_archives_before_ar
    called = false
    archive_fixture(bytes: "!<thin>\n/host/private.o\n") { |_argv, _options| called = true }
    assert_raises(Erx::Error) { resolve }
    refute called
  end

  def test_generic_archive_check_snapshots_bytes_and_ends_options
    command = nil
    archive = archive_fixture(bytes: "!<arch>\nnormal archive") do |argv, _options|
      command = argv
      assert_equal "!<arch>\nnormal archive", File.binread(argv[-2])
    end
    assert_equal ['root.c'], resolve.map { |record| record.fetch('path') }
    assert_equal '--', command.fetch(2)
    refute_equal archive, command[-2]
  end

  class FixtureFiasco < Erx::PackProvenance
    attr_accessor :audit_result
    attr_reader :audit_calls

    private

    def fresh_fiasco_audit
      @audit_calls = (@audit_calls || 0) + 1
      [[], audit_result, @catalog]
    end
  end

  def fiasco_fixture
    require_relative '../../tools/lib/erx/fiasco_provenance'
    FileUtils.mkdir_p(File.join(@root, 'build/fiasco/images'))
    image = write('build/fiasco/images/bootstrap_banner.elf', 'Fiasco image')
    facts = { 'state' => 'complete', 'image' => { 'artifact' => reference(image) },
              'sources' => [{ 'path' => 'root.c', 'license' => 'BSD-2-Clause' }] }
    audit = write('build/fiasco/provenance.json', Erx::FiascoProvenance.canonical_report(facts))
    receipt = write('fiasco-receipt.json', JSON.generate('version' => 1, 'kind' => 'fiasco',
                      'artifact' => reference(image), 'audit' => reference(audit)))
    resolver = FixtureFiasco.new(root: @root, catalog: build_catalog, runner: Object.new)
    resolver.audit_result = facts
    [resolver, receipt, image, audit]
  end

  def test_fiasco_receipt_rechecks_the_fixed_backend_and_binds_audit_bytes
    resolver, receipt, image, _audit = fiasco_fixture
    records = resolver.resolve(receipt: receipt, artifact: image, build_kind: 'development')
    assert_equal ['root.c'], records.map { |record| record.fetch('path') }
    assert_equal 1, resolver.audit_calls
    resolver.audit_result = resolver.audit_result.merge('state' => 'blocked')
    assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: image, build_kind: 'development') }
  end

  def test_fiasco_receipt_cannot_select_another_artifact_or_report
    resolver, receipt, image, _audit = fiasco_fixture
    parsed = JSON.parse(File.read(receipt))
    parsed['audit'] = reference(@source)
    File.write(receipt, JSON.generate(parsed))
    assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: image, build_kind: 'development') }
    assert_nil resolver.audit_calls
    parsed['artifact'] = reference(@artifact)
    File.write(receipt, JSON.generate(parsed))
    assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development') }
    assert_nil resolver.audit_calls
  end

  def test_fiasco_stopgap_license_blocks_release_images
    resolver, receipt, image, audit = fiasco_fixture
    directory = File.join(@root, 'fiasco/kernel')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'source.cpp'), "// SPDX-License-Identifier: GPL-2.0-only\nint fixture;\n")
    FileUtils.mkdir_p(File.join(directory, 'legal'))
    license_text = File.join(directory, 'legal/gpl2.txt')
    File.write(license_text, 'Complete fixture GPL version 2 license text')
    Erx::Origin.new(root: directory).write(repository: 'https://example.invalid/fixture', revision: 'fixture',
      archive_sha256: 'a' * 64, review: { 'rules' => [], 'default_license' => 'GPL-2.0-only', 'default_evidence' => 'fixture SPDX' })
    facts = resolver.audit_result.merge('sources' => [{ 'path' => 'fiasco/kernel/source.cpp', 'license' => 'GPL-2.0-only' }],
                                        'license_notices' => { 'GPL-2.0-only' => [reference(license_text)] })
    resolver.audit_result = facts
    File.write(audit, Erx::FiascoProvenance.canonical_report(facts))
    parsed = JSON.parse(File.read(receipt))
    parsed['audit'] = reference(audit)
    File.write(receipt, JSON.generate(parsed))
    resolver.instance_variable_set(:@catalog, build_catalog.merge(Erx::BuildInputs.imported(root: directory)))
    records = resolver.resolve(receipt: receipt, artifact: image, build_kind: 'development')
    assert_equal 'stopgap', records.first.fetch('status')
    assert_includes records.first.fetch('notice'), 'Complete fixture GPL version 2 license text'
    assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: image, build_kind: 'release') }
  end

  def test_gnu_script_scalars_are_not_file_contributions
    map = "Linker script and memory map\n .text 0x10000 0x4 root.o\n" +
          %w[BYTE SHORT LONG QUAD SQUAD].map { |op| " 0x10004 0x8 #{op} 0x10 (_end - _start)\n" }.join
    assert_equal ['root.o'], Erx::PackProvenance.contributors(map, format: 'gnu')
    assert_raises(Erx::Error) do
      Erx::PackProvenance.contributors(map + " 0x10008 0x8 UNKNOWN 0x0\n", format: 'gnu')
    end
    assert_raises(Erx::Error) do
      Erx::PackProvenance.contributors(map + " 0x10008 0x8 QUAD 0x0 hidden.o\n", format: 'gnu')
    end
  end

  def test_compiler_mp_phony_rules_only_repeat_prerequisites
    assert_equal [%w[root.o], ['root.c', 'space header.h']],
                 Erx::PackProvenance.dependencies("root.o: root.c space\\ header.h\nroot.c:\nspace\\ header.h:\n")
    ["root.o: root.c\nother.h:\n", "root.o: root.c\nroot.c: hidden.h\n",
     "root.o: root.c\nroot.c other.h:\n"].each do |bytes|
      assert_raises(Erx::Error) { Erx::PackProvenance.dependencies(bytes) }
    end
  end

  class ChangedAfterCheck < Erx::PackProvenance
    attr_accessor :replace_path, :replacement

    private

    def checked_file(reference)
      result = super
      if result.fetch('path') == replace_path
        File.binwrite(replace_path, replacement)
        self.replace_path = nil
      end
      result
    end
  end
  class BoundedVisits < Erx::PackProvenance
    private

    def visit(*arguments, **options)
      @test_visits = (@test_visits || 0) + 1
      raise Erx::Error, 'test guard: receipt traversal repeated completed work' if @test_visits > 2000
      super
    end
  end

  def setup
    @produced = []
    @root = Dir.mktmpdir('erx-provenance-')
    File.write(File.join(@root, 'LICENSE'), 'project BSD licence text')
    @source = write('root.c', "/* SPDX-License-Identifier: BSD-2-Clause */\nint start;\n")
    @object = write('root.o', 'object bytes')
    @artifact = write('root.elf', 'linked bytes')
    @dependency = write('root.d', "root.o: root.c\n")
    @map = write('root.map', "VMA LMA Size Align Out In Symbol\n10000 10000 4 4 root.o:(.text)\n")
    @receipt = { 'version' => 1, 'kind' => 'linked', 'artifact' => reference(@artifact),
                 'linker_map' => reference(@map).merge('format' => 'lld', 'directory' => '.'),
                 'compiles' => [{ 'object' => reference(@object), 'dependency' => reference(@dependency),
                                  'directory' => '.', 'sources' => [reference(@source)] }],
                 'archives' => [], 'inputs' => [] }
    @resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(name, bytes)
    path = File.join(@root, name)
    File.binwrite(path, bytes)
    @produced << path unless @produced.include?(path)
    path
  end

  def build_catalog(inputs_class: Erx::BuildInputs)
    inputs_class.pack(root: @root, paths: @produced)
  end

  def test_hash_tracking_survives_catalog_merge
    requested_paths = []
    catalog = build_catalog(inputs_class: tracking_inputs_class(requested_paths))
    merged = catalog.merge(build_catalog)
    merged.verify(@artifact)
    merged.read(@object, maximum: 1024 * 1024)
    assert_equal [File.realpath(@artifact), File.realpath(@object)], requested_paths
  end

  def reference(path)
    { 'path' => path.delete_prefix(@root + '/'), 'sha256' => Digest::SHA256.file(path).hexdigest }
  end

  def resolve
    receipt = write('receipt.json', JSON.generate(@receipt))
    @resolver.instance_variable_set(:@catalog, build_catalog)
    @resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development')
  end

  def test_actual_object_closure_has_stable_names_and_notices
    records = resolve
    assert_equal ['root.c'], records.map { |record| record.fetch('path') }
    assert_equal 'BSD-2-Clause', records.first.fetch('license')
    assert_includes @resolver.notices(records), 'project BSD licence text'
    refute_includes JSON.generate(records), @root
  end

  def test_permissive_license_alternative_is_selected_instead_of_requiring_both
    File.write(@source, "/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0-only */\nint start;\n")
    @receipt.fetch('compiles').first['sources'] = [reference(@source)]
    record = resolve.first
    assert_equal 'BSD-3-Clause', record.fetch('license')
    assert_equal 'BSD-3-Clause OR GPL-2.0-only', record.fetch('declared_license')
  end

  def test_permissive_stopgap_is_allowed_in_release_provenance
    external = [{ 'path' => @source, 'sha256' => Digest::SHA256.file(@source).hexdigest,
                  'label' => 'third_party/fixture/root.c', 'license' => 'BSD-2-Clause',
                  'status' => 'stopgap', 'evidence' => 'reviewed permissive fixture',
                  'notices' => [{ 'path' => File.join(@root, 'LICENSE'),
                                  'sha256' => Digest::SHA256.file(File.join(@root, 'LICENSE')).hexdigest }] }]
    receipt = write('receipt.json', JSON.generate(@receipt))
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: external)
    records = resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release')
    assert_equal 'stopgap', records.first.fetch('status')
    assert_equal 'BSD-2-Clause', records.first.fetch('license')
    external.first['license'] = 'GPL-2.0-only'
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: external)
    assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release') }
    assert_equal 'GPL-2.0-only', resolver.resolve(receipt: receipt, artifact: @artifact,
                                                build_kind: 'development').first.fetch('license')
  end

  def test_empty_receipt_is_a_typed_refusal
    receipt = write('empty.json', ''.b)
    @resolver.instance_variable_set(:@catalog, build_catalog)
    assert_raises(Erx::Error) do
      @resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development')
    end
  end

  def test_outside_initial_receipt_is_rejected_without_reading_it
    Dir.mktmpdir('outside-receipt-') do |outside|
      path = File.join(outside, 'receipt.json')
      File.write(path, JSON.generate(@receipt))
      resolver = ReadTracking.new(root: @root, catalog: build_catalog)
      error = begin
        resolver.resolve(receipt: path, artifact: @artifact, build_kind: 'development')
        nil
      rescue Erx::Error => refused
        refused
      end
      refute_includes(resolver.opened_paths || [], File.realpath(path))
      assert_instance_of Erx::Error, error
    end
  end

  def test_outside_artifact_is_not_hashed_before_authorization
    Dir.mktmpdir('outside-artifact-') do |outside|
      path = File.join(outside, 'artifact')
      File.binwrite(path, 'outside bytes')
      @receipt['artifact'] = { 'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest }
      receipt = write('receipt.json', JSON.generate(@receipt))
      requested_paths = []
      catalog = build_catalog(inputs_class: tracking_inputs_class(requested_paths))
      resolver = Erx::PackProvenance.new(root: @root, catalog: catalog)
      begin
        resolver.resolve(receipt: receipt, artifact: path, build_kind: 'development')
      rescue Erx::Error
        nil
      end
      refute_includes requested_paths, File.realpath(path)
    end
  end

  def test_symlink_escape_and_private_state_are_not_read_or_hashed
    Dir.mktmpdir('outside-source-') do |outside|
      secret = File.join(outside, 'source.c')
      File.write(secret, "/* SPDX-License-Identifier: BSD-2-Clause */\n")
      link = File.join(@root, 'escaped.c')
      File.symlink(secret, link)
      File.write(@dependency, "root.o: escaped.c\n")
      @receipt.fetch('compiles').first['dependency'] = reference(@dependency)
      @receipt.fetch('compiles').first['sources'] = [{ 'path' => link, 'sha256' => Digest::SHA256.file(secret).hexdigest }]
      receipt = write('receipt.json', JSON.generate(@receipt))
      requested_paths = []
      catalog = build_catalog(inputs_class: tracking_inputs_class(requested_paths))
      resolver = Erx::PackProvenance.new(root: @root, catalog: catalog)
      assert_raises(Erx::Error) do
        resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development')
      end
      refute_includes requested_paths, File.realpath(secret)
      private_root = File.join(@root, '.git')
      Dir.mkdir(private_root)
      receipt = File.join(private_root, 'receipt.json')
      File.write(receipt, JSON.generate(@receipt))
      resolver = ReadTracking.new(root: @root, catalog: build_catalog)
      assert_raises(Erx::Error) do
        resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development')
      end
      refute_includes(resolver.opened_paths || [], File.realpath(receipt))
    end
  end

  def test_consumed_map_dependency_and_nested_receipt_bytes_match_their_hashes
    component = write('component.json', JSON.generate(@receipt))
    producer = write('producer.rb', "# SPDX-License-Identifier: BSD-2-Clause\n")
    original = Marshal.load(Marshal.dump(@receipt))
    [@map, @dependency, component].each do |path|
      before = File.binread(path)
      @receipt = if path == component
                   { 'version' => 1, 'kind' => 'assembled', 'artifact' => reference(@artifact),
                     'components' => [reference(component)], 'producer' => reference(producer) }
                 else
                   original
                 end
      @resolver = ChangedAfterCheck.new(root: @root, catalog: build_catalog)
      @resolver.replace_path = File.realpath(path)
      @resolver.replacement = before + "\n "
      assert_raises(Erx::Error) { resolve }
      File.binwrite(path, before)
    end
  end

  def test_notice_budget_is_checked_before_assembly
    records = resolve
    assert_raises(Erx::Error) { @resolver.notices(records, budget: 8) }
  end

  def test_external_notice_bytes_match_the_reviewed_digest
    notice = write('toolchain-license.txt', 'reviewed toolchain terms')
    external = { 'path' => @source, 'sha256' => Digest::SHA256.file(@source).hexdigest,
                 'license' => 'BSD-2-Clause', 'label' => 'toolchain/root.c',
                 'evidence' => 'reviewed terms', 'status' => 'permanent', 'notices' => [reference(notice)] }
    @resolver = ChangedAfterCheck.new(root: @root, catalog: build_catalog, external: [external])
    @resolver.replace_path = File.realpath(notice)
    @resolver.replacement = 'substituted terms'
    assert_raises(Erx::Error) { resolve }
  end

  def test_root_license_and_accumulated_notices_obey_admission_budget
    receipt = write('receipt.json', JSON.generate(@receipt))
    @resolver.instance_variable_set(:@catalog, build_catalog)
    assert_raises(Erx::Error) do
      @resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development', notice_budget: 8)
    end
    File.write(@source, "/* Extra source notice must be retained.\n * SPDX-License-Identifier: BSD-2-Clause\n */\nint start;\n")
    @receipt.fetch('compiles').first['sources'] = [reference(@source)]
    assert_includes @resolver.notices(resolve), 'Extra source notice must be retained.'
  end

  def test_innocently_named_project_secret_is_not_a_catalog_input
    directory = File.join(@root, 'config')
    Dir.mkdir(directory)
    secret = File.join(directory, 'local-values.yml')
    File.write(secret, "# SPDX-License-Identifier: BSD-2-Clause\n# private operator value\nkey: secret\n")
    File.write(@dependency, "root.o: config/local-values.yml\n")
    @receipt.fetch('compiles').first['dependency'] = reference(@dependency)
    @receipt.fetch('compiles').first['sources'] = [reference(secret)]
    @resolver = ReadTracking.new(root: @root, catalog: build_catalog)
    assert_raises(Erx::Error) { resolve }
    refute_includes(@resolver.opened_paths || [], File.realpath(secret))
  end

  def test_stale_artifact_object_source_dependency_and_map_are_refused
    [@artifact, @object, @source, @dependency, @map].each do |path|
      original = File.binread(path)
      File.binwrite(path, original + 'changed')
      assert_raises(Erx::Error) { resolve }
      File.binwrite(path, original)
    end
  end

  def test_dependencies_cannot_attribute_another_object
    File.write(@dependency, "other.o: root.c\n")
    @receipt.fetch('compiles').first['dependency'] = reference(@dependency)
    assert_raises(Erx::Error) { resolve }
  end

  def test_unknown_sources_and_missing_dependency_members_fail_closed
    File.write(@source, 'no copyright or licence')
    @receipt.fetch('compiles').first['sources'] = [reference(@source)]
    assert_raises(Erx::Error) { resolve }
    @receipt.fetch('compiles').first['sources'] = []
    assert_raises(Erx::Error) { resolve }
  end

  def test_unresolved_link_object_is_not_silently_ignored
    File.write(@map, "10000 10000 4 4 hidden.o:(.text)\n")
    @receipt['linker_map'] = reference(@map).merge('format' => 'lld', 'directory' => '.')
    error = assert_raises(Erx::Error) { resolve }
    assert_includes error.message, 'unresolved linked object'
  end

  def test_alternate_object_names_cannot_hide_linked_contributions
    ['hidden.obj', 'extensionless', 'odd.lib(member.obj)'].each do |name|
      File.write(@map, "10000 10000 4 4 root.o:(.text)\n10004 10004 4 4 #{name}:(.text)\n")
      @receipt['linker_map'] = reference(@map).merge('format' => 'lld', 'directory' => '.')
      assert_raises(Erx::Error) { resolve }
      gnu = "Linker script and memory map\n .text 0x10000 0x4 root.o\n .text 0x10004 0x4 #{name}\n"
      assert_equal ['root.o', name], Erx::PackProvenance.contributors(gnu, format: 'gnu')
    end
  end

  def test_dependency_escape_and_continuation_are_make_syntax
    targets, inputs = Erx::PackProvenance.dependencies("root\\ file.o: a\\ b.h \\\n c.h\n")
    assert_equal ['root file.o'], targets
    assert_equal ['a b.h', 'c.h'], inputs
    ["x: $(shell bad)", 'x: a#bad', "x: a\\", 'no target'].each do |bad|
      assert_raises(Erx::Error) { Erx::PackProvenance.dependencies(bad) }
    end
  end

  def test_gnu_discarded_contributions_do_not_enter_the_closure
    map = "Discarded input sections\n 0x0000 0x4 dead.o\nLinker script and memory map\n .text 0x10000 0x4 root.o\n"
    assert_equal ['root.o'], Erx::PackProvenance.contributors(map, format: 'gnu')
  end

  def test_gnu_linker_fill_is_not_a_file_contribution
    map = "Linker script and memory map\n .text 0x10000 0x4 root.o\n *fill* 0x00000000000058ec 0x14 00000000\n"
    assert_equal ['root.o'], Erx::PackProvenance.contributors(map, format: 'gnu')
  end

  def test_assembled_receipts_bind_components_and_producer
    component = write('linked.json', JSON.generate(@receipt))
    producer = write('assemble.rb', "# SPDX-License-Identifier: BSD-2-Clause\n")
    @receipt = { 'version' => 1, 'kind' => 'assembled', 'artifact' => reference(@artifact),
                 'components' => [reference(component)], 'producer' => reference(producer) }
    assert_equal %w[assemble.rb root.c], resolve.map { |record| record.fetch('path') }
    @receipt.fetch('components').first['sha256'] = '0' * 64
    assert_raises(Erx::Error) { resolve }
  end

  def test_repeated_receipt_children_are_checked_once
    child = write('leaf.json', JSON.generate(@receipt))
    producer = write('assemble.rb', "# SPDX-License-Identifier: BSD-2-Clause\n")
    14.times do |level|
      node = { 'version' => 1, 'kind' => 'assembled', 'artifact' => reference(@artifact),
               'components' => Array.new(64) { reference(child) }, 'producer' => reference(producer) }
      child = write("level-#{level}.json", JSON.generate(node))
    end
    resolver = BoundedVisits.new(root: @root, catalog: build_catalog)
    records = resolver.resolve(receipt: child, artifact: @artifact, build_kind: 'development')
    assert_equal %w[assemble.rb root.c], records.map { |record| record.fetch('path') }
  end
end
