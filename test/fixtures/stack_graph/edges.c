/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Every edge the stack graph records, each in a function of its own: a
 * call of a static function, an ordinary tail call, an indirect call and
 * an indirect tail call through a table the compiler cannot see, a
 * musttail call of an external function, mutual recursion through
 * musttail, which the optimizer is free to fold into a loop, and a loop
 * whose branches stay inside its function. erx_fixture_external is defined
 * in no object, so it is an external of the graph.
 */

int erx_fixture_external(int value);
extern int (*erx_fixture_handlers[2])(int);

int count_odd(int value);

__attribute__((noinline)) static int
scaled(int value)
{
	return erx_fixture_external(value) * 3;
}

int
plain_call(int value)
{
	return scaled(value) + 1;
}

int
ordinary_tail(int value)
{
	return erx_fixture_external(value + 1);
}

int
indirect_call(int index, int value)
{
	return erx_fixture_handlers[index & 1](value) + 1;
}

int
indirect_tail(int index, int value)
{
	return erx_fixture_handlers[index & 1](value);
}

int
count_even(int value)
{
	if (value <= 0)
		return 0;
	__attribute__((musttail)) return count_odd(value - 1);
}

int
count_odd(int value)
{
	if (value <= 0)
		return 1;
	__attribute__((musttail)) return count_even(value - 1);
}

int
forwarded(int value)
{
	__attribute__((musttail)) return erx_fixture_external(value);
}

int
summed(int count)
{
	int sum = 0;

	for (int i = 0; i < count; i++)
		sum += erx_fixture_external(i);
	return sum;
}
