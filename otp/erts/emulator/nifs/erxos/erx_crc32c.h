/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CRC32C_H
#define ERX_CRC32C_H

#include <stddef.h>
#include <stdint.h>

/*
 * CRC-32C (Castagnoli), as RFC 3720 uses it: the reflected polynomial 0x82F63B78, with the
 * initial inversion and the final inversion done inside the call. crc is the value of the
 * bytes before these, 0 for none, so a long input checked in pieces gives the one-shot value:
 * erx_crc32c(erx_crc32c(0, a, na), b, nb) is erx_crc32c(0, a b, na + nb). data may be NULL
 * when length is 0.
 */
uint32_t erx_crc32c(uint32_t crc, const uint8_t *data, size_t length);

#endif
