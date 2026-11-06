# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/block_write_path'

# The chokepoint that only the block driver's write path builds a write request
# (docs/design-storage.md, "The block driver"): the tree passes, and each seeded naming of
# ERX_VIRTIO_BLK_T_OUT outside erx_blk_write fails, in the driver's own modules too.
class BlockWritePathTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WRITE_PATH = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
  DRIVER = 'erlang/apps/erx_blk/src/erx_blk.erl'
  SEEDED = "h(S) -> <<?ERX_VIRTIO_BLK_T_OUT:32/little, 0:32, S:64/little>>.\n"

  def lines_of(files) = Erx::BlockWritePath.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_the_write_path_names_the_type
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::BlockWritePath.violations(files).map(&:to_s)
    assert_match Erx::BlockWritePath::NAMED, files.fetch(WRITE_PATH)
  end

  def test_a_seeded_write_request_outside_the_write_path_is_refused
    assert_equal [[DRIVER, 2]], lines_of(DRIVER => "%% ERX_VIRTIO_BLK_T_OUT in a comment is not code\n#{SEEDED}")
    assert_equal [['erlang/apps/erx_files/src/seeded.erl', 1]], lines_of('erlang/apps/erx_files/src/seeded.erl' => SEEDED)
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => "f() -> 'ERX_VIRTIO_BLK_T_OUT'.\n")
    assert_empty lines_of(WRITE_PATH => SEEDED)
    assert_empty lines_of(DRIVER => "f() -> ?ERX_VIRTIO_BLK_T_OUTER.\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(DRIVER)))
      File.write(File.join(root, DRIVER), SEEDED)
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_block_write_path, [DRIVER, 'README.md']) }
      assert_match "#{DRIVER}:1", error.message
    end
  end
end
