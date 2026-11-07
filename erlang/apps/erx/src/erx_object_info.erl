%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_object_info).
-moduledoc """
erx_object_info and erx_info_partial of the system domain's own liberx
(docs/design-stopgap.md, "Reporting kernel objects"). info/3 gives a
report's bytes, which erx_schema:decode_report/2 takes apart, and the
collector erx_kernel_records turns into records.
""".

-export([info/3, partial/1]).
-nifs([info_nif/4, partial_nif/1]).
-on_load(on_load/0).

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc "The report of Kind for Object and Index, as bytes, or the refusal's status number.".
-spec info(atom(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | {error, integer()}.
info(Kind, Object, Index) ->
    {ok, #{topic := Topic, size := Size}} = erx_schema:report_layout(Kind),
    info_nif(Object, Topic, Index, Size).

-doc "The reported bits of Kind's report that liberx's backend counts only partly.".
-spec partial(atom()) -> non_neg_integer().
partial(Kind) ->
    {ok, #{topic := Topic}} = erx_schema:report_layout(Kind),
    partial_nif(Topic).

info_nif(_Object, _Topic, _Index, _Size) ->
    erlang:nif_error(undef).

partial_nif(_Topic) ->
    erlang:nif_error(undef).
