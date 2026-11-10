/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * A name's holders, the field the export table keeps on the name's own record
 * (erx_exports.h). Apart so erl_process.h, which ERTS's C++ JIT includes too, carries the
 * field without the funnel's C interface.
 */

#ifndef ERX_EXPORTS_SET_H
#define ERX_EXPORTS_SET_H

#include <stdint.h>

/*
 * One connection as the export table sees it: the peer's domain id and the connection's
 * serial, which the peer's distribution entry takes when the connection goes pending
 * (erl_node_tables.c) and no other connection of the boot shares. Every holder is written for one connection and holds only on it.
 */
typedef struct erx_exports_conn {
	uint32_t		 peer;		/* the peer's domain id; 0 for no domain */
	uint32_t		 pad;
	uint64_t		 serial;	/* the connection's own; 0 names none */
} erx_exports_conn_t;

/*
 * What one peer holds on one name: its ERX_RIGHT_* bits, never 0 while it is held, on the
 * connection serial names. Once that connection has ended the holder holds nothing: no
 * later connection's lookup matches it, and the next write for the peer replaces it.
 */
typedef struct erx_export_holder {
	uint32_t		 peer;		/* a domain that was given the name */
	uint8_t			 rights;	/* ERX_RIGHT_*: what it holds on it */
	uint8_t			 pad[3];
	uint64_t		 serial;	/* the connection it was given on */
} erx_export_holder_t;

/*
 * A name's holders, private to the runtime. All zero is an open set that holds nothing;
 * once closed, at the transition that ends the name, it holds nothing and is written
 * never again, so a writer that raced the end leaves nothing behind.
 */
typedef struct erx_exports {
	uint16_t		 nholders;
	uint16_t		 cap;		/* holders allocated */
	uint32_t		 closed;	/* the name has ended */
	erx_export_holder_t	*holders;	/* one per peer given the name */
} erx_exports_t;

#endif /* ERX_EXPORTS_SET_H */
