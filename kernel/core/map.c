/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The mapping-record core (docs/design-kernel.md, "Memory" and "Virtual
 * memory"). The tree is an AVL tree keyed by a record's first page. It splits
 * and joins, so the records of any range come out as one subtree in
 * logarithmic time, and each node keeps what its subtree holds, so "is there a
 * kernel-user page in this range", "how many records" and "where is the
 * highest hole of this size" each take one walk down, whatever the range
 * holds.
 *
 * Every edit is one plan, and every plan has one shape, which erx_map_apply
 * alone carries out:
 *
 *   the window   an address range whose ends cut no record: all that lies in
 *                it leaves the tree;
 *   the pops     the records of the window, at its two ends, that are reused;
 *   the segments the pieces to write, in address order, each into a popped
 *                record or a spare, each going back to the tree or out with
 *                what remains of the window.
 *
 * A part keeps its window to the record it meets and the neighbours it merges
 * with, all popped, so nothing else remains. A release or a replacing insert
 * pops the two straddlers and detaches the rest whole. So the planners only
 * decide, and no caller strings tree edits together.
 *
 * The bound on the walks: a balanced tree of height 23 holds at least 75,024
 * records (the Fibonacci bound), more than a tree or a detached subtree can
 * ever hold, so a path has fewer than MAP_PATH_MAX nodes and every path array
 * below is large enough.
 */

#include <stdalign.h>

#include "erx/map.h"

#define MAP_PAGE_SHIFT	12
#define MAP_PATH_MAX	24
/* The pages a 64-bit address can name. */
#define MAP_PAGES_LIMIT	(UINT64_C(1) << (64 - MAP_PAGE_SHIFT))
/* Every access a ceiling may hold; a protection never holds write and execute. */
#define MAP_ACCESS_ALL	((uint8_t)(ERX_PROT_RW | ERX_PROT_RX))
/* The ceiling of private memory and of a reservation. */
#define MAP_PRIVATE_CEILING ((uint8_t)ERX_PROT_RW)
/* A segment's source when it takes no popped record. */
#define MAP_SOURCE_SPARE 0xffu

_Static_assert((1u << MAP_PAGE_SHIFT) == ERX_PAGE_SIZE, "the page size");
_Static_assert(ERX_MAPPINGS_MAX + ERX_MAP_SPARES_MAX < 75024,
    "a path of a balanced tree this large fits MAP_PATH_MAX");

enum {
	MAP_LEFT = 0,
	MAP_RIGHT = 1
};

/* Where a segment goes: back to the tree, or out on either side of the rest. */
enum {
	MAP_TO_TREE = 0,
	MAP_TO_TREE_NEW,	/* to the tree, as the record an insert makes */
	MAP_TO_DETACHED_LOW,
	MAP_TO_DETACHED_HIGH
};

struct erx_mapping {
	erx_mapping_t	*child[2];	/* by address; MAP_LEFT, MAP_RIGHT */
	erx_mapping_view_t view;
	/* What the subtree rooted here holds, kept by map_update. */
	uint64_t	 first;		/* the lowest start */
	uint64_t	 last;		/* the highest end */
	uint64_t	 gap;		/* the widest hole between two of its records */
	uint32_t	 count;		/* its records */
	uint8_t		 kinds;		/* a bit for each kind among them */
	uint8_t		 height;	/* a leaf's is 1 */
};

/* The kinds that hold the promise of a table: all but a reservation. */
#define MAP_KIND_BIT(kind)	((uint8_t)(1u << (kind)))
#define MAP_KINDS_TOUCHING	((uint8_t)(MAP_KIND_BIT(ERX_MAP_PRIVATE) | \
    MAP_KIND_BIT(ERX_MAP_OBJECT) | MAP_KIND_BIT(ERX_MAP_DELETED) | \
    MAP_KIND_BIT(ERX_MAP_KERNEL)))

_Static_assert(ERX_MAP_KERNEL < 8, "every kind has a bit of kinds");

size_t
erx_map_record_size(void)
{
	return (sizeof(erx_mapping_t));
}

size_t
erx_map_record_align(void)
{
	return (alignof(erx_mapping_t));
}

static uint32_t
map_height(const erx_mapping_t *node)
{
	return (node == NULL ? 0 : node->height);
}

/* Recomputes a node's summary from its own fields and its children's. */
static void
map_update(erx_mapping_t *node)
{
	const erx_mapping_t *left = node->child[MAP_LEFT];
	const erx_mapping_t *right = node->child[MAP_RIGHT];
	uint64_t gap = 0;
	uint32_t hl = map_height(left), hr = map_height(right);

	node->height = (uint8_t)((hl > hr ? hl : hr) + 1);
	node->count = 1;
	node->kinds = MAP_KIND_BIT(node->view.kind);
	node->first = node->view.start.raw;
	node->last = node->view.end.raw;
	if (left != NULL) {
		uint64_t between = node->view.start.raw - left->last;

		gap = left->gap > between ? left->gap : between;
		node->count += left->count;
		node->kinds |= left->kinds;
		node->first = left->first;
	}
	if (right != NULL) {
		uint64_t between = right->first - node->view.end.raw;

		if (right->gap > gap)
			gap = right->gap;
		if (between > gap)
			gap = between;
		node->count += right->count;
		node->kinds |= right->kinds;
		node->last = right->last;
	}
	node->gap = gap;
}

/* Rotates so that node's child on the other side of dir rises over it. */
static erx_mapping_t *
map_rotate(erx_mapping_t *node, int dir)
{
	erx_mapping_t *pivot = node->child[!dir];

	node->child[!dir] = pivot->child[dir];
	pivot->child[dir] = node;
	map_update(node);
	map_update(pivot);
	return (pivot);
}

/* Restores balance at a node whose children differ in height by at most 2. */
static erx_mapping_t *
map_rebalance(erx_mapping_t *node)
{
	uint32_t hl = map_height(node->child[MAP_LEFT]);
	uint32_t hr = map_height(node->child[MAP_RIGHT]);
	int heavy;

	if ((hl > hr ? hl - hr : hr - hl) < 2) {
		map_update(node);
		return (node);
	}
	heavy = hl > hr ? MAP_LEFT : MAP_RIGHT;
	if (map_height(node->child[heavy]->child[!heavy]) >
	    map_height(node->child[heavy]->child[heavy]))
		node->child[heavy] = map_rotate(node->child[heavy], heavy);
	return (map_rotate(node, !heavy));
}

/*
 * Joins two balanced trees around one record, every page of low below it and
 * every page of high above it. It walks the taller tree's near spine down to
 * the height of the shorter, hangs the record there, and rebalances on the way
 * back: cost proportional to the difference in height.
 */
static erx_mapping_t *
map_join(erx_mapping_t *low, erx_mapping_t *middle, erx_mapping_t *high)
{
	erx_mapping_t *path[MAP_PATH_MAX];
	erx_mapping_t *cursor, *subtree;
	uint32_t hl = map_height(low), hr = map_height(high);
	uint32_t n = 0, shorter;
	int inner;

	if ((hl > hr ? hl - hr : hr - hl) < 2) {
		middle->child[MAP_LEFT] = low;
		middle->child[MAP_RIGHT] = high;
		map_update(middle);
		return (middle);
	}
	inner = hl > hr ? MAP_RIGHT : MAP_LEFT;
	cursor = hl > hr ? low : high;
	shorter = hl > hr ? hr : hl;
	while (map_height(cursor) > shorter + 1) {
		path[n++] = cursor;
		cursor = cursor->child[inner];
	}
	middle->child[!inner] = cursor;
	middle->child[inner] = hl > hr ? high : low;
	map_update(middle);
	subtree = middle;
	while (n > 0) {
		erx_mapping_t *parent = path[--n];

		parent->child[inner] = subtree;
		subtree = map_rebalance(parent);
	}
	return (subtree);
}

/*
 * Splits a tree into the records that start below key and the rest. A key must
 * cut no record. It walks one path and joins each node on it, with its other
 * subtree, to the side it belongs to; the heights telescope, so the whole split
 * is logarithmic.
 */
static void
map_split(erx_mapping_t *tree, uint64_t key, erx_mapping_t **low,
    erx_mapping_t **high)
{
	erx_mapping_t *path[MAP_PATH_MAX];
	uint32_t n = 0;

	while (tree != NULL) {
		path[n++] = tree;
		tree = tree->child[key <= tree->view.start.raw ? MAP_LEFT :
		    MAP_RIGHT];
	}
	*low = NULL;
	*high = NULL;
	while (n > 0) {
		erx_mapping_t *node = path[--n];

		if (key <= node->view.start.raw)
			*high = map_join(*high, node, node->child[MAP_RIGHT]);
		else
			*low = map_join(node->child[MAP_LEFT], node, *low);
	}
}

/* Takes the record at one end of a tree that is not empty. */
static erx_mapping_t *
map_take_end(erx_mapping_t **tree, int side)
{
	erx_mapping_t *end = *tree, *taken, *rest;

	while (end->child[side] != NULL)
		end = end->child[side];
	if (side == MAP_LEFT) {
		map_split(*tree, end->view.start.raw + 1, &taken, &rest);
	} else {
		map_split(*tree, end->view.start.raw, &rest, &taken);
	}
	*tree = rest;
	return (taken);
}

/* Joins two trees, all of low below all of high. */
static erx_mapping_t *
map_concat(erx_mapping_t *low, erx_mapping_t *high)
{
	erx_mapping_t *middle;

	if (low == NULL)
		return (high);
	if (high == NULL)
		return (low);
	middle = map_take_end(&high, MAP_LEFT);
	return (map_join(low, middle, high));
}

erx_mapping_t *
erx_map_first_from(const erx_map_tree_t *tree, erx_uvpn_t page)
{
	erx_mapping_t *node = tree->core_root, *best = NULL;

	while (node != NULL) {
		if (node->view.end.raw > page.raw) {
			best = node;
			node = node->child[MAP_LEFT];
		} else {
			node = node->child[MAP_RIGHT];
		}
	}
	return (best);
}

erx_mapping_t *
erx_map_lookup(const erx_map_tree_t *tree, erx_uvpn_t page)
{
	erx_mapping_t *node = erx_map_first_from(tree, page);

	if (node == NULL || node->view.start.raw > page.raw)
		return (NULL);
	return (node);
}

/* The highest record that starts below a page, or NULL. */
static erx_mapping_t *
map_last_below(const erx_map_tree_t *tree, uint64_t page)
{
	erx_mapping_t *node = tree->core_root, *best = NULL;

	while (node != NULL) {
		if (node->view.start.raw < page) {
			best = node;
			node = node->child[MAP_RIGHT];
		} else {
			node = node->child[MAP_LEFT];
		}
	}
	return (best);
}

/* What the records that overlap a range hold. */
typedef struct map_fold {
	uint32_t	count;
	uint8_t		kinds;
} map_fold_t;

static void
map_fold_node(map_fold_t *fold, const erx_mapping_t *node)
{
	fold->count++;
	fold->kinds |= MAP_KIND_BIT(node->view.kind);
}

static void
map_fold_subtree(map_fold_t *fold, const erx_mapping_t *node)
{
	if (node != NULL) {
		fold->count += node->count;
		fold->kinds |= node->kinds;
	}
}

/*
 * Folds the records that overlap [start, end): one walk down to the one nearest
 * the root, then one down each side, taking each subtree that lies wholly inside
 * from its summary.
 */
static map_fold_t
map_fold_range(const erx_map_tree_t *tree, uint64_t start, uint64_t end)
{
	const erx_mapping_t *node = tree->core_root, *arm;
	map_fold_t fold = { 0, 0 };

	while (node != NULL &&
	    (node->view.end.raw <= start || node->view.start.raw >= end))
		node = node->child[node->view.end.raw <= start ? MAP_RIGHT :
		    MAP_LEFT];
	if (node == NULL)
		return (fold);
	map_fold_node(&fold, node);
	arm = node->child[MAP_LEFT];
	while (arm != NULL) {
		if (arm->view.end.raw <= start) {
			arm = arm->child[MAP_RIGHT];
		} else {
			map_fold_node(&fold, arm);
			map_fold_subtree(&fold, arm->child[MAP_RIGHT]);
			arm = arm->child[MAP_LEFT];
		}
	}
	arm = node->child[MAP_RIGHT];
	while (arm != NULL) {
		if (arm->view.start.raw >= end) {
			arm = arm->child[MAP_LEFT];
		} else {
			map_fold_node(&fold, arm);
			map_fold_subtree(&fold, arm->child[MAP_LEFT]);
			arm = arm->child[MAP_RIGHT];
		}
	}
	return (fold);
}

uint32_t
erx_map_count(const erx_map_tree_t *tree)
{
	return (tree->core_root == NULL ? 0 : tree->core_root->count);
}

erx_mapping_view_t
erx_map_view(const erx_mapping_t *mapping)
{
	return (mapping->view);
}

erx_mapping_t *
erx_map_next_touching(const erx_map_tree_t *tree, erx_uvpn_t page)
{
	erx_mapping_t *node = tree->core_root, *best = NULL, *subtree = NULL;

	/*
	 * Down the path of the page: each place it turns left, the node and its
	 * right subtree lie past the page and below everything found so far.
	 */
	while (node != NULL) {
		if (node->view.end.raw <= page.raw) {
			node = node->child[MAP_RIGHT];
			continue;
		}
		if ((MAP_KIND_BIT(node->view.kind) & MAP_KINDS_TOUCHING) != 0) {
			best = node;
			subtree = NULL;
		} else if (node->child[MAP_RIGHT] != NULL &&
		    (node->child[MAP_RIGHT]->kinds & MAP_KINDS_TOUCHING) != 0) {
			best = NULL;
			subtree = node->child[MAP_RIGHT];
		}
		node = node->child[MAP_LEFT];
	}
	/* Then to the lowest touching record of the subtree that won. */
	while (subtree != NULL) {
		erx_mapping_t *left = subtree->child[MAP_LEFT];

		if (left != NULL && (left->kinds & MAP_KINDS_TOUCHING) != 0) {
			subtree = left;
		} else if ((MAP_KIND_BIT(subtree->view.kind) &
		    MAP_KINDS_TOUCHING) != 0) {
			best = subtree;
			subtree = NULL;
		} else {
			subtree = subtree->child[MAP_RIGHT];
		}
	}
	return (best);
}

bool
erx_map_span_touched(const erx_map_tree_t *tree, erx_uvpn_t start,
    erx_uvpn_t end)
{
	return ((map_fold_range(tree, start.raw, end.raw).kinds &
	    MAP_KINDS_TOUCHING) != 0);
}

int
erx_map_tree_init(erx_map_tree_t *tree, erx_uvpn_t end)
{
	uint64_t low = ERX_USER_BASE_MIN >> MAP_PAGE_SHIFT;

	if (end.raw <= low || end.raw > MAP_PAGES_LIMIT)
		return (ERX_EINVAL);
	tree->core_root = NULL;
	tree->core_generation = 0;
	tree->core_low = low;
	tree->core_high = end.raw;
	return (ERX_OK);
}

/* A byte size as pages: ERX_EINVAL unless page-aligned and not zero. */
static int
map_pages_of(uint64_t size, uint64_t *pages)
{
	if (size == 0 || (size & (ERX_PAGE_SIZE - 1)) != 0)
		return (ERX_EINVAL);
	*pages = size >> MAP_PAGE_SHIFT;
	return (ERX_OK);
}

int
erx_map_range_decode(const erx_map_tree_t *tree, uint64_t addr, uint64_t size,
    erx_map_range_t *range)
{
	uint64_t pages, start;
	int status;

	if ((addr & (ERX_PAGE_SIZE - 1)) != 0)
		return (ERX_EINVAL);
	status = map_pages_of(size, &pages);
	if (status != ERX_OK)
		return (status);
	start = addr >> MAP_PAGE_SHIFT;
	/* Both are below 2^52, so the sum cannot wrap. */
	if (start < tree->core_low || start + pages > tree->core_high)
		return (ERX_ERANGE);
	range->start.raw = start;
	range->end.raw = start + pages;
	return (ERX_OK);
}

/* Whether a range a caller holds lies inside the tree's user range. */
static bool
map_range_valid(const erx_map_tree_t *tree, const erx_map_range_t *range)
{
	return (range->start.raw >= tree->core_low &&
	    range->start.raw < range->end.raw &&
	    range->end.raw <= tree->core_high);
}

static bool
map_prot_valid(uint32_t prot)
{
	return (prot == ERX_PROT_NONE || prot == ERX_PROT_R ||
	    prot == ERX_PROT_RW || prot == ERX_PROT_RX);
}

/* Whether a ceiling allows a protection (K4). */
static bool
map_beneath(uint8_t prot, uint8_t ceiling)
{
	return ((prot & ~ceiling) == 0);
}

/*
 * The fields a record of each kind may hold. Each record the core writes comes
 * from an accepted insert, or from a part that keeps these, so erx_map_check
 * finds them true of every record.
 */
static int
map_fields_valid(erx_map_kind_t kind, const erx_memobj_t *object,
    erx_npages_t offset, uint8_t prot, uint8_t ceiling, uint8_t flags)
{
	bool names_object = kind == ERX_MAP_PRIVATE || kind == ERX_MAP_OBJECT;
	bool private_memory = kind == ERX_MAP_PRIVATE || kind == ERX_MAP_RESERVED;

	if (kind < ERX_MAP_RESERVED || kind > ERX_MAP_KERNEL)
		return (ERX_EINVAL);
	if (!map_prot_valid(prot) || (ceiling & ~MAP_ACCESS_ALL) != 0 ||
	    (flags & ~ERX_MAP_GUARDED) != 0)
		return (ERX_EINVAL);
	if (names_object != (object != NULL) || (!names_object && offset != 0))
		return (ERX_EINVAL);
	if (private_memory && ceiling != MAP_PRIVATE_CEILING)
		return (ERX_EINVAL);
	if (kind == ERX_MAP_RESERVED && (prot != ERX_PROT_NONE || flags != 0))
		return (ERX_EINVAL);
	return (map_beneath(prot, ceiling) ? ERX_OK : ERX_ERIGHTS);
}

/* The piece [start, end) of a record: its fields, its offset moved along. */
static erx_mapping_view_t
map_piece(const erx_mapping_view_t *view, uint64_t start, uint64_t end)
{
	erx_mapping_view_t piece = *view;

	if (piece.object != NULL)
		piece.offset += start - piece.start.raw;
	piece.start.raw = start;
	piece.end.raw = end;
	return (piece);
}

static void
map_plan_begin(const erx_map_tree_t *tree, erx_map_plan_t *plan)
{
	*plan = (erx_map_plan_t){ .core_stage = ERX_MAP_REFUSED,
	    .core_tree = tree, .core_generation = tree->core_generation };
}

static void
map_plan_seg(erx_map_plan_t *plan, const erx_mapping_view_t *attrs,
    uint8_t source, uint8_t placement)
{
	erx_map_seg_t *seg = &plan->core_segs[plan->core_nsegs++];

	seg->attrs = *attrs;
	seg->source = source;
	seg->placement = placement;
	if (source == MAP_SOURCE_SPARE)
		plan->nspares++;
}

/*
 * Plans taking [start, end) out of the tree, with the record new in its place
 * if there is one. It is the funnel of inserts and releases, so it alone
 * refuses a range that overlaps a kernel-user page. A record that straddles an
 * end is popped and keeps the piece outside the range; a spare takes the piece
 * inside, which leaves with the rest of the window. A record that straddles
 * both ends is popped once, and a second spare takes its piece above the range.
 * Popped records sit in apply's array in pop order: the low straddler at 0, the
 * high one after it.
 */
static int
map_plan_cut(const erx_map_tree_t *tree, uint64_t start, uint64_t end,
    const erx_mapping_view_t *new, erx_map_plan_t *plan)
{
	erx_mapping_view_t low = { 0 }, high = { 0 }, piece;
	map_fold_t fold = map_fold_range(tree, start, end);
	uint32_t added;
	bool cut_low = false, cut_high = false, straddles_both = false;

	if ((fold.kinds & MAP_KIND_BIT(ERX_MAP_KERNEL)) != 0)
		return (ERX_EEXIST);
	if (fold.count > 0) {
		low = erx_map_first_from(tree, (erx_uvpn_t){ start })->view;
		high = map_last_below(tree, end)->view;
		cut_low = low.start.raw < start;
		cut_high = high.end.raw > end;
		straddles_both = cut_low && cut_high &&
		    low.start.raw == high.start.raw;
	}
	added = (cut_low ? 1 : 0) + (cut_high ? 1 : 0) + (new != NULL ? 1 : 0);
	if (erx_map_count(tree) - fold.count + added > ERX_MAPPINGS_MAX)
		return (ERX_ENOMEM);

	plan->core_window_start = cut_low ? low.start.raw : start;
	plan->core_window_end = fold.count == 0 ? start :
	    (cut_high ? high.end.raw : end);
	plan->core_pop_front = cut_low ? 1 : 0;
	plan->core_pop_back = cut_high && !straddles_both ? 1 : 0;
	if (cut_low) {
		piece = map_piece(&low, low.start.raw, start);
		map_plan_seg(plan, &piece, 0, MAP_TO_TREE);
		piece = map_piece(&low, start,
		    low.end.raw < end ? low.end.raw : end);
		map_plan_seg(plan, &piece, MAP_SOURCE_SPARE,
		    MAP_TO_DETACHED_LOW);
	}
	if (new != NULL)
		map_plan_seg(plan, new, MAP_SOURCE_SPARE, MAP_TO_TREE_NEW);
	if (cut_high && !straddles_both) {
		piece = map_piece(&high,
		    high.start.raw > start ? high.start.raw : start, end);
		map_plan_seg(plan, &piece, MAP_SOURCE_SPARE,
		    MAP_TO_DETACHED_HIGH);
	}
	if (cut_high) {
		piece = map_piece(&high, end, high.end.raw);
		map_plan_seg(plan, &piece, straddles_both ? MAP_SOURCE_SPARE :
		    (uint8_t)plan->core_pop_front, MAP_TO_TREE);
	}
	plan->core_stage = ERX_MAP_PLANNED;
	return (ERX_OK);
}

/* The top of the highest hole of at least pages in a subtree whose gap holds one. */
static uint64_t
map_highest_hole(const erx_mapping_t *node, uint64_t pages)
{
	for (;;) {
		const erx_mapping_t *left = node->child[MAP_LEFT];
		const erx_mapping_t *right = node->child[MAP_RIGHT];

		if (right != NULL && right->gap >= pages)
			node = right;
		else if (right != NULL &&
		    right->first - node->view.end.raw >= pages)
			return (right->first);
		else if (left != NULL &&
		    node->view.start.raw - left->last >= pages)
			return (node->view.start.raw);
		else
			node = left;
	}
}

/*
 * Finds the highest free range of pages pages that ends at or below base and
 * lies inside the user range; false when there is none. The nodes the walk
 * passes on their right are, read back up, the records below the base in
 * descending order, with each one's left subtree between it and the next. So
 * the holes come in descending order too, and each subtree's summary says
 * whether to enter it.
 */
static bool
map_place(const erx_map_tree_t *tree, uint64_t pages, uint64_t base,
    uint64_t *start)
{
	const erx_mapping_t *path[MAP_PATH_MAX];
	const erx_mapping_t *node = tree->core_root;
	uint64_t top = base > tree->core_high ? tree->core_high : base;
	uint32_t n = 0;

	if (top <= tree->core_low)
		return (false);
	while (node != NULL) {
		if (node->view.start.raw < top) {
			path[n++] = node;
			node = node->child[MAP_RIGHT];
		} else {
			node = node->child[MAP_LEFT];
		}
	}
	while (n > 0) {
		const erx_mapping_t *at = path[--n];
		const erx_mapping_t *left = at->child[MAP_LEFT];

		if (top > at->view.end.raw && top - at->view.end.raw >= pages) {
			*start = top - pages;
			return (true);
		}
		top = at->view.start.raw;
		if (left == NULL)
			continue;
		if (top - left->last >= pages || left->gap >= pages) {
			if (top - left->last < pages)
				top = map_highest_hole(left, pages);
			*start = top - pages;
			return (true);
		}
		top = left->first;
	}
	if (top - tree->core_low < pages)
		return (false);
	*start = top - pages;
	return (true);
}

int
erx_map_plan_insert(const erx_map_tree_t *tree, const erx_map_insert_t *request,
    erx_map_plan_t *plan)
{
	erx_mapping_view_t new;
	uint64_t pages, start;
	int status;

	map_plan_begin(tree, plan);
	if ((request->vm_flags & ~(uint32_t)(ERX_VM_FIXED | ERX_VM_NOREPLACE)) != 0)
		return (ERX_EINVAL);
	if ((request->vm_flags & ERX_VM_NOREPLACE) != 0 &&
	    (request->vm_flags & ERX_VM_FIXED) == 0)
		return (ERX_EINVAL);
	status = map_fields_valid(request->kind, request->object, request->offset,
	    request->prot, request->ceiling, request->flags);
	if (status != ERX_OK)
		return (status);
	status = map_pages_of(request->size, &pages);
	if (status != ERX_OK)
		return (status);
	/* A thread's kernel-user page is one page. */
	if (request->kind == ERX_MAP_KERNEL && pages != 1)
		return (ERX_EINVAL);
	if (request->object != NULL &&
	    (request->offset > request->object_pages ||
	    pages > request->object_pages - request->offset))
		return (ERX_ERANGE);
	if ((request->vm_flags & ERX_VM_FIXED) != 0) {
		erx_map_range_t range;

		status = erx_map_range_decode(tree, request->addr, request->size,
		    &range);
		if (status != ERX_OK)
			return (status);
		start = range.start.raw;
		if ((request->vm_flags & ERX_VM_NOREPLACE) != 0 &&
		    map_fold_range(tree, start, start + pages).count > 0)
			return (ERX_EEXIST);
	} else if (!map_place(tree, pages, request->base.raw, &start)) {
		return (ERX_ENOMEM);
	}
	new = (erx_mapping_view_t){ .start.raw = start,
	    .end.raw = start + pages, .object = request->object,
	    .offset = request->offset, .kind = request->kind,
	    .prot = request->prot, .ceiling = request->ceiling,
	    .flags = request->flags };
	plan->range.start = new.start;
	plan->range.end = new.end;
	plan->next = new.end;
	plan->done = true;
	return (map_plan_cut(tree, start, start + pages, &new, plan));
}

int
erx_map_plan_release(const erx_map_tree_t *tree, const erx_map_range_t *range,
    erx_map_plan_t *plan)
{
	map_plan_begin(tree, plan);
	if (!map_range_valid(tree, range))
		return (ERX_EINVAL);
	plan->range = *range;
	plan->next = range->end;
	plan->done = true;
	return (map_plan_cut(tree, range->start.raw, range->end.raw, NULL, plan));
}

int
erx_map_plan_remove_kernel(const erx_map_tree_t *tree, erx_uvpn_t page,
    erx_map_plan_t *plan)
{
	const erx_mapping_t *node = erx_map_lookup(tree, page);

	map_plan_begin(tree, plan);
	if (node == NULL || node->view.kind != ERX_MAP_KERNEL ||
	    node->view.start.raw != page.raw)
		return (ERX_EINVAL);
	plan->core_window_start = node->view.start.raw;
	plan->core_window_end = node->view.end.raw;
	plan->range.start = node->view.start;
	plan->range.end = node->view.end;
	plan->next = node->view.end;
	plan->done = true;
	plan->core_stage = ERX_MAP_PLANNED;
	return (ERX_OK);
}

/* Whether two records may be one: adjacent, and everything lines up. */
static bool
map_mergeable(const erx_mapping_view_t *low, const erx_mapping_view_t *high)
{
	if (low->end.raw != high->start.raw || low->kind != high->kind ||
	    low->object != high->object || low->prot != high->prot ||
	    low->ceiling != high->ceiling || low->flags != high->flags)
		return (false);
	switch (low->kind) {
	case ERX_MAP_RESERVED:
		return (true);
	case ERX_MAP_PRIVATE:
	case ERX_MAP_OBJECT:
		return (low->offset + (low->end.raw - low->start.raw) ==
		    high->offset);
	default:
		return (false);	/* a deleted or kernel record stays its own */
	}
}

/*
 * Plans writing `after` over [start, end) of the record `at`, whole or in part,
 * merging with a neighbour that lines up. A merge needs no spare and moves one
 * boundary, so a long commit in parts stays one record. Every old record is
 * popped and reused in address order, so a record of an object stays that
 * object's, and only spares and leftovers concern its reverse map.
 *
 * It is the funnel of every part that writes, so it holds K4 for all of them:
 * no ceiling changes, what it writes suits its kind, and a kernel-user record
 * is never written.
 */
static int
map_plan_edit(const erx_map_tree_t *tree, const erx_mapping_view_t *at,
    const erx_mapping_view_t *after, erx_map_plan_t *plan)
{
	erx_mapping_view_t pieces[3], merged = *after;
	const erx_mapping_t *neighbour;
	uint32_t npieces = 0, npopped = 1;
	bool has_low = at->start.raw < after->start.raw;
	bool has_high = after->end.raw < at->end.raw;
	int status;

	if (at->kind == ERX_MAP_KERNEL)
		return (ERX_EEXIST);
	if (after->ceiling != at->ceiling)
		return (ERX_ERIGHTS);
	status = map_fields_valid(after->kind, after->object, after->offset,
	    after->prot, after->ceiling, after->flags);
	if (status != ERX_OK)
		return (status);
	plan->core_window_start = at->start.raw;
	plan->core_window_end = at->end.raw;
	if (!has_low) {
		neighbour = map_last_below(tree, at->start.raw);
		if (neighbour != NULL && map_mergeable(&neighbour->view, after)) {
			merged.start = neighbour->view.start;
			merged.offset = neighbour->view.offset;
			plan->core_window_start = neighbour->view.start.raw;
			npopped++;
		}
	}
	if (!has_high) {
		neighbour = erx_map_first_from(tree, at->end);
		if (neighbour != NULL && map_mergeable(after, &neighbour->view)) {
			merged.end = neighbour->view.end;
			plan->core_window_end = neighbour->view.end.raw;
			npopped++;
		}
	}
	if (has_low)
		pieces[npieces++] = map_piece(at, at->start.raw,
		    after->start.raw);
	pieces[npieces++] = merged;
	if (has_high)
		pieces[npieces++] = map_piece(at, after->end.raw, at->end.raw);
	if (erx_map_count(tree) - npopped + npieces > ERX_MAPPINGS_MAX)
		return (ERX_ENOMEM);
	plan->core_pop_front = npopped;
	plan->edits = npopped > npieces ? npopped : npieces;
	for (uint32_t i = 0; i < npieces; i++)
		map_plan_seg(plan, &pieces[i],
		    i < npopped ? (uint8_t)i : MAP_SOURCE_SPARE, MAP_TO_TREE);
	plan->core_stage = ERX_MAP_PLANNED;
	return (ERX_OK);
}

/* Where a part acts and where the next one starts. */
static void
map_plan_range(const erx_map_part_request_t *request, uint64_t start,
    uint64_t end, erx_map_plan_t *plan)
{
	plan->range.start.raw = start;
	plan->range.end.raw = end;
	plan->next.raw = end;
	plan->done = end >= request->range.end.raw;
}

/* Plans a part that writes no record, over [start, end). */
static int
map_plan_nothing(const erx_map_part_request_t *request, uint64_t start,
    uint64_t end, erx_map_plan_t *plan)
{
	map_plan_range(request, start, end, plan);
	plan->core_stage = ERX_MAP_PLANNED;
	return (ERX_OK);
}

/*
 * Plans a part's commit of the reservation `at` from start, with protection
 * prot: at most a part's pages, each of them charged before the records move.
 * The offset is the page's own number, so no two pages of one private object
 * ever name one offset, whatever the caller commits and decommits (K5), and
 * successive commits line up and merge.
 */
static int
map_plan_commit(const erx_map_tree_t *tree,
    const erx_map_part_request_t *request, const erx_mapping_view_t *at,
    uint64_t start, uint64_t end, uint8_t prot, erx_map_plan_t *plan)
{
	erx_mapping_view_t after = *at;

	if (request->object == NULL)
		return (ERX_EINVAL);
	if (end - start > ERX_RANGE_PART_PAGES)
		end = start + ERX_RANGE_PART_PAGES;
	after.start.raw = start;
	after.end.raw = end;
	after.kind = ERX_MAP_PRIVATE;
	after.object = request->object;
	after.offset = start;
	after.prot = prot;
	plan->charge_pages = end - start;
	map_plan_range(request, start, end, plan);
	return (map_plan_edit(tree, at, &after, plan));
}

/* Plans a part's change of protection over [start, end) of `at`. */
static int
map_plan_protection(const erx_map_tree_t *tree,
    const erx_map_part_request_t *request, const erx_mapping_view_t *at,
    uint64_t start, uint64_t end, uint8_t prot, erx_map_plan_t *plan)
{
	erx_mapping_view_t after;

	if (at->prot == prot)
		return (map_plan_nothing(request, start, end, plan));
	after = map_piece(at, start, end);
	after.prot = prot;
	/* An access it no longer allows; a deleted record has no translation. */
	plan->clears = at->kind != ERX_MAP_DELETED && (at->prot & ~prot) != 0;
	map_plan_range(request, start, end, plan);
	return (map_plan_edit(tree, at, &after, plan));
}

/* Plans a part's decommit over [start, end) of `at`. */
static int
map_plan_decommit(const erx_map_tree_t *tree,
    const erx_map_part_request_t *request, const erx_mapping_view_t *at,
    uint64_t start, uint64_t end, erx_map_plan_t *plan)
{
	erx_mapping_view_t after;

	if (at->kind == ERX_MAP_OBJECT) {
		/* Trimming never meets sharing: only its translations go. */
		plan->clears = true;
		return (map_plan_nothing(request, start, end, plan));
	}
	if (at->kind != ERX_MAP_PRIVATE)
		return (map_plan_nothing(request, start, end, plan));
	after = (erx_mapping_view_t){ .start.raw = start, .end.raw = end,
	    .kind = ERX_MAP_RESERVED, .prot = ERX_PROT_NONE,
	    .ceiling = MAP_PRIVATE_CEILING };
	plan->clears = true;
	plan->trim_pages = end - start;
	plan->trim_object = at->object;
	plan->trim_offset = at->offset + (start - at->start.raw);
	map_plan_range(request, start, end, plan);
	return (map_plan_edit(tree, at, &after, plan));
}

/* Decides one part from the first record at or after the cursor. */
static int
map_plan_part_at(const erx_map_tree_t *tree,
    const erx_map_part_request_t *request, erx_map_plan_t *plan)
{
	const erx_mapping_t *first;
	erx_mapping_view_t at;
	uint64_t end = request->range.end.raw, cursor = request->cursor.raw;
	uint64_t start, stop;
	uint8_t prot;

	if (!map_range_valid(tree, &request->range) ||
	    cursor < request->range.start.raw || cursor > end)
		return (ERX_EINVAL);
	if (request->op != ERX_MAP_COMMIT && request->op != ERX_MAP_DECOMMIT &&
	    request->op != ERX_MAP_PROTECT)
		return (ERX_EINVAL);
	if (request->op == ERX_MAP_PROTECT && !map_prot_valid(request->prot))
		return (ERX_EINVAL);
	if (cursor == end)
		return (map_plan_nothing(request, end, end, plan));
	first = erx_map_first_from(tree, request->cursor);
	if (first == NULL || first->view.start.raw >= end) {
		if (request->op == ERX_MAP_PROTECT)
			return (ERX_ERANGE);
		return (map_plan_nothing(request, cursor, end, plan));
	}
	at = first->view;
	if (request->op == ERX_MAP_PROTECT && at.start.raw > cursor)
		return (ERX_ERANGE);
	if (at.kind == ERX_MAP_KERNEL)
		return (ERX_EEXIST);
	start = at.start.raw > cursor ? at.start.raw : cursor;
	stop = at.end.raw < end ? at.end.raw : end;
	switch (request->op) {
	case ERX_MAP_DECOMMIT:
		return (map_plan_decommit(tree, request, &at, start, stop, plan));
	case ERX_MAP_COMMIT:
		if (at.kind != ERX_MAP_RESERVED && at.kind != ERX_MAP_PRIVATE)
			return (map_plan_nothing(request, start, stop, plan));
		prot = ERX_PROT_RW;
		break;
	case ERX_MAP_PROTECT:
	default:
		if (!map_beneath(request->prot, at.ceiling))
			return (ERX_ERIGHTS);
		prot = request->prot;
		break;
	}
	if (at.kind == ERX_MAP_RESERVED && prot != ERX_PROT_NONE)
		return (map_plan_commit(tree, request, &at, start, stop, prot,
		    plan));
	return (map_plan_protection(tree, request, &at, start, stop, prot, plan));
}

int
erx_map_plan_part(const erx_map_tree_t *tree,
    const erx_map_part_request_t *request, erx_map_plan_t *plan)
{
	int status;

	map_plan_begin(tree, plan);
	status = map_plan_part_at(tree, request, plan);
	/* A refusal reports nothing for a caller to act on. */
	if (status != ERX_OK)
		map_plan_begin(tree, plan);
	return (status);
}

/* Writes a piece into a record that is out of the tree. */
static void
map_write(erx_mapping_t *record, const erx_mapping_view_t *attrs)
{
	record->view = *attrs;
	record->child[MAP_LEFT] = NULL;
	record->child[MAP_RIGHT] = NULL;
}

int
erx_map_apply(erx_map_tree_t *tree, erx_map_plan_t *plan, erx_mapping_t **spares,
    uint32_t nspares, erx_map_result_t *result)
{
	erx_mapping_t *popped[3] = { NULL, NULL, NULL };
	erx_mapping_t *kept, *above, *rest, *leaving;
	uint32_t npopped = 0, spare = 0;
	bool used[3] = { false, false, false };

	*result = (erx_map_result_t){ .detached.root = NULL };
	if (plan->core_stage != ERX_MAP_PLANNED || plan->core_tree != tree)
		return (ERX_EINVAL);
	plan->core_stage = ERX_MAP_SPENT;
	if (plan->core_generation != tree->core_generation)
		return (ERX_ESTALE);
	if (nspares < plan->nspares)
		return (ERX_ENOMEM);
	if (nspares > plan->nspares)
		return (ERX_EINVAL);
	if (plan->core_nsegs == 0 &&
	    plan->core_window_start == plan->core_window_end)
		return (ERX_OK);

	tree->core_generation++;
	/* kept grows to all that stays below the plan's end; above stays too. */
	map_split(tree->core_root, plan->core_window_start, &kept, &rest);
	map_split(rest, plan->core_window_end, &leaving, &above);
	while (npopped < plan->core_pop_front)
		popped[npopped++] = map_take_end(&leaving, MAP_LEFT);
	if (plan->core_pop_back > 0)
		popped[npopped++] = map_take_end(&leaving, MAP_RIGHT);
	for (uint32_t i = 0; i < plan->core_nsegs; i++) {
		const erx_map_seg_t *seg = &plan->core_segs[i];
		erx_mapping_t *record;

		if (seg->source == MAP_SOURCE_SPARE) {
			record = spares[spare++];
			if (seg->attrs.kind == ERX_MAP_OBJECT)
				result->added[result->nadded++] = record;
		} else {
			record = popped[seg->source];
			used[seg->source] = true;
		}
		map_write(record, &seg->attrs);
		switch (seg->placement) {
		case MAP_TO_DETACHED_LOW:
			leaving = map_join(NULL, record, leaving);
			break;
		case MAP_TO_DETACHED_HIGH:
			leaving = map_join(leaving, record, NULL);
			break;
		case MAP_TO_TREE_NEW:
			result->inserted = record;
			kept = map_join(kept, record, NULL);
			break;
		case MAP_TO_TREE:
		default:
			kept = map_join(kept, record, NULL);
			break;
		}
	}
	for (uint32_t i = 0; i < npopped; i++)
		if (!used[i])
			result->freed[result->nfreed++] = popped[i];
	tree->core_root = map_concat(kept, above);
	result->detached.root = leaving;
	result->detached.count = leaving == NULL ? 0 : leaving->count;
	return (ERX_OK);
}

erx_mapping_t *
erx_map_detached_next(erx_map_detached_t *detached)
{
	erx_mapping_t *top = detached->root;

	if (top == NULL)
		return (NULL);
	/*
	 * Rotates the lowest record to the top. A rotation moves one node off
	 * the left spine for good, and no left spine is longer than a path of
	 * the original tree. The summaries are not kept: nothing but this
	 * function reads a detached tree.
	 */
	while (top->child[MAP_LEFT] != NULL) {
		erx_mapping_t *left = top->child[MAP_LEFT];

		top->child[MAP_LEFT] = left->child[MAP_RIGHT];
		left->child[MAP_RIGHT] = top;
		top = left;
	}
	detached->root = top->child[MAP_RIGHT];
	detached->count--;
	top->child[MAP_RIGHT] = NULL;
	return (top);
}

void
erx_map_take_all(erx_map_tree_t *tree, erx_map_detached_t *detached)
{
	detached->root = tree->core_root;
	detached->count = erx_map_count(tree);
	tree->core_root = NULL;
	tree->core_generation++;
}

int
erx_map_mark_deleted(erx_map_tree_t *tree, erx_mapping_t *mapping)
{
	erx_mapping_t *path[MAP_PATH_MAX];
	erx_mapping_t *node = tree->core_root;
	uint64_t start = mapping->view.start.raw;
	uint32_t n = 0;

	while (node != NULL && node != mapping) {
		path[n++] = node;
		node = node->child[start < node->view.start.raw ? MAP_LEFT :
		    MAP_RIGHT];
	}
	if (node == NULL)
		return (ERX_ESTALE);
	if (mapping->view.kind != ERX_MAP_OBJECT)
		return (ERX_EINVAL);
	mapping->view.kind = ERX_MAP_DELETED;
	mapping->view.object = NULL;
	mapping->view.offset = 0;
	map_update(mapping);
	while (n > 0)
		map_update(path[--n]);
	tree->core_generation++;
	return (ERX_OK);
}

int
erx_map_edges(const erx_map_tree_t *tree, const erx_map_range_t *range,
    erx_npages_t span, erx_map_edges_t *edges)
{
	uint64_t start = range->start.raw, end = range->end.raw;
	uint64_t low_region, high_region, covered_start, covered_end;
	bool start_cuts, end_cuts;

	*edges = (erx_map_edges_t){ .nedges = 0 };
	if (span == 0 || span > MAP_PAGES_LIMIT || !map_range_valid(tree, range))
		return (ERX_EINVAL);
	low_region = start - start % span;
	high_region = end - end % span;
	start_cuts = start != low_region;
	end_cuts = end != high_region;
	/* Both are at most 2^52, so neither sum wraps. */
	covered_start = start_cuts ? low_region + span : start;
	covered_end = high_region;
	if (start_cuts) {
		edges->edge[edges->nedges].start.raw = low_region;
		edges->edge[edges->nedges].keep = erx_map_span_touched(tree,
		    (erx_uvpn_t){ low_region }, (erx_uvpn_t){ low_region + span });
		edges->nedges++;
	}
	/* A range inside one region has that one edge, already counted. */
	if (end_cuts && !(start_cuts && high_region == low_region)) {
		edges->edge[edges->nedges].start.raw = high_region;
		edges->edge[edges->nedges].keep = erx_map_span_touched(tree,
		    (erx_uvpn_t){ high_region },
		    (erx_uvpn_t){ high_region + span });
		edges->nedges++;
	}
	if (covered_start < covered_end) {
		edges->covered_start.raw = covered_start;
		edges->covered_end.raw = covered_end;
		edges->covered_touched = erx_map_span_touched(tree,
		    edges->covered_start, edges->covered_end);
	}
	return (ERX_OK);
}

/* One record's own fields and its place among its neighbours in address order. */
static const char *
map_check_record(const erx_map_tree_t *tree, const erx_mapping_t *node,
    uint64_t *previous_end)
{
	const erx_mapping_view_t *view = &node->view;

	if (view->start.raw >= view->end.raw)
		return ("a record is empty");
	if (view->start.raw < *previous_end)
		return ("two records overlap");
	if (view->start.raw < tree->core_low || view->end.raw > tree->core_high)
		return ("a record lies outside the user range");
	*previous_end = view->end.raw;
	if (map_fields_valid(view->kind, view->object, view->offset, view->prot,
	    view->ceiling, view->flags) != ERX_OK)
		return ("a record's fields do not suit its kind");
	return (NULL);
}

/* A node's summary, against what its children's say. */
static const char *
map_check_summary(const erx_mapping_t *node)
{
	erx_mapping_t copy = *node;
	uint32_t hl = map_height(node->child[MAP_LEFT]);
	uint32_t hr = map_height(node->child[MAP_RIGHT]);

	if ((hl > hr ? hl - hr : hr - hl) > 1)
		return ("the tree is out of balance");
	map_update(&copy);
	if (copy.height != node->height || copy.count != node->count ||
	    copy.kinds != node->kinds || copy.first != node->first ||
	    copy.last != node->last || copy.gap != node->gap)
		return ("a node's summary is wrong");
	return (NULL);
}

const char *
erx_map_check(const erx_map_tree_t *tree)
{
	const erx_mapping_t *stack[MAP_PATH_MAX];
	const erx_mapping_t *node = tree->core_root;
	const char *problem;
	uint64_t previous_end = 0;
	uint32_t n = 0;

	if (tree->core_low >= tree->core_high || tree->core_high > MAP_PAGES_LIMIT)
		return ("the user range is malformed");
	if (erx_map_count(tree) > ERX_MAPPINGS_MAX)
		return ("the tree holds too many records");
	/* In order, with a stack no deeper than the height, which is checked. */
	while (node != NULL || n > 0) {
		while (node != NULL) {
			if (n == MAP_PATH_MAX)
				return ("the tree is too deep");
			stack[n++] = node;
			node = node->child[MAP_LEFT];
		}
		node = stack[--n];
		problem = map_check_record(tree, node, &previous_end);
		if (problem == NULL)
			problem = map_check_summary(node);
		if (problem != NULL)
			return (problem);
		node = node->child[MAP_RIGHT];
	}
	return (NULL);
}
