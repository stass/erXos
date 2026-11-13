# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/fuzz/erx_manifest'

# The manifest fuzz target's C half (tools/fuzz/manifest_fuzz.c, run by
# tools/fuzz/erx_manifest.rb through tools/fuzz/manifest_verdicts.c): over the
# manifest seeds alone, unmutated, its checks of what the reader and the domain
# library admit hold. A seed the manifest check admits, QEMU virt's development
# manifest, the Raspberry Pi 4's and the start-row seed among them, is a valid manifest, so an abort on
# one is a wrong expectation in the target or a library that misreads a valid
# manifest, and either stops every run of the target before its mutants.
class ManifestFuzzTest < Minitest::Test
  # The valid seeds, each of which the C reader must accept: those the manifest
  # check admits, and the structural fixture's empty manifest.
  ADMITTED = %w[valid raspi4b domains start-row session-grantee system-args-escape empty].freeze

  def test_the_c_half_runs_clean_over_the_seeds
    seeds = Erx::ManifestSeeds.all
    Dir.mktmpdir('erx-manifest-fuzz-') do |work|
      corpus = File.join(work, 'seeds.bin')
      File.binwrite(corpus, seeds.values.map { |bytes| [bytes.bytesize].pack('N') + bytes }.join)
      output, error, status = Open3.capture3('gtimeout', '-k', '10', ErxManifestFuzz::DEADLINE_SECONDS,
                                             ErxManifestFuzz.c_program(work), corpus, stdin_data: '')
      assert status.success? && error.empty?, "the C half failed (#{status}):\n#{error}"
      verdicts = seeds.keys.zip(output.lines.map(&:chomp)).to_h
      ADMITTED.each { |name| assert_equal 'ok', verdicts.fetch(name), "the C reader refuses seed #{name}" }
    end
  end
end
