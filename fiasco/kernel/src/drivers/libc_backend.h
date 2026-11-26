/* Modified by erXos: the stop's bounded take of the printf lock. */
/* This file defines the back-end interface */
/* of the kernel C-library. */

#ifndef __LIBC_BACKEND_H__
#define __LIBC_BACKEND_H__

#include <stddef.h>
#include <cdefs.h>

__BEGIN_DECLS

/**
 * The text output back-end.
 *
 * This function must be provided to the C-library for text output. It must
 * simply send len characters of str to an output device.
 *
 * \param str Buffer to send.
 * \param len The number of bytes.
 * \return 1 on success, 0 else.
 */
int __libc_backend_outs(const char *str, size_t len);

typedef unsigned int __libc_backend_printf_lock_t;

__libc_backend_printf_lock_t __libc_backend_printf_lock(void);

void __libc_backend_printf_unlock(__libc_backend_printf_lock_t);

void __libc_backend_printf_local_force_unlock(void);

/* erXos: the stop's bounded take, which it never undoes. */
int __libc_backend_printf_take_bounded(unsigned tries);

__END_DECLS

#endif //__LIBC_BACKEND_H__
