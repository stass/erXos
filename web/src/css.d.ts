/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A stylesheet is imported only for its effect: esbuild gathers every
 * imported .css file into the bundle's one stylesheet, and the import
 * binds no name.
 */

declare module '*.css';
