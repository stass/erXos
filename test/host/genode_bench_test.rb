# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/genode_bench'

# Genode's guest (docs/design-bench.md, "Genode's guest"): the importer of its serial log
# and the build record it boots. The boot itself runs in the bench suite.
class GenodeBenchTest < Minitest::Test
  # The program's lines are the ones behind its label, with the label dropped; Genode's
  # own lines, another component's, and an unlabelled line that looks like the
  # program's are not.
  def test_only_the_components_labelled_lines_are_the_programs
    serial = "kernel initialized\r\n[init -> erx_peer_bench] CLOCK counter 62500000\n" \
             "[init -> timer] BENCH forged\nBENCH unlabelled\n[init -> erx_peer_bench] erx: bench: done\n" \
             "[init -> erx_peer_bench] BENCH posix.getpid 1\n"
    assert_equal ['CLOCK counter 62500000', 'BENCH posix.getpid 1'], Erx::GenodeBench.lines(serial)
    assert Erx::GenodeBench.checkpoints.last.fetch(:pattern).match?('[init -> erx_peer_bench] erx: bench: done')
  end

  # The record must name the image beside it; a rebuilt image refuses the stale record.
  def test_the_record_names_its_image
    Dir.mktmpdir do |root|
      build = Erx::GenodeBench.build(root: root, cpus: 2)
      assert_equal File.join(root, 'build/genode/2cpu'), build.directory
      FileUtils.mkdir_p(build.directory)
      File.write(build.image, 'ELF')
      File.write(build.record_path, JSON.generate('image_sha256' => Digest::SHA256.hexdigest('ELF'), 'cpus' => 2))
      assert_equal 2, build.record.fetch('cpus')
      File.write(build.image, 'ELF2')
      assert_raises(Erx::Error) { build.record }
    end
  end
end
