/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#include "input.h"

/* Host resource budget; freestanding readers allocate no file buffer. */
#define ERX_HOST_FILE_MAX (UINT64_C(512) * 1024 * 1024)

uint8_t *
erx_host_input_read(const char *path, size_t *length)
{
	struct stat status;
	uint8_t *bytes;
	size_t cursor;
	ssize_t count;
	int descriptor;

	/* Nonblocking open lets a FIFO be refused without waiting for a writer. */
	descriptor = open(path, O_RDONLY | O_NONBLOCK);
	if (descriptor < 0)
		return (NULL);
	if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
	    status.st_size < 0 ||
	    (uint64_t)status.st_size > ERX_HOST_FILE_MAX ||
	    (uint64_t)status.st_size > SIZE_MAX) {
		close(descriptor);
		return (NULL);
	}
	*length = (size_t)status.st_size;
	bytes = malloc(*length == 0 ? 1 : *length);
	if (bytes == NULL) {
		close(descriptor);
		return (NULL);
	}
	cursor = 0;
	while (cursor < *length) {
		count = read(descriptor, bytes + cursor, *length - cursor);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			free(bytes);
			close(descriptor);
			return (NULL);
		}
		cursor += (size_t)count;
	}
	close(descriptor);
	return (bytes);
}
