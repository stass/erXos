%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_vt_oracle).
-moduledoc """
erx_vt's side of the differential test against libvterm
(docs/design-display.md, "The oracle"): runs the corpus script that
test/vt/vterm_dump.c reads, `new COLS ROWS`, `feed N` and its N bytes, and
`dump`, and writes what vterm_dump writes: at each `dump`, erx_vt:dump/1,
then `reply HEX` (or `reply -`) for the replies since the last dump, then
`end`.
""".

-export([main/0, run/2]).

%% The script and output paths are the emulator's plain arguments.
-spec main() -> ok.
main() ->
    [Script, Output] = init:get_plain_arguments(),
    run(Script, Output).

-spec run(file:filename(), file:filename()) -> ok.
run(Script, Output) ->
    {ok, Bytes} = file:read_file(Script),
    ok = file:write_file(Output, lists:reverse(script(Bytes, none, [], []))).

script(<<>>, _VT, _Replies, Out) ->
    Out;
script(Bytes, VT, Replies, Out) ->
    [Line, Rest] = binary:split(Bytes, <<"\n">>),
    case binary:split(Line, <<" ">>, [global]) of
        [<<"new">>, Cols, Rows] ->
            script(Rest, erx_vt:new(binary_to_integer(Cols), binary_to_integer(Rows)), [], Out);
        [<<"feed">>, Count] ->
            N = binary_to_integer(Count),
            <<Fed:N/binary, After/binary>> = Rest,
            {Next, Effects} = erx_vt:feed(VT, Fed),
            script(After, Next, [Replies | [Reply || {reply, Reply} <- Effects]], Out);
        [<<"dump">>] ->
            Reply = case iolist_to_binary(Replies) of
                        <<>> -> <<"-">>;
                        Answered -> binary:encode_hex(Answered, lowercase)
                    end,
            ok = erx_vt:check(VT),
            script(Rest, VT, [], [[erx_vt:dump(VT), "reply ", Reply, "\nend\n"] | Out])
    end.
