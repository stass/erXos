%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_header).
-moduledoc """
The one parser of an app package file's structure
(docs/design-packaging.md, "The package"), whatever the file's origin and
whoever authenticated it. A package is a header, the app's EROFS image and
the image's hash tree, each from an EROFS block boundary, as
`abi/formats/package.txt` lays them.

`decode/2` takes the file's length and its first bytes, as many as the
file has up to `ERX_PKG_HEADER_MAX`. It reads the header through the
generated reader, `erx_pkg_reader`, and then checks that the padding after
the header is zero and that the image and the tree lie end to end to the
file's end, the tree as long as `erx_verity_tree` gives for the image. The
file's bytes are untrusted: every length is checked before it is used, and
the first failure is the answer. `layout/2` is the decoder's layout alone.
`check_file/2` is the file check, the one entry that judges a package file:
the decoder, then the file's name and the header's authentication, by the
SHA-256 the image's `package` row records or by a trusted signer's Ed25519
seal, which `erx_bytes:ed25519_verify/3` checks over every byte of the
header before the signature.
""".

-export([decode/2, layout/2, check_file/2]).
-export_type([decoded/0, start/0, reason/0, authority/0, signer/0, authenticator/0, checked/0,
              check_reason/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).

%% A file at least as long as the block boundary after its header has that
%% boundary within the bytes the decoder reads.
-if(?ERX_PKG_HEADER_MAX rem ?BLOCK =/= 0).
-error("pkg_header_max is not a multiple of the EROFS block size").
-endif.

-doc "What a package starts: its Erlang applications, or its program with its arguments.".
-type start() :: {applications, [binary(), ...]} | {program, binary(), [binary()]}.

-doc """
A decoded header: the packed declaration, the build's ABI version and
architecture, the seal and the header's length, and the image's layout.
""".
-type decoded() :: #{name := binary(),
                     abi_version := non_neg_integer(),
                     arch := binary(),
                     version := pos_integer(),
                     memory := non_neg_integer(),
                     needs := [binary()],
                     gatt := [binary()],
                     start := start(),
                     license := binary(),
                     key := binary(),
                     signature := binary(),
                     header_length := pos_integer(),
                     layout := erx_verity_tree:layout()}.

-doc """
Why a file is not a package: longer than `ERX_PKG_BYTES_MAX`; a header the
reader refuses; fewer bytes read than the decoder reads, or a file cut short
of the header's block boundary (`short`); padding not zero; a tree length
that is not the image's; or a file that does not end where the tree does.
""".
-type reason() :: {too_large, non_neg_integer()}
                | {header, erx_pkg_reader:error() | short | padding
                         | {tree, non_neg_integer(), non_neg_integer()}}
                | {length, non_neg_integer(), pos_integer()}.

-doc """
Decode the package file of `Length` bytes whose first bytes are `Bytes`.
The decoder reads a copy of `min(Length, ERX_PKG_HEADER_MAX)` of them, and
refuses fewer, as a read cut short gives, with `{header, short}`.
""".
-spec decode(non_neg_integer(), binary()) ->
    {ok, decoded()} | {error, reason()}.
decode(Length, Bytes)
  when is_integer(Length), Length >= 0, is_binary(Bytes) ->
    try
        {ok, decode_file(Length, Bytes)}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-doc "The layout `decode/2` finds, after all of its checks.".
-spec layout(non_neg_integer(), binary()) ->
    {ok, erx_verity_tree:layout()} | {error, reason()}.
layout(Length, Bytes) ->
    case decode(Length, Bytes) of
        {ok, #{layout := Layout}} -> {ok, Layout};
        {error, _} = Error -> Error
    end.

-doc """
How a header is authenticated (docs/design-packaging.md, "The package"):
`{hash, Sha256}` for a package of the image, the SHA-256 its `package` row
records; `{signers, Keys}` for an installed package, each trusted signer
with its 32-byte Ed25519 public key.
""".
-type authority() :: {hash, <<_:256>>} | {signers, [{signer(), <<_:256>>}]}.

-doc """
A trusted signer: the name of the manifest's `signer` row that holds its
key, or `development` for the image builder's development package key.
""".
-type signer() :: binary() | development.

-doc """
Who authenticates a file the file check accepted: `image` for a package of
the image, whose header's SHA-256 the manifest's `package` row records,
otherwise the trusted signer whose seal it carries.
""".
-type authenticator() :: image | signer().

-doc """
A file the file check accepted: its decoded header, the signer that
authenticates it, the SHA-256 of the header's bytes and the header's
extent, the bytes before the image.
""".
-type checked() :: #{header := decoded(),
                     signer := authenticator(),
                     sha256 := <<_:256>>,
                     extent := pos_integer()}.

-doc """
Why the file check refuses a file: the decoder's reason; a file name that
is not `NAME.app` with NAME the declaration's app name; or a header the
authority does not authenticate: its SHA-256 is not the recorded one
(`hash`), its key is no trusted signer's (`signer`), or its signature is
not valid (`signature`).
""".
-type check_reason() :: reason()
                      | {name, binary(), binary()}
                      | {untrusted, hash | signer | signature}.

-doc """
The file check: decode the file `{Name, Length, Bytes}`, `Name` its name in
the directory and `Bytes` its first bytes, then check that `Name` is
`NAME.app` for the declaration's app name and that `Authority`
authenticates the header. Under `{hash, H}` the signer and signature fields
are not read. Under `{signers, Keys}` the header's key must be one of
`Keys`, which is checked first, and its signature must verify over every
byte of the header before it; the signer is the key's name in `Keys`.
""".
-spec check_file({binary(), non_neg_integer(), binary()}, authority()) ->
    {ok, checked()} | {error, check_reason()}.
check_file({Name, Length, Bytes}, Authority) when is_binary(Name) ->
    case decode(Length, Bytes) of
        {ok, Decoded} ->
            try
                {ok, authenticate(Name, Bytes, Decoded, Authority)}
            catch
                throw:{?MODULE, Reason} -> {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

authenticate(Name, Bytes, #{name := App, header_length := HeaderLength,
                            layout := #{image_offset := Extent}} = Decoded,
             Authority) ->
    check(Name =:= <<App/binary, ".app">>, {name, Name, App}),
    Sha256 = erx_bytes:sha256(binary:part(Bytes, 0, HeaderLength)),
    Signer = case Authority of
                 {hash, Want} ->
                     check(Sha256 =:= Want, {untrusted, hash}),
                     image;
                 {signers, Keys} ->
                     signed(Bytes, Decoded, Keys)
             end,
    #{header => Decoded, signer => Signer, sha256 => Sha256, extent => Extent}.

%% The trusted signer whose key the header carries, once the signature,
%% which the decoder found at the header's end, verifies over every byte of
%% the header before it. Those bytes fit one call: the BIF
%% (erx_bytes_bif.c) asserts that pkg_header_max less the signature is
%% within its bound.
signed(Bytes, #{header_length := HeaderLength, key := Key, signature := Signature}, Keys) ->
    Signer = case lists:keyfind(Key, 2, Keys) of
                 {Name, Key} -> Name;
                 false -> throw({?MODULE, {untrusted, signer}})
             end,
    Signed = binary:part(Bytes, 0, HeaderLength - ?ERX_PKG_SIGNATURE_SIZE),
    check(erx_bytes:ed25519_verify(Signature, Key, Signed), {untrusted, signature}),
    Signer.

decode_file(Length, Read) ->
    check(Length =< ?ERX_PKG_BYTES_MAX, {too_large, Length}),
    Want = min(Length, ?ERX_PKG_HEADER_MAX),
    check(byte_size(Read) >= Want, {header, short}),
    %% A copy, so a decoded string never keeps a longer read alive.
    Bytes = binary:copy(binary:part(Read, 0, Want)),
    View = header_view(Bytes),
    #{header_length := HeaderLength, image_blocks := ImageBlocks,
      tree_blocks := TreeBlocks, salt := Salt, root_hash := RootHash} =
        Header = reader_answer(erx_pkg_reader:header(View)),
    ImageOffset = block_boundary(HeaderLength),
    check(ImageOffset =< byte_size(Bytes), {header, short}),
    Padding = binary:part(Bytes, HeaderLength, ImageOffset - HeaderLength),
    check(Padding =:= <<0:(byte_size(Padding) * 8)>>, {header, padding}),
    WantTree = erx_verity_tree:blocks(ImageBlocks),
    check(TreeBlocks =:= WantTree, {header, {tree, TreeBlocks, WantTree}}),
    TreeOffset = ImageOffset + ImageBlocks * ?BLOCK,
    End = TreeOffset + TreeBlocks * ?BLOCK,
    check(Length =:= End, {length, Length, End}),
    Layout = #{image_offset => ImageOffset,
               image_length => ImageBlocks * ?BLOCK,
               tree_offset => TreeOffset,
               tree_length => TreeBlocks * ?BLOCK,
               salt => Salt,
               root_hash => RootHash},
    declaration(View, Header, Layout).

%% The header is the first header_length bytes, which the generated reader
%% finds from the header's own length field and checks whole.
header_view(Bytes) ->
    reader_answer(erx_pkg_reader:open_prefix(Bytes)).

declaration(View, Header, Layout) ->
    #{key := Key, signature := Signature} =
        reader_answer(erx_pkg_reader:fetch(View, seal, 0)),
    #{name := Name, arch := Arch, license := License} = Header,
    #{name => string(View, Name),
      abi_version => maps:get(abi_version, Header),
      arch => string(View, Arch),
      version => maps:get(app_version, Header),
      memory => maps:get(memory, Header),
      needs => strings(View, needs),
      gatt => strings(View, gatt),
      start => start(View, Header),
      license => string(View, License),
      key => Key,
      signature => Signature,
      header_length => maps:get(header_length, Header),
      layout => Layout}.

start(View, #{kind := ?ERX_PKG_ERLANG}) ->
    {applications, strings(View, applications)};
start(View, #{kind := ?ERX_PKG_NATIVE, program := Program, args := Args}) ->
    {program, string(View, Program), arguments(string(View, Args))}.

%% The arguments are NUL-terminated strings, which the reader checked.
arguments(Bytes) ->
    lists:droplast(binary:split(Bytes, <<0>>, [global])).

strings(View, Table) ->
    Reversed = reader_answer(erx_pkg_reader:fold(View, Table,
        fun(Reference, Acc) -> [string(View, Reference) | Acc] end, [])),
    lists:reverse(Reversed).

string(View, Reference) ->
    reader_answer(erx_pkg_reader:string(View, Reference)).

block_boundary(Offset) ->
    (Offset + ?BLOCK - 1) div ?BLOCK * ?BLOCK.

%% The generated reader's answer, or its refusal as the decoder's.
reader_answer({ok, Value}) -> Value;
reader_answer({error, Reason}) -> throw({?MODULE, {header, Reason}}).

check(true, _Reason) -> ok;
check(false, Reason) -> throw({?MODULE, Reason}).
