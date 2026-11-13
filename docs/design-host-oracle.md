# Offline host oracle

The full stock OTP oracle runs in a task-owned Linux container with no
external network interface. Docker supplies the isolation boundary; on
macOS, a local provider such as OrbStack supplies its Linux VM. Native
macOS OTP builds remain separate inputs to bootstrap compilation and native
performance measurements. A Linux suite result never claims macOS behavior,
and container timing is not compared with native macOS latency.

## Inputs and execution identity

The oracle uses the pinned OTP 29.1.2 archive, never the modified `otp/`
tree. Its toolchain comes from an immutable OCI image already present in
the selected engine. `deps.lock` records the image repository, version label,
platform-specific manifest SHA-256, platform, license inventory and status.
The version label is descriptive; the manifest digest selects the bytes.
An image's configuration digest and its manifest digest are different
identities and are recorded as such. Only the explicit fetch step may pull
the pinned image. Docker supports [pulling by digest](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier).

The image contains Ruby, GNU timeout, the C/C++ toolchain and all build
prerequisites. A complete official Ruby image based on `buildpack-deps`
provides a suitable starting point; the actual pinned image must pass the
prerequisite probe. Configure and suite execution never install packages,
download tools or build another container image. Every container is created
with `--pull never`; a missing image is a setup error.

The caller explicitly selects a local Docker context. Read-only inspection
resolves its endpoint and requires a local UNIX socket. The adapter creates
a matching context in a private Docker configuration directory and passes
that directory and context on every client invocation. It copies only the
validated endpoint, not operator credentials, plugins or proxy settings.
It never changes the global context or VM settings. This also avoids
Docker's [automatic injection of configured proxies](https://docs.docker.com/engine/cli/proxy/)
into new containers. Remote endpoints require a separate design and are
refused. The daemon and the VM provider are trusted development tools.

Each report records the macOS or Linux host, selected context and endpoint,
engine identity, guest kernel and architecture, image manifest/configuration
digests, effective resource limits, OTP source digest, compiler identities,
configure arguments and runtime flavour. Linux artifacts live below
`build/oracle/linux/{emu,jit}`; they never replace native artifacts below
`build/oracle/{emu,jit}`. Native build receipts and benchmark reports carry
their own execution identity.

## Container boundary

Creation uses `--network none`, `--init`, private PID, IPC, UTS and cgroup
namespaces, no additional devices, `--cap-drop ALL` and
`--security-opt no-new-privileges`. The workload runs as a non-root UID/GID
that owns its output directory. Host networking, host namespaces, published
ports, privileged mode, extra capabilities, Docker sockets and host service
sockets are not accepted plan inputs. The adapter inspects the created
container and checks these settings before starting it. Container logging
uses `--log-driver none`; attached output goes only to the host runner's
private log, without invoking an engine-configured remote log service.

Docker's [none network](https://docs.docker.com/engine/network/drivers/none/)
has only a private loopback device. Wildcard listeners, fixed ports, daemon
processes and distributed Erlang peers therefore remain inside the same
container. An operator's `epmd`, proxy and loopback DNS service are outside
that network namespace. The context sets a private hostname, adds its
IPv4 loopback hosts entry and supplies a local resolver configuration that
cannot reach an external resolver. Native hostname lookup is tested without
changing OTP's resolver implementation. Docker does not configure IPv6
loopback for this driver by default; its actual availability is reported,
not assumed or manufactured by granting network administration authority.

The workload has checked, read-only input mounts and a fresh, owned Docker
volume for its writable filesystem. It has no writable host bind mount.
The input set contains the verified archive and required tooling/reporting
sources, not the entire repository, home directory or Docker configuration.
Bind inputs use private propagation and canonical validated paths and
contain no host service sockets. The workload starts through `env -i` with
an explicit environment; image entrypoints and health checks do not execute.
The parent environment stays unchanged.

## Native workspace and artifact export

The volume uses Docker's local driver with no driver options, an
unpredictable per-invocation name and the same private ownership token as
the workload. The host records that name before creation and inspects the
returned volume's name, label, driver and options before use. No existing
operator volume is accepted. A fresh volume mounts at the pinned image's
`/tmp`, whose empty-volume initialization supplies its writable directory
permissions. The non-root workload creates `/tmp/erx-oracle` with mode 0700;
the preflight verifies its ownership and filesystem behavior. This uses
[Docker's volume initialization](https://docs.docker.com/engine/storage/volumes/#mounting-a-volume-over-existing-data),
not a privileged preparation process or a host filesystem share.

Source extraction, build objects, installed OTP, native helpers, Common Test
logs and private test directories all live in that Linux workspace. The
guest's temporary, home and XDG directories live there too, with both
`.erlang` startup locations initially empty. No executable or filesystem
test fixture runs from a macOS shared directory. A host artifact path is
only a data destination, never a guest working directory or executable cache.

The native volume survives the workload's termination. Only after the
adapter has confirmed that the workload container and its detached children
are gone does it start a short-lived exporter using the same pinned image,
non-root UID, offline namespace and resource/deadline rules. The exporter
mounts the exact owned volume read-only at `/native`, the checked exporter
code read-only, and one fresh owned host staging directory at `/artifacts`.
No stock program runs in this phase. A stopped workload and a read-only
export mount make the input tree stable throughout inspection and copying.

The exporter constructs a bounded file plan from a closed set of evidence
roots: the guest result, event stream, runner logs, image-license evidence
when requested, and the selected suite's Common Test log tree. It does not
copy the source or installed-runtime tree wholesale. The Common Test walk
prunes its private fixture directories, `log_private` and the pinned
per-case/per-configuration forms `log_private.<number>` and
`log_private.cfg.<number>`. These contain test data, including deliberately
unusual filesystem objects; they are not required reporting evidence.
Optional attachments from them need an explicit bounded selection. The same
policy applies
to success, failure, timeout and cancellation; missing or unfinished records
remain missing or unfinished. Progress messages already captured by the
attached host runner remain available independently of artifact export.

Traversal uses `lstat` and does not follow links. Only directories and
ordinary file contents are exported; symlinks, sockets, devices and FIFOs
are recorded as excluded types. Hard-linked ordinary files are copied as
independent bytes and charged separately. The plan bounds total entries,
depth, relative pathname bytes, individual file bytes, aggregate file bytes
and inventory bytes. Each bound is an explicit finite configuration value
recorded in the report. The copy reads no more than each admitted file's
declared size and checks the result. It creates new destination files
exclusively, with mode 0600, and directories with mode 0700; source ownership,
permissions, links and extended attributes are not transferred. A host
pathname collision, including case or normalization collisions, is an export
error rather than an overwrite.

The inventory records each copied file's guest-relative path, byte count and
SHA-256, plus exclusions, inaccessible paths and bound failures. Diagnostics
escape filenames, and the inventory itself is size-bounded. Already copied
safe evidence is retained when export is partial; partial publication has an
explicit artifact status and cannot be reported as complete evidence.
Required result/event/report files are distinguished from ancillary raw
artifacts so missing case evidence cannot become a successful empty suite.
Case outcomes, run completeness and artifact availability remain separate:
an unavailable optional attachment does not change a passed case into a
failed one. Required reporting evidence that exceeds a bound or cannot be
copied leaves the conformance result incomplete; optional omissions keep
their own reason and availability status.
The host verifies the staging tree and inventory before publishing artifact
paths, and projects a case's guest log path only through an exported entry.
No archive decoder, custom tar parser or general file-transfer service is
part of this boundary.

A container writable layer would tie post-termination export to Docker's
archive-copy interface. A volume supplies a stable filesystem to the bounded
Ruby copier and survives removal of the workload. A tmpfs would consume the
workload's memory budget and lose the evidence when its container stops.
The volume's extra storage lifetime therefore buys one ordinary, bounded
copy path for every workload outcome.

CPU, memory, combined memory/swap, process count and shared-memory limits
are explicit positive plan values, checked against engine support and
recorded. Resource exhaustion is a failed or incomplete run, never a pass.
The deadline bounds elapsed execution; it is not a disk quota. Native volume
space remains an engine resource. Artifact byte limits bound copied host
data; they do not impose an unverified engine storage quota. Out-of-space
errors remain explicit.

## Lifetime and failure handling

One workload container owns an entire build or suite invocation, including
every native fixture and daemon the stock tools create. The ordinary
[command runner](design-build.md#processes-and-evidence) owns Docker client
processes, logs and deadlines. The container adapter owns the guest
lifetime; killing the client is insufficient.

Before `docker create`, the adapter records a private ownership token and
an empty CID path in its run manifest. Creation writes the CID and applies
that token as a label. The adapter checks the exact CID and ownership label,
validates the complete container configuration, and starts it attached with
closed standard input. It never selects containers by a common name prefix.
If creation is interrupted before the CID is recorded, cleanup recovers
only containers carrying that exact private token; an ambiguous outcome
remains an explicit cleanup error.

The workload's top-level GNU timeout runs inside the container as well as
the host client's deadline. This bounds a guest even if the host client
disappears. The guest init reaps children. A normal exit, command failure,
cancellation or deadline enters the same cleanup: capture the owned
workload's final state, then force-remove that CID with its own bounded
runner call. Cleanup and artifact export do not inherit an already-cancelled
work token. Removal ends the private PID namespace, including children that
called
`setsid`. Docker documents [forced removal](https://docs.docker.com/reference/cli/docker/container/rm/#force-remove-a-running-container-force)
for a running container; the implementation verifies that the owned CID
no longer exists before exporting artifacts. The exporter has its own exact
CID and role under the same owner token. Its deadline and cleanup follow the
same rule. After export, the adapter removes the exporter, removes the exact
owned volume and verifies that both are absent before reporting completion.
If workload removal is unproven, export does not race its possible writers.
The two container roles and the volume are explicit in the run manifest;
recovery resolves only those exact roles under that invocation's token.

An unreachable engine or failed removal retains the CIDs, volume identity,
context and cleanup diagnostic for targeted recovery. A confirmed stopped
volume can be retained explicitly for retry after an export error; its
retention is recorded and prevents a completed-cleanup claim. It cannot
produce a successful build or suite report. Cleanup never prunes images,
volumes, containers or VMs and never stops the engine or an operator-owned
service. Every running status includes the owned CID, age and deadline.

## Oracle behavior and verification

Both `emu` and `jit` are built from the verified stock archive inside this
context. Each full suite starts from a fresh verified stock source build and
uses OTP's make test target, including its fixture preparation. Case
selection and expectations are unchanged. External-network cases keep their
actual failures or stock skips; Linux and missing IPv6 behavior remain
visible in results. The oracle does not fabricate DNS answers for public
names, change lookup methods to induce skips, or silently omit cases.
Reports preserve case identities, setup failures and incomplete outcomes as
[the reporting contract](design-build.md#oracle-and-protocol-models) requires.
The workload sets OTP's `TS_EXTRA_PLATFORM_LABEL` to `Docker`, records it
with the profile, and preserves the skips the pinned suites make for that
actual environment. Private reporting modules carry neither documentation
nor debug chunks, so they do not enter OTP's application-documentation tests.

Host tests first exercise planning and lifecycle with a fake engine: missing
or mismatched image identities, remote endpoints, extra mounts or networking,
partial creation of either container or the volume, cancellation, timeout,
failed export and failed cleanup. Artifact fixtures cover path collisions,
links, special files, private-fixture pruning, inaccessible entries,
depth/count/byte limits, partial copies and missing required evidence.
Actual-engine proofs use only owned fixtures and reserved documentation
addresses. They
check the inspected network mode, the absence of non-loopback interfaces and
external routes, failed numeric external connections and native DNS lookup,
successful loopback TCP/UDP and distributed Erlang exchanges, and the
observed IPv6 result. Resolver failure alone is not isolation evidence;
the absent interface and route are part of the proof. The native-filesystem
regression copies the same `/usr/bin/true` into the execution workspace,
changes its mode to 0111 and proves that it executes successfully as the
non-root workload while ordinary reads fail. The actual stock
`port_SUITE:port_program_with_path` case is also run there. Neither a test
skip nor a mode change to the stock fixture satisfies this acceptance check.

A cleanup fixture daemonizes with `setsid`, holds a fixed loopback port and
continues after its original parent exits. Cancellation removes its whole
container before the read-only export begins, the artifact fixture remains
available for bounded copying, a second owned container can use the same
port, and a separate operator-service fixture remains alive and unchanged.
Additional fixtures
poison parent proxy variables and both parent Erlang startup locations,
then prove that none reaches the stock runtime. No probe captures unrelated
host traffic or changes global network configuration.

One invocation owns the workload namespace, its native volume, and a finite
export phase. Callers supply a validated build/suite plan and receive a
completed report only after those resources are gone. Docker namespace
enforcement and its local engine are the trust boundary; host kernel or
engine compromise is outside this trusted-code development harness.
