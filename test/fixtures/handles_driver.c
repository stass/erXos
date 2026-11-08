/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A host driver for liberx/backend/core/handles.c. It replays every sequence of
 * creates, dups, closes, destroys and one generation hook up to a fixed depth on a
 * table of three handles, and after each step checks every handle against a model
 * that knows nothing of records or generations: each object has a serial, a destroy
 * ends it, and a handle is good exactly while its object lives. The hook sets the
 * lowest free record's generation to its last value, as the Fiasco backend's test
 * hook does, so a sequence that reuses that record twice meets the retire. Then the
 * fixed cases: the limit, the pool running dry, refusals by value and kind, and a
 * mapped object outliving its last handle. Prints "ok: N checks" or fails with the
 * case and what disagreed.
 */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/handles.h"

#define PAGE		((size_t)ERX_PAGE_SIZE)
#define LIMIT		3u
#define DEPTH		6u
#define SERIALS		(DEPTH + 1u)
#define OTHER_KIND	(ERX_BACKEND_OBJECT_MEMORY + 1u)

typedef enum op {
	OP_CREATE,
	OP_DUP,
	OP_CLOSE,
	OP_DESTROY,
	OP_AGE
} op_t;

typedef struct step {
	op_t		op;
	uint64_t	handle;
} step_t;

/* What the driver knows: which serial each handle names, which serials live, and each serial's record. */
typedef struct model {
	uint32_t	entry[LIMIT];		/* serial plus one, or 0 */
	bool		live[SERIALS];
	uint32_t	refs[SERIALS];
	uint32_t	record[SERIALS];
	uint32_t	serials;
} model_t;

static uint32_t		 pages_left;
static uint32_t		 pages_held;
static const char	*current_case = "setup";
static unsigned long	 checks;
static step_t		 path[DEPTH];

static _Noreturn void
fail(const char *what, uint64_t detail)
{
	fprintf(stderr, "%s: %s (0x%llx)\n", current_case, what, (unsigned long long)detail);
	for (uint32_t i = 0; i < DEPTH; i++)
		fprintf(stderr, " step %u: op %d handle %llu\n", i, (int)path[i].op, (unsigned long long)path[i].handle);
	exit(1);
}

static void
check(bool ok, const char *what, uint64_t detail)
{
	checks++;
	if (!ok)
		fail(what, detail);
}

static uintptr_t
source_take(void)
{
	void *page = NULL;

	if (pages_left == 0)
		return (0);
	if (posix_memalign(&page, PAGE, PAGE) != 0)
		fail("the host gave no page", 0);
	pages_left--;
	pages_held++;
	memset(page, 0xa5, PAGE);
	return ((uintptr_t)page);
}

static void
source_give(uintptr_t page)
{
	if (pages_held == 0)
		fail("more pages given back than taken", page);
	pages_held--;
	free((void *)page);
}

static const erx_backend_grow_pages_t source = { .take = source_take, .give = source_give };

/* The lowest free model entry, or LIMIT. */
static uint32_t
model_free_entry(const model_t *model)
{
	uint32_t entry = 0;

	while (entry < LIMIT && model->entry[entry] != 0)
		entry++;
	return (entry);
}

/* What erx_backend_handle_find must answer for handle, by the model alone. */
static int
model_find(const model_t *model, uint64_t handle)
{
	if (handle == 0 || handle > LIMIT || model->entry[handle - 1] == 0)
		return (ERX_EINVAL);
	return (model->live[model->entry[handle - 1] - 1] ? ERX_OK : ERX_ESTALE);
}

/* The lowest free record, whose generation the hook sets to its last value. */
static void
age_lowest_free(erx_backend_grow_table_t *objects)
{
	for (uint32_t index = 0; index < erx_backend_grow_table_capacity(objects); index++)
		if (erx_backend_object_at(objects, index)->kind == ERX_BACKEND_OBJECT_FREE) {
			erx_backend_object_at(objects, index)->generation = UINT32_MAX;
			return;
		}
}

/* Every handle the core answers as the model does, and a good one names its serial's record. */
static void
check_all(const erx_backend_grow_table_t *objects, const erx_backend_handles_t *handles, const model_t *model)
{
	for (uint64_t handle = 0; handle <= LIMIT + 1; handle++) {
		uint32_t index = UINT32_MAX;
		const int want = model_find(model, handle);
		const int got = erx_backend_handle_find(objects, handles, handle, ERX_BACKEND_OBJECT_MEMORY, &index);

		check(got == want, "a handle answers otherwise than the model", handle);
		if (got == ERX_OK)
			check(index == model->record[model->entry[handle - 1] - 1], "a handle names another record", handle);
	}
}

static void
apply(erx_backend_grow_table_t *objects, erx_backend_handles_t *handles, model_t *model, const step_t *step)
{
	const uint32_t free_entry = model_free_entry(model);
	uint32_t index = UINT32_MAX;
	uint64_t handle = 0;
	bool freed = true;
	int status;

	switch (step->op) {
	case OP_CREATE:
		check(erx_backend_object_take(objects, ERX_BACKEND_OBJECT_MEMORY, 7, 9, &index) == ERX_OK, "a take failed", 0);
		for (uint32_t serial = 0; serial < model->serials; serial++)
			check(!model->live[serial] || model->record[serial] != index, "a take reused a live record", index);
		status = erx_backend_handle_add(objects, handles, index, &handle);
		if (free_entry == LIMIT) {
			check(status == ERX_ELIMIT, "an add past the limit was given", (uint64_t)status);
			erx_backend_object_unmake(objects, index);
			return;
		}
		check(status == ERX_OK && handle == (uint64_t)free_entry + 1, "an add took another entry", handle);
		model->record[model->serials] = index;
		model->live[model->serials] = true;
		model->refs[model->serials] = 1;
		model->entry[free_entry] = ++model->serials;
		return;
	case OP_DUP:
		status = erx_backend_handle_dup(objects, handles, step->handle, &handle);
		if (model_find(model, step->handle) != ERX_OK) {
			check(status == model_find(model, step->handle), "a dup of a bad handle answered otherwise", step->handle);
			return;
		}
		if (free_entry == LIMIT) {
			check(status == ERX_ELIMIT, "a dup past the limit was given", (uint64_t)status);
			return;
		}
		check(status == ERX_OK && handle == (uint64_t)free_entry + 1, "a dup took another entry", handle);
		model->entry[free_entry] = model->entry[step->handle - 1];
		model->refs[model->entry[free_entry] - 1]++;
		return;
	case OP_CLOSE:
		status = erx_backend_handle_close(objects, handles, step->handle, &freed, &index);
		if (model_find(model, step->handle) == ERX_EINVAL) {
			check(status == ERX_EINVAL, "a close of no entry answered otherwise", (uint64_t)status);
			return;
		}
		check(status == ERX_OK, "a close failed", (uint64_t)status);
		{
			const uint32_t serial = model->entry[step->handle - 1] - 1;
			const bool live = model->live[serial];

			model->entry[step->handle - 1] = 0;
			if (live)
				model->refs[serial]--;
			check(freed == (live && model->refs[serial] == 0), "a close's last reference misjudged", serial);
			if (freed) {
				check(index == model->record[serial], "a close freed another record", index);
				erx_backend_object_free(objects, index);
				model->live[serial] = false;
			}
		}
		return;
	case OP_DESTROY:
		status = erx_backend_handle_find(objects, handles, step->handle, ERX_BACKEND_OBJECT_ANY, &index);
		check(status == model_find(model, step->handle), "a destroy's find answered otherwise", step->handle);
		if (status == ERX_OK) {
			erx_backend_object_free(objects, index);
			model->live[model->entry[step->handle - 1] - 1] = false;
		}
		return;
	case OP_AGE:
		age_lowest_free(objects);
		return;
	}
}

/* Replays path[0..depth) on fresh tables, checking after each step. */
static void
replay(uint32_t depth)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	model_t model = { 0 };

	pages_left = UINT32_MAX;
	erx_backend_objects_init(&objects, &source);
	erx_backend_handles_init(&handles, LIMIT, &source);
	for (uint32_t i = 0; i < depth; i++) {
		apply(&objects, &handles, &model, &path[i]);
		check_all(&objects, &handles, &model);
	}
	erx_backend_handles_clear(&handles);
	erx_backend_grow_table_clear(&objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

static void
explore(uint32_t depth)
{
	static const op_t handle_ops[] = { OP_DUP, OP_CLOSE, OP_DESTROY };

	replay(depth);
	if (depth == DEPTH)
		return;
	path[depth] = (step_t){ .op = OP_CREATE };
	explore(depth + 1);
	path[depth] = (step_t){ .op = OP_AGE };
	explore(depth + 1);
	for (size_t op = 0; op < sizeof(handle_ops) / sizeof(handle_ops[0]); op++)
		for (uint64_t handle = 1; handle <= LIMIT; handle++) {
			path[depth] = (step_t){ .op = handle_ops[op], .handle = handle };
			explore(depth + 1);
		}
	path[depth] = (step_t){ 0 };
}

/* A table limited only by its pages: the add after the first page's last entry needs a grow. */
static void
case_limits_and_pool(void)
{
	const uint32_t per_page = (uint32_t)(PAGE / sizeof(erx_backend_handle_entry_t));
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index;
	uint64_t handle;

	current_case = "limits_and_pool";
	pages_left = 0;
	erx_backend_objects_init(&objects, &source);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_ENOMEM,
	    "a take with no page was given", 0);
	pages_left = 2;
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 0, 0, &index) == ERX_OK && index == 0,
	    "the first take is not record 0", index);
	erx_backend_handles_init(&handles, per_page + 1, &source);
	pages_left = 0;
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_ENOMEM, "an add with no page was given", 0);
	check(erx_backend_object_at(&objects, index)->handles == 0, "a refused add counted", 0);
	pages_left = 2;
	for (uint32_t i = 0; i < per_page; i++)
		check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_OK && handle == i + 1u,
		    "an add within the first page failed", i);
	check(erx_backend_handles_end(&handles) == (uint64_t)per_page + 1, "the end is not the first page's", 0);
	pages_left = 0;
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_ENOMEM, "a grow with no page was given", 0);
	pages_left = 1;
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_OK && handle == per_page + 1u,
	    "the add the limit allows failed", handle);
	check(erx_backend_handles_end(&handles) == (uint64_t)per_page + 2, "the end passes the limit", 0);
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_ELIMIT, "an add past the limit was given",
	    0);
	check(erx_backend_handle_find(&objects, &handles, per_page + 2u, ERX_BACKEND_OBJECT_ANY, &index) == ERX_EINVAL,
	    "an entry past the limit was found", 0);
	check(erx_backend_object_at(&objects, 0)->handles == per_page + 1u, "the record miscounts its handles", 0);
	for (uint64_t h = 1; h <= per_page + 1u; h++) {
		bool freed;

		check(erx_backend_handle_close(&objects, &handles, h, &freed, &index) == ERX_OK && freed == (h == per_page + 1u),
		    "a close misjudged the last handle", h);
	}
	erx_backend_handles_clear(&handles);
	erx_backend_grow_table_clear(&objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

/* Refusals by value and by kind, and a mapped object outliving its last handle. */
static void
case_refusals_and_mappings(void)
{
	erx_backend_grow_table_t objects;
	erx_backend_handles_t handles;
	uint32_t index;
	uint32_t found;
	uint64_t handle;
	bool freed;

	current_case = "refusals_and_mappings";
	pages_left = UINT32_MAX;
	erx_backend_objects_init(&objects, &source);
	erx_backend_handles_init(&handles, 0, &source);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 3, 4, &index) == ERX_OK, "a take failed", 0);
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_ELIMIT, "a table of no entries took one", 0);
	erx_backend_handles_init(&handles, ERX_CAPS_MAX, &source);
	check(erx_backend_handle_add(&objects, &handles, index, &handle) == ERX_OK && handle == 1, "an add failed", 0);
	check(erx_backend_handle_find(&objects, &handles, 1, OTHER_KIND, &found) == ERX_ETYPE, "a kind was not checked", 0);
	check(erx_backend_handle_find(&objects, &handles, 0, ERX_BACKEND_OBJECT_ANY, &found) == ERX_EINVAL,
	    "the null handle was found", 0);
	check(erx_backend_handle_find(&objects, &handles, UINT64_MAX, ERX_BACKEND_OBJECT_ANY, &found) == ERX_EINVAL,
	    "a huge handle was found", 0);
	check(erx_backend_handle_find(&objects, &handles, 2, ERX_BACKEND_OBJECT_ANY, &found) == ERX_EINVAL,
	    "a free entry was found", 0);
	check(erx_backend_object_at(&objects, index)->creator == 3 && erx_backend_object_at(&objects, index)->budget == 4,
	    "a record lost its creator or budget", 0);
	erx_backend_object_at(&objects, index)->mappings = 1;
	check(erx_backend_handle_close(&objects, &handles, 1, &freed, &found) == ERX_OK && !freed,
	    "a mapped object went with its last handle", 0);
	check(erx_backend_handle_close(&objects, &handles, 1, &freed, &found) == ERX_EINVAL, "a closed entry closed again",
	    0);
	erx_backend_object_at(&objects, index)->mappings = 0;
	check(erx_backend_object_unreferenced(erx_backend_object_at(&objects, index)), "an unreferenced record kept", 0);
	erx_backend_object_free(&objects, index);
	check(erx_backend_object_at(&objects, index)->kind == ERX_BACKEND_OBJECT_FREE &&
	    erx_backend_object_at(&objects, index)->generation == 1, "a free did not move the generation on", 0);
	check(erx_backend_object_take(&objects, ERX_BACKEND_OBJECT_MEMORY, 3, 4, &found) == ERX_OK && found == index,
	    "a freed record was not taken again", found);
	erx_backend_object_unmake(&objects, index);
	check(erx_backend_object_at(&objects, index)->kind == ERX_BACKEND_OBJECT_FREE &&
	    erx_backend_object_at(&objects, index)->generation == 1, "an unmake moved the generation", 0);
	erx_backend_handles_clear(&handles);
	erx_backend_grow_table_clear(&objects);
	check(pages_held == 0, "a table kept a page", pages_held);
}

int
main(void)
{
	current_case = "sequences";
	explore(0);
	case_limits_and_pool();
	case_refusals_and_mappings();
	printf("ok: %lu checks\n", checks);
	return (0);
}
