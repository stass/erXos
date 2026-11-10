%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_host).
-moduledoc """
`host name [server]`: looks a name or an address up in the DNS, as
FreeBSD's host(1) does, with its lines, so a script written for FreeBSD
reads the same answers.

Queries. An address, IPv4 or IPv6, is looked up by its pointer name
(`D.C.B.A.in-addr.arpa`, or the nibbles under `ip6.arpa`). A name is
looked up for its A records, then its AAAA records. A name that ends in
a dot is tried as it is; any other name is tried with each domain of
inet_db's search list appended, after the name itself if it has a dot,
before it otherwise, as res_search(3) tries them, and the
first that is not NXDOMAIN is the one answered. Queries go through
inet_res to inet_db's name servers, or only to `server`, an address or a
name looked up first, which a header names as FreeBSD's does.

Output, one line per record of the answers:

    www.erxos.test is an alias for web.erxos.test.
    web.erxos.test has address 192.0.2.10
    web.erxos.test has IPv6 address 2001:db8::10
    10.2.0.192.in-addr.arpa domain name pointer web.erxos.test.

An alias the A and AAAA answers both carry is written once. A name with
no such record writes `Host name not found: 3(NXDOMAIN)`, and the other
DNS failures their own code and name in the same line; no answer from
any server writes `;; connection timed out; no servers could be
reached`. Each ends the command with a failure status.

Every name in a line comes from a DNS reply, which any host on the path
can forge, so it passes the field escape (erx_text:escape_field/1), as
do the arguments written back. The plan of queries and the lines are a
pure core, candidates/3, reverse/1, answer_lines/1, failure_line/2 and
server_lines/2, which the tests drive directly; run/2 sends the queries
and writes the lines.
""".

-behaviour(erx_cmd).
-erx_command(host).
-erx_usage("host name [server]").
%% The resolver sends its queries through the network stack, a service of
%% the system domain, which a session reaches only through its net facet.
-erx_needs([net]).

-export([run/2]).
-export([candidates/3, reverse/1, answer_lines/1, failure_line/2, server_lines/2]).

-export_type([rr/0]).

-define(DNS_PORT, 53).
%% res_search(3)'s default: a name with a dot is tried as it is first.
-define(NDOTS, 1).

-type rr() :: {Type :: atom(), Owner :: string(), Data :: term()}.

-spec run([binary()], erx_cmd:ctx()) -> ok | {error, term()}.
run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "") of
        {ok, [], [Name]} ->
            lookup(Ctx, binary_to_list(Name), []);
        {ok, [], [Name, Server]} ->
            with_server(Ctx, binary_to_list(Name), Server);
        _ ->
            {error, usage}
    end.

with_server(Ctx, Name, Server) ->
    case inet:getaddr(binary_to_list(Server), inet) of
        {ok, Address} ->
            ok = erx_cmd:write(Ctx, server_lines(Server, Address)),
            lookup(Ctx, Name, [{nameservers, [{Address, ?DNS_PORT}]}]);
        {error, Reason} ->
            ok = erx_cmd:say(Ctx, [<<"host: couldn't get address for '">>,
                                   erx_text:escape_field(Server), <<"': not found\n">>]),
            {error, {reported, Reason}}
    end.

lookup(Ctx, Name, Opts) ->
    case inet:parse_strict_address(Name) of
        {ok, Address} -> answer(Ctx, reverse(Address), [ptr], Opts);
        {error, einval} -> search(Ctx, Name, candidates(Name, search_list(), ?NDOTS), Opts)
    end.

%% The first candidate whose A query is not NXDOMAIN is answered; when every one is,
%% the name as typed is the one not found.
search(Ctx, Name, [Candidate | Rest], Opts) ->
    case query(Candidate, a, Opts) of
        {error, nxdomain} when Rest =/= [] -> search(Ctx, Name, Rest, Opts);
        {error, nxdomain} -> failed(Ctx, Name, nxdomain);
        {error, Reason} -> failed(Ctx, Candidate, Reason);
        {ok, ARecords} -> answer(Ctx, Candidate, ARecords, [aaaa], Opts)
    end.

%% Queries Name for each of Types in turn and writes every record found, in the order
%% found. A type answered NXDOMAIN after records were found, as some servers answer an
%% AAAA query for a name with only an A record, is passed over; any other failure, or
%% NXDOMAIN with nothing found, writes the failure line instead and fails the command.
answer(Ctx, Name, Types, Opts) ->
    answer(Ctx, Name, [], Types, Opts).

answer(Ctx, _Name, Records, [], _Opts) ->
    erx_cmd:write(Ctx, answer_lines(Records));
answer(Ctx, Name, Records, [Type | Types], Opts) ->
    case query(Name, Type, Opts) of
        {ok, More} -> answer(Ctx, Name, Records ++ More, Types, Opts);
        {error, nxdomain} when Records =/= [] -> answer(Ctx, Name, Records, Types, Opts);
        {error, Reason} -> failed(Ctx, Name, Reason)
    end.

failed(Ctx, Name, Reason) ->
    case failure_line(Name, Reason) of
        {ok, Line} -> ok = erx_cmd:write(Ctx, Line);
        error -> ok = erx_cmd:report(Ctx, erx_text:escape_field(list_to_binary(Name)), Reason)
    end,
    {error, {reported, Reason}}.

%% The answer section of a reply to the query, as records; the failures inet_res reports
%% with the reply attached are reported without it.
query(Name, Type, Opts) ->
    case inet_res:resolve(Name, in, Type, Opts) of
        {ok, Msg} -> {ok, [rr(RR) || RR <- inet_dns:msg(Msg, anlist)]};
        {error, {Reason, _Msg}} -> {error, Reason};
        {error, Reason} -> {error, Reason}
    end.

rr(RR) ->
    {inet_dns:rr(RR, type), inet_dns:rr(RR, domain), inet_dns:rr(RR, data)}.

search_list() ->
    inet_db:res_option(search).

%% --- The pure core ----------------------------------------------------------------

-doc """
The names res_search(3) tries for `Name`, in order: only the name, less
its dot, when it ends in one; else the name and each search domain
appended to it, the name first when it has at least `Ndots` dots.
""".
-spec candidates(string(), [string()], non_neg_integer()) -> [string()].
candidates(Name, Search, Ndots) ->
    case lists:reverse(Name) of
        [$. | Rest] when Rest =/= [] ->
            [lists:reverse(Rest)];
        _ ->
            Searched = [Name ++ "." ++ Domain || Domain <- Search],
            case length([C || C <- Name, C =:= $.]) >= Ndots of
                true -> [Name | Searched];
                false -> Searched ++ [Name]
            end
    end.

-doc "The pointer name of an address, under `in-addr.arpa` or `ip6.arpa`.".
-spec reverse(inet:ip_address()) -> string().
reverse({A, B, C, D}) ->
    lists:flatten(io_lib:format("~b.~b.~b.~b.in-addr.arpa", [D, C, B, A]));
reverse({_, _, _, _, _, _, _, _} = Address) ->
    Nibbles = [N || <<N:4>> <= << <<W:16>> || W <- tuple_to_list(Address) >>],
    lists:append([[lists:nth(N + 1, "0123456789abcdef"), $.] || N <- lists:reverse(Nibbles)])
        ++ "ip6.arpa".

-doc """
The lines of the answer records, in order, each written once: aliases,
IPv4 and IPv6 addresses and pointers. Records of other types, and
address records whose data is not an address, write nothing.
""".
-spec answer_lines([rr()]) -> [binary()].
answer_lines(Records) ->
    unique([Line || Record <- Records, Line <- [line(Record)], Line =/= none]).

line({cname, Owner, Target}) when is_list(Target) ->
    <<(name(Owner))/binary, " is an alias for ", (name(Target))/binary, ".\n">>;
line({a, Owner, {_, _, _, _} = Address}) ->
    address_line(Owner, <<" has address ">>, Address);
line({aaaa, Owner, {_, _, _, _, _, _, _, _} = Address}) ->
    address_line(Owner, <<" has IPv6 address ">>, Address);
line({ptr, Owner, Target}) when is_list(Target) ->
    <<(name(Owner))/binary, " domain name pointer ", (name(Target))/binary, ".\n">>;
line(_Record) ->
    none.

address_line(Owner, Words, Address) ->
    case inet:ntoa(Address) of
        {error, einval} -> none;
        Text -> <<(name(Owner))/binary, Words/binary, (list_to_binary(Text))/binary, "\n">>
    end.

unique(Lines) ->
    {Unique, _Seen} = lists:foldl(fun(Line, {Kept, Seen}) ->
                                          case sets:is_element(Line, Seen) of
                                              true -> {Kept, Seen};
                                              false -> {[Line | Kept], sets:add_element(Line, Seen)}
                                          end
                                  end, {[], sets:new([{version, 2}])}, Lines),
    lists:reverse(Unique).

-doc """
The line of a failed lookup of `Name`, FreeBSD's for a DNS error code or
for no server answering, or `error` for a failure host(1) has no line
for, which the caller reports as a diagnostic.
""".
-spec failure_line(string(), term()) -> {ok, binary()} | error.
failure_line(_Name, timeout) ->
    {ok, <<";; connection timed out; no servers could be reached\n">>};
failure_line(Name, Reason) ->
    case rcode(Reason) of
        {Code, Text} ->
            {ok, <<"Host ", (name(Name))/binary, " not found: ", (integer_to_binary(Code))/binary,
                   "(", Text/binary, ")\n">>};
        none ->
            error
    end.

rcode(formerr) -> {1, <<"FORMERR">>};
rcode(servfail) -> {2, <<"SERVFAIL">>};
rcode(nxdomain) -> {3, <<"NXDOMAIN">>};
rcode(notimp) -> {4, <<"NOTIMP">>};
rcode(refused) -> {5, <<"REFUSED">>};
rcode(badvers) -> {16, <<"BADVERS">>};
rcode(_Reason) -> none.

-doc "The header naming the server the queries go to, as typed and as its address.".
-spec server_lines(binary(), inet:ip4_address()) -> iodata().
server_lines(Server, Address) ->
    [<<"Using domain server:\nName: ">>, erx_text:escape_field(Server),
     <<"\nAddress: ">>, inet:ntoa(Address), <<"#">>, integer_to_binary(?DNS_PORT),
     <<"\nAliases: \n\n">>].

%% A name as text: inet_dns gives a reply's names as lists of bytes.
name(Name) ->
    erx_text:escape_field(list_to_binary(Name)).
