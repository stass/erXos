/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * BeamAsm's executable memory on erXos (docs/design-runtime.md, "BeamAsm"):
 * one JIT object (ERX_MEM_JIT) mapped twice into the runtime's own space,
 * readable and executable at rx and readable and writable at rw, so no
 * mapping is ever writable and executable. erx_jit_memory.c defines these over
 * liberx's memory calls; asmjit's VirtMem (asmjit/core/virtmem.cpp) is
 * their one caller. Plain C types, so C++ includes this header too.
 */

#ifndef ERX_JIT_MEMORY_H
#define ERX_JIT_MEMORY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What a map or an unmap answers. A refused call changes nothing. */
enum erx_jit_memory_result {
	ERX_JIT_MEMORY_OK = 0,
	ERX_JIT_MEMORY_NO_ROOM = 1,	/* no pages or no free range */
	ERX_JIT_MEMORY_REFUSED = 2	/* a size that is not whole pages, or a space without JIT objects */
};

/* The page size the two aliases are made of. */
size_t	erx_jit_memory_page(void);
/*
 * A new JIT object of size bytes, whole pages, mapped at *rx and *rw; both
 * are NULL when the call is refused.
 */
int	erx_jit_memory_map(size_t size, void **rx, void **rw);
/* Removes both mappings that one map made, which ends their object. */
int	erx_jit_memory_unmap(void *rx, void *rw, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* ERX_JIT_MEMORY_H */
