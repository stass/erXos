# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# A program's handler (docs/design-programs.md, "The handler"): its pure core,
# erx_prog_handler_core, by test/erlang/erx_prog_handler_core_tests.erl, and its
# effect process, erx_prog_handler, with the real pipe server over a fake pipe NIF
# and stand-ins (test/erlang/stand_in) for the program driver, the pixel allocator
# and the NIF calls the handler makes, by
# test/erlang/erx_prog_handler_tests.erl. The core's resolve of an executable file
# walks the EROFS reader's fixture images (erx_erofs_tests). Each seeded fault must
# fail the EUnit case named beside it.
class ErxProgHandlerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_files].freeze
  TESTS = %w[test/erlang/erx_pipe_fake_nif.erl test/erlang/erx_prog_handler_fakes.erl
             test/erlang/stand_in/erx_win.erl test/erlang/stand_in/erx_draw_conn.erl
             erlang/apps/erx_session/src/erx_session_export.erl build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
             test/erlang/stand_in/erx_program.erl test/erlang/stand_in/erx_pixels.erl
             test/erlang/stand_in/erx_pipe_nif.erl test/erlang/stand_in/erx_file_description.erl build/gen/otp/erts/preloaded/src/erx_prog.erl otp/erts/preloaded/src/erx_path.erl
             build/gen/otp/erts/preloaded/src/erx_prog_grammar.erl
             otp/erts/preloaded/src/erx_erofs.erl otp/erts/preloaded/src/erx_verity.erl
             otp/erts/preloaded/src/erx_verity_tree.erl test/erlang/host_bytes/erx_bytes.erl
             otp/erts/preloaded/src/erx_file_remote.erl test/erlang/erx_erofs_tests.erl
             test/erlang/erx_prog_handler_core_tests.erl test/erlang/erx_prog_handler_tests.erl].freeze
  SUITES = %w[erx_prog_handler_core_tests erx_prog_handler_tests].freeze
  # The reader's fixture images, which the core's resolve cases mount at /app.
  FIXTURES = File.join(ROOT, 'test/fixtures/erofs')
  INCLUDES = %w[otp/lib/kernel/include].freeze
  CORE = 'erlang/apps/erx/src/erx_prog_handler_core.erl'
  HANDLER = 'erlang/apps/erx/src/erx_prog_handler.erl'
  EXPORT = 'erlang/apps/erx_session/src/erx_session_export.erl'

  def test_the_handler_starts_forwards_and_ends
    text, ok = run_eunit({})
    assert ok, text
    assert_match(/All \d+ tests passed/, text)
  end

  # A seeded fault: the file it edits, the text it replaces and its replacement,
  # and the EUnit case that must catch it.
  Mutant = Data.define(:file, :original, :replacement, :caught_by)
  MUTANTS = {
    'an image check that admits an entry without rx' =>
      Mutant.new(file: CORE, original: 'image_check(#{rights := rx} = Entry, Names) ->',
                 replacement: 'image_check(#{rights := _} = Entry, Names) ->', caught_by: 'an ro entry is eacces'),
    'a resolve that follows a link beneath the mount' =>
      Mutant.new(file: CORE, original: 'unfollowed(_Entry, _Names) -> {error, eacces}.',
                 replacement: 'unfollowed(#{provider := {erofs, Fs}}, Names) -> erx_erofs:read_link(Fs, Names).',
                 caught_by: 'a last link is never followed'),
    'a /dev tree grant that does not end with the handler' =>
      Mutant.new(file: EXPORT, original: '#{client => own, ends_with => self()}', replacement: '#{client => own}',
                 caught_by: 'a_refused_windowed_start_ends_what_it_made'),
    'a first window that fails once opening answers the errno and keeps the handler' =>
      Mutant.new(file: CORE,
                 original: "first_window(C, _Slot, _Case, _Path, _Flags, _Mode, {failed, Errno}) when is_atom(Errno) ->\n" \
                           '    {C#core{phase = {ended, {shutdown, {window, Errno}}}, queue = queue:new()}, []}.',
                 replacement: "first_window(C, Slot, Case, _Path, _Flags, _Mode, {failed, Errno}) when is_atom(Errno) ->\n" \
                              '    file_reply(C, Case, Slot, {error, Errno}).',
                 caught_by: 'a_first_draw_the_connection_refuses_ends_the_program'),
    'a window check against the export names of a program without a window' =>
      Mutant.new(file: CORE, original: '|| Dir := Names <- exported(Window), Name <- Names]',
                 replacement: '|| Dir := Names <- exported(), Name <- Names]', caught_by: 'window_test_'),
    'a window whose /dev entry is not capped at a read-only entry at /dev itself' =>
      Mutant.new(file: CORE, original: '{not writes_dev(Window, Table), eacces}', replacement: '{false, eacces}',
                 caught_by: 'window_test_'),
    'a window capped at the deepest entry covering /dev, which refuses a table with none at /dev' =>
      Mutant.new(file: CORE,
                 original: 'writes_dev({window, _}, Table) -> lists:all(fun(Rights) -> Rights =:= rw end, dev_rights(Table)).',
                 replacement: 'writes_dev({window, _}, Table) -> ' \
                              'case deepest_entry(Table, [<<"dev">>]) of #{rights := rw} -> true; _ -> false end.',
                 caught_by: 'window_test_'),
    'a window admitted to a table with no room for its /dev' =>
      Mutant.new(file: CORE, original: 'length(without_dev(Table)) < ?ERX_NS_MOUNTS_MAX',
                 replacement: 'length(without_dev(Table)) =< ?ERX_NS_MOUNTS_MAX', caught_by: 'window_test_'),
    'a narrowing that drops the starter mounts below the narrowed path' =>
      Mutant.new(file: CORE, original: "     | Below];", replacement: "     | []];", caught_by: 'narrowing_test_'),
    'a narrowed path that keeps the starter entry root, so the program reaches above it' =>
      Mutant.new(file: CORE, original: 'root := Root ++ lists:nthtail(length(Point), Place)', replacement: 'root := Root',
                 caught_by: 'narrowing_test_'),
    'a narrowing that grants rights the starter lacks' =>
      Mutant.new(file: CORE, original: "  when Rights =:= Own; Rights =:= ro ->\n    Below",
                 replacement: "  when is_atom(Own) ->\n    Below", caught_by: 'narrowing_test_'),
    'a read answer longer than its count copied into the slot' =>
      Mutant.new(file: CORE, original: '{ok, Bytes}) when byte_size(Bytes) =< Count ->', replacement: '{ok, Bytes}) when is_integer(Count) ->',
                 caught_by: 'read_longer_than_its_count_is_eio'),
    'O_NOFOLLOW refused as a flag the protocol lacks' =>
      Mutant.new(file: CORE, original: 'bor ?ERX_P9_O_DIRECTORY bor ?ERX_P9_O_NOFOLLOW)).',
                 replacement: 'bor ?ERX_P9_O_DIRECTORY)).', caught_by: 'directory_and_nofollow_are_relayed_test_'),
    'an lcreate with O_EXCL and O_DIRECTORY admitted' =>
      Mutant.new(file: CORE, original: 'Case =:= file_lcreate, Flags band ?EXCL_DIRECTORY =:= ?EXCL_DIRECTORY ->',
                 replacement: 'Case =:= file_lcreate, Flags band ?EXCL_DIRECTORY =:= -1 ->',
                 caught_by: 'unknown_open_flags_are_einval_test_'),
    'an lcreate with O_DIRECTORY relayed to create' =>
      Mutant.new(file: CORE, original: 'create_mode(Flags, _Mode) when Flags band ?ERX_P9_O_DIRECTORY =/= 0 -> none;',
                 replacement: 'create_mode(Flags, _Mode) when Flags band ?ERX_P9_O_DIRECTORY =:= -1 -> none;',
                 caught_by: 'directory_and_nofollow_are_relayed_test_'),
    'a getattr field the server did not give sent as known' =>
      Mutant.new(file: CORE, original: 'maps:filter(fun(_, Value) -> is_integer(Value) end,',
                 replacement: 'maps:map(fun(_, Value) -> if is_integer(Value) -> Value; true -> 0 end end,',
                 caught_by: 'getattr_answers_the_attributes_given'),
    'a getattr nlink past its field sent' =>
      Mutant.new(file: CORE, original: "        {error, {range, _}} -> reply(C, file_getattr, Slot, {error, eoverflow})\n",
                 replacement: "        {error, {range, _}} -> reply(C, file_getattr, Slot, {ok, \#{}})\n",
                 caught_by: 'getattr_past_a_field_is_eoverflow'),
    'a data slot past the program slots admitted' =>
      Mutant.new(file: CORE, original: 'true when Data >= Slots ->', replacement: 'true when Data > Slots ->',
                 caught_by: 'data_slot_past_the_program_slots_is_einval'),
    'a refused start that keeps its hand-offs' =>
      Mutant.new(file: CORE, original: '[{hand_drop, Number} || {_, {pipe_hand, Number, _}} <- Made] ++',
                 replacement: '[] ++', caught_by: 'refused_start_undoes_everything'),
    'a busy send treated as taken, so a newer frame passes the owed one' =>
      Mutant.new(file: CORE, original: "{C#core{out = owed}, []};\n",
                 replacement: "pump(drop_head(C));\n", caught_by: 'owed_report_waits_for_room'),
    'a stop asked again at every stop event' =>
      Mutant.new(file: CORE, original: 'stop(C, _Status) -> {C, []}.',
                 replacement: 'stop(C, Status) -> {C, [{end_program, Status}]}.', caught_by: 'stop_once_then_exit'),
    'a kill that reaches a process beyond the program' =>
      Mutant.new(file: CORE, original: 'reach(_C, _Target) -> none.', replacement: 'reach(_C, _Target) -> self.',
                 caught_by: 'kill_beyond_reach_is_esrch'),
    'a kill of itself answered ok without a signal sent' =>
      Mutant.new(file: CORE, original: 'reply(C, kill, Slot, {error, enosys})', replacement: 'reply(C, kill, Slot, ok)',
                 caught_by: 'kill_of_itself_with_another_signal_is_enosys'),
    'a continue signal taken for one of the program\'s own' =>
      Mutant.new(file: CORE, original: 'when Action =:= stop; Action =:= continue ->', replacement: 'when Action =:= stop ->',
                 caught_by: 'kill_of_itself_with_a_job_control_signal_is_eperm'),
    'a frame the grammar refuses read anyway' =>
      Mutant.new(file: CORE, original: '{error, _} -> stop(C, ?REFUSED_STATUS)', replacement: '{error, _} -> from_program(C, Frame)',
                 caught_by: 'refused_frames_stop_the_program'),
    'pipe2 ignoring O_CLOEXEC: the flags dropped before the pipe server' =>
      Mutant.new(file: CORE, original: '[{make_pipe, Flags}]', replacement: '[{make_pipe, []}]',
                 caught_by: 'pipe_asks_the_pipe_server_with_the_programs_flags'),
    'an install that leaks the first hand-off when the second is refused' =>
      Mutant.new(file: CORE, original: '[PipeEnd || {pipe, _, PipeEnd, _} <- lists:reverse(Done)] ++',
                 replacement: '[] ++',
                 caught_by: 'pipe_install_refused_second_closes_both_ends'),
    'a refused install that keeps the hand-off not yet installed' =>
      Mutant.new(file: CORE, original: '[{hand_drop, Number} || {pipe_hand, Number, _} <- Hands] ++',
                 replacement: '[] ++',
                 caught_by: 'pipe_install_refused_first_closes_both_ends'),
    'a reply sent at once, ahead of the frame out' =>
      Mutant.new(file: CORE, original: '    pump(enqueue(C, {frame, Frame})).',
                 replacement: '    {C, [{send, Frame}]}.', caught_by: 'replies_queue_behind_the_frame_out'),
    'a starter whose exit leaves its program running' =>
      Mutant.new(file: HANDLER, original: "{'DOWN', _, process, Starter, _} -> stop;",
                 replacement: '', caught_by: 'starters_exit_stops_the_program'),
    'a handler that stays after its program ends' =>
      Mutant.new(file: HANDLER, original: "            ok = log_end(Pid, Reason),\n            exit(Reason);\n",
                 replacement: "            ok = log_end(Pid, Reason),\n            receive after infinity -> ok end;\n",
                 caught_by: 'exit_is_the_monitors_down'),
    'a handler that exits normal, which the starter reads as a lost status' =>
      Mutant.new(file: HANDLER, original: '            exit(Reason);', replacement: '            exit(normal);',
                 caught_by: 'exit_is_the_monitors_down'),
    'a handler that reports sigkill for every stop, which loses the exit 3' =>
      Mutant.new(file: CORE, original: 'erx_prog:status(Status)',
                 replacement: 'erx_prog:status(case C#core.stopping of true -> ?STOP_STATUS; false -> Status end)',
                 caught_by: 'an_end_behind_a_closed_port_keeps_its_status'),
    'a start past its deadline that leaves its handler holding the range and the holder entry' =>
      Mutant.new(file: HANDLER,
                 original: "        exit(Handler, kill),\n        receive {'DOWN', Watch, process, Handler, _} -> ok end,\n",
                 replacement: '',
                 caught_by: 'a_start_past_its_deadline_frees_what_it_holds'),
    'a refused start that keeps the program\'s holder entry, so its ends are never gone' =>
      Mutant.new(file: CORE, original: "        [holder_drop].\n", replacement: "        [].\n",
                 caught_by: 'an_end_of_another_process_is_refused'),
    'a builder that drops a display by its mount point, which keeps the bind of it' =>
      Mutant.new(file: CORE,
                 original: "on_window_tree(\#{provider := {Kind, _, ?ERX_WINDOWS_TREE_BYTES}})\n  when Kind =:= grant; Kind =:= facet ->",
                 replacement: 'on_window_tree(#{point := [<<"n">>, <<"display">>]}) ->',
                 caught_by: 'no_window_tree_test_'),
    'a first draw that takes an entry at /dev for the shared /dev, which opens a window on its grant' =>
      Mutant.new(file: CORE, original: '#{point := Point} -> Point =:= []',
                 replacement: '#{point := Point} -> length(Point) =< 1', caught_by: 'first_window_test_'),
    'a check that refuses only an entry exactly at an export name' =>
      Mutant.new(file: CORE, original: 'lists:any(fun(Name) -> lists:prefix(Name, Point) end, Names)',
                 replacement: 'lists:member(Point, Names)', caught_by: 'export_names_test_'),
    'an open number scan that starts past 0' =>
      Mutant.new(file: CORE, original: 'Open = lowest_free(0, Opens),', replacement: 'Open = lowest_free(1, Opens),',
                 caught_by: 'opens_take_the_lowest_free_number_in_every_order_test_'),
    'a first open of /dev/draw waiting for its window that the open bound does not count' =>
      Mutant.new(file: CORE, original: '+ length([Waiting || {opening, _, _, _, _, _, _} = Waiting <- [First]]),',
                 replacement: '+ 0 * length([First]),',
                 caught_by: 'an_open_waiting_for_its_window_counts_toward_the_bound_test'),
    'a clunk that does not free its number' =>
      Mutant.new(file: CORE, original: '{Desc, Rest} -> relay(C#core{opens = Rest}, Slot, file_clunk,',
                 replacement: '{Desc, _Rest} -> relay(C, Slot, file_clunk,',
                 caught_by: 'opens_take_the_lowest_free_number_in_every_order_test_')
  }.freeze

  # Seeded runs at once: each compiles and runs the suites in its own directory; one after
  # another they come near the host tests' per-file deadline.
  MUTANT_JOBS = 6

  def test_seeded_faults_are_caught
    sources = MUTANTS.values.map(&:file).uniq.to_h { |file| [file, File.read(File.join(ROOT, file))] }
    MUTANTS.each do |name, mutant|
      assert_equal 1, sources.fetch(mutant.file).scan(mutant.original).size,
                   "mutant #{name} must edit exactly one place"
    end
    runs = MUTANTS.each_slice(MUTANT_JOBS).flat_map do |slice|
      slice.map do |name, mutant|
        seeded = sources.fetch(mutant.file).sub(mutant.original) { mutant.replacement }
        Thread.new { [name, mutant, *run_eunit({ mutant.file => seeded })] }
      end.map(&:value)
    end
    runs.each do |name, mutant, text, ok|
      refute ok, "seeded fault not caught: #{name}"
      # Verbose EUnit names every case, so only the named case's failure line counts.
      assert_match(/#{mutant.caught_by}.*\*failed\*/, text, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  # The suites' text and whether they passed, with replaced's sources in place of the tree's.
  def run_eunit(replaced)
    Dir.mktmpdir('erx-prog-handler-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced, includes: INCLUDES)
      eval_text = "halt(case eunit:test([#{SUITES.join(', ')}], [verbose]) of ok -> 0; _ -> 1 end)."
      text, status = Open3.capture2e({ 'ERX_EROFS_FIXTURES' => FIXTURES }, 'gtimeout', '-k', '10', '180',
                                     ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      [text, status.success?]
    end
  end
end
