# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/device_posters'

# The chokepoint "only the block driver's one write path issues writes", held by
# construction: a call of erx_device:post/4 outside erx_blk_write fails, in the driver's
# own modules too, whether a remote call, a fun, an apply, or an import.
class DevicePostersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  WRITE_PATH = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
  DRIVER = 'erlang/apps/erx_blk/src/erx_blk_virtio.erl'
  SEEDED = "p(D, Q, T, S) -> erx_device:post(D, Q, T, S).\n"

  def lines_of(files) = Erx::DevicePosters.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_the_write_path_posts
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::DevicePosters.violations(files).map(&:to_s)
    assert_match Erx::DevicePosters::NAMED.fetch('post'), files.fetch(WRITE_PATH)
  end

  def test_a_seeded_post_outside_the_write_path_is_refused
    assert_equal [[DRIVER, 2]], lines_of(DRIVER => "%% erx_device:post/4 in a comment is not code\n#{SEEDED}")
    {
      'a fun' => "f() -> fun erx_device:post/4.\n",
      'a quoted atom' => "f(D, Q, T, S) -> 'erx_device':'post'(D, Q, T, S).\n",
      'an apply' => "f(A) -> erlang:apply(erx_device, post, A).\n",
      'an import' => "-import(erx_device, [read/2, post/4]).\n",
      'a call split across lines' => "f(D, Q, T, S) ->\n    erx_device:\n        post(D, Q, T, S).\n"
    }.each do |form, source|
      line = source.lines.index { |text| text.include?('erx_device') } + 1
      assert_equal [[DRIVER, line]], lines_of(DRIVER => source), form
    end
    assert_equal [['erlang/apps/erx_uart/src/seeded.erl', 1]], lines_of('erlang/apps/erx_uart/src/seeded.erl' => SEEDED)
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => SEEDED)
  end

  # command/2 has one site, the write path: a post site of another transport may not issue
  # an SD command either.
  COMMANDED = "c(D, W) -> erx_device:command(D, W).\n"

  def test_a_seeded_command_outside_the_write_path_is_refused
    assert_equal [[DRIVER, 1]], lines_of(DRIVER => COMMANDED)
    assert_equal [[DRIVER, 1]], lines_of(DRIVER => "f(A) -> erlang:apply(erx_device, command, A).\n")
    net = 'erlang/apps/erx_net/erxos/erx_virtio_net.erl'
    assert_equal [[net, 1]], lines_of(net => COMMANDED)
    assert_equal [[net, 1]], lines_of(net => "-import(erx_device, [command/2]).\n")
    assert_empty lines_of(WRITE_PATH => COMMANDED)
  end

  def test_other_device_calls_the_write_path_and_tests_are_not_refused
    assert_empty lines_of(WRITE_PATH => SEEDED)
    assert_empty lines_of(DRIVER => "f(D, Q) -> erx_device:complete(D, Q), erx_device:poster(D), my_erx_device:post(D).\n")
    assert_empty lines_of(DRIVER => "f() -> \"erx_device, posted\".\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(DRIVER)))
      File.write(File.join(root, DRIVER), SEEDED)
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_device_posters, [DRIVER, 'README.md']) }
      assert_match "#{DRIVER}:1", error.message
    end
  end
end
