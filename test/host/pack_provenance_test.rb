# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/pack_provenance'
require_relative '../../tools/lib/erx/serving_set'
require_relative '../fixtures/link_inputs'

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
    File.write(@inputs, LinkInputsFixture.text('root.a(root.o)'))
    @receipt['linker_inputs'] = reference(@inputs).merge('directory' => '.')
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
    image = write('build/fiasco/images/bootstrap.raw', 'Fiasco image')
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

  def test_a_fiasco_gpl_source_outside_the_closed_table_is_refused
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
    %w[development release].each do |kind|
      error = assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: image, build_kind: kind) }
      assert_match(/no permitted grant/, error.message, kind)
    end
  end

  LLD_MERGED = File.expand_path('../fixtures/lld_merged', __dir__)

  # merged.trace and merged.map come from one LLD 23.1.3 link of the sources beside them:
  #   clang --target=aarch64-none-elf -c {a,b,c}.s && llvm-ar rc lib.a c.o
  #   ld.lld --gc-sections --trace -Map merged.map a.o b.o lib.a -o merged.elf > merged.trace
  # b.o holds only a merged string, so its bytes sit in a section LLD made: the map shows
  # them as <internal> and never names b.o, while --trace names every input LLD loaded.
  def test_link_inputs_name_an_input_whose_only_bytes_were_merged
    refute_includes File.read(File.join(LLD_MERGED, 'merged.map')), 'b.o'
    assert_equal ['a.o', 'b.o', 'lib.a(c.o)'],
                 Erx::PackProvenance.link_inputs(File.binread(File.join(LLD_MERGED, 'merged.trace'))).map(&:to_s)
  end

  # The audit follows each input of that link to its sources: b.c, whose only output is
  # the merged string, among them.
  def test_a_traced_link_attributes_the_sources_of_every_loaded_input
    compiles = %w[a b c].map do |name|
      source = write("#{name}.c", "/* SPDX-License-Identifier: BSD-2-Clause */\nint #{name};\n")
      { 'object' => reference(write("#{name}.o", "#{name} object bytes")),
        'dependency' => reference(write("#{name}.d", "#{name}.o: #{name}.c\n")),
        'directory' => '.', 'sources' => [reference(source)] }
    end
    member = File.join(@root, 'c.o')
    listing = write('archive-members.txt', "c.o\n")
    runner = Object.new
    runner.define_singleton_method(:run) { |argv, **_options| { 'log' => argv[1] == 't' ? listing : member } }
    @resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, runner: runner)
    File.binwrite(@inputs, File.binread(File.join(LLD_MERGED, 'merged.trace')))
    @receipt.merge!('linker_inputs' => reference(@inputs).merge('directory' => '.'), 'compiles' => compiles,
                    'archives' => [reference(write('lib.a', "!<arch>\nlib")).merge('members' => [
                      { 'name' => 'c.o', 'sha256' => reference(member).fetch('sha256'), 'object_path' => 'c.o' }
                    ])])
    assert_equal %w[a.c b.c c.c], resolve.map { |record| record.fetch('path') }.sort
  end

  # The list is whole or refused: a cut leaves no final newline, and a line that is not
  # one input name (empty, with a space as a map row has, or with parentheses that are
  # not one archive member, or a leading ~ that path expansion would take for a home
  # directory) is refused, as is a list naming nothing or past the bound.
  def test_a_cut_or_malformed_link_input_list_is_refused
    list = LinkInputsFixture.text('root.o', 'lib.a(member.o)')
    assert_equal [Erx::PackProvenance::LinkInput.new(file: 'root.o', member: nil),
                  Erx::PackProvenance::LinkInput.new(file: 'lib.a', member: 'member.o')],
                 Erx::PackProvenance.link_inputs(list)
    { list.chomp => /does not end with a newline/,
      list[0, list.index('member')] => /does not end with a newline/,
      '' => /does not end with a newline/,
      "#{list}\n" => /not an input name/,
      "#{list}210128 210128 10 4 root.o:(.text)\n" => /not an input name/,
      "#{list}root\to\n" => /not an input name/,
      "#{list}lib.a(member.o\n" => /not an input name/,
      "#{list}lib.a(a)(b)\n" => /not an input name/,
      "#{list}(member.o)\n" => /not an input name/,
      "#{list}~/root.o\n" => /not an input name/,
      "#{list}r\xC3\xB6ot.o\n".b => /not an input name/,
      "x\n" * ((Erx::PackProvenance::MAX_METADATA / 2) + 1) => /too large/ }.each do |bytes, message|
      error = assert_raises(Erx::Error, bytes[0, 80].inspect) { Erx::PackProvenance.link_inputs(bytes) }
      assert_match message, error.message, bytes[0, 80].inspect
    end
  end

  # A map's input-section shape, file:(section), is a well-formed name of an archive
  # member, so the list admits it; no file of that name exists, so the audit refuses it.
  def test_a_map_row_name_in_the_list_is_unresolved
    File.write(@inputs, LinkInputsFixture.text('root.o', 'root.o:(.text)'))
    @receipt['linker_inputs'] = reference(@inputs).merge('directory' => '.')
    error = assert_raises(Erx::Error) { resolve }
    assert_match %r{No such file or directory.*/root\.o:\z}, error.message
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
    File.write(File.join(@root, 'LICENSE'), 'project BSD license text')
    @source = write('root.c', "/* SPDX-License-Identifier: BSD-2-Clause */\nint start;\n")
    @object = write('root.o', 'object bytes')
    @artifact = write('root.elf', 'linked bytes')
    @dependency = write('root.d', "root.o: root.c\n")
    @inputs = write('root.inputs', LinkInputsFixture.text('root.o'))
    @receipt = { 'version' => 1, 'kind' => 'linked', 'artifact' => reference(@artifact),
                 'linker_inputs' => reference(@inputs).merge('directory' => '.'),
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

  # A file a compiler made from sources alone: its record is the sources it names.
  def resolve_compiled(receipt_fields)
    receipt = write('compiled.json', JSON.generate({ 'version' => 1, 'kind' => 'compiled', 'artifact' => reference(@artifact) }.merge(receipt_fields)))
    @resolver.instance_variable_set(:@catalog, build_catalog)
    @resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'development')
  end

  def test_a_compiled_receipt_attributes_its_sources
    records = resolve_compiled('sources' => [reference(@source)])
    assert_equal ['root.c'], records.map { |record| record.fetch('path') }
    assert_equal 'BSD-2-Clause', records.first.fetch('license')
  end

  # The serving module's source is written by a runtime build, whose OTP copy holds the
  # imported tree's ORIGIN.md as the copy makes it: the receipt of the beam compiled from
  # it still resolves, as a generated source, since the source is not under that copy.
  def test_a_compiled_receipt_attributes_the_derived_serving_source_of_an_otp_copy
    copy = File.join(@root, 'build/runtime/hosted/otp')
    FileUtils.mkdir_p(copy)
    File.write(File.join(copy, 'ORIGIN.md'), "# origin\n")
    source = Erx::ServingSet.source(otp: copy)
    FileUtils.mkdir_p(File.dirname(source))
    @produced << source
    File.write(source, "%% SPDX-License-Identifier: BSD-2-Clause\n-module(erx_ramfs_serving).\n")
    records = resolve_compiled('sources' => [reference(source)])
    assert_equal 'BSD-2-Clause', records.first.fetch('license')
  end

  def test_a_compiled_receipt_needs_a_source_it_can_verify
    assert_raises(Erx::Error) { resolve_compiled('sources' => []) }
    assert_raises(Erx::Error) { resolve_compiled('sources' => [reference(@source).merge('sha256' => '0' * 64)]) }
    assert_raises(Erx::Error) { resolve_compiled('sources' => [reference(@source)], 'extra' => 1) }
  end

  def test_actual_object_closure_has_stable_names_and_notices
    records = resolve
    assert_equal ['root.c'], records.map { |record| record.fetch('path') }
    assert_equal 'BSD-2-Clause', records.first.fetch('license')
    assert_includes @resolver.notices(records), 'project BSD license text'
    refute_includes JSON.generate(records), @root
  end

  # Many files under one license: NOTICES carries the license document once, each
  # distinct file notice once, and every file's name, as a FreeBSD or Debian
  # copyright file does.
  def test_notices_give_each_text_once_with_the_files_it_covers
    headers = { 'a.c' => 'Copyright (c) 2026, First Author', 'b.c' => 'Copyright (c) 2026, First Author',
                'c.c' => 'Copyright (c) 2025, Second Author' }
    sources = headers.map do |name, line|
      reference(write(name, "/* #{line}\n * SPDX-License-Identifier: BSD-2-Clause */\nint #{name[0]};\n"))
    end
    text = @resolver.notices(resolve_compiled('sources' => sources))
    assert_equal 1, text.scan('project BSD license text').size
    assert_equal 1, text.scan('First Author').size
    assert_equal 1, text.scan('Second Author').size
    assert_includes text, "Files:\n  a.c\n  b.c\nLicense: BSD-2-Clause\nEvidence: file SPDX\nDocuments: LICENSE\n" \
                          "/* Copyright (c) 2026, First Author\n"
    assert_includes text, "Files:\n  c.c\nLicense: BSD-2-Clause\nEvidence: file SPDX\nDocuments: LICENSE\n" \
                          "/* Copyright (c) 2025, Second Author\n"
  end

  # A pack resolves each of its entries in turn and renders NOTICES from all of
  # their records, so a document only an earlier entry cites is still printed.
  def test_notices_cover_every_resolve_of_a_pack
    blob = write('blob.bin', 'external bytes')
    notice = write('blob-NOTICE', 'external MIT text')
    external = { 'path' => blob, 'sha256' => Digest::SHA256.file(blob).hexdigest, 'license' => 'MIT',
                 'label' => 'ext/blob.bin', 'evidence' => 'reviewed registry', 'status' => 'permanent',
                 'notices' => [reference(notice)] }
    @resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: [external])
    first = resolve_compiled('sources' => [reference(@source)])
    second = resolve_compiled('sources' => [reference(blob)])
    text = @resolver.notices((first + second).sort_by { |record| record.fetch('path').b })
    assert_includes text, 'project BSD license text'
    assert_includes text, 'external MIT text'
  end

  # A release pack admits an external archive's OFL-1.1 only when the archive states that content is
  # font data, and an archive whose OFL-1.1 is not font data stays refused.
  def resolve_external_release(license, font_data:)
    blob = write('fonts.a', 'archive bytes')
    notice = write('fonts-NOTICE', 'font notice text')
    external = { 'path' => blob, 'sha256' => Digest::SHA256.file(blob).hexdigest, 'license' => license,
                 'label' => 'ext/fonts.a', 'evidence' => 'reviewed registry', 'status' => 'stopgap',
                 'notices' => [reference(notice)] }
    external['font_data'] = font_data unless font_data.nil?
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: [external])
    receipt = write('compiled.json', JSON.generate({ 'version' => 1, 'kind' => 'compiled', 'artifact' => reference(@artifact),
                                                     'sources' => [reference(blob)] }))
    resolver.instance_variable_set(:@catalog, build_catalog)
    resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release')
  end

  # A package an image takes (ImageApps) is attributed whole under the license its header
  # declares, judged as an archive's but always as permanent, so a development build that
  # accepts a release component's restricted license still refuses a package's, and a package that
  # names no license.
  def resolve_package(license, status: 'permanent', build_kind: 'development')
    package = write('clock.app', 'package bytes')
    external = { 'path' => package, 'sha256' => Digest::SHA256.file(package).hexdigest, 'license' => license,
                 'label' => 'apps/clock.app', 'evidence' => 'package header', 'status' => status, 'notices' => [] }
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: [external])
    receipt = write('package.json', JSON.generate('version' => 1, 'kind' => 'package', 'artifact' => reference(package)))
    resolver.instance_variable_set(:@catalog, build_catalog)
    resolver.resolve(receipt: receipt, artifact: package, build_kind: build_kind)
  end

  def test_a_package_enters_only_under_a_permissive_license
    record = resolve_package('BSD-2-Clause').first
    assert_equal %w[apps/clock.app BSD-2-Clause permanent], record.values_at('path', 'license', 'status')
    { 'GPL-2.0-only' => /no permitted grant/, 'NOASSERTION' => /unresolved source license/ }.each do |license, reason|
      error = assert_raises(Erx::Error) { resolve_package(license) }
      assert_match(%r{\Athe package apps/clock\.app cannot enter the image: }, error.message)
      assert_match(reason, error.message)
    end
    error = assert_raises(Erx::Error) { resolve_package('GPL-2.0-only', status: 'stopgap') }
    assert_match(/a package receipt names a package registered as neither permanent nor package-local/, error.message)
  end

  # A local test image registers a package that is not permissive as package-local, which a
  # development build accepts under its license and a release build refuses.
  def test_a_package_local_enters_only_a_development_build
    record = resolve_package('GPL-2.0-only', status: 'package-local').first
    assert_equal %w[apps/clock.app GPL-2.0-only package-local], record.values_at('path', 'license', 'status')
    error = assert_raises(Erx::Error) { resolve_package('GPL-2.0-only', status: 'package-local', build_kind: 'release') }
    assert_match(/no permitted grant/, error.message)
  end

  def test_release_admits_ofl_for_font_data_and_refuses_it_otherwise
    record = resolve_external_release('MIT AND OFL-1.1', font_data: true).first
    assert_equal '(MIT AND OFL-1.1)', record.fetch('license')
    [nil, false].each do |statement|
      error = assert_raises(Erx::Error) { resolve_external_release('MIT AND OFL-1.1', font_data: statement) }
      assert_match(/no permitted grant/, error.message)
    end
    error = assert_raises(Erx::Error) { resolve_external_release('MIT AND GPL-2.0-only', font_data: true) }
    assert_match(/no permitted grant/, error.message)
    error = assert_raises(Erx::Error) { resolve_external_release('MIT AND OFL-1.1', font_data: 'yes') }
    assert_match(/invalid font data/, error.message)
  end

  ADDITION = "/* Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
             " * SPDX-License-Identifier: BSD-2-Clause */\nint added;\n"

  # Resolves a release link record whose one source is a file in `vendor`, an
  # imported tree under MIT, and returns the records. The source is an addition
  # the tree's check saw, or, given `captured_after_check`, a file written after
  # that check, which the catalog holds without the check having read it.
  def resolve_vendor_source(captured_after_check: nil, imports: { 'vendor' => 'permanent' })
    FileUtils.mkdir_p(File.join(@root, 'vendor'))
    write('vendor/upstream.c', "/* SPDX-License-Identifier: MIT */\nint upstream;\n")
    Erx::Origin.new(root: File.join(@root, 'vendor')).write(repository: 'https://example.invalid/vendor',
      revision: 'fixture', archive_sha256: 'a' * 64,
      review: { 'rules' => [], 'default_license' => 'MIT', 'default_evidence' => 'fixture' })
    added = write('vendor/added.c', ADDITION)
    checked = Erx::BuildInputs.imported(root: File.join(@root, 'vendor'))
    source = captured_after_check ? write('vendor/late.c', captured_after_check) : added
    write('root.d', "root.o: #{source.delete_prefix(@root + '/')}\n")
    @receipt.fetch('compiles').first['sources'] = [reference(source)]
    @receipt.fetch('compiles').first['dependency'] = reference(File.join(@root, 'root.d'))
    receipt = write('receipt.json', JSON.generate(@receipt))
    @resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog.merge(checked), imports: imports)
    @resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release')
  end

  def test_file_erxos_added_to_an_import_is_attributed_as_erxos_code
    records = resolve_vendor_source
    record = records.first
    assert_equal 'vendor/added.c', record.fetch('path')
    assert_equal 'BSD-2-Clause', record.fetch('license')
    assert_equal 'BSD-2-Clause', record.fetch('declared_license')
    assert_equal 'file SPDX', record.fetch('evidence')
    assert_includes record.fetch('notice'), 'SPDX-License-Identifier: BSD-2-Clause'
    assert_includes @resolver.notices(records), 'project BSD license text'
    assert_equal ['LICENSE'], record.fetch('notice_documents').map { |document| document.fetch('path') }
  end

  def test_addition_takes_the_status_of_the_tree_it_lives_in
    assert_equal 'stopgap', resolve_vendor_source(imports: { 'vendor' => 'stopgap' }).first.fetch('status')
  end

  def test_file_captured_after_the_check_with_no_notice_has_no_attribution
    error = assert_raises(Erx::Error) { resolve_vendor_source(captured_after_check: "int late;\n") }
    assert_match(/unresolved imported input: vendor\/late\.c/, error.message)
  end

  def test_file_captured_after_the_check_declaring_another_license_has_no_attribution
    bytes = "// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
            "// SPDX-License-Identifier: BSD-2-Clause AND GPL-2.0-only\n"
    error = assert_raises(Erx::Error) { resolve_vendor_source(captured_after_check: bytes) }
    assert_match(/unresolved imported input: vendor\/late\.c/, error.message)
  end

  def test_addition_in_an_unregistered_import_is_refused
    error = assert_raises(Erx::Error) { resolve_vendor_source(imports: {}) }
    assert_match(/unregistered imported dependency: vendor\/added\.c/, error.message)
  end

  # A submodule's ORIGIN.md sits beside it (Origin::SUBMODULES), so the directory
  # holding both is no import root: erXos's file there is its own code, and only a
  # file inside the submodule belongs to the import, which this resolver was not
  # given.
  def test_the_directory_holding_a_submodule_is_erxos_code
    submodule = Erx::Origin::SUBMODULES.first
    holder = File.dirname(submodule)
    FileUtils.mkdir_p(File.join(@root, submodule))
    write("#{holder}/ORIGIN.md", "# Source origin\n\nprose, no inventory\n")
    own = write("#{holder}/own.c", "/* SPDX-License-Identifier: BSD-2-Clause */\nint own;\n")
    record = resolve_compiled('sources' => [reference(own)]).first
    assert_equal ["#{holder}/own.c", 'BSD-2-Clause', 'permanent'], record.values_at('path', 'license', 'status')
    upstream = write("#{submodule}/upstream.c", "int upstream;\n")
    error = assert_raises(Erx::Error) { resolve_compiled('sources' => [reference(upstream)]) }
    assert_match(%r{unregistered imported dependency: #{submodule}/upstream\.c}, error.message)
  end

  def test_permissive_license_alternative_is_selected_instead_of_requiring_both
    File.write(@source, "/* SPDX-License-Identifier: BSD-3-Clause OR GPL-2.0-only */\nint start;\n")
    @receipt.fetch('compiles').first['sources'] = [reference(@source)]
    record = resolve.first
    assert_equal 'BSD-3-Clause', record.fetch('license')
    assert_equal 'BSD-3-Clause OR GPL-2.0-only', record.fetch('declared_license')
  end

  def test_permissive_release_component_is_allowed_in_release_provenance
    external = [{ 'path' => @source, 'sha256' => Digest::SHA256.file(@source).hexdigest,
                  'label' => 'third_party/fixture/root.c', 'license' => 'MIT',
                  'status' => 'release', 'evidence' => 'reviewed permissive fixture',
                  'notices' => [{ 'path' => File.join(@root, 'LICENSE'),
                                  'sha256' => Digest::SHA256.file(File.join(@root, 'LICENSE')).hexdigest }] }]
    receipt = write('receipt.json', JSON.generate(@receipt))
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: external)
    records = resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release')
    assert_equal %w[release MIT], records.first.values_at('status', 'license')
    external.first['status'] = 'tools'
    resolver = Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: external)
    error = assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: 'release') }
    assert_match(/invalid dependency provenance status/, error.message)
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
    %w[release development].each do |kind|
      assert_raises(Erx::Error) { resolver.resolve(receipt: receipt, artifact: @artifact, build_kind: kind) }
    end
  end

  # The Doom example's archive, attributed whole under the label the image build gives it, as
  # the one input of an image registered as example, at the path the image build writes it
  # (EXAMPLE_ARCHIVE) unless at names another.
  def resolve_example(license:, label: Erx::PackProvenance::EXAMPLE_LABEL, status: 'example', build_kind: 'development',
                      at: Erx::PackProvenance::EXAMPLE_ARCHIVE)
    resolve_registered_at(at, license: license, label: label, status: status, build_kind: build_kind)
  end

  # Resolves the fixture's source copied to at, a path relative to the tree or an absolute
  # one outside it, as the one input the receipt compiles, registered as an external file
  # under label, license and status.
  def resolve_registered_at(at, license:, label:, status:, build_kind: 'development')
    input = File.expand_path(at, @root)
    FileUtils.mkdir_p(File.dirname(input))
    if input.start_with?(@root + '/')
      write(at, File.binread(@source))
    else
      File.binwrite(input, File.binread(@source))
    end
    @receipt['compiles'] = [@receipt.fetch('compiles').first.merge('sources' => [reference(input)],
                                                                    'dependency' => reference(write('root.d', "root.o: #{at}\n")))]
    resolve_registered(license: license, label: label, status: status, build_kind: build_kind, path: input)
  end

  # Resolves the fixture's one input, the file at path (the fixture's source unless path
  # names another the receipt compiles), registered as an external file under label,
  # license and status.
  def resolve_registered(license:, label:, status:, build_kind: 'development', path: @source)
    external = [{ 'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest,
                  'label' => label, 'license' => license, 'status' => status, 'evidence' => 'registered fixture',
                  'notices' => [{ 'path' => File.join(@root, 'LICENSE'),
                                  'sha256' => Digest::SHA256.file(File.join(@root, 'LICENSE')).hexdigest }] }]
    receipt = write('receipt.json', JSON.generate(@receipt))
    Erx::PackProvenance.new(root: @root, catalog: build_catalog, external: external)
                       .resolve(receipt: receipt, artifact: @artifact, build_kind: build_kind)
  end

  # The example status admits GPL-2.0 only for the Doom example's archive, in a development
  # build: the same GPL bytes under another label, at another path or as permanent, another
  # restricted license under the example's label, and a release build are refused.
  def test_only_the_example_archive_enters_under_gpl_2
    record = resolve_example(license: 'GPL-2.0-or-later AND BSD-3-Clause').first
    assert_equal ['GPL-2.0-or-later AND BSD-3-Clause', 'example'], record.values_at('declared_license', 'status')
    refusals = { { label: 'third_party/fixture/root.c' } => /registered as example/,
                 { at: 'build/other/libdoom.a' } => /registered as example/,
                 { license: 'GPL-3.0-or-later' } => /registered as example/,
                 { license: 'GPL-2.0-only' } => /registered as example/,
                 { status: 'permanent' } => /no permitted grant/,
                 { build_kind: 'release' } => /no permitted grant/ }
    refusals.each do |change, reason|
      error = assert_raises(Erx::Error) { resolve_example(license: 'GPL-2.0-or-later AND BSD-3-Clause', **change) }
      assert_match(reason, error.message, change.inspect)
    end
  end

  def gcc_header(outside, name) = File.join(outside, 'lib/gcc/aarch64-elf/16.2.0/include', name)

  # Seeded fault: a build accepts a license that is not permissive only from
  # LicenseCheck::TABLE, so a GPL input that the table does not name is refused in
  # every build kind, as is GCC's exception on any file: a header of a GCC include directory, a clang resource header, or a GCC runtime file of l4re-core
  # such as an old build linked.
  def test_a_gpl_input_outside_the_closed_table_is_refused
    Dir.mktmpdir('outside-toolchain-') do |outside|
      gcc = 'GPL-3.0-or-later WITH GCC-exception-3.1'
      refusals = [{ license: 'GPL-2.0-only', label: 'third_party/fixture/root.c', at: 'root.c' },
                  { license: 'GPL-2.0-only', label: 'fiasco/kernel/src/kern/fixture.cpp',
                    at: 'build/fiasco/inputs/fiasco/kernel/src/kern/fixture.cpp' },
                  { license: 'GPL-3.0-or-later', label: 'toolchain/gcc-16.2.0/stdarg.h', at: gcc_header(outside, 'stdarg.h') },
                  { license: gcc, label: 'toolchain/gcc-16.2.0/stdarg.h', at: gcc_header(outside, 'stdarg.h') },
                  { license: gcc, label: 'toolchain/llvm/include/stdarg.h',
                    at: File.join(outside, 'lib/clang/21/include/stdarg.h') },
                  { license: gcc, label: 'fiasco/l4re-core/libgcc/contrib/gcc-16/libgcc/crtstuff.c',
                    at: 'build/fiasco/inputs/fiasco/l4re-core/libgcc/contrib/gcc-16/libgcc/crtstuff.c' }]
      refusals.product(%w[development release]).each do |input, kind|
        error = assert_raises(Erx::Error) do
          resolve_registered_at(input.fetch(:at), build_kind: kind, **{ status: 'release' }.merge(input.except(:at)))
        end
        assert_match(/no permitted grant/, error.message, [input, kind].inspect)
      end
    end
  end

  # The FSF All Permissive License is permissive: l4re-core's ldscripts/kip_addr.S, which
  # sigma0 links, another file under it and a permanent dependency under it enter every
  # build kind, as no row of the table names them.
  def test_the_fsf_all_permissive_license_enters_every_build
    inputs = [{ label: 'fiasco/l4re-core/ldscripts/kip_addr.S', status: 'release',
                at: 'build/fiasco/inputs/fiasco/l4re-core/ldscripts/kip_addr.S' },
              { label: 'fiasco/l4re-core/ldscripts/other.S', status: 'release',
                at: 'build/fiasco/inputs/fiasco/l4re-core/ldscripts/other.S' },
              { label: 'third_party/fixture/root.c', status: 'permanent', at: 'root.c' }]
    inputs.product(%w[development release]).each do |input, kind|
      record = resolve_registered_at(input.fetch(:at), license: 'FSFAP', build_kind: kind, **input.slice(:label, :status)).first
      assert_equal [input.fetch(:label), 'FSFAP'], record.values_at('path', 'license'), [input, kind].inspect
    end
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

  def test_consumed_input_list_dependency_and_nested_receipt_bytes_match_their_hashes
    component = write('component.json', JSON.generate(@receipt))
    producer = write('producer.rb', "# SPDX-License-Identifier: BSD-2-Clause\n")
    original = Marshal.load(Marshal.dump(@receipt))
    [@inputs, @dependency, component].each do |path|
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

  # stdlib's edlin_expand_SUITE_data holds visible<U+1F600>_file: a UTF-8 path
  # label goes into the same notice as binary notice bytes.
  def test_notices_join_a_non_ascii_path_with_binary_notice_bytes
    record = { 'path' => "data/visible\u{1F600}_file", 'license' => 'MIT', 'evidence' => 'file SPDX',
               'notice' => "\xC2\xA9 Example".b, 'notice_documents' => [] }
    text = @resolver.notices([record])
    assert_includes text, "data/visible\u{1F600}_file".b
    assert_includes text, "\xC2\xA9 Example".b
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

  def test_root_license_and_accumulated_notices_obey_the_check_budget
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

  def test_stale_artifact_object_source_dependency_and_input_list_are_refused
    [@artifact, @object, @source, @dependency, @inputs].each do |path|
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
    File.write(@source, 'no copyright or license')
    @receipt.fetch('compiles').first['sources'] = [reference(@source)]
    assert_raises(Erx::Error) { resolve }
    @receipt.fetch('compiles').first['sources'] = []
    assert_raises(Erx::Error) { resolve }
  end

  def test_unresolved_link_object_is_not_silently_ignored
    File.write(@inputs, LinkInputsFixture.text('hidden.o'))
    @receipt['linker_inputs'] = reference(@inputs).merge('directory' => '.')
    error = assert_raises(Erx::Error) { resolve }
    assert_includes error.message, 'unresolved linked object'
  end

  def test_alternate_object_names_cannot_hide_linked_contributions
    ['hidden.obj', 'extensionless', 'odd.lib(member.obj)'].each do |name|
      File.write(@inputs, LinkInputsFixture.text('root.o', name))
      @receipt['linker_inputs'] = reference(@inputs).merge('directory' => '.')
      assert_equal ['root.o', name], Erx::PackProvenance.link_inputs(File.binread(@inputs)).map(&:to_s)
      assert_raises(Erx::Error) { resolve }
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
