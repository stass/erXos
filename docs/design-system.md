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

The decisions that shape the rest, each owned by the section linked:

* **The system domain is the root task**, ERTS on the interpreter in user
  mode, with no JIT object, writable-then-executable view or C++
  ([The root task](#the-root-task), A11). Nothing in the machine has
  authority the system domain did not pass on.
* **One manifest is the configuration**, checked by the build and read
  through generated readers by every party that configures the machine
  ([The manifest](#the-manifest), A10).
* **Authority starts at the system domain.** Only a space's creator
  installs into its table, no introduction carries an IPC gate, and a
  domain holding `SPACES` builds sub-spaces of its own
  ([Authority](#authority), [Sub-spaces](#sub-spaces), A1, A7).
* **Lifetime by construction.** Every domain's space is a child of the
  system domain's, so the system domain's end ends every domain; it is
  restarted as OTP's `heart` restarts a node, by starting the machine
  again ([Boot](#boot), A6, A8).
* **Every domain's end is seen in one place, and is one destroy** of the
  domain's own budget; what others map sits on child budgets of its outer
  budget ([Ending a domain](#ending-a-domain), A2, A5).
* **A domain is built whole or not at all**
  ([Creating a domain](#creating-a-domain), A4).
* **Drivers are Erlang** over a device shim that parses nothing, in the
  domain the manifest names ([Devices](#devices), A9).
* **Services do bounded control on their own grant**: no thread runs on
  another group's time ([Resource policy](#resource-policy)).
* **The system domain is trusted.** Its authority over another domain's
  processes is what that domain exports to it, and over the domain itself
  its creator's. A defect in it cannot corrupt the kernel, but it holds
  the root authority, so it is a defect of the whole machine; the oracle,
  the sanitizers and the construction rules that bind its C keep that
  risk small ([Security](#security)).

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
checked-in text file per configuration, `config/manifest/<name>.txt`,
one for each platform and build kind; the packer, `tools/erx pack`,
parses it, runs the check below over it, and packs the result. The
manifest holds:

* **The machine:** its host name, an identifier that is the host part of
  every domain's node name ([Identifiers](#identifiers)); `root_memory`,
  the size of root budget the configuration assumes; the shares of the
  `system` and `users` groups; the
  system domain's own limits,
  `max_domains`, `max_connections`, `system_lane`, `system_queue`,
  `peer_held` and `system_reserve`, the part of `system` the service
  grants inside it leave to the system domain's own threads; its **boot
  timeout** (`boot_timeout_s`), the seconds a domain's runtime has to
  report ready after its start, which every configured domain, every
  session and every create request that sets none of its own takes: 60
  unless the machine says otherwise, which suits hardware and QEMU, and
  longer on a machine much slower than those, as the website's emulator
  is, so only that machine waits longer for a hung boot; the lane
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
  area; whether it holds `SPACES`, and its sub-space group's grant; on
  Fiasco, its priority band and its thread, object and mapping limits,
  which bound what it can make the root hold for it
  ([design-fiasco.md](design-fiasco.md#memory-and-budgets), FD14), all
  of these from its limits record, as a session's come from its
  template's, its threads running within its grant's CPU set
  ([design-abi.md](design-abi.md#principal-domain-and-limit-records)).
  The band and the three limits are Fiasco's alone and leave the
  manifest with it: erXos's kernel bounds a domain by its budget and
  grant (FD14, FD15), and nothing above the domain library reads them; its
  restart intensity, whether it is `required`, and whether the rescue configuration starts it; its
  arguments and environment; its **devices**,
  given by unit ([Devices](#devices)), each by device-tree path or, for a
  PCIe function, by its place on a bus, with its compatible string, its
  mark as confined or unconfined if it masters DMA, the size of its memory
  if it is unconfined, and its `hostile` mark and its role, which the
  platform's placement table sets
  ([design-platforms.md](design-platforms.md#what-the-manifest-says)), a
  USB host controller's role being `usb`; its
  partition windows, by role in the medium layout, and on a `usb` or a
  `block` device's row a `drive` window, which names no partition and
  whose `drive` field names a drive, `diskN`, numbered across the
  machine, whose medium, whatever it is, the device's domain serves
  whole to the media domain
  ([design-drives.md](design-drives.md#manifest-rows));
  its **facets**, each
  naming a service that the system release or another configured domain
  serves, with the grant's limits; and its **introductions**, each naming
  another configured domain.
* **Each display:** a record named after the `windows` service it
  describes, whose server is the display domain, so the display's name
  is that service's everywhere; its policy, idle policy and reserved
  chord. Who may draw on it, and how much, are the facet rows of its
  service; which session is its own, the start row that names it. The
  entry names no session and no application
  ([design-display.md](design-display.md#a-displays-session)).
* **Each read-only image** a configured domain boots from: its extents,
  root hash, salt and tree layout, which the packer computes as it builds
  the image ([design-storage.md](design-storage.md#data-model)).
* **The start rows** ([design-apps.md](design-apps.md#the-start-table)):
  each names a principal whose session starts at boot with no login,
  whether it is enabled, optionally a display, and its restart
  intensity. They are the start table's defaults, which the machine's
  `start.conf` overrides. An app is a principal of the manifest with a
  session template today; principals added at run time are the
  packaging design's ([design-apps.md](design-apps.md#packaging)).
* **The boot order**, the configured domains in an order in which every
  domain follows every configured domain whose service its facets name,
  and every row holding a `pci` device follows the PCIe domain
  ([design-pcie.md](design-pcie.md#the-catalogue-and-gives)), which the
  check computes, breaking ties by stable name order.
* **In a development build only**, the native programs of a partial boot
  ([Boot](#boot)).

**The packed form** is the layout `erx_manifest_t` of
`abi/manifest.txt`, whose rules
[design-abi.md](design-abi.md#system-manifest-representation) states: a
header, fixed-record arrays and a string table, reached only through
checked indices, spans and string references, never a native pointer.
Two readers are generated from it: a C reader in `liberx`, which the
root-task entry uses before ERTS starts, and the Erlang module
`erx_manifest`, which the system services use and which gives the
records a span names (`erx_manifest:span/3`). The packer writes every
descriptor array the boot reads (configured domains, devices, facets,
boot order, liveness), so no compiled configuration table repeats them;
domain records refer to complete named limit records, so no runtime
default or second table can supply missing configuration; and a unit
owns its devices' one holder field. A generated host report describes
the checked configuration and cannot configure a boot
([design-generation.md](design-generation.md#configuration-and-command-catalogs)).
Dynamic creation still goes through the domain library's whole-plan
validation and Erlang policy.

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
| the device service | each device's holder, unit and confinement mark, each domain's windows by role and drive, an unconfined device's memory size, and the console's and the host link's paths |
| the resource policy | the principals' budgets, shares and quotas; the lane size per class; `system_reserve`, which bounds the service grants it sets |
| the principal service | the principals, and which of them are system-shell principals, which it tells the console with each login it confirms |
| the start service | the `start` rows, the principals with a session template, and the `windows` services each template is granted, by which it checks a row's display ([design-apps.md](design-apps.md#the-start-table)) |
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
   domain, a configured domain or a session template, never the service's
   own server; a
   grantee takes at most one facet of a service name, since its registry
   holds each under that name; and every introduction names configured
   domains.
3. **Exactly one domain holds PCIe configuration space, and that domain
   holds nothing else,** on every platform where erXos drives a PCIe
   bridge in a full boot: the PCIe domain, `pcie`, which runs the PCIe enumerator and
   nothing beside it. QEMU `virt`, the Raspberry Pi 4, whose BCM2711
   bridge is closed and leads to the VL805 USB controller
   ([design-usb.md](design-usb.md#the-bcm2711-bridge)), and the
   Raspberry Pi 5 drive bridges; on a platform that drives none, no
   domain holds configuration space and there is no PCIe domain. A
   `pci` row names an interrupt line only at a place a closed bridge's
   platform record lists, and then the line its place's pin routes
   ([design-pcie.md](design-pcie.md#the-closed-bus)).
4. **Budgets and grants sum within the root's.** The principals' budgets,
   the system domain's baseline and its reservation for `max_domains`
   admitted domains ([Resource policy](#resource-policy)), the unconfined
   devices' memory and the domain library's tables fit within
   `root_memory`; each configured domain's two budgets fit within its
   principal's; the shares of `system` and `users` sum within the root
   group, the configured domains' grants within `system`, each principal's
   share within `users`, and each sub-space grant within its domain's;
   and the principals' quotas of domains sum within `max_domains`, every
   living domain, configured or requested, being one of its principal's.
5. **Every name is a system identifier,** the host name included, and so
   is every pooled name a principal's `names` quota allows
   ([Identifiers](#identifiers)); no two configured domains or principals
   share a name, no configured domain's name has a pooled name's
   form, and no principal but the system principal is named `root`, whose
   pooled names the system principal's sessions take.
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
   record and the reset count; only storage domains hold windows on data
   and vault's partitions, and only the media domain, which holds no
   unit and no other window, holds `drive` windows; a window names a drive
   exactly when its role is `drive`, no drive is named twice or lies on
   two controllers' rows, and the rows on one domain's controllers name
   at most `usb_drives_max` drives ([design-drives.md](design-drives.md#manifest-rows));
   the units of the UARTs that `console` and
   `hostlink` name and of the device each grant of the `line` interface
   names by its `device` parameter, a device of role `uart` or `serial`
   and of no other, are the system domain's and their
   paths all differ, so no two `line` grants name one device and none
   names the console's or the host link's; a `line` grant states `rate`
   and `flow` exactly when its device is a `uart`, and every placed
   `serial` device, a virtio console, is named by a `line` grant, since the
   root writes a `given` record with unconfined DMA memory for every
   `serial` device the system domain holds
   ([design-bluetooth.md](design-bluetooth.md#the-controllers-line)); the
   service of the `line` interface is named `line`, the one name by which
   the line service finds and serves its grants, the facet-names check
   reads its serve call and its grantees mount it at `/line`; the
   console's UART shares an interrupt line with none of the others, since
   the console starts its own line's owner, while the host link's UART and the
   `line` grants' devices may share lines with each other, one line group
   for each line starting its one owner before the services that drive
   them
   ([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain));
   a unit whose registers can put a signal of the `console`'s or the
   `hostlink`'s device on a pin, by the chip's pin table and whichever
   pins the platform record's rows use
   ([design-pinctrl.md](design-pinctrl.md#the-pin-table)), is held by no
   domain or by the system domain, since its holder can take or read
   those lines
   ([design-header-io.md](design-header-io.md#the-pin-controller-and-the-console)); only
   the storage domain that serves the vault holds the vault's partition,
   and only the vault holds a facet of that domain's tree; only the
   network domain holds a network device; and only the system domain
   holds a facet of the driver-control interface, which stops and starts
   another domain's drivers ([The holder's driver-control
   facet](#the-holders-driver-control-facet)); and only a display
   domain, one that serves a display's window service, holds a facet of
   the `input` interface, whose holder reads every key pressed on the
   devices behind it, whatever window has the keyboard
   ([design-display.md](design-display.md#the-display-device)). The
   interface declares no rights, so every such facet is read-only.
9. **A release build's manifest confines what it can:** each unconfined
   device's holder holds that device's unit and nothing else, so the file
   system or network stack that parses what an unconfined `hostile` device
   carries runs in another domain, and no domain holds an unconfined
   device together with a window on a partition that no hash tree checks
   (a data or vault's partition, or a drive) or a `hostile` device of another
   unit; the diagnostic names that hostile input when the violating holder
   has one. A USB domain, the configured domain that holds a `usb`
   device, holds that controller's unit and nothing else and runs no
   file system, whether or not its controller is confined: the media
   domain reaches a drive's medium through its drive grant
   ([design-drives.md](design-drives.md),
   [design-usb.md](design-usb.md#who-holds-a-controller)). The web domain, the configured domain that holds the
   `login` facet and parses browsers' bytes, holds no unconfined
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
   partial boot. It has no clause for the bus masters the loader left
   running: those are the trusted loader's until each driver's reset,
   after which alone a device's buffers and descriptors are installed,
   and the window before that reset is a [Medium] security residual, by
   the rule [design-platforms.md](design-platforms.md#dma) states, so
   development and release builds are admitted alike.
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
    ([Boot information](design-fiasco.md#boot-information)), so a
    placement or a row the boot would refuse fails the build. The
    production build always runs the planner; a check without one plans
    nothing for an empty set of children, and fails closed for a
    nonempty set. Because the builder reads the manifest as untrusted
    input ([The manifest](#the-manifest)), it is the one check of the
    rules across records that it reads, such as one system window and
    its `system_image` row, the `record_volume` window held by the
    system window's holder, no grantee taking two facets of one service
    name, and no session template's environment setting a variable its
    start gives it: the build reaches each by running that same builder
    here, and the source check does not restate it. The source check
    judges what the view does not need to build the boot, such as which
    configured domain holds a window's block device and that the
    `record_volume` window lies on the system window's device. The
    generated reader judges each structural rule of `abi/manifest.txt`
    (enum members, ranges, indexes and table sizes); neither check
    restates one, except where the view checks an index it is about to
    follow.
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
    a session that starts with no one asking takes its restart intensity
    from its start row (property 17), and the boot order, the plans of
    property 12 and every unit, window,
    service and introduction resolve through the domain table, which holds
    no template, so none of them reaches one. A facet alone may name a
    template as its grantee, written `@session.PRINCIPAL`, for a service a
    configured domain serves, which its server grants each session made
    from the template, or for a service the system domain serves, whose
    facet the domain service starts for each such session ([Facets a
    configured domain serves](#facets-a-configured-domain-serves)); the
    grant adds nothing to the boot order. Its limits are judged
    against its principal's ceilings, budget and quota when a session is
    made from it, by the request path every principal's domain takes.
15. **The system domain holds no `net` grant:** no facet of the `net` or
    `netadmin` service names the system domain as its grantee, so the
    trusted base takes no socket's traffic and no answer of the network
    domain's grant ([The network domain](#the-network-domain)). The check
    compares the service row's interface number with the numbers
    `abi/services/net.txt` declares, so a row that spells the interface
    by number is held to it too. A grant made at run time cannot name it
    either: the network service's mint refuses the system domain's id as
    a grantee
    ([design-network-stack.md](design-network-stack.md#the-grant)). Each
    grantee of `net`, a configured domain or a session template, also
    runs with a `max_frame` of at least the protocol's floor,
    `net_max_frame_min`, in its own runtime limits, so a client configured
    below it fails the build rather than at its first socket; the client
    side checks its floors again at run time
    ([design-domains.md](design-domains.md#principals-sessions-and-quotas),
    "Floors from a protocol"). Seeded violations: a development manifest
    that grants the system domain a `net` facet, which the check refuses
    with this property's diagnostic, naming the facet; the same with the
    interface written as its number; a `net` grantee whose runtime limits
    have a `max_frame` below the floor while the system domain's are
    above it; and a mint request naming the system domain, which the mint
    refuses and counts. A `net` grant's ports are this property's too: every
    port its `listen` lists is one of its `ports`, those it lists or by
    default 1,024 to 65,535, and a privileged port, below 1,024, which a
    grant binds only when its row lists it, is listed by one grant of its
    network domain alone, to a configured domain, never to a session
    template, whose grant every session made from it holds. The stack binds a
    port for the first grant to claim it, so without this any other grant of
    the same network domain could take a service's privileged port first.
    Seeded violation: two grants of one network domain listing the same
    port below 1,024.
16. **Every receiver of `files`, of `inspect` and of `code` takes its frames:** for each facet of an
    interface `abi/services` declares `served_as tree` (`files`, `windows`
    and `line`), compared by number, the
    grantee (the system domain under the machine's system runtime limits, a
    configured domain or a session template) and the service's server
    each run with a `max_frame` of at least `files_max_frame_min`, 128 KiB:
    a read reply or a write request of the file client's 64 KiB transfer
    unit arrives in one frame, and the funnel drops a longer one, which
    would leave the 9P caller waiting; the facet's `max_request` admits a
    request that long. The storage domain's `data` is one such facet
    ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
    The `inspect` interface (`abi/services/inspect.txt`) holds its
    receivers to its own floor the same way: every grantee of an
    `inspect` facet and the system domain, its server, which also takes
    the runtime agents' answers of the same bound, run with a `max_frame`
    of at least `inspect_max_frame_min`, a `max_message_heap` of at least
    `inspect_message_heap_min` and a `funnel_depth` of at least
    `inspect_funnel_depth_min`, so no funnel drops a valid answer
    ([design-live.md](design-live.md#the-inspect-service)).
    The `code` protocol holds its receivers to its floors whatever they
    are granted, since every domain but the system domain receives
    loads: every configured domain and session template runs with at
    least the load floors `code_load_max_frame_min`,
    `code_load_message_heap_min` and `code_load_funnel_depth_min`, and
    the system domain, which receives every code server's answers, with
    at least the answer floors `code_answer_*_min`; and every facet of
    the `code` interface has a `max_request` of at least
    `code_request_max`, the longest request `load` sends, and its
    grantee and server, which receive its requests and replies, run with
    at least the facet floors `code_facet_*_min`. The ABI generator
    computes the nine floors and the bound from
    `abi/services/code.txt` (`tools/lib/erx/abi_code_bounds.rb`)
    ([design-live.md](design-live.md#the-code-server)).
    Seeded violations: a check that reads only the grantee's limits, which
    admits a server below the floor; a session template that holds
    `inspect` with a `max_frame` below its floor; a check of
    `max_frame` alone, which admits a template whose `max_message_heap`
    is below `inspect_message_heap_min`; a `code` check of configured
    domains alone, which admits a session template below a load floor;
    one of `max_frame` alone, which admits a template whose
    `max_message_heap` is below `code_load_message_heap_min`; and one
    that holds the system domain to the load floors, which admits its
    `funnel_depth` below `code_answer_funnel_depth_min`; and a `code` check
    without the facet floors, which admits a code facet whose grantee
    runs below `code_facet_max_frame_min`.
17. **Start rows are well formed:** every `start` row names a principal
    with a session template, at most one row for each principal; every
    such principal's name begins with a letter, and no two rows share a
    variable name, the principal's name with each `-` replaced by `_`,
    so `/etc/start.conf` names each row by one `sh` variable prefix
    (`my-app` by `my_app_`); at most
    one enabled row names each display; a display a row names is a
    `windows` service that a facet row grants the principal's template;
    and the sessions the boot starts can all be built beside the
    configured domains, which the planner of property 12 decides by
    planning each in the boot view, in the boot's order: first root's
    console session, from the system principal's session template, which
    a development build's console logs in at boot (step 4 of
    [the boot](#boot)) and from which root logs in at any build's
    console, so it is counted in every build, and then the session of
    each enabled row
    ([design-apps.md](design-apps.md#the-start-table)). So a manifest
    whose start rows fill a principal's quota or memory with no room left
    for the console's login fails the build, not the boot. A system
    principal with no session template gives the console no session, and
    none is planned for it. Every facet row of the resolved manifest,
    the rows the build derives included, that grants the data
    partition's `etc` tree, which holds `/etc/start.conf`, with rights
    other than read-only is granted to one of two grantees: the system
    domain, whose start service writes the file for `service enable` and
    `disable`, or a session template that a facet row also grants the
    start service's tree, `start`, read-write; so only the start service and who may
    command the start table may rewrite its settings
    ([design-apps.md](design-apps.md#the-start-table)). No session
    template's environment sets `ERX_START_FLAGS`, and every session
    template's arguments and environment leave room in its boot page's
    strings for that variable at its longest, `start_flags_max` bytes,
    beside the boot view's other reserve, since the library adds it to
    every session a start row starts
    ([design-apps.md](design-apps.md#start-flags),
    [Boot information](design-fiasco.md#boot-information)). Seeded
    violations: a check that plans the enabled rows alone, which admits
    a system principal whose memory holds its start row but not root's
    console session beside it; a check that compares principals' names
    unmapped, which admits `start` rows for `my-app` and `my_app`; a
    `start` row for a principal named `9lives`; a
    board source that grants `etc` read-write to a session template
    holding no `start`, one that grants it read-write to a template
    whose `start` grant is read-only, and one that grants it to a configured domain
    other than the system domain, which a check that admits any domain
    misses; a check that admits a writable `etc` grant to templates
    holding `start` alone, which refuses every manifest whose system
    domain holds `etc` read-write; an `apps`
    row naming `etc` in `services` under a build whose property 19 lacks
    its `etc` exclusion, so the derived row grants `etc` to the app
    template, which this clause still refuses; a boot view that does not
    look for `ERX_START_FLAGS` in a template's environment, which admits
    a template that sets it; and a reserve that leaves the variable out,
    which admits a template with room for every other word but not for
    it.
18. **A display's pixel areas fit its budget:** every service of the
    `windows` interface has exactly one `display` record and every
    `display` record names such a service, so no grant of a display
    escapes the sum below; its server, the display domain, is a
    configured domain, never the system domain, whose row sets none of
    the environment keys its display record gives it
    ([design-display.md](design-display.md#a-displays-session)), and
    serves no other display, so no domain pays for two displays' grants out of one outer
    budget; for each display, each
    grant of its service costs the display its `pixels`, or
    `windows_pixels_default` of `abi/services/windows.txt` where the
    facet row states none, rounded up to pages, and the side the display
    reads for it, the display's own `lane` rounded up to pages, and for
    a grant whose facet row carries `clipboard`, the one copy it may hold
    while a fid is open for writing, `windows_clipboard_bytes` rounded up
    to pages; no facet
    row grants a display to the system domain, since its connection to
    the display is made by the display's creation, not by an
    introduction, and so carries no pixel area, which design-display.md
    sizes only for a configured domain or a session; a grant
    counts once for a configured domain and, for a
    session template, as many times as its principal's `domains` quota
    lets sessions of it live at once; the costs sum within the display
    domain's outer budget, since the display pays for every pixel area it
    maps and every side it reads; no facet row sets the `session`
    parameter, which the domain service alone sets
    ([design-display.md](design-display.md#the-pixel-area)); only a facet
    row granting a display to the system principal's session template,
    root's, sets the `front` parameter, and only in a development build,
    since the newest window of a front grant takes a single display's
    screen ([design-display.md](design-display.md#windows-and-the-window-system));
    every holder of a display's grant, a configured domain or a session
    template, the app template among them, boots a release script that
    starts `erx_memdraw` and `erx_win`, the client side of the display,
    whose allocator gives each window its buffer in the pixel area
    ([design-display.md](design-display.md#the-pixel-area)), which the
    check reads from what the build records each script of the archive
    starts;
    and no facet row turns `clipboard` on for a configured domain on a display
    whose policy is `single`, which never shows a configured domain's
    window, so that grant could never hold the window taking the
    keyboard and use the clipboard
    ([design-display.md](design-display.md#the-window-process)). Seeded
    violations: a check that counts a template's row once, which admits
    a template whose sessions together pass the budget; a facet row
    that sets `session`; a configured domain's row that sets `front`;
    another principal's template's row that sets `front`, which a check
    that admits any session template misses; root's row with `front` in
    a release build; a `windows` service with no `display`
    record, whose grants no sum would count; a check that sums
    each display alone, which admits a domain serving two displays
    whose grants together pass its budget; a facet row granting a
    display to the system domain; a session script without `erx_memdraw`
    and `erx_win`, an app script without `erx_win`, also when the
    display's name is spelt in hex, and a configured domain granted the
    display whose script boots only what every domain boots; and a
    configured domain's row with `clipboard` on a `single` display.

Property 19, which holds the board's own domains to their proof with
every installed app present, is the packaging design's
([design-packaging.md](design-packaging.md#the-builds-check)).

Each property has a test that seeds one violation into a manifest and
expects the build to fail with that property's diagnostic.

The check's one normalized input is the Ruby reader's, with the
platform placement records; budget and grant arithmetic is exact and in
Ruby. The awklog evaluation of
[Protocol verification](design-verification.md#focused-tool-evaluations)
compares a relational form of these rules with the Ruby check without
changing them. Facet edges grant particular operations, not transitive
authority; runtime admission and capability checks enforce every dynamic
use.

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
	supervised :: boolean(),             % the library's build answer: its boot
	                                     % information carries the supervised flag
	code       :: pid() | none,          % its code server, once its domain pid
	                                     % passed the report on
	ended      :: undefined | {erx_domain:end_(), integer()}  % the end and when
}).
```

A domain's target in the code service follows from its record and is
never stored: `{configured, Row}` for a supervised domain of a configured
row and `{domain, Id}` for any other
([design-live.md](design-live.md#the-code-server), "Targets"). A
supervised created domain's target needs a record of its specification
that outlives each of its domains, which this record is not; its name is
an open decision of design-live.md.

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

The records are declared in `include/erx/dom.h`. The fields the design
relies on, among others there:

* **A domain record** holds the domain's id (0 for a free record), its
  principal, its **origin** (request, configured row, partial-boot row or
  session template, with the manifest index for all but a request; set by
  the library's origin constructor and immutable), its state (`BUILDING`
  while the plan applies, `BUILT` with its first thread waiting,
  `RUNNING`, and `ENDED`: stopped, own budget destroyed and reported, the
  outer budget and crash area kept until the retire frees the record), its
  `ERX_DOM_SECRET` and `ERX_DOM_SPACES` flags, and the library's handles
  to its own budget, its outer budget, its space, group and sub-space
  group, its crash area (none for a secret domain), its boot information
  page, its mapping of the sealing page (only for the release marked
  `ERX_ENTRY_SEAL`), its first thread, and the number of its connection
  to the system domain. It keeps the domain's grant (a living configured
  domain's counts against `system`'s reserve until the domain ends); the
  stop the library made, with the fault record it came from; and the
  classified end with the record that ended it. Neither the outer budget
  nor any child of it is ever given to the domain.
* **A remains row** holds a retired domain's id, which a connection row
  names, the principal whose memory its outer budget stays carved from,
  that outer budget, the parent of the child budgets of the connections
  that name the id and of nothing else, and its size, which its destroy
  gives back to the principal.
* **A connection row** holds its number, the two domain ids `a` and `b`
  (`a` is 4 for a connection to the system domain), each party's child
  budget for the connection, carved from that party's outer budget (for
  a connection to the system domain, `b`'s holds everything), each side,
  one memory object its writer writes and the other party maps read-only,
  sized by its reader's lane and charged to its reader's child budget,
  each party's bell, a soft IRQ object bound to that party's group and
  charged to its child budget, of which the peer holds `TRIGGER` alone,
  an optional pixel area charged to the child budget of its reader, and
  `closing`, set once `connection_down` is told: the child budgets are
  destroyed once each party has unmapped the objects or ended, never on a
  timer.
* **A device record** holds its catalogue index, which is its manifest
  device row, its living holder (0 for none), the carved resource, its
  register windows, its IRQ objects and, if confined, its DMA window, all
  charged to the holder's own budget; and, if unconfined, its contiguous
  memory, made at its first give, charged to the system domain and kept
  for the boot.

The label of a domain's space, on each of its records, is the domain's id,
so the fault thread finds the record from the label alone. A sub-space has
no record here: it belongs to the domain that created it
([Sub-spaces](#sub-spaces)).

**A classified end** is one of four, computed by a pure function from the
records alone: `HALT`, the space stopped itself with a halt status;
`CRASH`, it stopped itself with `ERX_EXIT_CRASH`; `FAULT`, a thread
faulted and the library stopped the space, with the fault kind; and
`STOPPED`, the library stopped it on request. An exit record names the
thread that stopped the space and that thread's space, and only the
library, in the system domain's space, holds a capability that stops a
domain's space, so a stop the library made tells itself from one the
domain made by the stopper's space, whichever came first. A record's
noted stop is `NONE` until the library stops its space, so a zeroed
record notes none. The domain service turns the end into the `Info` of
`{domain_down, D, Info}`: `{halt, Status}`, `crash`, `{fault, Kind}` or
`stopped` ([design-domains.md](design-domains.md#links-monitors-and-exits)).

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
   waits but the firmware request, which runs on a dirty I/O scheduler
   and holds the lock only before and after its wait
   ([Devices](#devices), "Firmware requests").
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
   secure lines. The login asks the domain service, which alone reads the
   system principal from the system manifest, for that principal
   (`erx_domain:system_principal/0`) and then for root's session,
   from the system principal's session template. The domain service
   holds every session's start until the system release has started its
   last application, so each session is granted every service the system
   domain serves, whichever application names it. The session takes
   the line once its tty names itself, with its namespace in place
   ([A session takes the console](#a-session-takes-the-console)); the system shell stays one menu
   key away, and when the session ends the console logs `root` in again
   ([design-live.md](design-live.md#the-console)).
5. **The start table.** Once the system domain's namespace is in place,
   by the rule a session's start waits on
   ([A session takes the console](#a-session-takes-the-console)), the
   start service reads `start.conf` and starts each enabled row of the start table,
   the manifest's `start` rows with the machine's `start.conf` over them
   ([design-apps.md](design-apps.md#the-start-table)): the session of
   the principal the row names, with no login, and for a row that names
   a display, once that display's server has settled
   ([A session takes the console](#a-session-takes-the-console)), on that display, to
   which the system domain introduces it and whose session it becomes
   ([design-display.md](design-display.md#a-displays-session)). Each
   row's keeper starts its session again when it ends, within the row's
   intensity ([design-apps.md](design-apps.md#keeping-a-session)).

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
and at the host link's `console` line, and when the first session a
start row keeps reports ready, which counts as an automatic login
([design-apps.md](design-apps.md#keeping-a-session)). A development build's automatic
login comes early in every boot, so there rescue catches only a fault
before the console's first login. When the
count it read is past three, the system release boots its **rescue
configuration**: the console, a login, and the domains the manifest marks
for rescue, in the default manifests the devices domain, the storage
domains, the slot writer, the vault's storage domain and the vault, and
no user domain and no network domain, so an operator at the console can
repair what a deterministic fault at boot would otherwise reset forever.
The release boots the same configuration at once, whatever the count,
when its pin driver's start cannot set the pins of a device that only
domains outside that configuration use
([design-pinctrl.md](design-pinctrl.md#at-start)).
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
intensity the manifest gives, as a supervisor restarts a child: at most
`restarts` restarts within `restart_period_s`, except that a restart after
a boot timeout counts until a boot of the row reports ready and then ends,
however long that takes. A boot that hangs is stopped only at each timeout,
so its restarts come a boot timeout apart, and a period could not hold them
on a machine whose boot timeout is long; counted in a row, they leave a
domain that hangs every time down after `restarts` restarts, whatever the
boot timeout. Beyond the intensity,
a domain the manifest marks `required` ends the machine the same way, with
the reason in the log, and any other is left down and shown so in the
inspector, since a machine without its network is still a machine an
operator can repair at the console. Each end of a configured domain is one
log line, and a fault's line names where it struck from the kernel's fault
record: its program counter, cause and address, the address shown as
unknown for a fault that names none. An asynchronous error is taken at a
later return to user mode on whatever thread runs then, so its line says
the location is presumed: that thread may not be its source.

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

#### A session takes the console

A session takes the console only with its namespace in place. The
domain service answers a session's start only once each `files` grant of
its template is installed in it, or that grant has settled as failed,
and the console connects the person's line to the session only on that
answer, so a command typed at the first prompt, `ls /data` among them,
meets the namespace the session will keep and never an I/O error left
over from the boot. The guarantee is about the line, not the session:
the session's tty and shell start as soon as its init's ready report is
answered, and until the line is connected the console holds the tty's
first output and the tty waits, as for any session not connected
([design-live.md](design-live.md#the-console)), so only the person's line
is held. A session the menu
starts is listed in it only once its start is answered, so it too is
in place before anyone can connect to it.

* **In place.** A session's namespace is in place when each grant of a
  `files` service to it has settled: the mint core has installed it
  ([Facets a configured domain serves](#facets-a-configured-domain-serves)),
  its operation has failed, or it has no operation while its server is
  not starting. A server is starting from its start, or from the boot
  while the hold at boot holds its row ([Devices](#devices)), until it
  reports ready, is stopped for its boot timeout, or ends. A server that
  is ready but does not provide the grant's name, one that has ended,
  and one whose start was refused are not starting, so their grants have
  no operation
  to wait for and count as settled. Grants of every other
  interface (`net`, `driver_control`, `web`) are not waited for: the mint
  core installs them when their server reports, as it does after a
  restart.
* **The answer.** The mint core keeps its rule that a session's ready
  answer reaches it before any grant is installed, so the session's
  grants exist only from its ready report on. The service keeps the
  start's caller from the start until it answers, as it keeps a
  create's; for a session it answers not at the ready report but at the
  first step of the mint core after it, the report's own included, at
  which `erx_domain_mints:in_place/3`, a pure function of the grants and
  the starting rows, holds for the session. A session that ends before
  then is answered with an error, as a create whose domain ends before
  its report is, and the console treats it as any start that failed.
* **Failure is bounded.** A server that fails or never comes up delays
  the answer by at most the machine's boot timeout (`boot_timeout_s`), after
  which its start has ended; a grant whose introduction, mint or
  installation stalls fails at the mint core's deadline. Either way the
  session takes the console with that mount answering I/O error, as it
  does whenever its server is down, and the grant is installed when the
  server reports after a restart. A server that ends while the session
  waits settles its grant at once: the session does not wait for a
  restart.
* **The system domain.** The system domain is a grantee of the same
  rule: its namespace is in place when each `files` grant to it, `data`
  among them, has settled. The domain service answers
  `erx_domain:system_namespace/0` once `erx_domain_mints:in_place/3`
  holds for the system domain, which it checks after each step of the
  mint core and each stop for a boot timeout, or at once when it already
  holds; the system domain holds its grants from the boot on, so they
  are checked from the first request, and the wait is bounded as a
  session's is. The start table waits for that answer before its first
  read of `start.conf` (step 5 of the boot), so on a boot whose storage
  domain comes up on its first start and makes the grant within the mint
  core's deadline the read finds the machine's settings before any row
  starts. On one whose storage domain is down, ends before it reports
  ready, or misses the deadline, the read fails and the manifest's rows
  start alone, as a session does not wait for a restart either, and
  each row takes its local settings at its own command or the next boot
  ([design-apps.md](design-apps.md#failure-handling-diagnostics-and-debuggability)).
* **A display's row.** The start table starts a row that names a
  display only once that display's server has settled, by the same rule
  of starting a grant's wait reads: `erx_domain:server_settled/1`, a
  request of the system domain's own like `system_namespace/0` (a
  message from another domain reaches the service only in its
  `{erx_origin, D, Msg}` envelope, which is no call it takes), is
  answered `ok` once no starting configured row serves the display
  (`erx_domain_mints:settled/3`, the `{server, Name}` query). Its server is
  then ready, or stopped for its boot timeout, ended, or refused its
  start; a name no configured row serves has nothing to wait for and is
  answered at once. The service checks the rule after each step of the
  mint core and each stop for a boot timeout, as it does for the
  system domain's namespace, so the wait is bounded by the machine's
  boot timeout, and a display that is down never holds a row: the row
  starts all the same, its session's windows grant is installed when the
  server reports after a restart, as any grant is, and the row's keeper
  asks again before each start of its session
  ([design-apps.md](design-apps.md#keeping-a-session)).
* **One incarnation's grant.** The device service answers a PCIe
  domain's report only once the system domain holds that incarnation's
  `pcie` facet ([design-pcie.md](design-pcie.md#facets)). It asks with
  `erx_domain:await_grant(pcie, D)`, a request of the system domain's
  own like `system_namespace/0`, sent and not waited on, for the
  incarnation `D` that the report's envelope names. The domain service
  keeps the caller beside those of `system_namespace/0` and answers at
  the first step of the mint core at which the system domain's grant of
  `pcie` has settled for `D`: `{ok, Facet}` when the grant is installed
  with `D` as its server, `{error, failed}` when it failed with `D` as
  its server, `{error, ended}` when `D` has ended or the grant carries
  another server, and `{error, unprovided}` when `D` is ready and the
  grant is idle, since `D` provides no `pcie`, or the system domain is
  granted no `pcie` at all. A `D` the mint core has not heard of, once
  the grant's server row is not starting, is answered `{error, ended}`:
  it stopped without a ready report or is no incarnation of the row, and
  the mint core will hear of it no more. The wait is bounded by
  the mint core's deadline for an operation in progress and by the
  machine's boot timeout before the ready report of `D`, an incarnation
  of the grant's server row, so no query waits on an incarnation that
  never comes.
* **Why it holds by construction.** The wait reads only state the mint
  core already keeps, the grant of each `files` service to the session,
  and the domain service's own record of which configured domains are
  starting; no domain is named and no list of mounts is kept. A new
  storage-like server is waited for because it serves a `files` grant to
  a template, and a new service of another interface is not, because it
  does not. The console connects a session, or lists it, only once the
  service has answered its start, so no path gives the person the line
  sooner, and the session exchanges no message of its own for it.

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
NIFs, since none of them waits; the device service's firmware request,
the one entry that waits, is a dirty I/O NIF
([Devices](#devices), "Firmware requests"):

| Entry | What it does | Result |
| --- | --- | --- |
| `erx_dom_principal(number, configuration)` | validates the complete normalized principal configuration, stores its resolved default and ceiling profiles, carves its budget and creates its group under `users`, with its domain quota: a manifest principal's budget a wall from the root budget, an app principal's elastic from the `apps` budget, with no guarantee and that budget's guarantee as cap ([design-packaging.md](design-packaging.md#an-apps-principal)) | `ERX_OK`, `ERX_EEXIST`, `ERX_ENOMEM`, `ERX_EINVAL` |
| `erx_dom_create(spec)` | validates an `erx_dom_spec_t` into a plan and applies it ([Creating a domain](#creating-a-domain)); a configured row's plan also gives the domain the devices the manifest places on that row ([Devices](#devices)) | the domain's record, with the number of its connection to the system domain and the system domain's values of that connection's objects, or the failing step's status after every applied step is undone, `ERX_EBUSY` when a device of the row is held by a living domain |
| `erx_dom_start(id)` | starts the built domain's first thread | `ERX_OK`; `ERX_EDEAD` for a stopped space; `ERX_EINVAL` for any state but built |
| `erx_dom_stop(id, status)` | stops the domain's space, and with it every sub-space below it | `ERX_OK`; `ERX_EINVAL` for an unknown or ended id |
| `erx_dom_resize(id, memory)` | resizes a running domain's own budget with `erx_budget_resize`, guarantee and cap together, within its principal's budget ([Resource policy](#resource-policy)); refuses a configured domain, whose sizes are the manifest's (A10) | `ERX_OK`; `ERX_EINVAL` for an unknown, ended or configured id; `ERX_ENOMEM` when the principal's budget cannot cover the growth, after which nothing changes |
| `erx_dom_destroy(id)` | destroys the stopped domain's own budget, which deletes at once every object charged to it and to every budget carved from it; the fault thread calls it at the exit record | `ERX_OK`; `ERX_EINVAL` unless the domain has stopped |
| `erx_dom_retire(id)` | releases an ended domain: destroys its crash area, frees its record and gives its principal back the domain and its own budget's bytes; destroys its outer budget when no connection names the domain, and otherwise keeps the outer budget as the domain's remains, which the disconnect of its last connection destroys; the domain service calls it once the crash area is read and the system connection disconnected, without waiting for any other connection | `ERX_OK`; `ERX_EINVAL` unless the domain has ended; `ERX_EBUSY` while its system connection stands |
| `erx_dom_connect(a, b, a_reads, b_reads, area, area_reader)` | creates a connection between two built or running domains: carves from each domain's outer budget a child budget for the connection; creates two sides, `b`'s sized `a_reads` and charged to `a`'s child, since `a` reads it, and `a`'s sized `b_reads` and charged to `b`'s child; two bells, each charged to the child of the domain whose group it is bound to; and, when `area` is not 0, a pixel area of `area` bytes, charged to the child of `area_reader`, which maps it read-only while the other party writes it ([design-display.md](design-display.md#the-pixel-area)); gives each domain its share ([Authority](#authority)) | the connection's number and each domain's values; `ERX_ENOMEM` when a reader's outer budget cannot cover its child; `ERX_ELIMIT` for a full table; `ERX_EINVAL` for a domain outside built or running, for `a == b`, for an `area` that is not a whole number of pages, or for an `area` whose `area_reader` is neither, or an `area_reader` other than 0 without one |
| `erx_dom_disconnect(number)` | destroys the connection's child budgets, which deletes its sides and bells at once, and the remains of each retired party that no other connection names; the domain service asks it only once each party has unmapped them or ended; a capability to them fails with `ERX_ESTALE` from then on | `ERX_OK`; `ERX_EINVAL` for an unknown number |
| `erx_dom_code_object(session, size)` | creates a paged object with an execute ceiling from the session's budget through the system domain's own capability to it, which carries `CODE`, and gives the session a copy with `SUPPLY`, `READ`, `MAP`, `CHILD`, `DUP`, `GIVE` and `EXEC`; the kernel refuses an executable mapping of it until it is sealed (K8) | the object's number and the session's value; `ERX_ENOMEM`; `ERX_ELIMIT` beyond `code_objects_max` for the session; `ERX_EINVAL` for a session neither built nor running, or a size of 0 |
| `erx_dom_code_drop(session, number)` | deletes a session's code object, after which every mapping of it faults | `ERX_OK`; `ERX_EINVAL` |
| `erx_dom_info(id, topic)` | the domain's group or own budget report, from `erx_object_info` on the library's handle, for the inspector's collector ([design-live.md](design-live.md#inspection-records)); any system-domain process may ask, since a report holds counts and masks and none of the domain's data | the report; `ERX_EINVAL` for a domain neither built nor running or another topic; the backend's refusal |
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
group and boot objects; its connections, lanes, pixel areas and doorbells; the
resources of the devices it holds; and, for the vault, the sealing page.
It never installs an IPC gate of another domain, so no domain holds a gate
to another domain, no rendezvous joins two domains, and memory crosses a
domain boundary only through objects the system domain created and
charged to an outer budget or a child of one. The rule holds by construction: the plans
draw every install from `erx_dom_grants`, which has no row for a foreign
gate, and the library's host test runs a seeded plan that installs one,
which must fail.
A creation specification, `erx_dom_spec_t` in `include/erx/dom.h`, is
the domain service's description of the domain, a fixed layout
constructed from an admitted request, a checked configured-domain row, a
checked partial-boot row or a session template. It carries the domain's
id, allocated by the domain service and unused; its principal; its
origin, set by the library's origin constructor, which is authority
provenance and never a field accepted from a request; its flags,
`ERX_DOM_SECRET` for the vault's (no crash area, required for the
release marked `ERX_ENTRY_SEAL`, whose domain alone gets the sealing
page) and `ERX_DOM_SPACES` (it holds `SPACES`, with a sub-space group);
its release slice and runtime image, as boot-image indices; the
guarantee and cap of its own budget and of its outer budget; its group's
grant and its sub-space group's, within it; its complete runtime limits;
the data areas of the lane it reads and of the lane the system domain
reads from it, both charged to its child budget for the system
connection; its `connections` quota, which also sizes the control table
on the system domain's side; its crash area's size; and its arguments
and environment, which together fit `ERX_BOOT_STRINGS_MAX`.

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
* `erx_dom_plan_session(view, id, template, name, name_len, display, display_len, domain_pid)`
  takes an index into the checked manifest's session templates, the
  name the domain service chose and the session's default display, a
  service name or none; its environment gains, after the template's
  words, `principal=N`, the template's principal's number,
  `display=NAME`, and `serves=svc` where the template declares
  `serves svc` ([design-app-trees.md](design-app-trees.md#serving-erx_svc));
  everything else (principal, images,
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

**A grant fits its parent** when its slice, the quantum of its threads,
is within the ABI's `slice_min_us` .. `slice_max_us`, and it asks for
nothing the parent lacks: its cpuset is within the parent's, its flags
within the parent's, its urgency ceiling at most the parent's, and its
rate at most the parent's.
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
      request names, the `supervised` flag when the domain's
      specification restarts it, which tells its code server to wait
      for its start load ([design-live.md](design-live.md#the-code-server)),
      and each given device's record
      ([Boot information](design-fiasco.md#boot-information))
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
   told its address yet, and contiguous runs are not returned on
   Fiasco, so a fresh memory goes into the device's record and the
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

**On Fiasco.** The plan, its checks and its undo are the same code.
Each step's kernel call is a request to Fiasco's root service, the
one owner of every Fiasco object, served on its one thread
([design-fiasco.md](design-fiasco.md#the-root-service)), each a row of
[its call table](design-fiasco.md#the-call-table): step 1's budgets and
step 3's group are walls at their guarantees and a record: each budget
a Fiasco factory for its kernel memory and the root's charge for its
pages, so K32's walls hold without borrowing (FD25), and the group's
grant is a record (FD15); step 2's space is a Fiasco task with its parent and
fault gate recorded, so the domain's end ends its sub-spaces, and its
faults reach the root service as Fiasco's fault messages, which become
fault records at the library's gate; step 4's sides and bells are memory
objects and IRQ objects of the root, the bells bound by the library to
each party's group; and step 6's installs are `erx_cap_pass` from the
library's table into the space it created. A handle on Fiasco
is a slot whose rights the root records and checks at every service
call, and whose Fiasco capability carries only the rights those allow
([design-fiasco.md](design-fiasco.md#passing-a-handle)), so a domain that
bypasses `liberx` is still held to step 6's rights: it gets no delete
right on its connection's objects, and the root refuses it a write
mapping of the system domain's side. What Fiasco lacks against erXos's
kernel is in
[Downsides against erXos's kernel](design-fiasco.md#downsides-against-erxoss-kernel); what
Fiasco means for connections and for the domains' invariants, D7 and D17
included, is in [design-domains.md](design-domains.md#on-fiasco).

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
a_reads, b_reads, area, area_reader)`: every page of a connection is charged to the party
that reads it, on a child budget of its outer budget that the library
carves for that connection, so the side `A` reads is charged to `A`'s
child and sized by `A`'s own spec, likewise `B`'s, and each bell to the
child of the party that waits on it; a sender never makes a receiver pay
for what it is willing to receive, and the receiver's policy chooses the
lane size. A connection between a display and a client the manifest
grants its window tree carries one more object, a **pixel area**: the
client writes it and the display maps it read-only, it is sized by the
`pixels` of the facet row that grants the client the display, a
configured domain's own row or its session template's, which the
manifest states for the pair whichever introduction makes their
connection, and it is charged to the display's
child with the side the display reads
([design-display.md](design-display.md#the-pixel-area)). No call grows
or adds an area afterwards. A side goes to the reader's outer budget, not its own, because
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
through its `code_objects` facet, and the domain service calls
`erx_dom_code_object(session, size)`, which creates the object from the
session's budget through the system domain's own capability to it, so
the session pays for its code, and gives the
session a copy with `SUPPLY`, `READ`, `MAP`, `CHILD`, `DUP`, `GIVE` and
`EXEC`: the session fills and seals it, and installs it into its
programs' sub-spaces itself, as their creator, where the loader maps
it; the kernel refuses an executable
mapping before the seal. The library keeps the only `DESTROY`, so the
session's copy carries none, bounds the objects at `code_objects_max` per
session, and deletes one at `erx_dom_code_drop`, which the domain
service calls when the session's command server drops the object
through the same facet; the rest go with the
session's budget at its destroy, after every program that mapped one has
stopped with the session
([design-programs.md](design-programs.md#file-objects)).

A session is a trusted supplier of its own programs' code, an app's
session as much as a template's: the copy it holds can be filled with
any bytes, from any source, and sealed, and nothing below the session
checks where they came from. That harms no party but the session: the
object is charged to the session's own budget and runs only in the
session's own spaces, its own and its programs', which stop with the
session, and a session whose image carries `ERX_IMAGE_JIT` already
makes machine code in its own JIT space. What
the `rx` rule of a grant protects is a program, from running a file
that it or another program could rewrite: the session's handler fills
a code object for a program only from a file the program reaches
through an `rx` entry
([design-files.md](design-files.md#invariants), F6; [design-programs.md](design-programs.md#invariants), P10).
It is no check on the session itself.

A
program from the boot image needs none: its session maps its slice. A
session's shared mappings of files need nothing of the library either: the
session serves them from memory objects of its own budget
([design-files.md](design-files.md#shared-mappings)).

**The `code_objects` facet.** `abi/services/code_objects.txt` declares
the interface a session reaches the domain service's code objects
through, with its two operations and the limits `code_objects_max` and
`code_objects_max_request`. `create` takes the object's size in bytes, a positive integer, and
answers `{ok, Number, Cap}`, the object's number and the session's value
of its copy, or the library's refusal, `{error, enomem}` for the
session's budget, `{error, elimit}` beyond `code_objects_max` and
`{error, einval}` once the session has ended; `drop`
takes a number and answers `ok`, or `{error, einval}` for a number that
names none of the grantee's live objects. The facet's decoder refuses
any other request with `{error, badarg}`. The session is the facet's
grantee, taken from its grant record and never from a request, so no
request names a session: a session makes objects only from its own
budget and drops only its own. The system manifest declares the
service once, served by the system domain, and the domain service
grants a facet of it to every session it starts, a template's and an
app's alike, by its own policy
([design-domains.md](design-domains.md#facets), "The facet table"),
with no facet row: what it hands a session, memory of the session's
own budget within `code_objects_max` for code the session supplies, depends
on nothing a template chooses, and an app's session lists it among its
facets ([design-packaging.md](design-packaging.md#an-apps-session)).
The facet's limits are the domain service's policy too, the same for
every session: `max_request` is `code_objects_max_request`, which holds
the largest request's whole envelope, a call whose caller's pid and alias
each carry a node name of up to 255 bytes, with room to spare; and
`in_flight` is 4, so the command server can fill a few programs' objects
at once. A facet row for the service is refused by the build's check of
the manifest, so no row grants it to a configured domain or changes its
limits for a template. It is policy and not a row because it gives a
session only its own budget, which no template has reason to withhold
or limit again, while the facets that are rows reach beyond the
session, as the code service's install facet loads into the system
domain and `root_clock` sets the machine's clock
([design-time.md](design-time.md#who-may-set-it)), so a template must choose them.
Any process of the session can reach it, an app's own Erlang
applications among them; that the command server is its one caller in
erXos's code is no boundary, and the trust above covers them all.

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
  each connection, the side of that connection the domain reads, the
  pixel area it reads and the bell it waits on, or for its connection to
  the system domain both
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
   the fault's kind, keeping the record beside it; the first stop is the
   one noted, and the report of a `FAULT` end carries that record, the
   kernel's own account of where the fault struck, as `fault` in its
   `Record`.
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
3. **Records the death**, the last 16 per principal, with the record,
   for a crash the crash header's slogan, and for every end the device
   access trace, decoded
   ([design-runtime.md](design-runtime.md#the-device-access-trace)),
   which it reads by copying the
   crash area into an object of its own with `erx_mem_copy`, never through
   a mapping, so a deleted source fails with `ERX_ESTALE` and never
   faults. In a development build the log line that reports the end
   adds, when the trace holds entries, the path that shows them,
   `/proc/domains/Id/crash`, and no entry: register values are the
   domain's data, shown only to principals that may inspect the domain,
   and the log is read with `varlog` alone.
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
end**: `off`, which `init:stop/0` and every deliberate `erlang:halt/0,1`
with a non-negative number in the system domain ask for, `halt(0)` and
`halt(3)` alike, `reset`, which `init:reboot/0` asks for, `trial` or
`reset`, which the update service asks for
([design-storage.md](design-storage.md#system-updates)), and `off` or
`reset`, which a session that holds the `machine` grant asks for ([A
session's request](#a-sessions-request)). Every request reaches the
coordinator through its one entry, with the end and the principal that
asked. For `trial` the
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
2. **Every storage service, and the media service, freezes**: the
   system domain asks each, on its durability facet, for a checkpoint that freezes it, which answers once
   a completed checkpoint holds every write the service acknowledged and
   then answers every later write `{error, erofs}`, as a trial's mount
   does, waiting at most 5 s for them all
   ([design-storage.md](design-storage.md#interfaces)). An error, timeout
   or service death is an unsuccessful freeze, never an acknowledgement;
   the coordinator records each service's outcome.
3. **The coordinator selects the end from the outcomes.** `trial` is
   selected only when the vault and every storage service acknowledged
   preparation; the media service's outcome is recorded and logged and
   selects nothing, since a trial reads no drive
   ([design-drives.md](design-drives.md#finishing-a-volume)). Otherwise a requested trial becomes `reset`, which sets no
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
operations keep their own guarantees. A trial's read-only mount is
reached only after successful preparation. The pure end decision takes the
requested end, the boot value and the complete set of preparation
outcomes; an outcome still pending is a failure at the deadline.

A numeric halt's status chooses no end: `halt(3)` asks for `off` as
`halt(0)` does. What stops the system domain without the coordinator is
not ordered: ERTS's exit on a fatal error, `erlang:halt/1` with a string
or with `abort`, which OTP takes as a crash rather than a halt
(`erts/emulator/beam/bif.c`, `halt_2`), and a stop of the system domain's
space that does not go through the coordinator. The runtime stops its
space, and the kernel writes the crash record and ends the machine by
`erx.panic`, as for a fault ([The crash record](#the-crash-record)).

#### A session's request

Root's ordinary login session ends the machine with `reboot` and `halt`.
FreeBSD's reboot(8) is the model: it refuses every caller but the
superuser with `EPERM` and logs `rebooted by USER`, `halted by USER` or
`powered off by USER` at `LOG_CRIT` (`sbin/reboot/reboot.c:385-388` and
`:417-437` at FreeBSD commit `975e3605`, the commit `erx_net` pins;
[References](#references)). The rest of this section follows from one
construction: **ending the machine is a write to a file the domain
service serves, and holding the grant of that file is the right to end
it.**

Without that file, nothing outside the system domain can ask for an end.
Every end above is asked for in the system domain. No interface that
`abi/services` declares carries a request for one. `erx_machine_end`
needs `POWER`, a right of the root resource alone: `kind root_resource`
carries it and `kind carved_resource` does not, and a resource capability
cannot be passed (`pass none`, `abi/kernel.txt`), so the right never
leaves the system domain. In a session, `init:reboot/0` and
`erlang:halt/0,1` stop only the session's own domain
([design-runtime.md](design-runtime.md#crash-handling)).

**The `machine` tree** is a service of the system domain and an instance
of `files`, as the start service's tree, `start`, is
([design-apps.md](design-apps.md#interfaces)). The domain service's
application serves it with `erx_fs`, beside the coordinator, and a
session that holds the grant mounts it at `/machine`, where the system
domain mounts its own grant of it
([design-shell.md](design-shell.md#interfaces)):

| File | Read | Write |
| --- | --- | --- |
| `ctl` | nothing: write-only, mode `0200`, and an open for reading is refused with `eacces` | one end per write, whatever the offset: `reset` or `off`, with at most one trailing newline. The write succeeds once the coordinator has installed the ending record. It is refused with `einval` for any other bytes, `trial` and an empty write included; with `ebusy` while an ending record is installed, whoever asked for it; and with `eio` when the coordinator ended before it answered |

A session whose template holds no `machine` grant has no `/machine`. A
path into it answers `enoent`, as `/etc/start` does for a session without
`start`.

**The right is the grant.** The manifest's facet rows say which session
templates hold it. For each session of such a template, the domain
service asks the tree's grant supervisor in the session's ready answer
for one `erx_fs` grant bound to the session's domain and ending with it
([Facets a configured domain serves](#facets-a-configured-domain-serves),
"Facets of the system domain's services"). The records every
development manifest takes grant it to root's template alone
(`@session.system`). A release manifest
grants it to root's template and to any administrator's template its
author lists, as it does `start`. There is no administrator flag, group or
list beside the facet rows, and the tree does not check who a writer is:
whoever holds the grant may end the machine, as whoever holds `/etc/start` may
command the start table. It follows that:

* every session of root holds the grant: one started by a login at a
  console line, through the web front end or over SSH, or from a line's
  menu, since each starts from the template alone
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas));
* ending the machine needs a writable route to the grant: the session's
  mount of `/machine`, a mount that names the same facet elsewhere, or a
  descriptor of `ctl` opened for writing, which a program receives
  whatever its namespace holds
  ([design-programs.md](design-programs.md#descriptors-and-files),
  "Files passed on"). A program inherits `/machine` with its session's
  namespace, so a program root runs may end the machine, as on UNIX.
  Narrowing a command with `within`, or leaving `/machine` out of a
  program's namespace
  ([design-files.md](design-files.md#narrowing-for-a-program)), takes
  the right away only when no route remains: `within` names no `machine`
  grant, no `ctl` descriptor is passed, and the namespace keeps no other
  mount of the facet. Ordinary capability inheritance decides this, with
  no rule of its own for the machine tree;
* a grant ends with its session, so no grant outlives the session it was
  made for.

**The grant names who asks.** At the mint the domain service computes the
grantee's principal, as it computes `inspect`'s scope (**Parameters the
domain service computes at the mint**, in [Facets a configured domain
serves](#facets-a-configured-domain-serves)), and starts each grant with
that principal as the grant's own argument (`erx_fs_grants:grant/4`, as
`erx_winfs` serves each client its own directory). The `ctl` line carries
the end and nothing else, so the log can only ever name the principal of
the grant the write came through. The request carries no principal; the
coordinator takes it from the server-side grant. A session may know its
own principal's name from its `/etc/passwd`
([design-programs.md](design-programs.md#the-posix-lite-personality)),
and that gains it nothing, since no request names anyone. The system
side fills the principal in, from the grant for a session's request and
as the system principal for its own.

**One entry for every request.** The coordinator takes every request for
an end through one call, with the end and the user that asked. The
`ctl` handler passes its grant's user name, and the system domain's own
callers, `init:stop/0`, `init:reboot/0`, a numeric `erlang:halt/0,1`,
the update service and the system shell's commands, pass the system
principal's, `root`. For each request the coordinator calls
`erx_dom_end_begin(how)`. When the begin succeeds, the coordinator writes
one log record at `critical`, which records the request it accepted:
`rebooted by P` for `reset`, `powered off by P` for `off`, and
`trial boot requested by P` for `trial`, where `P` is that user name.
The record names what was asked, not
how the machine ended: an `off` accepted during a trial ends by a reset
(K19), and a `trial` whose preparation failed ends by a reset, which the
coordinator's preparation lines report. It then answers `ok`, and
prepares and commits as above. When an ending record is already
installed, it answers `busy` and logs nothing. This gives one log line
per end, written by the system domain whoever asked, and one refusal for
every later request, whatever its source.

**The request carries the end alone**, `reset` or `off`. `trial` is the
update service's and no session asks for it. There is no flag for an
orderly or an immediate end. FreeBSD's `-q` skips init's stopping of
services but still flushes the file system cache: `reboot(2)` syncs
unless `-n` is given (`reboot.8:185-189`, `reboot.c:390-393`). erXos's
ordered end stops no service and runs no stop scripts. Its two
preparation steps, the vault's quiesce and the storage freeze, are that
flush, so `-q` has nothing to skip. Its 10 s deadline already bounds an
end that a hung service would delay. `-q` is accepted and asks for the
same ordered end. A second word that commits without preparation would
give any holder of the grant a way to drop the freeze's guarantee for
every principal's acknowledged writes, to save at most the 7 s of the two
preparation deadlines, and no consumer needs that. `halt` asks for `off`:
`erx_machine_end` has no end that stops the machine without turning it
off, so FreeBSD's `halt` and `halt -p` are the same end here.

**What the requester learns** is that its write succeeded, or one of
three errnos. It never learns the preparation's outcomes, whether a
trial turned its `off` into a reset (K19), or who else asked. A write
that succeeds means the end has begun and cannot be undone. The requester
may not see even that, because the machine can end before the reply
reaches it.

**The commands.** `reboot` and `halt` are Erlang commands of the command
shell ([design-shell.md](design-shell.md#commands)) and declare
`-erx_needs([machine])`. Their one decision takes the arguments, and
each writes the end's line, `reset\n` or `off\n`, to `/machine/ctl`. In a
session the path reaches the session's grant. In the system domain's
command shell it reaches the system domain's own grant of the tree,
started with the system principal, which the domain service mounts at
`/machine` in the system domain's namespace when it serves the tree
([design-shell.md](design-shell.md#interfaces)). When the write is
refused the command prints `reboot: ` (or `halt: `) and the errno's
text, as reboot(8)'s `err(1, NULL)` does, and exits 1. When it succeeds
the command exits 0 in a session. In the system domain's command shell,
which the end ends too, it waits for the end instead, as FreeBSD's
reboot waits for init, so the shell prints no prompt over the end's
last line; the command tells the two apart by the runtime it runs in
(`erx_inspector:is_system_runtime/0`).

A session without the grant refuses either command with the shell's
standard `no_facet` before it starts, as for any command whose facet is
absent, and the commands' help names `machine` as their need
([design-shell.md](design-shell.md#commands)). FreeBSD prints
`reboot: Operation not permitted` instead; matching that text would need
the two commands to run without `-erx_needs` and make the check
themselves, a second refusal path for two commands, so erXos keeps the
one refusal every absent facet gets.

**Why a file tree.** Of the three homes a new need may take, an end is a
one-shot command, so it is a `ctl` file of a tree its owner serves:

* it is not an inspection path, which is state someone reads; `/proc`
  takes no writes;
* it is not a declared protocol, which is for a live conversation. An end
  is one word with one answer. An interface of its own would add an
  operation schema, a facet module and its admission path to carry that
  word, and a program would need an Erlang client to send it.

The tree adds no new mechanism. It uses the `files` interface, `erx_fs`
and its grant supervisor, the template's facet rows, the session's mount,
and the end of a grant with its session, all of which exist. A program
reaches it as it reaches any file, through its namespace.

**Concurrency.** The coordinator takes requests one at a time. Of two
requests at once, from two sessions or from a session and the system
domain, the first begin wins and the other is answered `busy`. A write
in flight when its session ends either reached the coordinator, and the
end goes on, or did not, and nothing happens. After a successful begin
no domain is created or restarted, so a session that asks for a new
domain after its `reboot` is refused, and it ends with the machine.

**Failure.** The tree's grants are temporary children of their
supervisor. A grant that crashes ends that session's grant alone. The
session's mount of `/machine` stays, and its paths and every descriptor
opened on the grant answer `eio`, as any facet's mount does once its
grant has ended ([design-files.md](design-files.md#building-binding-and-mounting)).
The domain service mints a system domain service's grant for a session
only in its ready answer and does not mint it again, so that session can
no longer end the machine; a fresh session, from a new login, gets a new
grant. The system domain's own grant is kept by the tree's supervisor:
one that ends is started again and mounted in place of the ended one,
and until then the system shell's `/machine` answers `eio`. The
coordinator is a process of the domain service, whose end
ends the machine ([System services](#system-services)). So `eio` is the
answer to a write whose coordinator ended during the call, and the
machine then ends by the crash path anyway.

**The kernel's side.** The `machine` grant is the only way a session can
ask for an end, because `erx_machine_end` itself is the system domain's
alone. On erXos's kernel the call's generated decoder requires `POWER` on
`res` through the one capability lookup, and only the root resource
carries `POWER`, so any other caller gets `ERX_ERIGHTS` (K31;
[design-kernel.md](design-kernel.md#kernel-calls)). On Fiasco, the
Fiasco backend's service does the same with the tool it has: it answers
`ERX_FIASCO_CALL_MACHINE_END` only for the root task and refuses a call
from any other task with `ERX_ENOTSUP`, as it refuses `erx_log_take` and
`erx_object_info` from a task (`liberx/backend/fiasco/service.c`).
Without that check, any task could end the machine by calling the stub,
and the `machine` grant would bound nothing.

**What a holder can do** is end the machine for every other principal,
which is why the shipped manifests grant the tree to root alone. A
holder cannot weaken the end. Its request makes the same ordered end the
system domain's own does, with the same preparation and deadline, and
the log names the holder's principal.

**Manifest rows.** Every development manifest
(`config/manifest/development.txt`, which both boards' manifests follow)
declares the `machine` service, served by the system domain as a `files`
instance, and one facet row granting it to `@session.system`. Its
`max_request` is `files_max_frame_min`, as for every `files` grant
(property 16); one write in flight is enough for a file that takes one
word; and the grant holds only its fids, so its `max_heap_size` is
small. Its `reductions` and `period_ns` are the values every facet row
carries, and no CPU limit binds an `erx_fs`
grant, so what bounds repeated requests is the first begin, after which
every write is answered `ebusy` and logs nothing, and the grant's one
write in flight. The grant travels on the session's system connection,
so `max_connections` does not change, and no `abi/services` file is
added: `abi/services/files.txt` declares the interface, and the facet
table check (FacetNames) takes the row from these manifest records.

**Verification.** Host tests, and one case of a native guest, each with
its seeded fault:

* **The `ctl` parse**, which has a fuzz target: only the two ends, each
  with at most one newline, are accepted. Seeds: a parser that also
  accepts `trial`, and one that takes a second newline.
* **The coordinator's entry**: one begin and one log line naming the
  grant's principal, then `busy` with no line. Seeds: a coordinator that
  answers `ok` to a second request, and a log line that names the system
  principal instead of the request's.
* **The mint** in `erx_domain_srv`, over a manifest whose `machine` row
  grants a test principal's template and not root's. Seeds: a mint that
  passes the system principal instead of the grantee's, and one that
  gives the system domain's services to every template.
* **The commands' decision**: `reboot` and `reboot -q` write `reset\n`,
  `halt` and `halt -p` write `off\n`, an unknown option is a usage
  error, and only the system domain's shell waits. Seeds: `halt` mapped to `reset`, and a command that waits
  outside the system domain.
* **The system domain's own mount.** Seed: a start that leaves the own
  grant unmounted.
* **Fiasco's root check**, in the native task guest, since the Fiasco
  backend's service has no host build: a task's `erx_machine_end` returns
  `ERX_ENOTSUP`. Seed: with the check removed, QEMU exits at the call.

The QEMU suite `machine_end` has two 1-CPU cells, `reboot` and `halt`,
each its own boot of the development manifest with a principal whose
template holds no `machine` row: that session finds no `/machine` and
root's session still answers, and root's command logs its line before
QEMU exits, within the ending record's deadline for `reboot`. Seeds: a manifest that also
grants the other template, whose write then ends the machine first, and
a `ctl` that answers `ok` without calling the coordinator. The harness
cannot tell a power-off from a reset under `-no-reboot` (`TODO.md`,
tooling, `machine_end`), so the log line tells the two ends apart.

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
configured domain, the system domain or a session template, with the
grant's limits. A template's grant, written `grantee
@session.PRINCIPAL`, is made for each session of that principal while
the session lives, by the server directly, never through the system
domain; a template's grant of a service the system domain serves is
started by the domain service, as below. Service
names are unique per server, not across the manifest. The facet is a
process of the server's domain, minted there by the server's own code with
`erx_facet:start/3`, so the system domain never stands in front of it; the
domain service decides when each grant is minted, asks the server, and
installs the result in the grantee's capability registry, under the
service's name; the facet row's own name names the row in the manifest
alone.

**The registry.** A domain's capability registry is one value with one
owner, `erx_facets`, a preloaded module, since every resolution of a path
reads it: each facet under its name, as its pid, or for a facet of a files
service as its pid with its grant's rights
([design-files.md](design-files.md#namespaces)). Only that module knows
the shape. The value also carries a generation, a counter each
installation raises, by which a process waits for the next
installation ([Waiting for a
grant](#waiting-for-a-grant)). Its one writer, `erx_facets:install/1`,
is called by the domain's connection agent alone, in every domain: the
domain service installs a facet for the system domain through the
system domain's agent (`erx_connections:grant/1`). Its readers read it at use:
`erx:cap/1`; a resolution, which puts each facet's grant beneath its
mount with the lesser of the two rights (`erx_facets:table/1`), so a
re-grant serves the next lookup; and a reader that opens a files facet's
tree by name, whose handle `erx_facets:file_grant/2` makes read-only and
which keeps the grant it opened on, as an image mount does. So nothing
a reader takes from the registry carries more than its grant's rights.
Two build checks hold this: the registry's key appears in no other
module, and no other module calls its writer.

**Providers.** A configured domain's services each name a **mint**, a
process of the domain that mints facets of one service, with
`erx_facet:provide(Name, Mint)`, before its init reports ready, and the
ready report carries them as its `provides` map, each under its name's
text, a binary: the system domain decodes the report in safe mode, which
makes no atom ([design-runtime.md](design-runtime.md#the-edits-outside-syserxos),
edit 9), so the domain service reads a name as the atom of that text
where it has one, and a name it has none for is one no row declares. A
mint named after the report is refused. A mint lives as long as its domain's incarnation: the
providers are the report's until the domain ends, so a mint's end ends its
domain, as a permanent application's does, and the restarted domain's
report provides again. A server reports ready
once its mints are named, and each of its services serves from the
moment its protocol says: a storage mint runs its mount after the
report and holds a mint request that comes first in its queue until
the mount is done (`erx_fs_mint`), and for the PCIe protocol
serving starts at the answer to the PCIe domain's report: its mint
grants `pcie` at once, and its enumerator takes a request only once the
device service has answered that report
([design-pcie.md](design-pcie.md#processes)). The ready-report gate authenticates the reporting domain and its
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

**A session as provider.** A session provides two kinds of service,
under the same rules with a session in place of a configured domain's
incarnation: each mint is a pid the session owns, node and creation
both, and its `provides` map names no service but these, or is refused
whole. Its **lines** are the services `abi/services` declares
`served_by session`, `web_line` and `ssh_line`, which every session
provides and the domain service mints only when the system domain names
their grantee ([A session's lines](#a-sessions-lines)). `svc` is its
app's own tree ([design-app-trees.md](design-app-trees.md#providing)):
its principal NAME has a start row and its template declares `serves
svc`; NAME's provider is
its newest live session that provides `svc`, and a report from an older
one provides nothing. The name the grant is installed under is
`{svc, NAME}`, from the session's principal, never from the report. No
manifest row grants `svc`: the domain service grants it by its own
policy, as it grants `code_objects`, to every live session whose
template holds the start service's tree, `start`, with rights `rw`, and
to no other grantee, the system domain included.

**One operation per grant.** For each grant, named by its grantee (a
configured domain, the system domain or a live session) and its service's
name, the domain service keeps one record. The
grant's **pair** is the current ready incarnation of its server, if that
incarnation provides the name, and the current ready incarnation of its
grantee; the system domain, id 4, is always ready. The record follows the
pair, so each operation is bound to both incarnations by construction:

| State | Meaning |
| --- | --- |
| `idle` | the grant has no pair: its server or its grantee is not ready, or the server provided no mint for the name |
| `introducing` | the domain service is introducing the grantee to the server ([Creating a domain](#creating-a-domain)); skipped when the grantee is the system domain, which every domain is connected to |
| `minting` | the mint has been asked for a facet bound to the grantee, and its reply is awaited |
| `installing` | the facet has been sent to the grantee's registry, its pid and, for a files service, the rights of the grant's facet row, and its acknowledgement is awaited |
| `installed` | the grantee acknowledged; the grant holds the facet's pid |
| `failed` | the operation for this pair failed, and was logged; nothing is retried for the pair |

Beside its state, the record of a session's grant carries the
**session mark**, a boolean fixed when the record is made and never
changed: it is true for the grant on the display that the session's
start names with `display`, which only a start row's keeper names
([design-apps.md](design-apps.md#starting-a-session)), and false for
every other grant. Every mint of the record carries it as the `session`
parameter, the first and each one after the server's restart, so a
display domain's new incarnation mints the display's session's grant as
the display's session again, and no other grant ever carries it
([design-display.md](design-display.md#a-displays-session)).

The record moves on these events, and on nothing else:

* **a session's ready report**, which adds a record for each of its
  template's grants, keyed by the session's id, so two sessions of a
  template never share one, and, for a template that holds `start`, a
  record `{svc, NAME}` for each name with a provider; or **the session's
  end**, which cancels their operations and deletes them.
* **a provider's ready report** of `svc`, which adds a record
  `{svc, NAME}` for each live session whose template holds `start`, or
  **its end**, after which those records have no pair until NAME's next
  session provides, and leave their state as below. A session is never restarted, so only its
  server's restart makes its grants anew; a failed one stays failed for
  the session's life.
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
  `{erx_facet_mint, Tag, Name, Grantee, Principal, Limits}`, where
  `Principal` is the user name of the grantee's principal, the prefix of
  its sessions' names: `root` for the system principal, and for any other
  its name in the system manifest, a configured domain's row's or a
  session's template's
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas)),
  from which a server scopes the grant by principal, as the storage
  domain roots a home grant at the user's home
  ([design-files.md](design-files.md#building-binding-and-mounting), "A
  user's home"), and `Limits` is the facet row's limits, with
  the `session` parameter added where the grant's record carries the
  session mark (below), through the server's
  domain pid, which the server's domain already holds, since a send
  exports its sender's pid to the receiving domain; the request names no
  process to reply to. An error fails the operation;
* **the mint's reply**, `{erx_facet_minted, Tag, Reply}`, which the server
  sends its own domain pid with `erx_facet:minted/2`, and the domain pid
  passes on as an answer of its domain, as it passes on
  `connection_mapped`. So no pid of the domain service leaves the system
  domain, and nothing a server sends reaches the domain service but
  through its domain pid. A refusal crosses as the atom `refused`,
  whatever the server's reason, since the service reads no more of it and
  the system domain's safe decode would drop a reply naming an atom it
  lacks. The reply is untrusted. It
  counts only from the pair's server, for an operation in `minting` with
  that tag. `{ok, Facet}` with `Facet` a pid the server's incarnation
  owns, node and creation both, moves the operation to `installing` and
  sends the grantee
  `{erx_facets_install, Tag, Name, Facet}`, where `Facet` is the pid, or
  for a files service `{Pid, Rights}` with the rights of the grant's
  facet row, which the manifest states and no reply sets
  ([design-files.md](design-files.md#building-binding-and-mounting),
  "Rights beneath an entry"); any other reply fails it. A
  reply with an unknown or finished tag, a second reply, or one from
  any other domain is dropped and counted;
* **the acknowledgement**, `{erx_facets_installed, Tag}` from the
  grantee's connection agent, which installs a name only from its
  connection to the system domain and answers through its domain pid, as
  it answers `connection_mapped`. It counts only from the pair's grantee,
  for an operation in `installing` with that tag, and makes the grant
  `installed`. Anything else is dropped and counted. For the system
  domain the domain service installs the same value it would send
  through its own runtime's agent, a call answered once the facet is
  installed, and acknowledges on that answer;
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
report, which every operation for that grantee follows. The ready answer
also names the facets of configured domains the manifest grants the
grantee, its row's grants or its session template's, and no other
domain's, each with its service's interface number (`abi/services`), so
the grantee knows a name is coming before its grant is installed and what
kind of grant it is, as a display tells its input trees from another
display's window service ([design-display.md](design-display.md#the-display-device)):
a domain mounts a files facet only where the manifest grants
it one ([design-files.md](design-files.md#building-binding-and-mounting),
"A facet's mount"), and the domain's agent keeps the names and their
interfaces for `erx:granted/0`, which answers the names, and
`erx:granted/1`, which answers those of one interface. The system domain, which holds the manifest, takes its
own names from it. Until its grant is installed, and while its server
restarts, the grantee finds the name absent or its facet dead, and
treats both as the service being unavailable.

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
names it, and answers a failure only once the process it spawned has
ended: when that process's init does not report within the start's
deadline of five seconds, `start/3` kills it and takes its `'DOWN'`,
keeping its monitor until then, before it answers `{error, timeout}`. So
a failed start leaves no facet behind, and a caller that starts another
next never runs two. A facet whose operation was cancelled or failed after the
server minted it is never installed; it ends with its grantee through its
`ends_with`, or, for the system domain as grantee, with the server. There
is at most one such facet per pair, since a pair runs one operation.

**Facets of the system domain's services.** A `facet` row may also grant
a configured domain or a session template a service the system domain
serves. No mint is involved: each such service names the process behind
it with `erx_facet:serve(Name, Pid)` as it starts, in the system domain's
own table, and when a configured domain or a session reports ready, the
domain service starts a facet in front of that process for each such row
granted to the domain's row or the session's template, bound to the
domain and within the row's limits, with the scope the service's own
pure function gives for the grantee where the service has scopes, as
`inspect` does ([design-live.md](design-live.md#the-inspect-service)),
and sends it in the ready answer with any other facet the domain gets
there. So these facets reach every incarnation and every session with
its ready answer, before any installation, and end with it, or with the
process behind them. For a service of an interface `abi/services` declares
`served_as tree` (`files` and `line`; `windows` is left out because
property 18 makes a configured domain, never the system domain, the server of
every `windows` service) the process
behind it is the supervisor of its tree's grants (`erx_fs_grants`), and
the domain service asks it for an `erx_fs` grant bound to the grantee and
ending with its domain pid, in place of a facet in front of it, as a
files service's mint does for its grantees (`start`, served by the start
service, and `apps`, served by the package process, are such). A
service that has named no living process by then is left out and logged; the domain finds the name absent, as it
finds any unavailable service, until it restarts. The domain service
creates the configured domains as it starts, so a service whose facets
the manifest grants them is started before it, by an application the
system release starts before `erx_domain`.

**Parameters the domain service computes at the mint.** A grant's
parameters are its facet row's, except a parameter the domain service
computes at the mint: a value no facet row may set, which the domain
service derives from its own records, with a pure function, each time it
mints the grant or starts its facet, and carries in that mint. It is one
mechanism, with five uses: `inspect`'s scope, which
`erx_domain_core:inspect_scope/4` gives from the grantee's principal, the
manifest's system-shell principals, its development flag and whether
the grantee holds `start`
([design-live.md](design-live.md#the-inspect-service)); the `windows`
grant's `session`, the session mark the domain service fixes for the
display's session and copies into every mint of that grant
([design-display.md](design-display.md#the-pixel-area)); the
`machine`, `windows` and `inspect` grants' `principal`, the grantee's
user name, the one name every grant carries (`root` for the system
principal, as in a mint request), which the tree's log line names ([A session's request](#a-sessions-request)),
the display's trusted overlay shows for each window
([design-display.md](design-display.md#windows-and-the-window-system))
and the inspector reads to decide who sees a window's tree
([design-live.md](design-live.md#inspection)); and an app's `ble`
grant's `services`, the one computed value that narrows a value its row
sets: the app template's `ble` row names the services apps may handle,
and `erx_domain_core:app_session/4` gives each app's session that row
with `services` replaced by the intersection of the row's set and the
GATT services the app's record holds, which admission kept apart from
every other app's ([design-packaging.md](design-packaging.md#an-apps-session),
[design-bluetooth.md](design-bluetooth.md#the-ble-facet)); and a line's
`opening`, the system domain's process whose end ends the line's grant,
which the line operation's request names
([A session's lines](#a-sessions-lines)). A service that
needs a value only the domain service knows takes it the same way, never
through a facet row or a protocol of its own.

**A facet row's parameters reach the mint by name.** The manifest check
resolves each `parameter NAME VALUE` line of a facet row against its
service's declaration and packs it as a parameter row, keyed by the
declaration's number ([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)).
The domain library's boot view, the one reader of the packed manifest on
the boot path, is the one place a row is decoded: it checks each facet's
rows against the parameters its service's interface declares, from a
table the build generates from `abi/services` (`erx_service_parameters`
in `erx/abi.h`), so each declared parameter appears once, except a set,
whose elements are consecutive rows in strictly ascending order,
numeric or, for an identifier set, by bytes
([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)),
in number order, of its declared kind and within its declared bound, and no
parameter the interface requires is left out. A device reference, such
as the `line` grant's `device`, is the index of its device row, which the
manifest check resolves from the device-tree path the facet row states
and the reader checks against the device table; a domain or principal
reference, which no service declares, is refused, as the manifest check
refuses one. `erx_domain_lib:configured/0` then gives
each checked parameter in the grant's `Limits` under its declared name,
beside the row's six limit fields: an integer kind as an integer, a
boolean as `true` or `false`, text or bytes as a binary, a device
reference as its row's index in the manifest's device table, and a
`set`, whose elements the view takes as consecutive rows of its key in
strictly ascending order and at most its `MAX_COUNT`, as the list of its
elements in that order. The generator refuses a parameter that takes a
limit field's name, so the two never meet in one map. So the `windows` grant's `pixels`, `windows`
and `clipboard` are the row's, and the pixel area `erx_domain_mints` charges
the display is the one property 18 summed.

The decisions are a pure state machine, `erx_domain_mints`, beside
`erx_domain_core` and `erx_domain_links`: it takes the manifest's rows,
the events above and the requests for a session's line ([A session's
lines](#a-sessions-lines)), and returns the next state and the actions, to
introduce, send the mint, send the install, answer a line's asker, arm and
disarm a deadline, and
log a refusal, a dropped message or a failure, which `erx_domain_srv`
applies; it logs and counts every refusal and drop. The actions for the
log carry only atoms, the service's own numbers and the reasons the core
names, never a term a domain sent. A session template's grant is held
per live session, keyed by the session's id: the session's ready report adds
one for each of the template's grants, its end cancels their operations and
deletes them, and the server's restart makes them anew for every live
session, so two sessions of a template never share a grant and an ended
session leaves nothing in the domain service. It is tested exhaustively over every
order of these events, with two incarnations of a server and of a
grantee, one session beside two incarnations of the server and two
sessions beside one, a third domain that claims the name, forged pids, and
replies that come late, twice, or from the wrong domain or session, and
with line operations among them, each racing its session's end and its
peer's.

#### A session's lines

A **line** is a facet a session serves to a front-end domain, the web
domain or the SSH domain, whose grantee the system domain names at run
time instead of the manifest: the web domain when the host link's `web`
facet opens or a login through its `login` facet succeeds
([design-web.md](design-web.md#logging-in-and-the-line)), and the SSH
domain and the phone console when a login through theirs succeeds
([design-login.md](design-login.md))
([design-ssh.md](design-ssh.md#logging-in)). Through it the front end
opens what the session offers it: views of the session's paths for the
web domain, ttys for the SSH domain's channels. The process that serves
it, the **line process** (`erx_web_line`, `erx_ssh_line`), is the
session's; the facet is the only name of the session a front end gets
but those its replies hand out, and the system domain hands the facet
out as the reply of a declared facet's operation, `login`'s
`{ok, Line}` or the host link's `web` opening, which is how every route
between domains begins ([design.md](design.md#decisions)). That
process, the **opening**, also bounds the grant: the facet ends when it
does.

The construction: **a line is a facet the session mints for the grantee
the system domain names, within the life of the opening that asked for
it, and the line process takes nothing from another domain but the
system domain's mint request and sends a front end nothing.** The facet
rules of [design-domains.md](design-domains.md#facets) then hold for a
line by construction: it takes the grantee's calls alone, within the
grant's limits, and replies only to a caller and alias of the grantee's
(`erx:call_from/3`); it drops and counts everything else; and it ends
with what its grant names. The pieces:

* **The interface.** Each line's interface is declared in `abi/services`
  with `served_as message` and `served_by session`: `ssh_line` in
  `abi/services/ssh.txt` and `web_line` in `abi/services/web.txt`.
  `served_by session` says that a session serves the interface and that
  the domain service grants it only on a request naming its grantee, so
  no manifest row grants it. The interface lists exactly the operations
  the line serves its grantee: an operation the design names enters it
  with the code that serves it, and what the session sends the grantee,
  a tty's ending or a view's update, is no operation of it.
  `served_by session` is the one source of which names are lines: the
  generator emits them, each with its grant's quantities, as
  `?ERX_LINES`, which the domain service reads; the facet-name check
  takes such a name as a line, which the source may provide and pass to
  `erx_domain:line/4` though no manifest row names it; and the manifest
  check refuses a `service` or `facet` row of such an interface.
* **The grant's quantities.** No facet row states a line's grant, so the
  interface does, with a `quantity` line for each of the five a facet row
  carries ([design-abi.md](design-abi.md#services-facets-and-their-parameter-schemas)),
  each required of a `served_by session` interface:
  * `max_request` is derived from every argument variant the line
    serves, under both measures a request meets: the decoded size that
    the facet contract's funnel checks before a message is queued
    ([design-domains.md](design-domains.md#facets)), read here as the
    term's heap words times the word size plus the bytes of every binary
    it references, and the encoded size `erx_facet` checks, which stands
    in for the funnel's check while that is a residual of
    [todo-domains.md](todo-domains.md): `erlang:external_size/1` of the
    call `{'$gen_call', From, Request}`, the envelope left out. Each is
    taken with the caller's pid and alias and every pid in `Request` of a
    node name at its 255-character bound, and the bound is the smallest
    power of two not below the larger of the two for the largest
    request, so a request that grows a little between OTP releases still
    fits, and a variant that enters the interface derives it again. A
    host test builds the largest request of each variant and checks both
    measures against it. For `ssh_line` the largest is an
    `open_tty` of `{exec, Command}` with a 32 KiB command and a 64-byte
    `TERM`, about 33 KiB under either measure, since the command's bytes
    dominate both, so 65,536; for `web_line` an `open` of a `path` of 16
    segments of 256 bytes, about 5 KiB under either, so 8,192. These
    sizes are worked from the external term format and the heap layout,
    not measured; the host test measures them. A `trace` target's selection, up to 16
    presentations of up to 4 KiB of text, enters `open` with the trace
    view and raises `web_line`'s to 131,072.
  * `in_flight` is how many of the grantee's requests the line serves at
    once, a choice of concurrency and no bound on what the line keeps: 4
    for `ssh_line`, since a channel's `open_tty` is answered at once, and
    16 for `web_line`, one per view a connection may open together. What
    lives past its request is bounded by the line process's own limits,
    `ssh_line_max_channels` ttys and 64 views.
  * `reductions` and `period_ns`, the grantee's share of the session's
    grant, 100,000 reductions a second for both, and `max_heap_size`,
    65,536 words, room for twice the largest request with the facet's
    own state.
  * The queue quota is the session runtime's own `-erx queue_quota`, as
    for every process outside the system domain
    ([design-domains.md](design-domains.md#flow-control)); a line's grant
    names none.

  A line adds no enforcement of its own: what the facet behaviour
  enforces of these, and its residuals in
  [todo-domains.md](todo-domains.md), are the line's.
* **The mint.** The line process is its line's mint and the service
  behind its facet. Both line processes are built on one module,
  `erx_session_line`. It names itself the mint of its line with
  `erx_facet:provide/2` before init's ready report ([A session as
  provider](#facets-a-configured-domain-serves)), and of messages from
  another domain it acts on one alone: the mint request `{erx_facet_mint,
  Tag, Name, Grantee, Principal, Limits}` in the system domain's
  envelope, for its own `Name` and a `Grantee` other than the system
  domain. It answers in three strict steps. First, if it holds a facet,
  it ends it and takes that facet's `'DOWN'`; the facet traps no exits,
  so the exit ends it, and from its `'DOWN'` on, nothing new of the
  old grantee's is admitted. Then it starts the new facet with
  `erx_facet:start/3`, bound to `Grantee`, within `Limits`, and ending
  with the session's connection to `Grantee`
  (`erx_connections:connection/1`), with the line process and with the
  opening that `Limits` names; `start/3` answers a failure only once the
  process it spawned has ended, a timed-out one killed and its `'DOWN'`
  taken ([Failure](#facets-a-configured-domain-serves), above), so no
  failed start overlaps the next. Last it replies with
  `erx_facet:minted/2`: `{ok, Facet}`, or a refusal when the start
  failed, after which the line holds no facet until the next request.
  Every other message in an envelope is dropped. So a line has one facet
  at a time, as it has one front end: a newer request replaces the
  older grant, for the same grantee or another. A request the old facet
  forwarded before its end still reaches the line process and runs, as
  revocation allows ([design-domains.md](design-domains.md#facets)); its
  reply goes to the old facet's alias and is lost with it.
* **The facet's callback.** `erx_session_line` is also the callback of
  every line's facet. Its `admit/3` forwards each request the facet
  admitted to the line process with the grantee, the grantee's caller and
  the facet itself, which the facet gives it and the request never does,
  and the line process's own callback answers it. A request of no
  operation the line serves is answered `{error, badarg}`. The
  interfaces of `ssh_line` and `web_line` name no message in no call's
  shape, so their facets have no `message/2` and drop such a message,
  counted. A job's messages, the first such need, are routed and
  delivered by the answer to design-ssh.md's open question "How a job's
  messages reach their job"
  ([design-ssh.md](design-ssh.md#risks-and-open-questions)), with
  `open_job`, and enter `ssh_line`'s interface with it.
* **What the session sends a front end.** The line process sends a front
  end nothing, since every send to another domain exports its sender
  ([design-domains.md](design-domains.md#exports)). Its answers go
  through the facet. A tty is two processes of the session, a console
  that drives its shells and a terminal relay that speaks to its master
  ([design-shell.md](design-shell.md#the-terminal-relays-protocol)), and
  only the relay sends the channel anything: the console messages, which
  it opens with `{tty_open, Relay}`, and, as its last message before it
  ends, the ending of what ran on the tty, `{exited, Status}` or
  `{signaled, Signal}`, which the console hands it once the shell has
  ended and the channel has taken the last output. A job's relay sends
  its channel the job's messages and its ending; a web view sends its own
  updates. So every sender is a name the front end was already handed,
  the tty's relay, the job's relay or the view, and the console, like the
  line process, is exported to no front end.
* **The opening.** `erx_domain:line(Name, Session, Peer, Opening)` names
  the opening, a process of the system domain: the host link's `web`
  facet process, which asks for root's line as it opens, or, for a
  login, the login facet the login came through, which the login service
  knows as the pid of the forward's reply target. The domain service carries `Opening` in the mint request's
  `Limits` as `opening`, a parameter the domain service computes at the
  mint (below), so a facet row can never set it, and the line puts it in
  the facet's `ends_with`. When the host closes its `web` facet, or the
  login facet ends with its front end, the line's facet ends. The
  session learns the opening's pid with `send` alone, and the opening
  acts on nothing in the session's envelope: the host link's `web` facet
  process takes only the web domain's casts and the host link's calls,
  and a login facet only its grantee's calls.
* **Views and ttys.** A request a line serves may start a process that
  acts for the grantee, as a process a facet starts does
  ([design-domains.md](design-domains.md#facets)), and hand its pid out
  in the reply, exported with `send` alone. A web view is one
  ([design-web.md](design-web.md#views-on-the-line)): it takes, in its
  grantee's envelope alone, `next`, `stop` and, for a UI view, the
  events of `abi/protocols/web.txt`'s grammar within its bounds, and
  drops everything else; and it charges its facet's account
  for its work. It runs with the heap limit its interface declares for
  it, as such a process does, `web_line_view_heap_max` in
  `abi/services/web.txt`, 262,144 words, set when the line spawns it with
  `max_heap_size` killing at the limit and counting the binaries it
  references, and with its message queue on its heap, so what waits
  unread counts toward the same limit, the session runtime setting no
  queue quota by default
  ([design-domains.md](design-domains.md#flow-control)). The value holds
  a view's last projection, at most one 64 KiB update, beside the
  inspector's largest record before projection, a listing page of 1,000
  children, with room to spare; it is chosen, not measured, and the
  view's heap test measures a view over that page and confirms, on OTP
  29.1.2, that a flood of unread messages ends the view at the limit. A view ends at
  `stop`, with the grantee's caller that opened it, with the session,
  and with the facet through which it was opened, which it monitors;
  that monitor's `'DOWN'` reaches it even while its share is spent,
  since a paused process takes the `'DOWN'` of its facet beside the
  facet's resume message
  ([design-domains.md](design-domains.md#facets)). So the host's
  closing of its `web` facet ends every root view opened under it,
  paused or not, while root's session and its UIs stay; a replaced
  facet's views end and are never bound to the new grantee; and each
  ended view leaves the line's table, which bounds the views that live
  at once to 64, as a connection's `web_views_max` bounds its own.
  A tty is the one name a line hands out that does not end with its
  facet. It is the console's
  ([design-live.md](design-live.md#paths)): its relay takes the console
  messages from its master alone, and the tty ends at `tty_hangup`, with
  its master's end and with the session, as a terminal ends with its
  line, so a shell is never killed under a channel that is still open.
  A login's line facet is replaced only by another login into the same
  session, which no login makes, since each starts a session of its
  own; and the session ends with the front end's process that logged in
  ([design-login.md](design-login.md#a-session-ends-with-what-it-was-started-for)),
  its ttys with it.
* **Calls of the session's own.** A process of the session reaches the
  line process directly, without an envelope, since it acts with the
  session's authority anyway; the browser renderer hands the web line a
  UI's changes this way
  ([design-web.md](design-web.md#uis-the-browser-renderer)).
* **The operation.** `erx_domain:line/4` asks the domain service for
  session `Session`'s line `Name` with `Peer` as its grantee, and is
  answered once, within the operation's deadline. The mint core keeps,
  beside its grants, one **line operation** for each session and line
  name it was asked for and has not answered: made by the request,
  deleted at its answer. It runs as a grant's operation does, bound to
  its pair, `{Session, Peer}`, with a fresh tag and the 10-second
  deadline: `introducing` the two domains, then `minting`, the mint
  request sent to the session's provider of `Name` through the session's
  domain pid with the quantities `?ERX_LINES` gives `Name` and the
  opening. Its replies are read as every mint reply is: one from any
  other domain, or with another tag, is dropped and counted; one from
  the session with the operation's tag settles it at once, `{ok, Facet}`
  with `Facet` a pid the session owns, node and creation both, answering
  the asker `{ok, Facet}`, and anything else failing it. The answer
  stands where a grant's installation stands, so a line operation has
  no `installing` or `installed` state; and since no one but its asker
  wants the facet, its pair is fixed when it is made and never
  reconciled: after either domain's restart nothing mints the line again
  until someone asks.

The operation's answers:

| Answer | When |
| --- | --- |
| `{ok, Facet}` | the session minted the line's facet for `Peer` |
| `{error, no_line}` | the session is not live or has no accepted mint under `Name`, a name outside `?ERX_LINES` included; or it ended before the answer |
| `{error, busy}` | an operation for the session's line `Name` is pending |
| `{error, ended}` | `Peer` ended before the answer |
| `{error, Reason}` | the introduction refused, with `introduce/2`'s reason |
| `{error, refused}` | the session's reply with the operation's tag is a refusal, `Peer` being the system domain, the session having no connection to it or the facet not starting, or names a pid the session does not own, or is of any other shape |
| `{error, unavailable}` | the deadline passed with no reply that counts |

An opening that ends before its answer leaves the operation to run; a
facet minted for it ends with it at once, since `erx_facet` ends a facet
whose `ends_with` names a process that has ended.

**Invariants.**

| Invariant | Holds because |
| --- | --- |
| **L1.** No domain but the system domain chooses who reaches a session's line, and no front end holds the line process's name | the line process acts on no message from another domain but the mint request in the system domain's envelope, which the domain service sends only on an `erx_domain:line/4` of the system domain's own processes; the system domain learns the line process's name from the ready report, as it learns every mint's; the line process sends a front end nothing, so no export of it reaches one, and a front end reaches it only through a facet minted for it |
| **L2.** A front end reaches a line only within a facet's bounds | the line is an `erx_facet`, whose admission, limits and counts are the behaviour's ([design-domains.md](design-domains.md#facets)) |
| **L3.** A line's facet ends with its session, with its grantee's connection and with its opening | its `ends_with` names the session's connection to the grantee, the line process and the opening; the line process is its application's one process, started permanent, so its end ends the session domain and the session's end ends it |
| **L4.** A line has at most one facet | the mint starts a facet only after it has taken the `'DOWN'` of the one before, and `erx_facet:start/3` answers a failure only after the process it spawned has ended |
| **L5.** No facet of an ended session or for an ended peer is handed out | a line operation is bound to its pair: the end of either domain answers it and deletes it, and a reply after that matches nothing |
| **L6.** A view a line handed out ends with the facet it came through | a view monitors the facet through which it was opened and takes that monitor's `'DOWN'` paused or not; a tty is the one exception, ending with its master and its session (Views and ttys, above) |
| **L7.** Which services are lines is one fact | `served_by session` in `abi/services`, from which `?ERX_LINES`, the facet-name check and the manifest check's refusal are derived |

L1 binds other domains. A process of the session itself acts with the
session's authority, which already reaches every process of the session
and can export any of them, and the envelope authenticates only what
crossed a connection, so a local process can send the line process a
message of any shape; nothing a session's process does that way reaches
past the session.

**Authority.** The facet carries the grant to call the line's operations
and nothing more, for as long as its opening, its session and its
grantee's connection last. A reply may hand out a further name, exported
to the grantee with `send` alone, as every facet's reply may; a view
ends with the facet it came through (L6), and a tty with its master. The line holds
no authority beyond the session's: its views read through the session's
inspect facet at that facet's scope, and its ttys run the session's
shell.

**Failure.**

| Failure | What follows |
| --- | --- |
| the session ends during the operation | the asker gets `no_line`; a facet already minted ended with the session |
| the peer ends during the operation | the asker gets `ended`; a facet already minted ends with the connection |
| the session's mint is silent | the deadline answers `unavailable`; a facet it mints afterwards is handed to no one and ends at the line's next mint, with the session, with the connection or with its opening, so a line has at most one such facet |
| the new facet does not start at a replacement | the line holds no facet, and the asker gets `refused`; the old grantee's facet has ended, and a new grant needs a new request |
| the opening ends | the facet ends, and every view opened through it, paused ones included, each leaving the line's table; the session, its UIs and its ttys' shells stay |
| a facet's start times out | `start/3` kills the facet and takes its `'DOWN'` before it answers `{error, timeout}`; the line holds no facet and the asker gets `refused` |
| the line process ends | its application is permanent, so the session domain ends, and every facet of the line with it |
| the grantee restarts | the facet ends with the connection; the new incarnation gets a line only by a new request: a login, or the host link's `web` facet opening again |
| a session's ready report provides a line under a pid the session does not own | that entry is refused, logged and counted, as a configured domain's entry is, and the report's other providers stand; `erx_domain:line/4` for it answers `no_line` |
| a session's ready report names a service outside the two kinds a session provides | the map is refused whole, logged and counted; the session runs, and `erx_domain:line/4` answers `no_line` for each of its lines |

**Tests.** Each passing case beside the seeded fault that must fail it:

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| mint core, exhaustive over event orders (host) | a line request introduces, mints and answers `{ok, Facet}` once; the session's end, the peer's end and the deadline each answer once and leave no operation; a late or second reply is dropped and counted | the session's end leaves the operation in place, so a late reply answers the asker with a facet of an ended session |
| mint core, replies (host) | a reply from another domain or with another tag is dropped and counted, and the deadline answers `unavailable`; a reply from the session with the operation's tag naming a pid of another domain or node, or of another shape, answers `refused` at once | the owner check on `Facet` dropped, so the asker gets another domain's pid |
| mint core, a second request (host) | a request while one is pending for the same session and line is answered `busy`, and one mint request is sent | a second operation started beside the first |
| session providers (host) | a session providing `web_line` and `ssh_line` under pids it owns has both; a pid of another node refuses that entry alone and the other line stays; a map naming `data` is refused whole; each refusal is counted, and `line/4` answers `no_line` for a refused line | the name check against `?ERX_LINES` dropped |
| the line's mint (host, `erx_session_line`) | the mint request in the system domain's envelope starts a facet bound to the grantee, exported to it with `send`, and answers `minted`; the same request in the grantee's envelope, naming the system domain as grantee, or naming another line starts none, and a call to the line process itself in the grantee's envelope opens nothing | the envelope's origin not compared with the system domain's id |
| replacement (host) | at a second mint the stand-in export table records the new facet's export only after the old facet's `'DOWN'`; a request the old facet forwarded before its end is served at the line, while a call to the old facet after its end is admitted nowhere; a new facet that fails to start, by a refused init or by a stand-in init that never reports, leaves the line with none and answers a refusal, the timed-out one's `'DOWN'` taken before the refusal | the new facet started before the old one ends, so two live facets are observed; and `start/3` answering `timeout` before the killed child's `'DOWN'`, so the stand-in sees it alive after the refusal |
| the facet's lifetime (host) | closing the stand-in connection ends the facet, and so do the line process's end and the stand-in opening's | the opening left out of `ends_with` |
| no door beside the facet (host) | after an `open_tty` and the ending of what ran on its tty, the stand-in export table holds no export of the line process or of the tty's console toward the SSH domain, the ending having come from the tty's relay, and a call sent to the line process in the grantee's envelope reaches no callback | the line process sending a tty's ending to the channel itself |
| request bounds (host) | the largest request of each implemented variant, with node names at their bound, encodes within its line's `max_request`; an `open_tty` with a 32 KiB `exec` command is admitted, one past `max_request` is dropped and counted, and the eleventh channel is answered `limited` | `ssh_line`'s `max_request` left at the facet's default of 4 KiB, which refuses the 32 KiB command |
| the web line's views (host) | an `open` through the facet starts a view that answers the grantee's caller and takes `next` and `stop` in the grantee's envelope alone, dropping any other message; the view ends with its facet, at a replacement or at its opening's end, and never answers the new grantee; a view paused with its share spent ends at its facet's end all the same and its table entry is freed, so a 65th open after 64 such ends succeeds | the view not monitoring its facet, so it outlives the host's closing; and a paused receive that takes only the resume message, so a paused view outlives its facet |
| a view's heap (host) | a view over a 1,000-child listing page stays within `web_line_view_heap_max`; a flood of unread messages from the grantee ends that view alone at the limit | the view spawned without `max_heap_size`, so the flood grows it past the limit |
| the line names (build check) | a source that provides `web_line` passes the facet-name check; one that provides a name no manifest row and no `served_by session` interface declares fails it; a manifest `facet` row of `ssh_line` is refused | `served_by session` removed from `web_line`'s declaration |
| the host link's web views (QEMU) | in a development build, opening the host link's `web` facet gives the web domain root's line, a browser's record view equals the read from root's console, and closing the facet ends the view | a test build whose line mint refuses every request, so the view ends `unsupported` |

#### Waiting for a grant

Grants arrive after the ready answer, so three kinds of process wait on
them. A domain's own code waits for a facet to reach its registry: root's
session's SSH daemon for its `net` and `data` facets
([design-ssh.md](design-ssh.md#stages)), a display for each input tree
and again after each re-grant
([design-display.md](design-display.md#the-display-device)). The
system domain's own services wait for a grant or a server to settle: the
start table for the system domain's namespace and for a display's server
([A session takes the console](#a-session-takes-the-console)), the
device service for one incarnation's `pcie` grant
([design-pcie.md](design-pcie.md#facets)). And configured rows holding a
`pci` device wait at boot for the device service's answer to the PCIe
report ([Devices](#devices), "The hold at boot").

One rule covers all three: **a wait is held by the one process that
writes the facts it reads, and answered after each write of those
facts.** No waiter looks again on a timer, no answer depends on when it
looked, and each kind of fact has one place where its waiters live.

| Wait | Facts it reads | Held and answered by | A waiter waits at most |
| --- | --- | --- | --- |
| registry wait | the domain's facet registry and the ready answer's granted names | the domain's connection agent, the one writer of both | its own deadline |
| settlement wait | the mint core's grants and the starting rows | the domain service | the mint core's deadline and the server row's boot timeout |
| rows held at boot | the catalogue's `answered`, the PCIe rows' ends and the `pcie` server's settlement | the device service decides; the domain service holds the rows and keeps the fallback | the PCIe row's boot timeout and 30 s more, or its end |

The three are kept apart because their facts differ. A facet in the
registry says the grant was installed; it does not say that a grant
failed, since a failed grant never reaches the registry, so a waiter
that must hear a failure at once uses the settlement wait, whose facts
include it. And a settled grant says nothing about the server's own
work: the system domain holds a PCIe incarnation's `pcie` facet whether
or not its report has been answered, so the hold at boot waits on the
answer the device service gives, never on a facet
([design-pcie.md](design-pcie.md#concurrency)).

**The registry wait.** The registry's value carries a generation that
each installation raises ([The registry](#facets-a-configured-domain-serves)),
which `erx_facets:generation/0` reads.

* `erx_facets:await(Name, Seen, Timeout)` answers `{ok, Pid}`, a facet's
  pid as `erx:cap/1` gives it, once the registry holds under `Name` a
  facet whose pid is not `Seen`: `none` for
  a first wait, or the pid of a facet the caller followed and whose
  server has ended. It answers `timeout` when `Timeout` passes first:
  milliseconds, `infinity` or `{abs, Deadline}`, as
  `gen_server:receive_response/2` takes it, one deadline over all its
  reads. It runs in the caller: it reads the generation and then the
  facets, answers at once when the registry holds such a facet, and
  otherwise asks for the generation after the one it read and reads
  again.
* `erx_facets:changed(Generation)` returns a request id, which the
  domain's connection agent answers `ok` once the registry's generation
  is past `Generation`, at once when it already is, and also when the
  same process asks again, which answers its older request. So `ok`
  says to read again, not that the registry changed, and a process
  keeps one request outstanding for every fact it waits on, since two
  would answer each other in turn. A process that
  must go on taking its own messages, as a `gen_server` does, takes the
  answer with `gen_server:check_response/2` and reads again.

No installation is missed. Everything a waiter decides on that the
agent writes, the facets and the ready answer's granted names, which
`erx:granted/0,1` read, changes only in an installation, and every
installation raises the generation. The ready answer is one
installation: the agent writes its granted names and then its facets,
and raises the generation even when it installs no facet. So a waiter
reads in one order: the generation, then the granted names if it uses
them, then the facets, and names in its request the generation it read
first. The agent compares that with the registry's when the request
arrives, so an installation after the waiter's first read answers the
request at once; at worst the waiter reads again and finds what it
already saw. Both orders are needed. The agent writes the names before
the installation raises the generation, so a generation past the
waiter's means the names are in place; the waiter reads the generation
first, so names it read from before the ready answer come with a
generation from before it, which the installation then answers. A
waiter that read the names first could pair names from before the ready
answer with a generation from after it, and wait for an installation
that never comes.

The agent keeps each unanswered request in a map from the asking pid to
its reply address and a monitor of that pid. After each installation it
answers every entry, removes its monitor and empties the map; a pid's
second request answers its first at once; and an entry goes at its
process's `'DOWN'`. So the map holds at most one entry for each living
process of the domain that has asked since the last installation. A
waiter whose deadline passed keeps its entry until the next
installation, its next request or its end, one entry still;
`gen_server:receive_response/2` drops the request's alias when its
timeout passes (`otp/lib/stdlib/src/gen.erl:415`), so the late answer
never reaches it.

The agent writes every installation, the system domain's included
([The registry](#facets-a-configured-domain-serves)), so every
installation is followed by its answers with no second party to tell.
In the system domain the domain service installs with
`erx_connections:grant/1`, which the system domain's agent takes only
as a call from its installer: the process that made itself the
installer with `erx_connections:become_installer/0`, which the domain
service does as it starts, before it grants anything. The first claim
is the only one: the service is never restarted, its end ending the
system domain, so a slip that claims before it ends the service's start
rather than installing in its place, and the agent, in the base runtime,
names nothing of the domain service. It takes the service's two other calls, `open_side/2` and
`close_side/2`, from its installer alone too, so no slip ends a domain's system connection. Any other process of its runtime is answered `badarg`; a message from another domain arrives in its
`{erx_origin, D, Msg}` envelope, which is no call the agent takes
(`erx_connections:serve/2`), and a domain's agent answers `grant`
`badarg`, as any call it does not take, since a domain's installations
come from the system domain over its connection. With the build check
`facet-registry-writers`, which refuses a call of `erx_facets:install/1`
outside the agent, no slip of another process of the system domain
installs a facet whose rights the manifest did not give. Code that runs
in the domain service's own process is the service's, and the cores it
calls return actions rather than install. The check is against a slip,
not a forgery: a call names its caller's pid itself, so a message
forged with the installer's pid installs, as a direct write of the
registry would, and the system domain runs only trusted code. The agent
makes no call to the domain service, which calls it to install, so
neither waits on the other.

A restart changes nothing the waiter relies on. The agent is never
restarted: its end ends the runtime (`erx_dist.erl:146`), so no waiter
outlives it. A waiter that restarts asks again, and its predecessor's
entry goes at the predecessor's `'DOWN'`. A server's restart installs
its successor's facet under the same name, a new generation, so a waiter that names the ended facet as `Seen`
is answered with the successor's. `{ok, Pid}` says what the registry
holds, not that the server lives, since a facet stays in the registry
after its server ends (`erx:cap/1`); a waiter that monitors the facet
hears of that end and waits again with it as `Seen`.

**The settlement wait.** A process of the system domain asks the domain
service one of three queries, a closed set, each with its own call. The
service keeps every asker in one list with its query, and answers each
once `erx_domain_mints:settled/3`, a pure function of the query, the
grants and the starting rows, no longer returns `wait`. Its three
clauses are `erx_domain_mints:in_place/3`, `server_settled/3` and
`system_grant/4` as they stand, behind one dispatcher, not new rules.
It evaluates the list at the points where those facts change: after each step of the mint core,
each stop for a boot timeout, and the release of the rows held at boot
whatever each held row's start then does. An end's step is evaluated
before the ended domain's successor starts (`erx_domain_srv:ended/4`), so
a waiter on the ended incarnation is answered by its end and never
waits on through the next one.

| Query | Asked with | Answer |
| --- | --- | --- |
| `namespace` | `erx_domain:system_namespace/0` | `ok` once each `files` grant to the system domain is installed, failed, or idle while its server is not starting |
| `{server, Name}` | `erx_domain:server_settled/1` | `ok` once no starting configured row serves `Name`, at once for a name no row serves |
| `{grant, Name, Id}` | `erx_domain:await_grant/2` | `{ok, Facet}`, `{error, failed}`, `{error, ended}` or `{error, unprovided}`, as [One incarnation's grant](#a-session-takes-the-console) states |

A starting row is one whose domain runs without having reported ready,
or a row held at boot, which stays starting until the release starts
it, whether that start succeeds or is refused. Each request is sent,
not waited on (`gen_server:send_request/2`), so the asker goes on taking its own
messages. The askers are the start table, the package service and the
device service, each asking once for each query it waits on (the start
table once for each display, the device service once for each report),
and each answer comes within the mint core's deadline and the server
row's boot timeout, so the list stays bounded. A session's start is answered by the namespace
rule for that session as part of the start itself, not as a query.
`server_settled/1` takes the name as a binary, as the start table holds
it, and the service answers `ok` at once for a name with no atom, since
no row serves it.

**The rows held at boot.** Which rows wait for the PCIe report, and
until when, is the device service's knowledge; the domain service holds
rows on its word and names no PCIe concept. Before it starts any
configured row, the domain service calls `erx_devices:held_at_boot(Rows)`
with the configured rows in boot order. The device service's PCIe
process answers `{Held, Fallback}`: the rows it holds, each row whose
units hold a `pci` device, never the PCIe row (the row holding a host
bridge that some `pci` device's place names), and none on a machine
with no PCIe row, decided by `erx_devices_pci_core:held/2` from the
catalogue alone; and the fallback, `{settled, <<"pcie">>, 30000}`, or
`none` when it holds nothing. The domain service starts the others in
boot order, counts each held row as starting, and starts the held rows
in boot order when the device service casts `erx_domain:release_held/0`,
or when the fallback's time has passed since its server settled; a
release with nothing held changes nothing. A call that fails, or gets
no answer within 5 s, holds nothing and is logged, as an unreadable
catalogue holds nothing. The PCIe process makes no call to the domain
service (its waits are sent requests and its release a cast), so the
call cannot deadlock.

The rows are released at the first of three events:

* the library's catalogue recording an answered report: a bridge's
  `answered` naming an incarnation, which the PCIe process writes
  before it sends a report's answer
  ([design-pcie.md](design-pcie.md#records)) and reads as it
  starts;
* the end of a domain whose origin is a PCIe row, which the domain
  service forwards with every end, before it starts the next
  incarnation (`erx_devices:domain_ended(Id, Origin)`), so a PCIe row
  that ends before it reports cannot hold the rows for as long as its
  restarts last;
* the fallback, which the domain service keeps beside the held rows:
  once the settlement wait finds the `pcie` server settled, at its
  usual points ([The settlement wait](#waiting-for-a-grant)), it arms
  one timer of 30 s, whose end releases the rows. The PCIe row is then
  ready, stopped for its boot timeout, ended with no restart, or refused
  its start, and 30 s covers a walk after a ready report. The fallback
  names a server and a time, no PCIe concept, and is armed once in a
  boot: nothing re-arms or extends it.

The first two are the device service's and the third the domain
service's, which is never restarted, so the bound holds however often
the device service's PCIe process restarts. That process keeps no
record of whether it released: a restarted process releases at once
when its predecessor answered a report, and otherwise waits for a
report's answer or a forwarded end as at boot, while the fallback runs
on unchanged. A release already made is made again harmlessly, since a
release with nothing held changes nothing. A PCIe row that will never
report, because its start was refused, it was stopped for its boot
timeout, or it was ready at its start with no report to make, releases
only through the fallback, 30 s after it settled: one release rule for
every path, at a bounded delay paid only when the boot has already gone
wrong.

A row the second or third event starts before a report is answered is
given what the catalogue confirms at its start, as every give is
([design-pcie.md](design-pcie.md#the-catalogue-and-gives)): nothing of
its `pci` devices when no report has been taken, and each function the
latest report confirmed `ready` when a report was taken but not
answered, as when its incarnation ended before the system domain held
its `pcie` facet. The give's own checks, a layout the latest report
confirmed and found `ready` on a bridge not marked `firmware_lost`, are
what make a give safe; the answer adds none. Its holder's requests then
meet `between` and `down`, as those of a holder that outlives a PCIe
incarnation do ([Devices](#devices), "The device service's PCIe
process"), until an incarnation's report is answered.

The `pci` and `pci_bus` services stay named in front of the domain
service (`erx_facet:serve/2`), since a facet ends with the process it
stands in front of and the domain service is never restarted, while the
device service's PCIe process, which their callbacks find by name at
each request, may be. That is where the facets live, not a PCIe
decision.

**Refusals and error results.**

| Call | Result | Means |
| --- | --- | --- |
| `erx_facets:await/3` | `timeout` | no facet of the name other than `Seen` was installed before the deadline; a grant that failed never reaches the registry, so this is also how a failure shows here |
| `erx_facets:await/3`, `changed/1` | `{error, noproc}` | the runtime is no node, so it has no agent and no configured domain grants it anything |
| `changed/1` | `{error, badarg}` | the generation is no non-negative integer, as for any call the agent does not take |
| settlement queries | as the query table | a query outside the closed set is answered `{error, badarg}` |
| `erx_devices:held_at_boot/1` | a call that fails | the domain service holds nothing and logs the reason |
| `erx_connections:grant/1` | `{error, badarg}` | asked of a domain's agent, whose installations come from the system domain only, or of the system domain's agent by any process but its installer |
| `erx_connections:become_installer/0` | `{error, badarg}` | another process claimed first, which ends the domain service's start; asked of a domain's agent |
| `changed/1`, `grant/1`, a settlement query, `release_held/0` | not acted on | sent from another domain: it arrives in its `{erx_origin, D, Msg}` envelope, which neither the agent nor the domain service takes as a call or a cast; the agent counts it in `dropped/0` |

**Verification.** Each case runs on the host; each seeded fault must
fail its case.

| Test | Passing case | Seeded fault |
| --- | --- | --- |
| `erx_connections_tests`, both agent loops | a `changed` request for the current generation is answered after the next installation, in a domain and in the system domain | the agent's answer after an installation dropped: the request is never answered within the test's deadline |
| same | an installation between the waiter's read and its request answers the request at once | the agent holds every request whatever its generation: the request waits for a second installation |
| same | a second request from one pid answers the first at once | the older entry overwritten unanswered: the first request is never answered |
| same | the agent monitors a waiting asker (`erlang:process_info(Agent, monitors)`) and no longer once it has answered it; an asker's end is taken, not counted in `dropped/0` | the asker not monitored: the agent's monitors lack it while it waits |
| same | `grant/1` from the domain service installs and is answered; the same request enveloped as from another domain, and `grant/1` asked of a domain's agent, install nothing | the system agent's clause matching the enveloped form: the peer's facet is installed |
| same | `grant/1`, the raw `{'$gen_call', From, {grant, Facets}}` and one whose `From` names no pid, from a process of the system domain's runtime that is not the installer, are answered `badarg` and install nothing, before any process is the installer and while one is; a second `become_installer/0` is refused, while the installer lives and after it has ended | the agent's check of its caller removed: the other process's facet is installed |
| `erx_facets` cases in the same suite | `await(Name, Old, T)` is not answered while the registry holds `Old`, and is answered with the successor's facet | the facet compared by presence alone: `await` answers with `Old` |
| same | `await(Name, none, 50)` answers `timeout`, and an installation after it leaves nothing in the caller's mailbox | the reply taken with a plain `receive` after a timer instead of `gen_server:receive_response/2`: the late `ok` lands in the mailbox |
| same | `{erx, granted}` holds the ready answer's names when its installation wakes a waiter | the names written after the installation: the woken waiter reads none and waits on |
| same | a ready answer that installs no facet still raises the generation | the generation raised only by a non-empty installation: a waiter on the names alone is never woken |
| `erx_domain_mints_tests` | `settled/3` answers each query as `in_place/3`, `server_settled/3` and `system_grant/4` decide, and a `{grant, Name, Id}` for an `Id` the core has not heard of is `{error, ended}` once the server row is not starting | the `{grant, Name, Id}` query matched by name alone: a predecessor's facet answers it; an unheard `Id` answered `wait` with the row not starting: the asker waits for good |
| `erx_domain_mints_srv_tests` | three askers, one of each query, are each answered at the step that settles their own query; the system domain's installation is acknowledged only after the agent's answer | every asker answered when any query settles: the `{grant, ...}` asker is answered before its incarnation's installation |
| same | a `{server, Name}` asker is answered at its row's end, before the row's restart starts | the list evaluated after the successor starts: the asker waits through the successor's boot |
| `erx_domain_tests` | a held row counts as starting: a session waiting on a `files` grant it serves is answered only after `release_held`, and a held row whose start is then refused settles at that release | held rows left out of the starting rows: the session is answered before its server starts, and the display a held row serves is settled before it starts |
| same | the fallback releases the held rows 30 s after the PCIe row's refused start, and 30 s after its stop for its boot timeout | a refused row counted as starting: the fallback is never armed and the rows stay held |
| same | the PCIe process restarts every 20 s, with no report and no forwarded end, and the held rows are still released 30 s after the `pcie` server settled | the fallback kept by the PCIe process and armed again at each of its starts: the release never comes within the test's deadline |
| same | the device service is asked once, with the rows in boot order; nothing held, or a call that fails, starts every row in boot order; the held row starts only at `release_held`, not at the boot | a held row started at boot: it starts with the free rows |
| `erx_devices_pci_core_tests` | `held/2` holds the rows with a `pci` device, never the PCIe row, none without one | the PCIe row held: the case fails, as a boot would wait for a report that cannot come |
| same | release once `answered` is written and at a PCIe row's forwarded end, each once | the release dropped at the forwarded end: a PCIe row that ends before reporting holds the rows until the fallback |
| `erx_devices_pci_tests` | a restarted PCIe process releases at its start when the library's `answered` names an incarnation, and otherwise not until one of the three events, with the restart before the intake, between the intake and the answer, and after the answer | the restart releasing at once: with no report taken, the held rows start and are given nothing |
| `dom_core_test` | a function a report confirmed `ready` is given before any report is answered, and a function no report confirmed is not | the give requiring `answered`: the confirmed function is not given, against what design-pcie states |
| `erx_input_follower_tests` | a tree is followed at the installation of its facet, and again at its server's re-grant, whether the old facet's `'DOWN'` comes before or after the new installation | the follower's `Seen` dropped: the dead facet is followed again at every installation of another name |
| same | the ready answer and the input facet installed between the follower's read of the generation and of the names, and again between the names and the facets: the tree is followed | the names read before the generation: the follower waits for an installation that never comes |
| same | a failed listing is tried again on the same grant with its monitor kept; a retry that comes after the grant's end is discarded | the retry kept after the end: a lister runs on the dead grant beside the successor's |
| `erx_ssh_dev_tests` | the daemon starts once `net` and `data` are both installed, in either order, with no timer; the import then has its own ten minutes from the daemon's start | the wait for `data` dropped: the daemon starts with `net` alone and cannot keep its host key |

On the target, the `pcie` QEMU suite boots with held rows; the `usb`
suite types on a keyboard behind `qemu-xhci`, a held row, and gains a
cell whose manifest allows the USB domain one restart, which kills the
domain's first incarnation once the first key has arrived, checks that
the display follows the new incarnation's input facet, and types a
second key that must arrive; the `apps` suite starts an app's session
through the namespace and start table's settlement; and the
`net_device` suite's reboot cell logs in over ssh past the daemon's
start at boot. Together they cover each wait on the target.

### Authority

Who holds what, with the rights each capability carries:

| Holder | Holds |
| --- | --- |
| the system domain | the initial capabilities, the root budget (`ALLOC`, `SPACES`, `CODE`, `CARVE`), the root resource (`CARVE`, `POWER`, `TRACE`, `ENTROPY`, `INSPECT`) and the boot image (`SYSTEM`) among them; every principal's budget and every domain's space, own and outer budgets and group with every right; every object it created for a domain; every connection's objects and child budgets, with the only `DESTROY`; every device's objects until it gives them, and their `DESTROY` always; every unconfined device's memory; the fault gate (bound to the fault thread); the sealing page; the time page; `CONFIGURE` on the `system` group, the `users` group, every principal group and every domain group; on another domain's processes, only what that domain's runtime exports to it, as any peer ([design-domains.md](design-domains.md#authority)) |
| a domain | its own objects; its own budget (`ALLOC`, and `SPACES` only where the system domain allows it, [Sub-spaces](#sub-spaces)); its group (`ATTACH`, `SIGNAL`) and the group's shared areas; for each of its connections: its own side (`READ`, `WRITE`, `MAP`), the peer's side (`READ`, `MAP`), the peer's bell (`TRIGGER`) and, where the connection has a pixel area, the area (`READ`, `WRITE`, `MAP` for the party that writes it, `READ`, `MAP` for its reader), and no capability to its own bell, which the system domain bound to the domain's group and whose label the domain knows; the time page (`READ`, `MAP`); its release slice; its crash area; its boot information page |
| a domain that holds a device | as a domain, plus the IRQ objects of the device's lines or MSIs (`BIND`, `ACK`), which its driver binds to the domain's group; its DMA window (`MAP`, `BIND`), or for an unconfined device its contiguous memory (`READ`, `WRITE`, `MAP`, `PHYS`); its register windows' memory objects (`READ`, `WRITE`, `MAP`), none of them for a device of no kind but the IRQ object of a line a device of a kind in its unit names; for the block device's domain and the slot writer, a read-only view of the machine page; all as the domain's creation gave them |
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
guarantee ([design-kernel.md](design-kernel.md#budgets)), and so is the
budget the manifest's `apps` row gives all apps to share, from which
each app principal's budget is carved as a wall when its session starts
and destroyed when that session retires
([design-packaging.md](design-packaging.md#an-apps-principal)); each domain's
two budgets from its principal's, side by side and each a wall:
its own budget at its spec's `memory`, and its outer
budget at its spec's `outer`, which the policy sizes from the
domain's admission: a child budget for its connection to the system
domain, holding both of that connection's lanes, the one it reads at its
lane size with the control table and the one the system domain reads at
`system_lane`, with both bells; a child budget for each connection its
`connections` quota allows, holding the lane it reads at its lane size
and its bell; for a display, the pixel areas its clients can make it
hold, the sum property 18 computes over the facet rows of its
`windows` services; each child's own records; and its crash area
([Ending a domain](#ending-a-domain)). An
introduction carves a child from the reader's outer budget, which the
policy sized for it, so an introduction fails with `ERX_ENOMEM` only
beyond the domain's own quota. Every domain budget the domain library
carves, own, outer and the connection children, and every manifest
principal's budget, the `apps` budget included, is a wall, so the kernel
admits or refuses every charge of a domain's at the domain's own budget,
counts none of it against another domain's, no principal of the manifest
spends beyond its own, and a domain's memory depends on nothing outside
it but the kernel (K32,
[design-kernel.md](design-kernel.md#budgets)). An app principal's
budget is a wall carved from the `apps` budget for each of its sessions
and destroyed at that session's retire; it holds nothing but that
session's walls, so apps share the `apps` wall's memory and none of it
reaches past that wall. The library carves no elastic budget for a
domain or a principal; and the library's grant
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
the system domain. This section owns which domain holds a device, how it
is given and what its holder's drivers may do;
[design-shared-devices.md](design-shared-devices.md) owns the unit rule
and the sharing of a page or a line inside a domain. At boot the device
service reads the root resource's device list through `erx_object_info`
and builds a catalogue: path, compatible string, register ranges,
interrupt lines, and whether a device is confined
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
A catalogue entry's index is its manifest device row; on erXos's kernel
the carve finds the device in the root resource by the entry's
device-tree path, not by its position in the list.

Each device goes to the one domain the manifest names for it, as part of
that domain's creation: for each unit the manifest places on the
configured row, `erx_dom_plan_configured` adds a **give**, planned by
`erx_dom_plan_unit_give` and applied whole by one step of the creation's
plan. A give carves the resources of the unit's devices and creates from
the holder's own budget the unit's register windows, its IRQ objects and,
for each confined device, its DMA window, one object per page run and per
line as [the unit rule](design-shared-devices.md#the-unit-rule) says; for
an unconfined device it gives the device's contiguous memory instead
(What a device keeps, below); a device of no kind gets only its
resource. It then gives the holder its capabilities
([Authority](#authority)). A give is its own plan, not steps in the
creation's, because every unit's objects use the same object numbers and
so cannot share the creation's object namespace; a creation holds up to
eight. No device service has to give at the right moment. The planner
gives a device only to a domain of the row its unit is placed on, and
refuses a give with `ERX_EBUSY` while a living domain holds the device,
so a second domain of the row is refused while the first lives. On
success the device's record names the holder and its objects; at the
holder's end the window, line, resource and DMA objects are destroyed
and the record names no holder. `erx_domain_lib:devices/0` returns the
catalogue with each entry's holder: `{ok, [#{index, unit, row, role,
holder}]}`, where `row` is a configured row or `system`, `role` is
`block`, `net` or `none`, and `holder` is a domain id, `system` or
`none`. The `PHYS` right on contiguous memory goes only to the domain of
the device the memory is for, and is stripped from every other
capability to that memory. A device the manifest does not name goes to
no domain, and a PCIe function among them keeps its bus mastering off.

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
8), so a host link the boot accepts is never the console's UART, whatever
the device tree's `serialN` aliases say.

**Firmware requests.** The device service is the one sender of the
firmware's mailbox requests after boot, `erx_firmware_request`
([design-usb.md](design-usb.md#the-vl805s-firmware)): the VL805's
notification, which the PCIe domain's bridge driver asks for with
`pci_bus:firmware/1`, answered `ok` for `ERX_OK` and `{error, Status}`
naming any other status ([design-pcie.md](design-pcie.md#facets));
the Bluetooth line's power for the line service
([design-bluetooth.md](design-bluetooth.md#the-power-line)); and the
board sensors' readings for the sensor driver, which asks for the
machine's rows with `erx_devices:firmware_rows(machine)`, their
readings' names in row order as the domain library's boot view reads
them from the manifest, empty on a platform with none, and then for one
reading at a time with `erx_devices:firmware_read(Reading)`, answered
`{ok, Answer}` with the answer's bytes, `{error, Status}` with the
kernel call's status, or `{error, enotsup}` for a `Reading` that is
not a machine row of the platform
([design-board-sensors.md](design-board-sensors.md#the-sensor-driver)).
A request may wait in the kernel up to its 1 s deadline, and a process
running a
dirty NIF cannot run its receive loop, so the work is split as the
stopgap's littlefs glue splits it
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
The device service's process takes every request into a queue and
never waits on the kernel. Its **firmware worker** (`erx_firmware_worker`),
a process linked to it, alone calls the domain library's firmware entries,
and is handed the next request only after the last one's answer. They are
`erx_domain_lib:firmware/2`, the one library call over the firmware's
requests, which sends the row the manifest lists for what it is asked:
`firmware(Bridge, bridge)`, a host bridge's notification, its first
row, with the resource the bridge's device record holds for its give;
`firmware(Device, {power, Phase})`, a power line's phase, for a device
whose manifest row carries the line's times; and a reading, `firmware(machine, Index)`. The library
offers each only to such a row and refuses any other with `enotsup`.
Those entries are dirty I/O NIFs, since the kernel call waits and an executor's would
answer `ERX_EWOULDBLOCK`. So two requests never meet in the kernel,
and the device service answers the watchdog's liveness call ([Boot](#boot)) and every
other call while a request waits. Each entry runs outside the
library's lock and reads only records the view wrote as it was built;
a bridge's status then goes to its catalogue under the lock, where an
`ERX_ETIMEDOUT` marks the bridge `firmware_lost`
([design-pcie.md](design-pcie.md#the-catalogue-and-gives)), so no
other entry, and no other service, waits on the mailbox. The library's intake takes every function of a marked bridge
as `not_ready`, so a bridge whose notification timed out gives none of
its functions for the rest of the boot, whatever a late answer or a
later start of the PCIe domain finds. The queue holds at most one
request per caller: the PCIe domain asks through its `pci_bus` facet, whose grant takes one request
in flight and refuses another with `{error, busy}`, and the system
domain's own callers, the sensor driver and the line service, each ask
the next only after the last one's answer. The worker reads its
reductions around each call and returns them with the answer, and the
runtime charges a dirty I/O call its elapsed time, so a facet's
account holds each request at the time the mailbox took
([design-board-sensors.md](design-board-sensors.md#concurrency-and-failure)).
The worker's end ends the
device service by their link, and its supervisor restarts both; a call
the old worker left in the kernel finishes within its deadline, and a
request of the new worker that meets it answers `ERX_EBUSY`, which
fails that request alone.

**Which domain holds a device is the manifest's**, and nothing else: a
device goes where its capabilities are installed, and devices are given by
unit (Units, below). The default manifests put the block device in the
storage domain, the network device in the network domain, the TPM, with
the controller of the serial bus it sits on where a board offers it that
way, in the vault's domain, the PCIe configuration window, where the
platform has a bridge erXos drives, in the **PCIe domain**, `pcie`, which
runs the PCIe enumerator and holds nothing else, the console's and the
host link's UART units in the system domain (The console, below), and
every other device the kernel does not keep (I2C, the other SPI
controllers, GPIO where it does not set the console's pins, and
whatever else the board offers) in one **devices domain**, which is not
in the trusted base. A pin controller that sets the function of the
console's or the host link's pins is never the devices domain's
(property 8). On every platform,
the unit of a device whose DMA is unconfined, so that it reaches all
memory, gets a domain of its own in a release build's manifest, holding
that unit and nothing else, so the domains that parse hostile media and
packets never hold a device that is the whole machine (property 9): on
QEMU `virt`, where the IOMMU confines PCIe functions alone, a release
build's manifest therefore gives the block and network devices as
virtio-pci functions, and each unit of virtio-mmio transports it keeps a
domain of its own; on the boards, which confine nothing, every DMA
device's unit has one
([design-platforms.md](design-platforms.md#qemu-virt)). A
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
only through a connected session's tty. Where the console's or the host
link's unit holds other devices, as on the Raspberry Pi 4, the system
domain holds them too and drives none of them
([design-shared-devices.md](design-shared-devices.md#context)). The
kernel shares the console's UART in time and keeps no register page of it:
it writes the UART by polling, at the address its platform build fixes
and through a mapping it makes for those writes, during its boot and at
a panic or the machine's end, and the driver owns it otherwise
([design-kernel.md](design-kernel.md#console-log-and-panic)).

**On Fiasco.** The device service, the manifest's placement, the
drivers and their supervisors are the same code. In a give, the domain
library creates the unit's register windows, its lines' IRQ objects and,
at the first give, each device's contiguous memory, all in the root,
from the catalogue entry at the give's index (neither backend has a
resource object, so the give's resource step makes nothing), and passes
them to the holding domain, whose driver maps the window and binds the
line to its own group, so the line's deliveries reach that task's
readiness dispatcher; no device object is created from a task other than
the root ([Device records](design-fiasco.md#device-records)). At the
holder's end the library deletes the window's and the line's objects and
keeps the contiguous memory for the restarted holder. Fiasco lists no
IOMMU stream, and QEMU `virt`, as the harness starts it, attaches its
devices over virtio-mmio, so every DMA device there is unconfined: the
domain library's boot view, which the manifest check builds too,
refuses a device marked confined, as it refuses a unit split across
rows, so such a manifest fails the build. The development manifest gives
the block device to the storage domain, which runs the block driver and
the file systems (littlefs as a NIF behind the `erx_fs` seam), the
network device to the network domain, and virtio-gpu and virtio-input to
a display domain where it configures one; the system domain holds only
the console's and the host link's UARTs. The manifest check accepts these
unconfined devices in a development build, and property 9 refuses them
in a release manifest. In the storage domain a driver's end ends the
domain, whose restart gives the device back; other drivers restart under
their supervisors. Every driver's DMA reaches all memory, so a driver,
or a domain that parses hostile bytes beside one, can reach every domain
through its device; DMA windows, MSIs and the lifetime of device buffers
are erXos's kernel's
([Downsides against erXos's kernel](design-fiasco.md#downsides-against-erxoss-kernel)),
and moving a device to virtio-pci behind the IOMMU changes its device
record and its DMA profile, not its driver.

#### Drivers

A **driver** is an Erlang process under a supervisor in the domain that
holds its device, written against the **device NIF**, `erx_device`, the
one C beneath it ([design-runtime.md](design-runtime.md#the-device-nif)).
Drivers come in one application per device class under `erlang/apps/`,
`erx_uart` for the UARTs and `erx_fb` for the displays; only their modules and `erx_device` itself
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
  never undoes a successor's binding. A line that two devices of a unit
  name is shared and is bound once, by the line's **owner**, which the
  drivers join instead of binding, all through `erx_irq_line`, the one
  module that binds or acknowledges a line
  ([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain)).
  No dirty scheduler blocks in an
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
  status register and reading it back as zero; a PCIe function by its
  own controller's reset once its `pci` facet's `open` has turned bus
  mastering off and memory space on, or, when its registers cannot
  reset it, by the facet's `reset`, a function-level reset through the
  PCIe enumerator where the function offers one; an SD host
  controller by its software reset), and the NIF installs the device's
  queues only after that reset; a virtio device's reset is the NIF's
  own, the first step of `negotiate/2`, and the NIF posts nothing to a
  device before it, so a driver that starts on a device another driver
  or the loader left running installs no buffer or descriptor before the
  reset has retired every address the device may hold; a native shim
  keeps the same order (Native shims, below). What a device the loader
  left running writes before that reset is a [Medium] security residual
  ([design-platforms.md](design-platforms.md#dma)). A driver process that crashes is restarted
  by its supervisor and resets the device again. Its pools and queues stay
  in the NIF's record of the device meanwhile, and the NIF releases them
  only at the new driver's `negotiate/2`. A PCIe function's driver, after
  its reset, asks the device service through its `pci` facet to have
  the enumerator enable the function's bus mastering, the same gate as
  at its first start (PCIe, below); a reset its registers cannot do it
  asks for through the same facet
  ([design-pcie.md](design-pcie.md#who-programs-what-and-when)). The reset is the
  driver's because the driver alone knows its device; the system domain
  never touches the registers of a device another domain holds.

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
single-threaded C under `liberx` and needs no runtime of its own. It
writes its device's addresses itself, so it takes the device NIF's
`negotiate/2` contract as its own: its owner's first command to it is
`negotiate`, whose first write to the device is the device's reset and
which installs no buffer or descriptor until the device's idle report,
and it refuses every other command until a `negotiate` has succeeded
([design-platforms.md](design-platforms.md#dma), rule 1).

**PCIe.** The host bridge is a device like any other, and its driver, the
**PCIe enumerator**, is an Erlang process in the PCIe domain, which holds
the bridge's configuration window (ECAM, or the BCM2711's registers with
their index and data access) as its register window and nothing else, so
the enumerator alone reads and writes configuration space. It walks the
bus and parses configuration space in Erlang, with binary matching and a
fuzz target over configuration snapshots, since every parser of
untrusted input has one, places the BARs, and reports each function,
with its BARs, capabilities and place, to the device service, which
keeps it in the catalogue as the function's layout; each function's
configuration is the projection of that layout and of the setting its
holder asked for, which the domain library keeps
([design-pcie.md](design-pcie.md)). To give a function
to the domain the manifest names for it, the library plans the give with
`erx_dom_plan_unit_give`, whose plan carves the function's BARs as register
windows after checking that each lies inside the bridge's windows from
the device tree and overlaps no other device, creates its MSIs as IRQ
objects on the MSI frame, whose doorbell address and data the result
names (functions interrupt by MSI or MSI-X: a bridge's INTx lines,
which the functions behind it share, go to no domain, and a function that
offers neither is given with no interrupt, except behind a closed
bridge, the Raspberry Pi 4's, whose row's INTx line is a line of its
unit, given as a device-tree unit's line is,
[design-shared-devices.md](design-shared-devices.md#the-unit-rule)), and creates its DMA window on the stream that the device tree's
`iommu-map` gives its requester id, when the function lies on one of the
machine's fixed buses
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles));
a function elsewhere is unconfined, and its domain is in the trusted base.
The PCIe domain is in the trusted base whole on every platform:
configuration space turns on any function's bus mastering, which for an
unconfined function reaches all memory. It holds nothing but the
configuration window, so no other driver shares that trust and the
devices domain stays outside it (property 3). The give enables nothing:
the function's driver asks the device service, through its `pci` facet,
to have the enumerator enable memory space and program the route as it
starts, and bus mastering once it has reset its device, and at the
holder's end the device service has the function turned off, so a
function's bus mastering is raised only for a living holder that asked
(Resets, above;
[design-pcie.md](design-pcie.md#who-programs-what-and-when)). A
confined function cannot reach memory before its binding: the
kernel sets the IOMMU to abort DMA from every stream not bound to a DMA
window ([design-kernel.md](design-kernel.md#dma-and-the-iommu)). The
PCIe domain restarts like any configured domain; a restart takes the
targets from the domain library, re-reads configuration space, keeps
every function that reads as its setting and turns every other one off
with its layout written, so it changes no running function and raises
none ([design-pcie.md](design-pcie.md#the-plan)). The kernel keeps the
register pages of the devices of `hw/kernel_devices.txt`; the console's
UART it only writes by polling (The console, above).

**The device service's PCIe process.** One process of the device
service writes the library's settings and calls the PCIe domain's
`pcie` facet, so the settings the library holds and those sent are
written in one order. Its decisions are a pure core,
`erx_devices_pci_core`, a state machine over three states: `between`,
no PCIe incarnation's report answered since the last one ended, in
which a holder's request waits and a holder's end lowers the setting in
the library and sends nothing; `synced`, the current incarnation's
report answered, in which requests are handled and a holder's end
lowers the setting and then sends it; and `down`, 5 s in `between`, in
which a request is answered `{error, unavailable}` at once. It keeps no
monitor: the domain service forwards every domain's end, with its
origin, before it starts that domain's next incarnation
(`erx_devices:domain_ended/2`); the answered incarnation's end moves
the core to `between`, and a holder's end turns that holder's
functions' settings `off`. It answers a report only once the system domain holds
the reporting incarnation's `pcie` facet, which it asks for with
`erx_domain:await_grant/2`
([A session takes the console](#a-session-takes-the-console)), writes
that incarnation into the bridges' `answered` before it sends the
answer, and from then on calls `pcie` on the facet that request
returned. A restarted process reads every setting, holder and
`answered` from the library, and begins in
`synced` only when `answered` names the incarnation that still holds
its bridges ([design-pcie.md](design-pcie.md#concurrency)).

**The hold at boot.** A configured row whose units hold a `pci` device
starts only once the device service has answered the boot's first
report, and the rows without one start in boot order meanwhile. The
device service decides which rows are held and when they are released:
once the catalogue records an answered report or at a PCIe row's end,
and names the fallback the domain service keeps, 30 s after the PCIe
row has settled. The domain service holds the rows it names, counts
them as starting and starts them on the device service's word or at
that fallback
([Waiting for a grant](#waiting-for-a-grant), "The rows held at
boot"). A row started before a report is answered is given what the
catalogue confirms, as every give is: nothing of its `pci` devices
before any report has been taken
([design-pcie.md](design-pcie.md#the-catalogue-and-gives)).

**Units.** Devices that cannot be given apart, because they share a
register page or an interrupt line or sit behind one PCIe function, form
one **unit**, given whole to one domain, so no page and no line is ever
held by two domains; another domain reaches a sub-device's function only
through a file tree or a facet its holder serves
([the unit rule](design-shared-devices.md#the-unit-rule)). The manifest
gives devices by unit, and the check proves each unit given whole
(property 1); the domain library's boot view, which the manifest check
runs too, refuses a manifest whose own units split a page or a line. At
boot the device service computes the units again from the catalogue and
the kernel's listing, so no list of units is trusted unchecked, and gives
a unit that the machine splits across the manifest's domains to no
domain, with a diagnostic. A unit's holder's drivers reset its devices
together, and a give places a device only on a domain of the configured
row the manifest places its unit on, never on a requested or session
domain or another row's. A USB device is a sub-device of its host
controller's unit: its registers are the controller's, its interrupts
arrive on the controller's, and it is reached only through transfers the
controller runs. It enters no catalogue, is named in no manifest row and
is given to no domain; other domains see only the places its
controller's domain serves, fixed when they are configured, an input
number's file in its input tree and a drive's grant
([design-usb.md](design-usb.md#hotplug-ends-at-the-controllers-domain)).
A PCIe function whose BAR carries several peripherals at fixed offsets,
as RP1's does, has **parts**: device rows (selector `part`) that the
packer writes after the function's row from the platform record, each
naming its function, a block of the BAR and at most one MSI-X entry, so
a part is always in its function's unit and its driver opens a record
like any other ([design-rp1.md](design-rp1.md#the-parts)).

**Partition windows.** The block driver serves each partition of its
medium as a window ([design-storage.md](design-storage.md#data-model)).
Where each partition lies comes only from the medium layout of the ABI
file. The device service gives the slots' boot and system partitions,
the boot-selection record and the reset count to the slot writer alone,
derived from that layout, and
the manifest assigns each data partition by its role in the layout, never
by sectors, to its storage domain, and each drive to the media domain,
which serves its volumes ([design-drives.md](design-drives.md)). The holder of the manifest's `system`
window, the storage domain that serves `system`, gets one read-only
window on the system partition of the slot that the boot value names;
when the boot value is `unknown`, it gets none
([design-storage.md](design-storage.md#the-system-tree)). No other domain
gets a window on a slot: a domain that reads the `system` tree holds a
read-only grant of it, and an app's session mounts its package with the
layout the domain service hands it in the app's record, which the file
check built
([design-packaging.md](design-packaging.md#an-apps-session)). A
window is a grant of the block driver's domain, which the device service
introduces to the window's holder over a connection once the holder
runs. The slot
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
`name TAB value` line each in the `/proc` format, and for a PCIe
function also its place, identity, BARs, state, mode and route, and
for a bridge `firmware lost` when that mark is set
([design-pcie.md](design-pcie.md#records)). The tree is read-only.
The device service's control facet serves a second tree of the same
shape, mounted at `/dev` instead for the sessions that hold that facet,
whose device directories also hold `ctl`: a write of one word, `stop`,
`start` or `reset`, with or without its newline, at most 16 bytes, acts
on that device through the facet, by asking the holder's driver
supervisor to stop, start or restart the driver process
([The holder's driver-control facet](#the-holders-driver-control-facet)),
and any other write fails with
`einval`. The holder's facet is found by its interface, the
driver-control service of the configured row the device is placed on;
while no domain of that row holds the device, or its facet is not
installed, a write fails with `enxio`. A start of a running driver fails
with `ebusy`, and a driver that did not stop or start, or a call that
did not complete, such as one to the facet of a holder that has ended
and not yet restarted, with `eio`. The facet call is the control tree's
bounded work, a call to another service whose design names its
deadline as the bound
([design-files.md](design-files.md#serving-the-erx_fs-behaviour),
"Waiting requests"), so the tree has no keeper: the call waits at most
`erx_driver_ctl`'s 30 s deadline, the bound for which the tree's grant
may stop answering its other requests, its clunks and flushes among
them. Every holder of the grant holds the facet's control, so a write
that holds the grant holds only requests of parties who could ask for
that stop or start themselves. A write whose call times out answers
`eio` for an operation the facet may still complete. Holding the path is
holding the facet, as for every file server
([design.md](design.md#decisions)), so no write is checked against who
wrote it, and the tree changes nothing the control facet could not change.
Like every file grant, the tree's grant acts for whoever holds its pid, so
a session that hands it on shares the facet's control with the receiver
([design-files.md](design-files.md#narrowing-for-a-program)); the facet
serves the tree from a process linked to it, so revoking the facet ends
the tree and every fid on it, and no grant of the tree outlives the facet.
Like every facet that serves a file tree, each of the two installs as its
pid with the rights of its facet row; a namespace entry names the facet
and the tree its mount's options give, and resolves with the lesser of
its own rights and the facet's, and the grant answers `enoent` to an attach that names any other tree
([design-files.md](design-files.md#namespaces)).

#### The holder's driver-control facet

A domain that holds a unit serves the system domain a facet of the
driver-control interface (`abi/services/driver_control.txt`), under a
name of its own, such as the storage domain's `storage_ctl`: the system
domain's registry holds each facet under its service's name, so one name
per holder keeps the holders apart, and one facet covers every unit its
holder holds. Its requests are `{stop | start | restart, Unit}`, with
`Unit` the unit's manifest name. `stop` ends the unit's driver process
through the holder's driver supervisor, which then leaves it stopped;
`start` starts a stopped one; `restart` does both. The answer is `ok`,
`{error, running}` for a start of a running driver, or `{error, failed}`
when the driver did not start, which the driver's own log line explains;
a unit the holder does not name, and a request of any other shape, is
refused with `{error, badarg}`. The facet reaches only the driver
processes of its holder's own units, through the supervisor that already
restarts them after a crash, so it adds no authority over a device.
Unlike a crash, a stop holds the driver down until a start: in between
the driver serves nothing, a request it was serving fails as at its
crash, and what its clients do with that failure is theirs, as for
littlefs over the block driver ([design-storage.md](design-storage.md)).

Only the system domain holds such a facet. The manifest check proves it
(property 8) from the service's interface, not from its name, and the
holder's mint refuses a mint request that names any other grantee, so a
manifest row the check let through still grants nothing. The system
shell calls it through `erx:cap/1`, as
`erx_driver_ctl:restart(erx:cap(storage_ctl), block)`, and the device
service's control facet and its `/dev` tree are fronts over it. A unit
name in a request is only a key of the holder's table of its units, so a
request makes no atom and names no process. One module, `erx_driver_ctl`,
is both sides: the grantee's calls, and the mint and facet each holder
starts with its own table of units.

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

A measurement taken on Fiasco admits no native driver. There
an interrupt reaches its driver through a dispatcher thread, and its
acknowledgement, like most kernel calls, is a request to the root
service, which serves the whole machine on one thread
([design-fiasco.md](design-fiasco.md#interrupts-and-readiness)), so an
Erlang driver that misses a device's timing there may be missing
Fiasco's, and a shim admitted on that number would work around
Fiasco rather than the device. Such a measurement is recorded with
the kernel named, and the row's decision waits for the same measurement on
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
| domain service, `erx_domain_srv` | creates the manifest's domains in its boot order and every other domain; introduces, stops and destroys domains through the domain library; keeps domain pids, names, connections and death records; restarts configured domains; runs the ordered end and serves the `machine` tree, through which a session that holds its grant asks for one | [Creating a domain](#creating-a-domain), [Ending a domain](#ending-a-domain), [A session's request](#a-sessions-request) |
| principal service, `erx_principal` | principals, credentials, sessions and quotas, its registry of app principals a value the domain service keeps, which no restart loses within a boot ([design-packaging.md](design-packaging.md#an-apps-principal)); each session's credentials facet, with `login_keys`, `add_login_key` and `del_login_key` on that session's own principal's SSH login keys | [design-domains.md](design-domains.md#principals-sessions-and-quotas), [design-ssh.md](design-ssh.md#login-keys) |
| facets, `erx_facet` | one process per grant of a service to a domain; admission per client | [design-domains.md](design-domains.md#facets) |
| resource policy, `erx_policy` | the group tree, grants, capacity, budgets, lane sizes | [Resource policy](#resource-policy) |
| device service, `erx_devices` | the device catalogue, each device given to the domain the manifest names, `/dev` | [Devices](#devices) |
| watchdog, `erx_watchdog` | pets the kernel's watchdog every period, at priority `max`, once every service it lists has answered a liveness call | [Boot](#boot) |
| clock service, `erx_clock` | the wall clock's one setter: takes ntpd's samples and root's sets through the `clock` facet, whose rows grant ntpd's template `sample` alone and root's template `set` alone ([design-time.md](design-time.md#who-may-set-it)), decides each step with `erx_clock_core`, sets the time page through `erx_clock_nif`, and reports `/proc/time` | [design-time.md](design-time.md) |
| console service, `erx_console` | the two console lines: the UART over its driver in the system domain and the host-link port's bytes; each line's menu and login prompt, the connection of sessions' ttys, and the system-shell facet, which it grants to a login at a secure line, holds for that login and ends with it | [Devices](#devices), [design-live.md](design-live.md#the-console) |
| inspector, `erx_inspector` | one schema over kernel, service and runtime reports, the previous boot's crash record included; the `inspect` service, whose facets the domain service mints with the scope `erx_domain_core:inspect_scope/4` gives, and the questions to each domain's inspection agent | [design-live.md](design-live.md#inspection), [design-live.md](design-live.md#the-inspect-service) |
| tracer, `erx_tracer` | trace sessions and the kernel's trace | [design-live.md](design-live.md#tracing) |
| host link, `erx_hostlink` | sessions with the development host | [design-live.md](design-live.md#the-host-link) |
| line service, `erx_line` | one line tree, `data` and `ctl`, for each grant of the `line` interface, over the driver of the device its `device` parameter names, a UART or a virtio console, in that line's group; it moves the bytes and parses none, and its `ctl` takes one word, `reset`, which turns the line's device off through the device service, starts the driver afresh and turns the device on; a driver that does not start leaves the line broken with no driver, so it ends no process | [design-bluetooth.md](design-bluetooth.md#the-controllers-line) |
| pin driver, `erx_pins` | on a board whose pin controller the system domain holds: puts every device that has one state in it, from the board's pin table, before the domain service and the line service start; when it cannot set a device, the release boots its rescue configuration, or does not boot when that configuration uses the device; serves the `gpio` and `pins` trees | [design-pinctrl.md](design-pinctrl.md#placement-and-boot-order) |
| code service, `erx_code` | the code store, code facets, overlays, the install facet | [design-live.md](design-live.md#the-code-store) |
| update service, `erx_update` | system updates, through the slot writer: writing the spare slot, the trial, the commit and the fallback | [design-storage.md](design-storage.md#system-updates) |
| start service, `erx_starter` | the start table, the manifest's `start` rows with the machine's `start.conf` over them, and the supervisor and keeper of each row; its tree, `start`; the package process and its `apps` tree ([design-packaging.md](design-packaging.md#apps)) | [design-apps.md](design-apps.md) |
| file trees, `erx_procfs` and the device service's tree | the system domain's own `/proc`, the system shell's and the host link's, as every domain runs one for itself; `/dev` for administrators | [design-live.md](design-live.md#the-proc-tree), [Devices](#devices) |
| login service, `erx_login` | the `login` facet every front end holds, the SSH domain, the web domain and the phone console: cookies for SSH's key exchanges, key and passphrase logins, each starting a session of the principal and minting the front end's line; a login belongs to the front end's process that made it, and its session ends with that process | [design-login.md](design-login.md) |
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
  record as for any facet. The introduction carries the grant's limits.
  The three limits the client's funnel applies to a frame, `max_frame`,
  `max_message_heap` and `funnel_depth`, each have a floor in a domain
  that holds `net`, which the client side checks against its own
  runtime before it sends a request, answering `{error, enobufs}`
  itself for what it could not carry
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas),
  [design-network-stack.md](design-network-stack.md#message-sizes)).
  The `netadmin` facet, which configures interfaces and reads every
  client's statistics, is granted to administrators only.
* **The system domain holds no `net` grant** (property 15). The
  trusted base parses no network traffic, its own or a client's, and
  takes no stream of a socket into its queues; what in it would need
  the network runs in a service domain instead. Root's session at the
  UART holds `net`, so `ifconfig`, `ping`, `host` and the programs root
  runs reach the network from there, not from the system shell
  ([design-network-stack.md](design-network-stack.md#the-grant)).
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
domain's end, and never for another principal within the boot. A name
binds for the boot rather than being assigned to a principal in the
manifest, so naming needs no administration, at the cost that a name
need not mean the same principal across boots. The
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
digits, or for `root`, is refused with `{error, name_taken}`, so no
principal takes another's pooled names. The manifest check proves that every principal's
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

* **A partition of its own.** The vault's files
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
  stopgap, and nothing on the partition is ever converted: the installation that brings erXos's F2FS creates the
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
  `{ssh_host, Name}`, `{tls_client, Name}`, `{tls_server, Name}`,
  `{token, Service}` or `{state, Service}` ([State slots](#state-slots)).
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
  UART, the host link or a network connection, which a front end's
  login names as its configured domain's name and the peer it reports
  ([design-login.md](design-login.md#operations)). The principal service
  holds passphrases in its queue and heap as it passes them on, so it
  sets `process_flag(sensitive, true)` before it registers and reports
  through `erx_report:status/2`
  ([design-login.md](design-login.md#secrets)). The
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
    The keys are the principal's, not one session's: a session started
    by an SSH key login opens nothing, uses the keys while another
    session of the principal holds them open, and holds them open
    itself while it lives, as every session does
    ([design-ssh.md](design-ssh.md#logging-in)).
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
  The SSH host key `{ssh_host, "ssh"}` is made at the first request for
  it after an installation. Its public blob is no secret: the vault gives
  it to its host key facet's grantee, whose daemon sends it to clients,
  and to the system domain, whose login facet reads it when it starts
  and compares it with the host key in each key login's exchange
  ([design-ssh.md](design-ssh.md#logging-in)).
* **Login keys.** Each principal's SSH login keys, a list of Ed25519
  public key blobs, live in a **login-key section** of the principal's
  file, sealed with AES-256-GCM under a key that HKDF-SHA-256 derives from
  the machine's master key with a label naming the principal and the
  section, and binding as associated data the file's format version and
  the principal. So the vault reads a principal's login keys at any time,
  without its passphrase, and answers them to the principal service for
  the login facet's checks; a section copied into another principal's
  file does not open; under `device` or `tpm` nothing that writes the
  medium can add a key, and under `none` whoever writes the medium can,
  as machine keys are as readable as it; and the keys go with the file
  when it is removed. The vault changes the section only through the
  file's owner (below) and only at the principal service's request
  through a session's credentials facet: adding a key opens the master
  key with the passphrase the session gives, as changing a passphrase
  does, under the limits and the queue of the terminal the session's
  login came from, so a session left open cannot add a way in; removing
  one needs no passphrase. The principal service decodes each blob with
  the login facet's decoder and refuses one that does not decode or
  whose key is of small order, so the vault parses no SSH structure
  ([design-ssh.md](design-ssh.md#login-keys)).
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

#### State slots

A service that must use a machine secret in clear, because its protocol
hands the secret to hardware or sends it whole, keeps it in a **state
slot**: one opaque blob of the purpose `{state, Service}`, which the
vault stores and never parses. Bluetooth's bonds, whose keys the
controller needs in each LE Long Term Key Request Reply
([design-bluetooth.md](design-bluetooth.md#bonds-and-the-store)), and
the Wi-Fi design's network keys, which the chip needs, are its
consumers. A key facet would not serve them: the secret leaves the vault
at every use, so what the vault adds is sealing at rest and one owner
for the bytes, not containment.

* **Grant.** A configured domain's manifest row holds the **state
  facet** of its purpose, as the SSH domain's holds its host key facet;
  `Service` is the name the row gives, no two rows name one purpose, and
  the system domain stands in front of the vault with the facet as with
  every key facet. The facet acts for its grantee alone.
* **Where it lives.** Each slot is a **state section** of the machine's
  file, sealed with AES-256-GCM under a key that HKDF-SHA-256 derives
  from the machine's master key with a label naming the purpose, and
  binding as associated data the file's format version and the purpose,
  as a login-key section is bound to its principal. So a section copied
  to another purpose does not open, a medium read away from the machine
  opens none under `device` or `tpm`, and under `none` whoever reads or
  writes the medium reads or writes every slot, as with every machine
  key. A medium rolled back to an older machine file brings back an
  older blob with every other machine secret, the rollback that
  [Risks and open questions](#risks-and-open-questions) weighs.
* **Operations.** `get() -> {ok, Blob} | none | {error, unavailable}`
  returns the blob whole, or `none` before the first `put`, and the vault
  logs each release with the grantee's domain and the purpose, as it
  logs a token's. `put(Blob) -> ok | {error, too_large | unavailable}`
  replaces it whole through the machine file's owner, and answers `ok`
  only once the publication's checkpoint has answered, as every change
  to the file does (One owner per file, above), so a blob the vault
  confirmed survives a power cut. On a trial boot `put` answers
  `unavailable`.
* **Bounds.** A blob is at most `vault_state_max`, 4 KiB, and the
  machine's file holds at most one section per purpose the manifest
  names, so what the slots cost the vault's partition is fixed by the
  manifest. A section whose purpose no row names stays in the file and
  is released to no one.
* **No structure.** The vault checks the blob's length alone. Its
  grantee decodes it as untrusted input, with a versioned decoder and a
  fuzz target of its own, since under `none` a medium can be written.


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

Nothing here owes compatibility to an earlier build. The layouts this
document uses carry versions only so that a mismatch fails loudly; the
kernel, `liberx` and the runtimes are built from one tree. The state
that outlives a boot is the vault's files and, where a platform keeps
one, the crash record. A vault file of another format version is refused
with a diagnostic and its principal answered `unavailable`, never read
under another layout, and an installation that changes the format
re-creates the vault's partition; a crash record of another build is
reported as unreadable and dropped.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | Who cleans up | What the user sees |
| --- | --- | --- | --- | --- |
| A malformed creation specification | the planning entries | nothing | none needed | the status code in the domain service; a counter |
| A creation step fails | the step's status | nothing: the applied steps undone by destroying the domain's two budgets (A4) | the domain library | `erx_domain:create/1` returns the mapped error |
| A domain's runtime never reports ready | the spec's boot timeout, or else the machine's | the built domain | the domain service stops it, and it ends as any domain does | a log line; for a request, `{error, timeout}` |
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
| A register access aborts on the bus, inside the device NIF | the fault gate: the fault ends the domain | the domain's stopped space until its destroy | the domain service restarts the configured domain; its drivers reset their devices | a log line, in a development build naming where the domain's device access trace is shown ([design-runtime.md](design-runtime.md#the-device-access-trace)); the domain's clients see `noconnection` and reconnect |
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
host link's UARTs are the system domain's, and a pin controller that
can put their signals on a pin is held by no domain or by the system
domain (property 8).
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
  enumerator writes; the enumerator's parser is Erlang with a fuzz
  target, and a crash of the enumerator ends the PCIe domain, which the
  domain service restarts and whose restart writes nothing to a running
  function ([design-pcie.md](design-pcie.md#failure-handling-and-restart)).
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
  passphrase keeps opening a copy taken before the change, and an SSH
  login key removed since the copy was taken logs in again. Under `none`
  it can also add a login key to any principal's file. Only the
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

Every passing case has a seeded failure beside it: a build check is run
once against a planted violation, a model once against a mutated
transition, a QEMU test once against a test-build hook that breaks the
property, and each must fail, so that a passing suite proves the code
under test ran. The invariants table names the check of each invariant;
this section gives the approach, the oracles, the fuzz targets and the
seeded faults.

* **Pure functions on the host.** The planning entries over valid and
  invalid specifications, every field at and beyond its bounds;
  `erx_dom_classify` over every record kind, status and stopper, a
  domain's own stop racing the library's among them; `erx_dom_record_step`
  over every order of records and stops for one domain; the end decision
  over each boot value, requested end and set of preparation outcomes,
  with missing and late replies; `erx_policy:capacity/1` by properties
  (shares on a CPU never past one CPU, capacity never past demand, runs
  within their cpusets, order-independence). Seeds: a plan that names
  another parent or another fault gate (A6, A2); each capacity property
  against a mutated placement step.
* **Creation origin, CPU parent and limits.** A configured service whose
  grant passes its principal's user share but fits `system` is planned
  under `system` and charged to its principal, and the same grant from a
  request is refused; a forged origin fails decoding and a mismatched row
  fails planning; a restart keeps the origin with a new id. Every runtime
  limit, at independently chosen values, survives normalization,
  validation and boot-page projection for configured, requested and
  system runtimes, and a missing, out-of-range or above-ceiling value
  prevents the start. Seeds: apply code that substitutes the principal's
  group for the planned parent; a planted violation of each origin
  constructor and caller source check; a hook that opens a peer lane
  before the limit record is installed.
* **Configuration headroom.** `erx_policy`'s grant rule over random
  grants, periods and cpusets agrees with property 13 on every shipped
  manifest; under QEMU every service domain spins at its full grant while
  the watchdog keeps petting. These are configuration tests, not a
  scheduler supply proof. Seeds: a rule that sums rates without the
  cpuset term; a manifest built around the check that gives the services
  all of `system`, under which the watchdog's deadline passes.
* **The manifest check.** For each property a manifest that violates it
  in one place fails the build with that property's diagnostic, and the
  shipped manifests pass. Property 9's seeded release manifests each break
  one clause: a `hostile` unconfined device given to a storage domain
  that also holds data windows, `web` listed among the host link's
  facets, a plain-HTTP listener for the web domain, and an unconfined
  device given to the web domain; property 13's gives the configured
  service domains rates that sum to more than `system`'s rate less
  `system_reserve`, and its seeded faults drop the reserve from the sum
  and skip the fit of each grant to `system`. The boot order over chains, trees and cycles,
  the cycle refused; the generated C and Erlang readers give the same
  records over every shipped manifest and refuse the whole file at each
  out-of-range offset, count, index and string. Seed: a manifest packed by
  hand around the check, which the source check over the packer's paths
  catches.
* **Undo.** A failure injected at each step of a creation, on the host
  and through a QEMU test-build hook, leaves nothing once the undo
  returns, and the principal's budget back at its baseline after the
  reaper runs; a domain whose init never reports ready leaves nothing.
  Seeds: a hook that charges one object of the creation to a third
  budget; a plan that installs another domain's IPC gate.
* **The root task and its end, under QEMU with HVF.** Boot to the login
  and the system shell; the system domain killed under load, halted with
  a string and left unpetted, each ending the machine by `erx.panic` with
  the crash record and no domain running; on each board, a system domain
  killed during a trial, which boots the committed slot; a configured
  domain ended repeatedly, within and beyond its intensity; the previous
  crash record in its brief and full forms, refused to every caller but
  the system shell; a partial boot of two native programs. Seeds: a hook
  that skips the `root_memory` comparison; a root image carrying
  `ERX_IMAGE_JIT`, which the manifest check refuses first; a hook that
  makes the domain service a `permanent` child, under which the machine
  survives its kill; a hook that faults the system domain at every boot,
  after which the fifth boot is rescue.
* **Names.** Node names, creations and `name_taken`; a name bound to one
  principal for the boot; 1,000 sessions one after another reuse the
  lowest pooled names and keep the atom count flat. Seeds: a hook that
  skips the `names` quota, after which the hostile-domain test finds the
  atom table past its bound; a hook that numbers pooled names from a
  counter.
* **Connections and ending.** Under QEMU: a peer's end seen everywhere
  across the connection and its charges returned; a peer that writes the
  side a dead domain read runs on until it unmaps; a peer that never
  answers keeps one child budget and the remains, within its own
  `connections` quota, while the dead configured domain restarts at once;
  a bell rung after the disconnect gets `ERX_ESTALE`; 10,000 short domains
  leave every budget at its baseline; a crash dump is read whole after
  the own budget's destroy; a line logged just before a halt reaches the
  console; sub-spaces three deep return every charge in one destroy.
  Seeds: a hook that charges a side to its reader's own budget, which
  faults the peer; one that charges every side to the outer budget
  directly, which leaves other connections' pages charged; one that
  charges the crash area to the own budget; one that links the logger
  proxy without trapping exits, which loses the line.
* **Devices.** Erlang virtio block and network drivers over the device
  NIF under QEMU, against the stock OTP file and socket suites that
  reach them and against sDDF's published throughput, the oracle gate G9
  compares with; a hostile device model writing malformed descriptors,
  lengths past a buffer and stale addresses, which crashes the driver
  process and corrupts nothing, under ASan in hosted mode; a received
  buffer rewritten by a model device after `complete/2`, which leaves the
  binary unchanged (R9); interrupt latency by `tools/erx bench irq`;
  the refusals and placements of A9 and of the boot checks (a second
  holder, a mark the fabric does not confirm, a split unit, a `console`
  path that is not `/chosen/stdout-path`'s); an unconfined device's
  restarted holder given the same memory; a confined device's DMA and a
  function enabled before its window aborting at the IOMMU; the
  enumerator, a native shim, a bus abort and the console driver each
  ending only what they should. Seeds: a hook that skips the console path
  comparison; a check over the driver applications' BEAM files that only
  the console's driver writes the console UART's transmit register; a
  native driver outside a sub-space port, or without a row of the driver
  table, which fails the build.
* **Shutdown.** `init:stop/0`, `init:reboot/0` and `erlang:halt/0,1`
  end QEMU under `-no-reboot`, normal latency recorded apart from
  deadline behaviour; the coordinator killed or hung after each
  preparation boundary, and the vault or a storage domain killed while
  ending is latched, end by the ending record's reset at its deadline,
  with no domain created and no deadline extended; a rejected begin
  leaves every service running; a freeze that succeeds before another
  service times out, and a refusal after preparation, end by a normal
  reset with incomplete durability reported. Seeds: a hook that skips the vault's `stop/0` under
  `tpm`, after which swtpm counts a failure; a release that passes only
  status 0 to the coordinator, which turns `halt(3)` into a crash record.
  A session's request has its own tests ([A session's
  request](#a-sessions-request)).
* **Authority, sub-spaces and admission.** Each `ERX_ERIGHTS` refusal A1
  and A7 promise; sub-spaces three deep that stop with their creator,
  whose faults never reach the system domain; a creator that names a
  fault gate it does not serve, or asks JIT objects it lacks, refused; an
  unsealed code object refused an executable mapping; a client flooding
  a service at its lane's full rate while another is served within the
  service's budget; a request past its schema refused before any heap is
  built; a facet process killed at its `max_heap_size` with no other
  client stalled; the inspector's per-client CPU statistic against the
  service's reductions. Seeds: the source checks of A1, A5 and A7, each with its
  planted violation.
* **Vault.** Oracles: OTP's `ssh` and `ssl` in TLS 1.3 against stock OTP
  29.1.2 peers, RFC 9106's Argon2id test vector, and swtpm behind
  `tpm-tis-device` for the `tpm` backend. Cases: each purpose's exact
  input and nothing else; each slot's binding to principal, index,
  backend and parameters; re-wraps, passphrase changes and power cuts;
  one login envelope for strangers, wrong passphrases and every slot's
  parameters; the network's rate limit, which never slows a UART login;
  enrolment at the UART alone; `unavailable` with the partition or backend
  gone and for changes on a trial boot; the sealing page mapped into the
  vault's domain alone, and after boot neither the device-secret page
  nor the sealing page in the system domain's space, checked by a walk
  of its mappings; under `tpm`, tries spent only on wrong passphrases, the
  reserve for local lines, an altered response failing its HMAC, a
  substituted storage key refused before any value is sent, and no
  stored lockout authorization; on each board, a file copied to another
  board opening no slot.
* **Identifiers.** `erx_ident`'s property test against a reference
  regular expression, every byte value at every position, lengths 0, 1,
  63 and 64. Seed: a record built outside its owning module.
* **Hostile domains.** Domains that never read their lane, flood it,
  never answer `connection_down`, ring their bells in a loop, trickle
  records, hold links and monitors up to `peer_held`, or forge connection
  messages, `max_domains` of them at once: the system domain stays
  responsive within its reservation, and every other domain is served.
* **A session's lines.** The mint core's line operations, the line's
  mint and facet, and the line names' build checks, each with its seeded
  fault, are the table of [A session's lines](#a-sessions-lines).
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

**A line beside the facet mechanism.** The line process would be
exported to its front end itself and admit the front end's calls with an
admission loop of its own, and the domain service would keep each
session's line pids in a registry of their own, hand one out after
introducing the two domains, and ask the line, in the system domain's
envelope, to export itself to the front end. That costs five things a
maintainer must know beside the facet: a second admission path for
calls from another domain, with no `max_request`, no limit in flight
and no counts; an export request of its own, with the peer it replaces;
a registry that checks a session's `provides` by rules of its own,
beside the mint core's providers; a three-step lookup, introduction and
export that its caller strings together with a deadline of its own; and
a hand-kept list of line names, from which the facet-name check exempts
them. Minting the line as a facet removes all five and adds two: the
line operation in the mint core, which reuses the introduction, the
mint request, the tag, the deadline and the reply checks every grant
has, and the `served_by session` mark, from which the line names are
derived ([A session's lines](#a-sessions-lines)).

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
object model and loader, which erXos does not use; Fiasco keeps only
Fiasco's kernel, `bootstrap` and `sigma0`
([design-fiasco.md](design-fiasco.md)).

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
* **Are a web line's views facets too?** A view is a process of the
  session that an `open` through the line's facet starts and hands out,
  acting for that facet's grantee as a process a facet starts does
  ([A session's lines](#a-sessions-lines), "Views and ttys"): it takes
  `next`, `stop` and a UI view's events in its grantee's envelope alone,
  charges its facet's account, and ends with its facet. Minting each
  view as a facet would add a facet process per view, up to 64 a line,
  for bounds the view already has as a process acting for a facet.
  Recommended: keep a view as such a process, a name a facet's reply
  hands out; the line's table of 64 bounds the views alive at once.

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
* FreeBSD, `sbin/reboot/reboot.c` (SHA-256
  `4276e0b6a399ef4249bc95a2bfa7e00f4fab73d63de20c32778584eaae59bcc4`)
  and `sbin/reboot/reboot.8` (SHA-256
  `d297a8f4323ed0285957452aa1f0212fabccc678ee74dc3d621a9155ce5c9398`) at
  commit `975e3605ebb15cbaf5a25c1c9d1f51aed41291d0`, read 2026-11-14: the
  superuser check, `-q`, `-p`, the cache flush and the `rebooted by` log
  line ([A session's request](#a-sessions-request)).
