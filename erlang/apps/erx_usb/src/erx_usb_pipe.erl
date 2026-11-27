%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_pipe).
-moduledoc """
A function's pipes (docs/design-usb.md, "Transfers and pipes"): how a
function process submits transfers through its controller process. A pipe
names its controller, its device's reference and its endpoint's address;
the bus process makes one for each pipe a function claims, with new/3, and
hands the function its own pipes alone at start.

control/3 sends one request on a device's EP0 and waits for its answer,
`{ok, Bytes}` or `{error, Reason}`, `{error, gone}` should the controller
end first. interrupt_in/3 posts one interrupt-IN transfer; its completion arrives as
the message `{usb, Pipe, Tag, Result}`, Result `{ok, Bytes}` or `{error,
Reason}`, so a function keeps its transfers posted and waits in its own
receive. bulk_in/3 and bulk_out/3 post one bulk transfer the same way,
each completion carrying what the controller reports moved: the bytes
read, or the count written. reset_pipe/1 brings both sides of a pipe back
to the start of its data toggle, as one operation of the controller, and
waits for its answer, `ok` or the error that ended it. post_control/3
and post_reset_pipe/1 send the same requests without waiting: the answer
arrives as `{Ref, Answer}` under the reference they return, and the
sender bounds the wait itself. The controller answers a pipe whose
device is detached `{error, gone}`.

Each request reaches the controller as `{erx_usb_pipe, From, Request}`,
and reply/2 builds the message that answers it; this module is the one
that spells both.
""".

-export([new/3, endpoint/1, control/3, post_control/3, interrupt_in/3, bulk_in/3, bulk_out/3, reset_pipe/1,
         post_reset_pipe/1, reply/2,
         from_function/1]).

-export_type([pipe/0, request/0]).

-opaque pipe() :: {pipe, Controller :: pid(), erx_usb_bus_core:ref(), Address :: byte()}.

-doc "A request as it reaches the controller, from the process that sent it.".
-type request() :: {control, pipe(), <<_:64>>, none | {in, pos_integer()} | {out, binary()}, reference()}
                 | {interrupt_in | bulk_in, pipe(), term(), pos_integer()}
                 | {bulk_out, pipe(), term(), binary()}
                 | {reset_pipe, pipe(), reference()}.

-doc "The pipe of endpoint Address of device Ref, served by Controller.".
-spec new(pid(), erx_usb_bus_core:ref(), byte()) -> pipe().
new(Controller, Ref, Address) when is_pid(Controller), is_integer(Address), Address >= 0, Address =< 255 ->
    {pipe, Controller, Ref, Address}.

-doc "The device reference and endpoint address Pipe names, as the controller reads them.".
-spec endpoint(pipe()) -> {erx_usb_bus_core:ref(), byte()}.
endpoint({pipe, _Controller, Ref, Address}) ->
    {Ref, Address}.

-doc """
Sends the control request Setup, with the data stage Data, on Pipe, a
device's EP0, and answers the controller's answer.
""".
-spec control(pipe(), <<_:64>>, none | {in, pos_integer()} | {out, binary()}) -> {ok, binary()} | {error, term()}.
control(Pipe, Setup, Data) ->
    await(Pipe, fun(Monitor) -> {control, Pipe, Setup, Data, Monitor} end).

-doc "Resets Pipe, a bulk or interrupt pipe, and answers `ok` or the error that ended the reset.".
-spec reset_pipe(pipe()) -> ok | {error, term()}.
reset_pipe(Pipe) ->
    await(Pipe, fun(Monitor) -> {reset_pipe, Pipe, Monitor} end).

-doc """
Sends the control request Setup as control/3 does, without waiting: its answer arrives as
`{Ref, Answer}`, Ref the reference this returns. The sender bounds the wait itself; a
controller that ends first sends no answer.
""".
-spec post_control(pipe(), <<_:64>>, none | {in, pos_integer()} | {out, binary()}) -> reference().
post_control(Pipe, Setup, Data) ->
    post(Pipe, fun(Ref) -> {control, Pipe, Setup, Data, Ref} end).

-doc "Resets Pipe as reset_pipe/1 does, without waiting: its answer arrives as `{Ref, Answer}`.".
-spec post_reset_pipe(pipe()) -> reference().
post_reset_pipe(Pipe) ->
    post(Pipe, fun(Ref) -> {reset_pipe, Pipe, Ref} end).

post({pipe, Controller, _Ref, _Address}, Build) ->
    Ref = make_ref(),
    Controller ! {?MODULE, self(), Build(Ref)},
    Ref.

%% Sends the request Build makes under a monitor of the controller and waits for its answer.
await({pipe, Controller, _Ref, _Address}, Build) ->
    Monitor = monitor(process, Controller),
    Controller ! {?MODULE, self(), Build(Monitor)},
    receive
        {Monitor, Answer} -> demonitor(Monitor, [flush]), Answer;
        {'DOWN', Monitor, process, Controller, _Reason} -> {error, gone}
    end.

-doc """
The message that answers Request with Result, which the controller sends
to the request's sender: a control request's answer under its monitor, an
interrupt-IN or bulk transfer's completion as `{usb, Pipe, Tag, Result}`.
""".
-spec reply(request(), term()) -> term().
reply({control, _Pipe, _Setup, _Data, Monitor}, Result) -> {Monitor, Result};
reply({reset_pipe, _Pipe, Monitor}, Result) -> {Monitor, Result};
reply({Kind, Pipe, Tag, _Length}, Result) when Kind =:= interrupt_in; Kind =:= bulk_in -> {usb, Pipe, Tag, Result};
%% An OUT transfer that completes without an error moved every byte posted: the
%% controller reports a short packet only on IN (xHCI 4.10.1.1; unverified here), so the
%% count is the data's.
reply({bulk_out, Pipe, Tag, Data}, {ok, _Bytes}) -> {usb, Pipe, Tag, {ok, byte_size(Data)}};
reply({bulk_out, Pipe, Tag, _Data}, Failure) -> {usb, Pipe, Tag, Failure}.

-doc """
The sender and the request a message to the controller carries, or `none` for a message
that did not come this way.
""".
-spec from_function(term()) -> {ok, pid(), request()} | none.
from_function({?MODULE, From, Request}) -> {ok, From, Request};
from_function(_Other) -> none.

-doc "Posts one interrupt-IN transfer of up to Length bytes on Pipe; its completion is `{usb, Pipe, Tag, Result}`.".
-spec interrupt_in(pipe(), term(), pos_integer()) -> ok.
interrupt_in(Pipe = {pipe, Controller, _Ref, _Address}, Tag, Length) when is_integer(Length), Length > 0 ->
    Controller ! {?MODULE, self(), {interrupt_in, Pipe, Tag, Length}},
    ok.

-doc "Posts one bulk-IN transfer of Length bytes on Pipe; its completion is `{usb, Pipe, Tag, Result}`.".
-spec bulk_in(pipe(), term(), pos_integer()) -> ok.
bulk_in(Pipe = {pipe, Controller, _Ref, _Address}, Tag, Length) when is_integer(Length), Length > 0 ->
    Controller ! {?MODULE, self(), {bulk_in, Pipe, Tag, Length}},
    ok.

-doc """
Posts Data as one bulk-OUT transfer on Pipe; its completion is `{usb, Pipe, Tag, {ok, Count}}`
or the failure. Only erx_blk_write calls it, the one write path of a medium
(docs/design-usb.md, "The block transport").
""".
-spec bulk_out(pipe(), term(), binary()) -> ok.
bulk_out(Pipe = {pipe, Controller, _Ref, _Address}, Tag, Data) when is_binary(Data), byte_size(Data) > 0 ->
    Controller ! {?MODULE, self(), {bulk_out, Pipe, Tag, Data}},
    ok.
