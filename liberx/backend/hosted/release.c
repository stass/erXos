/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Maps a boot archive in a macOS process. A run boots from one only when
 * ERX_RELEASE_ARCHIVE names it, while the stock prim_file layer stays beside
 * the release file system (otp/erts/emulator/nifs/erxos/erx_prim_file_stage.c).
 */

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "erx/release.h"
#include "liberx/backend/hosted/release.h"

erx_hosted_release_t
erx_hosted_release_map(const char **reason)
{
	const char *path;
	struct stat status;
	void *bytes;
	int descriptor;

	path = getenv("ERX_RELEASE_ARCHIVE");
	if (path == NULL)
		return (ERX_HOSTED_RELEASE_NONE);
	*reason = "unreadable";
	descriptor = open(path, O_RDONLY);
	if (descriptor < 0)
		return (ERX_HOSTED_RELEASE_REFUSED);
	if (fstat(descriptor, &status) != 0 || status.st_size <= 0) {
		close(descriptor);
		return (ERX_HOSTED_RELEASE_REFUSED);
	}
	bytes = mmap(NULL, (size_t)status.st_size, PROT_READ, MAP_PRIVATE, descriptor, 0);
	close(descriptor);
	if (bytes == MAP_FAILED)
		return (ERX_HOSTED_RELEASE_REFUSED);
	if (erx_release_bind(bytes, (size_t)status.st_size, reason) != 0) {
		munmap(bytes, (size_t)status.st_size);
		return (ERX_HOSTED_RELEASE_REFUSED);
	}
	return (ERX_HOSTED_RELEASE_MAPPED);
}
