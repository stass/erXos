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
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [0, 1]}),
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

  # Two records on one shared soft line share its entry (docs/design-shared-devices.md,
  # "Verification"): the owner's bind through the first takes a trigger through either, a
  # driver's bind of the shared line is refused, an owner's bind through the second is busy,
  # and the holder is the binder.
  def test_records_on_one_shared_line_have_one_binder
    assert_equal 'ok', evaluate(<<~'ERLANG')
      {ok, A} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [{shared, 7}]}),
      {ok, B} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [{shared, 7}]}),
      {error, unbound} = erx_device:irq_holder(B, 0),
      {error, shared} = erx_device:irq_bind(A, 0),
      ok = erx_device:irq_bind_owner(A, 0),
      Me = self(),
      {ok, Me} = erx_device:irq_holder(B, 0),
      {error, ebusy} = erx_device:irq_bind_owner(B, 0),
      ok = erx_device:stand_in_fire(B, 0),
      receive {erx_irq, A, 0} -> ok after 5000 -> exit(no_delivery) end,
      ok = erx_device:irq_ack(A, 0),
      ok = erx_device:irq_bind_owner(A, 0),
      {ok, D} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [8]}),
      {error, direct} = erx_device:irq_bind_owner(D, 0),
      {error, ebusy} = erx_device:open(#{peripheral => pl011, window => stand_in, lines => [7]}),
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

  OPEN_VIRTIO = '{ok, D} = erx_device:open(#{peripheral => virtio_mmio, window => stand_in, lines => []}), '

  # The runtime's refusal behind the owned-register chokepoint (whose build check has its own
  # seeded violation in chokepoints_device_test.rb): Erlang storing to a register only the NIF
  # stores to, a ring's address among them, is badarg, while a plain register still reads.
  def test_a_register_the_nif_owns_is_badarg_from_erlang
    assert_equal 'ok', evaluate(OPEN_VIRTIO + <<~'ERLANG')
      2 = erx_device:read(D, version),
      [{'EXIT', {badarg, _}} = (catch erx_device:write(D, R, 0)) || R <- [queue_desc_low, queue_ready, status, queue_notify]],
      {'EXIT', {badarg, _}} = (catch erx_device:write_field(D, status, driver_ok, 1)),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # The NIF glue on a virtio stand-in: negotiate/2 takes a Wanted below 2^64 and accepts
  # VERSION_1 alone of what the stand-in offers, and post/4 takes an out segment only as a binary.
  def test_negotiate_and_post_take_only_their_shapes
    assert_equal 'ok', evaluate(OPEN_VIRTIO + <<~'ERLANG')
      {ok, Q} = erx_device:queue_create(D, 0, 8, 64),
      {'EXIT', {badarg, _}} = (catch erx_device:negotiate(D, -1)),
      {'EXIT', {badarg, _}} = (catch erx_device:negotiate(D, 1 bsl 64)),
      {ok, 16#100000000} = erx_device:negotiate(D, 16#ffffffff),
      {'EXIT', {badarg, _}} = (catch erx_device:post(D, Q, 1, [{out, [<<1>>]}])),
      ok = erx_device:post(D, Q, 1, [{out, <<1>>}]),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # A hostile device on a stand-in's queue: after an honest completion, an over-length entry,
  # an index ahead of what is in flight and a foreign head each break the queue, the entries
  # before the bad one still returned, and each negotiate makes it whole again. One chain of an
  # out and an in descriptor on a queue just negotiated has head 0, so descriptor 1 is no head.
  def test_a_malformed_used_entry_breaks_the_queue_until_negotiate
    assert_equal 'ok', evaluate(OPEN_VIRTIO + <<~'ERLANG')
      {ok, Q} = erx_device:queue_create(D, 0, 8, 64),
      Run = fun(Posts, Entries) -> {ok, _} = erx_device:negotiate(D, 0),
                [ok = erx_device:post(D, Q, T, [{out, <<T>>}, {in, 16}]) || T <- lists:seq(1, Posts)],
                ok = erx_device:stand_in_used(D, Q, Entries),
                {erx_device:complete(D, Q), erx_device:complete(D, Q)} end,
      {{ok, [{1, <<_:32>>}]}, {ok, []}} = Run(1, [{next, 4}]),
      {{ok, [{1, <<_:32>>}]}, {error, broken}} = Run(2, [{next, 4}, {next, 17}]),
      {{error, broken}, {error, broken}} = Run(1, [{next, 0}, {next, 0}]),
      {{error, broken}, {error, broken}} = Run(1, [{1, 0}]),
      {error, broken} = erx_device:post(D, Q, 9, [{in, 1}]),
      io:format("~s~n", [ok]), halt().
    ERLANG
  end

  # The driver of a queue the device broke ends; the runtime goes on, and its restart's
  # negotiate returns every buffer the device held, so the restarted driver posts the whole
  # queue again. Each driver posts until the queue is full.
  def test_a_restarted_driver_gets_every_posted_buffer_back
    assert_equal 'ok', evaluate(OPEN_VIRTIO + <<~'ERLANG')
      {ok, Q} = erx_device:queue_create(D, 0, 8, 64), Me = self(),
      Driver = fun() -> {ok, _} = erx_device:negotiate(D, 0),
                   Ok = lists:takewhile(fun(T) -> erx_device:post(D, Q, T, [{in, 64}]) =:= ok end, lists:seq(1, 9)),
                   Me ! {posted, length(Ok)},
                   receive go -> ok end,
                   case erx_device:complete(D, Q) of {error, broken} -> exit(broken) end end,
      Start = fun() -> P = spawn_monitor(Driver), receive {posted, N} -> {P, N} end end,
      {{P1, R1}, 8} = Start(),
      ok = erx_device:stand_in_used(D, Q, [{next, 65}]),
      P1 ! go,
      broken = receive {'DOWN', R1, process, P1, Why} -> Why after 5000 -> exit(driver_lived) end,
      {_, 8} = Start(),
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
