# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/manifest_context'

# erx_build:principals/1, which names a principal's sessions (docs/design-domains.md,
# "Principals, sessions and quotas"), over manifests the packer made: each principal's
# number is its index plus one, in the packer's name order, and the system principal is
# the manifest's root.system_principal, which need not be the first. A manifest that does
# not parse names no principal.
class ErxBuildPrincipalsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FIXTURE = File.join(ROOT, 'test/fixtures/manifest_empty.txt')
  # A principal that sorts before the fixture's root, so root, the system principal, is 2,
  # a share of half the users' share that every grant of the manifest takes, and room for
  # alpha's one domain.
  HALF = <<~TEXT
    share half
      quota_ns 4000000
      period_ns 10000000
      cpuset 1
      capacity_mcpu 400
      capacity_first 0
      slice_us 1000
      grace_us 5
      base 16
      ceiling 31
      flags none
  TEXT
  ALPHA = <<~TEXT
    principal alpha
      memory 1048576
      grant @share.half
      domains 1
      names 1
      default_limits @limits.native
      ceiling_limits @limits.native
  TEXT

  def setup
    Erx::Generated.ensure(root: ROOT)
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT))
    @codec = Erx::ABI::Codec.new(schema)
    @context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(@codec))
  end

  def test_the_fixtures_one_principal_is_the_system_principal
    assert_equal '{ok,#{system => 1,names => #{1 => <<"root">>}}}', principals(packed(File.binread(FIXTURE)))
  end

  def test_the_system_principal_is_the_manifests_not_the_first
    source = File.binread(FIXTURE).sub("share users\n", "#{HALF}share users\n")
                 .gsub('grant @share.users', 'grant @share.half').sub("principal root\n", "#{ALPHA}principal root\n")
                 .sub('max_domains 4', 'max_domains 5')
    assert_equal '{ok,#{system => 2,names => #{1 => <<"alpha">>,2 => <<"root">>}}}', principals(packed(source))
  end

  # The system principal's sessions are root_N, so a principal named root that is not
  # the system principal would share their names; the packer refuses it.
  def test_only_the_system_principal_may_be_named_root
    source = File.binread(FIXTURE).sub("share users\n", "#{HALF}share users\n")
                 .gsub('grant @share.users', 'grant @share.half')
                 .sub("principal root\n", "#{ALPHA.sub('principal alpha', 'principal root')}principal sys\n")
                 .sub('system_principal @principal.root', 'system_principal @principal.sys')
                 .sub('max_domains 4', 'max_domains 5')
    error = assert_raises(Erx::Manifest::Invalid) { packed(source) }
    assert_match(/only the system principal may be named root/, error.message)
  end

  def test_a_manifest_that_does_not_parse_names_no_principal
    assert_equal '{error,malformed}', principals('junk'.b)
  end

  private

  def packed(source)
    fixture = Erx::Manifest.structural_fixture(source: source, codec: @codec, context: @context)
    assert_kind_of Erx::Manifest::StructuralFixture, fixture
    fixture.bytes
  end

  # erx_build:principals({ok, Bytes}) as the oracle's emulator prints it.
  def principals(bytes)
    Dir.mktmpdir('erx-build-principals') do |work|
      includes = %w[erlang/apps/erx/include].flat_map do |include|
        ['-I', Erx::Generated.path(include, root: ROOT), '-I', File.join(ROOT, include)]
      end
      sources = [Erx::Generated.path('erlang/apps/erx/src/generated/erx_manifest.erl', root: ROOT),
                 File.join(ROOT, 'erlang/apps/erx/src/erx_build.erl')]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *includes, '-o', work, *sources, stdin_data: '')
      assert status.success?, output
      File.binwrite(File.join(work, 'manifest'), bytes)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'io:format("~0p", [erx_build:principals(file:read_file("manifest"))]), ' \
                                                'halt().',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      output
    end
  end
end
