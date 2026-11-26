/* Modified by erXos: vsnprintf formats into a buffer of its own, so vfprintf
 * takes the printf lock only for the console, and formatting a string never
 * waits on another CPU (docs/design-debugger.md, "On Fiasco"). */
#include "stdio_impl.h"
#include <limits.h>
#include <string.h>
#include <stdint.h>

struct cookie {
	char *s;
	size_t n;
};

#define MIN(a, b) ((a) < (b) ? (a) : (b))

static void sn_write(FILE *f, const char *s, size_t l)
{
	struct cookie *c = f->cookie;
	size_t k = MIN(c->n, (size_t)(f->wpos - f->buf));
	if (k) {
		memcpy(c->s, f->buf, k);
		c->s += k;
		c->n -= k;
	}
	k = MIN(c->n, l);
	if (k) {
		memcpy(c->s, s, k);
		c->s += k;
		c->n -= k;
	}
	*c->s = 0;
	f->wpos = f->buf;
}

int vsnprintf(char *restrict s, size_t n, const char *restrict fmt, va_list ap)
{
	char buf[80];
	char dummy[1];
	struct cookie c = { .s = n ? s : dummy, .n = n ? n-1 : 0 };
	FILE f = {
		.write = sn_write,
		.buf = buf,
		.buf_size = sizeof buf,
		.wpos = buf,
		.cookie = &c,
	};
	int ret;

	*c.s = 0;
	ret = vfprintf(&f, fmt, ap);
	sn_write(&f, 0, 0);
	return ret;
}
