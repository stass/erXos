# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/import_notices'

class ImportNoticeProfileTest < Minitest::Test
  def fixture
    { 'version' => 1, 'licenses' => { 'MIT' => [{ 'path' => 'LICENSE', 'sha256' => 'a' * 64 }] },
      'packages' => [{ 'path' => 'vendor/nested', 'notices' => [],
                      'grants' => { 'MIT' => [{ 'path' => 'vendor/nested/COPYRIGHT', 'sha256' => 'b' * 64 }] } }] }
  end

  def test_nested_package_overrides_the_selected_grant_only
    profile = Erx::ImportNotices.parse(JSON.generate(fixture))
    assert_equal ['vendor/nested/COPYRIGHT'],
                 Erx::ImportNotices.select(profile, source: 'vendor/nested/source.c', grants: ['MIT']).map { |doc| doc.fetch('path') }
    assert_equal ['LICENSE'], Erx::ImportNotices.select(profile, source: 'own/source.c', grants: ['MIT']).map { |doc| doc.fetch('path') }
    assert_empty Erx::ImportNotices.select(profile, source: 'vendor/nested/source.c', grants: ['GPL-2.0-only'])
    assert profile.frozen?
  end

  def test_unknown_fields_unbound_documents_and_traversal_fail
    variants = []
    value = fixture
    value['unknown'] = 1
    variants << value
    value = fixture
    value.fetch('licenses').fetch('MIT').first['path'] = '../private'
    variants << value
    value = fixture
    value.fetch('licenses').fetch('MIT').first['sha256'] = 'unbound'
    variants << value
    value = fixture
    value.fetch('packages') << value.fetch('packages').first.dup
    variants << value
    value = fixture
    value.fetch('licenses')['MIT AND GPL-2.0-only'] = value.fetch('licenses').delete('MIT')
    variants << value
    variants.each { |variant| assert_raises(Erx::Error) { Erx::ImportNotices.parse(JSON.generate(variant)) } }
  end
end
