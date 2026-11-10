# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/runtime'

# erx_device from Erlang on the hosted runtime, through its stand-in: plain memory for a
# window and software objects for lines, so the BIFs' dispatch and the NIF's bindings run
# under real terms and a real event table. `make check-runtime-hosted` builds the runtime
# and runs this.
class RuntimeDeviceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  BUDGET_SECONDS = 60

  def setup = Erx::Runtime.check_current(root: ROOT)

  def test_a_register_goes_by_name_and_only_as_the_table_allows
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => []}),
      ok = erx_device:write(D, imsc, 16),
      16 = erx_device:read(D, imsc),
      1 = erx_device:read_field(D, imsc, rxim),
      ok = erx_device:write_field(D, imsc, txim, 1),
      48 = erx_device:read(D, imsc),
      ok = erx_device:write_field(D, imsc, rxim, 0),
      32 = erx_device:read(D, imsc),
      ok = erx_device:write(D, dr, 65),
      65 = erx_device:read_field(D, dr, data),
      ok = erx_device:write(D, icr, erx_device:read(D, ris)),
      ok = erx_device:write_field(D, icr, txic, 1),
      1 = erx_device:field(D, dr, oe, 16#800),
      0 = erx_device:field(D, dr, fe, 16#800),
      16#ab = erx_device:field(D, dr, data, 16#8ab),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  REFUSED = ['write(D, dr, 16#100)', 'write_field(D, dr, data, 65)', 'read(D, icr)', 'read_field(D, icr, txic)', 'field(D, icr, txic, 1)', 'field(D, dr, data, -1)', 'field(D, dr, no_such, 0)',
             'write(D, fr, 0)', 'write_field(D, fr, rxfe, 1)', 'read(D, no_such_register)',
             'read_field(D, imsc, no_such_field)', 'read_field(D, imsc, data)', 'read(D, 16#38)', 'read(D, {imsc, 0})',
             'read(D, "imsc")', 'read(D + 1000, imsc)', 'read(-1, imsc)', 'read(self(), imsc)', 'write(D, imsc, -1)',
             'write(D, imsc, 1 bsl 70)', 'write(D, imsc, 1 bsl 11)', 'write(D, imsc, an_atom)',
             'write_field(D, imsc, rxim, 2)', 'irq_ack(D, 0)', 'irq_bind(D, 0)',
             'open(#{peripheral => no_such, window => stand_in, lines => []})', 'open(#{peripheral => pl011, lines => []})',
             'open(not_a_map)'].freeze
  # The boot page holds a short command line, so the refusals go a few at a time.
  REFUSED_PER_BOOT = 6
  OPEN_STAND_IN = '{ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => []}), '

  def test_what_the_table_does_not_allow_is_badarg
    REFUSED.each_slice(REFUSED_PER_BOOT) do |calls|
      checks = calls.map { |call| "{'EXIT', {badarg, _}} = (catch erx_device:#{call}), " }.join
      assert_equal 'ok', evaluate("#{OPEN_STAND_IN}#{checks}io:format(\"~s~n\", [ok]), halt().")
    end
  end

  def test_a_hosted_runtime_has_no_real_device
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {error, enotsup} = erx_device:open(#{peripheral => pl011, window => {physical, 16#9000000, 4096}, lines => [33]}),
      {ok, _} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => []}),
      {error, enotsup} = erx_device:open(#{peripheral => pl011, window => {physical, 0, 4096}, lines => []}),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # A given spec decodes on a hosted runtime, which has no objects to map, so its open fails
  # at the window's map; one that mixes the forms is badarg before anything is mapped.
  def test_a_given_device_decodes_and_a_mixed_spec_is_badarg
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {error, einval} = erx_device:open(#{peripheral => pl011, window => {object, 1, 0, 4096}, lines => [{object, 2}]}),
      {error, einval} = erx_device:open(#{peripheral => pl011, window => {object, 1, 0, 4096}, lines => [],
                                          memory => {object, 3, 8192}}),
      io:format("~s~n", [ok]), halt().
    ERLANG
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {'EXIT', {badarg, _}} = (catch erx_device:open(#{peripheral => pl011, window => {object, 1, 0, 4096}, lines => [2]})),
      {'EXIT', {badarg, _}} = (catch erx_device:open(#{peripheral => pl011, window => {physical, 0, 4096}, lines => [],
                                                       memory => {object, 3, 8192}})),
      {'EXIT', {badarg, _}} = (catch erx_device:open(#{peripheral => pl011, window => {object, 1, 0}, lines => []})),
      {'EXIT', {badarg, _}} = (catch erx_device:open(#{peripheral => pl011, window => {object, 1, 0, 4096}, lines => [],
                                                       memory => {object, 3, 0}})),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  def test_a_line_reaches_the_process_bound_to_it
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [0, 0]}),
      ok = erx_device:irq_bind(D, 1),
      ok = erx_device:stand_in_fire(D, 1),
      receive {erx_irq, D, 1} -> ok after 5000 -> exit(no_delivery) end,
      ok = erx_device:irq_ack(D, 1),
      ok = erx_device:stand_in_fire(D, 1),
      receive {erx_irq, D, 1} -> ok after 5000 -> exit(no_second_delivery) end,
      ok = erx_device:irq_ack(D, 1),
      ok = erx_device:stand_in_fire(D, 0),
      receive {erx_irq, D, 0} -> exit(unbound_line_delivered) after 200 -> ok end,
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # A successor's binding moves the line, so the late exit of the driver before it changes nothing.
  def test_a_late_exit_leaves_the_successors_binding
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [0]}),
      Me = self(),
      Former = spawn(fun() -> ok = erx_device:irq_bind(D, 0), Me ! bound, receive stop -> ok end end),
      receive bound -> ok end,
      Ref = monitor(process, Former),
      ok = erx_device:irq_bind(D, 0),
      Former ! stop,
      receive {'DOWN', Ref, process, Former, normal} -> ok end,
      erlang:yield(),
      ok = erx_device:stand_in_fire(D, 0),
      receive {erx_irq, D, 0} -> ok after 5000 -> exit(lost_to_former) end,
      ok = erx_device:irq_ack(D, 0),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # The driver's exit ends its binding; a restarted driver binds the same line of the same record.
  def test_a_restarted_driver_binds_again
    assert_equal 'ok', evaluate(<<~'ERLANG')
      Spec = #{peripheral => pl011, window => stand_in, lines => [0]},
      {ok, D} = erx_device:open(Spec),
      Me = self(),
      Driver = fun() -> ok = erx_device:irq_bind(D, 0), Me ! bound,
                        receive {erx_irq, D, 0} -> Me ! irq end, ok = erx_device:irq_ack(D, 0) end,
      First = spawn(Driver),
      receive bound -> ok end,
      ok = erx_device:stand_in_fire(D, 0),
      receive irq -> ok after 5000 -> exit(no_delivery) end,
      Ref = monitor(process, First),
      receive {'DOWN', Ref, process, First, _} -> ok end,
      spawn(Driver),
      receive bound -> ok end,
      ok = erx_device:stand_in_fire(D, 0),
      receive irq -> ok after 5000 -> exit(no_delivery_after_restart) end,
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # More bindings than the event table has labels (erx_event_table.h), so a label an exit or
  # a move failed to give back ends in `{error, elimit}`.
  def test_a_binding_gives_back_its_label_at_an_exit_and_at_a_move
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [0]}),
      Me = self(),
      Bind = fun() -> ok = erx_device:irq_bind(D, 0), Me ! bound end,
      [begin {P, R} = spawn_monitor(Bind), receive bound -> ok end,
       receive {'DOWN', R, process, P, normal} -> ok end end || _ <- lists:seq(1, 300)],
      [ok = erx_device:irq_bind(D, 0) || _ <- lists:seq(1, 300)],
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  private

  # The expression's last printed line.
  def evaluate(expression)
    output, = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', BUDGET_SECONDS.to_s,
                              OUTPUT.beam, OUTPUT.archive, '-noshell', '-eval', expression.gsub("\n", ' '), stdin_data: '')
    output.lines(chomp: true).last.to_s.then { |line| line == 'ok' ? line : output }
  end
end
