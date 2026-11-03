# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/pack'

class PackResourceTest < Minitest::Test
  class KnownProvenance
    def resolve(**_arguments)
      [].freeze
    end

    def artifact_hash(path)
      Digest::SHA256.file(path).hexdigest
    end
  end

  # The planner has already checked these tiny LOADs. Their original ELF files
  # also contain large unused sections, which still consume staging space.
  class TinyLoads
    def call(_path, budget:)
      raise Erx::Error, 'test fixture budget too small' if budget < 8192
      { 'abi_version' => 1, 'flags' => 0, 'span' => 4096, 'fixed_base' => 0, 'entry' => 64,
        'phdr_offset' => 0, 'phnum' => 1, 'base_alignment' => 4096,
        'output_size' => 8192, 'loads' => [] }
    end
  end

  def test_original_source_snapshots_share_one_staging_budget
    root = File.expand_path('../..', __dir__)
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: root).schema)
    Dir.mktmpdir('pack-resource-') do |directory|
      artifact = File.join(directory, 'large-unused.elf')
      File.binwrite(artifact, 'x' * 16_000)
      entries = 3.times.map do |index|
        { 'path' => "root#{index}", 'kind' => codec.member('entry_kind', 'image'),
          'flags' => 0, 'artifact' => artifact, 'receipt' => 'unused', 'id' => "image#{index}" }
      end
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      tools = Erx::PackTools.build(root: root, owner_root: directory,
                                   directory: File.join(directory, 'tools'), runner: runner)
      pack = Erx::Pack.new(root: root, output_root: directory, codec: codec, planner: TinyLoads.new,
                           checker: tools.fetch('checker'), hasher: tools.fetch('hasher'), runner: runner,
                           provenance: KnownProvenance.new)
      assert_raises(Erx::Error) do
        pack.send(:snapshot, entries, workspace: directory, budget: 32_768, build_kind: 'development')
      end
    end
  end
end
