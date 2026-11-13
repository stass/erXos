# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/device_callers'

# The chokepoint that only erx_device and the driver applications name erx_device
# (docs/design-runtime.md, "The device NIF"): the tree passes, and each seeded way of
# reaching the device module from elsewhere fails.
class DeviceCallersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  STOCK = 'otp/lib/stdlib/src/seeded.erl'
  SERVICE = 'erlang/apps/erx_files/src/seeded.erl'

  def lines_of(files) = Erx::DeviceCallers.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes_and_its_driver_is_a_site
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::DeviceCallers.violations(files).map(&:to_s)
    assert_match Erx::DeviceCallers::NAMED, files.fetch('erlang/apps/erx_uart/src/erx_pl011.erl')
  end

  def test_a_remote_call_from_a_stock_module_fails
    assert_equal [[STOCK, 2]], lines_of(STOCK => "-module(seeded).\nf(D) -> erx_device:read(D, dr).\n")
  end

  def test_an_apply_a_quoted_atom_or_a_string_from_a_service_fails
    text = "f(D) -> apply(erx_device, read, [D, dr]).\ng() -> 'erx_device'.\nh() -> \"erx_device\".\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2], [SERVICE, 3]], lines_of(SERVICE => text)
  end

  def test_a_percent_in_a_string_or_a_character_does_not_hide_the_code_after_it
    text = "f(D) -> io:put_chars(\"100%\"), erx_device:read(D, dr).\ng(D) -> [$%, erx_device:read(D, dr)].\n"
    assert_equal [[SERVICE, 1], [SERVICE, 2]], lines_of(SERVICE => text)
  end

  def test_a_triple_quoted_string_with_quotes_and_percents_keeps_the_lines_after_it
    text = "-moduledoc \"\"\"\nA \"quoted\" 50% note.\n\"\"\".\nf(D) -> erx_device:read(D, dr).\n"
    assert_equal [[SERVICE, 4]], lines_of(SERVICE => text)
  end

  # A sigil's delimiters can hold a quote or a %: ~s and the vanilla sigil take escapes,
  # ~S is verbatim, so its backslash ends nothing early and hides nothing after it.
  def test_sigils_with_quotes_percents_and_backslashes_keep_the_code_after_them
    text = "f(D) -> {~s(say \"hi), ~S\"a\\\", erx_device:read(D, dr)}.\ng(D) -> {~b\"50%\", ~\"\"\"\n  a \" %\n  \"\"\", erx_device:read(D, dr)}.\n"
    assert_equal [[SERVICE, 1], [SERVICE, 4]], lines_of(SERVICE => text)
  end

  def test_comments_names_that_merely_contain_it_and_files_outside_the_scope_pass
    text = "%% erx_device is the driver's.\nf() -> erx_device_table:x(), my_erx_device.\n"
    assert_empty lines_of(SERVICE => text)
    assert_empty lines_of('test/erlang/seeded_tests.erl' => "f(D) -> erx_device:read(D, dr).\n")
  end

  def test_the_device_module_and_a_driver_application_are_sites
    call = "f(D) -> erx_device:read(D, dr).\n"
    assert_empty lines_of('erlang/apps/erx/src/erx_device.erl' => call, 'erlang/apps/erx_uart/src/seeded.erl' => call)
    assert_equal [['erlang/apps/erx/src/seeded.erl', 1]], lines_of('erlang/apps/erx/src/seeded.erl' => call)
  end

  # A driver that binds a shared line itself would take its deliveries from the drivers
  # joined to the line's owner (docs/design-shared-devices.md, SD3).
  def test_a_driver_that_binds_a_shared_line_itself_fails
    bind = "f(D) -> erx_device:irq_bind_owner(D, 0).\n"
    assert_equal [['erlang/apps/erx_uart/src/seeded.erl', 1]], lines_of('erlang/apps/erx_uart/src/seeded.erl' => bind)
    assert_empty lines_of('erlang/apps/erx/src/erx_device.erl' => bind, 'erlang/apps/erx/src/erx_irq_line.erl' => bind)
    assert_equal [['erlang/apps/erx/src/seeded.erl', 1], ['erlang/apps/erx/src/seeded.erl', 1]],
                 lines_of('erlang/apps/erx/src/seeded.erl' => bind)
  end

  # The source check runs the rule over the files git lists, OTP's included.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(STOCK)))
      File.write(File.join(root, STOCK), "f(D) -> erx_device:read(D, dr).\n")
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_device_callers, [STOCK, 'README.md']) }
      assert_match "#{STOCK}:1", error.message
    end
  end
end
