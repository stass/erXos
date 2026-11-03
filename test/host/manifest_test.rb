# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

class ManifestTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: @root))
    @codec = Erx::ABI::Codec.new(schema)
    @source = File.binread(File.join(@root, 'test/fixtures/manifest_empty.txt'))
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec))
  end

  def fixture(source = @source, context = @context)
    Erx::Manifest.structural_fixture(source: source, codec: @codec, context: context)
  end

  def test_empty_native_configuration_has_no_planning_or_dynamic_reservation
    result = fixture
    assert_instance_of Erx::Manifest::StructuralFixture, result
    assert result.matches?(@context)
    assert result.bytes.frozen?
    assert_equal 0, result.report.fetch('child_plan_instances')
    assert_equal 0, result.report.fetch('dynamic_domain_reservation')
    assert_equal 'unsupported', result.report.fetch('root_startup')
    assert_equal 'unsupported', result.report.fetch('policy_admission')
    view = @codec.open('manifest', result.bytes)
    assert_equal 0, view.count('domains')
    assert_equal 0, view.count('partial_boot')
    assert_equal 1, view.count('devices')
  end

  def test_equivalent_source_order_has_identical_bytes
    changed = @source.sub("  max_domains 4\n  max_connections 4", "  max_connections 4\n  max_domains 4")
    assert_equal fixture.bytes, fixture(changed).bytes
  end

  def test_string_references_follow_record_field_order
    view = @codec.open('manifest', fixture.bytes)
    device = view.fetch('devices', 0)
    assert_operator device.fetch('path').fetch('offset'), :<, device.fetch('compatible').fetch('offset')
  end

  def test_catalog_change_invalidates_fixture_binding
    arguments = ManifestContextFixture.arguments(@codec)
    arguments.fetch(:catalog).last.fetch('source')['sha256'] = 'b' * 64
    other = Erx::Manifest::Context.new(**arguments)
    refute fixture.matches?(other)
  end

  def test_notice_binding_accepts_original_non_utf8_bytes_without_exposing_them
    record = @context.provenance.first
    refute record.key?('notice')
    assert_match(/\A[0-9a-f]{64}\z/, record.fetch('notice_sha256'))
  end

  def test_conflicting_build_kind_is_refused_in_both_directions
    source = @source.sub('flags development,partial_boot', 'flags none')
    assert_raises(Erx::Manifest::Invalid) { fixture(source) }
    arguments = ManifestContextFixture.arguments(@codec).merge(build_kind: 'release')
    release_context = Erx::Manifest::Context.new(**arguments)
    assert_raises(Erx::Manifest::Invalid) { fixture(@source, release_context) }
  end

  def test_nonempty_native_boot_requires_real_planning
    source = @source + "partial_boot probe\n  image @artifact.root\n"
    error = assert_raises(Erx::Manifest::Unsupported) { fixture(source) }
    assert_equal 'partial_boot', error.field
  end

  def test_missing_sizing_for_full_boot_is_not_a_success
    source = @source.sub('flags development,partial_boot', 'flags development')
    assert_raises(Erx::Manifest::Unsupported) { fixture(source) }
  end

  def test_zero_cpuset_uses_parent_before_rate_comparison
    source = @source.gsub('cpuset 1', 'cpuset 0')
    result = fixture(source)
    assert_equal 1, result.report.fetch('effective_system_cpuset')
    assert_equal 1, result.report.fetch('effective_users_cpuset')
  end

  def test_root_budget_overcommit_is_refused
    source = @source.sub('root_memory 1073741824', 'root_memory 33554432')
    error = assert_raises(Erx::Manifest::Invalid) { fixture(source) }
    assert_equal 4, error.property
  end

  def test_raw_admitted_constructor_is_private
    assert_raises(NoMethodError) { Erx::Manifest::Admitted.new(bytes: ''.b, report: {}, context: @context) }
  end

  def test_declared_baseline_cannot_understate_checked_private_image_memory
    arguments = ManifestContextFixture.arguments(@codec)
    image = arguments.fetch(:catalog).last.fetch('image')
    image['span'] = 8_392_704
    image.fetch('segments') << { 'file_offset' => 8192, 'mem_offset' => 4096,
                                'file_size' => 0, 'mem_size' => 8_388_608,
                                'prot' => @codec.member('prot', 'rw'), 'flags' => 0 }
    context = Erx::Manifest::Context.new(**arguments)
    source = @source.sub('root_memory 1073741824', 'root_memory 4096')
                    .sub('system_baseline 67108864', 'system_baseline 1')
                    .sub('memory 268435456', 'memory 0')
    error = assert_raises(Erx::Manifest::Invalid) { fixture(source, context) }
    assert_equal 4, error.property
    assert_equal 'machine.system_baseline', error.field
  end

  def test_real_admission_requires_the_real_initial_root_plan
    error = assert_raises(Erx::Manifest::Unsupported) do
      Erx::Manifest.admit(source: @source, codec: @codec, context: @context)
    end
    assert_equal 4, error.property
    assert_equal 'root_startup', error.field
  end
end
