# Code style

erXos is written in C17, Erlang and Ruby, with assembly only where C cannot
express an operation. C follows FreeBSD `style(9)` (Kernel Normal
Form), Erlang follows the conventions of the Erlang/OTP sources, and Ruby
follows the community Ruby style; the project conventions below take
precedence over all three. These rules apply to code erXos writes. Imported
code (OTP, musl and the stopgap Fiasco fork) keeps its own style and license
notices, and an edit to an imported file follows that file's style. This
guide is engineering practice: it binds how the code is written, not what it
computes.

**Human readability is a requirement.** Code should make its purpose, data
flow, invariants and failure paths understandable to another developer.
Use clear names and straightforward control flow, separate logical phases
visually, and explain non-obvious reasoning or ownership in concise comments.
Prefer several clear steps when combining operations would obscure their order
or purpose. Review readability explicitly before committing; passing tests and
mechanical formatting checks alone do not establish it.

## Readability standard

The standard applies to every language in the tree.

Write for a maintainer encountering the code for the first time. The main
flow should read almost like English: validate the inputs, prepare the result,
perform the operation, and publish the result. Use the actual operations of
the subsystem in those steps. The reader should see what a function accomplishes
before having to understand how its tables are laid out.

Before writing nontrivial code, read the analogous functions already in the
tree and identify what makes their structure understandable. The qualities to
look for, and to aim at:

* Named stages with immediate error checks make execution order visible; a
  file comment explains why a failed stage prevents later ones from running.
* Validation precedes reading and state advances only after success; the
  explanation includes the boundary case that motivates the algorithm.
* Allocation, initialization and publication of a new object are distinct
  steps; the comment explains why the fallible step must come first.
* Names carry their role and saved state, and comments explain restoration
  obligations -- or why there are none.

When a function in the tree exemplifies one of these qualities, cite it next
to the quality; examples are chosen because they read well, and a function
that reads better replaces one. Code in the tree that departs from this guide
is not a precedent: the guide governs.

### Structure around meaningful operations

A function should have one coherent responsibility and a clear level of
detail. An operation that coordinates several stages should express those
stages through named helpers. A helper that implements a traversal may show
its indexing directly. Avoid mixing the policy decision, table growth,
copying and index translation in one deeply nested loop.

Extract a helper when its name expresses a meaningful operation or its contract
contains reasoning the caller should not have to repeat. Do not create a
helper for every assignment or scatter a simple operation across many tiny
functions. The caller must remain understandable without opening every callee.
Prefer a little explicit repetition to a generic framework that hides the
algorithm. Function length alone does not measure readability.

Keep the normal path visible. Reject invalid input early, skip irrelevant
entries with `continue` when appropriate, and put distinct phases in separate
blocks. If nesting comes from several responsibilities, separate those
responsibilities instead of merely moving the same tangle into another function.

### Names and representations must explain the data

Use verbs and domain nouns for operations: a name such as
`map_initial_stack` explains more than `process_entry`. Predicate names should
describe a question; a function that builds an address space or performs a
fallible operation needs an action name and an explicit failure contract.

Name values by their role where ambiguity matters. Distinguish a physical
address from a virtual address, a page number from a byte address, a
capability value from a capability-table index, a byte count from an element
count, and a ring's occupied length from its free space. For example,
`stack_top_va`, `cap_slot_index` and `saved_irq_mask` carry information that
`top`, `index` and `saved` may lose. A short `i` or `n` is fine in a small
loop with one obvious interpretation. Do not burden every name with context
already clear from its scope.

Represent a logical object explicitly. Prefer a mapping with named `base`,
`length` and `rights` fields to an integer array whose positions have different
meanings. Use enums or designated fields when positional booleans or numeric
tags would require the reader to memorize a convention. Compact representations
are appropriate when justified by the format, the hardware, or measured cost;
document their meaning once near the representation and localize their encoding
and decoding. Do not spread sentinel handling, bit packing and index
conversions through unrelated code.

### Make execution and failure handling explicit

Do not hide several state-changing steps in `&&`, `||`, a ternary, or nested
function arguments. Give each meaningful operation its own statement and check
its result before continuing. Compound pure predicates and a direct check of
one fallible operation remain ordinary, readable code.

For example, these illustrative helpers populate two regions of a new address
space and report failure with `false`. Avoid compressing their sequence:

```c
return (map_image_text(space) && map_initial_stack(space));
```

Make the stages visible:

```c
if (!map_image_text(space))
	return (false);

if (!map_initial_stack(space))
	return (false);

return (true);
```

The helper names must also describe coherent operations; expanding a boolean
expression alone is not enough. Preserve the existing failure contract when
restructuring code. In particular, distinguish invalid input, resource
exhaustion, quota exhaustion and internal failure where the interface
distinguishes them.

Make ownership and publication easy to locate. Show what is borrowed, what is
owned, and what cleans up after an unsuccessful operation. Prefer preparing a
complete object before making it visible to its consumer, whether the consumer
is another CPU, another domain or a device. If construction is incremental,
make the partial state and its cleanup contract explicit. Keep count updates
separate from complex assignments when they determine which entries are
initialized or visible. Resource accounting and bounds checks must remain part
of the operation's contract; do not remove them to shorten the flow.

### Explain the model before the mechanics

For a non-obvious algorithm, give a self-contained explanation near its
implementation: what its objects represent, how information moves, and what
makes the process finish with the required result. State representation
conventions where they are defined. Explain a surprising boundary case with a
small example when that is clearer than abstract shorthand.

For instance, saying that each thread enters a run queue once is insufficient
if the reader cannot tell what makes a thread runnable, who removes it, or
which CPU may touch the queue. Explain those relationships, then let the code
express the individual steps. The explanation may need several sentences or
paragraphs. A one-line comment is not inherently better. Do not use comments
to compensate for names or helper boundaries that can be made clearer.

## Readable tests

Tests follow the same standard as production code. Name the scenario and make
its setup, operation, and expected result distinct. Use fixture helpers that
express the state being built; avoid nested mutations in call arguments that
force the reader to reconstruct the fixture's state. Use named fields when
positional data would obscure the case being tested.

Keep an independent oracle understandable on its own. Explain the property it
checks and how it differs from the production approach; copying the
implementation into the test does not provide independent evidence. A failed
assertion should identify the relevant case and expectation without requiring
a debugger to discover what the test intended. A QEMU transcript test names
the line it waits for and the deadline it waits under.

## Functional core

Kernel and runtime code decides in pure functions and acts in a thin layer
of effects. A pure function receives everything it reads as arguments and
returns its decision: it reads no hardware, no global state and no clock, so
it builds for the host and its tests reach every branch there. The effect
layer carries the decision out (it writes page tables, programs devices,
schedules processes and delivers messages) and decides nothing a pure
function could decide.

The core takes four shapes:

* **Pure decisions.** A check or a computation over plain values, such as
  whether a protection change stays beneath a mapping's ceiling or which run
  queue a woken process joins, is a function of its arguments.
* **Pure state machines.** A protocol is a function from the current state
  and an event to the next state and the actions to perform, and the caller
  performs them. Protocol state machines (the scheduling contract between
  the kernel and a runtime, signal delivery in `erx_sig_step`, the router's
  connections, cross-domain links and monitors, the domain lifecycle, the
  pipe core, the update trial, host-link sessions) are explored
  exhaustively on the host:
  every event in every reachable state, up to a stated depth.
* **Plan, then apply.** An operation that changes several things at once,
  such as mapping a range, tearing down a domain or installing code, first
  builds a complete plan and validates it whole. Only a valid plan is
  applied, and applying it cannot fail halfway for a reason that validation
  could have caught.
* **Pure data structures.** Allocators, capability tables, queues and
  validators operate only on memory they are handed, so they are tested on
  the host like any other library.

A combination of values that must never occur is not a pair of flags that
every writer must keep consistent; it is a variant that cannot express it.

Code in which the caller strings helpers together and must call them in the
right order is the shape that keeps producing sequencing bugs. Convert it so
that the core returns what to do and one function does it:

```c
	/* Before: every caller must remember the order. */
	if (!erx_range_is_free(as, va, len))
		return (ERX_EBUSY);
	erx_range_reserve(as, va, len);
	erx_pt_map(as, va, pages, prot);
	erx_tlb_sync(as);

	/* After: the plan is computed and validated whole, then applied. */
	error = erx_map_plan(&as->layout, &req, &plan);
	if (error != 0)
		return (error);
	erx_map_apply(as, &plan);
```

Erlang code takes the same shape: pure functions decide, and the
`gen_server` or `gen_statem` callback performs the effects their result
names.

## C

### Layout and whitespace

* Use tabs for indentation, with tab stops every eight columns. Indent
  continuations four columns beyond the statement's indentation, using tabs
  followed by spaces. Never put spaces before tabs or leave trailing whitespace.
* Aim for 80 columns. Keep searchable diagnostic strings intact; a slightly
  longer line is acceptable when it reads better.
* Separate logical blocks with one blank line: declarations, validation,
  preparation, processing, and cleanup should be visually distinct when they
  perform separate tasks. Keep closely related statements together; do not
  insert a blank line after every statement.
* Put one blank line between declarations and statements, and between functions.
  Do not add a blank line immediately inside a block with no declarations or
  before its closing brace.
* Put spaces after control keywords and commas, and around binary operators.
  Do not put spaces after function names, inside parentheses or brackets, or
  between unary operators and their operands.
* Attach pointer stars to the name: `const char *name`, `erx_thread_t *thread`.
  Write casts and `sizeof` without a following space: `(size_t)n`,
  `sizeof(*thread)`. Always parenthesize the operand of `sizeof`.
* Wrap long expressions with the operator at the end of the preceding line.
  Add parentheses where they clarify precedence.
* Source files must be ASCII-only, including comments and strings. Markdown
  prose is exempt.

### Names, types, and declarations

* Use `lower_snake_case` for functions, variables, struct tags, and typedefs.
  Use uppercase names for constants, enum values, and macros with side effects.
  Avoid identifiers reserved to the implementation.
* **Give every erXos-defined struct a matching `_t` typedef and use that
  typedef in declarations, fields, parameters, and return types.** For example,
  `typedef struct erx_ring erx_ring_t;`. Keep the struct tag for its definition
  and interfaces that require a tag, such as `queue(3)` macros.
* Typedef the struct itself, never its pointer: write `erx_ring_t *`, not a
  typedef that hides the indirection. Define each typedef in its owning header
  or source file; include that header where needed instead of duplicating it.
  Forward typedefs support opaque and self-referential types:

```c
typedef struct erx_ring erx_ring_t;

struct erx_ring {
	erx_ring_t	*next;
	size_t		 capacity;
	uint32_t	 head;
	uint32_t	 tail;
};
```

* Put shared types in the appropriate header and private types near the top
  of their source file. Separate type definitions from object declarations;
  use `extern` for shared object declarations in headers.
* Give each struct member its own line. Order members by logical use, then
  size (largest first), then name. Align member names with one or two tabs
  where practical; use one space after unusually long types. A struct whose
  layout is fixed by hardware or by an ABI keeps that layout, states so in a
  comment, and pins it with `_Static_assert()` on its size and offsets.
* Put local declarations at the start of their block, ordered by size and
  then name. Simple initializers are fine; put complicated calls in the
  statement block. A `for` loop may declare its counter in the initializer.
* Prefer standard fixed-width types such as `uint32_t`, and `bool`, `true`,
  and `false` from `<stdbool.h>`. Use designated initializers when they help
  identify fields, and `_Static_assert()` for compile-time assertions.
* Give values that must not be mixed distinct types so that mixing them does
  not compile. Physical addresses, kernel virtual addresses, user virtual
  addresses, page frame numbers and capability values are one-member
  structs, not bare integers or pointers, and converting one to another is
  a named function:

```c
typedef struct erx_pa erx_pa_t;		/* physical address */
typedef struct erx_kva erx_kva_t;	/* kernel virtual address */

struct erx_pa {
	uint64_t	raw;
};

struct erx_kva {
	uint64_t	raw;
};

static inline erx_kva_t
erx_pa_to_kva(erx_pa_t pa)
{
	return ((erx_kva_t){ .raw = pa.raw + ERX_PHYSMAP_BASE });
}
```

* Prefix erXos's external identifiers with `erx_` (functions, types,
  objects) and `ERX_` (macros, enum values). ERTS owns `erts_`, `erl_` and
  `ERTS_`; never use them in erXos code.
* Mark unused parameters and locals with `ERX_UNUSED` from the project's
  `cdefs.h`; do not use `(void)arg;` casts.

### Functions and control flow

* Decide in pure functions and act in a thin effect layer, as described
  under [Functional core](#functional-core).
* Declare function prototypes at file scope: private `static` functions near
  the top of the source file, shared functions in their owning header. Keep
  prototypes in logical order, alphabetically where practical. Use prototype
  syntax, including `(void)` for no parameters; never use K&R declarations.
* Put a function definition's return type on its own line and its opening
  brace on the next line after the parameter list.
* Put control-flow opening braces on the same line as the condition. Write
  `} else {` on one line. Braces around single statements may be omitted when
  clear; be consistent within each function.
* Align `case` and `default` with `switch`, and indent their bodies one tab.
  Mark intentional fallthrough with `/* FALLTHROUGH */`.
* Use `for (;;)` for an indefinite loop. Put an empty loop body's semicolon
  on its own line.
* Compare pointers with `NULL`, numbers with `0`, and characters with `'\0'`.
  Only booleans should be tested directly or with unary `!`.
* Use `NULL` without a cast when the pointer type is known. Supply the required
  pointer type for a null variadic argument. Do not cast a `void *` result in C.
* Parenthesize returned values: `return (result);`. A void function may end
  without a `return` statement.

### Comments

* Add a concise comment before a logical block only when its purpose,
  constraint, or reasoning is not obvious from the code. Explain the reason
  for a check or ordering requirement instead of narrating statements.
* Make comments self-contained and self-explanatory. State the relevant
  invariant or contract directly; do not refer to design documents or require
  the reader to follow a document path, section number, or link. An
  architectural requirement may cite the Arm Architecture Reference Manual
  rule it implements, in addition to stating the requirement.
* Do not put temporal or campaign markers in comments: change history, dates
  of fixes, phase labels, issue references, and commit references belong in
  commit messages. Preserve required copyright and license notices.
* Use enough sentences to explain the reasoning. Keep a simple observation
  short; give an algorithm, representation, or subtle contract the explanation
  it needs. Document non-obvious ownership, lifetime, units, failure behavior,
  and concurrency requirements where needed. Remove repetition and irrelevant
  detail, not information the reader needs to understand the code.
* Keep comment syntax consistent within each file. Use `/* ... */` for short
  comments in C-style files; use aligned leading `*` lines for a necessary
  multiline comment. Avoid decorative banners and section-number hierarchies.

This example separates validation from the result and explains a protocol
constraint that the arithmetic alone does not convey:

```c
static bool
erx_ring_has_space(const erx_ring_t *ring, size_t record_bytes)
{
	size_t free_bytes;

	/*
	 * One slot always stays empty so that a full ring and an empty ring
	 * have different head and tail values.
	 */
	free_bytes = ring->capacity - erx_ring_used(ring) - 1;

	return (record_bytes <= free_bytes);
}
```

### File organization and headers

* Keep required copyright and SPDX notices at the top in a comment starting
  in column one, followed by a blank line. Preserve attribution in imported
  code; do not add revision-history annotations to erXos code.
* Group includes in this order, with a blank line between groups:
  1. System headers (`<sys/...>`). Put `<sys/types.h>` or `<sys/param.h>`
     first when needed; do not include both. Sort the rest alphabetically.
     Freestanding code includes only the compiler's freestanding headers
     (`<stdbool.h>`, `<stddef.h>`, `<stdint.h>`, `<stdatomic.h>` and the like).
  2. Network headers, when needed.
  3. Other library headers, sorted alphabetically.
  4. Project headers, sorted alphabetically.
* Use angle brackets for system and installed library headers, and double
  quotes for local headers. Headers that define an interface between two
  components, such as the kernel and a domain, are strict C17 and include no
  build configuration headers.
* Keep function declarations outside functions. Headers must include what
  they need so their users do not depend on a particular include order.

### Macros and conditional compilation

* Prefer established library facilities to custom machinery, including
  `queue(3)` macros for linked lists where suitable.
* Parenthesize expression-like macro expansions and their arguments where
  needed for precedence. Avoid evaluating an argument more than once.
* Wrap statement macros in `do { ... } while (0)`, leaving the final
  semicolon to the caller. Align continuation backslashes.
* Use a consistent space or tab after `#define`. A macro replacing a function
  uses the uppercase version of that function's name.
* Add condition comments to `#endif` or `#else` only for long or confusingly
  nested regions. Match the opening condition for `#endif` and the inverse
  condition for `#else`; separate the comment with one space.
* Keep architecture and board conditionals out of portable code: the
  difference lives behind a function in the architecture or platform layer,
  not in an `#ifdef` at each call site.
* Use branch-prediction hints only when measurements show a benefit in hot
  code, and apply them to the complete condition.

### Library calls

* Prefer the BSD memory primitives from `<strings.h>` when they fit. The
  kernel provides its own implementations with the same contracts:

  | Operation | Preferred form |
  | --- | --- |
  | Zero memory | `bzero(buf, n)` |
  | Copy memory | `bcopy(src, dst, n)` |
  | Compare for equality | `bcmp(a, b, n) == 0` |

  Watch `bcopy`'s source-first argument order. Use `memset` for nonzero fills,
  `memcmp` for ordering, and `memcpy` when its call-site types make it clearer.
* Use the project's error interfaces in library code, and `printf(3)`-family
  calls for formatted output. Untrusted text reaches a console, a log or the
  host terminal only as the escaping funnel's output.
* Use checked arithmetic, through the project's wrappers around
  `__builtin_add_overflow` and `__builtin_mul_overflow`, for every size,
  offset and count that comes from outside the component.

### Kernel and other freestanding code

* The kernel and other freestanding components compile with
  `-ffreestanding` and no hosted C library. The kernel also compiles with
  `-mgeneral-regs-only`: it saves and restores the floating-point and SIMD
  state of user-mode threads but never uses it itself.
* Kernel C code recurses only through a tail call marked
  `__attribute__((musttail))`, which the compiler must turn into a jump or
  reject; a tail call the optimizer happens to make does not count. A state
  machine may be written as state functions that tail-call one another this
  way.
* Kernel code uses no variable-length arrays and no `alloca`. Kernel stacks
  are small and fixed: every frame's size is visible at compile time, the
  build proves the kernel's worst-case depth from each entry point,
  and every loop over externally controlled data states its bound.
* Every lock is declared next to a comment naming the data it protects. Lock
  ordering is defined in one place, and code that takes two locks names the
  order it relies on.
* Atomics use `<stdatomic.h>` with an explicit memory order. Every order
  other than `memory_order_relaxed` has a comment naming the operation it
  pairs with.
* Device registers are reached only through accessors generated from their
  CMSIS-SVD files, and system registers only through accessors generated
  from the system-register specification, never through `volatile` pointers
  or hand-packed bit masks. A register whose reads have side effects has no
  read-modify-write accessor.
* Barriers and cache and TLB maintenance live in named helpers whose
  comments state the architectural requirement they satisfy.
* `panic` is for violated kernel invariants only. Nothing a domain does, and
  nothing a device reports, may reach `panic`; malformed requests fail with
  an error or fault the offending domain.

## AArch64 assembly

* Assembly appears only where C cannot express the operation: the boot
  entry before a stack exists, exception vectors, context switch, and
  instruction sequences the architecture prescribes. Assembly calls into C
  as soon as it has a stack.
* Assembly files are preprocessed (`.S`). Each routine is bracketed by the
  project's entry and end macros, which give it a symbol type and size.
* Instructions are lowercase and indented one tab; labels start in column
  one. Use local numeric labels for short branches within a routine.
* Every system-register write, barrier and exception-level change carries a
  comment saying what it establishes and why the order matters.
* Offsets into C structures come from a generated header checked by
  `_Static_assert()`, never from hand-copied constants.

## Erlang

* Follow the layout of the Erlang/OTP sources: four-space indentation, no
  tabs, and lines that aim for 80 columns.
* erXos-owned modules are prefixed `erx_`. Each module has one
  responsibility, stated in its `-moduledoc`.
* Every exported function has a `-spec` and a `-doc`. Code compiles with
  `warnings_as_errors` and is Dialyzer-clean.
* Long-lived processes are OTP behaviours (`gen_server`, `gen_statem`,
  `supervisor`) running under a supervisor. A bare `spawn` is for
  short-lived work whose failure the caller observes.
* Let it crash: do not catch an exception you cannot handle. Use
  `try ... catch Class:Reason:Stacktrace`, never the old `catch Expr`.
* Data from a realm other than the system realm, from a device, or from
  the host link is untrusted. An untrusted term is decoded only by the
  funnel, `erx_term:decode_untrusted/3`, never by `binary_to_term`; the
  funnel bounds size, nesting and decoded heap, and creates no atoms.
  Validate the decoded term's shape at the boundary, before it reaches
  internal state.
* Never turn untrusted text into an atom except with
  `binary_to_existing_atom/2`. Names arrive as binaries, and a node turns
  only the names it needs into atoms of its own; a module loaded under a
  `code` capability becomes an atom only in the node that loads it.
* Message protocols are documented as types next to the code that serves
  them. Requests and replies are tagged tuples; fallible calls return
  `{ok, Value} | {error, Reason}`.
* Keep process state in the behaviour's state, not in the process
  dictionary.
* NIF code is C and follows the C rules above. A NIF never blocks a normal
  scheduler for more than about a millisecond; longer work runs on a dirty
  scheduler or its own thread.
* Unit tests use EUnit; integration tests use Common Test.

## Ruby

* Ruby is host tooling only. It never runs on the target.
* Use two-space indentation, `snake_case` methods and variables,
  `CamelCase` classes and modules, and `# frozen_string_literal: true` at the
  top of every file.
* Use the standard library and its bundled gems. Any other gem is a
  dependency and goes in the dependency table first.
* Start subprocesses with an argument vector (`system(*argv, exception:
  true)`, `Process.spawn(*argv)`, `Open3.capture3(*argv)`), never with a
  shell command string. Close standard input of every child unless the
  child needs it.
* Every external process has a deadline. On expiry, kill its whole process
  group and report which command timed out. `Timeout.timeout` is not a
  deadline for a child process.
* Fail loudly: check every exit status, and exit nonzero on failure.
* Command-line tools parse options with `OptionParser`. Every option has a
  long name. Exit statuses are 0 for success, 1 for failure and 2 for usage
  errors.
* Tests use minitest.

## Applying the guide

Keep changes focused and consistent. Follow these conventions when creating
or editing code; make broad style sweeps deliberate, reviewable work. Compile
with the project's warnings enabled and use its required reviews, tests, and
sanitizers for the behavior affected.

### Readability review

Before submitting code, read the main path as if you had not written it.
Explain its operation in plain language using its function and variable
names. If that requires translating vague names, tracing positional arrays,
or consulting the conversation, revise the code. This is a comprehension
check, not a requirement to add a comment above every step.

The required review must assess structure and explanation, as well as
formatting. Compare the changed code with the qualities listed above. Cite
concrete functions or passages in the review and explain where the flow is
understandable and where the reader must reconstruct missing meaning. Check
whether the reader can follow the algorithm, distinguish the values it
manipulates, and identify state changes, failure handling, and ownership from
the implementation and its local contracts.

Treat difficult-to-follow code as a finding even when it is correct,
formatted, and commented. Fix the cause: unclear responsibility, unsuitable
representation, hidden sequencing, vague naming, or missing reasoning. Adding
whitespace and comments is insufficient when the structure itself needs to
change. Address readability findings before committing; passing tests does
not resolve them.
