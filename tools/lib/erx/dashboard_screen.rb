# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'rbconfig'
require 'tmpdir'
require_relative 'lvgl'
require_relative 'oracle'
require_relative 'ppm'

module Erx
  # The kiosk dashboard's screen at a given wall-clock minute when every quote's first round
  # failed for one reason, as the host's erx-lvgl draws it at the display suite's size: the
  # board comes from the live source's own pure modules (erx_quotes_core on
  # erx_quotes_table's table, then erx_quotes_view), so it is the board the dashboard shows
  # after a boot with no network. It is the picture the host test compares
  # with test/display/reference/dashboard and the kiosk cell (tools/lib/erx/kiosk.rb)
  # compares the guest's screen with. The caller names the dashboard's app directory and an
  # SDK exported from the tree (Erx::AppPack::Sdk); the app's modules compile with the SDK's
  # erlc against the SDK's applications alone, as a third party's build does
  # (docs/design-packaging.md, "Examples"), and the screen model
  # (test/erlang/erx_lvgl_screen.erl) runs on the SDK's erl over them.
  module DashboardScreen
    ROOT = File.expand_path('../../..', __dir__)
    SCREEN = File.join(ROOT, 'test/erlang/erx_lvgl_screen.erl')
    LAUNCHER = File.join(ROOT, 'test/fixtures/erx_lvgl_buffer.rb')
    FLAGS = %w[-Werror +debug_info].freeze
    WIDTH = 1280
    HEIGHT = 800
    DEADLINE = 300

    module_function

    # The screen at time, [[year, month, day], [hour, minute, second]], as an Erx::Ppm::Image,
    # of the dashboard at app over sdk, every quote's first round having failed with reason,
    # a Symbol naming an erx_quotes_http reason such as :no_net.
    def picture(time, app:, sdk:, runner:, reason:)
      program = Erx::Lvgl::Build.new(root: ROOT, runner: runner).call
      Dir.mktmpdir('erx-dashboard-screen') do |work|
        compile(work, app: app, sdk: sdk, runner: runner, tests: [SCREEN])
        runner.run([sdk.erl, '-noshell', *code_path(work, sdk: sdk), '-eval',
                    "ok = file:write_file(\"picture.rgb\", erx_lvgl_screen:picture(#{screen(program)}, " \
                    "erx_dashboard_view:tree(#{model(time, reason)}), {#{WIDTH}, #{HEIGHT}})), halt(0)"],
                   name: 'dashboard-screen', deadline: DEADLINE, chdir: work, env: Erx::Oracle::CLEAN_ERLANG_ENV)
        Erx::Ppm::Image.new(width: WIDTH, height: HEIGHT, pixels: File.binread(File.join(work, 'picture.rgb')))
      end
    end

    # Compiles the dashboard's modules at app, then tests (absolute paths of further
    # modules), into work, an existing directory, with sdk's erlc against sdk's
    # applications, warnings as errors; returns work.
    def compile(work, app:, sdk:, runner:, tests: [])
      runner.run([sdk.erlc, *FLAGS, '-o', work, *code_path(work, sdk: sdk), *modules(app), *tests],
                 name: 'dashboard-compile', deadline: DEADLINE, env: Erx::Oracle::CLEAN_ERLANG_ENV)
      work
    end

    # The code path of what compile wrote into work: work first, the SDK's applications
    # after it.
    def code_path(work, sdk:) = ['-pa', work, *[*sdk.ebins, sdk.host_ebin].flat_map { ['-pz', it] }]

    # The modules of the applications at app, each behaviour before the modules that implement
    # it, the order erlc needs them in.
    def modules(app)
      Dir.glob(File.join(app, 'lib/*/src/*.erl')).sort_by do |path|
        [File.foreach(path).any? { |line| line.start_with?('-callback ') } ? 0 : 1, path]
      end
    end

    # The view's model at time with the board of failed (below), as an Erlang term.
    def model(time, reason)
      (year, month, day), (hour, minute, second) = time
      clock = "{{#{Integer(year)}, #{Integer(month)}, #{Integer(day)}}, " \
              "{#{Integer(hour)}, #{Integer(minute)}, #{Integer(second)}}}"
      "\#{time => #{clock}, board => #{failed(reason)}, dial => erx_dashboard_clock:png(dark, #{clock}), ground => erx_dashboard_pictures:ground(erx_dashboard_view:clock_offset())}"
    end

    # The board erx_quotes sends once every quote of the table has started its first round
    # and each round failed with reason, as an Erlang expression: the core takes one outcome
    # per quote, and with one source per quote each outcome ends its round.
    def failed(reason)
      "(fun() -> T = erx_quotes_table:table(), " \
        "{C0, _} = erx_quotes_core:tick(erx_quotes_core:new(T, 0), 0, 1.0), " \
        "C = lists:foldl(fun({Q, _}, S) -> element(1, erx_quotes_core:outcome(S, Q, {error, #{reason}, none}, 0, 1.0)) end, " \
        "C0, maps:get(quotes, T)), " \
        'erx_quotes_view:board(C, 0) end)()'
    end

    # The model screen's map of the program and how to start it, as an Erlang term: in the
    # dark palette, which the kiosk's display entry chooses (config/manifest/development.txt).
    def screen(program)
      pairs = { program: program, ruby: RbConfig.ruby, launcher: LAUNCHER }.map { |key, path| "#{key} => #{path.inspect}" }
      "\#{#{pairs.join(', ')}, args => [\"dark\"]}"
    end
  end
end
