/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <pthread.h>
#include <stdio.h>

#include "erx/abi.h"

static erx_time_page_t clock_page;

static void *
write_clock(void *argument)
{

	(void)argument;
	for (uint64_t index = 0; index < 10000; index++) {
		if (!erx_time_page_wall_offset_ns_store(&clock_page, -(int64_t)index) ||
		    !erx_time_page_seq_store(&clock_page, index))
			return (&clock_page);
	}
	return (NULL);
}

static void *
read_clock(void *argument)
{
	uint64_t sequence;
	int64_t offset;

	(void)argument;
	for (size_t index = 0; index < 10000; index++) {
		if (!erx_time_page_seq_load(&clock_page, &sequence) ||
		    !erx_time_page_wall_offset_ns_load(&clock_page, &offset) ||
		    sequence >= 10000 || offset > 0 || offset <= -10000)
			return (&clock_page);
	}
	return (NULL);
}

int
main(void)
{
	pthread_t writer, reader;
	void *writer_result, *reader_result;
	erx_utcb_t utcb = {0};
	uint64_t value = 17;
	int64_t offset;

	if (erx_time_page_seq_status(ERX_TIME_PAGE_SEQ_TERMINAL) != ERX_ELIMIT ||
	    erx_time_page_seq_status(0) != ERX_OK)
		return (1);
	if (!erx_time_page_wall_offset_ns_store(&clock_page, INT64_MIN) ||
	    !erx_time_page_wall_offset_ns_load(&clock_page, &offset) || offset != INT64_MIN)
		return (1);
	if (!erx_time_page_wall_offset_ns_store(&clock_page, 0))
		return (1);
	if (erx_utcb_mr_load(&utcb, ERX_MSG_WORDS, &value) || value != 17 ||
	    erx_utcb_mr_store(&utcb, ERX_MSG_WORDS, UINT64_MAX) ||
	    !erx_utcb_mr_store(&utcb, ERX_MSG_WORDS - 1, UINT64_MAX) ||
	    !erx_utcb_mr_load(&utcb, ERX_MSG_WORDS - 1, &value) || value != UINT64_MAX)
		return (1);
	if (pthread_create(&writer, NULL, write_clock, NULL) != 0)
		return (1);
	if (pthread_create(&reader, NULL, read_clock, NULL) != 0) {
		(void)pthread_join(writer, NULL);
		return (1);
	}
	if (pthread_join(writer, &writer_result) != 0 ||
	    pthread_join(reader, &reader_result) != 0 ||
	    writer_result != NULL || reader_result != NULL)
		return (1);
	puts("atomic accessor checks passed");
	return (0);
}
