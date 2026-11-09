/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Plan 9's <u.h> for the 9front build (test/display/memdraw_shapes.c),
 * basic types with Plan 9's widths, so ulong is 32 bits as on every Plan 9
 * port, which the image layout (Memimage.width counts 32-bit words) and
 * the channel descriptors assume.
 */
#ifndef ERX_ORACLE_U_H
#define ERX_ORACLE_U_H

#include <stddef.h>
#include <stdint.h>

typedef signed char schar;
typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef uint32_t ulong;
typedef int64_t vlong;
typedef uint64_t uvlong;
typedef uint8_t u8int;
typedef uint16_t u16int;
typedef uint32_t u32int;
typedef uint64_t u64int;
typedef uintptr_t uintptr;
typedef uint32_t Rune;

#define nil ((void *)0)
#define nelem(x) (sizeof(x) / sizeof((x)[0]))
#define USED(...) ((void)(__VA_ARGS__))
#define SET(x) ((void)0)

#endif
