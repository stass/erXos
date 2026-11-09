%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The module jit_reload loads again and again: compiled three times, with
%% VERSION 1, 2 and 3, so each load replaces the code that says one number with
%% code that says the next (tools/lib/erx/native_domain.rb).
-module(jit_probe).
-export([version/0]).

-spec version() -> 1 | 2 | 3.
version() -> ?VERSION.
