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
(kind, cause, addr, pc, thread, space, status); for a fault it also has
fault, the same fields of the fault record whose stop ended the domain,
the kernel's own record of where the fault struck (its pc, cause and
addr; for an asynchronous error the addr is not valid, and the thread,
and so the pc, is only the one that ran when the error was taken,
presumed to be its source). Every other outcome is
the return value of the call that caused it.

A refused call is {error, Name}, Name the ABI file's status name with an
e before it (einval, enomem, ebusy, enotsup), or {error, {status, N}} for
a status the ABI file does not name. info/2 alone answers {error, N}, the
status number, as erx_object_info:info/3 does, since erx_kernel_records
takes both alike. Where there is no library, in a domain's runtime and a
hosted runtime, the module loads all the same and every well-formed call
is {error, enotsup}, register/0 included, and info/2 {error, ?ERX_ENOTSUP}. It does not load a second time, since its library,
lock and fault thread live as long as the system domain.

The registered process, the domain service, is also the only one that may
change the library: create/1, configured/3, session/5, app_session/6, start/1, stop/2, retire/1,
connect/6 and disconnect/1 answer {error, erights} to any other caller, and
so does crash/1, which reads a domain's crash dump. info/2 answers any
caller, since a group's or budget's report holds none of the domain's data,
and so do pci_report/2, the PCIe catalogue's intake, pci_bridges/0, its
read, pci_mode/2, the write of a PCIe function's mode, pci_answered/1,
the write of the incarnation answered, and firmware/2, a bridge's
notification or a power line's phase, whose caller is the device service.
""".

-export([register/0, create/1, start/1, stop/2, retire/1, crash/1, info/2, connect/6, disconnect/1,
         configured/0, configured/3, templates/0, apps/0, devices/0, session/5, app_session/6, code_object/2,
         code_drop/2, end_commit/1, pci_report/2, pci_bridges/0, pci_mode/2, pci_answered/1,
         firmware/2]).
-nifs([register_nif/0, create_nif/1, start_nif/1, stop_nif/2, retire_nif/1, crash_nif/1, info_nif/3, connect_nif/6,
       disconnect_nif/1, configured_nif/0, configured_create_nif/3, templates_nif/0, apps_nif/0, devices_nif/0,
       session_create_nif/5, app_session_create_nif/6, code_object_nif/2, code_drop_nif/2,
       end_commit_nif/1, pci_report_nif/2, pci_bridges_nif/0, pci_mode_nif/2, pci_answered_nif/1,
       bridge_firmware_nif/1, power_nif/2]).
-on_load(on_load/0).

-include("generated/erx_abi.hrl").

-export_type([spec/0, created/0, error/0, configured/0, template/0, apps/0, device/0, pci_place/0,
              pci_catalogue/0, pci_layout/0]).

-type error() :: {error, atom() | {status, integer()}}.
%% A group's grant (erx_grant_t): its quota_ns, cpuset and slice_us, and its
%% period_ns and capacity_mcpu, each 0 when left out, so a capped grant (a quota
%% other than ERX_QUOTA_NONE) names its period. The slice is the quantum of the
%% group's threads, ERX_SLICE_MIN_US .. ERX_SLICE_MAX_US. The library admits it as
%% design-system.md's "A grant fits its parent" states.
-type grant() :: #{quota_ns := non_neg_integer(), cpuset := non_neg_integer(),
                   slice_us := non_neg_integer(),
                   period_ns => non_neg_integer(), capacity_mcpu => non_neg_integer()}.
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
lanes the domain and the system domain read. supervised is the supervised bit of the boot
information the library wrote (docs/design-live.md, "Overlays"), which erx_dom_plan_boot_flags
decides; Erlang code reads it here and never recomputes it.
""".
-type created() :: #{id := pos_integer(), connection := non_neg_integer(), side := non_neg_integer(),
                     peer_side := non_neg_integer(), bell := non_neg_integer(),
                     reader := non_neg_integer(), system_lane := non_neg_integer(),
                     ctl_slots := non_neg_integer(), domain_pid_number := non_neg_integer(),
                     domain_pid_serial := non_neg_integer(), supervised := boolean()}.

-doc """
A configured domain of the system manifest: its row in the manifest's domain
table, its place in the boot order (from 0), its name, an identifier the
manifest check accepted, its principal, its kind, its restart intensity:
at most restarts restarts within restart_period_s seconds, and the drive
windows on its placed devices, the drives it serves, each its drive number
and the configured row that holds the window, the drive grant's grantee
(docs/design-drives.md, "How the grant reaches the media domain").
""".
-type configured() :: #{row := non_neg_integer(), place := non_neg_integer(), name := binary(),
                        principal := pos_integer(), kind := service | secret,
                        restarts := non_neg_integer(), restart_period_s := non_neg_integer(),
                        drives := [{Drive :: non_neg_integer(), Holder :: non_neg_integer()}]}.

-doc """
A session template of the system manifest, from which each session of its
principal is made on request: its index among the templates and its
principal, which has no other. It is no configured domain, and the boot
creates none.
""".
-type template() :: #{template := non_neg_integer(), principal := pos_integer()}.

-doc "The apps row's app entries in the library's view (apps/0).".
-type apps() :: #{template := non_neg_integer(), first := pos_integer(),
                  max := pos_integer(), memory := pos_integer()}.

-doc """
An entry of the device catalogue the system manifest's device table makes:
its index, the manifest's device row; its unit row; the configured row its
unit is placed on, or system; its role word, or none for a kind no runtime
drives; and the domain that holds it: a living domain of that row, system
for the system domain's devices, or none while the row has no living domain.
What /dev shows of it as well: its unit's manifest name; its kind's
compatible string, none when its role is none; its registers, the
{Address, Bytes} of its register window, or unknown for a PCIe function,
whose configuration space gives them; its ranges, the {Base, Bytes} of
each run of whole pages its registers touch, which a give maps; its
interrupt lines, as the platform's interrupt controller numbers them,
none listed for a PCIe function; whether it is confined, that is, has an
IOMMU stream; and for a PCIe function its place, by which the device
service matches a report to its row, and its setting, each none for every
other device.
""".
-type device() :: #{index := non_neg_integer(), unit := non_neg_integer(),
                    unit_name := binary(),
                    row := non_neg_integer() | system, role := block | net | none,
                    compatible := binary() | none,
                    registers := {Address :: non_neg_integer(), Bytes :: pos_integer()} | unknown,
                    ranges := [{Base :: non_neg_integer(), Bytes :: pos_integer()}],
                    lines := [non_neg_integer()], confined := boolean(),
                    holder := pos_integer() | system | none,
                    place := pci_place() | none, setting := erx_abi_layout:erx_pcie_setting() | none}.

-doc "A PCIe function's place: its host bridge's device row, and its bus, device and function there.".
-type pci_place() :: {Bridge :: non_neg_integer(), Bus :: 0..255, Device :: 0..31, Function :: 0..7}.

-doc """
A host bridge's catalogue (docs/design-pcie.md, "The catalogue and gives"):
its record, whether its firmware notification timed out, the PCIe
incarnation whose report the device service last answered, or none, and
its layouts in its placing report's order.
""".
-type pci_catalogue() :: #{bridge := erx_abi_layout:erx_pcie_bridge(), firmware_lost := boolean(),
                           answered := pos_integer() | none, layouts := [pci_layout()]}.

-doc """
A layout: the function as the placing report gave it, its state that
report's; the latest report's state, none when that report did not list it;
and whether the latest report listed it with its layout.
""".
-type pci_layout() :: #{record := erx_abi_layout:erx_pcie_function(),
                        state := erx_abi_enums:pcie_state() | none, confirmed := boolean()}.

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
Domain Id's group or budget report, as erx_object_info:info/3 gives one
for an object the inspector holds: {ok, Bytes} for erx_schema:decode_report/2,
or {error, Status} with the refusal's status number. The domain library
asks on its own handle, which never leaves it, and the backend answers:
ERX_ENOTSUP where it cannot report that object, and ERX_EINVAL for a
domain neither built nor running.
""".
-spec info(group | budget, pos_integer()) -> erx_kernel_records:answer().
info(Kind, Id) when Kind =:= group; Kind =:= budget ->
    {ok, #{topic := Topic, size := Size}} = erx_schema:report_layout(Kind),
    info_nif(Id, Topic, Size).

-doc """
Connects domains A and B, A reading a ring of AReads bytes and B one of
BReads, with a pixel area of Area bytes, whole pages, that AreaReader,
A or B, maps read-only and the other writes (docs/design-display.md,
"The pixel area"), or none for Area and AreaReader 0:
{ok, #{number => N, a => Party, b => Party}}, each Party the side,
peer_side, peer_bell, label and area in that domain's own table, area
none or {Handle, Bytes, write | read}.
""".
-spec connect(pos_integer(), pos_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
              non_neg_integer()) ->
          {ok, #{number := pos_integer(), a := map(), b := map()}} | error().
connect(A, B, AReads, BReads, Area, AreaReader) ->
    connect_nif(A, B, AReads, BReads, Area, AreaReader).

-doc "Destroys connection Number's child budgets, with its sides, bells and pixel area.".
-spec disconnect(pos_integer()) -> ok | error().
disconnect(Number) ->
    disconnect_nif(Number).

-doc """
What the domain service reads of the system manifest at boot. boot_timeout_s
is the machine's boot timeout: the seconds each domain's init has to report
ready unless its request sets its own, from 1 to the manifest reader's
boot_timeout_max_s. The rest: the machine's
host name, the configured domains, in row order, the services, each its
server, a configured domain's row or system, its name and the abi/services
number of the interface it serves (erx_abi.hrl's ERX_SERVICE_* macros, so
a holder's driver-control facet is found by ?ERX_SERVICE_DRIVER_CONTROL),
and the facet rows, each
its grantee, a configured row, system, or {template, Template} for the
sessions made from session template Template, the service's name, its server, a
configured row or system, and the grant's limits: the facet row's
max_request, in_flight, reductions, period_ns, max_heap_size and queue, its
operations as the list of their abi/services names in number order, empty for
a row of `operations none`, and
each parameter the row states under its abi/services name, an integer as an
integer, a boolean as true or false, text or bytes as a binary, and a device
reference as the index of its row in the manifest's device table
(docs/design-system.md, "Facets a configured domain serves").
""".
-spec configured() -> {ok, #{host := binary(), boot_timeout_s := pos_integer(), domains := [configured()],
                             services := [{non_neg_integer() | system, atom(), non_neg_integer()}],
                             grants := [{non_neg_integer() | system | {template, non_neg_integer()}, atom(),
                                         non_neg_integer() | system, map()}]}}
                    | error().
configured() ->
    configured_nif().

-doc """
The system manifest's session templates, in principal order, but the app
template, which names no principal and apps/0 names.
""".
-spec templates() -> {ok, [template()]} | error().
templates() ->
    templates_nif().

-doc """
The apps row as the library placed it at boot (docs/design-packaging.md,
"An app's principal"): none for a manifest with no apps row, or the app
template's index, the first app entry's principal number, max, the app
entries the boot holds, and the apps budget in bytes. It is the one source
of max: the domain service bounds the registry of app principals by it, and
admission is to be given the same max (docs/design-packaging.md, "An app's
principal").
""".
-spec apps() -> {ok, none | apps()} | error().
apps() ->
    apps_nif().

-doc """
Ends the machine, off or reset, as the last step of its ordered end
(docs/design-system.md, "Shutting down"); it returns only a refusal, and
{error, enotsup} where there is no library, in a domain's runtime and a
hosted one. Any process may ask it, as any process of the system domain may
end the machine with erlang:halt/0: init asks it once its shutdown has
stopped the domain service.
""".
-spec end_commit(off | reset) -> error().
end_commit(off) ->
    end_commit_nif(?ERX_END_OFF);
end_commit(reset) ->
    end_commit_nif(?ERX_END_RESET).

-doc """
The device catalogue, in the manifest's device order, with each device's holder.
""".
-spec devices() -> {ok, [device()]} | error().
devices() ->
    case devices_nif() of
        {ok, Devices} -> {ok, [Device#{setting := setting(Setting)} || #{setting := Setting} = Device <- Devices]};
        Error -> Error
    end.

-doc """
The PCIe domain's report on the host bridge of device row Bridge, which the
device service hands on whole (docs/design-pcie.md, "The catalogue and
gives"), into that bridge's catalogue: every function the walk found, as
the erx_pcie_function maps of erx_abi_layout. ok when the intake took it;
{error, {einval, Record, Field}} when it refused it whole, Record the
refused function's index in Functions counted from 0 (with Field bridge
for a row with no catalogue, the list's length or the unread function's
index) and Field the field it
names. A report the library cannot read is refused whole all the same, so
no earlier report's confirmation survives it: more functions than a bridge
holds, with Field functions and Record the list's length, and a function
that does not encode, with Field record.
""".
-spec pci_report(non_neg_integer(), [erx_abi_layout:erx_pcie_function()]) ->
          ok | {error, {einval, non_neg_integer(), atom()}} | error().
pci_report(Bridge, Functions) ->
    pci_report_nif(Bridge, [function_bytes(Function) || Function <- Functions]).

%% A function's bytes, or none for one that does not encode, which the intake
%% refuses as a record it cannot read. Every exception of the encoder means a
%% map it does not take, so a defect of the encoder itself would show as that
%% refusal, which fails safe: it unconfirms the bridge's every layout.
function_bytes(Function) ->
    try
        erx_abi_layout:encode(erx_pcie_function, Function)
    catch
        error:_ -> none
    end.

-doc """
Every host bridge's catalogue, in device row order (docs/design-pcie.md,
"The catalogue and gives"), from which the device service answers the PCIe domain's
targets, with devices/0 for every pci row's setting.
""".
-spec pci_bridges() -> {ok, [pci_catalogue()]} | error().
pci_bridges() ->
    case pci_bridges_nif() of
        {ok, Bridges} -> {ok, [catalogue(Bridge) || Bridge <- Bridges]};
        Error -> Error
    end.

-doc """
Writes Mode into the setting of device row Index, a pci row
(docs/design-pcie.md, "Concurrency"): off, a lowering, which the device
service writes before it sends it, or decoding or mastering, a raise,
written after the PCIe domain's ok. The route stays the give's. ok, or
{error, einval} for a row that is not a pci row, or a raise of a function
no living domain holds or its catalogue does not give; another Mode is a
function_clause error.
""".
-spec pci_mode(non_neg_integer(), erx_abi_enums:pcie_mode()) -> ok | error().
pci_mode(Index, Mode) ->
    pci_mode_nif(Index, erx_abi_enums:value(pcie_mode, Mode)).

-doc """
Records PCIe incarnation D as answered in the catalogue of every host bridge
it holds (docs/design-pcie.md, "Facets", "Concurrency"): the device service
writes it before it sends the answer to D's report, and reads it back from
pci_bridges/0 when it restarts. ok, or {error, einval} when D holds no
bridge.
""".
-spec pci_answered(pos_integer()) -> ok | error().
pci_answered(D) ->
    pci_answered_nif(D).

-doc """
Makes a firmware request of device row Device (docs/design-system.md,
"Firmware requests"; docs/design-fiasco.md, "The firmware request"), the
device service's firmware worker its caller. Request is `bridge`, the
notification of a host bridge row (docs/design-usb.md, "The VL805's
firmware"), or `{power, Phase}`, a phase of fw_power_phase of the power line
of a device whose manifest row carries the line's times
(docs/design-bluetooth.md, "The power line"). The library offers each only
to such a row, and sends the row the manifest lists for it, so the caller
chooses neither the tag nor its words. The request runs in the calling
process's dirty I/O scheduler, up to its 1 s deadline, outside the
library's lock; a bridge's {error, etimedout} marks it firmware_lost for the
boot, and every later request answers the same. ok, or {error, Name}:
enotsup for a request the row does not offer or a root with no mailbox,
einval for a row past the catalogue, ebusy, etimedout or eproto as the
firmware answered.
""".
-spec firmware(non_neg_integer(), bridge | {power, erx_abi_enums:fw_power_phase()}) -> ok | error().
firmware(Device, bridge) ->
    bridge_firmware_nif(Device);
firmware(Device, {power, Phase}) ->
    power_nif(Device, erx_abi_enums:value(fw_power_phase, Phase)).

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
create/1 builds a request's domain, with Display, the service name of its
default display or none, as its `display` variable after the template's
environment (docs/design-display.md, "Choosing a display"). Everything
else is the template's and its limits record's, which the library judges
against the template's principal as it judges a request: its ceilings,
share, budget and domain quota, and SPACES, which a session's limits must
hold.
""".
-spec session(pos_integer(), non_neg_integer(), binary(), atom(), pid()) -> {ok, created()} | error().
session(Id, Template, Name, none, DomainPid) ->
    session_create_nif(Id, Template, Name, <<>>, DomainPid);
session(Id, Template, Name, Display, DomainPid) ->
    session_create_nif(Id, Template, Name, atom_to_binary(Display), DomainPid).

-doc """
An app's session's start (docs/design-packaging.md, "An app's session"):
builds a session of the app in app entry Entry, from the app template
under the entry's principal, with Memory, the declared memory of the app's
record, for its own budget, as session/5 builds a template's session, under
id Id, name Name, domain pid DomainPid and Display, its default display or
none. The library plans no other template for an app entry, and refuses
the start as erx_dom_plan_app_session does (include/erx/dom.h): einval for
an entry past apps/0's max or a memory that is 0, not page-aligned or past
the apps budget, elimit for an app already running a session, and enomem
for a session the apps budget does not hold beside the others.
""".
-spec app_session(pos_integer(), non_neg_integer(), pos_integer(), binary(), atom(), pid()) ->
          {ok, created()} | error().
app_session(Id, Entry, Memory, Name, none, DomainPid) ->
    app_session_create_nif(Id, Entry, Memory, Name, <<>>, DomainPid);
app_session(Id, Entry, Memory, Name, Display, DomainPid) ->
    app_session_create_nif(Id, Entry, Memory, Name, atom_to_binary(Display), DomainPid).

-doc """
A session's code object (include/erx/dom_lib.h, erx_dom_lib_code_object):
{ok, Number, Cap}, a paged object of Size bytes rounded up to a page, made
from the session's own budget, and Cap its copy in the session's table,
which can be filled, sealed and run but never written through a mapping or
destroyed; {error, elimit} with code_objects_max live, {error, enomem} for
the budget or for a size no page count holds, {error, einval} for a session
neither built nor running. Size and, for code_drop/2, Number are within the
bounds erx_code_objects_facet:decode/1 holds a request to, the facet being
the one caller.
""".
-spec code_object(pos_integer(), pos_integer()) -> {ok, pos_integer(), non_neg_integer()} | error().
code_object(Session, Size) ->
    code_object_nif(Session, Size).

-doc "Deletes a session's code object Number: ok, or {error, einval} for a number that names none of its live objects.".
-spec code_drop(pos_integer(), pos_integer()) -> ok | error().
code_drop(Session, Number) ->
    code_drop_nif(Session, Number).

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

code_object_nif(_Session, _Size) ->
    erlang:nif_error(undef).

code_drop_nif(_Session, _Number) ->
    erlang:nif_error(undef).

crash_nif(_Id) ->
    erlang:nif_error(undef).

info_nif(_Id, _Topic, _Size) ->
    erlang:nif_error(undef).

connect_nif(_A, _B, _AReads, _BReads, _Area, _AreaReader) ->
    erlang:nif_error(undef).

disconnect_nif(_Number) ->
    erlang:nif_error(undef).

configured_nif() ->
    erlang:nif_error(undef).

configured_create_nif(_Id, _Row, _DomainPid) ->
    erlang:nif_error(undef).

templates_nif() ->
    erlang:nif_error(undef).

apps_nif() ->
    erlang:nif_error(undef).

devices_nif() ->
    erlang:nif_error(undef).

session_create_nif(_Id, _Template, _Name, _Display, _DomainPid) ->
    erlang:nif_error(undef).

app_session_create_nif(_Id, _Entry, _Memory, _Name, _Display, _DomainPid) ->
    erlang:nif_error(undef).

end_commit_nif(_How) ->
    erlang:nif_error(undef).

pci_report_nif(_Bridge, _Records) ->
    erlang:nif_error(undef).

pci_bridges_nif() ->
    erlang:nif_error(undef).

pci_mode_nif(_Index, _Mode) ->
    erlang:nif_error(undef).

pci_answered_nif(_D) ->
    erlang:nif_error(undef).

bridge_firmware_nif(_Bridge) ->
    erlang:nif_error(undef).

power_nif(_Device, _Phase) ->
    erlang:nif_error(undef).

%% The library hands records as the bytes its generated encoders write, which
%% the generated codec reads: the records' one form in Erlang.
catalogue({Bridge, FirmwareLost, Answered, Layouts}) ->
    #{bridge => decoded(erx_pcie_bridge, Bridge), firmware_lost => FirmwareLost, answered => answered(Answered),
      layouts => [#{record => decoded(erx_pcie_function, Record), state => state(State), confirmed => Confirmed}
                  || {Record, State, Confirmed} <- Layouts]}.

answered(0) -> none;
answered(D) -> D.

state(0) -> none;
state(State) -> {ok, Name} = erx_abi_enums:name(pcie_state, State), Name.

setting(none) -> none;
setting(Setting) -> decoded(erx_pcie_setting, Setting).

decoded(Layout, Bytes) ->
    {ok, Record} = erx_abi_layout:decode(Layout, Bytes),
    Record.
