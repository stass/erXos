/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * One seeded violation of the stack proof per exported function, each the
 * entry of its own proof: a frame above the 1 KiB cap; recursion through
 * two calls, which no optimization level makes a tail jump; and mutual
 * recursion through ordinary tail calls, which -O2 makes tail jumps and
 * -O0 leaves calls, so it passes only the optimized proof. bounded calls a
 * function outside the object, which passes only when it is a declared
 * leaf.
 */

struct erx_fixture_node {
	struct erx_fixture_node *left;
	struct erx_fixture_node *right;
};

int erx_fixture_leaf(int value);
int ping(int value);

int
big_frame(int index)
{
	volatile char buffer[1100];

	buffer[index & 1023] = 1;
	return buffer[0];
}

int
walk(const struct erx_fixture_node *node)
{
	if (node == 0)
		return 0;
	return walk(node->left) + walk(node->right) + 1;
}

__attribute__((noinline)) int
pong(int value)
{
	if (value <= 0)
		return erx_fixture_leaf(value);
	return ping(value - 1);
}

__attribute__((noinline)) int
ping(int value)
{
	if (value <= 0)
		return 1;
	return pong(value - 1);
}

int
bounded(int value)
{
	return erx_fixture_leaf(value) + 1;
}
