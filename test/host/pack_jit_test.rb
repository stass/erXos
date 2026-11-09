# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/pack'

# The packer sets ERX_IMAGE_JIT on the images the build declares as making JIT objects
# and on no other (docs/design-kernel.md, "Image manifests"): an entry's `jit`, which
# only an image entry may carry, and the planner's flags never.
class PackJitTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  class KnownProvenance
    def resolve(**_arguments) = [].freeze
    def artifact_hash(path) = Digest::SHA256.file(path).hexdigest
  end

  # A fixed image's plan, as erx_elf_plan gives one for a task.ld link.
  class FixedPlan
    def initialize(codec) = @codec = codec

    def call(_path, budget:)
      raise Erx::Error, 'test fixture budget too small' if budget < 8192

      { 'abi_version' => 1, 'flags' => @codec.member('image_flags', 'fixed'), 'span' => 4096, 'fixed_base' => 0x40_0000,
        'entry' => 64, 'phdr_offset' => 0, 'phnum' => 1, 'base_alignment' => 4096, 'output_size' => 8192, 'loads' => [] }
    end
  end

  class << self
    attr_accessor :tools
  end

  def setup
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    @directory = File.realpath(Dir.mktmpdir('pack-jit-'))
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    self.class.tools ||= begin
      base = File.realpath(Dir.mktmpdir('pack-jit-tools-'))
      Minitest.after_run { FileUtils.remove_entry(base) }
      Erx::PackTools.build(root: ROOT, owner_root: base, directory: File.join(base, 'tools'),
                           runner: Erx::Runner.new(owner_root: base, log_dir: File.join(base, 'logs')))
    end
    @artifact = File.join(@directory, 'image.elf')
    File.binwrite(@artifact, 'x' * 64)
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_a_jit_image_entry_carries_the_mark_beside_the_planners_flags
    row = snapshot(entry(jit: true)).first
    flags = row.fetch('image').fetch('flags')
    assert flags.anybits?(@codec.member('image_flags', 'jit')), 'the declared BeamAsm image is marked'
    assert flags.anybits?(@codec.member('image_flags', 'fixed')), "the planner's fixed mark stays"
  end

  def test_an_image_entry_without_the_declaration_is_not_marked
    row = snapshot(entry).first
    refute row.fetch('image').fetch('flags').anybits?(@codec.member('image_flags', 'jit'))
  end

  def test_a_file_entry_cannot_declare_jit
    file = entry(jit: true).merge('kind' => @codec.member('entry_kind', 'file'))
    error = assert_raises(Erx::Error) { snapshot(file) }
    assert_includes error.message, 'only an image entry makes JIT objects'
  end

  # R10: the root task's image, which carries the system mark, is never marked for JIT.
  def test_the_system_image_cannot_declare_jit
    root = entry(jit: true).merge('flags' => @codec.member('entry_flags', 'system'))
    error = assert_raises(Erx::Error) { snapshot(root) }
    assert_includes error.message, "the system domain's image makes no JIT objects"
  end

  def test_jit_is_declared_only_as_true
    [false, 1, 'yes'].each do |value|
      error = assert_raises(Erx::Error) { snapshot(entry.merge('jit' => value)) }
      assert_includes error.message, 'invalid pack artifact fields'
    end
  end

  private

  def entry(jit: nil)
    { 'path' => 'runtimes/jit', 'kind' => @codec.member('entry_kind', 'image'), 'flags' => 0, 'artifact' => @artifact,
      'receipt' => 'unused', 'id' => 'jit-runtime', **(jit.nil? ? {} : { 'jit' => jit }) }
  end

  def snapshot(*entries)
    pack = Erx::Pack.new(root: ROOT, output_root: @directory, codec: @codec, planner: FixedPlan.new(@codec),
                         checker: self.class.tools.fetch('checker'), hasher: self.class.tools.fetch('hasher'),
                         runner: @runner, provenance: KnownProvenance.new)
    rows, _records = pack.send(:snapshot, entries, workspace: @directory, budget: 1 << 20, build_kind: 'development')
    rows
  end
end
