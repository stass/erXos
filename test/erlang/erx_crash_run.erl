%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A crash-state run over FAT (docs/design-crash-states.md, "The checks of one
%% state", "Where it runs and what it reports", "Concurrency and failure"). For each
%% image and workload it records the trace the FAT server sends its window
%% (erx_ram_window), derives each epoch's crash states (erx_crash_states), follows
%% the workload's marks through the model (erx_fs_model) and checks every state:
%%
%% 1. `mount`: erx_fat:mount/2 mounts the state or refuses it with a reason; an
%%    exception fails it.
%% 2. `ownership`: erx_fat:check/1 answers ok; a state refused at step 1 fails here.
%% 3. `obligations`: the tree read through erx_fat meets the obligation at the
%%    state's earliest moment and after each mark between it and the epoch's end.
%% 4. `fsck`: the checker the run is handed as `fsck`, a fun of the state's read
%%    function and its count of sectors answering ok or {error, Why}; none until
%%    `fsck_fat`'s checker, erx_fat_check, joins (design-crash-states, "Packages").
%%
%% States are checked in parallel processes, at most one per scheduler, each under a
%% deadline; one that crashes fails its state alone, and one past its deadline is
%% `timed_out`, which is no pass. Each failure is reported by its image's and
%% workload's names, epoch, choice and first failing step. The first ?RECORDS_MAX
%% failures are written into the output directory the run is handed, with the base
%% image named by its SHA-256, as records replay/2 rebuilds byte for byte; file
%% names come from positions only, never from an image.

-module(erx_crash_run).

-export([run/1, record/2, tree/2, moments/3, judged/2, write_failure/3, replay/2, format/1]).

-define(SECTOR, 512).
-define(STATE_DEADLINE_MS, 60000).
-define(RECORDS_MAX, 4).

%% The run: images [{Label, Base}], workloads [{Name, Ops}], bound and seed per
%% epoch, the output directory, and the optional checker of step 4. It answers the
%% report; it prints a line per cell to the user's terminal.
-spec run(#{images := [{binary(), binary()}], workloads := [{term(), [erx_fs_model:op()]}],
            bound := pos_integer(), seed := integer(), out := file:filename(), fsck => none | fun()}) -> map().
run(#{images := Images, workloads := Workloads, out := Out} = Options) ->
    Cells = [cell(ImageIndex, Image, Workload, Options)
             || {ImageIndex, Image} <- lists:enumerate(Images), Workload <- Workloads],
    Failures = lists:append([F || #{failures := F} <- Cells]),
    Recorded = [write_failure(Out, F, I) || {I, F} <- lists:enumerate(lists:sublist(Failures, ?RECORDS_MAX))],
    #{cells => Cells, states => lists:sum([N || #{checked := N} <- Cells]),
      timed_out => lists:sum([N || #{timed_out := N} <- Cells]), failures => Failures, records => Recorded}.

cell(ImageIndex, {Label, Base}, {Name, Ops}, #{bound := Bound, seed := Seed} = Options) ->
    Trace = record(Base, Ops),
    Obligations = obligations(Trace, Ops, tree(Base, fun(L) -> {ok, binary:part(Base, L * ?SECTOR, ?SECTOR)} end)),
    Epochs = erx_crash_states:epochs(Trace, Base),
    Generated = [{E, erx_crash_states:states(E, #{mode => atomic, bound => Bound, seed => Seed})} || E <- Epochs],
    Jobs = [{E, S} || {E, #{states := States}} <- Generated, S <- States],
    Fsck = maps:get(fsck, Options, none),
    Results = parallel(fun({E, S}) -> checked(Base, E, S, Obligations, Fsck) end, Jobs),
    Failures = [#{image => Label, image_index => ImageIndex, workload => Name, base => Base, trace => Trace,
                  epoch => I, choice => C, step => Step, reason => Why}
                || {{#{index := I}, #{choice := C}}, {fail, Step, Why}} <- lists:zip(Jobs, Results)],
    Cell = #{image => Label, workload => Name, checked => length(Jobs),
             timed_out => length([T || timed_out = T <- Results]), failures => Failures,
             epochs => [#{index => I, count => N, coverage => Cov} || {#{index := I}, #{count := N, coverage := Cov}} <- Generated]},
    io:format(user, "~s~n", [format(Cell)]),
    Cell.

%% ---------------------------------------------------------------------------
%% Recording
%% ---------------------------------------------------------------------------

%% The trace the FAT server sends its window while it runs Ops over Base, a whole
%% medium mounted writable, with the driver's marks around each operation. The
%% volume runs in a process of its own, killed once the last operation answered,
%% so nothing it might still send lands after the trace is taken.
-spec record(binary(), [erx_fs_model:op()]) -> erx_ram_window:trace().
record(Base, Ops) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Parent ! {trace, self(), recorded(Base, Ops)} end),
    receive
        {trace, Pid, Trace} -> erlang:demonitor(Ref, [flush]), Trace;
        {'DOWN', Ref, process, Pid, Why} -> error({recording_failed, Why})
    end.

recorded(Base, Ops) ->
    process_flag(trap_exit, true),
    Window = erx_ram_window:start(Base, #{record => true}),
    ok = erx_media_volume:new_mounts(),
    {ok, Volume} = erx_media_volume:start_link(Window, #{number => 1, first => 0, length => byte_size(Base) div ?SECTOR}),
    #{mount := rw} = erx_media_volume:outcome(Volume),
    lists:foreach(fun({I, Op}) ->
                          ok = erx_ram_window:mark(Window, {'begin', I}),
                          ok = performed(Volume, Op),
                          ok = erx_ram_window:mark(Window, {answered, I})
                  end, lists:enumerate(Ops)),
    exit(Volume, kill),
    receive {'EXIT', Volume, _} -> ok end,
    #{trace := Trace} = erx_ram_window:final(Window),
    Trace.

%% Op through the volume's calls; any answer but the one the model predicts fails
%% the recording.
performed(V, fsync) ->
    ok = erx_media_volume:fsync(V);
performed(V, {create, Path}) ->
    {ok, file, _} = erx_media_volume:create(V, walked(V, lists:droplast(Path)), lists:last(Path)), ok;
performed(V, {mkdir, Path}) ->
    {ok, dir, _} = erx_media_volume:mkdir(V, walked(V, lists:droplast(Path)), lists:last(Path)), ok;
performed(V, {write, Path, Offset, Bytes}) ->
    Size = byte_size(Bytes),
    {ok, Size} = erx_media_volume:write(V, walked(V, Path), Offset, Bytes), ok;
performed(V, {truncate, Path, Size}) ->
    ok = erx_media_volume:truncate(V, walked(V, Path), Size);
performed(V, {remove, Path}) ->
    ok = erx_media_volume:remove(V, walked(V, lists:droplast(Path)), lists:last(Path));
performed(V, {rmdir, Path}) ->
    ok = erx_media_volume:rmdir(V, walked(V, lists:droplast(Path)), lists:last(Path));
performed(V, {rename, From, To}) ->
    ok = erx_media_volume:rename(V, walked(V, lists:droplast(From)), lists:last(From),
                                 walked(V, lists:droplast(To)), lists:last(To)).

walked(V, Path) ->
    {ok, dir, Root} = erx_media_volume:root(V),
    lists:foldl(fun(Name, At) -> {ok, _, Next} = erx_media_volume:walk(V, At, Name), Next end, Root, Path).

%% ---------------------------------------------------------------------------
%% The oracle
%% ---------------------------------------------------------------------------

%% The obligation from each trace position on: the base tree's from 0, and the
%% model's after each mark, at the mark's position.
obligations(Trace, Ops, BaseTree) ->
    {_, Reversed} = lists:foldl(fun({Pos, {Kind, _} = Mark}, {Model, Acc}) when Kind =:= 'begin'; Kind =:= answered ->
                                        Next = erx_fs_model:follow(Mark, Ops, Model),
                                        {Next, [{Pos, erx_fs_model:obligation(Next)} | Acc]};
                                   (_, Acc) -> Acc
                                end, {erx_fs_model:new(BaseTree), [{0, erx_fs_model:obligation(erx_fs_model:new(BaseTree))}]},
                                lists:enumerate(Trace)),
    lists:reverse(Reversed).

%% The obligations a state whose earliest moment is T, in an epoch ending at End,
%% must meet: the one in force at T, and the one after each mark between T and End.
-spec moments(non_neg_integer(), pos_integer(), [{non_neg_integer(), erx_fs_model:obligation()}]) ->
          [{non_neg_integer(), erx_fs_model:obligation()}].
moments(T, End, Obligations) ->
    {Before, After} = lists:partition(fun({Pos, _}) -> Pos =< T end, Obligations),
    [lists:last(Before) | [{Pos, O} || {Pos, O} <- After, Pos < End]].

%% Actual against each of Moments in order: ok, or the first moment it breaks.
-spec judged([{non_neg_integer(), erx_fs_model:obligation()}], erx_fs_model:tree()) ->
          ok | {error, {non_neg_integer(), term()}}.
judged([], _Actual) ->
    ok;
judged([{Pos, Obligation} | Rest], Actual) ->
    case erx_fs_model:judge(Obligation, Actual) of
        ok -> judged(Rest, Actual);
        {error, Why} -> {error, {Pos, Why}}
    end.

checked(Base, #{'end' := End} = Epoch, #{choice := Choice, t := T}, Obligations, Fsck) ->
    Read = erx_crash_states:read_fun(Base, Epoch, Choice),
    Sectors = byte_size(Base) div ?SECTOR,
    try erx_fat:mount(Read, Sectors) of
        {error, Why} -> {fail, ownership, {not_mounted, Why}};
        {ok, Fat} -> mounted(Fat, Read, Sectors, moments(T, End, Obligations), Fsck)
    catch
        Class:Reason -> {fail, mount, {Class, Reason}}
    end.

mounted(Fat, Read, Sectors, Moments, Fsck) ->
    case erx_fat:check(Fat) of
        ok ->
            try judged(Moments, tree(Fat)) of
                ok -> fscked(Fsck, Read, Sectors);
                {error, Why} -> {fail, obligations, Why}
            catch
                throw:{unreadable, _Path, _Why} = Unreadable -> {fail, obligations, Unreadable}
            end;
        Other ->
            {fail, ownership, Other}
    end.

fscked(none, _Read, _Sectors) -> pass;
fscked(Fsck, Read, Sectors) ->
    case Fsck(Read, Sectors) of
        ok -> pass;
        {error, Why} -> {fail, fsck, Why}
    end.

%% The tree of the volume Read reads, or of a mounted Fat: each path with `dir` or
%% its file's bytes. A directory or file the read path refuses is thrown.
-spec tree(binary(), erx_fat:read_sector()) -> erx_fs_model:tree().
tree(Base, Read) ->
    {ok, Fat} = erx_fat:mount(Read, byte_size(Base) div ?SECTOR),
    tree(Fat).

tree(Fat) ->
    walked_dir(Fat, [], erx_fat:root(Fat), #{[] => dir}).

walked_dir(Fat, Path, Node, Acc) ->
    Entries = case erx_fat:list(Node, Fat) of
                  {ok, Es} -> Es;
                  {error, Why} -> throw({unreadable, Path, Why})
              end,
    lists:foldl(fun({Name, Child}, A) ->
                        P = Path ++ [Name],
                        case erx_fat:attr(Child) of
                            #{kind := dir} -> walked_dir(Fat, P, Child, A#{P => dir});
                            #{kind := file, size := Size} -> A#{P => {file, file_bytes(Fat, P, Child, Size)}}
                        end
                end, Acc, Entries).

file_bytes(Fat, Path, Node, Size) ->
    case erx_fat:read(Node, 0, Size, Fat) of
        {ok, Bytes} when byte_size(Bytes) =:= Size -> Bytes;
        {ok, Short} -> throw({unreadable, Path, {short_read, byte_size(Short), Size}});
        {error, Why} -> throw({unreadable, Path, Why})
    end.

%% ---------------------------------------------------------------------------
%% Parallel checks
%% ---------------------------------------------------------------------------

%% Fun over Jobs, at most one process per scheduler at a time, in order: each its
%% answer, {fail, crash, Why} when it crashed, or timed_out past its deadline.
parallel(Fun, Jobs) ->
    Width = erlang:system_info(schedulers_online),
    collected(Fun, lists:enumerate(Jobs), Width, #{}, #{}).

collected(_Fun, [], _Width, Running, Done) when map_size(Running) =:= 0 ->
    [Answer || _ := Answer <- maps:iterator(Done, ordered)];
collected(Fun, [{I, Job} | Rest], Width, Running, Done) when map_size(Running) < Width ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Parent ! {checked, self(), Fun(Job)} end),
    Timer = erlang:start_timer(?STATE_DEADLINE_MS, self(), {deadline, Pid}),
    collected(Fun, Rest, Width, Running#{Pid => {I, Ref, Timer}}, Done);
collected(Fun, Jobs, Width, Running, Done) ->
    receive
        {checked, Pid, Answer} when is_map_key(Pid, Running) ->
            {I, Ref, Timer} = maps:get(Pid, Running),
            erlang:demonitor(Ref, [flush]), erlang:cancel_timer(Timer),
            collected(Fun, Jobs, Width, maps:remove(Pid, Running), Done#{I => Answer});
        {'DOWN', _Ref, process, Pid, Why} when is_map_key(Pid, Running) ->
            {I, _, Timer} = maps:get(Pid, Running),
            erlang:cancel_timer(Timer),
            collected(Fun, Jobs, Width, maps:remove(Pid, Running), Done#{I => {fail, crash, Why}});
        {timeout, _Timer, {deadline, Pid}} when is_map_key(Pid, Running) ->
            {I, Ref, _} = maps:get(Pid, Running),
            erlang:demonitor(Ref, [flush]), exit(Pid, kill),
            collected(Fun, Jobs, Width, maps:remove(Pid, Running), Done#{I => timed_out})
    end.

%% ---------------------------------------------------------------------------
%% Failure records and replay
%% ---------------------------------------------------------------------------

%% Failure written into Out as the Index-th record: the base image once, named by its
%% SHA-256, then the record and the failing image. Answers the record's path.
-spec write_failure(file:filename(), map(), pos_integer()) -> file:filename().
write_failure(Out, #{base := Base, trace := Trace, epoch := Epoch, choice := Choice, step := Step,
                     image_index := ImageIndex} = Failure, Index) ->
    Sha = sha256(Base),
    BasePath = filename:join(Out, base_name(Sha)),
    ok = case filelib:is_regular(BasePath) of true -> ok; false -> file:write_file(BasePath, Base) end,
    %% The image as the check read it, through the state's read function, which
    %% replay/2's rebuild through erx_crash_states:image/4 does not share.
    [E] = [E || #{index := I} = E <- erx_crash_states:epochs(Trace, Base), I =:= Epoch],
    Read = erx_crash_states:read_fun(Base, E, Choice),
    Image = iolist_to_binary([element(2, Read(Lba)) || Lba <- lists:seq(0, byte_size(Base) div ?SECTOR - 1)]),
    Stem = filename:join(Out, io_lib:format("failure-~b-~b", [Index, ImageIndex])),
    ok = file:write_file([Stem, ".img"], Image),
    Record = #{version => erx_crash_states:version(), base_sha256 => Sha, trace => Trace, mode => atomic,
               epoch => Epoch, choice => Choice, step => Step, workload => maps:get(workload, Failure),
               image_sha256 => sha256(Image)},
    ok = file:write_file([Stem, ".term"], term_to_binary(Record)),
    lists:flatten([Stem, ".term"]).

%% The image the record at Path names, rebuilt from the base in Out, its trace, its
%% epoch and its choice alone, compared with the failing image beside the record.
-spec replay(file:filename(), file:filename()) ->
          ok | {error, {version, binary(), binary()} | {base_sha256, binary(), binary()} | differs}.
replay(Path, Out) ->
    {ok, Bytes} = file:read_file(Path),
    #{version := Version, base_sha256 := Sha, trace := Trace, epoch := Epoch, choice := Choice} =
        binary_to_term(Bytes, [safe]),
    Ours = erx_crash_states:version(),
    {ok, Base} = file:read_file(filename:join(Out, base_name(Sha))),
    {ok, Failing} = file:read_file(filename:rootname(Path) ++ ".img"),
    case {Version, sha256(Base)} of
        {Ours, Sha} ->
            case erx_crash_states:image(Base, Trace, Epoch, Choice) of
                Failing -> ok;
                _ -> {error, differs}
            end;
        {Ours, Other} -> {error, {base_sha256, Sha, Other}};
        _ -> {error, {version, Version, Ours}}
    end.

base_name(Sha) -> <<"base-", Sha/binary, ".img">>.

sha256(Bytes) -> binary:encode_hex(crypto:hash(sha256, Bytes), lowercase).

%% ---------------------------------------------------------------------------
%% The report
%% ---------------------------------------------------------------------------

%% One cell's line: its image and workload, each epoch's coverage, the states checked
%% and each failure. What an image holds reaches the terminal escaped.
-spec format(map()) -> iodata().
format(#{image := Label, workload := Name, checked := Checked, timed_out := TimedOut, failures := Failures,
         epochs := Epochs}) ->
    Coverage = [coverage(E) || E <- Epochs],
    [io_lib:format("~s ~0p: ~b states, ~b timed_out, ~b failing; epochs ~s", [Label, Name, Checked, TimedOut,
                                                                             length(Failures),
                                                                             lists:join(", ", Coverage)])
     | [["\n  ", failure_line(F)] || F <- lists:sublist(Failures, 3)]].

coverage(#{index := I, count := N, coverage := exhaustive}) ->
    io_lib:format("~b exhaustive ~b", [I, N]);
coverage(#{index := I, coverage := {sampled, K, M, Seed, Version}}) ->
    io_lib:format("~b sampled ~b of ~b seed ~b version ~s", [I, K, M, Seed, Version]).

failure_line(#{epoch := Epoch, choice := Choice, step := Step, reason := Why}) ->
    erx_text:escape_line(iolist_to_binary(io_lib:format("epoch ~b choice ~0p: ~s: ~0p", [Epoch, Choice, Step, Why]))).
