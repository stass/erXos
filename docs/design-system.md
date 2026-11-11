# The system domain

Above the kernel, one trusted party runs the machine: the **system
domain**, the kernel's one root task. It is an ERTS domain in user mode
that receives every root capability from the kernel, builds and ends every
other domain, holds every device until it gives the device to a driver's
domain, introduces domains to each other, and runs the system services in
Erlang: domains and principals, facets, resource policy, devices, the
inspector, tracing, the host link and code loading. The mechanism that
creates, inspects and ends domains is the **domain library**, C17 in
`liberx`'s system layer, called through NIFs; the policy that decides who
gets what is Erlang; and what the machine is configured to run is one
file, the **manifest**, which the build checks and packs into the boot
image. This document specifies all three, how the machine boots and ends,
how authority flows from the root task outwards, how devices reach their
drivers, and the resource policy that sets every group's grant. The
architecture is in [design.md](design.md); the kernel in
[design-kernel.md](design-kernel.md); CPU groups in
[design-scheduler.md](design-scheduler.md); runtimes in
[design-runtime.md](design-runtime.md); domains, connections and facets in
[design-domains.md](design-domains.md); the console, inspector and host
connection in [design-live.md](design-live.md).

Decisions every reader of this document needs:

* **The system domain is the root task.** The kernel starts one user-mode
  task, and `liberx`'s root-task entry builds the system domain's memory,
  threads and group from the root capabilities and starts ERTS, which
  boots the system release on the interpreter: no JIT object, no
  writable-then-executable view and no C++ exist in the system domain.
  Policy and mechanism for domains live in one place: Erlang policy over a
  C17 domain library. Nothing in the machine has authority the system
  domain did not pass on.
* **One manifest is the configuration.** Every configured domain, with its
  principal, image, budget, grant, devices, facets and introductions, is a
  record of one file that the build checks and packs into the boot image.
  The check proves properties over it, such as that no domain parsing
  hostile input holds an unconfined device, and fails the build on a
  violation. The root-task entry, the domain service and the device
  service read that one file through readers generated from its layout in
  the ABI source, and nothing else configures the machine.
* **Authority starts at the system domain.** It creates every domain, so
  it alone holds domains' spaces with `CAPS`, and only it installs
  capabilities into a domain's table: a domain's initial capabilities, its
  devices and its connections. Every capability it installs is a copy of
  one of its own. No introduction carries an IPC gate, so no capability
  passes from one domain to another. A domain that the system domain lets
  hold `SPACES` creates sub-spaces of its own, as any L4 task holding a
  factory creates tasks, fills them from what it holds, and ends them with
  itself; a session's programs are such sub-spaces.
* **Lifetime by construction.** Every domain's space is a child of the
  system domain's space, and a space never outlives its parent. So when
  the system domain ends, every domain ends with it, and nothing is left
  to reconcile: a fault in the system domain, a halt of it outside an
  ordered shutdown, or a missed watchdog deadline ends the machine through
  the firmware interface, as `erx.panic` says, with a crash record written
  first. The system domain is restarted the way OTP's `heart` restarts a
  node: by starting the machine again.
* **Every domain's end is seen in one place.** The system domain serves
  the fault gate of every domain's space, so faults, halts, crashes and
  stops arrive there as records, which the domain library classifies and
  the domain service turns into the domain's end. A sub-space's records
  go to the gate its creator named.
* **A domain's end is one destroy.** Each domain has two budgets: its
  own, which pays for what only the domain uses, and its outer budget,
  which pays for what other parties map. Ending a domain is destroying
  its own budget, which deletes every object charged to it at once, as
  destroying an EROS space bank does: every capability to them fails the
  one lookup and every mapping of them faults. Nothing another party
  uses is charged there, so nothing waits before the destroy. Each
  connection's pages sit on a child budget of the outer budget, carved
  for that connection and destroyed once both parties have let go; the
  domain itself is released at its retire, right after its end, and its
  outer budget goes then, or, while a survivor still maps a connection's
  pages, with the last such connection.
* **A domain is built whole or not at all.** The domain library validates
  a creation into a plan before it creates any object, and undoes what it
  applied if a later step fails, by destroying the domain's two budgets.
* **Drivers are Erlang.** A driver is an Erlang process under a
  supervisor, in a domain that holds its device's capabilities; the C
  beneath it is a device shim that parses nothing. Which domain holds
  which device is the manifest's. The console is such a driver, in the
  system domain, so only the system domain and the session connected to
  it read what the operator types.
* **Services do bounded control on their own grant.** No thread ever runs
  on another group's time. A service admits requests per client, in that
  client's facet process, and what it holds for a client is bounded by
  that process and the client's lane.
* **The system domain is trusted, and runs in user mode.** Its authority
  over another domain's processes is what that domain exports to it, as
  any peer's is; its authority over the domain itself, its space, budget,
  group and connections, is its creator's. It decides policy, and loads
  code only from its release and the install facet. A defect in it cannot
  corrupt the
  kernel, but it holds the root authority, so a defect in it is a defect
  of the whole machine, as a kernel defect is; what keeps that risk small
  is the oracle, the sanitizers, and the construction rules that bind its
  C.

## Context

The architecture places mechanism that every domain's isolation depends on
in the kernel and policy in Erlang in the system domain
([design.md](design.md#trust-placement)). The kernel starts exactly one
task, with a fixed set of initial capabilities
([design-kernel.md](design-kernel.md#the-root-task)): the root budget, the
root group and its `system` child, the root resource with the device list,
the boot image with `SYSTEM`, the time page, its own space and thread, the
device-secret page, the kernel's **machine page**, and the previous boot's
crash record where the platform kept one. L4Re puts the
root role in `moe` and `ned`, Zircon in `userboot` and the component
manager, seL4 in its root task; erXos makes the root task the system
domain itself, with its mechanism in one C17 library and everything that
decides in Erlang, and takes a reset when the root task fails, as OTP's
`heart` restarts a node whose runtime has stopped answering.

## Requirements

Functional requirements:

1. **Boot** the system domain from the boot image, start the system
   release, create the domains the manifest lists, and reach the login or
   the system shell on the console's UART.
2. **Build and end domains** on the domain service's decision: budget,
   space, group, connection to the system domain, crash area, runtime image,
   release, first thread; and end each by destroying its own budget.
3. **See every end** of every domain (fault, halt, crash, stop), classify
   it, and turn it into the domain's end: its connections down everywhere,
   `{domain_down, D, Info}` on its domain pid, and its death record.
4. **Introduce domains:** create a connection between two domains when
   policy introduces them, each lane charged to a child budget, carved
   for that connection, of the outer budget of the domain that reads it,
   and take it down when either ends.
5. **Shut down and reset** the machine in order on the system domain's
   decision, and end it with a crash record when the system domain itself
   fails.
6. **Resource policy** in Erlang: the group tree, every group's grant and
   capacity, budgets per principal and domain, and admission at every
   service by client.
7. **System services** in Erlang: domains, principals and sessions,
   facets, devices, the console, inspection, tracing, the host link and
   code.
8. **Devices and drivers:** give each device to exactly one domain, named
   by the manifest; drivers as Erlang processes over the device NIF; the
   PCIe enumerator in Erlang; and no page an unconfined device may still
   address reused while the machine runs.
9. **Sessions and their programs:** give a session `SPACES`, and the
   budget and group its programs spend, so that a session creates its
   programs as sub-spaces and ports of its own
   ([design-programs.md](design-programs.md#a-program-is-a-port)).
10. **Keys:** hold every principal's private keys and secrets outside the
    domains that use them, and sign for them by purpose
    ([The vault](#the-vault)).
11. **Names:** check every system identifier once, when what it names is
    created, and give every domain a node name of its own
    ([Identifiers](#identifiers)).
12. **Configuration:** one manifest, checked when the build packs it, read
    by every party that configures the machine
    ([The manifest](#the-manifest)).

Non-functional requirements:

* **Small.** The domain library is about 2,000 lines of C17 (a budget),
  with its plans and classifications as pure functions tested on the
  host.
* **Bounded.** No call into the domain library waits on a domain, loops or
  allocates without bound; every creation is validated before any effect.
* **Prompt.** A domain's death reaches every linked process within 1 ms of
  the stop (experiment E-D3,
  [design-domains.md](design-domains.md#connections)).

Non-goals: persistence of principals and domains across reboots, which
belongs to the storage design; recovery from a kernel or system-domain
fault, which is a reset.

## Overview

```text
                 +------------------------------------------------------------+
                 |  kernel: objects, capabilities, groups, faults, watchdog   |
                 +------------------------------------------------------------+
  kernel mode         ^ root capabilities, fault records          ^ kernel calls, pets
 ---------------------|--------------------------------------------|-----------------
  user mode           v                                            |
   +----------------------------------------------------------------------------+
   | system domain (ERTS, interpreter), the root task, domain id 4              |
   |  Erlang: domain service, principals, facets, resource policy, device       |
   |          service, console, inspector, tracer, host link, code, watchdog    |
   |  NIFs (C17 in ERTS): erx_domain_lib entries, the fault thread              |
   |  liberx system layer (C17): root-task entry, domain library                |
   +------+------------------+------------------+------------------+------------+
          | connection       | connection       | connection       | connection
   +------+----------+ +-----+-----------+ +----+-------------+ +--+-------------+
   | storage (ERTS)  | | network (ERTS)  | | devices (ERTS)   | | vault (ERTS)   |
   |  block driver   | |  NIC driver     | |  slow drivers    | |  keys, logins, |
   +-----------------+ +-----------------+ |                  | |  sealing       |
                                           +------------------+ +----------------+
   +---------------------+   +----------------------------------+
   | web@erxos (ERTS)    |   | session alice_1@erxos (ERTS)     |
   +---------------------+   |  programs: sub-spaces and ports  |
                             +----------------------------------+
```

Every domain's space hangs below the system domain's. Every domain has a
connection to the system domain, made at its creation, and a connection to
each domain it has been introduced to, made by the system domain at the
introduction ([design-domains.md](design-domains.md#connections)).

**A domain's life, end to end.** A principal's shell calls
`erx_domain:create(Spec)`. The domain service checks the principal's
quotas and that no living domain has the name, computes the domain's
grant and lane sizes, allocates a domain id, and calls the domain library,
which validates the request into a plan, carves the domain's two
budgets, creates the objects, gives the domain its capabilities, makes its
connection to the system domain, and leaves its first thread stopped.
The system domain's connection agent opens its side of that connection,
the domain's domain pid, which the boot information names, exports itself
to the domain, and the domain service starts the first thread. The
runtime, the node `Name@Host` with the domain id as its creation, exports
its init process and its name to the system domain before it reads its
first frame, boots, reports ready to its domain pid, receives its facets
and serves. When the domain ends, the kernel posts a record to the fault
gate; the domain library's fault thread classifies the end, destroys the
domain's own budget, which deletes everything only the domain used at
once, its devices' objects included, and reports to the domain service,
which takes every connection of the domain down, ends the domain pid with
`{domain_down, D, Info}`, records the death, has the library destroy
each connection's child budgets once both parties have let go of it, and
then the domain's outer budget.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **A1.** Only a space's creator installs capabilities into its table: the system domain into domains, a domain into its sub-spaces; and no capability passes between two domains | `erx_cap_pass` installs into a space only with `CAPS` on it, and `CAPS` on a space comes only with its creation: the creating call puts the space's root capability into the creator's table, and a space's capability passes on with `INSPECT` alone, whoever passes it (K17, K24); the system domain creates every domain and passes no capability with `CAPS` on a domain's space to anyone, so `CAPS` on a space never leaves its creator's table, the system domain's for a domain and a domain's for its sub-spaces; a rendezvous needs a gate both parties hold, and no introduction carries a gate, so no domain holds a gate another domain serves ([design-kernel.md](design-kernel.md#invariants), K17, K24) | a space's capability passed with more than `INSPECT`; a capability with `CAPS` on a domain's space passed to anyone; an introduction that makes a gate between two domains | the domain library's grant table checked by a host test (A7); the kernel's test that a space's capability passed on carries `INSPECT` alone; domain tests that a domain's `erx_cap_pass` into another domain's space fails with `ERX_ERIGHTS`, that `erx_space_create` without `SPACES` fails with `ERX_ERIGHTS`, and that no pass moves a sub-space's capability with more than `INSPECT`; a source check that `erx_dom_connect` creates no gate, with a seeded violation |
| **A2.** The system domain sees every domain's end | a space's fault gate is an argument of `erx_space_create` and never changes (K28); the kernel posts an exit record for every stop, and for a space whose last thread ends, however it ends, once no thread of it can return to user mode (K18), and a fault record for every fault; the domain library names its one fault gate for every domain it creates | a call that changes a fault gate; an exit record posted while a thread can still run; a space left with no thread and no record; a plan that names another gate | the call table has no such call; a host test that every plan names the library's fault gate; a test that a domain faulting in its first instruction is reported; a test that a domain's threads on every CPU, and threads it creates while stopping, are stopped before its exit record arrives; a native domain whose threads all exit |
| **A3.** The domain library never waits on a domain | every entry does bounded work under the library's one lock and makes no kernel call that waits; the fault thread, an ERTS thread that the NIF module `erx_domain_lib` starts at load, waits only in its open wait on the fault gate, with a timeout from which it also checks the ending record's deadline; a domain's end is one destroy of its own budget, which waits on no party; a connection's child budgets are destroyed only when the domain service asks, once each party has unmapped the connection's objects or ended, never on a timer while a party lives, and the outer budget only once none of its children remains, so no entry waits for an answer: a survivor that never answers `connection_down` keeps that one connection's child budget, and with it the dead domain's outer budget, and the connection counts against its own `connections` quota until it unmaps or ends | an entry that calls a gate a domain serves; a creation step that waits for a runtime; a destroy that waits for a holder to let go; a connection deleted on a timer while a party still maps it | hostile-domain tests: a domain that never reads its lane from the system domain, never answers `connection_down`, or floods it; a runtime that stops reading its lanes; every library entry timed with the manifest's `max_domains` domains alive |
| **A4.** A domain is built whole or not at all | a creation is validated into a plan by a pure function before any effect; step 1 carves the domain's two budgets, each a wall, and every later object of the domain is charged to one of them, so the undo of a failure is destroying both; a domain whose runtime does not report ready is stopped and ended by the domain service, so `erx_domain:create/1` returns an error only once the domain has ended and been retired, when nothing of it is charged but the remains a survivor still maps, which belong to the principal and the survivor, not to the domain; a retire the library refuses, which only a bug of the service or the library causes, is logged and leaves the record charged | an effect before validation; an object of the domain charged to a budget other than its two | an exhaustive host test that injects a failure at every step of a creation and checks that every object is destroyed when the undo returns, and that the principal's budget is back at its baseline once the destroyed records' grace period has passed and the reaper has run, which the test drives, since a destroyed record's cache page stays charged until the reaper frees it ([design-kernel.md](design-kernel.md#budgets)); a QEMU test that injects one at each step through a test-build hook; a domain whose init process never reports ready, after which nothing of it is charged |
| **A5.** Ending a domain deletes everything only it used at once, and nothing another party still uses goes with it | every domain has an own budget and an outer budget, carved side by side from its principal's; the domain library charges to the own budget only what the domain alone maps or uses, and to the outer budget everything another party maps or reads after the domain is gone: on a child budget of it carved for each connection, the side of that connection the domain reads and the bell it waits on, or for its connection to the system domain both sides and both bells; and on the outer budget directly, its crash area, which no other party maps; the library has no entry that maps one domain's memory into another but `erx_dom_connect`, so an outer budget holds exactly its connections' child budgets and its crash area; only the system domain creates a mapping that crosses domains, and every one is a connection's, charged to the child budget of an outer budget for that connection, so the rule holds by construction; destroying a budget deletes every object charged to it and to the budgets carved from it ([design-kernel.md](design-kernel.md#budgets), K25, K26); the fault thread destroys the own budget at the exit record, through `erx_dom_destroy`; the system domain destroys a connection's child budgets through `erx_dom_disconnect` once each party has let go, and the outer budget through `erx_dom_retire` once the crash area is read when no connection names the domain, or else, as its remains, through the `erx_dom_disconnect` of the last connection that does; the domain holds no capability to its outer budget or to any child of it; the system domain charges nothing of a domain's to its own budget, and maps nothing charged to a domain's own budget | a cross-domain mapping, or memory a device may address, charged to a domain's own budget; a library entry other than `erx_dom_connect` that maps one domain's memory into another; a domain holding its outer budget or a child of it; a second path that destroys a domain's budgets | a source check that the domain library destroys a budget only in `erx_dom_destroy`, `erx_dom_disconnect` and `erx_dom_retire`, and that `erx_dom_connect` is the one entry that creates an object another domain maps, and creates it from a child budget of an outer budget, each with a seeded violation; a host test that drives the library over the hosted kernel interface through random creations, introductions, device gives and ends, and checks after each destroy that no object a living party maps was deleted, and after each retire and disconnect that the principal's budget is back at its baseline less the remains a connection still names, once the reaper has run, less any page a failed IOMMU pinned, which the test never provokes; a test that ends a domain while its peer still writes the side the dead domain read and reads the side it wrote, and finds the peer running until it answers `connection_down`; a test whose peer never answers, after which only that connection's child budget stays, with the dead domain's outer budget it is carved from as the remains, every other child of that outer budget is gone, the connection counts against the peer's `connections`, a configured domain restarts at once, and the principal's budget is back at its baseline once the peer unmaps; a test that creates and ends domains under load, some with sub-spaces nested three deep, and checks that the principal's budget returns to its baseline once the reaper has run |
| **A6.** No domain outlives the system domain, and a system domain that cannot serve ends the machine | every domain's space is a child of the system domain's space, which the plan names as every domain's parent (K27); the first space has no fault gate, so a fault in it, a stop of it outside an ordered end, or a watchdog deadline missed goes to the kernel's end path, which writes the crash record and ends the machine by `erx.panic`; the watchdog process pets only after every service it lists has answered a liveness call within the period, so a system domain whose runtime runs but whose device service stops answering, even after its supervisor restarted it, misses the deadline too; the domain service is the system release's significant child, so its end, the watchdog's kill of it included, ends the system domain outside an ordered end; no party outside the kernel and the system domain keeps a record of any domain, so there is nothing to reconcile and no protocol that could be wrong | a domain created under another parent; a system-domain fault handled by anything but the kernel's end path; a watchdog pet from anything but the system domain's runtime; a pet that does not wait for the listed services' answers | a host test that every plan names the system domain's space as parent; a QEMU test that kills the system domain under load and finds the machine ended with the crash record on the console and no domain running; a test that stops the pet and sees the machine end at the deadline; a test that deadlocks the device service and sees it killed and restarted with the pets going on, and one that keeps it from answering after each restart and sees the machine end at the deadline; a test that deadlocks the domain service and sees the machine end at its kill; a test that a domain's `erx_watchdog_pet` fails with `ERX_ERIGHTS` |
| **A7.** The system domain installs only what its grant table allows | every `erx_cap_pass` the domain library makes goes through one function, `erx_dom_install`, which takes a row of `erx_dom_grants`, the constant table of installs that [Authority](#authority) describes, and the recipient the validated plan names for the row's role; each install copies one of the library's own capabilities from the system domain's table, never from another domain's, and each mask lies within its recipient's row in the authority table | a pass outside `erx_dom_install`; a pass from another domain's table; a row that grants more than its recipient's row in [Authority](#authority); a recipient the plan did not check | a source check that `erx_cap_pass` is referenced only from `erx_dom_install`, and that its source table is always the system domain's own, with a seeded violation of each; host tests that every row of `erx_dom_grants` lies within the rights the authority table lists for its recipient, transcribed into the test; domain tests that a device's objects reach their domain without `GIVE`, and that a side of a connection reaches its reader with `READ` and `MAP` alone |
| **A8.** A space never outlives its parent: no domain outlives the system domain, no sub-space its creator, and no program its session | every space has a parent, fixed when it is created, and stops when its parent stops ([design-kernel.md](design-kernel.md#creating-spaces)); the domain library names its own space as every domain's parent; a sub-space's parent is its creator's space or one of that space's sub-spaces, and a session's programs are its sub-spaces ([design-programs.md](design-programs.md#a-program-is-a-port)); a stopped space takes no children, and `erx_thread_start` refuses a stopped space; a parent exists before its child, so the relation is a tree, and the kernel stops it from its root down without anyone keeping a list | a space created anywhere but under its creator's own space or one below it; a creation under a stopped parent; a thread started in a stopped space | the host test of A6; the kernel's host test of stopping over random trees, with creations racing each stop; a domain test that ends a session holding programs three generations deep, each with a sub-space, and sees every one's exit record before the session's |
| **A9.** A device is held by one domain at a time, and a device never reaches memory its holder did not give it, nor a page anyone else may later use | the domain library gives a device only, in its creation, to the configured domain the manifest names for it, and refuses a second living holder with `ERX_EBUSY`; the kernel refuses a second IRQ object for a line, a second MMIO object for a page and a second DMA window for a stream; a device's register windows, IRQ objects and DMA window are charged to its holder's own budget, which the fault thread destroys at the holder's exit record, and deleting a confined device's window aborts its stream before any page is freed; an unconfined device's memory is the device's for the boot, charged to the system domain and given to each of its holders in turn, so no page it may still address is ever given to anyone else; the device NIF builds every address it gives a device from a memory object the domain holds, an offset and a length it checks, through `erx_dma_map` or `erx_mem_dma_addr`, alone writes a device-address field or an addressing flag, in a register or a descriptor, posts nothing to a device until its driver has reset it, and leaves an address a device may still hold unused until the device's completion protocol has retired it or the device has been reset; pools and queues are state of the device's record in the NIF, never of a process, so a driver's crash frees nothing a device may still reach; the NIF parses nothing a device wrote | a device given twice; an unconfined device's memory freed or charged to its holder; a NIF that takes a raw address or posts before a reset; an address field or an addressing flag written from Erlang; a pool or queue freed with the process that made it; a descriptor or a device's record parsed in C | domain tests that ask for a device another living domain holds, refused with `ERX_EBUSY`; a test that ends an unconfined device's domain and finds its restarted holder given the same memory, and that memory never charged to or mapped by any other domain; the NIF's host tests over addresses outside the pool's objects, each refused, over a post before `negotiate/2`, refused, and over a seeded write of an address register from Erlang and a seeded pool owned by a process, each failing ([design-runtime.md](design-runtime.md#invariants), R8); a chokepoint check that only the device NIF's address builder references `erx_dma_map` and `erx_mem_dma_addr` in a runtime, with a seeded violation; a hostile virtio device model under QEMU that writes malformed descriptors, which crashes the driver process and nothing else |
| **A10.** The machine runs only a configuration whose properties the build proved | the manifest is the one source of configuration: the root-task entry, the domain service, the device service, the policy and the principal service read it through the readers generated from its layout in the ABI source, and no boot argument, release term or run-time call configures a domain, a device's holder, a facet of the manifest or a budget the manifest sets; the packer's only way to produce the manifest's bytes is the check, which returns the packed form only when every property of [The manifest](#the-manifest) holds; the manifest is a file of the system release, so only the system domain slices it | a second source, such as a boot argument or a term in a release; a service that reads configuration from elsewhere; a packing path that skips the check | a test for each property that seeds one violation into a manifest and expects the build to fail; a source check that the manifest file is opened only by the generated readers, with a seeded violation; a check over the system release's BEAM files that no module but `erx_manifest` reads the file; a QEMU test that boots each shipped manifest and finds every configured domain and device placed as it says |
| **A11.** The system domain makes no machine code | the root task's image is the interpreter's, which carries no `ERX_IMAGE_JIT`, so the kernel creates the first space without JIT objects ([design-kernel.md](design-kernel.md#image-manifests), K8), and no JIT object, writable-then-executable view or C++ exists in the system domain; the manifest check proves that the boot image's root entry carries no `ERX_IMAGE_JIT` | a root image built with BeamAsm; a manifest that names a JIT image for the system domain | the manifest check's property, with a seeded root image that carries the flag; a boot test that a JIT object's creation in the system domain fails |

## Data model

### The manifest

The **manifest** is the machine's configuration, and its only one. It is
one file, which the build packs into the boot image among the files of
the system release, so only the system domain can slice it
([design-kernel.md](design-kernel.md#the-boot-image)). Its source is a
checked-in text file per configuration, `config/<name>.txt`, one for each
platform and build kind; the packer, `tools/erx pack`, parses it, runs the
check below over it, and packs the result. The manifest holds:

* **The machine:** its host name, an identifier that is the host part of
  every domain's node name ([Identifiers](#identifiers)); `root_memory`,
  the size of root budget the configuration assumes; the shares of the
  `system` and `users` groups; the
  system domain's own limits,
  `max_domains`, `max_connections`, `system_lane`, `system_queue`,
  `peer_held` and `system_reserve`, the part of `system` the service
  grants inside it leave to the system domain's own threads; the lane
  size per class of domain; the
  vault's sealing backend; the services the watchdog process asks for
  liveness; the **system-shell principals**, whose login at a secure line
  opens the system shell (`root` in a development build, and by default
  none in a release build); the console, `console`, by the device-tree
  path of its UART; and the host-link port, `hostlink`, by the
  device-tree path of its UART, where the machine has one; and the
  `secure` attribute of each of the two console lines, the UART and the
  host link, which marks a line at which a system-shell principal's login
  opens the system shell, as UNIX's `/etc/ttys` marks the terminals where
  root may log in ([design-live.md](design-live.md#the-console)). The
  console has no other line. The manifest grants
  the system-shell facet to no domain: the console grants it to a login,
  holds it for that login and ends it with the login.
* **Each principal:** its name, budget, share of `users`, quota of
  domains, and quota of names it may bind.
* **Each configured domain:** its name; its principal; its kind (`service`
  or `secret`); its runtime image and release, as boot-image entries; its
  own and outer budgets, grant, lane size, `connections` quota and crash
  area; whether it holds `SPACES`, and its sub-space group's grant; its
  restart intensity, whether it is `required`, and whether the rescue
  configuration starts it; its arguments and environment; its **devices**,
  given by unit ([Devices](#devices)), each by device-tree path or, for a
  PCIe function, by its place on a bus, with its compatible string, its
  mark as confined or unconfined if it masters DMA, the size of its memory
  if it is unconfined, and its `hostile` mark, which the platform's
  placement table sets
  ([design-platforms.md](design-platforms.md#what-the-manifest-says)); its
  partition windows, by role in the medium layout; its **facets**, each
  naming a service that the system release or another configured domain
  serves, with the grant's limits; and its **introductions**, each naming
  another configured domain.
* **Each read-only image** a configured domain boots from: its extents,
  root hash, salt and tree layout, which the packer computes as it builds
  the image ([design-storage.md](design-storage.md#data-model)).
* **The boot order**, the configured domains in an order in which every
  domain follows every configured domain whose service its facets name,
  which the check computes, breaking ties by stable name order.
* **In a development build only**, the native programs of a partial boot
  ([Boot](#boot)).

The packer generates the configured-domain, device, facet, boot-order
and watchdog-liveness descriptor arrays in this packed manifest. The
boot and service code reads those arrays through the generated readers;
no separate compiled configuration table repeats them. A generated host
report describes the checked configuration and cannot configure a boot.
Dynamic creation still goes through the domain library's whole-plan
validation and Erlang policy
([design-generation.md](design-generation.md#configuration-and-command-catalogs)).

**The packed form** is a layout of the ABI source, `erx_manifest_t`, read
through readers generated from it: a C reader in `liberx`, which the
root-task entry uses before ERTS starts, and an Erlang module,
`erx_manifest`, which the system services use. The complete
[binary representation](design-abi.md#system-manifest-representation)
defines the fixed header, every record table, their canonical order and
their bounds. The header is followed by fixed-record arrays and a string
table. A record reference is a checked index; a span names complete
records within its table by a file offset and count; a string uses an
offset within the string table and a byte length. No reader follows a
native pointer from the file.

The records cover principals, configured domains, named domain and
runtime limits, lane classes, units and devices, role-based partition
windows, services, facets with typed bounded scope parameters,
introductions, read-only image extents and hash-tree metadata, boot order,
liveness, system-shell principals, the console lines' `secure`
attributes and partial-boot programs. A unit owns its devices' one
holder field. Domain records refer to complete named
limit records, so neither a runtime default nor a second compiled table
can supply missing configuration. `erx_share_t` is the 48-byte wire
representation of the scheduler's existing `erx_grant_t`: exact quota,
period, CPU set, hints and urgency bounds, not another kind of share.

A reader that finds an offset, count or index out of range, a version
other than its own, or a string that is not what its field requires,
refuses the whole file; the root-task entry then ends the machine with a
crash record that names the field, as for any failed boot. The packer
writes only what the check accepted, but the boot image is untrusted
until the boot validator has checked it, and the readers parse its
content, so both readers have a fuzz target
([Verification and testing](#verification-and-testing)).

| Reader | What it takes from the manifest |
| --- | --- |
| the root-task entry, in C | `root_memory`, which it compares with the root budget before anything else; the shares of `system` and `users`; the system principal's budget; the sizes of the domain library's tables; a development build's partial boot |
| the domain service | the configured domains in the boot order, their restart intensities, `required` and rescue marks, facets and introductions; `system_lane`, `system_queue`, `peer_held` and `system_reserve`; the host name; the vault's sealing backend, which it passes to the vault at its creation |
| the device service | each device's holder, unit and confinement mark, each domain's windows by role, the image records, an unconfined device's memory size, and the console's and the host link's paths |
| the resource policy | the principals' budgets, shares and quotas; the lane size per class; `system_reserve`, which bounds the service grants it sets |
| the principal service | the principals, and which of them are system-shell principals, which it tells the console with each login it confirms |
| the console service | the `secure` attribute of the UART and the host link, its only lines; the console grants the system-shell facet only at a secure line |
| the watchdog process | the services it asks for liveness |

**The check.** The packer proves these properties over the manifest
alone. It reasons from the devices' marks and keeps no list of device
classes: whether a DMA device is confined is the manifest's mark, which
the device service holds the machine to at boot ([Devices](#devices)), and
whether a device is `hostile` is the mark the platform's placement table
sets on each device whose driver parses what arrives from outside the
machine or from a pluggable device, such as a block device, a network
device or a USB host controller
([design-platforms.md](design-platforms.md#what-the-manifest-says)). A
violation fails the build with the property, the record and the field:

1. **Every device the manifest names has exactly one holder,** and every
   unit is given whole to one domain. A device the manifest does not name,
   a PCIe function found at run time among them, goes to no domain, and a
   function's bus mastering stays off.
2. **Every facet names a server the manifest contains,** a service of the
   system release or of a configured domain, and a grantee, the system
   domain or a configured domain, never the service's own server; a
   grantee takes at most one facet of a service name, since its registry
   holds each under that name; and every introduction names configured
   domains.
3. **Exactly one domain holds PCIe configuration space, and that domain
   holds nothing else,** on every platform where erXos drives a PCIe
   bridge in a full boot: the PCIe domain, `pcie`, which runs the PCIe enumerator and
   nothing beside it. On a platform that drives no bridge, as the
   Raspberry Pi 4, no domain holds configuration space and there is no
   PCIe domain.
4. **Budgets and grants sum within the root's.** The principals' budgets,
   the system domain's baseline and its reservation for `max_domains`
   admitted domains ([Resource policy](#resource-policy)), the unconfined
   devices' memory and the domain library's tables fit within
   `root_memory`; each configured domain's two budgets fit within its
   principal's; the shares of `system` and `users` sum within the root
   group, the configured domains' grants within `system`, the principals'
   shares within `users`, and each sub-space grant within its domain's;
   and the principals' quotas of domains sum within `max_domains`, every
   living domain, configured or requested, being one of its principal's.
5. **Every name is a system identifier,** the host name included, and so
   is every pooled name a principal's `names` quota allows
   ([Identifiers](#identifiers)); no two configured domains or principals
   share a name, and no configured domain's name has a pooled name's
   form.
6. **The root task makes no machine code:** the boot image's root entry
   carries no `ERX_IMAGE_JIT` (A11). A full boot uses the interpreter
   image; a native partial boot may use the C17 root-entry image without
   ERTS, identified by its checked build provenance.
7. **The sealing secret goes to the vault alone:** in a full boot exactly one configured
   domain boots the release whose files carry `ERX_ENTRY_SEAL`, it is the
   one `secret` domain and has no crash area, and only it holds a TPM.
   A partial boot creates no vault and grants no sealing secret or TPM
   to its native children.
8. **Partitions, devices and the console reach only their holders:** only
   the slot writer holds the windows on the slots, the boot-selection
   record and the reset count; only storage domains hold windows on data,
   FAT and vault's partitions; the units of the UARTs that `console` and
   `hostlink` name are the system domain's, and the two paths differ; only
   the storage domain that serves the vault holds the vault's partition,
   and only the vault holds a facet of that domain's tree; only the
   network domain holds a network device.
9. **A release build's manifest confines what it can:** each unconfined
   device's holder holds that device's unit and nothing else, so the file
   system or network stack that parses what an unconfined `hostile` device
   carries runs in another domain, and no domain holds an unconfined
   device together with a window on a partition that no hash tree checks
   (a data, FAT or vault's partition) or a `hostile` device of another
   unit; the diagnostic names that hostile input when the violating holder
   has one. The web domain, the configured domain that holds the
   `erx_web_login` facet and parses browsers' bytes, holds no unconfined
   device, its network listener is TLS, and the host link's facets do not
   list `web`, so the web's development paths stay out of a release
   ([design-web.md](design-web.md)). A display domain, a configured
   domain holding a display device and its input devices, whose release
   serves that display's windows
   ([design-display.md](design-display.md#overview)), holds no
   unconfined DMA device, a virtio-mmio one among them, since it parses
   what its clients and its input devices send; a violation names the
   device and this property, and a development manifest that gives it one
   passes, with the display domain reported in the trusted base. The
   manifest has no
   partial boot.
   The packer sets the boot image's `ERX_PACK_UNCONFINED_DMA` exactly
   when the manifest gives an unconfined device.
10. **The domains have a boot order:** no configured domain's facets lead
    back to it, so the check can order every server before its clients,
    and it writes that order.
11. **The rescue configuration stands alone:** every facet of a domain
    the rescue configuration starts names the system release or another
    domain it starts, and it starts no domain that holds a network device.
12. **Every child domain can be built:** the check runs the host build of
    `erx_dom_plan_configured` over the configured domains in the boot
    order, or `erx_dom_plan_partial` over a partial boot's children, and
    `erx_dom_plan_connect` over the introductions, starting from the view
    of a machine just booted with `root_memory` and recording each plan in
    the view as the boot does (`erx_dom_plan_record`,
    `erx_dom_link_record`), so a domain or introduction the library would
    refuse fails the build, not the boot, and properties 4 and 13 over
    the configured domains are the planner's own judgment, in its own
    arithmetic. The view has one builder, `erx_dom_boot_view`, which the
    root and the host planner both run on the packed manifest's bytes,
    with each archive entry judged from the bytes it starts with; so
    every principal passes `erx_dom_principal_check` at build time, and
    the boot plans against exactly the view the check proved. The view
    also holds the device catalogue and its placement
    ([Devices](#devices), Units), and admits a configured row only when
    its arguments and environment leave room in its boot page's strings
    for what the library adds there
    ([Boot information](design-stopgap.md#boot-information)), so a
    placement or a row the boot would refuse fails the build. The
    production build always runs the planner; a check without one plans
    nothing for an empty set of children, and fails closed for a
    nonempty set.
13. **The system configuration leaves headroom in `system`:** with each grant
    taken as a rate, its quota over its period (an uncapped grant's rate
    being the size of its cpuset), the configured service domains' grants
    inside `system` sum to at most `system`'s rate less `system_reserve`
    of it. Since each grant fits `system`, and `system`'s rate is at most
    the number of its CPUs, the same headroom holds on those CPUs. This is a
    normalized configuration check, not a lower bound on CPU supplied
    within a period or deadline. The system runtime's threads belong
    directly to `system` and have no separate quota that could expire
    before residual parent quota becomes available. Quota phases,
    bursts, urgency and CPU placement still affect when they run
    ([Resource policy](#resource-policy)).
14. **A session template is not a domain, and the boot never creates
    one:** a record of the manifest's own session table, keyed by its
    principal, names the release, runtime, limits, arguments and
    environment from which the domain service makes each session domain
    of that principal on request
    ([design-domains.md](design-domains.md#principals-sessions-and-quotas)).
    The key gives a principal at most one; the template names a principal
    that exists, and its limits enable `SPACES`, since a session's programs
    are its sub-spaces. It has no restart intensity, boot flag or place:
    the boot order, the plans of property 12 and every unit, window,
    service, facet and introduction resolve through the domain table, which
    holds no template, so none of them reaches one. Its limits are judged
    against its principal's ceilings, budget and quota when a session is
    made from it, by the request path every principal's domain takes.

Each property has a test that seeds one violation into a manifest and
expects the build to fail with that property's diagnostic.

The manifest check has one normalized input from the Ruby reader and the
platform placement records. The relational-rule evaluation described in
[Protocol verification](design-verification.md#focused-tool-evaluations)
compares awklog with the Ruby implementation without changing these
properties or the manifest format. Checked exact budget and grant
arithmetic stays in Ruby. Facet edges grant particular operations, not
universal transitive authority; runtime admission and capability checks
continue to enforce every dynamic use. The roadmap owns tool adoption.

### The domain service's record

The domain service keeps one record per domain, in Erlang, holding what
Erlang decides with, in its own state; every capability lives in the
domain library's records, keyed by the same id:

```erlang
-record(domain, {
	id         :: erx_domain:id(),       % from a counter; never reused within a boot
	name       :: erx_ident:t(),
	principal  :: erx_principal:number(),
	pid        :: pid(),                 % the domain pid; exits with {domain_down, Id, Info}
	state      :: built | running | ended,
	kind       :: ordinary | session | service | secret,
	spec       :: erx_domain:spec(),     % release, runtime image, memory, grant, lanes,
	                                     % crash area, facets, env, as create/1 received it
	peers      :: #{erx_connection:number() => erx_domain:id()}, % its connections
	slots      :: #{erx_connection:number() => non_neg_integer()}, % each one's control
	                                     % slot, held until the domain has answered
	                                     % every record written into it
	devices    :: [erx_device:index()],  % devices its creation gave it
	ended      :: undefined | {erx_domain:end_(), integer()}  % the end and when
}).
```

A `session` domain holds `SPACES` and creates its programs as sub-spaces,
and is made from its principal's session template of the manifest, which
the boot never creates (property 14); a
`service` domain is one the manifest lists, which the domain service
restarts when it ends; a `secret` domain is the vault's, which has no
crash area and alone receives the sealing page.

### The domain library's records

The library keeps four tables, allocated at boot from the root budget:
the manifest's `max_domains` domain records (1,024 in the default
manifests), its `max_connections` connection rows (4,096), twice
`max_connections` remains rows, and one device record per entry of the
device catalogue. One lock guards the four; every entry holds
it for bounded work, and the fault thread's open wait is outside it.

A domain record lives from the plan's apply to the domain's retire,
which follows its end without waiting for any peer. A **remains** row is
what outlives a retired domain whose connection a survivor still holds:
the outer budget those connections' child budgets are carved from, with
the id the connection rows name and the principal whose memory the outer
budget stays carved from. It is no domain record: it takes no record, no
place in its principal's `domains` and none of its own budget's bytes,
so a new domain, the same configured row's restart among them, never
waits for it for a record or a place in `domains`. The remains do keep
the whole outer budget's size carved from the principal's memory, so a
principal whose memory cannot hold them beside the new domain's two
budgets is refused the new domain until the survivor lets go. A retire makes a remains row only for an id a connection
row names, and the disconnect of the last row naming the id destroys it
with that row, so every remains row is named by a connection row, and
the rows, which each name two ids, bound the remains at twice
`max_connections`: a retire always finds a free one.

```c
typedef struct erx_dom_origin {
	uint32_t	kind;		/* ERX_DOM_REQUEST, ERX_DOM_CONFIGURED,
					 * ERX_DOM_PARTIAL_BOOT or ERX_DOM_SESSION */
	uint32_t	record;		/* REQUEST: ERX_MF_NONE; otherwise the
					 * index in the origin's manifest table */
} erx_dom_origin_t;

typedef enum erx_dom_state {
	ERX_DOM_BUILDING,	/* plan being applied */
	ERX_DOM_BUILT,		/* built; first thread waiting for erx_dom_start */
	ERX_DOM_RUNNING,
	ERX_DOM_ENDED		/* stopped; own budget destroyed; reported;
				 * outer budget and crash area kept until
				 * the retire, which frees the record */
} erx_dom_state_t;

typedef struct erx_dom {
	uint32_t	id;		/* the domain id; 0 for a free record */
	uint32_t	principal;
	erx_dom_origin_t origin;	/* immutable creation source and manifest row */
	erx_dom_state_t	state;
	uint32_t	flags;		/* ERX_DOM_SECRET, ERX_DOM_SPACES */
	erx_cap_t	budget;		/* its own budget, carved from its
					 * principal's: what only it uses */
	erx_cap_t	outer;		/* its outer budget, carved beside it: the
					 * parent of its connections' child
					 * budgets, and its crash area; neither
					 * it nor a child given to the domain */
	erx_cap_t	space, group;
	erx_cap_t	spaces_group;	/* ERX_DOM_SPACES: its sub-space group; else ERX_CAP_NULL */
	erx_cap_t	crash;		/* its crash area, charged to its outer
					 * budget; ERX_CAP_NULL for a secret domain */
	erx_cap_t	bootinfo;	/* its boot information page */
	erx_cap_t	sealing;	/* its mapping of the sealing page; ERX_CAP_NULL
					 * unless its release is the one marked
					 * ERX_ENTRY_SEAL */
	erx_cap_t	first_thread;
	uint32_t	system_connection;	/* the number of its connection to the system domain */
	erx_grant_t	grant;		/* its group's grant: a living configured
					 * domain's is one of the admitted service
					 * grants */
	erx_dom_end_t	stop;		/* the stop the library made: FAULT with the
					 * kind, or STOPPED; NONE until it stops
					 * the space */
	erx_dom_end_t	end;		/* classified end, once ERX_DOM_ENDED */
	erx_fault_t	record;		/* the record that ended it */
} erx_dom_t;

typedef struct erx_dom_remains {
	uint32_t	id;		/* the retired domain's id, which a
					 * connection row names; 0 for a free row */
	uint32_t	principal;	/* whose memory the outer budget stays
					 * carved from */
	erx_cap_t	outer;		/* the retired domain's outer budget: the
					 * parent of the child budgets of the
					 * connections that name id, and of
					 * nothing else */
	uint64_t	bytes;		/* its size, which its destroy gives back
					 * to the principal */
} erx_dom_remains_t;

typedef struct erx_dom_connection {
	uint32_t	number;		/* 0 for a free row */
	uint32_t	a, b;		/* domain ids; a is 4 for a connection to the system domain */
	erx_cap_t	budget_a;	/* a's child budget for this connection,
					 * carved from a's outer budget: the side
					 * a reads and a's bell; ERX_CAP_NULL
					 * when a is 4 */
	erx_cap_t	budget_b;	/* b's, likewise; when a is 4 it holds
					 * both sides and both bells */
	erx_cap_t	side_a;		/* a's side: one memory object a writes and b
					 * maps read-only (the ring header and data
					 * area of a -> b, the reader page of b -> a);
					 * sized by b's lane and charged to
					 * budget_b */
	erx_cap_t	side_b;		/* b's side, likewise; charged to budget_a,
					 * or to budget_b when a is 4 */
	erx_cap_t	bell_a;		/* ERX_IRQ_SOFT bound to a's group; b holds
					 * TRIGGER alone; charged to budget_a, or
					 * to budget_b when a is 4 */
	erx_cap_t	bell_b;		/* bound to b's group; charged to budget_b */
	bool		closing;	/* connection_down told; the child budgets
					 * are destroyed once each party has
					 * unmapped the objects or ended, never
					 * on a timer */
} erx_dom_connection_t;

typedef struct erx_dom_device {
	uint32_t	index;		/* its catalogue entry's: the manifest's
					 * device row */
	uint32_t	holder;		/* the living domain it is given to; 0 for none */
	erx_cap_t	resource;	/* the carved resource; charged to the holder's own budget */
	erx_cap_t	windows[ERX_DEVICE_RANGES_MAX];	/* its register windows; likewise */
	erx_cap_t	irqs[ERX_DEVICE_IRQS_MAX];	/* its lines' or MSIs' IRQ objects; likewise */
	erx_cap_t	dma;		/* confined: its DMA window, likewise; else ERX_CAP_NULL */
	erx_cap_t	memory;		/* unconfined: its contiguous memory, made at
					 * its first give, charged to the system
					 * domain and kept for the boot; else
					 * ERX_CAP_NULL */
} erx_dom_device_t;
```

The label of a domain's space, on each of its records, is the domain's id,
so the fault thread finds the record from the label alone. A sub-space has
no record here: it belongs to the domain that created it
([Sub-spaces](#sub-spaces)).

**A classified end** is one of four, computed by a pure function from the
records alone: an exit record names the thread that stopped the space
and that thread's space, and only the library, in the system domain's
space, holds a capability that stops a domain's space, so a stop the
library made tells itself from one the domain made by the stopper's space,
whichever came first. A record's noted stop is `NONE` until the library
stops its space, so a zeroed record notes none:

```c
typedef enum erx_dom_end_kind {
	ERX_DOM_END_NONE,	/* no end yet: a record's stop until the library
				 * stops its space */
	ERX_DOM_END_HALT,	/* the space stopped itself with a halt status */
	ERX_DOM_END_CRASH,	/* the space stopped itself with ERX_EXIT_CRASH */
	ERX_DOM_END_FAULT,	/* a thread faulted; the library stopped the space */
	ERX_DOM_END_STOPPED	/* the library stopped it on request */
} erx_dom_end_kind_t;

typedef struct erx_dom_end {
	erx_dom_end_kind_t	kind;
	int64_t			status;	/* HALT: the status; FAULT: the fault kind */
} erx_dom_end_t;
```

The domain service turns it into the `Info` of `{domain_down, D, Info}`:
`{halt, Status}`, `crash`, `{fault, Kind}` or `stopped`
([design-domains.md](design-domains.md#links-monitors-and-exits)).

### The crash record

When the system domain ends outside an ordered shutdown, the kernel writes
one **crash record** before it ends the machine: a fixed layout of the ABI
file, `erx_crash_record_t`, whose `form` says which of two forms it is
([design-kernel.md](design-kernel.md#the-root-task)):

* the **brief** form, a release build's: the cause (`fault`, `halt` or
  `watchdog`), the program counter and the fault address, the build
  identifier, the boot value and its slot, the machine's uptime and the
  time since the last pet, and
  no other register, no stack and no dump, so nothing the system domain
  held, a passphrase it was checking included, survives the reset in it;
* the **full** form, a development build's: the brief form's fields, the
  faulting thread's registers, the backtrace and the kernel log's tail,
  among it the slogan and the start of the dump that the system domain's
  runtime writes to the kernel log through its sink before it stops its
  space, so a crash of ERTS in the system domain is read as a crash of the
  kernel is. A release build's runtime writes no slogan and no dump there.

Where the platform has a region that survives a warm reset, the kernel
writes the record there, and the next boot validates it by its magic,
form, boot value and checksum and gives the root task a read-only page holding it;
elsewhere the record goes to the console and the kernel log alone
([design-platforms.md](design-platforms.md#the-crash-record)). The
inspector shows the previous boot's record at `[kernel, crash]` only to
the system shell, and no console line shows anything of it before a
login ([design-live.md](design-live.md#paths)).

## Algorithms and behavior

### The root task

The kernel builds the first space, which has no parent and no fault gate,
maps the runtime image into it from the boot image with `erx_image_map`,
gives it the initial capabilities at the ABI file's well-known slots,
writes it a boot information page flagged `ERX_BOOT_ROOT`, creates its
first thread, a worker in `system`, and starts it at the image's
entry with that page's address as its argument
([design-kernel.md](design-kernel.md#the-root-task)). The runtime image
is the interpreter's for a full boot or the C17 root entry's for a native
partial boot. Neither carries `ERX_IMAGE_JIT`, so the first space
allows no JIT objects (A11); its budget, the root budget, carries `CODE`,
and so does every capability the system domain holds to a budget carved
through it, while the capability a domain receives to its own budget
never does. The domain library uses `CODE` only to make sessions' code
objects and the `ERX_SPACE_JIT` spaces of domains whose runtime image
carries `ERX_IMAGE_JIT`, each charged to the budget of the domain it is
for through the system domain's own capability to that budget.
`liberx`'s root-task entry, `erx_root_main`, which the image's entry
reaches when the boot information page carries `ERX_BOOT_ROOT`
([design-runtime.md](design-runtime.md#the-root-task-entry)), then:

1. **Reads the machine page and the manifest.** From the machine page it
   takes the boot value, the CPUs and memory, the build identifier and
   whether a crash record of the previous boot was found; it reads no
   boot argument, since every boot argument is the kernel's. It slices the
   manifest's file from the boot image with `SYSTEM`, maps it read-only
   and reads it through the generated C reader
   ([The manifest](#the-manifest)). A manifest the reader refuses, or a
   root budget smaller than the manifest's `root_memory`, ends the machine
   with a crash record that says which, before anything is created.
   An explicitly selected native partial boot with no child programs then
   takes the ordinary partial-boot completion path. It creates no users
   group, principal budgets, domain-library tables or fault worker merely
   to end them, and admits no dynamic domains. Its dynamic-domain
   reservation is zero. The initial root image, thread, stack, UTCB and
   boot objects already exist; their feasibility and charges still belong
   to the production initial-root bootstrap plan.
2. **Gives `system` its grant**, the manifest's `system_share`, before
   it starts any other thread: the kernel holds no policy and creates
   that group uncapped. The first root worker belongs to `system` from
   its creation, so no thread
   changes group during bootstrap
   ([design-kernel.md](design-kernel.md#the-root-task)). It then creates
   the root group's second child, `users`, with the manifest's share for
   it ([Resource policy](#resource-policy)), and the `system` principal's
   budget, carved from the root budget at the manifest's size for the
   domains it lists.
3. **Creates the domain library's tables** from the root budget at the
   manifest's sizes and its **fault gate** with `erx_gate_create`. Records
   wait at the gate until its **fault thread** binds it. That thread is an
   ERTS thread, in the `system` group like every thread of the system
   domain's runtime, which the domain service's NIF module,
   `erx_domain_lib`, starts with `enif_thread_create` when it loads and
   which binds the fault gate to itself before the load returns; a module
   whose thread cannot bind does not load. Being an ERTS thread, it reports
   each end to the domain service with `enif_send`, with no hop through a
   native worker. The fault thread serves records and the ending record's
   deadline and nothing else; the module enters the library from dirty CPU
   schedulers under the library's lock, since no entry of the library
   waits.
4. **Derives the sealing secret** when the device-secret page's status is
   present, with HMAC-SHA-256 keyed by the device secret, over the ABI file's
   `sealing_secret_label`, the 20 public bytes of the ASCII text
   `erXos sealing secret`, and writes it into
   the **sealing page**, a memory object of the root budget that the
   library keeps and maps into the vault's domain alone
   ([The vault](#the-vault)). With any other status, one outside the enum
   included, it derives nothing and makes no sealing page, so the zero bytes of
   the page never become a secret, and the vault's `device` backend answers
   `unavailable`. Either way it then unmaps and closes the device-secret page
   and zeroes its own buffers with stores the compiler cannot remove. From
   then on the system domain's memory holds neither the device secret nor
   the sealing secret: it holds at most a capability to a page it does not map.
5. **Slices the boot image** for the system release with `erx_image_slice`
   and the `SYSTEM` right, maps the slice read-only, and completes the
   boot information page the kernel gave it, in the layout every domain
   receives ([design-runtime.md](design-runtime.md#data-model)): its
   budget, the `system` runtime group, release slice, the time page, the root
   resource with
   `INSPECT`, `TRACE` and `POWER`, the machine page, the crash record's
   page where there is one, its domain id, 4, and its node name. The
   system domain's lanes to
   other domains come later, one at each domain's creation.
   The page also receives the complete runtime-limit projection from
   `system_runtime_limits`, the header's `peer_held` and its checked
   aggregate peer-held bound. ERTS receives those values through its boot
   page, using the same startup validator as every other runtime; it does
   not open the system manifest to discover its limits.
6. **Starts ERTS** as every domain starts it: the runtime reads its boot
   information page and boots the release it names. One startup path
   serves every domain; the system domain's runtime image is the
   interpreter's, and every other domain runs the image its manifest
   record or its spec names.

When the manifest is a development build's with a partial boot, steps 5
and 6 give way to the partial boot below.

### Boot

1. **The kernel** validates the device tree and the boot image, starts the
   other CPUs, creates the root objects, prints its banner, which says
   `development build: trusted code only` in development builds, and
   starts the root task ([design-kernel.md](design-kernel.md#boot)).
2. **The root-task entry** reads the manifest, gives `system` its grant
   before starting other threads, builds the system domain
   as above and
   starts ERTS.
3. **The system release** starts its services under one supervisor
   ([System services](#system-services)). The domain service then creates
   the domains the manifest lists, in the manifest's boot order: in the
   default manifests the devices domain, the storage domains, the slot
   writer, the network domain, the vault's storage domain, the vault. The
   creation gives each the devices the manifest names for it, before its
   first thread starts ([Devices](#devices)), and
   the domain service grants it its facets and makes its introductions as
   the manifest lists them. Once the slot writer runs, and before the
   network domain or any user domain exists, the update service has it
   read and advance the reset count (below).
4. **The console** serves its lines: the UART, and the host link where
   the machine has one. Each line starts with a login in release builds;
   in development builds the console logs `root` in at the UART and,
   when the host opens it, at the host link's `console` line, both
   secure lines. The login asks the domain service for root's session,
   from the system principal's session template, and the session takes
   the line once its tty names itself; the system shell stays one menu
   key away, and when the session ends the console logs `root` in again
   ([design-live.md](design-live.md#the-console)).
5. **Each display's session.** For each display domain whose manifest
   entry names a session principal, the domain service starts that
   principal's session domain once the display domain runs, with no
   login, and the system domain introduces it to the display
   ([design-display.md](design-display.md#a-displays-session)).

**A reset loop ends in rescue.** The **reset count** counts the
machine's consecutive unordered ends, a fault of the system domain, its
halt outside an ordered shutdown or a missed watchdog deadline, in a
sector of its own beside the boot-selection record, which the slot writer
alone writes; the record itself is written only at a commit
([design-storage.md](design-storage.md#system-updates),
[design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)).
Since an unordered end leaves no time to write anything, the count is
advanced at boot and cleared at the two points that prove the boot good:
the update service has the slot writer add one early in every boot, a
trial boot included, as step 3 says,
and set it to zero at an ordered end, before the storage services freeze,
and at the first successful login at any line, typed or automatic: at
the UART, the host link or the web, and in a
development build the console's own logins of `root` at the UART at boot
and at the host link's `console` line. A development build's automatic
login comes early in every boot, so there rescue catches only a fault
before the console's first login. When the
count it read is past three, the system release boots its **rescue
configuration**: the console, a login, and the domains the manifest marks
for rescue, in the default manifests the devices domain, the storage
domains, the slot writer, the vault's storage domain and the vault, and
no user domain and no network domain, so an operator at the console can
repair what a deterministic fault at boot would otherwise reset forever.
The manifest check proves that the domains marked for rescue need nothing
outside themselves and the system release (property 11). An end before
the slot writer advances the count is not counted; the committed slot
booted that far in the healthy trial that committed it. Under QEMU `virt`
the harness, which plays the firmware, also stops a run that loops
([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)).

**Boot failure.** A system release that does not start ends ERTS, which
stops its space; the kernel writes the crash record and ends the machine
by `erx.panic`, because there is nothing to restart to. A configured domain
that fails to start, or ends later, the domain service restarts within the
intensity the manifest gives, as a supervisor restarts a child; beyond it,
a domain the manifest marks `required` ends the machine the same way, with
the reason in the log, and any other is left down and shown so in the
inspector, since a machine without its network is still a machine an
operator can repair at the console.

**The watchdog.** The kernel keeps one watchdog on the system domain's
pet, configured by `erx.watchdog=P,D,B`, its period, its deadline after a
pet and its boot deadline (1 s, 5 s and 60 s by default, a budget for a
runtime that schedules fairly), and off in deterministic mode
([design-kernel.md](design-kernel.md#the-watchdog)). The kernel arms it
when it starts the root task, with the deadline `B` ahead, sized to cover
ERTS's boot on the slowest board, the Raspberry Pi 4, a budget the boot
probe checks on each board; each pet sets the deadline `D` ahead. The
system release's **watchdog process**, `erx_watchdog`, a process at
priority `max` under the top supervisor, pets through
`erx_watchdog_pet(res)`, which needs `POWER` on the root resource, so no
other domain can pet or disturb it. A pet proves more than that a `max`
process runs: each period the watchdog process makes a liveness call to
every service the manifest lists for it, the domain service and the
device service at least, and pets only once each has answered within the
period. A service that does not answer is killed, its supervisor restarts
it, and the pet follows the restarted service's first answer, except the
domain service, whose kill ends the machine as its every end does
([System services](#system-services)); a service
that never answers again, or a runtime that cannot run the watchdog
process at all, misses the deadline. A missed deadline ends the machine as
a fault would, with a crash record naming the watchdog, by `erx.panic`: a
reset in release builds, and a halt in development builds, so the console
can be read. Where a board has a hardware watchdog, the kernel reloads it
from its own timer for as long as the kernel runs, so a kernel that stops
taking interrupts resets too, and a development build's halt becomes a
reset within the board's timeout; the kernel's deadline on the pet is what
catches a hung system runtime or service
([design-platforms.md](design-platforms.md#the-watchdog)). In a partial
boot no ERTS runs, so the root-task entry pets the watchdog itself until
the machine ends.

**A trial boot.** When the machine page's boot value is `trial(slot)`, the
kernel holds the machine lease, which it took at its early device-tree
pass, so every end of the machine during the trial is a reset (K19,
[design-kernel.md](design-kernel.md#console-log-and-panic)): a boot
failure, a fault of the system domain or a missed watchdog deadline boots
the committed slot. After the commit the update service ends the machine
with `reset`, so the committed system runs from a normal boot
([design-storage.md](design-storage.md#system-updates)).

**Partial boots.** A development build's manifest selects a native
partial boot with `ERX_MANIFEST_PARTIAL_BOOT`, independently of how many
programs its `partial_boot` list names. It replaces configured domains:
the
root-task entry then, instead of starting ERTS, builds each program the
list names in the boot image as a domain through the domain library, with
the default limits and no connection, starts each, pets the watchdog at
its period from its own thread, and ends the machine when all of them have
ended. The empty list follows that same completion path immediately;
it has no child to create or wait for and introduces no different end
or crash behavior. The programs write through `erx_debug_log` to the kernel log, which
the kernel's early console prints while no console driver runs
([design-kernel.md](design-kernel.md#console-log-and-panic)). This is how
the kernel interface, the domain library and the execution contract are
tested before ERTS runs. A release build's manifest has no partial boot
(property 9).

### The domain library

The domain library is the C17 in `liberx`'s system layer that holds the
system domain's root capabilities and every capability it creates for
other domains, and performs every creation, install, introduction, device
grant, stop and destruction. It is written under the kernel's construction
rules: every operation is a plan computed by a pure function from a copy
of its arguments and the library's own view, validated whole, then applied
step by step with an undo per step; checked arithmetic on every size and
count; no recursion; and the chokepoints of A5 and A7. It builds for the
host, where its plans and its state machines run exhaustively and its
fuzz target runs over creation specifications. Its entry points, called
by the domain service through the NIF module `erx_domain_lib`, dirty CPU
NIFs, since none of them waits:

| Entry | What it does | Result |
| --- | --- | --- |
| `erx_dom_principal(number, configuration)` | validates the complete normalized principal configuration, stores its resolved default and ceiling profiles, carves its budget from the root budget and creates its group under `users`, with its domain quota | `ERX_OK`, `ERX_EEXIST`, `ERX_ENOMEM`, `ERX_EINVAL` |
| `erx_dom_create(spec)` | validates an `erx_dom_spec_t` into a plan and applies it ([Creating a domain](#creating-a-domain)); a configured row's plan also gives the domain the devices the manifest places on that row ([Devices](#devices)) | the domain's record, with the number of its connection to the system domain and the system domain's values of that connection's objects, or the failing step's status after every applied step is undone, `ERX_EBUSY` when a device of the row is held by a living domain |
| `erx_dom_start(id)` | starts the built domain's first thread | `ERX_OK`; `ERX_EDEAD` for a stopped space; `ERX_EINVAL` for any state but built |
| `erx_dom_stop(id, status)` | stops the domain's space, and with it every sub-space below it | `ERX_OK`; `ERX_EINVAL` for an unknown or ended id |
| `erx_dom_resize(id, memory)` | resizes a running domain's own budget with `erx_budget_resize`, guarantee and cap together, within its principal's budget ([Resource policy](#resource-policy)); refuses a configured domain, whose sizes are the manifest's (A10) | `ERX_OK`; `ERX_EINVAL` for an unknown, ended or configured id; `ERX_ENOMEM` when the principal's budget cannot cover the growth, after which nothing changes |
| `erx_dom_destroy(id)` | destroys the stopped domain's own budget, which deletes at once every object charged to it and to every budget carved from it; the fault thread calls it at the exit record | `ERX_OK`; `ERX_EINVAL` unless the domain has stopped |
| `erx_dom_retire(id)` | releases an ended domain: destroys its crash area, frees its record and gives its principal back the domain and its own budget's bytes; destroys its outer budget when no connection names the domain, and otherwise keeps the outer budget as the domain's remains, which the disconnect of its last connection destroys; the domain service calls it once the crash area is read and the system connection disconnected, without waiting for any other connection | `ERX_OK`; `ERX_EINVAL` unless the domain has ended; `ERX_EBUSY` while its system connection stands |
| `erx_dom_connect(a, b, a_reads, b_reads)` | creates a connection between two built or running domains: carves from each domain's outer budget a child budget for the connection; creates two sides, `b`'s sized `a_reads` and charged to `a`'s child, since `a` reads it, and `a`'s sized `b_reads` and charged to `b`'s child; and two bells, each charged to the child of the domain whose group it is bound to; gives each domain its share ([Authority](#authority)) | the connection's number and each domain's values; `ERX_ENOMEM` when a reader's outer budget cannot cover its child; `ERX_ELIMIT` for a full table; `ERX_EINVAL` for a domain outside built or running, or for `a == b` |
| `erx_dom_disconnect(number)` | destroys the connection's child budgets, which deletes its sides and bells at once, and the remains of each retired party that no other connection names; the domain service asks it only once each party has unmapped them or ended; a capability to them fails with `ERX_ESTALE` from then on | `ERX_OK`; `ERX_EINVAL` for an unknown number |
| `erx_dom_code_object(session, size)` | creates a paged object with an execute ceiling from the session's budget through the system domain's own capability to it, which carries `CODE`, and gives the session a copy with `SUPPLY`, `READ`, `MAP`, `CHILD`, `DUP`, `GIVE` and `EXEC`; the kernel refuses an executable mapping of it until it is sealed (K8) | the object's number and the session's value; `ERX_ENOMEM`; `ERX_ELIMIT` beyond `file_objects` for the session |
| `erx_dom_code_drop(session, number)` | deletes a session's code object, after which every mapping of it faults | `ERX_OK`; `ERX_EINVAL` |
| `erx_dom_end_begin(how)` | installs the ending record with its absolute deadline ([Shutting down](#shutting-down)) | `ERX_OK`; `ERX_EBUSY` for a second begin; `ERX_ENOTSUP` for a trial when the boot value is `unknown` |
| `erx_dom_end_commit(how)` | ends the machine with `erx_machine_end` | does not return on success; `ERX_EINVAL` without a record, except for an emergency `reset` |

The library reports to the domain service with one kind of message,
`{domain_ended, Id, End, Record}`, which the fault thread sends to the
domain service's registered process when it has handled an exit record
([Ending a domain](#ending-a-domain)). Every other outcome is the return
value of the call that caused it.

A principal configuration contains its budget, group grant and quotas
plus complete resolved default and ceiling profiles, including their
runtime limits. The principal constructor checks defaults against
ceilings and retains immutable copies in the library's principal view.
Creation planning therefore reads those limits from the same owner that
holds the principal's budget and quota; it neither follows a requester
supplied profile index nor relies on a second default table in Erlang.

**The one installer.** Only a space's creator installs into its table
(A1), so the domain library is the one party that installs into a
domain's table, and what it installs is fixed: the domain's own budget,
group and boot objects; its connections, lanes and doorbells; the
resources of the devices it holds; and, for the vault, the sealing page.
It never installs an IPC gate of another domain, so no domain holds a gate
to another domain, no rendezvous joins two domains, and memory crosses a
domain boundary only through objects the system domain created and
charged to an outer budget or a child of one. The rule holds by construction: the plans
draw every install from `erx_dom_grants`, which has no row for a foreign
gate, and the library's host test runs a seeded plan that installs one,
which must fail.

A creation specification is the domain service's description of the
domain, a fixed layout constructed from an admitted request, a checked
configured-domain row or a checked partial-boot row. Its creation origin
is authority provenance, not a field accepted from a request:

```c
typedef struct erx_dom_spec {
	uint32_t	version;	/* 1 */
	uint32_t	id;		/* allocated by the domain service; nonzero, unused */
	uint32_t	principal;
	erx_dom_origin_t origin;	/* set by the library's origin constructor */
	uint32_t	flags;		/* ERX_DOM_SECRET: the vault's: no crash
					 * area; required for the release the
					 * boot image marks with ERX_ENTRY_SEAL,
					 * whose domain alone gets the sealing page;
					 * ERX_DOM_SPACES: it holds SPACES, with a
					 * sub-space group of grant `spaces` */
	uint32_t	release;	/* index of the release's first file in the boot image */
	uint32_t	release_files;	/* number of files in its slice */
	uint32_t	runtime;	/* index of the runtime image file */
	uint64_t	memory;		/* its own budget's guarantee and cap, bytes */
	uint64_t	outer;		/* its outer budget's guarantee and cap, bytes: its
					 * connections' child budgets and its
					 * crash area */
	erx_grant_t	grant;		/* the domain group's grant */
	erx_grant_t	spaces;		/* ERX_DOM_SPACES: the sub-space group's grant, within `grant` */
	erx_runtime_limits_t runtime_limits; /* complete per-domain startup values */
	uint32_t	lane;		/* data area of the lane the domain reads */
	uint32_t	connections;	/* the domain's connections quota, which
					 * also gives the control table on the
					 * system domain's side its slots */
	uint32_t	system_lane;	/* data area of the lane the system domain
					 * reads; both lanes of the system
					 * connection are charged to the domain's
					 * child budget for that connection */
	uint32_t	crash;		/* crash area size; zero for none */
	uint32_t	args_len;	/* NUL-separated arguments follow */
	uint32_t	env_len;	/* NUL-separated environment follows; args_len +
					 * env_len <= ERX_BOOT_STRINGS_MAX (2,048) */
} erx_dom_spec_t;
```

The library has one planning entry per source, each of which constructs
the specification from that source itself and then plans it, so no
caller ever hands the planner a specification or an origin:

* `erx_dom_plan_request(view, request, limits, given)` takes the request
  fields of a caller whose domain facet admitted it, with its principal,
  and a mask of the runtime limits the request gave; it sets
  `ERX_DOM_REQUEST` and no manifest index, resolves every limit the
  request left out from the principal's `default_limits`, and zeroes the
  strings past the arguments and environment;
* `erx_dom_plan_configured(view, id, row)` takes a row of the checked
  manifest's configured domains, from its boot order or a restart record,
  and resolves the principal, images, complete limits and flags from that
  row alone; it sets `ERX_DOM_CONFIGURED`;
* `erx_dom_plan_partial(view, id, row)` takes a checked native program
  row of a partial-boot manifest, with the partial boot's system
  principal and the manifest's native limits; it sets
  `ERX_DOM_PARTIAL_BOOT`;
* `erx_dom_plan_session(view, id, template, name, name_len, domain_pid)`
  takes an index into the checked manifest's session templates and the
  name the domain service chose; everything else (principal, images,
  arguments, complete limits and flags) is the template's and its limits
  record's, so a session is its template by construction. A template
  whose limits lack `ERX_DOM_SPACES` is `ERX_EINVAL`. It sets
  `ERX_DOM_SESSION` with the template's index; only the domain service's
  start of a session (`erx_domain:start_session/2`) calls it.

Every resolved limit is checked against the independent
`ceiling_limits`, and the specification holds the complete runtime-limit
projection defined by the ABI, not references into the system manifest.
The specification is never copied in from outside: a copied one would
carry an origin its sender chose, and comparing it with its manifest row
field by field would be a second copy of the row's layout. These are
entries over one internal type, not additional domain-creation
protocols.

The public request schema has no origin, manifest-row or CPU-parent
field; supplying one is an unknown-field error. Only the three entries
build `erx_dom_origin_t`, enforced by a source check with a seeded
violation. The configured and partial entries are called only from
manifest startup/restart and the root partial-boot entry point,
respectively, which source checks enforce in C. From Erlang the
configured entry is reached only through the domain library's NIF,
whose every entry that changes the library answers only the process
that registered with it, the domain service, and the service calls it
only from manifest startup and restart: there the rule holds by that
caller check, not by a check of the Erlang source. Neither is an
operation exposed through a domain facet. A numeric index supplied by a requester never selects
manifest authority. The planner checks the origin's range; the
specification's static fields are the row's by construction, and origin
metadata does not bypass the ordinary whole-plan checks.

**A grant fits its parent** when it asks for nothing the parent lacks:
its cpuset is within the parent's, its flags within the parent's, its
urgency ceiling at most the parent's, and its rate at most the parent's.
A grant's rate is in thousandths of a CPU: an uncapped grant's is the
size of its cpuset times 1,000, and a capped one's its quota times 1,000
over its period, rounded up. A grant whose rate cannot be stated (an
empty cpuset, a period outside the ABI's range, a quota past what its
cpuset could spend in a period, or nonzero padding) fits nothing.

CPU placement is derived from that origin: a configured domain's parent
is `system`, while a requested or partial-boot domain's parent is its
principal's group under `users`. The plan records this typed parent
selection and the resolved group capability from the locked machine
view. Its apply phase consumes that selection without choosing a parent
again. Memory ownership is independent: every origin carves both domain
budgets from the named principal's budget, and every domain space remains
a child of the system domain's space. A service's CPU placement grants
no access to another principal's memory or to a parent group capability.

The domain record retains the origin for its lifetime. A configured
domain's restart uses the same immutable manifest row, with a new domain
id; a live grant adjustment validates against the CPU parent derived
from the stored origin and the single system-reserve predicate when
that parent is `system`. A request cannot reclassify a running domain,
and no operation changes a domain group's parent. The configured-domain
baseline remains the manifest's; runtime changes do not edit it.

### Creating a domain

`erx_dom_create` builds a domain from an `erx_dom_spec_t`:

1. **Construct and validate.** The NIF calls the planning entry of the
   domain's source ([The domain library](#the-domain-library)), which
   constructs the specification in the library's memory and plans it: a
   pure function of its source and of the library's view of the machine (free
   records, the principal's budget, group and count of domains, the
   checked manifest, principal defaults and ceilings, `system`'s group
   and admitted service grants, which are the grants of the living
   configured domains' records, the number
   of domains alive, the boot image's index, whether a living domain holds
   the sealing page). It checks the version; every size against its range;
   that `id` is nonzero and names no record; that the release's files
   exist, form a slice of whole entries, and are not files of the system
   release, which the kernel's slicing refuses without `SYSTEM` and the
   library asks with that right only for its own; the runtime image's
   manifest and ABI version; the origin and its static row binding; every
   runtime limit against the principal's ceilings and the runtime's ABI
   bounds; that
   the grant fits the parent derived from that origin and `spaces` fits
   `grant`; for a configured origin, that the complete service-grant
   set satisfies the same system-reserve predicate as the manifest
   checker; that the principal holds fewer
   domains than its quota, so that a record is free, since every living
   domain is one of its principal's and the quotas sum within the
   manifest's `max_domains`; that `ERX_DOM_SECRET` is set exactly when the release is
   the one marked `ERX_ENTRY_SEAL`, and that no other living domain holds
   the sealing page then; and that the ending record is not installed,
   since no domain is created once the machine is ending. It returns a
   plan, a list of steps with their arguments including the resolved CPU
   parent, or an error. Planning and application hold the library lock;
   grant changes use that same lock, so neither the parent nor its
   admitted grant set changes between their check and use.
2. **Apply.** The steps, in order, each recording its undo:
   1. carve the domain's own budget and its outer budget, side by side,
      from its principal's, each a wall, so that every charge of the
      domain's is admitted or refused at its own budget, and nothing of
      the domain's is counted against another domain's, or against its
      principal's room beyond what a later shrink by this policy moves
      there (K32);
   2. create the domain's space with the library's fault gate, the domain
      id as the label of its records, `ERX_SPACE_JIT` exactly when the
      runtime image carries `ERX_IMAGE_JIT`
      ([design-kernel.md](design-kernel.md#image-manifests)), and the
      system domain's own space as its parent (A8);
   3. create the domain's group under the plan's resolved CPU parent with `grant`,
      and with `ERX_DOM_SPACES` its sub-space group under it with
      `spaces`;
   4. create the boot information page, charged to the domain's own
      budget; the crash area, charged to its outer budget, so the dump
      outlives the domain until the domain service has read it; and the
      domain's **connection to the system domain**, as every connection
      is built ([design-domains.md](design-domains.md#connections)), all
      of it charged to one child budget that the library carves from the
      domain's outer budget for that connection, since the system domain
      charges nothing of a domain's to its own: the system domain's side,
      the ring the domain reads with its `lane` bytes and, after it, the
      **control table**, one control slot for each connection the
      domain's `connections` quota allows, in which the system domain
      writes the domain's connection-control records
      ([design-domains.md](design-domains.md#connections)); the domain's side, the ring the
      system domain reads, with `system_lane` bytes; and a bell for each
      party, a software IRQ object, which the library binds itself, since
      `BIND` on an object conveys where its deliveries go and each group
      is the library's to bind to: the system domain's bell to the system
      domain's group and the domain's bell to the domain's group, each
      with a label that names the connection, through which the runtime
      learns which connection rang
      ([design-runtime.md](design-runtime.md#connections-in-erts));
      for a partial-boot origin the plan contains no system-connection
      objects or capability installs, and the boot page names no connection;
   5. slice the boot image for the release's files with
      `erx_image_slice`, charged to the domain's own budget; map the runtime
      image's executable with `erx_image_map`, the release slice read-only
      with `erx_vm_map` over the span the plan computes from the boot image's
      index (its first file's offset to its last file's end, rounded up to a
      page, the slice's own extent), the boot information page read-only, and for the
      release marked `ERX_ENTRY_SEAL` the sealing page read-only;
   6. give the domain its capabilities through `erx_dom_install` (A7): its
      own budget with `ALLOC`, and nothing of its outer budget or of its
      children, and with
      `ERX_DOM_SPACES` also `SPACES`, `CARVE`, `DUP` and `GIVE`; its group
      with `ATTACH` and `SIGNAL`; with `ERX_DOM_SPACES` its sub-space
      group with `CONFIGURE`, `ATTACH`, `SIGNAL`, `DUP` and `GIVE`; of its
      connection, its own side with `READ`, `WRITE` and `MAP`, the system
      domain's side with `READ` and `MAP`, and the system domain's bell
      with `TRIGGER` alone, and no capability to its own bell, whose label
      it learns; the time page with `READ` and `MAP`; the release slice;
      the crash area; for a configured row, each device the manifest
      places on the row, as a give of its own
      ([Devices](#devices)); then write the boot information page with the
      plan's complete `runtime_limits` projection, the capability values
      the installs returned, the addresses of the
      mappings, the release slice's and the sealing page's included, the
      label of its own bell, the two data areas' sizes, the domain's own
      node name, the system domain's node name and id as the peer of its
      first connection, the number and serial of the domain pid the
      request names, and each given device's record
      ([Boot information](design-stopgap.md#boot-information))
      ([design-runtime.md](design-runtime.md#data-model));
   7. create the first thread, a worker in the domain's group, with the
      boot information page's address as its argument, stopped;
   8. record the plan in the library's view with `erx_dom_plan_record`,
      the function the manifest check's host planner records with
      (property 12): the record enters `ERX_DOM_BUILT`, the principal
      counts the domain and its two budgets, the record keeps the
      domain's grant, so a configured domain's counts against `system`'s
      reserve until the domain ends, and the system connection takes its
      row and number.
3. **Return** the domain's record, with the connection's number and
   the system domain's values of its connection's objects, or the
   failing step's status after undoing what was applied, which is
   undoing the gives first, last give first, and then destroying the
   domain's two budgets, since every object of the creation is charged to
   one of them (A4); a give's objects are destroyed one by one, by their
   own handles, before the holder's budget goes. A device's contiguous
   memory is never undone: it is charged to the system domain and is the
   device's for the boot from the give that makes it, no driver has been
   told its address yet, and contiguous runs are not returned on the
   stopgap, so a fresh memory goes into the device's record and the
   row's next creation gives it again, as it does the memory an earlier
   holder kept.

The domain service creates the domain pid before it asks for the plan,
since the boot information names it, and ends it when the plan fails.
Once the library returns, the domain service hands the system domain's
values of the connection to its runtime's connection agent, which maps
the two sides and from then on carries frames between the system domain's
processes and the domain's
([design-runtime.md](design-runtime.md#connections-in-erts)); the domain
pid exports itself to the domain with `send` and to the caller's domain
with `send`, `link` and `exit`; and the domain service calls
`erx_dom_start`. The domain's runtime, before it reads its first frame,
exports its init process with `send` and the domain's name with `spawn` to
the system domain and to its spawner, both named in its boot information,
so no frame either sends from the start is dropped as one to a name never
exported; init then boots the domain's release and reports ready to the
domain pid, which passes the report to the domain service, and the domain
service answers with the facets the spec names
([design-domains.md](design-domains.md#domain-lifecycle)).
`erx_domain:create/1` returns `{ok, Domain}` when the init process reports
ready, or `{error, Reason}` when the runtime fails or the spec's boot
timeout passes first, after which the domain service has stopped and
destroyed the domain, so in every error case nothing of it remains (A4,
[design-domains.md](design-domains.md#principals-sessions-and-quotas)).
A domain may report and end at once, as one whose `-eval` halts does, and
its end may reach the domain service before its report. The service tells
the domain pid of the end only once the domain's system side is closed,
which reads the lane to its end, and the pid passes on every report still
in its queue before it ends, so the service answers a create whose domain
ended unreported only once its domain pid has ended too: `{ok, Domain}` if
the report came, its end otherwise. A runtime that is no node reports
nothing, so a domain with a system connection runs its release over the
`erx` carrier, as every domain's release does.

A domain counts against its principal's domain quota until the library
retires it, but its domain pid can end first: a kill ends the pid at once,
while the library is still tearing the domain down. A caller that acts on
the pid's end, as the console starting a login again after its session was
killed does, would then be refused with `elimit` for a domain it saw end.
So the domain service holds a create or a session's start for a principal
one of whose domains is ending, its domain pid gone but the domain not yet
retired, and runs it once that domain is retired, in arrival order with the
principal's other held starts. The hold is bounded (10 seconds): a domain
the library never retires holds no start for longer, and the library then
answers the start as it stands. The service judges an ending domain by its
pid's liveness, not by the pid's exit signal, which may still be in its
queue when the caller's start arrives, so the rule holds for every caller
by construction and no caller retries.

**On the stopgap.** The plan, its checks and its undo are the same code.
Each step's kernel call is a request to the stopgap's root service, the
one owner of every Fiasco object, served on its one thread
([design-stopgap.md](design-stopgap.md#the-root-service)), each a row of
[its call table](design-stopgap.md#the-call-table): step 1's budgets and
step 3's group are records with nothing charged or enforced, so K32's
walls do not hold; step 2's space is a Fiasco task with its parent and
fault gate recorded, so the domain's end ends its sub-spaces, and its
faults reach the root service as Fiasco's fault messages, which become
fault records at the library's gate; step 4's sides and bells are memory
objects and IRQ objects of the root, the bells bound by the library to
each party's group; and step 6's installs are `erx_cap_pass` from the
library's table into the space it created. A handle on the stopgap
carries no rights, so the rights step 6 names are the library's own
discipline, recorded nowhere: the domain gets no delete right on its
connection's objects because only an object's creator may destroy it,
and it maps the system domain's side read-only because its own `liberx`
asks for that. That a domain which bypasses `liberx` is held to step 6's
rights and that its charges stay within its walls are erXos's kernel's
([What Phase 1 defers](design-stopgap.md#what-phase-1-defers)); what the
stopgap means for connections and for the domains' invariants, D7 and D17
included, is in [design-domains.md](design-domains.md#on-the-stopgap).

Domain ids come from a counter in the domain service that only grows and
starts at 4, since stock `erlang:setnode/2` raises a creation below 4 to
4: the system domain is 4, and when the counter would pass 2^32 - 2,
creation fails with `system_limit`. No id is reused within a boot, so a
stale pid, whose creation is its domain's id, names nothing
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
A domain's name is the name of a node ([Identifiers](#identifiers)): the
domain service refuses a creation whose name a living domain holds, or
that another principal has bound, with `{error, name_taken}`, and one
that would bind a name past the principal's `names` quota with
`{error, quota}`.

**Introducing two domains.** Two domains exchange frames only over a
connection, and the system domain makes every connection, when its policy
introduces the two, in the cases
[design-domains.md](design-domains.md#introduction-and-connection-down)
lists, and at the introductions the manifest lists. An explicit
introduction needs the `introduce` right on both domain pids, which an
inspector listing or a `connection_up` that names a domain never conveys
([Authority](#authority)). The domain service calls `erx_dom_connect(A, B,
a_reads, b_reads)`: every page of a connection is charged to the party
that reads it, on a child budget of its outer budget that the library
carves for that connection, so the side `A` reads is charged to `A`'s
child and sized by `A`'s own spec, likewise `B`'s, and each bell to the
child of the party that waits on it; a sender never makes a receiver pay
for what it is willing to receive, and the receiver's policy chooses the
lane size. A side goes to the reader's outer budget, not its own, because
its writer maps it until it has answered `connection_down`, and a side on
the reader's own budget would be deleted at the reader's end under the
writer's mapping, faulting the writer; it goes to a child of the outer
budget, one per connection, so that one survivor that never lets go keeps
that connection's pages alone. The library binds each bell to its party's
group with a label that names the connection; each domain receives its
share as creation's step 6 gives it, the label of its own bell included;
and the system domain keeps the delete right to every object of the
connection and to its child budgets. A connection carries no IPC gate: no
flow of the design passes a capability between two domains. Each domain
learns of its new connection, with the values of its share, in
`connection_up` from the domain service, through its domain pid, in its
control table on its connection to the system domain, once its init has
reported ready, which its connection agent takes from that connection
alone, maps, and answers with `connection_mapped`
([design-domains.md](design-domains.md#introduction-and-connection-down)).
The domain service records the connection under both domains.

A connection ends when either domain ends, when either runtime ends it and
tells its domain pid `connection_lost`, or when policy withdraws the
introduction: each party still running that did not end the connection
itself is told `connection_down` by the domain service, through its
domain pid, into the connection's slot of the party's control table,
which no ordinary frame can fill, so the record never waits for room or
behind other frames. Each party takes
what the lane it reads holds up to that point, fires its links and
monitors with the reason, unmaps, and answers `connection_unmapped`,
which its domain pid passes to the domain service
([design-domains.md](design-domains.md#domains)). The domain service
asks `erx_dom_disconnect`, which destroys the connection's child budgets,
once each party has unmapped the objects or ended, and never on a timer
while a party lives. A survivor that never answers keeps that connection's
child budget of the dead domain's outer budget, and so the outer budget
itself as the dead domain's remains, whose limit stays carved from its
principal's until the last connection naming the domain is disconnected;
every other child of that outer budget goes as its own parties let go,
and the crash area went at the retire, so what the survivor keeps of the
dead domain's memory is one connection's pages. The connection counts against the survivor's
own
`connections` quota until it unmaps or ends, so what it can keep of
others' memory is bounded by that quota, and the inspector shows each such
connection as closing, with the party that holds it
([design-domains.md](design-domains.md#introduction-and-connection-down)).
A survivor that rings the dead domain's bell rings an IRQ object no one
waits on, until the disconnect deletes it; from then on it gets
`ERX_ESTALE`, never a fault.

**Code objects for a session.** A session that starts a program from a
file reached through an `rx` grant needs a paged object with an execute
ceiling for the program's code, which only a call through a budget
capability that carries `CODE` can create (K8). Only the system domain's
own capabilities to budgets carry `CODE`: the root budget's, and its
capability to every budget it carves, each principal's and each
domain's; the capability a domain receives to its own budget never does,
so no table but the system domain's holds `CODE`. The session asks
through its facet, and the domain service calls
`erx_dom_code_object(session, size)`, which creates the object from the
session's budget through the system domain's own capability to it, so
the session pays for its code, and gives the
session a copy with `SUPPLY`, `READ`, `MAP`, `CHILD`, `DUP`, `GIVE` and
`EXEC`: the session fills and seals it, and maps it into its programs'
sub-spaces itself, as their creator; the kernel refuses an executable
mapping before the seal. The library keeps the only `DESTROY`, so the
session's copy carries none, bounds the objects at `file_objects` per
session, and deletes one at `erx_dom_code_drop`, which the domain
service calls when the session's command server evicts the object from
its cache by asking over the session's connection; the rest go with the
session's budget at its destroy, after every program that mapped one has
stopped with the session
([design-programs.md](design-programs.md#file-objects)). A
program from the boot image needs none: its session maps its slice. A
session's shared mappings of files need nothing of the library either: the
session serves them from memory objects of its own budget
([design-files.md](design-files.md#shared-mappings)).

### Ending a domain

Every domain has two budgets, carved side by side from its principal's
by the domain library at its creation and both sized by the policy from
the domain's admission:

* its **own budget** pays for everything only the domain maps or uses:
  its space with its private memory, translation tables and capability
  table, its threads, its group and sub-space group, its boot information
  page, its release slice, its devices' resources, register windows, IRQ
  objects and DMA windows, and every budget it carves, for its sub-spaces
  or, in a session, its programs;
* its **outer budget** pays for everything another party maps or reads
  after the domain is gone: through a **child budget** carved from it for
  each connection, the side of that connection the domain reads and the
  bell it waits on, or for its connection to the system domain both
  sides and both bells; and directly, its crash area, which no other
  party maps. The domain library has no entry that maps one domain's
  memory into another but `erx_dom_connect`, which makes a connection,
  so an outer budget holds exactly its connections' child budgets and its
  crash area, by construction.

Only the system domain creates a mapping that crosses domains, and every
one is a connection's, charged to the child budget of an outer budget
for that connection, so the rule holds by construction, and what another
party maps goes only once both parties have let go of that connection.
The domain receives no capability to its outer budget or
to any child of it, and cannot destroy them. Ending a domain is **one
destroy**, of its own budget, at its exit record: every object charged to
it, and to every budget carved from it, is deleted at once, every
capability to them fails the one lookup and every mapping of them faults
([design-kernel.md](design-kernel.md#budgets), K25, K26), and since
nothing another party maps is among them, nothing waits for anyone first.
The rest goes later, by the system domain. At `erx_dom_retire`, as soon
as the domain service has read the crash area, the domain is released:
its record is freed, its principal gets back its place in `domains` and
its own budget's bytes, its crash area is destroyed, and so is its outer
budget when no connection names the domain. Otherwise the outer budget
outlives the domain as its remains ([The domain library's
records](#the-domain-librarys-records)), which hold only what a survivor
still maps. Each connection's child budget goes at `erx_dom_disconnect`,
once both parties have let go of the connection, and the disconnect of
the last connection that names a retired domain destroys its remains
with it. So a domain's end releases the domain whatever its peers do,
and only memory a peer still maps outlives it, charged to the principal
that paid for it. The system domain charges nothing of a domain's to its
own budget.

Records arrive on the fault gate at the library's fault thread, labelled
with the domain's id:

1. **A fault record** (any kind but `exit`): the library stops the space
   with `erx_space_stop(space, status)` and notes the end as `FAULT` with
   the fault's kind.
2. **An exit record** arrives once no thread of the space runs or can run
   again ([design-kernel.md](design-kernel.md#threads-and-faults)). If its
   stopper's space is the system domain's, whose fault thread and NIFs alone
   hold a capability that stops a domain, the end is
   the `FAULT` the library noted or `STOPPED` on request. Otherwise the
   space stopped itself, or its last thread ended, and its status tells
   the end: `ERX_EXIT_CRASH` is `CRASH`, and any other status is `HALT`
   with that status, among them the kernel's `ERX_EXIT_NOTHREAD`, which
   says the domain's last thread was deleted or released without exiting.
   `ERX_EXIT_PARENT` never names a domain, since a domain's parent is the
   system domain's own space, which stops only with the machine; a
   sub-space's creator sees it. A record whose label names a domain the
   library has already destroyed is dropped. The library reads nothing of
   the domain's memory; the domain service reads the crash header for the
   slogan and the dump.

On the exit record, the fault thread, under the library's lock:

1. **Destroys the domain** with `erx_dom_destroy`, which destroys its own
   budget. Its devices' objects go with it: deleting a confined device's
   DMA window aborts the device's stream before any page is freed
   ([design-kernel.md](design-kernel.md#dma-and-the-iommu)), every device
   it held is free for its next holder at once, and an unconfined device's
   memory, the device's for the boot, stays in the device's record
   ([Devices](#devices)). For the vault, the private memory that held its
   secrets and its mapping of the sealing page go before anything else
   runs, whatever the domain service does next.
2. **Reports** `{domain_ended, Id, End, Record}` to the domain service and
   sets the state to `ERX_DOM_ENDED`.

A `CRASH` end means the crash area holds a complete dump, which the
runtime wrote before it stopped its space; the area is charged to the
outer budget, so it outlives the destroy. The library needs no step for
the domain's sub-spaces: the kernel stopped every space below the
domain's when it stopped, and posts a space's exit record only after the
records of the spaces below it (A8); their budgets are carved from the
domain's own and went with it.

The domain service, on `{domain_ended, Id, End, Record}`:

1. **Takes the domain's connections down.** Its runtime's connection
   agent has the system domain's side of the domain's system connection
   finish, taking what the domain published on its lane to the system
   domain, since a dead domain's position is final, then ends the side's
   port with `{domain_down, Id, Info}`, so every facet of the domain ends
   and every link, monitor and pending spawn a system-domain process held
   toward the domain's processes fires with that reason (edit 56 of
   [design-runtime.md](design-runtime.md#the-edits-outside-syserxos)),
   each behind the domain's last messages to that process; a process that
   must act on those, such as the console facet with the domain's last
   log records, traps exits or monitors, so the exit does not kill it
   before it reads them
   ([design-domains.md](design-domains.md#links-monitors-and-exits)). The
   agent unmaps both sides, which the domain's child budget for that
   connection pays for, and the domain service asks `erx_dom_disconnect`.
   For every other connection of the domain, the domain service sends the
   surviving party `connection_down` through that party's domain pid,
   with `{domain_down, Id, Info}` as the reason, and the party takes what
   the dead domain published, fires its links and monitors with that
   reason, unmaps and answers `connection_unmapped`; the domain service
   asks `erx_dom_disconnect` once it has
   ([design-domains.md](design-domains.md#introduction-and-connection-down)).
2. **Ends the domain pid** with `{domain_down, Id, Info}`, so every
   process that linked to or monitored the domain sees its end, wherever
   it runs ([design-domains.md](design-domains.md#links-monitors-and-exits)).
3. **Records the death**, the last 16 per principal, with the record and,
   for a crash, the crash header's slogan, which it reads by copying the
   crash area into an object of its own with `erx_mem_copy`, never through
   a mapping, so a deleted source fails with `ERX_ESTALE` and never
   faults.
4. **Retires the domain** with `erx_dom_retire` once the crash area is
   read and the system connection disconnected, without waiting for any
   other connection: the library frees the record, gives the principal
   back the domain and its own budget's bytes, destroys the crash area,
   and destroys the outer budget too unless a connection still names the
   domain, in which case the outer budget stays as the domain's remains
   until the last such connection is disconnected. A survivor that never
   answers `connection_down` keeps that connection's child budget, and
   with it the remains, until it unmaps or ends, within its own
   `connections` quota, and holds back nothing else: not the domain's
   record, its name, its place in its principal's quota, nor its restart,
   unless its principal's memory cannot hold the remains beside the
   restarted domain ([The domain library's
   records](#the-domain-librarys-records)).
5. **Frees the domain's name**, and for a configured domain starts the
   domain again within its restart intensity ([Boot](#boot)).

**A lost system connection ends the domain.** A domain has no services,
facets or connections without its connection to the system domain, so
when that connection ends, the domain ends. When the system domain's
runtime ends it, for a malformed frame, a signal past `peer_held` or past
the manifest's `system_queue`, or its `peer_held_total`, its connection
agent tells the domain service, which stops the domain with
`erx_dom_stop`; a runtime that ends its own connection to the system
domain can tell no one, and halts its domain instead
([design-runtime.md](design-runtime.md#connections-in-erts)). Either way
the end reaches the fault gate and runs as above
([design-domains.md](design-domains.md#the-funnel)).

**What a domain sends the domain service.** Every message from another
domain reaches the domain service through the generated admission of its
operation schema, as every service's requests do
([design-domains.md](design-domains.md#authority)), with the domain of the
lane it arrived on stamped by the system domain's peer as `{erx_origin, D, Msg}`, which
no sender chooses ([design-domains.md](design-domains.md#the-peer)). The
service acts only on the sender's own side of a connection: a
`connection_mapped`, `connection_unmapped` or `connection_lost` reaches it
only through `D`'s domain pid, which takes it only as `{erx_origin, D,
Msg}` and passes on only those three shapes and init's ready report. The
answer names a peer, and the domain service applies it only to the
connection that joins `D` and that peer, in the state that expects it.
A message of any other shape is dropped and counted by the domain pid,
and one naming a connection `D` is not a party to, or one the
connection's state does not expect, by the domain service, so no domain
can take another's connection down or make the domain service fail by
what it sends.

**Where each object is charged.** Each object the system domain makes
for a domain is charged where its lifetime belongs, so a domain's end is
one destroy and nothing anyone still uses goes with it (A5):

| Object | Charged to | Goes |
| --- | --- | --- |
| the domain's space, with its private memory, translation tables and capability table; its threads; its group and sub-space group; its boot information page; its release slice | the domain's own budget | at its destroy, at its exit record |
| the budgets the domain carves, for its sub-spaces or, in a session, its programs, and everything charged to them | budgets carved from its own | with its own, at its destroy |
| a session's code objects | the session's own budget | at `erx_dom_code_drop`, or at the session's destroy |
| a device's resource, register windows, IRQ objects and DMA window | its holder's own budget | at the holder's destroy, which frees the device for its next holder |
| the side of each connection the domain reads, and the bell it waits on | the domain's child budget for that connection, carved from its outer budget | at `erx_dom_disconnect`, which destroys the child, once each party has unmapped it or ended |
| the domain's connection to the system domain, both sides and both bells | the domain's child budget for that connection, carved from its outer budget | at `erx_dom_disconnect`, once the system domain has unmapped it, before the retire |
| the domain's crash area, the one object no other party maps | the domain's outer budget, directly | at its retire, once the domain service has read it |
| the domain's outer budget itself, once the domain is retired | the domain's principal, as the domain's remains | at its retire when no connection names the domain; otherwise at the `erx_dom_disconnect` of the last connection that does |
| an unconfined device's contiguous memory | the system domain's budget | never while the machine runs: the device's for the boot, given to each of its holders in turn ([Devices](#devices)) |
| the sealing page | the root budget | never: the machine's |
| what the system domain's runtime holds for a domain: its frames, signals, links, monitors and facets | the system domain's runtime, in its heap, within what the domain's admission reserved ([Resource policy](#resource-policy)) | when the connection closes, at the domain's end |

### Shutting down

Every end of the machine that the system domain asks for is an **ordered
end**: `off`, which `init:stop/0` and `erlang:halt/0,1` in the system
domain ask for, `reset`, which `init:reboot/0` asks for, and `trial` or
`reset`, which the update service asks for
([design-storage.md](design-storage.md#system-updates)). For `trial` the
coordinator, a process of the domain service, first reads the boot value
in the machine page and refuses with `ERX_ENOTSUP` when it is `unknown`,
before anything changes. Before preparation it calls
`erx_dom_end_begin(how)`. The library validates the requested end and
installs an **ending record** with that request and an absolute 10 s
deadline, above the 2 s and 5 s of the two preparation steps, before
returning. There is one record: another begin cannot
replace it or extend the deadline. From then until the machine ends, no
domain is created or restarted, so a prepared service cannot come back
writable, and the fault thread checks the deadline at every timeout of
its open wait and calls `erx_machine_end(res, reset)` on expiry, including
when the coordinator has stopped answering; it runs no Erlang, so no
Erlang hang can extend the end. The decision to end is irreversible once
preparation starts: services are never thawed partway through it. The
coordinator first has the update service clear the reset count through
the slot writer ([Boot](#boot)); a clear that fails leaves the count as it
was and prevents no end. An update's whole state is the boot-selection
record, so the ordered end writes nothing of it: whether a spare slot is
complete is decided at boot, by verifying it against its update manifest
([design-storage.md](design-storage.md#system-updates)). An
ordered end then runs three steps, each with a deadline. A service that
does not answer cannot prevent the end, but its failure prevents a trial:

1. **The vault quiesces its sealing backend**, asked through its control
   interface, which only the system domain holds: it finishes the
   operation in flight, answers every later login and change
   `unavailable`, has the backend stop as its row of the `erx_seal`
   behaviour says, which under `tpm` sends `TPM2_Shutdown`, and answers,
   within 2 s ([The vault](#the-vault)).
2. **Every storage service freezes**: the system domain asks each, on its
   durability facet, for a checkpoint that freezes it, which answers once
   a completed checkpoint holds every write the service acknowledged and
   then answers every later write `{error, erofs}`, as a trial's mount
   does, waiting at most 5 s for them all
   ([design-storage.md](design-storage.md#interfaces)). An error, timeout
   or service death is an unsuccessful freeze, never an acknowledgement;
   the coordinator records each service's outcome.
3. **The coordinator selects the end from the outcomes.** `trial` is
   selected only when the vault and every storage service acknowledged
   preparation. Otherwise a requested trial becomes `reset`, which sets no
   one-shot trial flag and boots the committed slot; the log names the
   failed preparation and marks durability incomplete. Ordinary `off` and
   `reset` proceed after a failed preparation with that diagnostic, and
   every end during a trial is a reset (K19). The coordinator calls
   `erx_dom_end_commit` with the selected end, either the record's
   requested end or the fallback `reset`; the library accepts no change
   from `off` or `reset` to `trial`. For `trial` it checks the immutable
   boot value again and refuses with `ERX_ENOTSUP` when it is `unknown`;
   any refusal after preparation is followed by `erx_dom_end_commit(reset)`,
   never by resuming services. The library calls `erx_machine_end`, which
   then does not return
   ([design-kernel.md](design-kernel.md#console-log-and-panic)); it stops
   no domain first, since storage is frozen and the vault quiesced, and
   the machine's end stops every thread at once.

Only successful preparation establishes that every acknowledged protocol
write is in the frozen checkpoint and no later durable mutation or write
acknowledgement follows it. Concurrent stores through existing file
mappings have the ordinary unsynchronized-mapping semantics: a store that
races the freeze is not a durability acknowledgement, and a write-back
after the barrier is refused, so those stores are lost at the end. A
forced end after unsuccessful preparation makes no such claim: a normal
boot uses the file system's ordinary recovery, and completed durability
operations keep their own guarantees. A trial's mount without recovery is
reached only after successful preparation. The pure end decision takes the
requested end, the boot value and the complete set of preparation
outcomes; an outcome still pending is a failure at the deadline.

A halt of the system domain outside an ordered end, such as
`erlang:halt/1` with a nonzero status from a system process that bypassed
`init:stop/0`, is not ordered: the runtime stops its space, and the kernel
writes the crash record and ends the machine by `erx.panic`, as for a
fault ([The crash record](#the-crash-record)).

### Granting a running domain

`erx_domain:grant(Domain, Name, SourceFacet, Limits)` installs a facet in
a running domain. The caller must hold management authority over the
target, derived from its own domain facet's scope, never from knowing the
domain id, and authority to delegate the source facet: the source's live
grant record names the caller as its grantee, and `Limits` narrows that
record ([design-domains.md](design-domains.md#authority)). The domain
service mints the facet, a process of the system domain bound to the
target as its grantee ([design-domains.md](design-domains.md#facets)), and
sends its pid under `Name` to the target's capability registry on the
target's lane from the system domain. A facet that serves a file tree, a
storage domain's or a session's file server reached through a facet grant
included, goes with its rights and its tree's name, the attach name its
grant roots, and the namespace the domain builds from it keeps the three
together ([design-files.md](design-files.md#namespaces)). The registry
installs a name only from that lane, so no other domain can install one,
and acknowledges; the call returns `{ok, Facet}` at the acknowledgement,
or `{error, Reason}` when the target has ended or refused the name. A
replacement under the same name ends the old facet when the new one is
acknowledged, and never restores it if the installation fails. Revocation
is the facet's exit, which the registry sees as `noconnection` or a
`'DOWN'` and removes; a delayed frame naming a dead facet installs nothing
a process can use, since a dead pid names nothing (D1). Configured domains
take their baseline grants from the manifest, and `grant/4` refuses them
rather than imply that a runtime assignment edits that configuration.
Programs receive their names through their session's startup message
([design-programs.md](design-programs.md#the-channel)).

### Facets a configured domain serves

A configured domain can serve a service of its own, as the storage domain
serves `data`: the manifest's `service` row names the server and the
service's name, and a `facet` row grants that service to a grantee, a
configured domain or the system domain, with the grant's limits. Service
names are unique per server, not across the manifest. The facet is a
process of the server's domain, minted there by the server's own code with
`erx_facet:start/3`, so the system domain never stands in front of it; the
domain service decides when each grant is minted, asks the server, and
installs the result in the grantee's capability registry, under the
service's name; the facet row's own name names the row in the manifest
alone.

**Providers.** A configured domain's services each name a **mint**, a
process of the domain that mints facets of one service, with
`erx_facet:provide(Name, Mint)`, before its init reports ready, and the
ready report carries them as its `provides` map. A mint lives as long as
its domain's incarnation: the providers are the report's until the domain
ends. A server reports ready
only once it can serve: the storage domain's report follows its mount of
`/data`. The ready-report gate authenticates the reporting domain and its
connection agent ([Creating a domain](#creating-a-domain)), but the
`provides` map is the server's own words and is untrusted. The domain
service takes from it only what the manifest and the reporting
incarnation vouch for:

* the report is from the **current incarnation** of a configured domain:
  the newest domain id of that row, which has not ended and has not
  reported before. A report of an incarnation that ended, or of an older
  id than the row's newest, provides nothing;
* each name is one the row's `service` rows declare for that server. A
  name another server declares, or none does, is refused;
* each mint is a pid that incarnation **owns**: its node is the
  incarnation's node, and its creation, `erx:owner(Mint)`, is the
  incarnation's domain id. Both are checked, since a send goes over the
  connection the pid's node names while the creation is a field the pid's
  maker wrote, so a pid with the server's creation and another domain's
  node would carry the request to that domain. A pid of a third domain, a
  registered name, a fun, an `{M, F, A}` or any other term is refused, so
  the system domain sends a request only to a process of the server the
  manifest names;
* a `provides` value that is not a map, or holds more entries than the row
  declares services, is refused whole.

Every refusal is logged and counted, and leaves the rest of the report,
the domain's ready state included, as it was. What is accepted is the
incarnation's providers until it ends.

**One operation per grant.** For each configured grant, named by its
grantee and its service's name, the domain service keeps one record. The
grant's **pair** is the current ready incarnation of its server, if that
incarnation provides the name, and the current ready incarnation of its
grantee; the system domain, id 4, is always ready. The record follows the
pair, so each operation is bound to both incarnations by construction:

| State | Meaning |
| --- | --- |
| `idle` | the grant has no pair: its server or its grantee is not ready, or the server provided no mint for the name |
| `introducing` | the domain service is introducing the grantee to the server ([Creating a domain](#creating-a-domain)); skipped when the grantee is the system domain, which every domain is connected to |
| `minting` | the mint has been asked for a facet bound to the grantee, and its reply is awaited |
| `installing` | the facet's pid has been sent to the grantee's registry, and its acknowledgement is awaited |
| `installed` | the grantee acknowledged; the grant holds the facet's pid |
| `failed` | the operation for this pair failed, and was logged; nothing is retried for the pair |

The record moves on these events, and on nothing else:

* **a ready report** of a configured domain, with its accepted providers,
  or **its end**. After either, every grant whose pair changed leaves its
  state: a pending operation is cancelled, its deadline disarmed, and, if
  the grant has a new pair, a new operation starts in `introducing`, or in
  `minting` for the system domain as grantee. A grant whose pair did not
  change keeps its state, so a repeated trigger coalesces into the one
  operation already there, and there is never more than one operation per
  grant. Each operation carries a fresh **tag**, a number the domain
  service never reuses, and a **deadline** of 10 seconds from its start,
  for the whole of its introduction, mint and installation;
* **the introduction's result**: `ok` sends the mint
  `{erx_facet_mint, Tag, Name, Grantee, Limits}` through the server's
  domain pid, which the server's domain already holds, since a send
  exports its sender's pid to the receiving domain; the request names no
  process to reply to. An error fails the operation;
* **the mint's reply**, `{erx_facet_minted, Tag, Reply}`, which the server
  sends its own domain pid with `erx_facet:minted/2`, and the domain pid
  passes on as an answer of its domain, as it passes on
  `connection_mapped`. So no pid of the domain service leaves the system
  domain, and nothing a server sends reaches the domain service but
  through its domain pid. The reply is untrusted. It
  counts only from the pair's server, for an operation in `minting` with
  that tag. `{ok, Facet}` with `Facet` a pid the server's incarnation
  owns, node and creation both, moves the operation to `installing` and
  sends the grantee
  `{erx_facets_install, Tag, Name, Facet}`; any other reply fails it. A
  reply with an unknown or finished tag, a second reply, or one from
  any other domain is dropped and counted;
* **the acknowledgement**, `{erx_facets_installed, Tag}` from the
  grantee's connection agent, which installs a name only from its
  connection to the system domain and answers through its domain pid, as
  it answers `connection_mapped`. It counts only from the pair's grantee,
  for an operation in `installing` with that tag, and makes the grant
  `installed`. Anything else is dropped and counted. The system domain's
  own registry is local: the domain service installs there itself and
  acknowledges at once;
* **the deadline**, which fails an operation still pending.

Since an operation exists only while both incarnations of its pair are
current, an end of either cancels it before any later message of it is
read, and a reply or acknowledgement that arrives afterwards matches no
operation and is dropped. So no facet of an ended server reaches a
grantee, and none reaches an ended grantee, with no check before the
installation to remember. Domain ids are never reused within a boot, so an
id names one incarnation for good.

A later installation under the same name replaces the older pid, as
[Granting a running domain](#granting-a-running-domain) says; the older
pid, a facet of the server's ended incarnation, is dead already. Nothing
uninstalls a facet: its revocation is its exit, which the registry sees.
The manifest check refuses a configured grant whose name is also a facet
the grantee's spec takes from the system domain, so an installation never
replaces a facet of the ready answer; that answer reaches the grantee
first, since the domain service sends it as it takes the grantee's ready
report, which every operation for that grantee follows. Until its grant
is installed, and while its server restarts, the grantee finds the name
absent or its facet dead, and treats both as the service being
unavailable.

**Failure.** A failed operation is logged, with the step it failed in: the
introduction's error, a bad reply, or the deadline in `introducing`,
`minting` or `installing`, which names the party that was silent. It stays
failed for its pair until either incarnation changes: the domain service
retries nothing and ends neither domain over it. A service that cannot
mint ends its application, which is permanent, so its domain ends and is
restarted, and the new incarnation's ready report starts a new operation;
a failure the server does not see, a refused introduction or a grantee
that never acknowledges, leaves the grant failed until one of the two
domains restarts, which the log names for the operator. The domain
service never waits on a server or a grantee: every step is a message and
a state change, so a silent or slow mint holds one record until its
deadline and no more, and the domain service goes on handling ends and
restarts meanwhile. The server's mint starts each facet with
`erx_facet:start/3`, which exports it to the grantee before the reply
names it. A facet whose operation was cancelled or failed after the
server minted it is never installed; it ends with its grantee through its
`ends_with`, or, for the system domain as grantee, with the server. There
is at most one such facet per pair, since a pair runs one operation.

The decisions are a pure state machine, `erx_domain_mints`, beside
`erx_domain_core` and `erx_domain_links`: it takes the manifest's rows and
the events above, and returns the next state and the actions, to
introduce, send the mint, send the install, arm and disarm a deadline, and
log a refusal, a dropped message or a failure, which `erx_domain_srv`
applies; it logs and counts every refusal and drop. The actions for the
log carry only atoms, the service's own numbers and the reasons the core
names, never a term a domain sent. It is tested exhaustively over every
order of these events, with two incarnations of a server and of a
grantee, a third domain that claims the name, forged pids, and replies
that come late, twice, or from the wrong domain.

### Authority

Who holds what, with the rights each capability carries:

| Holder | Holds |
| --- | --- |
| the system domain | the initial capabilities, the root budget (`ALLOC`, `SPACES`, `CODE`, `CARVE`), the root resource (`CARVE`, `POWER`, `TRACE`, `ENTROPY`, `INSPECT`) and the boot image (`SYSTEM`) among them; every principal's budget and every domain's space, own and outer budgets and group with every right; every object it created for a domain; every connection's objects and child budgets, with the only `DESTROY`; every device's objects until it gives them, and their `DESTROY` always; every unconfined device's memory; the fault gate (bound to the fault thread); the sealing page; the time page; `CONFIGURE` on the `system` group, the `users` group, every principal group and every domain group; on another domain's processes, only what that domain's runtime exports to it, as any peer ([design-domains.md](design-domains.md#authority)) |
| a domain | its own objects; its own budget (`ALLOC`, and `SPACES` only where the system domain allows it, [Sub-spaces](#sub-spaces)); its group (`ATTACH`, `SIGNAL`) and the group's shared areas; for each of its connections: its own side (`READ`, `WRITE`, `MAP`), the peer's side (`READ`, `MAP`) and the peer's bell (`TRIGGER`), and no capability to its own bell, which the system domain bound to the domain's group and whose label the domain knows; the time page (`READ`, `MAP`); its release slice; its crash area; its boot information page |
| a domain that holds a device | as a domain, plus the IRQ objects of the device's lines or MSIs (`BIND`, `ACK`), which its driver binds to the domain's group; its DMA window (`MAP`, `BIND`), or for an unconfined device its contiguous memory (`READ`, `WRITE`, `MAP`, `PHYS`); its register windows' memory objects (`READ`, `WRITE`, `MAP`); for the block device's domain and the slot writer, a read-only view of the machine page; all as the domain's creation gave them |
| a session domain | as a domain holding `SPACES`, plus each code object the domain library made for it (`SUPPLY`, `READ`, `MAP`, `CHILD`, `DUP`, `GIVE`, `EXEC`), and every object it creates for its programs, their channels, pipes and shared mappings of files, with every right, since it is their creator ([design-programs.md](design-programs.md#a-program-is-a-port), [design-pipes.md](design-pipes.md#making-a-pipe), [design-files.md](design-files.md#shared-mappings)) |
| a domain holding `SPACES` | as its kind of domain, with `CARVE`, `DUP` and `GIVE` also on its own budget; its sub-space group, a child of its group with a grant of its own (`CONFIGURE`, `ATTACH`, `SIGNAL`, `DUP`, `GIVE`); each sub-space it created, with every right, and what it put in them |

**The grant table.** Every capability the system domain installs in another
space goes through one function, `erx_dom_install`, which takes a row of
`erx_dom_grants`: a constant table that names, for each step of each
operation, the object's kind, the recipient's role and the rights mask,
each mask within its recipient's row above (A7). Every row is an
**install**: `erx_cap_pass` from the system domain's own table into the
recipient's space, as a copy, under the kernel's rule for a space's
creator, which may pass what a type's pass set excludes, such as a budget,
a group or a device's objects, and passes a space's own capability with
`INSPECT` alone ([design-kernel.md](design-kernel.md#passing-capabilities)).
Its recipient is the domain being built, at creation's step 6; either end
of a connection, at `erx_dom_connect`; or a session, at
`erx_dom_code_object`. A device's holder is the domain being built, and
the gives of its creation install the device's objects. The library
never passes out of another domain's table and never moves a capability:
no flow in the design needs it, and a session installs into its programs
itself.

Every install and every pass intersects rights with a mask, and a pass
between two spaces of which the caller is not the creator also with its
type's pass set, so authority only narrows as it flows outwards from the
system domain ([design-kernel.md](design-kernel.md#invariants), K2, K17,
K24); none of a connection's sides, the time page or a device's objects
carries `GIVE`, so no domain passes its fabric or its devices on. No
domain holds `DESTROY` on memory another domain maps: the system domain
keeps the delete right to every connection's objects and every code
object the domain library creates, and a session to every ring and page
it creates for its programs, so no client can make a server or a driver's
domain fault. No domain holds another domain's space with `CAPS`, so no
domain installs anything into another domain's table, and no introduction
makes an IPC gate between two domains, so no domain holds a gate another
domain serves and no rendezvous joins two domains: what a domain holds
came from the system domain, from its own creations, or, in a sub-space,
from its creator.

**Introducing is a right of its own.** A connection is authority between
two domains, so the domain service makes one on a principal's request
only when the caller's domain holds `introduce` on both domain pids
([Creating a domain](#creating-a-domain)). That right is set only
by the owner's own export, `erx:export/3`, and encoding a domain pid in
a frame or a listing conveys `send` alone, so knowing or relaying a
domain pid never lets anyone join that domain to another
([design-domains.md](design-domains.md#exports)).

Facets carry authority of the connection's kind, not the kernel's: a facet
is a process of the system domain that acts only for its grantee, the
domain at the other end of the lane its requests arrive on, so knowing a
facet's pid grants nothing
([design-domains.md](design-domains.md#facets)). A program has no facets
of its own; everything beyond its session is a request to its handler
([design-programs.md](design-programs.md#the-handler)).

### Sub-spaces

A domain whose budget carries `SPACES` creates **sub-spaces**: address
spaces of its own, as any L4 task holding a factory creates tasks
([design-kernel.md](design-kernel.md#creating-spaces)). A sub-space has no
domain id, no node name, no export table, no connection and no record
in the system domain: it belongs to the domain that created it, which may
run code of unknown provenance there, holding only the capabilities it
was handed.
A session's programs are sub-spaces, and ports of the session's runtime
([design-programs.md](design-programs.md#a-program-is-a-port)); a native
shim is a sub-space port of its driver's domain
([Drivers](#drivers)).

* **Its creator builds it.** The creator holds the sub-space's root
  capability with every right. It maps into it objects it holds, beneath
  their ceilings; creates its threads in groups it holds, charged to a
  budget it holds, so the sub-space spends from the domain's budget and
  grant; installs capabilities into its table with `erx_cap_pass`, under
  the creator's rule; and copies it with `erx_space_copy` for `fork`
  ([design-kernel.md](design-kernel.md#copy-on-write-children-and-copies-of-spaces)).
  Code in a sub-space runs only what its creator could map with execute,
  and a sub-space allows JIT objects only when its creator's space does,
  so the right to make code still follows from the domain's image.
* **Its faults go to its creator.** Its fault gate is a gate the creator
  serves, or one whose server handed the creator `SERVE` on it, fixed when
  the sub-space is created; the system domain sees none of its records.
* **It ends with its creator.** Its parent is the creator's space or one of
  its sub-spaces, so it stops when the creator stops (A8); its capabilities
  never leave the creator's domain, and everything it is made of is
  charged to a budget carved from the creator's, so the creator's destroy
  deletes it whole (A5).
* **It cannot make its creator fault.** The creator gives a sub-space
  memory without `DESTROY`, and reaches memory the sub-space created only
  by copying with `erx_mem_copy` between that memory and an object of its
  own, which fails with `ERX_ESTALE` instead of faulting when that memory
  is gone, the kernel's rule for servers
  ([design-kernel.md](design-kernel.md#closing-and-deleting)).
* **Who may create them.** The system domain decides, as it decides every
  grant: a configured domain holds `SPACES` when its manifest record asks
  for it, and a session holds it always, since its
  programs are sub-spaces; an ordinary domain gets it only when its spec
  asks and its principal's policy allows. The domain library gives a
  domain that holds `SPACES` its budget with `CARVE`, `DUP` and `GIVE` as
  well, and a **sub-space group** under its group, starting with the grant
  the policy sets, `spaces`, and with `CONFIGURE` on it. That grant is a
  starting value, not a bound: the domain may set it anywhere within its
  own group's grant, which bounds every group below it, since what its
  sub-spaces spend comes from the domain's own grant either way. So the
  domain carves a budget for each sub-space, creates groups under the
  sub-space group for sub-spaces that need grants of their own, a
  program's child group for job control among them
  ([design-programs.md](design-programs.md#a-program-is-a-port)), sets
  their grants, and gives them, all within its own budget and grant:
  budgets and groups never pass between domains (K24), and the domain
  holds no `CONFIGURE` on its own group, whose grant stays the policy's. A
  domain hands `SPACES` on only within itself, by giving one of its
  sub-spaces a budget that carries it.
* **Seen nested in their domain.** The inspector shows each domain's
  sub-spaces under the domain's path, through `INSPECT` on the domain's
  space, which reaches the spaces below it
  ([design-live.md](design-live.md#paths)); a session's programs appear
  there as its ports, with their names; their charges are the domain's,
  since its budgets pay for them; a domain's crash report lists its
  sub-spaces with their states and charges, which that `INSPECT` reads.

### Resource policy

The resource policy is Erlang in the system domain, `erx_policy`. It owns
the group tree below the root, every grant in it, the budgets per
principal and domain, and the rule every shared service follows to admit
its clients.

**The group tree.**

```text
root
 |- system (aggregate grant, capped; contains the system runtime's threads)
 |   |- storage domain
 |   |- network domain
 |   |- devices domain
 |   |- vault, and its storage domain
 |   |- the PCIe domain
 |   `- any other domain the manifest lists
 `- users (system domain: CONFIGURE)
     |- principal "alice"
     |   |- domain 7 "notes"
     |   |- session 8 "alice_1"
     |   |   `- sub-space group: her programs, one child group each
     |   `- domain 9 ...
     `- principal "bob" ...
```

No group ever charges another group's time: every thread is charged to
its own group, the kernel's rule
([design-scheduler.md](design-scheduler.md#invariants)). A shared service
runs on its own group's grant, which the policy caps and sizes for the
domains it serves.

`system` directly contains every thread of the system domain; configured
service groups are its children. The kernel creates `system` uncapped
and puts the first worker there at creation; the root entry sets its
manifest grant. Thread membership is immutable, so bootstrap needs no
migration or second runtime startup. The aggregate cap applies to both
the direct runtime and the service children. The principal budget tree
is independent of this CPU hierarchy.

**Grants.** The defaults, all subject to experiments E-S1 and E-S8
([design-scheduler.md](design-scheduler.md#performance)):

| Group | Quota per period | Base urgency | Ceiling |
| --- | --- | --- | --- |
| `system` | a capped share of the machine, from the manifest, given by the root-task entry before anything else ([The root task](#the-root-task)) | 24 | 47 |
| a service domain the manifest lists (storage, network, devices, PCIe, the vault) | a capped share, sized for the domains it serves | 28 | 40 |
| `users` | the root group's remainder after `system` | 16 | 31 |
| a principal | its configured share of `users` | 16 | 31 |
| a domain | its spec, within its principal's | 16 | 31 |

A service's urgency places its work above ordinary user work; urgency is
not permission to run without quota, and a service that exhausts its quota
slows every client of that service together. That is the cost of running
services on their own grant, and the one Genode has shipped on: memory per
session, CPU by quota and priority per component. The policy sizes a
service's grant from the admissions it gives the service's clients: the
sum, over its clients, of each grant's share of measured reductions per
period, with headroom from the configuration; the grant is the cap, and
when the cap is reached the service shares it among its clients as Erlang
shares a runtime among its processes.

**The system domain's reserve.** `system_reserve` is the fraction of the
aggregate system grant that configuration leaves unassigned to service
children, expressed in thousandths: 250 means one quarter. Property 13
checks that headroom using normalized rates and configured CPU sets.
The system runtime spends the aggregate group's remaining quota
directly, with no independent runtime cap. At run time a service-grant
change uses the same predicate; a refused change returns `{error, quota}`
and changes no grant.

Headroom is not a real-time reservation. Independent quota periods,
bursts, priorities and placement can delay control work despite a
configuration passing that arithmetic. The watchdog deadline and control
latency are tested under the shipped configurations and adversarial
service loads; the headroom check alone proves neither. No replenishment
epoch, dedicated runtime group or separate scheduling mechanism follows
from `system_reserve`.

**Admission.** A shared service admits requests per client, by the
client's share of measured reductions per period, in the client's
**facet process**, one per grant of the service to a client, which
accounts the reductions its own work and the service's work on each
forwarded request spend, and takes no request once the share is spent
until the next period ([design-domains.md](design-domains.md#facets)).
Admission is that process's own loop, its queue quota and its
`max_heap_size` with off-heap binaries counted, the grant's
`max_request`, and the client's lane: a flooder fills its own lane and
blocks itself, since the funnel leaves its frames in the lane once the
facet holds its quota, and a sender whose lane is full waits in its own
runtime ([design-domains.md](design-domains.md#flow-control)). A
service's control steps are bounded by construction, not by arithmetic:

* generated decoders with schema bounds, so an unexpected shape or size is
  refused with bounded work, before any heap is built from it, and a field
  that carries opaque application data is bounded in bytes and never
  decoded as a term in the service;
* no loop over client-sized data outside the decoder;
* no request whose work grows with the client's input, unless that work
  runs in the client's own domain, as preparation the service validates
  completely before it acts on the result, or in the service's own domain
  within its own grant, where the service schedules its clients fairly as
  Erlang schedules its processes;
* one **commit funnel** per shared state: a shared-state owner accepts
  complete, validated commit descriptors; its mutation phase is bounded,
  calls no client callback and performs no blocking I/O while it holds
  shared state; it publishes a result or a defined failure, then releases
  that state. Preparation and external I/O happen outside it, and a
  completion returns as another descriptor, so no client's slowness holds
  the turn every other client needs.

Preparation runs in the client when the service can validate its complete
result without trusting how it was computed; a client cannot be made to
prepare what it cannot validate, and a service cannot be made to compute
what it did not admit. What a service holds per client is therefore
bounded by the client's facet process and the client's lane, and what it
spends is its own grant's, so nothing else needs accounting: the kernel
charges the service's threads to the service's group, and the runtime
charges each client's facet process to its own heap bound. A service
refuses a new binding it has no capacity for before any work starts, and
never borrows another client's.

**Attribution.** Per-client CPU is an inspector statistic: each service's
facet processes report their reductions and the work they forwarded, and
the inspector shows them per client
([design-live.md](design-live.md#inspection)). It is never an enforcement
mechanism; the enforcement is the service's own grant and each client's
facet and lane.

**Capacity.** The policy publishes each domain group's capacity and its
run ([design-scheduler.md](design-scheduler.md#status-words-and-capacity))
so that, on every CPU, the shares of the runs that include it, each
group's capacity spread evenly over its run, sum to at most one CPU. Its
rule, `erx_policy:capacity/1`, is a pure function of the grants and
cpusets:

1. Each group's demand is the lower of its cpuset's size and its quota per
   period.
2. Its target is its demand scaled by the lower of one and the machine's
   capacity over the sum of every group's demand.
3. The groups are placed one at a time, smallest target first, then by
   group id. Each takes, among the runs its cpuset allows, the one whose
   CPUs have the most room left, the lowest first position on ties, and
   the most capacity, up to its target, that the run holds spread evenly.
   It starts with runs of its target rounded up, at least one CPU long. A
   run of n CPUs carries more than n - 1 CPUs of capacity, so where the
   best run of n holds no more, the group tries runs of n - 1, down to
   one.

Placing a group only takes room it found free, so the shares on every CPU
stay within one CPU by construction. A group that finds no room has
capacity 0, which its runtime reads as one executor on its run's one CPU
([design-runtime.md](design-runtime.md#the-adapter)), and where runs do
not tile the CPUs some room stays unadvised; both cost only advice, since
the cpusets and quotas are what bind. The policy recomputes capacity when
a domain is created or ends and when a grant changes, and publishes a
change only when a run moves, a capacity changes by more than a tenth, or
100 ms have passed, so runtimes do not churn their schedulers.

**Budgets.** Each principal's budget is carved from the root budget at the
manifest's size, as a wall, a budget whose cap is fixed equal to its
guarantee ([design-kernel.md](design-kernel.md#budgets)); each domain's
two budgets from its principal's, side by side and each a wall:
its own budget at its spec's `memory`, and its outer
budget at its spec's `outer`, which the policy sizes from the
domain's admission: a child budget for its connection to the system
domain, holding both of that connection's lanes, the one it reads at its
lane size with the control table and the one the system domain reads at
`system_lane`, with both bells; a child budget for each connection its
`connections` quota allows, holding the lane it reads at its lane size
and its bell; each child's own records; and its crash area
([Ending a domain](#ending-a-domain)). An
introduction carves a child from the reader's outer budget, which the
policy sized for it, so an introduction fails with `ERX_ENOMEM` only
beyond the domain's own quota. Every budget the domain library carves,
the connection children included, is a wall, so the kernel admits or
refuses every charge of a domain's at the domain's own budget, counts
none of it against another domain's, no principal spends beyond its own,
and a domain's memory depends on nothing outside it but the kernel (K32,
[design-kernel.md](design-kernel.md#budgets)); and the library's grant
table passes no budget with `DESTROY`, so no domain resizes a budget of
its own (A7). The policy corrects the size of a domain it created at run
time with `erx_budget_resize` through the domain library's
`erx_dom_resize`, which moves the own budget's guarantee and cap together
within the principal's, so a domain is resized without being restarted;
a shrink beneath what the domain holds leaves the excess counted in the
principal's room until the domain frees it, with every charge that would
raise the domain's spending refused meanwhile, which is the one way a
domain's charge is counted there, and the policy's own doing; a shrink
takes nothing back from a sub-space budget the domain carved within its
own, whose charges within its guarantee go on, as the kernel's rule
says; a configured domain's budgets stay as the manifest says, as its
grants do (A10, [Granting a running domain](#granting-a-running-domain)).
A session carves from its own budget a **pool for its programs**, half
of its budget by default and a wall, and keeps the other half for its own
services, the shell, the terminal relay, the handler and the pipe server,
so that a loop of programs never starves them
([design-programs.md](design-programs.md#a-program-is-a-port),
[design-shell.md](design-shell.md#invariants)). From the pool it carves
each program's budget, as its creator, elastic, with a **floor** as its guarantee,
what the smallest program needs to start and to end, from the measured
cost of experiment E-P1 ([design-programs.md](design-programs.md#performance)),
and with the cap its policy gives the program, the pool's whole size
unless the starter asks for less, so that a program draws on what its
siblings are not using and is refused only when the pool is full, as a
QNX process is at the system's pool within its `RLIMIT_AS`, and a
session runs as many programs as fit rather than as many as their
guessed sizes would. The system domain sets no quota per program, since
a program spends only what its session's pool has.

**What a domain can make the system domain hold.** The system domain is
the one receiver every domain reaches, and an allocation failure in its
ERTS is a reset, so what one domain can make it hold is a sum fixed when
the domain is admitted, with these terms for its connection to the
system domain ([design-domains.md](design-domains.md#flow-control)):

* the lane the system domain reads from the domain, the manifest's
  `system_lane` bytes with its ring header and reader page, charged, as
  the other lane of that connection is, to the domain's child budget for
  the connection, carved from its outer budget, not to the system
  domain's, so this term is only the system domain's mappings of both
  sides, the capability slots that name the domain's objects, and its
  copy of each control slot's `seq`, 8 bytes per slot;
* one open-record buffer for that lane, which grows as the record's
  bytes arrive and is never allocated whole on its header's word, up to
  the system domain's `max_frame`, the largest `max_request` a grant may
  name, not a domain's general limit;
* its outbound queue to the domain while the domain's lane from it is
  full, up to the manifest's `system_queue` (16 KiB), the rest of a long
  frame being written in parts included; past it a message from the system
  domain is dropped and counted, and any other signal ends the connection,
  which ends the domain;
* what it holds because of the domain's processes, their links and
  monitors with system processes and the signals queued for them, up to
  the system domain's own `peer_held`, which the manifest
  sets far below a domain's 4 MiB, since system processes hold few links
  and monitors toward any one domain (64 KiB, an estimate the hostile-domain
  tests check); past it the connection ends;
* each facet granted to the domain, up to that facet's `max_heap_size`,
  toward which the frames copied out of the lane for it and not yet
  decoded count, with the off-heap binaries it holds.

The domain service sizes the system domain's reservation at admission: it
admits a domain only when the system domain's own budget, the root
budget less what it carves for principals, holds that sum for every
admitted domain, the new one included, beside the system domain's own
baseline, and refuses the creation with `system_limit` otherwise; a
later grant adds its facet's term and is checked the same way before the
facet is minted. So no admitted domain, and no set of them, can make the
system domain hold more than it reserved, and nothing of a domain's is
charged to the system domain's budget at all: the kernel objects made for
a domain are on its own budget, its outer budget or the outer budget's
children, and these terms are the
system domain's runtime's own memory. A lane's default size is a
class's, set in the manifest and tuned by the domains design's
experiments ([design-domains.md](design-domains.md#connections)).

**Domains per principal.** `erx_dom_principal` gives each principal a
quota of domains; the library counts the domains each principal has, from
creation to destroy, and refuses a creation beyond the quota with
`ERX_ELIMIT`, which the domain service reports as `quota`. Each principal
also has a `names` quota, 64 by default, of node names it may bind within
the boot ([Identifiers](#identifiers)), so that the atoms the system
domain makes of peer node names are bounded by the sum of the quotas the
manifest gives, beside the configured domains' own names. The manifest's
quotas sum within `max_domains`, which the manifest check proves, and
every living domain, configured or requested, is one of its principal's,
so a creation within a quota always finds a record and no principal can
take another's domains, as budgets keep one principal's memory from
another's. Principal numbers are
fixed within a boot.

### Devices

The device service, `erx_devices`, owns the machine's devices on behalf of
the system domain. At boot it reads the root resource's device list
through `erx_object_info` and builds a catalogue: path, compatible string,
register ranges, interrupt lines, and whether a device is confined
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
Each device goes to the one domain the manifest names for it, as part of
that domain's creation: for each catalogue entry whose unit the manifest
places on the configured row, `erx_dom_plan_configured` adds a **give**,
planned by `erx_dom_plan_device_give` and applied whole by one step of the
creation's plan. A give carves the device's resource, creates its
register windows as physical memory objects with device attributes, its
IRQ objects and, for a confined device, its DMA window, all from the
holder's own budget; for an unconfined device it gives the device's
contiguous memory instead (below); and it gives the holder its
capabilities ([Authority](#authority)). A give is its own plan, not
steps in the creation's, because every device's objects use the same
object numbers and so cannot share the creation's object namespace; a
creation holds up to eight. No device service has to give at the right
moment. The planner gives a device only to a domain of the row its unit
is placed on, and refuses a give with `ERX_EBUSY` while a living domain
holds the device, so a second domain of the row is refused while the
first lives. On success the device's record names the holder and its
objects; at the holder's end the window, line, resource and DMA objects
are destroyed and the record names no holder, while the contiguous
memory stays the device's for the boot, and the row's next creation
installs that memory again instead of making new. A catalogue entry's
index is its manifest device row. On erXos's kernel the carve finds the
device in the root resource by the entry's device-tree path, not by its
position in the resource's list. `erx_domain_lib:devices/0` returns the
catalogue with each entry's holder: `{ok, [#{index, unit, row, role,
holder}]}`, where `row` is a configured row or `system`, `role` is
`block`, `net` or `none`, and `holder` is a domain id, `system` or `none`.
The `PHYS` right on contiguous
memory goes only to the domain of the device the memory is for, and is
stripped from every other capability to that memory. A device the
manifest does not name goes to no domain, and a PCIe function among them
keeps its bus mastering off.

**The machine is held to the manifest's marks.** The manifest marks each
DMA device confined or unconfined, and its check reasons from those marks
([The manifest](#the-manifest)). At boot the device service gives a device
marked confined only on an IOMMU stream the device tree shows for it, and
otherwise gives it to no domain and logs a diagnostic naming the device
and its mark, so a machine whose fabric confines less than its manifest
assumed runs without that device rather than with an unconfined device
where the check allowed only a confined one. Likewise the console: the
manifest names the console's UART by device-tree path, and the device
service refuses at boot a manifest whose `console` path is not the UART
that the device tree's `/chosen/stdout-path` names, the one the kernel's
early console writes
([design-kernel.md](design-kernel.md#console-log-and-panic)): it fails
its start, so the system release does not boot and the machine ends as a
failed boot does ([Boot](#boot)), with a kernel log line naming both
paths. The
check proves the host link's path differs from the console's (property
8), so a host link the boot accepts is never the console's UART, however
firmware rewrites the `serialN` aliases.

**Which domain holds a device is the manifest's**, and nothing else: a
device goes where its capabilities are installed, and devices are given by
unit (Units, below). The default manifests put the block device in the
storage domain, the network device in the network domain, the TPM, with
the controller of the serial bus it sits on where a board offers it that
way, in the vault's domain, the PCIe configuration window, where the
platform has a bridge erXos drives, in the **PCIe domain**, `pcie`, which
runs the PCIe enumerator and holds nothing else, the console's and the
host link's UART units in the system domain (The console, below), and
every other device the kernel does not keep (GPIO, I2C, the
other SPI controllers, and whatever else the board offers) in one
**devices domain**, which is not in the trusted base. On every platform, a
device whose DMA is unconfined, so that it reaches all memory, gets a
domain of its own in a release build's manifest, so the domains that parse
hostile media and packets never hold a device that is the whole machine
(property 9): on QEMU `virt`, where the IOMMU confines PCIe
functions alone, a release build's manifest therefore gives the block and
network devices as virtio-pci functions, and any virtio-mmio device it
keeps a domain of its own; on the boards, which confine nothing, every DMA
device has one ([design-platforms.md](design-platforms.md#qemu-virt)). A
development build's manifest may merge them. Each such domain is a
configured domain like any other: created by the domain service at boot,
restarted by it within its intensity, its devices given again as it is
created ([Boot](#boot)). A device that stops answering its bus, so that a
register access aborts, faults the thread that touched it, which ends the
domain as any fault does; the domain service restarts it, and its driver
resets the device.

**The console.** The console port, and the host-link port where the
manifest names one, are UARTs like any other device, each named by its
device-tree path in the manifest's `console` and `hostlink` fields, and
every manifest, release and bring-up alike, gives both UARTs' units to the
system domain itself (property 8). There the console driver, an Erlang
process over the device NIF, feeds the console service, `erx_console`,
which connects one session's tty to the line at a time and copies its
bytes without reading them
([design-live.md](design-live.md#the-console)). So no domain can read a
passphrase typed at the login prompt, and a domain writes to the operator
only through a connected session's tty. On the Raspberry Pi 4 the
console's unit is the mini UART's, which shares its page with the
auxiliary SPI controllers, and the host link's is the PL011s' unit; both
go to the system domain, which drives neither the auxiliary SPI
controllers nor the PL011s the host link does not use
([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)). The
kernel shares the console's UART in time and keeps no register page of it:
it writes the UART by polling, at the address its platform build fixes
and through a mapping it makes for those writes, during its boot and at
a panic or the machine's end, and the driver owns it otherwise
([design-kernel.md](design-kernel.md#console-log-and-panic)).

**On the stopgap.** The device service, the manifest's placement, the
drivers and their supervisors are the same code. In a give, the domain
library creates a device's register window, its line's IRQ object and, at
the first give, its contiguous memory, all in the root, from the catalogue
entry at the give's index, which is the manifest's device row (neither
backend has a resource object, so the give's resource step makes
nothing), and passes them to the holding domain, whose
driver maps the window and binds the line to its own group, so the line's
deliveries reach that task's readiness dispatcher; no device object is
created from a task other than the root
([Device records](design-stopgap.md#device-records)). At the holder's end
the library deletes the window's and the line's objects and keeps the
contiguous memory for the restarted holder, as this section says of any
unconfined device. QEMU `virt`, as the harness starts it, has no IOMMU
and attaches its devices over virtio-mmio, so every DMA device on the
stopgap is unconfined. The catalogue is the manifest's device table:
the domain library's boot view builds an entry per device, placed on its
unit's holder, derives the units from the devices' register pages, and
refuses the whole view when devices that share a page are in two unit
rows, or when a device is marked confined, since the stopgap lists no
IOMMU stream; the manifest check builds the same view, so such a
manifest fails the build, and no domain is created from a placement the
view did not admit. The development manifest still gives each device
to its own domain once drivers move out of the system domain: the block
device to the storage domain, which runs the block driver and the file
systems, littlefs as its sub-space port; the network device to the network
domain; virtio-gpu and virtio-input to the display domain. The Phase 1
manifest check allows these unconfined devices in a development build, and
property 9 refuses them in a release manifest as it does on erXos's kernel;
the stopgap builds no release. Drivers die and restart under their
supervisors as this section describes, but their DMA reaches all memory,
so a driver, or a domain that parses hostile bytes beside one, can reach
every domain through its device. DMA windows, MSIs and the lifetime of
device buffers are erXos's kernel's
([What Phase 1 defers](design-stopgap.md#what-phase-1-defers)), and moving
a device to virtio-pci behind the IOMMU then changes its device record and
its DMA profile, not its driver.

#### Drivers

A **driver** is an Erlang process under a supervisor in the domain that
holds its device, written against the **device NIF**, `erx_device`, the
one C beneath it ([design-runtime.md](design-runtime.md#the-device-nif)).
Drivers come in one application per device class under `erlang/apps/`,
`erx_uart` for the UARTs; only their modules and `erx_device` itself
name `erx_device`, which a source check with a seeded violation enforces.
Through the NIF:

* **Registers** are read and written by name, through the accessors
  generated from the device's CMSIS-SVD file, never by raw address, so the
  one-source rule holds
  ([design.md](design.md#one-source-for-the-abi-and-the-hardware)). The
  NIF maps the register window the domain holds and resolves each name to
  an offset and a width at load, from the generated table for the device's
  compatible string. Every register carries a mark in the SVD source
  saying whether it holds a device address, such as a ring's base, and
  the NIF refuses a write of a marked register from Erlang: it writes
  those itself, from its own pools and queues.
* **Buffers** come from a pool in a DMA-mapped memory object the domain
  holds: for a confined device the NIF maps the pool into the device's
  window; for an unconfined one the pool is a range of the device's
  contiguous memory. Pools and queues are state of the device's record in
  the NIF, never of a driver process, so a crashed driver leaves them in
  place. Every device address the NIF gives a device is built from that
  object, an offset and a length, checked, and an address a device may
  still hold is left unused until the device's completion protocol has
  retired it or the device has been reset, the envelope's quarantine rule
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)). The NIF copies
  each received buffer's bytes into a fresh binary at completion and
  returns the buffer to its pool, so no binary aliases memory a device
  can write; transmit copies into the pool. Both copies are per-byte C.
* **Descriptors** are posted and completed through the NIF, which writes
  the fields the device's ring format names and reads back what the
  device wrote as a binary. The driver chooses only the fields the format
  marks as its own; every address field, and every flag that makes the
  device fetch an address, such as virtio's `NEXT` and `INDIRECT`, the
  NIF writes alone. **The NIF parses nothing a device wrote**: Erlang
  does, with binary pattern matching in the supervised driver process, so
  a malicious or broken device corrupts no memory. A device that writes
  nonsense crashes at worst the one process that parsed it, which its
  supervisor restarts, and a device that stops answering its bus, so that
  a register access aborts, ends its domain, which the domain service
  restarts ([Devices](#devices)).
* **Interrupts** are messages. The driver binds its line's IRQ object to
  the domain's group through the NIF, which registers the process as the
  label's owner and acknowledges the line once, so a line that a crashed
  driver left masked is unmasked for its successor; the runtime's poll
  backend delivers each firing to the process as a message, and the
  process acknowledges through the NIF after it has served the device,
  which unmasks the line
  ([design-kernel.md](design-kernel.md#irq-objects)). A process's exit
  unbinds only the lines still bound under its own label, so a late exit
  never undoes a successor's binding. No dirty scheduler blocks in an
  interrupt wait, and interrupt-to-handler latency passes through the
  runtime's scheduler, so gate G9 decides batching per device class
  ([plan.md](plan.md)).
* **Clients** of a driver, such as a file system over the block driver or
  the network stack over the network driver, are Erlang processes in the
  same domain, by the default configuration, and talk to it as to any
  process; a client in another domain goes over a connection, and its
  data, bulk data included, travels in frames on that connection.
* **Resets.** Every driver resets its device as it starts, the way its
  device's specification says (a virtio device by writing zero to its
  status register and reading it back as zero; a PCIe function by turning
  its bus mastering and memory space off and, where it offers one, a
  function-level reset through the PCIe enumerator; an SD host
  controller by its software reset), and the NIF installs the device's
  queues only after that reset; a virtio device's reset is the NIF's
  own, the first step of `negotiate/2`, and the NIF posts nothing to a
  device before it, so a driver that starts on a device another driver left
  running cannot hand it an address before the reset has retired every
  address the device may hold. A driver process that crashes is restarted
  by its supervisor and resets the device again. Its pools and queues stay
  in the NIF's record of the device meanwhile, and the NIF releases them
  only at the new driver's `negotiate/2`. A PCIe function's driver, after
  its reset, asks the device service through its facet to have the
  enumerator enable the function's memory space and bus mastering again,
  the same gate as at its first start (PCIe, below). The reset is the
  driver's because the driver alone knows its device; the system domain
  never touches a device's registers.

**Native shims.** The **device shim** is the device NIF's C and nothing
else. Any other native driver code, a ported driver, a vendor's C, a
stopgap sDDF driver or a native driver that gate G9 justifies, is a
**native shim**, a row of the driver table, and runs as a **sub-space
port** of the driver's domain, exactly as a program is a port of its
session ([design-programs.md](design-programs.md#a-program-is-a-port)):
the domain creates the sub-space, installs the device's capabilities into
it, which it holds, and a channel to its owner process, which speaks to it
as to a port. It holds nothing but the device and its channel, so for a
confined device its bugs cannot touch the Erlang heap; for an unconfined
device the shim, like the device and the domain that holds it, is in the
trusted base, since the device's DMA reaches all memory. A shim is
single-threaded C under `liberx` and needs no runtime of its own.

**PCIe.** The host bridge is a device like any other, and its driver, the
**PCIe enumerator**, is an Erlang process in the PCIe domain, which holds
the bridge's configuration window (ECAM) as its register window and
nothing else, so the enumerator alone reads and writes configuration
space. It walks the bus and parses configuration space in Erlang, with
binary matching in a supervised process and a fuzz target over
configuration snapshots, since every parser of untrusted input has one,
and reports each function, with its BARs, capabilities and requester id,
to the device service, which adds it to the catalogue. To give a function
to the domain the manifest names for it, the library plans the give with
`erx_dom_plan_device_give`, whose plan carves the function's BARs as register
windows after checking that each lies inside the bridge's windows from
the device tree and overlaps no other device, creates its MSIs as IRQ
objects on the MSI frame, whose doorbell address and data the result
names, and creates its DMA window on the stream that the device tree's
`iommu-map` gives its requester id, when the function lies on one of the
machine's fixed buses
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles));
a function elsewhere is unconfined, and its domain is in the trusted base.
The PCIe domain is in the trusted base whole on every platform:
configuration space turns on any function's bus mastering, which for an
unconfined function reaches all memory. It holds nothing but the
configuration window, so no other driver shares that trust and the
devices domain stays outside it (property 3). The device service then
asks the enumerator to program the function's MSIs and to enable its
memory space and bus mastering, and asks it again, for bus mastering and
memory space alone, when the function's driver reports a reset (Resets,
above). A confined function cannot reach memory before its binding: the
kernel sets the IOMMU to abort DMA from every stream not bound to a DMA
window ([design-kernel.md](design-kernel.md#dma-and-the-iommu)). The
enumerator restarts like any driver process; a restart re-reads
configuration space and changes no running function. The kernel keeps the
register pages of the devices of `hw/kernel_devices.txt` and no page of
the console's UART, which it writes by polling, at the address its
platform build fixes, at boot and at a panic or an end.

**Units.** Devices that cannot be given apart form one **unit**: those
whose register ranges share a page, since a page has at most one MMIO
object, and those behind one PCIe function, as the Raspberry Pi 5's I/O
controller's are ([design-platforms.md](design-platforms.md#pcie-bridges)).
The manifest gives devices by unit, and the check proves each unit given
whole to one domain (property 1). At boot the device service computes the
units from the catalogue's register ranges and the kernel's listing, so
no list of units is trusted unchecked, and gives a unit that the machine's
listing splits across the manifest's domains to no domain, with a
diagnostic; a manifest whose own units split a page never gets that far,
since the domain library's boot view, which the manifest check runs too,
refuses it whole. A unit goes to one
domain, whose drivers reset its devices together. The domain library
holds the placement as well: a give, `erx_dom_plan_device_give`, gives a
device only to a domain of the configured row the manifest places its unit on, never to
a requested or session domain or to another row's.

**Partition windows.** The block driver serves each partition of its
medium as a window ([design-storage.md](design-storage.md#data-model)).
Where each partition lies comes only from the medium layout of the ABI
file. The device service gives the slots, the boot-selection record and
the reset count to the slot writer alone, derived from that layout, and
the manifest assigns each data partition by its role in the layout, never
by sectors, to its storage domain, and each FAT partition likewise to a
FAT server's domain of its own. A domain whose release lives in an EROFS
image gets a read-only window on that image's sectors alone, from the
extents the boot image records, which must lie inside the slot that the
boot value names; when the boot value is `unknown`, it gets none. A window
is a grant of the block driver's domain, which the device service
introduces to the window's holder over a connection once the holder runs;
it sends the holder's capability registry the window with the image's
record from the manifest, its extents, root hash, salt and tree layout,
which the registry hands to the hash-checking reader alone
([design-runtime.md](design-runtime.md#per-byte-primitives)). The slot
writer and the block driver's domain each get, from the domain library, a
read-only view of the machine page, so each reads the boot value itself:
the slot writer never takes it from the update service, and the block
driver refuses every write but the record's and the reset count's on a
trial boot.

**What a device keeps.** At its holder's exit record the fault thread
destroys the holder's own budget, and with it the device's register
windows, IRQ objects and DMA window, which are charged there, and clears
the holder, so the domain's
restarted instance is given the device as soon as the domain service has
created it ([Ending a domain](#ending-a-domain)). A confined device's
memory needs no reset to be safe, because deleting its DMA window aborts
its stream before any page is freed, and the memory goes with the
holder's own budget. An unconfined device can still address whatever it was
given, so its memory is the device's for the boot: the library creates
it from the system domain's budget at the device's first give, keeps it
in the device's record, and gives the same memory to each of the device's
holders in turn, never to anything else and never freed while the machine
runs. No page an unconfined device may address is ever reused, so no
quarantine and no report of a reset are needed before it is given again,
and the next holder, the same configured domain restarted, trusts nothing
it finds there: its driver resets the device before the NIF posts
anything (Resets, above).

**The `/dev` tree.** The device service serves the catalogue as a file
tree through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)), mounted
at `/dev` in the namespace of an administrator principal's sessions. Each
device is a directory named by its catalogue index and compatible string,
encoded as `/proc` encodes the names it shows
([design-live.md](design-live.md#the-proc-tree)), such as
`/dev/12-virtio,mmio`, holding `status`, read only: its path, registers,
interrupt lines, unit, confinement, holder domain and driver process, one
`name TAB value` line each in the `/proc` format. The tree is read-only.
The device service's control facet serves a second tree of the same
shape, mounted at `/dev` instead for the sessions that hold that facet,
whose device directories also hold `ctl`: a write of one line, `stop`,
`start` or `reset` and a newline, at most 16 bytes, acts on that device
through the facet, by asking the holder's driver supervisor to stop,
start or restart the driver process, and any other write fails with
`einval`. Holding the path is holding the facet, as for every file server
([design.md](design.md#decisions)), so no write is checked against who
wrote it, and the tree changes nothing the control facet could not change.
Like every file grant, the tree's grant acts for whoever holds its pid, so
a session that hands it on shares the facet's control with the receiver
([design-files.md](design-files.md#narrowing-for-a-program)); the facet
serves the tree from a process linked to it, so revoking the facet ends
the tree and every fid on it, and no grant of the tree outlives the facet.
Like every facet that serves a file tree, each of the two carries its
tree's name with its pid and rights, as `erx_ns:mount`'s options do, so a
namespace entry names the facet's pid, its rights and the tree, and the
grant answers `enoent` to an attach that names any other tree
([design-files.md](design-files.md#namespaces)).

#### The driver table

Every piece of native driver code other than the device NIF is a row
here, a stopgap or third-party shim included; without the row, no native
driver code runs. A native driver exists only where gate G9's measurement
shows that an Erlang driver misses the device's timing or costs more than
a stated fraction of the device's throughput, and a stopgap or
third-party shim only until the Erlang driver behind the same interface
replaces it. A row names the device, the board, what justifies the shim
(for a native driver the measurement, the Erlang driver's latency or
throughput against the device's requirement, with host, accelerator,
QEMU version, compiler, flags and workload; for a stopgap or third-party
shim its origin and why it runs in place of an Erlang driver), the shape
of the native shim, always a sub-space port of the driver's domain over
`liberx`, and the `TODO.md` item that tracks it. sDDF is the model for the
split and the oracle for behaviour and throughput, never the source: an
sDDF driver may run as a stopgap shim, imported as erXos's code with an
origin file, under a row of its own
([design.md](design.md#dependencies)).

A measurement taken on the stopgap Fiasco admits no native driver. There
an interrupt reaches its driver through a dispatcher thread, and its
acknowledgement, like most kernel calls, is a request to the root
service, which serves the whole machine on one thread
([design-stopgap.md](design-stopgap.md#interrupts-and-readiness)), so an
Erlang driver that misses a device's timing there may be missing the
stopgap's, and a shim admitted on that number would work around the
stopgap rather than the device. Such a measurement is recorded with the
stopgap named, and the row's decision waits for the same measurement on
erXos's kernel.

| Device | Board | Measurement | Shim | Tracked by |
| --- | --- | --- | --- | --- |

The table has no rows.

### System services

The system release starts these services under its supervisors, and the
domain service alone is a significant child: a `temporary`, `significant`
child of a supervisor with `auto_shutdown => any_significant` at the top
of a permanent application. Its end, however it comes, `kill` included,
shuts that supervisor down and ends the application, and so the runtime,
outside an ordered end; the kernel's end path then writes the crash record
and ends the machine (A6), as for any fault of the system domain. So the
domain service is never restarted, and its records of every domain and
connection live in its own heap, with no copy kept for a successor and no
protocol to rebuild them. Its inputs from other domains are hardened as [Ending a domain](#ending-a-domain) says, so no
domain can crash it. Any other service's crash restarts that service and
nothing more, and besides the domain service's end only a fault of the
runtime itself, or a missed watchdog deadline, ends the machine. One
service of the table runs outside the system domain, in a domain the
manifest lists: the vault.

| Service | What it does | Detail |
| --- | --- | --- |
| domain service, `erx_domain_srv` | creates the manifest's domains in its boot order and every other domain; introduces, stops and destroys domains through the domain library; keeps domain pids, names, connections and death records; restarts configured domains; runs the ordered end | [Creating a domain](#creating-a-domain), [Ending a domain](#ending-a-domain) |
| principal service, `erx_principal` | principals, credentials, sessions and quotas | [design-domains.md](design-domains.md#principals-sessions-and-quotas) |
| facets, `erx_facet` | one process per grant of a service to a domain; admission per client | [design-domains.md](design-domains.md#facets) |
| resource policy, `erx_policy` | the group tree, grants, capacity, budgets, lane sizes | [Resource policy](#resource-policy) |
| device service, `erx_devices` | the device catalogue, each device given to the domain the manifest names, `/dev` | [Devices](#devices) |
| watchdog, `erx_watchdog` | pets the kernel's watchdog every period, at priority `max`, once every service it lists has answered a liveness call | [Boot](#boot) |
| console service, `erx_console` | the two console lines: the UART over its driver in the system domain and the host-link port's bytes; each line's menu and login prompt, the connection of sessions' ttys, and the system-shell facet, which it grants to a login at a secure line, holds for that login and ends with it | [Devices](#devices), [design-live.md](design-live.md#the-console) |
| inspector, `erx_inspector` | one schema over kernel, service and runtime reports, the previous boot's crash record included | [design-live.md](design-live.md#inspection) |
| tracer, `erx_tracer` | trace sessions and the kernel's trace | [design-live.md](design-live.md#tracing) |
| host link, `erx_hostlink` | sessions with the development host | [design-live.md](design-live.md#the-host-link) |
| code service, `erx_code` | the code store, code facets, overlays, the install facet | [design-live.md](design-live.md#the-code-store) |
| update service, `erx_update` | system updates, through the slot writer: writing the spare slot, the trial, the commit and the fallback | [design-storage.md](design-storage.md#system-updates) |
| file trees, `erx_procfs` and the device service's tree | `/proc` for each inspect facet; `/dev` for administrators | [design-live.md](design-live.md#the-proc-tree), [Devices](#devices) |
| web login, `erx_web_login` | the web domain's facet with two operations: `login`, which checks a login with the vault as the console does, starts a session and introduces it to the web domain, and `logout`, which ends a session a login through it started; the sessions it started end with it | [design-web.md](design-web.md#logging-in-and-the-line) |
| vault, `erx_vault`, in a domain of its own | principals' keys and secrets; logins; signatures for key facets, by purpose; its sealing backend, and that backend's driver where it has one | [The vault](#the-vault) |

### The network domain

The network domain is a configured `service` domain of the manifest, the
only one that holds a network device (rule 8), and runs erXos's TCP/IP
stack ([design-network-stack.md](design-network-stack.md)). What the
system domain gives it and keeps for it:

* **Its configuration,** in its manifest entry's arguments: for each
  interface, by the device-tree path or PCIe place of its device, the
  mode, `static` with its addresses, routes and name servers or `dhcp`,
  and whether IPv6 autoconfiguration runs, which it does by default.
* **The stable-address key facet,** among its manifest facets: a key
  facet of the vault whose one purpose is RFC 7217's interface
  identifiers, over a machine key the vault keeps
  ([The vault](#the-vault)), so the network domain computes no
  identifier from a secret it holds.
* **The `net` grant of each client.** A domain's specification names a
  `net` facet with its limits (`sockets`, `buffers`, `time_wait`,
  `ports`, `listen`, `addresses` and its `share`), each within its
  principal's policy and defaulting to the values the network stack's
  design gives
  ([design-network-stack.md](design-network-stack.md#the-grant)). The
  facet is a process of the network domain, which the network service
  makes when the domain service introduces the client to it, as a
  storage service makes its grants; the domain service keeps its grant
  record as for any facet. The introduction carries the limits and the
  client's `max_frame`, whose floor for a domain that holds `net` the
  grant checks
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)).
  The `netadmin` facet, which configures interfaces and reads every
  client's statistics, is granted to administrators only.
* **A restart makes the grants anew.** A network domain that ends is
  restarted within its intensity as any configured domain is; every
  socket ended with it, and the grants with it. Once it reports ready,
  the domain service introduces it again to every live domain whose
  specification names a `net` facet, and the network service makes each
  grant afresh, which the client's registry installs under `net` in place
  of the dead one ([Granting a running domain](#granting-a-running-domain)).

### Identifiers

A **system identifier** names something the system keeps: a principal, a
domain, a service, a facet or a release. Every identifier matches
`[a-z0-9][a-z0-9_-]*` and is 1 to 63 bytes long, ASCII by construction.
The rule has no `.`: an identifier becomes the name part of a node name, or
its host part under `-sname`, and stock `net_kernel` refuses a `.` in either.
`erx_ident:new/1` checks a binary against that rule and returns the opaque
`erx_ident:t()`, or `{error, bad_identifier}`; the name field of every
record the system services keep has that type. Each such record is built
only by a constructor in the module that owns it, which passes the name
through `erx_ident:new/1` itself, whatever it was given, and a build check
over the system domain's syntax trees fails on a record expression that
builds one outside its owning module; so no name that came from a
`receive`, an ETS table or a decoded frame reaches a record unchecked.
Names reach the system domain from other domains only through facets, and
each operation of the `erx_facet` behaviour declares which of its
arguments are identifiers, so the behaviour makes them with
`erx_ident:new/1`, and refuses the request on an error, before its
callback sees it. Nothing is normalised: `Web` is refused, not folded to
`web`, so two names are equal exactly when their bytes are. Dialyzer,
which the build runs over the system domain's applications, also reports
code that builds an `erx_ident:t()` outside `erx_ident` wherever it can
see the term's type, and `erx_ident`'s property test checks the rule
against a reference regular expression. Text that is
not an identifier, such as a file name or a log message, is UTF-8 data, and
whatever displays it under its source escapes it
([design-live.md](design-live.md#attributed-text)).

**A domain's name is its node name.** Every domain is an Erlang node named
`Name@Host`: its identifier, then `@`, then the machine's host name, an
identifier the manifest gives, so `system@erxos`, `pcie@erxos`,
`web@erxos` and `alice_1@erxos` on a machine named `erxos`. Both parts are
identifiers, so a node name is ASCII and at most 127 bytes, well within an
atom's bound. The node's creation is the domain's id, which no domain of
the boot reuses, so a domain created later under a freed name is a new
node of that name with a new creation, as a restarted stock node is, and
no pid of the old one names the new one
([design-domains.md](design-domains.md#domain-ids-pids-and-references)).
Since stock distribution keys each peer by its name, at most one living
domain has a name at the machine's host, and a name binds to a principal
for the boot at its first use: the domain service refuses a creation
whose name a living domain holds, or another principal has bound, with
`{error, name_taken}`. The name is free again for its principal at the
domain's end, and never for another principal within the boot. The
manifest's configured domains bind theirs to the system principal at
boot, so no principal can take `storage` or `vault`. Each principal
binds at most its `names` quota of names, 64 by default
([Resource policy](#resource-policy)), past which a creation fails with
`{error, quota}`, because the system domain makes an atom of every peer
node name and its atom table is never freed: the quota bounds the atoms
any principal can make the system domain hold. A sub-space has no node
name, since it is not a node: it speaks only through its creator.

**Sessions and command domains take pooled names.** A principal starts
sessions, and through them command domains, without naming each, so
these take their names from the principal's **name pool**: each is named
`<principal>_<n>`, with `n` the lowest number that no living domain of
the principal holds, so alice's first session is `alice_1@erxos` and a
command domain started beside it `alice_2@erxos`. A number is free again
for the same principal at its domain's end. The pool's names are names
the principal binds, counted against its `names` quota, so the system
domain holds one atom for each number of the pool ever in use, never one
for each session or command domain started, and a pool that the quota
leaves no room in refuses the creation with `{error, quota}`. A creation
that asks for a name of the pool's form, an identifier, `_` and decimal
digits, is refused with `{error, name_taken}`, so no principal takes
another's pooled names. The manifest check proves that every principal's
name, with `_` and the digits of its `names` quota, is still an
identifier (property 5). A pooled name is itself an identifier, so it is a
node name that stock distribution accepts and needs no OTP change.

### The vault

The vault, `erx_vault`, holds every principal's private keys and
secrets, so that no key enters a domain that uses it, after Plan 9's
factotum (R. Cox, E. Grosse, R. Pike, D. Presotto, S. Quinlan, "Security
in Plan 9", USENIX Security 2002). A domain that must authenticate holds a
**key facet** for one purpose, granted by its principal's session, and
asks the facet to sign; the facet signs with the key its grant names and
never returns the key. The vault runs in a service domain of its own,
an ERTS domain whose `crypto` uses OpenSSL 3.5, so that library stays out
of the system domain ([design.md](design.md#decisions)); the system
domain starts it at boot and stands in front of it with the key facets,
as for any service ([design-domains.md](design-domains.md#facets)).

* **A partition of its own.** By the user's decision, the vault's files
  live on the **vault's partition**, a partition of the boot medium's
  layout whose window the device service gives only to a storage domain
  that serves the vault alone
  ([design-storage.md](design-storage.md#data-model)): the system domain
  grants that domain's tree to the vault and to no one else. No
  principal's request reaches that storage domain, so a principals'
  storage domain compromised by crafted requests or a crafted data
  partition reaches no key file, and re-creating the data partition
  leaves the vault's files alone. The vault's storage domain runs the
  same release as the data partition's, erXos's F2FS with littlefs as its
  stopgap, and nothing on the partition is ever converted: by the user's
  decision, the installation that brings erXos's F2FS creates the
  partition afresh, as any fresh installation does
  ([design-storage.md](design-storage.md#system-updates)).

* **Keys never become terms.** A private key the vault opens lives only as
  an OpenSSL key object inside a NIF resource of the vault's, and a master
  key, a slot's key or the sealing secret only in a buffer that such a
  resource clears when it is freed, never as an Erlang binary or term, so
  no heap, message or dump of the vault carries one; only a token, which
  its protocol sends whole, becomes a term, for its grantee (below).
* **The vault's domain.** The domain service creates it with
  `ERX_DOM_SECRET` and no crash area, from the vault's release, whose
  files alone the boot image marks with `ERX_ENTRY_SEAL`
  ([design-kernel.md](design-kernel.md#the-boot-image)). The domain
  library maps the sealing page into a domain exactly when its release
  slice is that marked run, and creates such a domain only with
  `ERX_DOM_SECRET` and only while no other living domain holds the sealing
  page, so the right to the sealing secret follows from the image, never
  from a request ([Creating a domain](#creating-a-domain)). As for every
  domain, at its exit record the library destroys its own budget, which
  deletes its space, its mapping of the sealing page with it, and frees
  the memory that held its keys, so once the vault has ended no dump,
  stopped space or capability anyone holds reaches that memory ([Ending a
  domain](#ending-a-domain)). A fault or crash of the vault ends it, and
  the domain service starts it again, as it restarts every domain the
  manifest lists, after which principals' keys come back at their next
  login. The domain service passes the vault the manifest's sealing
  backend at its creation, and where the backend needs a device, as `tpm`
  needs the TPM, the manifest gives that device to the vault's domain and
  to no other (property 7).
* **What a key facet promises.** A key facet acts for its grantee alone,
  as every facet does, so a domain that learns its pid gets nothing from
  it ([design-domains.md](design-domains.md#facets)). It authorizes at the
  level of a protocol role, as a daemon that held the key would: it signs,
  for its grantee while the grant lives, any input of its purpose's shape,
  whichever peer the signature is for. It cannot tie a signature to a
  peer, an account or a session, because the input does not show them: a
  TLS 1.3 transcript hash and an SSH session identifier or exchange hash
  are digests. A grant restricted to destinations, as OpenSSH's
  destination-constrained agent keys are, would need authenticated
  evidence of the session, such as the server's signature over the session
  identifier by an allowed host key, checked by the vault before it signs;
  no grant carries such a restriction. Keeping key bytes out of terms
  keeps them out of messages, heaps and dumps, not out of the vault's
  runtime: its ERTS, its NIFs, OpenSSL and anything that can read its
  memory are inside every key's security boundary.
* **One purpose per key.** A key is created for one purpose, and the
  vault refuses a grant that names it for another, so a host key never
  signs user authentication and a user key never signs an exchange hash.
  A grant names a principal, a key and its purpose: `{ssh_user, User}`,
  `{ssh_host, Name}`, `{tls_client, Name}`, `{tls_server, Name}` or
  `{token, Service}`.
* **Exact inputs.** The facet checks that what it is asked to sign is
  exactly what its purpose's protocol signs, byte for byte, with nothing
  after it, so a facet is not a general signing oracle:
  * an SSH user facet signs only the user-authentication data of RFC 4252,
    section 7: a session identifier whose length is a hash length of the
    key exchange (32, 48 or 64 bytes), `SSH_MSG_USERAUTH_REQUEST`, the
    grant's user, the service `ssh-connection`, the method `publickey`,
    the boolean `TRUE`, the algorithm name of the facet's own key, and
    that key's public blob; for an RSA key the algorithm name is
    `rsa-sha2-256` or `rsa-sha2-512` (RFC 8332, section 3.2) while the
    blob names `ssh-rsa`, and the facet refuses the name `ssh-rsa`,
    whose signatures use SHA-1. RFC 4252 signs no server identity, so a
    signature authenticates the user to any server that trusts the key;
    a grant therefore names no host;
  * a TLS facet signs only TLS 1.3 `CertificateVerify` input (RFC 8446,
    section 4.4.3): 64 bytes of `0x20`, the context string of its side, a
    zero byte, and a transcript hash of 32 or 48 bytes, the lengths of
    SHA-256 and SHA-384, the only hashes TLS 1.3's cipher suites use: the
    transcript hash is the negotiated cipher suite's (RFC 8446, section
    4.4.1), whatever hash the signature scheme uses, and Ed25519 uses
    none; an RSA key signs only with RSASSA-PSS, as TLS 1.3 requires, so
    keys the vault holds serve TLS 1.3 only;
  * an SSH host facet signs only exchange hashes, which have no structure
    to check but their length, 32, 48 or 64 bytes; it signs as its host
    for its grantee while the grant lives, as the daemon's own copy of
    the key would, and never gives the key away.
* **OTP's own hooks.** OTP 29.1.2 already lets both protocols sign
  without the key: an SSH client's key callback returns
  `{ok, {ssh2_pubkey, Blob}}` from `user_key/2` and signs in `sign/3`
  (`lib/ssh/src/ssh_client_key_api.erl:120`, `:185`), and an `ssl` key can
  be `#{algorithm, sign_fun}` (`lib/ssl/src/ssl.erl:1133`). erXos ships a
  key callback module and a `sign_fun` that call the facet, so stock
  clients use the vault unchanged. A daemon's `host_key/2` must return
  the private key (`lib/ssh/src/ssh_server_key_api.erl:61`), so erXos's
  `ssh` adds to the daemon's key API what the client's has: `host_key/2`
  may return `{ok, {ssh2_pubkey, Blob}}`, and an optional `sign/3` signs
  the exchange hash, in `ssh_transport`'s host-key path
  (`lib/ssh/src/ssh_transport.erl:1111`). The addition changes nothing for
  a callback module written for stock OTP, which the oracle's `ssh` suites
  check.
* **Tokens.** A secret that its protocol sends whole, such as a bearer
  token or a password, cannot stay inside the vault: a `token` facet
  returns it to its grantee alone, and the vault logs every release
  with the grantee's domain and the purpose.
* **Layered keys.** Each principal has one **file** on the vault's
  partition. It holds the principal's keys and secrets, sealed once with
  AES-256-GCM under a key derived from the principal's **master key**, 32
  random bytes that the vault makes at enrolment, which never change and
  never leave the vault unwrapped; and its **credential slots**, at most
  one of them a passphrase slot, each of which wraps the master key, with
  AES-256-GCM too, under a key-encrypting key of its own, as each
  protector wraps Android's synthetic password and each keyslot a LUKS2
  volume key. Every seal takes a fresh random 96-bit nonce. A slot's seal
  binds, as associated data, the file's format version, the principal, the
  slot's index and kind, its derivation's parameters and its sealing
  backend, and under `tpm` the name of the TPM storage key it was sealed
  under, so a slot copied into another principal's file, renumbered or
  given weaker parameters does not open. Every slot opens the same master
  key, so a principal's keys are as safe as its weakest slot, and a slot
  of another kind, such as a FIDO2 key's `hmac-secret` or a recovery code,
  adds a way in without touching the keys.
* **Passphrase slots.** A passphrase slot's key-encrypting key is
  HKDF-SHA-256 (RFC 5869) over the passphrase stretched by Argon2id and
  the slot's secret from the machine's sealing backend, with the slot's
  salt and a label naming the principal and the slot. The stretch is
  Argon2id (RFC 9106), through OpenSSL 3.5's `ARGON2ID`, which OpenSSL has
  offered since 3.2, with a random 16-byte salt and a 32-byte output, at
  RFC 9106's second recommended option, for machines with less memory: 64
  MiB, three passes and four lanes, computed on one thread. The slot
  records its parameters, and the vault accepts them only within a fixed
  **ceiling**, checked before it derives anything: at most 64 MiB, at most
  three passes, exactly four lanes, a 16-byte salt and a 32-byte output. A
  slot outside the ceiling is treated as one that does not open: the login
  derives against the dummy instead (Logins, below), and the vault logs
  the file. So no file, however crafted, makes a derivation cost more than
  the ceiling, and the two queues' memory holds. Raising the configured
  parameters within the ceiling breaks no file: when a slot's parameters
  are below them, the vault re-wraps the master key into a fresh slot
  after the principal's next login, through the file's owner (One owner
  per file, below). The parameters are provisional until a derivation,
  measured on QEMU and on the Raspberry Pi 4, fits a login budget of about
  a second; if it does not, RFC 9106's procedure lowers the passes first,
  and the memory only when one pass is too slow
  ([Performance](#performance)). The ceiling is fixed in the vault's
  release: the measurement may lower the configured parameters beneath it,
  never raise them above it.
* **Sealing.** Each slot's key also takes a secret from the machine's
  **sealing backend**, behind a seam of the vault's own, the `erx_seal`
  behaviour, whose callbacks are the whole interface: `start/1` brings the
  backend up from the manifest's settings, or answers `unavailable`;
  `make/2` makes a slot's secret, given the slot's identity and its
  stretched passphrase, and returns the secret, as a handle of the vault's
  NIF, with an opaque blob to keep in the slot; `open/3` gives the secret
  back from the identity, the stretched passphrase and the blob, or
  refuses, or answers `unavailable`; and `stop/0` quiesces the backend at
  an ordered end ([Shutting down](#shutting-down)). The slot records
  which backend made it and the blob, and nothing else in the vault
  depends on which backend runs; each backend is a row of that one
  interface, and a machine runs the row its manifest names. The manifest
  names the machine's backend, and the vault never falls
  back to a weaker one: without the configured backend it serves no login
  (below). A slot made under another backend than the configured one opens
  only at the console's UART: a login from the host link or the network
  that finds no slot of the principal's under the
  configured backend derives against the dummy and does not match, and
  the vault logs that the file waits for the UART, so no login away from
  the UART turns a file made under a weaker backend into one sealed under
  the machine's. At the UART,
  where whoever is present could enrol the principal afresh anyway
  (Enrolment, below), the vault opens such a slot with its passphrase,
  when the backend that made it still answers, and moves the master key
  into a fresh slot under the configured backend, through the file's
  owner. A machine file whose machine slot another backend made is never
  opened: the vault makes the machine keys afresh under the configured
  backend, as an installation does, and logs it. The rows, and the threat
  each answers:
  * **`none`**: no secret. Whoever reads the medium can guess a
    passphrase offline, at one Argon2id derivation for each guess.
  * **`device`**: the slot's secret is HMAC-SHA-256, over the slot's
    identity, under the vault's **sealing secret**. `liberx`'s root-task
    entry derives that secret from the platform's device secret, which a
    board's key yields at boot
    ([design-platforms.md](design-platforms.md#device-secrets)), writes it
    into the sealing page and then closes the device-secret page, and the
    domain library maps the sealing page read-only into the vault's domain
    alone, keeping no mapping of its own ([The root task](#the-root-task)),
    so after boot neither secret is in the system domain's memory. On a
    machine without a device secret there is no sealing page, so `seal_addr`
    is zero and `start/1` answers `unavailable`. A
    medium read away
    from the board then yields no guess without the board's key, and a
    slot forged without it does not open. Code in kernel mode on the board
    can read the key, as can whoever boots other code on a board without
    secure boot, and guessing is then offline again; nothing limits its
    rate.
  * **`tpm`**: the slot's secret is 32 random bytes sealed in a TPM 2.0
    object, which the TPM releases only against the slot's authorization
    value, derived from the stretched passphrase, counting every wrong
    value against its dictionary-attack lockout. The medium alone opens
    no slot, and even a compromised machine, its kernel included, guesses
    only as fast as the lockout allows. An attack on the TPM chip itself
    is beyond it, and a slot without a passphrase, such as the machine
    slot, opens for anyone who can both command the TPM and read the
    medium.

  A secure element or a trusted execution environment fits the same
  behaviour as a row of its own. The vault with the `none` row alone is
  complete: logins, passphrase slots, machine keys and key facets work
  the same under every row, and only what a copy of the medium yields
  differs.
* **The `tpm` row.** A TPM is a device like any other: its driver is an
  Erlang process in the vault's domain, over the device NIF, which drives
  its register interface, which QEMU's `tpm-tis-device` emulates and a
  board's module offers on a serial bus
  ([design-platforms.md](design-platforms.md#device-secrets)); the device
  service gives the TPM, and on a board the controller of the serial bus
  it sits on, to the vault's domain and to no other, as the manifest says
  ([Devices](#devices)). The driver passes one command at a time to the
  TPM and returns its response within a deadline. The vault speaks TPM 2.0
  through a client in the same domain, provisionally erXos's own ([Risks
  and open questions](#risks-and-open-questions)): Erlang frames each
  command and decodes each response, with a bounded and fuzzed decoder,
  and the vault's NIF computes every secret of a session, the salt's key
  agreement and key derivation, the HMACs and the parameters' encryption,
  and holds every secret a command returns, on resources that hand Erlang
  handles, never bytes, as keys are held (above):
  * Where no firmware has started the TPM, the vault starts it. It
    derives a storage key in the owner hierarchy from a fixed template,
    so the key comes out the same at every start and no file keeps it;
    clearing the TPM changes the seed beneath that key, so every slot the
    TPM sealed is lost, never revealed.
  * The storage key is trusted on first use. When it makes the machine's
    file, the vault records the key's **name**, the hash of its public
    area, which the vault computes itself from what the driver returns,
    in the clear header of that file; it binds into each slot the TPM
    seals the name of the key in use, and supplies that name again when
    it opens the slot. At every later start it checks the public area
    the driver returns against the recorded name before it sends any
    command that carries a value or a secret, and answers `unavailable`,
    with a log line, when they differ. So a bus interposer, or a module
    swapped for another, that substitutes a key of its own is caught
    before any value reaches it, unless it can also rewrite the vault's
    partition, and then at the first slot it opens, after that one
    exposure; the first start trusts the key it is given.
  * Every command that carries an authorization value or a secret runs
    in a salted HMAC session bound to that storage key, with its
    parameters encrypted, so the bus between the vault's domain and the
    TPM sees neither a value nor a released secret, and the vault refuses
    a response whose HMAC does not check.
  * A passphrase slot's object counts its failures against the lockout.
    The machine slot's object and the dummy of logins are exempt from it
    (`noDA`), so neither the machine's start nor a stranger's name spends
    the TPM's tries.
  * On a TPM whose lockout authorization is empty, the vault's first start
    sets the lockout's parameters, provisionally 32 tries, one try
    forgiven every 10 minutes and a day's wait after a failed lockout
    authorization, and then a random lockout authorization that it keeps
    nowhere, destroying it once the TPM has it. So no one can reset the
    count of failures or change the parameters, the vault and a
    compromised kernel with the medium in hand included: every guess goes
    through the lockout, and the TPM forgives tries at its own rate alone.
    The row's `stop/0` sends `TPM2_Shutdown` when the machine ends in order
    ([Shutting down](#shutting-down)), since the TPM counts a start after
    an unordered end as a failure.
  * A TPM whose lockout authorization is set, as every TPM the vault has
    provisioned is, keeps its parameters until it is cleared. A fresh
    installation on such a TPM serves logins under them, says so at the
    console's UART, and offers there to clear the TPM: `TPM2_Clear` under
    the platform hierarchy, whose authorization is empty after a start
    that no firmware preceded, after which it provisions the TPM as at a
    first start. Where firmware starts the TPM and keeps the platform
    hierarchy, the owner clears it through the firmware instead. Clearing
    is also the owner's way to other parameters, and it loses every slot
    the TPM sealed.
* **The passphrase slot is the verifier.** The vault checks every
  passphrase: a passphrase is right exactly when it opens the principal's
  passphrase slot, since the cipher authenticates what it seals, so no
  other record of any passphrase exists, verifiers are as secret as the
  keys, and a principal with no keys has a file that seals none.
* **Enrolment.** A principal starts with no file. Its first passphrase is
  set only at the console's UART, by whoever is at the machine: a login
  there for a principal the manifest lists that has no file asks for a new
  passphrase twice, and the vault makes the principal's master key, its
  passphrase slot under the configured parameters and backend, and a file
  with no keys. The host link and the network enrol no
  one, so no one remote can claim a principal that
  has not enrolled, and presence at the machine is the root of trust, as
  far as the boot that put up the UART's prompt can be trusted
  ([design-platforms.md](design-platforms.md#trust-in-the-boot)). The rule
  is provisional, for the user to decide ([Risks and open
  questions](#risks-and-open-questions)). The vault cannot tell a deleted
  file from a principal that never enrolled, so whoever can both write the
  vault's partition and reach the console's UART can delete a principal's
  file and enrol that principal afresh, under every backend: the
  principal's keys are lost with the file, but its name and authority are
  taken ([Security](#security)). A fresh installation, the one that brings
  erXos's F2FS included, starts every principal with no file, so its
  principals enrol at the UART at its first boot, where whoever
  installed it is.
* **Changing a passphrase** re-wraps one slot: the vault opens the master
  key with the old passphrase and wraps it into a fresh slot under the new
  one, with a new salt and the configured parameters and backend, and
  publishes the file through its owner (below). The keys are never sealed
  again, and a session left open cannot change its principal's passphrase.
  A principal that has forgotten its passphrase has lost its keys unless
  another of its slots opens: an administrator can only have the principal
  service remove its file, after which the principal enrols again at the
  console's UART.
* **One owner per file.** Each principal's file, and the machine's, has
  one owner process in the vault, through which every change to it passes:
  an enrolment, a passphrase change, a re-wrap, the UART's move to the
  configured backend, and a key's addition or removal. The file's clear
  header carries its **generation**, which each publication raises by one.
  A change is computed from the file as published at one generation, and
  the owner publishes it only while the file still has that generation;
  otherwise it computes the change again from the newer file or, for a
  re-wrap, drops it. So a re-wrap that a login began under a passphrase
  that a change has since replaced never restores it. Publishing writes
  the new file whole, syncs it, renames it over the old, and has the
  vault's storage service take a checkpoint
  ([design-storage.md](design-storage.md#interfaces)); a change succeeds,
  and the vault answers it, only once that checkpoint has answered, so a
  change the vault has confirmed survives a power cut, and the file it
  replaced, an old passphrase's slot with it, does not come back. A
  failure before the checkpoint answers leaves the change unconfirmed: the
  vault answers `unavailable`, and the next start reads whichever file the
  medium kept, each of them complete.
* **Logins.** The principal service passes the vault every name it is
  given, the passphrase and the terminal it came from: the console's
  UART, the host link or a network connection. The
  vault answers matched, did not match, `limited` or `unavailable`, and
  nothing else:
  * **Limits by name and by terminal.** The vault counts failures by
    the name given, whether or not it is a principal's, in two classes
    of terminal, and by terminal. It answers `limited`, without a
    derivation, to a name that has had 5 failures in the last 60 seconds
    from local terminals (the UART and the host link) or 5 from network
    connections, and to a terminal that has had
    5. Each class has its own counter for a name, so a network peer
    cannot lock a name out at the UART. A counter goes 60 seconds after its last
    failure, and every failure costs a derivation, so no more counters
    live than derivations fit in a minute.
  * **Two queues.** It runs one derivation at a time for local terminals
    and one for network connections, each
    on one thread, so a flood of logins from the network
    never delays a login at the UART or the host link, and logins cost it
    at most two derivations' memory, 128 MiB, and two CPUs.
  * **No answer tells a principal from a stranger.** A name that is no
    principal's, and away from the UART a principal that has not
    enrolled, gets the work and the answer of a wrong passphrase: the
    vault runs the derivation against a dummy file it made at boot, whose
    one slot, under the configured parameters and backend, is for a random
    passphrase it then forgot, so it does not open. Every passphrase login
    derives exactly once, a file holding one passphrase slot, and its
    answer leaves the vault no earlier than the **login envelope** after
    its derivation began: the time a derivation at the ceiling takes,
    which the vault measures at its start, plus a quarter; a derivation
    that runs past it is answered at its end and counted. So a principal
    whose slot has older and cheaper parameters, one whose file is
    refused, and a stranger answer after the same time, and a re-wrap's
    second derivation runs after the answer, as a job of its own in the
    same queue. Counted by name as every other, such a name is limited as
    a principal is, so neither the answer, nor its time, nor the limit
    tells whether a principal exists.
  * **The TPM's tries.** Under `tpm`, each failure for a principal also
    counts against the TPM's lockout, which covers all its objects at
    once. So that no remote party can lock the UART
    out, the vault counts network failures for every
    name alike, forgiving one as often as the TPM does, and answers
    `limited` to network logins once that count, or the TPM's
    own, would leave fewer than 8 of the TPM's tries (provisional) for
    local terminals and unordered ends; since strangers'
    names count alike, the limit tells nothing about who is a principal.
  * While a session of that principal lives, the vault keeps its master
    key and the opened keys, and destroys them when the last one ends.
* **Machine keys**, such as an SSH host key and the secret behind the
  network domain's stable IPv6 addresses
  ([The network domain](#the-network-domain)), have no passphrase anyone
  types at boot. They live in the machine's file, under a master key of
  its own whose one slot, the **machine slot**, takes its key from the
  sealing backend alone. Under `device` or `tpm`, a medium read away from
  the machine opens none of them; under `none`, the machine slot protects
  nothing, and machine keys are as readable as the medium. A fresh
  installation makes them afresh, so a machine's SSH host key changes
  once at each installation and persists across updates and reboots.
* **Without its partition or its backend** the vault serves no login:
  when its partition does not mount, or the configured backend does not
  answer, it answers every login and every enrolment `unavailable`, and
  the console says why, rather than take principals for unenrolled,
  which would let whoever is at the UART claim any of them. Sessions
  already open keep their keys.
* **On a trial boot** every file system mounts read-only
  ([design-storage.md](design-storage.md#system-updates)), the vault's
  partition included: logins work, and a login whose slot is due for a
  re-wrap answers as any other and leaves the slot as it is, for a login
  on a normal boot; an enrolment, a passphrase change or the UART's
  move to the configured backend answers `unavailable` until the next
  normal boot, the console saying why. A trial begins with an ordered end
  of the machine, whose checkpoint freezes the vault's partition after
  every change the vault confirmed ([Shutting down](#shutting-down)), so
  the trial reads every one of them.


## Interfaces

The domain library's entry points are in [The domain
library](#the-domain-library); the kernel calls it makes are the kernel's
([design-kernel.md](design-kernel.md#kernel-calls)); the Erlang interfaces
of the services are in the documents the table above names.

The system domain's configuration is the manifest and nothing else
([The manifest](#the-manifest)): the domains it lists, the devices'
holders, the principals, the shares of `system` and `users`, the system
domain's own limits, the sealing backend, the watchdog's liveness list,
the rescue configuration, the host name, the console and the host-link
port. It is
read at boot and changed by a new build, never at run time. Its limits:

| Field | Meaning | Default manifests |
| --- | --- | --- |
| `max_domains` | records in the domain library's domain table: the most domains alive at once, for which the system domain sizes its own budget and lanes | 1,024 |
| `max_connections` | rows of the domain library's connection table | 4,096 |
| `system_lane` | data area of the lane the system domain reads from each domain | 16 KiB |
| `system_queue` | the system domain's outbound queue to a domain whose lane is full, and the queue quota of each system process whose facet's grant names none: the bytes of undecoded frames from other domains queued on it past which the funnel leaves the next frame for it in the lane ([design-domains.md](design-domains.md#flow-control)) | 16 KiB |
| `peer_held` | what the system domain holds for one domain's processes: links, monitors and queued signals | 64 KiB |
| `system_reserve` | normalized configuration headroom left unassigned to service children, in thousandths of `system`'s rate; not CPU supply within a deadline ([The manifest](#the-manifest), property 13) | 250 |

The system domain reads no boot argument: the kernel alone reads the
command line, and reports an unknown `erx.` key itself, in the kernel log
through that log's escaper
([design-kernel.md](design-kernel.md#configuration)). Two keys the kernel owns shape
this document: `erx.panic=halt|reset|off`, how the machine ends when the
system domain faults, halts outside an ordered end or misses the watchdog
(`halt` in development builds, so the console keeps the report, which a
board's hardware watchdog turns into a reset within its timeout, `reset`
in release builds, and `reset` whatever it says while a machine lease is
held), and `erx.watchdog=P,D,B`, the watchdog's period `P`, its deadline
`D` after a pet and its boot deadline `B` from the root task's start, in
seconds (1, 5 and 60), off in deterministic mode
([design-kernel.md](design-kernel.md#configuration),
[design-kernel.md](design-kernel.md#the-watchdog)).

## Compatibility and migration

Nothing here owes compatibility to an earlier build. The manifest, the
boot information page, the lanes' ring header and reader page, the crash
record and the creation specification carry versions and are fixed
layouts in `abi/erx_abi.txt`;
the kernel, `liberx` and the runtimes are built from one tree, so a
mismatch is a build error, not a runtime negotiation, and a version field
serves only to make a mismatch fail loudly. The one state that outlives a
boot is the vault's files ([The vault](#the-vault)), and the crash record
where a platform keeps one across a warm reset. Each vault file carries
its format's version, and a file of any other version is refused with a
diagnostic, its principal answered `unavailable`, and never read under
another layout; a crash record of another build is reported as unreadable
and dropped. No build converts either or reads an earlier format: an
installation that changes the vault's format re-creates the vault's
partition, as a fresh installation does.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A malformed creation specification | the planning entries | nothing | none needed | the status code in the domain service; a counter |
| A creation step fails | the step's status | nothing: the applied steps undone by destroying the domain's two budgets (A4) | the domain library | `erx_domain:create/1` returns the mapped error |
| A domain's runtime never reports ready | the spec's boot timeout | the built domain | the domain service stops it, and it ends as any domain does | `{error, timeout}`; a log line |
| A domain ends | the fault gate | nothing of its own budget, which the fault thread destroyed at once, its devices' objects with it; each connection's child budget of its outer budget until both parties have let go of that connection; its crash area until the domain service reads it at the retire; its outer budget, as its remains, until no connection names it | the library, the domain service | `{domain_down, D, Info}` in linked processes; `noconnection` across every connection of the domain; the death record in the inspector |
| A peer never answers `connection_down` | the domain service's record, which shows the connection closing | that connection's child budget, its sides and bells, and with it the dead domain's outer budget as its remains, whose other children go as their parties let go; within the survivor's own `connections` quota; the dead domain itself is retired at its end, and a configured one restarts | the survivor, when it unmaps or ends; then the domain service asks `erx_dom_disconnect`, which destroys the remains with the last connection | the inspector shows the connection closing, with the party that holds it |
| A domain sends the domain service a malformed message, or one about a connection it is not a party to | the generated admission and the connection's state | nothing | none needed: the message is dropped | a counter on the sending domain |
| The device service stops answering | the watchdog process's liveness call | the devices, each with its holder ([Devices](#devices)) | its supervisor restarts it, and the pets resume at its first answer; a service that never answers again ends the machine at the watchdog's deadline | a log line; at worst the crash record naming the watchdog |
| The domain service stops answering, or ends | the watchdog process's liveness call, which kills it; its supervisor, at its end | the machine | none: its end ends the system domain, and the kernel writes the crash record and ends the machine by `erx.panic` | the report on the console; the crash record at the next boot |
| The machine ends unordered more than three times in a row | the reset count, in its own sector beside the boot-selection record | the machine, booted in its rescue configuration | the operator, at the console | the console's login, saying the machine booted for rescue and why |
| The system domain faults, halts outside an ordered end, or misses the watchdog's deadline | the kernel | the machine | none: the kernel writes the crash record and ends the machine by `erx.panic` | the report on the console, brief in a release build; the previous boot's crash record in the inspector at the next boot, to the system shell, where the platform keeps one |
| The system release fails to boot | the root task's end | the machine | none | the report on the console; the machine ends by `erx.panic` |
| A configured domain fails to start, or ends repeatedly | the domain service's restart intensity | its objects until destroyed | the domain service restarts it within its intensity; beyond it, a `required` domain ends the machine as a fault would, and any other stays down | a log line; the inspector shows the domain down or the machine's end |
| A trial fails: its lease passes, or the system domain ends | the kernel's lease; the kernel | the machine | none | the machine resets and boots the committed slot; the update service records the failed trial |
| The coordinator or a service fails, or preparation misses its deadline, during an ordered end | the ending record's deadline, checked by the fault thread; the coordinator's outcomes | completed checkpoints and incomplete preparation | a normal reset, never a restart or a thaw | incomplete durability and the failed phase, where logging remains available |
| A driver process crashes, or a device misbehaves | the driver's supervisor; the driver's own checks of what the device wrote | the device's state, unknown | the supervisor restarts the driver, which resets the device | a log line; a client's request fails or is retried |
| A register access aborts on the bus, inside the device NIF | the fault gate: the fault ends the domain | the domain's stopped space until its destroy | the domain service restarts the configured domain; its drivers reset their devices | a log line; the domain's clients see `noconnection` and reconnect |
| A device's domain ends | the fault gate | an unconfined device's memory, the device's for the boot, given again to the restarted holder | the library deletes the device's other objects at the exit record; the domain service restarts the configured domain; the new driver resets the device before the NIF posts anything | the domain's clients see `noconnection` and reconnect |
| The vault's partition does not mount, or its sealing backend does not answer | the vault's open of its tree, or the backend's answer | the keys of sessions already open, while the vault runs | the operator, who repairs the medium or the backend; nothing re-creates the partition on its own | every login and enrolment answered `unavailable`, and the console says why ([The vault](#the-vault)) |
| The manifest violates a property | the packer's check | no boot image | the developer | the build fails, naming the property, the record and the field |
| The manifest does not read at boot, or the root budget is smaller than its `root_memory` | the root-task entry | the machine | none | a crash record naming the field or the sizes; the machine ends by `erx.panic` |
| A device's mark, or a unit, does not match the machine | the device service at boot | the device unplaced | the developer, who corrects the manifest | a log line naming the device and its mark; the device absent from its domain and `/dev` showing no holder |
| The manifest's `console` path is not the UART `/chosen/stdout-path` names | the device service at boot | the machine | the developer, who corrects the manifest or the slot's firmware configuration | a kernel log line naming both paths; the system release does not boot and the machine ends by `erx.panic`, with the crash record |

The domain library writes one line to the debug log for every domain it
builds, ends and destroys, every connection it makes and deletes, and every
device it gives and releases, through the kernel log's escaping
([design-kernel.md](design-kernel.md#console-log-and-panic)). The
inspector shows the domain service's records and the library's device and
connection tables as `reported_by => service`
([design-live.md](design-live.md#inspection)).

## Security

**Trust.** The kernel and the system domain's runtime and services are the
trusted base, with the domains that hold unconfined devices and the PCIe
domain, whole, which holds configuration space and nothing else. The
devices domain is outside it, with no exception: the console's and the
host link's UARTs are the system domain's.
The domain library and the device NIF are C17 under the construction rules
that bind the kernel's own C (the chokepoint checks, iterative parsing,
checked arithmetic, ASCII-only generated code); the rest of the system
domain is Erlang in user mode.

**Inputs the domain library validates.**

| Input | Source | Validation |
| --- | --- | --- |
| creation specifications, connection and device requests | the domain service, through NIFs | copied in once; validated whole by a pure plan; every size, index and limit range-checked with checked arithmetic; so a defect in the Erlang services cannot make the library act outside a plan the library itself validated |
| fault and exit records | the kernel | trusted; the label names the domain; an exit record's stopper tells the library's own stops apart; the kernel's own statuses, which no domain can pass to `erx_space_stop`, select `HALT` for `ERX_EXIT_NOTHREAD`, and a record for a domain the library has destroyed is dropped; any other status is the domain's own number and only selects `CRASH` or `HALT` |
| the boot image's index and image manifests | the kernel's validated copy | the kernel validated them at boot ([design-kernel.md](design-kernel.md#the-boot-image)) |
| the manifest | a file of the system release, which the packer wrote after its check | the generated C reader checks every offset, count, index and string before the root-task entry uses any field, and a refusal ends the boot ([The manifest](#the-manifest)); it has a fuzz target |

**Least authority among domains.** No domain but the system domain holds
`CAPS` on another domain's space, `CARVE` on the root resource, `ALLOC`
on the root budget or `CODE` on any budget. A domain's devices are the
ones its manifest record names, carved so that its register windows, lines
and stream are its own. A session holds `SPACES` and the objects it
created, and nothing of any other domain's. The system domain itself holds
the root authority: that is the one place where authority is not least,
and the reason its runtime, its services and its C are held to the oracle,
the sanitizers and the construction rules.

**What a domain can do to the system services.** Every message a domain
sends a system service passes the generated admission with the lane's
origin stamped by the funnel; the domain service acts only on the
sender's own side of a connection and drops and counts anything else
([Ending a domain](#ending-a-domain)), so no domain can end the domain
service, whose end alone among the services ends the machine ([System
services](#system-services)); and what a domain can
make the system domain hold is a sum reserved at its admission ([Resource
policy](#resource-policy)). So a domain can make a system service work,
within its grant's share, but cannot make it fail or exhaust the system
domain.

**Residual risks accepted.**

* A defect in the system domain acts with the root authority: it can stop
  domains, change grants, grant facets, and, through the domain library,
  give any capability to anyone. Its C is small, its plans are pure
  functions tested exhaustively on the host and fuzzed, its code comes
  only from its release and the install facet
  ([design-live.md](design-live.md#code-from-the-host)), and its Erlang is
  checked against the oracle; and a fault in it ends the machine rather
  than running on with corrupted state.
* A domain can fake the kind of its own end, crash or halt; it gains
  nothing, since it could equally crash or halt for real.
* The PCIe enumerator writes every function's configuration space: a
  defect in the PCIe domain can disable or misconfigure any PCIe device,
  and for an unconfined function aim its DMA anywhere, so the PCIe domain
  is in the trusted base. It holds nothing else, so no other driver
  shares that trust. A confined function lies on a
  fixed bus, whose number no configuration write changes, so it presents
  only its own requester id
  ([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)),
  and its DMA aborts at the IOMMU until its stream is bound, whatever the
  enumerator writes; the enumerator's parser is Erlang in a supervised
  process with a fuzz target, and its supervisor restarts it.
* A domain that holds an unconfined device is in the trusted base, with
  every process in it: a defect in its driver, or a device it drives,
  reaches all memory. A release build's manifest gives each such device a
  domain of its own, so the domains that parse hostile input hold none,
  and the manifest check proves it (property 9).
* A capability a domain holds to another's object works only while that
  object's budget lives: the owner's destroy deletes it under every
  holder, and a holder that mapped it faults. Lanes, crash areas and
  unconfined devices' memory are charged to budgets that outlive the
  domain for that reason, and no server maps memory a client owns.
* A domain holding `SPACES` reaches the kernel's space creation,
  address-space tags and calls on other spaces, which otherwise only the
  system domain reaches. Each is charged to the domain's own budget, bounded
  per call and restartable, and acts only on spaces the domain created,
  but more kernel code faces that domain, so the system domain grants
  `SPACES` only to sessions and to the configured domains that need it
  ([Sub-spaces](#sub-spaces)).
* A sub-space trusts its creator wholly: the creator reads and writes its
  memory, stops it and changes what it holds, as a parent process
  debugging its child could. A program trusts its session as a process
  trusts its kernel.
* A key facet is a signing oracle for its purpose's protocol role: its
  grantee can authenticate as its principal, to any SSH server that trusts
  the key or to any TLS peer that accepts it, for as long as the grant
  lives; no grant restricts the peer, since the vault sees only digests of
  the session. The purpose check keeps it from signing anything else, and
  the grant dies with the session that made it.
* The vault's runtime is inside every key's security boundary: a defect in
  its ERTS, its NIFs, its backend's driver or OpenSSL that reads its
  memory reads the keys of every principal with a session open, and under
  `device` the sealing secret.
* A passphrase passes through the system domain at login, from the console
  service or the host link to the principal service and on to the vault,
  so a development build's full crash record, with its registers and the
  system domain's slogan and dump, may hold one typed shortly before a
  crash; development builds run trusted code only. A release build's brief
  record holds no register but the program counter, no stack and no text,
  and the inspector shows either form only to the system shell, never on
  a console line before a login ([The crash record](#the-crash-record)).
* Tokens and passwords leave the vault whole, to their purpose's grantee,
  because their protocols send them; each release is logged.
* Under `none`, machine keys are as readable as the medium, and whoever
  reads the vault's partition, that storage domain or anyone with the
  medium in hand, can guess a principal's passphrase offline, at one
  Argon2id derivation for each guess. Under `device`, so can whoever has
  the board's key: code in kernel mode on the board, or whoever boots
  other code on a board without secure boot. Under `tpm`, every guess goes
  through the TPM, at the rate its lockout allows.
* Anyone who can reach a network login and knows a principal's name can
  keep that principal from logging in over the network, though not at the
  UART or the host link, for as long as it keeps failing; under `tpm`,
  anyone who can reach a network login can keep every principal from
  logging in over the network, by spending the TPM's tries that network
  logins may use; the network cannot keep a principal from logging in at
  the UART or the host link.
* Whoever can write the vault's partition can forge any principal's login
  under `none`: it replaces the principal's file with one sealed under a
  passphrase of its choosing, which the vault accepts, since the file is
  the only check; under `device` or `tpm`, a slot forged away from the
  board does not open, and a file forged under `none` opens only at the
  console's UART, where its forger could enrol the principal afresh anyway
  (Sealing). Under every backend it can put back an older copy of a file,
  which opens with the passphrase it was sealed under, so a changed
  passphrase keeps opening a copy taken before the change. Only the
  storage domain that serves the vault alone writes that partition, so
  either takes the medium in hand ([design.md](design.md#residual-risks)).
* Whoever can write the vault's partition and also reach the console's
  UART can take any principal, under every backend: it deletes the
  principal's file, which the vault cannot tell from a principal that
  never enrolled, and enrols the principal afresh at the UART. The
  principal's keys are lost with the file. Anchoring the set of enrolled
  principals in the TPM would detect the deletion under `tpm`
  ([Risks and open questions](#risks-and-open-questions)).
* The vault's own TPM driver can clear the TPM, which loses every slot
  sealed in it and the keys behind them; it is inside the vault's
  boundary already.
* Under `tpm`, the vault trusts the storage key the TPM returns when it
  makes the machine's file: a bus interposer that substitutes a key of
  its own at that moment, or that can also rewrite the vault's partition,
  sees the authorization values and released secrets of the slots opened
  through it.
* Until erXos's F2FS, littlefs's C code serves the vault's partition, a
  stopgap: a crafted partition can end that storage domain, which leaves
  the vault `unavailable`, and a defect in littlefs can lose a key file;
  neither reveals a key, since every file is sealed under keys the
  storage domain never holds.

## Verification and testing

Every passing case below has a seeded failure beside it: a build check is
run once against a planted violation, a model once against a mutated
transition, a QEMU test once against a test-build hook that breaks the
property, and each must fail, so that a passing suite proves the code
under test ran.

* **Pure functions on the host:** the planning entries and the other
  plans over valid and invalid specifications, with every field at and
  beyond its bounds, and with a seeded plan that names another parent or
  another fault gate, which the A6 and A2 checks must catch;
  `erx_dom_classify` over every record kind, status and stopper, including
  a domain's own stop racing the library's; `erx_dom_record_step` over
  every order of fault records, exit records and stops for one domain;
  the pure end decision over each boot value, requested end and set of
  preparation outcomes, with missing and late replies;
  `erx_policy:capacity/1` with properties (the runs' shares on a CPU never
  sum past one CPU; a group's capacity never exceeds its demand; every run
  lies in its group's cpuset; the same grants give the same runs in any
  order), each property once against a mutated placement step.
* **Creation origin and CPU parent:** a valid configured service whose
  grant exceeds its principal's user CPU share but fits `system` plans
  its group under `system` while charging its two budgets to that
  principal; the same grant from a dynamic request is refused. A forged
  origin field in a public request fails decoding; a mismatched manifest
  row fails planning; a partial-boot plan has its principal CPU parent
  and no connection; a restart preserves the configured origin with a
  new domain id. Seeded apply code that substitutes the principal group
  for a planned service parent fails the plan-conformance test. The
  constructor and caller source checks each have a planted violation.
* **Startup limits:** independently chosen, non-default values for every
  runtime limit survive source normalization, whole-plan validation and
  boot-page projection for configured, requested and system runtimes.
  A missing, out-of-range or above-ceiling value prevents start. A hook
  that opens a peer lane before the complete limit record is installed
  fails the startup-order check; no fallback runtime default makes it pass.
* **Configuration headroom:** `erx_policy`'s grant rule over random service
  grants, periods and cpusets, checking the normalized rate and overlap
  inequalities of property 13, refusing the rest with `{error, quota}`,
  and that it
  agrees with the manifest check's property 13 on every shipped manifest;
  seeded failure: a rule that sums rates without the cpuset term, which
  accepts a grant set that the random cases find leaves the reserve's
  CPUs overassigned. These are configuration tests, not a scheduler
  supply proof. Separately, under QEMU, every service domain spins at its full grant
  while the watchdog process keeps petting and the domain service answers
  within the period; seeded failure: a manifest built around the check
  that gives the services all of `system`, under which the watchdog's
  deadline passes.
* **The manifest check:** for each of its fourteen properties a manifest
  that violates it in one place, which must fail the build with that
  property's diagnostic, beside the shipped manifests, which must pass,
  among them, for property 9, a release build's manifest that gives a
  device marked `hostile` and unconfined to a storage domain that also
  holds data windows, one that lists `web` among the host's facets, one
  that gives the web domain a plain-HTTP listener and one that gives it an
  unconfined device, and for property 13, one whose service grants leave
  the reserve on the whole of `system` but not on the CPUs of the system
  domain's own threads;
  the check's boot order over manifests whose facets form a chain, a tree
  and a cycle, the cycle refused; a manifest packed by hand around the
  check, which the source check over the packer's paths catches. The
  generated C and Erlang readers over every shipped manifest give the
  same records, and over a manifest with each offset, count, index and
  string out of range in turn refuse the whole file.
* **Undo:** a host test injects a failure at each step of a creation, and
  a QEMU test injects one at each step through a test-build hook; every
  object is destroyed when the undo returns, and the principal's budget
  returns to its baseline once the destroyed records' grace period has
  passed and the reaper has run, which the test drives; a domain whose
  init process never reports ready, after which nothing of it remains; a hook that charges one object of the creation to a
  budget other than the domain's two, which the budget check catches; a
  seeded plan that installs another domain's IPC gate into the domain,
  which the library's host test must refuse.
* **The root task and its end, under QEMU with HVF:** boot to
  the login prompt and to the system shell; kill the system domain under
  load, with domains, sessions and programs running, and find the crash
  record on the console, every domain stopped, and the machine ended as
  `erx.panic` says; the same for `erlang:halt/1` from a system process and
  for a stopped watchdog pet, whose crash record names the watchdog; on
  each board, a system domain killed during a trial, which boots the
  committed slot; a configured domain killed repeatedly, restarted within
  its intensity, and beyond it the machine ended when it is `required` and
  left down when it is not; the previous boot's crash record read by the
  inspector where the platform keeps one, in its brief form in a release
  build, with no register but the program counter, no stack and no text,
  in its full form in a development build, and refused to every caller
  but the system shell, a session of a system-shell principal among them,
  and on every console line before a login; a development
  build's manifest with a partial boot of two native programs, which run,
  write to the kernel log through the early console, end, and end the
  machine, the root-task entry petting the watchdog throughout; a manifest
  whose `root_memory` exceeds the machine's root budget, which ends the
  boot with a crash record naming both sizes, and a hook that skips the
  comparison, which the test catches; a JIT object's creation in the
  system domain, refused, and a hook that boots a root image carrying
  `ERX_IMAGE_JIT`, which the manifest check must refuse first; the domain
  service killed while domains run, which ends the machine with the crash
  record on the console and no domain running, and a hook that makes it a
  `permanent` child, under which the supervisor restarts it and the test
  finds the machine still running; a test-build hook that faults the system
  domain at every boot, after which the fifth boot comes up in the rescue
  configuration, with no network domain and no user domain, a login clears
  the count, and the next boot is a normal one.
* **Names:** `node()` in a domain is its `Name@Host` and its creation is
  its domain id, the system domain's 4; a second living domain under a
  name, refused with `{error, name_taken}`, and the name taken again by
  its principal once the first has ended, as a node with a new creation,
  while a stale pid of the first names nothing; a name bound by one
  principal, refused to another for the rest of the boot; a principal
  past its `names` quota, refused with `{error, quota}`, and a hook that
  skips the quota, after which the hostile-domain test finds the system
  domain's atom table past its bound; a principal that starts and ends
  1,000 sessions and command domains one after another, whose names stay
  within `alice_1` and `alice_2` and whose system domain's atom count
  stays flat, and a hook that numbers pooled names from a counter instead
  of the lowest free number, after which the same test finds the atom
  count growing and the quota refusing; a creation that asks for
  `alice_3` by name, refused with `{error, name_taken}`.
* **Connections:** a domain whose peer ends, whose runtime takes what the
  peer published, sees `{domain_down, D, Info}` on everything across the
  connection and answers `connection_down` with `connection_unmapped`,
  after which the connection's objects are gone and both sides' charges
  are back; a peer whose dead partner's own budget is destroyed while the
  peer still writes the side the dead domain read, which runs on until it
  unmaps, and a hook that charges that side to the reader's own budget,
  after which the same test faults the peer; a peer that never answers,
  which keeps that connection's child budget, and with it the dead
  domain's outer budget as its remains, within its own `connections`
  quota, and is shown closing in the inspector, while the dead domain, a
  configured one, restarts at once, the outer budget never destroyed on a
  timer and the principal's budget back at its baseline once the peer
  unmaps,
  while the dead domain's other connections' children are destroyed as
  their parties let go, and a hook that charges every connection's sides
  to the outer budget directly, after which the test finds the other
  connections' pages still charged once their parties have let go; a
  survivor that rings the dead domain's bell after the disconnect and gets
  `ERX_ESTALE`; a domain introduced to two others, whose sides are charged
  to child budgets of their readers' outer budgets, one per connection,
  and sized by their specs; a client that fills its lane to a service and
  blocks itself while another client's requests are served;
  `erx_dom_connect` for a domain that is neither built nor running,
  refused with `ERX_EINVAL`, and beyond `max_connections`, refused with
  `ERX_ELIMIT`.
* **Ending:** 10,000 short domains created and ended one after another,
  each destroyed at its exit record and retired once its crash area is
  read and its system connection gone, after which the principal's and the
  system domain's budgets are back at their baselines; a domain that
  crashes with a dump, whose own budget is destroyed before the domain
  service reads the crash area, and whose dump is still read whole, and
  a hook that charges the crash area to the own budget, after which the
  read fails; a domain that logs a line and then halts at once, whose line
  reaches the console, and a hook that has the console facet link the
  domain's logger proxy without trapping exits, under which the line is
  lost; a vault that faults with keys loaded, after which the
  system domain's `INSPECT` on its space fails at once and no stopped
  space of it remains; a domain with sub-spaces three deep whose destroy
  returns every charge of every sub-space in the one call; a domain's
  attempt to reach its outer budget or a child of it, to which it holds
  no capability.
* **Devices:** an Erlang virtio block driver and an Erlang virtio network
  driver over the device NIF under QEMU, against the stock OTP file and
  socket suites that reach them, and against sDDF's published throughput
  for the same device as the oracle gate G9 compares with; a hostile
  device model that writes malformed descriptors, lengths past a buffer
  and stale addresses, which crashes the driver process, which its
  supervisor restarts, and corrupts no memory, checked under ASan in
  hosted mode; a received buffer whose bytes `complete/2` copies into a
  fresh binary, after which the buffer is back in its pool and a model
  device that rewrites it leaves the binary unchanged
  ([design-runtime.md](design-runtime.md#invariants), R9); interrupt
  delivery as a message under HVF, with the latency `tools/erx
  bench irq` measures for G9; a device given to a second domain while the
  first holds it, refused with `ERX_EBUSY`, and given to the first's
  restarted instance as soon as the first's exit record has been handled;
  an unconfined device whose domain ends, whose restarted holder gets the
  same memory and resets the device before its NIF posts anything, a post
  before `negotiate/2` refused, and that memory never charged to or
  mapped by any other domain; a confined device whose domain ends, whose
  DMA aborts at the IOMMU at once; a device the manifest marks confined on
  a machine whose device tree shows no stream for it, given to no domain
  with a diagnostic; a manifest that splits a unit, whose devices go to no
  domain; a manifest whose `hostlink` path equals its `console` path,
  refused by the check; a manifest whose `console` path is not the UART
  `/chosen/stdout-path` names, which ends the boot with both paths in the
  kernel log, and a hook that skips the comparison, after which the boot
  goes on and the test fails; a function whose bus mastering the
  enumerator enables before its DMA window exists, whose DMA aborts at the
  IOMMU; the enumerator's process killed while drivers run, whose restart
  leaves every function running; a BAR outside the bridge's windows or
  overlapping another device, which `erx_dom_plan_device_give` refuses with
  `ERX_EINVAL`; a native shim in a sub-space port that faults, whose
  driver domain runs on and restarts it; a register access that aborts on
  the bus, which ends the devices domain, which the domain service
  restarts, its drivers resetting their devices; the console driver killed
  in the system domain, restarted by its supervisor with the login prompt
  back; a manifest that gives the console's UART unit to any domain but
  the system domain, refused by the check; a check over the driver
  applications' BEAM files that only the console's driver writes the
  console UART's transmit register, with a seeded violation; the driver
  table's emptiness checked against the tree: a native driver outside a
  sub-space port, or one without a row, fails the build.
* **Shutdown:** `init:stop/0` and `init:reboot/0` in the system domain end
  QEMU with `-no-reboot`. Record normal completion latency separately from
  deadline behaviour: preparation can use 2 s for the vault and 5 s for
  storage; the ending record's absolute 10 s deadline bounds a failed
  coordinator. Kill or hang the coordinator after each preparation
  boundary, and kill the vault or a storage domain while ending is
  latched: no domain is created or restarted, the deadline cannot be
  extended, and the machine resets. A rejected begin leaves every service
  running normally; a freeze that succeeds before a different service
  times out, and a refusal after preparation, both end by a normal reset
  with incomplete durability reported; the vault's `stop/0` called once
  per ordered end under each sealing row, and a hook that skips it under
  `tpm`, after which the next start counts a failure in swtpm.
* **Authority:** a domain's attempts to pass capabilities into another
  domain's space, carve the root resource, allocate from the root budget
  or pet the watchdog fail with `ERX_ERIGHTS`; the kernel refuses
  `erx_cap_pass` into a space the caller did not create, and passes a
  space's capability on with `INSPECT` alone; a sub-space group's grants
  stay within the domain's; the build check that confines the library's
  `erx_cap_pass` to `erx_dom_install`, with the system domain's own table
  as its source, and the check that `erx_dom_connect` makes no gate, each
  with a seeded violation; a client's attempt to delete the connection's
  memory, which fails with `ERX_ERIGHTS`; a session
  that maps an unsealed code object executable, refused, and seals it and
  maps it, which runs.
* **Sub-spaces:** a domain without `SPACES` whose `erx_space_create` fails
  with `ERX_ERIGHTS`; a domain with it that builds sub-spaces three deep,
  each running a thread, and then faults: every sub-space stops with it,
  their faults never reach the system domain, and the destroy of the
  domain's own budget deletes every sub-space with it and returns their
  charges; a sub-space whose creator names a fault gate it does not serve,
  which fails; a sub-space asked for JIT objects by a creator whose own
  space allows none, which fails; a session whose programs are three
  generations deep, whose end stops all of them before its own exit
  record.
* **Admission:** a client that sends a service requests of the largest
  admitted size at the lane's full rate, while a second client's requests
  are answered within the service's budget; a request whose decoded shape
  exceeds its schema, refused by the decoder before any heap is built; a
  commit descriptor that names stale state, refused at the funnel with no
  partial mutation published; a facet process at its `max_heap_size`,
  killed and restarted, after which the client's next request is served
  and the service's other clients never stalled; the inspector's
  per-client CPU statistic against the service's reductions.
* **Vault:** each purpose signs its protocol's exact input and refuses
  everything else, including input one byte off the shape, a trailing
  byte, a session identifier or transcript hash of the wrong length, and
  an algorithm that is not the key's; a TLS facet signs a 48-byte
  transcript hash of a SHA-384 cipher suite under `rsa_pss_rsae_sha256`,
  and a 32-byte one under Ed25519; a grant naming a key for another
  purpose is refused; OTP's `ssh` client and daemon and `ssl` in TLS 1.3
  authenticate through key facets against stock OTP 29.1.2 peers on the
  development host; a wrong passphrase opens no slot and is answered only
  as a mismatch; the vault's Argon2id, through OpenSSL, matches RFC 9106's
  Argon2id test vector; a slot whose associated data names another
  principal, another index, another backend or weaker parameters does not
  open; a file with two passphrase slots is refused by its decoder; a slot
  below the configured parameters is re-wrapped after the principal's next
  login and opens with the same passphrase afterwards; a slot whose
  parameters exceed the ceiling does not open and costs one derivation
  against the dummy; a file wholly forged under `none` on a machine
  configured for `device` or `tpm` does not match from the host link or
  the network and is never
  re-wrapped there, while at the UART only the passphrase it was sealed
  under moves it; a machine file of another
  backend is replaced by fresh machine keys; a re-wrap computed before a
  passphrase change publishes nothing, so the old passphrase never opens
  the file again; a passphrase change answered before a power cut is the
  file the next start reads; a stranger, a principal with a wrong
  passphrase, and principals whose slots have older or configured
  parameters all answer after the same login envelope; six failed logins
  within 60 s from the network get
  `limited` while the UART and the host link still log the principal in,
  and a flood of network logins spread over many principals
  leaves a UART login's time unchanged; a name that is no
  principal's, and a principal that has not enrolled tried from the
  network, get did not match, in the time a wrong passphrase takes, and
  six failures for a name that is no principal's get `limited` exactly as
  a principal's do; a principal without a file enrols at the UART and
  nowhere else, not at the host link or the network; the system domain
  grants the tree of the
  vault's storage domain to the vault alone, a principals' storage domain
  finds no key file, and re-creating the data partition leaves every key
  file and machine key in place; a passphrase change rewrites one slot and
  leaves the sealed keys' bytes as they were, after which the file opens
  only with the new passphrase, and a change without the old passphrase is
  refused; the vault destroys a principal's key objects when its last
  session ends; its domain has no crash area; every token release appears
  in the log; with its partition unmounted, or its backend silent, every
  login and enrolment gets `unavailable`; on a trial boot a login works,
  one due for a re-wrap included, which leaves its slot as it was, an
  enrolment or a passphrase change gets `unavailable`, and every change
  the vault confirmed before the trial is seen in it; a principal whose
  file was deleted enrols afresh at the UART, as one that never
  enrolled; an SSH user facet signs `rsa-sha2-256` and `rsa-sha2-512`
  user-authentication data for an RSA key and refuses `ssh-rsa`; the
  domain library maps the sealing page into the domain of the release
  marked `ERX_ENTRY_SEAL` and into no other, refuses that domain without
  `ERX_DOM_SECRET` or while another holds the sealing page, and after boot
  the system domain's space maps neither the device-secret page nor the
  sealing page, checked by a walk of its mappings. Under QEMU with swtpm
  behind `tpm-tis-device`, the `tpm` backend, with the TPM's driver in the
  vault's domain: wrong passphrases spend the TPM's tries and strangers'
  names spend none; network and window failures stop at the reserve while
  the UART still logs in; a response altered between the TPM and the vault
  fails its HMAC; once the TPM is cleared every slot it sealed fails to
  open; a TPM that returns another storage key than the machine's file
  records gets `unavailable` before any command that carries a value, and
  a slot sealed under one storage key does not open under another; no file
  holds the lockout authorization, so a party that can send the TPM any
  command and read the whole medium cannot reset its count of failures;
  and a fresh installation over a TPM an earlier installation provisioned
  serves logins, offers the clear at the UART, and after it provisions the
  TPM as at a first start. On each board, under `device`: a file copied to
  another board opens no slot, and a board whose key was never provisioned,
  or whose read failed, has no device secret and no sealing page, and its
  vault answers `unavailable`.
* **Identifiers:** `erx_ident`'s property test against a reference
  regular expression, with every byte value at every position and
  lengths 0, 1, 63 and 64; the build check seeded with a record built
  outside its owning module must fail.
* **Hostile domains:** a domain that never reads its lane from the system
  domain, one that floods its lane to it, one that never answers
  `connection_down`, one that rings its bells in a loop, one that sends
  records whose bytes trickle in, and one that holds links and monitors
  with system processes up to `peer_held`; the system domain stays
  responsive, its memory within the sum it reserved for each admitted
  domain, and every other domain is served; `max_domains` such domains at
  once, which the system domain's budget holds; a domain that sends its
  domain pid `connection_lost`, `connection_mapped` and
  `connection_unmapped` naming connections it is not a party to, and
  malformed ones, each dropped and counted, with the domain service still
  running and every other connection up.
* **Fuzz targets**, built for the host: the manifest's generated C and
  Erlang readers, over packed manifests and their mutations, since the
  boot image is untrusted until the boot validator has checked it; the
  domain library's specification and request decoder; the PCIe
  enumerator's configuration parser, over snapshots of configuration space
  and their mutations; the vault's file decoder, its header and slots,
  over files sealed under known passphrases and their mutations; the TPM
  client's response decoder, over the responses to each command the vault
  sends and their mutations; and each key facet's purpose check, over its
  protocol's inputs and their mutations.

## Performance

The domain library is off every hot path: it acts at boot, at domain
creation, introduction and end, and at the ordered end. Domain creation is
dominated by mapping the image and the runtime's boot (budget 300 ms to a
ready init process under HVF,
[design-domains.md](design-domains.md#performance)); the library's share,
a few dozen kernel calls (an estimate), is negligible. A domain's end
costs one record at the fault gate, one budget destroy, one message to the
domain service, one `connection_down` frame and one disconnect, which
destroys the connection's child budgets, per connection of the domain,
and one more destroy at its retire; a destroy is
one kernel call whose work grows with what the budget holds, charged to
the system domain as the caller ([design.md](design.md#decisions)). E-D3
measures the time from a stop to the last death handled. The system domain
runs the interpreter, which is slower than BeamAsm on every path it runs;
its work is bounded control, and `tools/erx bench boot` and the
domain-creation benchmark measure what that costs. Boot to the login
prompt is measured by `tools/erx bench boot` against the budget in
[design.md](design.md#performance).

A driver's interrupt-to-handler latency passes through the runtime's
scheduler, and gate G9 measures it per device class against the device's
own timing, with `tools/erx bench irq` and the ring throughput of the
block and network drivers, under HVF and TCG apart; what it finds decides
batching per class, and a device it cannot serve from Erlang earns a row
in [the driver table](#the-driver-table). One ERTS instance per driver
domain, of about 10 MB of memory (gate G6's budget), is why devices are
grouped by configuration rather than given a domain each.

A login costs the vault one Argon2id derivation, 64 MiB and three passes
over four lanes on one thread, and under `tpm` a few TPM commands, and its
answer waits for the login envelope, a quarter more than a derivation at
the ceiling. Its budget is about a second on the Raspberry Pi 4 and under
HVF, which `tools/erx bench login` measures on each, with TCG's numbers
reported apart; the measurement sets the derivation's parameters ([The
vault](#the-vault)).

## Portability

The domain library, the device NIF and the policy contain nothing
architecture-specific; the library and the NIF are C17 over `liberx`, and
build for the host, where their pure functions and fuzz targets run. Which
devices a board has, which the kernel keeps, which are confined, and
whether the board keeps a crash record across a warm reset are the
platform layer's ([design-platforms.md](design-platforms.md#qemu-virt));
each platform has manifests of its own, for each build kind, which place
its devices by the platform's DMA contract, and a port adds manifests and
nothing in the system domain's code.

## Dependencies

No new dependencies: the domain library and the device NIF use `liberx`
and the C library seam; the system services use OTP's `kernel` and
`stdlib`; the vault uses OpenSSL 3.5's Argon2id, HKDF and AES-256-GCM
through its NIF, and the tests of its `tpm` row use swtpm, a host tool
([design.md](design.md#dependencies)). sDDF is a reference: the model for
the split between a driver, which touches registers and rings and parses
nothing from its clients, and the policy beside it, and the oracle for a
driver's behaviour and throughput; nothing of it is imported unless a row
of [the driver table](#the-driver-table) says so. Which TPM 2.0 client the
vault uses is an open question below.

## Alternatives considered

**A separate native root task that restarts the system runtime.** A small
C17 program would receive the root capabilities, build the system domain
and every other domain on its request, and rebuild the system domain when
it fails, keeping the configured domains alive across that restart. It
buys that configured services ride through a fault of the system runtime:
a storage domain keeps serving while the system domain comes back. It
costs two instances of the system domain overlapping in one budget during
the restart; identity and re-grant rules in every configured registry,
since every facet, session and dynamic grant dies with the old instance
and must be told apart from the new one's; device reconciliation, since
the devices' records must outlive the party that gave them; and a second
trusted program with its own request protocol, request page, ring and
fuzz target, whose every rule is a place to be wrong. What survives the
restart is computation without services, since every file, device, code
and key grant is a live process in the system domain. erXos takes the
reset, as OTP's `heart` does for a node whose runtime has failed, and
keeps the domain library behind one C interface, so a separate root task
remains a change behind that seam if the availability it buys is ever
wanted.

**The kernel restarts the system domain.** The kernel would hold the
policy of what to restart and how. It loses: restart policy, domain
records and the creation plan are user-level mechanism with no reason to
run in kernel mode, and the reconciliation above would move into the
kernel.

**Native drivers in domains of their own.** Each driver would be a C
process in a native domain, scheduled by a fiber runtime of its own, with
a control process in the system domain to restart its domain. It buys the
shortest interrupt-to-handler path and no runtime per driver domain. It
costs C that parses what a device wrote, inside a domain that holds the
device, where a malicious device corrupts memory instead of crashing a
process; a second implementation of the runtime contract to write, test
and keep; and drivers that cannot be inspected, traced or upgraded as
Erlang processes can. erXos writes drivers in Erlang over a device shim
that parses nothing, groups them in domains by configuration, and admits a
native exception only through a measured row of the driver table.

**Reset sequences as data, stepped by the root task.** The configuration
would give each device a reset sequence of masked writes and polls, which
the root task would validate and step through before giving the device to
its next driver. It buys a reset without a driver. It costs a validator
and fuzz target for the sequences, a reset state machine with deadlines,
and a trusted party that touches device registers, which a stuck register
read can hang. erXos has the next driver reset its device, as every driver
must anyway, and keeps an unconfined device's memory the device's for
the boot, so no page it may still address is reused.

**One file sealed under the passphrase.** Each principal's keys would be
sealed directly under a key derived from its passphrase. It loses: a
passphrase change seals every key again, and a second way in, such as a
FIDO2 key or a recovery code, would need a second copy of the keys,
where a master key that every slot wraps changes one slot at a time.

**A sealing call in the kernel.** The kernel would compute HMACs under
the device secret for the holder of a new right, so the secret never left
kernel mode. It loses, provisionally, for the user to confirm: it is a
call on every platform for one service on two boards. Against code in
kernel mode, which can read a board's key anyway, the call and the page
protect alike. What the page gives up is a memory disclosure: a defect in
the vault's runtime that reads its memory yields the sealing secret, and
with it offline guessing away from the board, where under the call such
a defect could use the secret only on the board while the vault runs
([design-platforms.md](design-platforms.md#device-secrets)).

**Keys in the domains that use them.** OTP's default, a key file read by
the application. It loses: a defect in any network-facing domain would
give away its principal's keys, where a key facet gives away only
signatures for one purpose while the grant lives.

**Budgets that outlive the domain until their objects go.** A domain's
budget would stay alive while any object charged to it lived, draining
back to its parent as its charges were freed, and a domain's end would
empty its tables and wait for every holder to let go. It buys one budget
per domain. It costs a draining state in the kernel, a keep-alive rule in
its reclamation, and an end whose memory returns on other parties'
schedules, so a survivor that never lets go keeps a dead domain's whole
budget. erXos ends a domain with one destroy of its own budget, as EROS
destroys a space bank, and charges what others map to child budgets of
the outer budget, one per connection, so a survivor keeps one
connection's child budget and the outer budget it was carved from, never
another connection's lanes.

**One budget per domain, lanes charged to the reader.** It buys one
budget fewer. It fails: a domain writes the side its peer reads, so
destroying the reader's budget would delete that side under the writer's
mapping and fault the writer, and the only remedy within one budget is to
wait for every writer before the destroy. The outer budget is that wait
moved onto the objects that need it.

**Keeping an ended domain's stopped space for a debugger.** The domain
service would keep a stopped domain for a while before its destroy. It
buys post-mortem inspection of a whole space. It costs a second moment at
which the domain's devices, name and memory are held, and a retention
policy to size; the crash area, on the outer budget, keeps the dump,
which is what inspection reads.

**Configuration as a term of the system release, with boot arguments.**
The domain service would read its configuration from a term of its
release and its limits from the boot arguments, and the device service
its placement from the same term. It buys nothing the manifest lacks and
costs a second source, read only after ERTS starts, so the root-task
entry, which needs the `system` group's share before anything else,
would read a third; and no check over the whole would run before the
machine boots. erXos packs one manifest, checked by the build, that every
reader takes through one generated layout.

**Checking the configuration at boot.** The domain service would prove
the manifest's properties as it reads it. It buys nothing over the build
check, which runs on the same file, and costs a machine that finds its
configuration wrong only when it is already booting. The readers still
bound-check every field at boot, since the boot image is untrusted until
validated.

**BeamAsm in the system domain.** The system domain would run the same
runtime image as the domains that need speed. It buys faster control
paths. It costs a JIT, its writable-then-executable views and 85,000
lines of C++ inside the trusted base, for a domain whose work is bounded
control; erXos runs the interpreter there.

**L4Re's `moe` and `ned` as the root task.** They implement L4Re's own
object model and loader, which erXos does not use; the stopgap keeps only
Fiasco's kernel, `bootstrap` and `sigma0`
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| A fault in the system domain's million lines of ERTS and services resets the machine, ending long-running user jobs and drivers mid-transfer | medium | medium | the oracle makes the system domain's runtime as trustworthy as the rest of ERTS; supervisors catch Erlang faults before the runtime does; storage survives a power cut by design; a separate root task stays a change behind the domain library's seam |
| An Erlang driver misses a device's timing, or costs more of its throughput than acceptable | medium | the device is slow, or lost | gate G9 measures each class under HVF and on each board; batching per class; a measured row in the driver table admits a native shim in a sub-space port |
| The default grants starve user domains or a service | medium | medium | E-S1 and E-S8 tune them; the policy is Erlang and changes without a kernel change |
| Grouping slow devices in one devices domain lets a defect in one driver take the others down | low | the devices domain restarts, with every slow device | each driver is a supervised process; a board whose configuration needs it gives a device its own domain, at one ERTS instance each |
| The interpreter makes the system domain's control paths slow enough to show in boot or domain creation | medium | slower boot and creation | the system domain does bounded control only; `tools/erx bench boot` and the domain-creation benchmark measure it against their budgets; the per-byte work it does is C |
| A machine's fabric confines less than its manifest marks, or splits a unit differently | low | the device runs nowhere until the manifest is corrected | the device service checks each mark and unit at boot and places nothing it cannot confirm, with a diagnostic; the platform's DMA contract is the manifest's source |
| A principal binds many names, or names others want | low | other principals cannot use those names for the boot | the `names` quota bounds each principal; the configured domains' names are the system principal's from boot; a name is no authority, since introductions are the system domain's |
| A peer that never answers `connection_down` keeps one connection's child budget of a dead domain's outer budget, and with it the outer budget, as the dead domain's remains, alive | low | that connection's pages and the outer budget's limit carved from the dead domain's principal's, held until the peer unmaps or ends, so a principal at its memory ceiling cannot restart the domain until the peer lets go; nothing else of the domain, whose record, name and place in `domains` go at its retire | every other connection's child goes as its parties let go; the connection counts against the peer's own `connections` quota, so what it keeps is bounded by its own limits; the inspector shows the connection closing, with the party that holds it |
| A deterministic fault early in every boot keeps the machine in rescue | low | the machine serves no user domain until an operator acts | the rescue configuration has the console and a login, so the operator can inspect the crash record and install a fixed release; an end before the slot writer advances the count is not counted |
| A protocol's signing input changes shape, so the vault's purpose check refuses valid requests | low | authentication fails until the check is extended | the checks follow the RFCs' fixed layouts and the vault's tests run against stock OTP peers |
| Argon2id at 64 MiB and three passes misses the login budget on the Raspberry Pi 4 | medium | logins slower than a second | the parameters live in each slot; RFC 9106's procedure lowers the passes, then the memory, and slots follow at their next login |
| A TPM's lockout, once spent, keeps principals out | low | logins through the TPM fail until it forgives a try, one every 10 minutes | the reserve for local terminals; the lockout's parameters; no one can reset the lockout, since its authorization is kept nowhere, so the owner waits for the TPM to forgive tries or clears it, losing every slot it sealed |

Open questions, with recommended answers:

* **Which devices share the devices domain on each board?** The default
  manifests put every slow device there, and every unconfined DMA device
  in a domain of its own, at one ERTS instance each. Recommended: the
  platform layer's DMA contract names which devices are unconfined
  ([design-platforms.md](design-platforms.md#qemu-virt)), each board's
  release build's manifest follows it mechanically, and a board whose
  unconfined devices are many takes the cost in memory rather than merge
  them, since a merged domain is the whole machine.
* **How do domains get their names?** Options: (a) a name binds to the
  principal that first uses it, for the boot, within the principal's
  `names` quota, which the design does; (b) an administrator assigns
  names to principals in the manifest, and a principal creates domains
  only under its own. (a) needs no administration and bounds the atoms
  the system domain makes; (b) keeps a name meaning the same principal
  across boots, at the cost of a manifest change per name. Recommended:
  (a), with the configured domains' names reserved by the manifest.
* **Should the crash record be kept across a warm reset where RAM
  survives one?** On the Raspberry Pi boards RAM is not cleared by a
  reset, but nothing promises its contents. Recommended: keep the record
  in a fixed page the platform layer names, validated by magic and
  checksum, and treat an invalid one as absent; the console and the log
  carry the record on every platform regardless.
* **Which TPM 2.0 client does the vault use?** The `tpm` backend needs a
  few TPM 2.0 commands, to start the TPM, derive the storage key, open
  salted and encrypted sessions, create, load and unseal a sealed object,
  set the lockout and read capabilities, and a decoder for responses that
  come from a device and are untrusted. The options:
  * tpm2-tss, the TCG software stack of the tpm2-software project
    (BSD-2-Clause, mature and maintained), as a NIF over erXos's TPM
    driver: complete, but tens of thousands of lines of C, with its own
    allocation and response parsing, inside the domain that holds every
    key, and a new permanent dependency;
  * a small client of erXos's own in C, as a NIF: little code, but C that
    parses a device's responses inside that domain;
  * a client of erXos's own whose framing and response decoder are Erlang,
    binary matching keeping the decoder memory-safe, and whose session
    cryptography, the ECDH and key derivation of a salted session, its
    HMACs and AES-CFB, runs in the vault's NIF over OpenSSL on resources
    that return handles, so no session key or released secret becomes a
    term; no dependency is added, at the cost of writing and owning the
    sessions' key derivation, checked against swtpm and the TCG's
    specification. Stock `crypto` would not do, since its functions return
    their results as binaries.

  Recommended: the client of erXos's own, Erlang with the vault's NIF,
  which also fits the rule that drivers and their protocols are Erlang.
  The `erx_seal` behaviour hides the choice, so any of them fits behind
  it.
* **Should `tpm` anchor the set of enrolled principals in the TPM?**
  Whoever can write the vault's partition and reach the console's UART
  can delete a principal's file and enrol the principal afresh (Security).
  Options: (a) state it as a residual, which the design does; (b) under
  `tpm`, keep a TPM NV counter that versions the machine's file, which
  lists every enrolled principal and its file's version, so a missing or
  older file, or a machine file older than the counter, reads as
  tampering and that principal, or the machine, gets `unavailable`; this
  also detects rollback under `tpm`, costs one NV index and one counter
  increment per change, and needs a recovery path for an owner whose
  medium was tampered with. Recommended: (b), designed with the vault's
  write order; (a) until the user decides.
* **How is the TPM's storage key authenticated?** Options: (a) not at all,
  the salted sessions protecting against a passive bus only; (b) trusted
  on first use, its name recorded in the machine's file and bound into
  every slot, which the design does provisionally; (c) the endorsement
  key's certificate checked against the manufacturers' roots, and the
  storage key bound to the endorsement key with `TPM2_MakeCredential` and
  `TPM2_ActivateCredential`, which needs the roots shipped and kept
  current and an X.509 path check in the vault. Recommended: (b), since it
  catches a substituted key at every start but the first at the cost of
  one recorded name, where (c) adds a certificate store to the domain that
  holds every key.
* **How are principals enrolled?** Provisional ([The
  vault](#the-vault)): the first passphrase is set at the console's
  UART only, by whoever is at the machine, and a change needs the old
  passphrase. The alternatives are a passphrase the administrator gives
  the packer, which puts a verifier into every copy of the image, and a
  one-time enrolment code the packer prints for each principal, which the
  UART's login asks for. Recommended: the UART, with the enrolment code if
  machines are installed unattended.

## References

* [research-hierarchical-scheduling.md](research-hierarchical-scheduling.md)
  (Identity and lifecycle), [research-kernel-bases.md](research-kernel-bases.md)
  (Zircon, seL4), [research-prior-art.md](research-prior-art.md),
  [research-architecture.md](research-architecture.md)
  (the root task, drivers in Erlang, services on their own grant).
* L4Re: `moe`, `ned` and `sigma0` in `l4re-core` at commit `e2e2d5af`,
  read 2026-10-29.
* Erlang/OTP 29.1.2: `lib/kernel/src/init.erl` (`stop/0`, `reboot/0`),
  read 2026-10-29; `heart(3)`, the heartbeat monitor that restarts a node
  whose runtime stops answering; `lib/ssh/src/ssh_client_key_api.erl`
  (`user_key/2`, line 120; `sign/3`, line 185),
  `lib/ssh/src/ssh_server_key_api.erl` (`host_key/2`, line 61),
  `lib/ssh/src/ssh_transport.erl` (`get_host_key/2`, line 1111),
  `lib/ssl/src/ssl.erl` (the `key()` type with `sign_fun`, line 1133),
  read 2026-10-30.
* The seL4 Device Driver Framework (sDDF), the model for a driver that
  touches registers and rings and parses nothing from its clients, and
  the oracle for driver throughput ([design.md](design.md#dependencies)).
* Genode OS Framework, "Genode Foundations": CPU quota and priority per
  component and memory per session, the shape of resource accounting in
  which no component spends another's CPU.
* R. Cox, E. Grosse, R. Pike, D. Presotto, S. Quinlan, "Security in Plan
  9", 11th USENIX Security Symposium, 2002 (the factotum, which the vault
  follows).
* RFC 4252, "The Secure Shell (SSH) Authentication Protocol", section 7;
  RFC 8446, "The Transport Layer Security (TLS) Protocol Version 1.3",
  section 4.4.3.
* RFC 9106, "Argon2 Memory-Hard Function for Password Hashing and
  Proof-of-Work Applications", 2021, section 4 (the second recommended
  option: Argon2id, t = 3, p = 4, 64 MiB, a 128-bit salt and a 256-bit
  tag) and section 5 (test vectors); RFC 5869, "HMAC-based
  Extract-and-Expand Key Derivation Function (HKDF)".
* OpenSSL 3.5 manual, `EVP_KDF-ARGON2(7)`
  (<https://docs.openssl.org/3.5/man7/EVP_KDF-ARGON2/>): `ARGON2ID`,
  added in OpenSSL 3.2, its lanes, memory cost in 1 KiB blocks and
  threads, read 2026-10-31.
* NIST SP 800-38D, "Recommendation for Block Cipher Modes of Operation:
  Galois/Counter Mode (GCM) and GMAC", 2007 (AES-256-GCM).
* M. Broz, "LUKS2 On-Disk Format Specification", version 1.1.4,
  2025-06-16 (keyslots, each with its own key-derivation parameters);
  Android Open Source Project, `SyntheticPasswordManager.java` in
  `frameworks/base`, `services/core/java/com/android/server/locksettings/`
  (a synthetic password and its protectors), read 2026-10-31.
* TCG, "Trusted Platform Module 2.0 Library", Part 1, dictionary-attack
  protection, as Microsoft's reference implementation implements it
  (`ms-tpm-20-ref`, `TPMCmd/tpm/src/subsystem/DA.c`, read 2026-10-31):
  the counter of failed tries, the recovery time, the lockout
  authorization and the failure a start after an unordered end counts.
* OpenSSH, "SSH agent restriction",
  <https://www.openssh.org/agent-restrict.html> (destination-constrained
  agent keys and the `session-bind@openssh.com` evidence, OpenSSH 8.9),
  read 2026-10-31.
* QEMU, "QEMU TPM Device" (`docs/specs/tpm.rst`) and
  `hw/core/sysbus-fdt.c` (`tpm-tis-device` on the `virt` machine,
  `tcg,tpm-tis-mmio`), master branch, read 2026-10-31.
