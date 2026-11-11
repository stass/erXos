%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_lib).
-moduledoc """
The domain service's way into the system domain's domain library
(docs/design-system.md, "The domain library"): dirty CPU NIFs over
liberx's erx_dom_lib entries, under the library's one lock.

The library reports with one kind of message, which its fault thread sends
to the process that called register/0, once a domain has ended and its own budget
is gone:

    {domain_ended, Id, {Kind, Status}, Record}

Kind is halt, crash, fault or stopped; Status is the halt status, or the
fault's kind for a fault. Record is the exit record's fields by name
(kind, cause, addr, pc, thread, space, status). Every other outcome is the
return value of the call that caused it.

A refused call is {error, Name}, Name the ABI file's status name with an
e before it (einval, enomem, ebusy, enotsup), or {error, {status, N}} for
a status the ABI file does not name. Where there is no library, in a
domain's runtime and a hosted runtime, the module loads all the same and
every well-formed call is {error, enotsup}, register/0 included. It does not load a second time, since its library,
lock and fault thread live as long as the system domain.

The registered process, the domain service, is also the only one that may
change the library: create/1, configured/3, session/4, start/1, stop/2, retire/1,
connect/4 and disconnect/1 answer {error, erights} to any other caller, and
so does crash/1, which reads a domain's crash dump.
""".

-export([register/0, create/1, start/1, stop/2, retire/1, crash/1, connect/4, disconnect/1,
         configured/0, configured/3, templates/0, devices/0, session/4, code_object/2, code_drop/2]).
-nifs([register_nif/0, create_nif/1, start_nif/1, stop_nif/2, retire_nif/1, crash_nif/1, connect_nif/4,
       disconnect_nif/1, configured_nif/0, configured_create_nif/3, templates_nif/0, devices_nif/0,
       session_create_nif/4]).
-on_load(on_load/0).

-export_type([spec/0, created/0, error/0, configured/0, template/0, device/0]).

-type error() :: {error, atom() | {status, integer()}}.
-type grant() :: #{quota_ns := non_neg_integer(), cpuset := non_neg_integer(),
                   capacity_mcpu => non_neg_integer()}.
-type limits() :: #{max_frame => non_neg_integer(), max_message_heap => non_neg_integer(),
                    funnel_depth => non_neg_integer(), exports => non_neg_integer(),
                    tmp => non_neg_integer(), overlay => non_neg_integer(),
                    atoms => non_neg_integer(), foreign_atoms => non_neg_integer(),
                    processes => non_neg_integer(), peer_held => non_neg_integer(),
                    peer_held_total => non_neg_integer()}.
-doc """
An admitted request (erx_dom_spec_t): the domain's id, which the domain
service allocates, its name, the identifier its node name carries before
the @ and the host, its principal, its domain pid, the process of this node
the domain service made for it, which the domain's boot page names, the boot image's indexes of its runtime
image and its release's first file with the release's file count, its own
and outer budgets' bytes, its group's grant, its lane's data area, and its
arguments and environment as NUL-ended strings. Optional are its
connections quota (0), its flags (0), the sub-space group's grant, which is
given exactly when flags hold ERX_DOM_SPACES, and the runtime limits it
sets, each one it leaves out being its principal's default. The library
sets the system lane and the crash area itself. A map with a key not named
here, a value of the wrong kind or width, or strings beyond the boot page's
room is badarg; the library validates every value against its view before
it makes anything.
""".
-type spec() :: #{id := pos_integer(), name := binary(), principal := pos_integer(), domain_pid := pid(),
                  runtime := non_neg_integer(),
                  release := non_neg_integer(), release_files := non_neg_integer(),
                  memory := non_neg_integer(), outer := non_neg_integer(), grant := grant(),
                  lane := non_neg_integer(), args := binary(), env := binary(),
                  connections => non_neg_integer(), flags => non_neg_integer(),
                  spaces => grant(), limits => limits()}.
-doc """
A created domain: its id and the system domain's values of its connection. connection is
its number, 0 for none, and also the label the system domain's bell is bound with; side,
the domain's side, and bell, the domain's bell, are slots of the system domain's table;
peer_side is the system domain's side; reader and system_lane are the data areas of the
lanes the domain and the system domain read.
""".
-type created() :: #{id := pos_integer(), connection := non_neg_integer(), side := non_neg_integer(),
                     peer_side := non_neg_integer(), bell := non_neg_integer(),
                     reader := non_neg_integer(), system_lane := non_neg_integer(),
                     ctl_slots := non_neg_integer(), domain_pid_number := non_neg_integer(),
                     domain_pid_serial := non_neg_integer()}.

-doc """
A configured domain of the system manifest: its row in the manifest's domain
table, its place in the boot order (from 0), its name, an identifier the
manifest check accepted, its principal, its kind, its restart intensity:
at most restarts restarts within restart_period_s seconds, and the seconds
its init has to report ready, from 1 to the manifest reader's
boot_timeout_max_s.
""".
-type configured() :: #{row := non_neg_integer(), place := non_neg_integer(), name := binary(),
                        principal := pos_integer(), kind := service | secret,
                        restarts := non_neg_integer(), restart_period_s := non_neg_integer(),
                        boot_timeout_s := pos_integer()}.

-doc """
A session template of the system manifest, from which each session of its
principal is made on request: its index among the templates and its
principal, which has no other. It is no configured domain, and the boot
creates none.
""".
-type template() :: #{template := non_neg_integer(), principal := pos_integer()}.

-doc """
An entry of the device catalogue the system manifest's device table makes:
its index, the manifest's device row; its unit row; the configured row its
unit is placed on, or system; its role word, or none for a kind no runtime
drives; and the domain that holds it: a living domain of that row, system
for the system domain's devices, or none while the row has no living domain.
""".
-type device() :: #{index := non_neg_integer(), unit := non_neg_integer(),
                    row := non_neg_integer() | system, role := block | net | none,
                    holder := pos_integer() | system | none}.

on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

-doc """
Makes the caller the process that hears of every end and the one that may
change the library. While another registered process is alive the answer
is {error, ebusy}, and where there is no library it is {error, enotsup}.
""".
-spec register() -> ok | error().
register() ->
    register_nif().

-doc """
Plans and builds a domain from Spec. A create by any process but the
registered one is {error, erights}, so no end goes unheard. A refused step undoes every step
before it.
""".
-spec create(spec()) -> {ok, created()} | error().
create(Spec) ->
    create_nif(Spec).

-doc "Starts a built domain's first thread.".
-spec start(pos_integer()) -> ok | error().
start(Id) ->
    start_nif(Id).

-doc "Stops a built or running domain's space; its end arrives as stopped.".
-spec stop(pos_integer(), integer()) -> ok | error().
stop(Id, Status) ->
    stop_nif(Id, Status).

-doc "Frees an ended domain's record once its connections are disconnected; {error, ebusy} before.".
-spec retire(pos_integer()) -> ok | error().
retire(Id) ->
    retire_nif(Id).

-doc """
Ended domain Id's crash area, read before its retire: {ok, Slogan, Dump,
Truncated}, the slogan and the dump text as the domain wrote them, which
are untrusted text and reach a terminal or a log only through that sink's
escaping. {error, ecorrupt} for a header that fails the reader's checks,
{error, einval} for a domain not ended or without a crash area, and
{error, erights} to any caller but the domain service, since the dump
holds the domain's data.
""".
-spec crash(pos_integer()) -> {ok, binary(), binary(), boolean()} | error().
crash(Id) ->
    crash_nif(Id).

-doc """
Connects domains A and B, A reading a ring of AReads bytes and B one of
BReads: {ok, #{number => N, a => Party, b => Party}}, each Party the
side, peer_side, peer_bell and label in that domain's own table.
""".
-spec connect(pos_integer(), pos_integer(), non_neg_integer(), non_neg_integer()) ->
          {ok, #{number := pos_integer(), a := map(), b := map()}} | error().
connect(A, B, AReads, BReads) ->
    connect_nif(A, B, AReads, BReads).

-doc "Destroys connection Number's child budgets, with its sides and bells.".
-spec disconnect(pos_integer()) -> ok | error().
disconnect(Number) ->
    disconnect_nif(Number).

-doc """
What the domain service reads of the system manifest at boot: the machine's
host name, the configured domains, in row order, the services configured
domains serve, each its server's row and its name, and the facet rows, each
its grantee, a configured row, system, or {template, Template} for the
sessions made from session template Template, the service's name, its server, a
configured row or system, and the grant's limits (docs/design-system.md,
"Facets a configured domain serves").
""".
-spec configured() -> {ok, #{host := binary(), domains := [configured()],
                             services := [{non_neg_integer(), atom()}],
                             grants := [{non_neg_integer() | system | {template, non_neg_integer()}, atom(),
                                         non_neg_integer() | system, map()}]}}
                    | error().
configured() ->
    configured_nif().

-doc """
The system manifest's session templates, in principal order.
""".
-spec templates() -> {ok, [template()]} | error().
templates() ->
    templates_nif().

-doc """
The device catalogue, in the manifest's device order, with each device's holder.
""".
-spec devices() -> {ok, [device()]} | error().
devices() ->
    devices_nif().

-doc """
Manifest startup and restart: builds configured row Row under id Id and
domain pid DomainPid, as create/1 builds a request's domain. The domain service calls it from its
manifest startup and restart with a row configured/0 gave, never a row a
request names.
""".
-spec configured(pos_integer(), non_neg_integer(), pid()) -> {ok, created()} | error().
configured(Id, Row, DomainPid) ->
    configured_create_nif(Id, Row, DomainPid).

-doc """
A session's start: builds a session of template Template, an index
templates/0 gave, under id Id, name Name and domain pid DomainPid, as
create/1 builds a request's domain. Everything else is the template's and
its limits record's, which the library judges against the template's
principal as it judges a request: its ceilings, share, budget and domain
quota, and SPACES, which a session's limits must hold.
""".
-spec session(pos_integer(), non_neg_integer(), binary(), pid()) -> {ok, created()} | error().
session(Id, Template, Name, DomainPid) ->
    session_create_nif(Id, Template, Name, DomainPid).

-doc "A session's code object: {error, enotsup} until sessions exist.".
-spec code_object(pos_integer(), non_neg_integer()) -> {ok, map()} | error().
code_object(_Session, _Size) ->
    {error, enotsup}.

-doc "Deletes a session's code object: {error, enotsup} until sessions exist.".
-spec code_drop(pos_integer(), non_neg_integer()) -> ok | error().
code_drop(_Session, _Number) ->
    {error, enotsup}.

register_nif() ->
    erlang:nif_error(undef).

create_nif(_Spec) ->
    erlang:nif_error(undef).

start_nif(_Id) ->
    erlang:nif_error(undef).

stop_nif(_Id, _Status) ->
    erlang:nif_error(undef).

retire_nif(_Id) ->
    erlang:nif_error(undef).

crash_nif(_Id) ->
    erlang:nif_error(undef).

connect_nif(_A, _B, _AReads, _BReads) ->
    erlang:nif_error(undef).

disconnect_nif(_Number) ->
    erlang:nif_error(undef).

configured_nif() ->
    erlang:nif_error(undef).

configured_create_nif(_Id, _Row, _DomainPid) ->
    erlang:nif_error(undef).

templates_nif() ->
    erlang:nif_error(undef).

devices_nif() ->
    erlang:nif_error(undef).

session_create_nif(_Id, _Template, _Name, _DomainPid) ->
    erlang:nif_error(undef).
