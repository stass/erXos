# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints_helper'

# The chokepoint "only erx_screen calls erx_display:flush_request/3 and power_request/2":
# a call of either outside erx_screen fails, in a driver's own modules too, in every form
# that names it as a call target; erx_display's definitions, the behaviour's types and a
# driver's own handle_call/3 pass.
class DisplayDriverCallersTest < Minitest::Test
  include ChokepointsHelper

  SCREEN = 'erlang/apps/erx_display/src/erx_screen.erl'
  DISPLAY = 'erlang/apps/erx_display/src/erx_display.erl'
  DRIVER = 'erlang/apps/erx_fb/src/erx_virtio_gpu.erl'
  WM = 'erlang/apps/erx_display/src/erx_wm.erl'
  SEEDED = "f(D, I) -> erx_display:flush_request(D, [], I).\n"

  def lines_of(files) = erlang_found(%w[display-driver-callers], files).map { |_, path, line| [path, line] }

  def test_the_tree_passes_and_the_screen_calls_the_driver
    files = erlang_tree
    assert_empty evaluate([rule('display-driver-callers')], files).map(&:to_s)
    screen = Erx::ErlangText.code_without_strings(files.fetch(SCREEN))
    assert_match(/erx_display:flush_request\(Driver, /, screen, 'erx_screen sends its frames through erx_display')
  end

  def test_a_seeded_call_outside_the_screen_is_refused
    assert_equal [[WM, 2]], lines_of(WM => "%% erx_display:flush_request/3 in a comment is not code\n#{SEEDED}")
    {
      'a power request' => "f(D) -> erx_display:power_request(D, off).\n",
      'a macro of a function' => "-define(F, flush_request).\n",
      'a fun' => "f() -> fun erx_display:flush_request/3.\n",
      'a quoted atom' => "f(D, I) -> 'erx_display':'flush_request'(D, [], I).\n",
      'an apply of the module' => "f(A) -> erlang:apply(erx_display, power_request, A).\n",
      'an apply through a variable' => "f(M, A) -> apply(M, flush_request, A).\n",
      'a module in a variable' => "f(M, D) -> M:power_request(D, dim).\n",
      'a module in a macro' => "f(D) -> ?DISPLAY:power_request(D, on).\n",
      'a module and function pair' => "f() -> {erx_display, flush_request}.\n",
      'an import' => "-import(erx_display, [power_request/2]).\n",
      'a macro of the module' => "-define(DISPLAY, erx_display).\n",
      'a call split across lines' => "f(D, I) ->\n    erx_display:\n        flush_request(D, [], I).\n"
    }.each do |form, source|
      # Each form is one line long but the split call, which is refused at its module.
      assert_equal [[WM, form == 'a call split across lines' ? 2 : 1]], lines_of(WM => source), form
    end
    assert_equal [[DRIVER, 1]], lines_of(DRIVER => SEEDED)
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => SEEDED)
  end

  def test_definitions_types_and_the_screen_are_not_refused
    assert_empty lines_of(SCREEN => SEEDED)
    assert_empty lines_of(DISPLAY => "-export([flush_request/3, power_request/2]).\n" \
                                     "flush_request(Driver, Rects, Image) -> x.\n" \
                                     "power_request(Driver, Level) -> x.\n")
    assert_empty lines_of(DRIVER => "-behaviour(erx_display).\n" \
                                    "-spec info(pid()) -> erx_display:info().\n" \
                                    "handle_call({power, Level}, _From, S) -> {reply, ok, S}.\n" \
                                    "f() -> [a, power, b], power(x), my_flush_request(y).\n")
    assert_empty lines_of(WM => "f() -> \"M:flush\", erx_display_x:flush_request(y), M:flush(z).\n")
    assert_empty lines_of(WM => "-moduledoc \"\"\"\nSends through `erx_display:flush_request/3`.\n\"\"\".\n" \
                                "f() -> io:format(\"erx_display, power_request~n\").\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    error = enforce_seeded(%w[display-driver-callers], WM, SEEDED)
    assert_match "#{WM}:1", error.message
  end
end
