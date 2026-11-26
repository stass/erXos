%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% FAT's directory geometry and the short entry's names and case flags (the FAT
%% specification, sections 6 and 7), shared by erx_fat, erx_fat_dir, erx_fat_entry
%% and erx_fat_name; the entry's byte layout is erx_fat_entry's alone.

%% A directory entry's bytes.
-define(ENTRY, 32).
%% A directory holds at most 65,536 entries (section 6).
-define(DIR_ENTRIES_MAX, 65536).
%% The dot entries' short names (section 6.1).
-define(DOT, <<".          ">>).
-define(DOTDOT, <<"..         ">>).
%% The case flags of a short entry's NTRes byte, as Windows NT writes them.
-define(LOWER_BASE, 16#08).
-define(LOWER_EXTENSION, 16#10).
