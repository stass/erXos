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

  # What base-hw on QEMU's virt allows at the pinned release is one declaration: it boots
  # under TCG alone, entered at the hypervisor's level, always on four CPUs, and its C
  # library refuses to pin, so the guest, the build and the program's arguments all follow
  # it and no caller passes any of it.
  def test_the_guest_boots_as_the_machine_declaration_allows
    machine = Erx::GenodeBuild::MACHINE
    assert_equal [%w[tcg], 4, true, false], [machine.accelerators, machine.cpus, machine.virtualization, machine.pinned]
    guest = Erx::GenodeBench::Guest.new(root: Dir.pwd, runner: nil, platform: nil)
    assert_equal [%w[tcg], [4], [4]], [guest.accelerators, guest.forms(1), guest.forms(4)]
    assert_equal %w[posix 4 unpinned], Erx::GenodeBuild.arguments
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
