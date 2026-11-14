# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'pack_root'
require_relative 'manifest_context'
require_relative 'first_stage_fixture'
require_relative '../../tools/lib/erx/elf_plan'
require_relative '../../tools/lib/erx/pack_wire'
require_relative '../../tools/lib/erx/boot_file'
require_relative '../../tools/lib/erx/manifest'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/toolchain_provenance'

# Test-only, fixed native-root recipe. This produces a structural wire fixture,
# never boot admission. The executable, source closure and full archive receive
# their real checks; M1's root-startup and policy obligations remain unsupported.
module StructuralPackFixture
  # The native_domain image carries both ERTS images and a release, and the boot_image
  # suite's large image a filler that carries it past the native root's place.
  BUDGET = 128 * 1_048_576
  module_function

  # extra_files are further entries, { path:, snapshot: }, which the wire format
  # carries and the manifest's catalog binds like any other: file entries, or
  # image entries planned as the root's is when the file says image: true.
  def build(root:, directory:, codec:, runner:, tools:, compiler:, linker:, external:, extra_files: [], first_stage: nil)
    directory = Erx::OutputDirectory.prepare(root: root, path: directory)
    raise Erx::Error, 'structural fixture build requires a clean directory' unless Dir.empty?(directory)
    native = PackRootFixture.build(root: root, directory: File.join(directory, 'native'),
                                   codec: codec, runner: runner, compiler: compiler, linker: linker)
    planner = Erx::ElfPlanner.new(helper: tools.fetch('planner'), runner: runner, codec: codec)
    plan = planner.call(native.fetch('artifact'), budget: BUDGET)
    resolver = Erx::PackProvenance.new(root: root, catalog: native.fetch('catalog'), external: external, runner: runner)
    provenance = resolver.resolve(receipt: native.fetch('receipt'), artifact: native.fetch('artifact'),
                                  build_kind: 'development', notice_budget: BUDGET)
    writer = Erx::PackWire.new(codec: codec, hasher: Erx::PackHasher.new(helper: tools.fetch('hasher'), runner: runner))
    system = codec.member('entry_flags', 'system')
    ordinary = codec.member('entry_kind', 'file')
    rows = [
      { 'path' => 'system/NOTICES', 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'notices' } },
      { 'path' => codec.fixed_bytes('system_manifest_path'), 'kind' => ordinary, 'flags' => system,
        'source' => { 'kind' => 'generated', 'producer' => 'manifest' } },
      { 'path' => 'system/root', 'kind' => codec.member('entry_kind', 'image'), 'flags' => system,
        'source' => { 'kind' => 'artifact', 'id' => 'root',
                      'sha256' => Digest::SHA256.file(native.fetch('artifact')).hexdigest },
        'image' => writer.image_manifest(plan) }
    ]
    rows += extra_files.map { |file| extra_row(file, planner: planner, writer: writer, codec: codec) }
    rows = rows.sort_by { |row| row.fetch('path').b }
    root_entry = rows.index { |row| row.fetch('path') == 'system/root' }
    context = Erx::Manifest::Context.new(build_kind: 'development', platform: ManifestContextFixture.platform,
                                         catalog: rows.map { |row| row.reject { |key, _| %w[snapshot size plan].include?(key) } },
                                         root_entry: root_entry,
                                         artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root_entry } }.merge(ManifestContextFixture.images),
                                         provenance: provenance, uart_peripherals: ManifestContextFixture.uart_peripherals)
    source = File.binread(File.join(root, 'test/fixtures/manifest_empty.txt'))
    structural = Erx::Manifest.structural_fixture(source: source, codec: codec, context: context)
    unless structural.is_a?(Erx::Manifest::StructuralFixture) && !structural.is_a?(Erx::Manifest::Admitted) && structural.matches?(context)
      raise Erx::Error, 'structural fixture is not bound to its exact catalog'
    end
    manifest_path = File.join(directory, 'manifest.bin')
    notices_path = File.join(directory, 'NOTICES')
    File.binwrite(manifest_path, structural.bytes)
    File.binwrite(notices_path, resolver.notices(provenance, budget: BUDGET))
    rows = rows.map do |row|
      if row.key?('snapshot')
        row
      elsif row.fetch('kind') == codec.member('entry_kind', 'image')
        row.merge('snapshot' => native.fetch('artifact'), 'size' => plan.fetch('output_size'), 'plan' => plan)
      else
        snapshot = row.fetch('source').fetch('producer') == 'manifest' ? manifest_path : notices_path
        row.merge('snapshot' => snapshot, 'size' => File.size(snapshot))
      end
    end
    output_path = File.join(directory, 'structural.erxpack')
    File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
      writer.write(rows: rows, root_entry: root_entry, build_kind: 'development', output: output, budget: BUDGET)
      output.flush
      output.fsync
    end
    checked = tools.fetch('checker').run([output_path], runner: runner, name: 'check-structural-pack', deadline: 30)
    unless File.binread(checked.fetch('log')) == "ok #{rows.size}\n"
      raise Erx::Error, 'structural checker did not report the expected entry count'
    end
    first_stage_path = File.join(directory, 'first-stage')
    single_path = File.join(directory, 'structural.boot')
    File.binwrite(first_stage_path, first_stage ? File.binread(first_stage) : FirstStageFixture.bytes)
    Erx::BootFile.write(codec: codec, first_stage: first_stage_path, archive: output_path, output: single_path, output_root: root)
    report = { 'kind' => 'structural_test_fixture', 'path' => output_path, 'single_path' => single_path,
               'single_sha256' => Digest::SHA256.file(single_path).hexdigest,
               'sha256' => Digest::SHA256.file(output_path).hexdigest, 'size' => File.size(output_path),
               'structure' => 'validated', 'executable' => 'validated', 'provenance' => 'validated',
               'root_startup' => 'unsupported', 'policy_admission' => 'unsupported',
               'child_plan_instances' => 0, 'entries' => rows.size,
               'manifest_sha256' => Digest::SHA256.hexdigest(structural.bytes),
               'configuration_sha256' => Digest::SHA256.hexdigest(source),
               'manifest' => structural.report }
    File.write(File.join(directory, 'fixture-result.json'), JSON.pretty_generate(report) + "\n")
    { 'report' => report.freeze, 'context' => context, 'manifest_source' => source.freeze,
      'native' => native, 'provenance' => provenance, 'rows' => rows.freeze }.freeze
  end

  def extra_row(file, planner:, writer:, codec:)
    snapshot = file.fetch(:snapshot)
    row = { 'path' => file.fetch(:path), 'kind' => codec.member('entry_kind', 'file'), 'flags' => 0, 'snapshot' => snapshot,
            'size' => File.size(snapshot),
            'source' => { 'kind' => 'artifact', 'id' => file.fetch(:path), 'sha256' => Digest::SHA256.file(snapshot).hexdigest } }
    return row unless file.fetch(:image, false)

    # As Pack#image_manifest does, the JIT mark goes into the manifest only; the plan stays the planner's.
    plan = planner.call(snapshot, budget: BUDGET)
    jit = file.fetch(:jit, false) ? codec.member('image_flags', 'jit') : 0
    manifest = writer.image_manifest(plan.merge('flags' => plan.fetch('flags') | jit))
    row.merge('kind' => codec.member('entry_kind', 'image'), 'size' => plan.fetch('output_size'), 'plan' => plan,
              'image' => manifest)
  end
end
