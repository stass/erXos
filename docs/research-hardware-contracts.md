# Research record: AArch64 features and DMA contracts

Checked 2026-10-31 on `stas-armbook.local`, Apple Silicon AArch64,
macOS 27.0.1 (26A434), using the web reader and curl 8.7.1 for
read-only source inspection. No kernel implementation, guest, device test
or benchmark ran. This record supports the architecture and platform designs; it does not certify a release profile.

## Cortex-A72 feature evidence

The [Cortex-A72 r0p3 TRM, 100095_0003_06_en](https://documentation-service.arm.com/static/60368ce38f952d2e4134dc2e),
identification-register summary and external debug register table, reports
`ID_AA64MMFR1_EL1` as zero: the Pi 4's core has no hardware PAN.
Table 4-35 reports 16-bit ASID support. Hardware PAN on a QEMU
configuration is evidence about that configuration alone. Kernel-call
memory access follows the object-window contract in
[design-arch-aarch64.md](design-arch-aarch64.md).

## SMMUv3 specification findings

Primary source: [Arm IHI 0070 G.b, 2025-04-30](https://documentation-service.arm.com/static/6813b2bbefb0f21122c144c2).
The cited rules apply to the base mechanisms used here; erXos does not
enable the specification's newer optional features.

| Question | Specification location and established result |
| --- | --- |
| `SIG_NONE` polling | Section 4.7.3, pp205-207: sync observability precedes consumer-index consumption; no signal does not weaken completion. |
| Old translated DMA | Section 4.7.3: TLBI and CFGI completion makes affected transactions globally observable to their shareability domain. This does not retire future device requests. |
| Silent quarantine | Sections 5.2 and 5.2.1, pp217 and 252: valid abort is silent; invalid `V` produces `C_BAD_STE`. |
| Already-translated traffic | Section 3.9.2 and `SMMU_CR0.ATSCHK`, pp343-344: fast mode bypasses stream checks; safe mode checks authorization. `EATS=0` alone is insufficient. |
| Boot disable | `SMMU_CR0` update rules, pp348-349: disable acknowledgement does not drain every inherited transaction; interconnect buffering needs platform completion. |
| Queue publication | Section 3.5.2 requires queue entries visible before the updated producer is observable. |
| Inherited caches | Section 3.11, pp93-94, and section 6.3.9.6, p349: changing `SMMUEN` need not invalidate configuration or TLB entries; fresh initialization explicitly invalidates both. |
| Inherited queues and MSIs | Sections 6.3.9.3-6.3.9.5, pp346-347, distinguish completed queue shutdown from command completion; section 3.18.1, p127, and `IRQ_CTRL`, p369, specify notification shutdown separately. |

The specification's initialization summary first builds the stream table
and queues, enables command processing, invalidates cached configuration
and translations, then enables translation. Its Non-secure invalidation
note names `CMD_TLBI_NSNH_ALL` and `CMD_TLBI_EL2_ALL`; the latter is legal
only with `IDR0.Hyp` (section 4.4.2.7, p187). The binding uses those
supported commands with `CMD_CFGI_ALL` and a completed `CMD_SYNC`, while
global abort remains active. `SMMU_CMDQ_BASE`, p393, specifies base/size,
then indexes, then queue enable, with the same rule for other queues.

These are fresh-initialization rules, not a general live takeover recipe.
The design accepts only a platform-established stopped handoff, verifies
accessible acknowledgements before reclamation, and refuses unknown,
active or unhandled inherited facilities. The loader/port proof must
include outstanding SMMU accesses and command-generated MSIs; disabling a
queue alone cannot establish that proof. A platform drain and closed
global abort precede allocator handoff; fresh cache invalidation precedes
translation enable. The Pi firmware's continuing machine-wide authority
remains an accepted trusted-base caveat.

The binding consequently requires safe ATS handling, valid abort entries,
explicit publication and reclamation barriers, and a completion visibility
domain covering reclaimed memory. Control-flow ordering alone is not an adequate reclamation barrier. Page quarantine remains
mandatory when completion is unknown.

## Source checks and their limits

[Linux v6.12 booting.rst](https://github.com/torvalds/linux/blob/v6.12/Documentation/arch/arm64/booting.rst),
section 4, explicitly requires DMA devices quiesced before entry. This is
a loader obligation, not evidence that Raspberry Pi firmware drains all
masters. erXos's additional platform drain obligation requires evidence
for outstanding transactions as well as stopped request generation.

The reproducible QEMU source baseline checked here is **v11.1.2**:

* [smmu-common.h](https://github.com/qemu/qemu/blob/v11.1.2/include/hw/arm/smmu-common.h),
  `smmu_get_sid`, constructs the stream id from the device model's bus
  number and `devfn`.
* [pci.c](https://github.com/qemu/qemu/blob/v11.1.2/hw/pci/pci.c),
  `pcibus_num`, fixes a root bus at zero; subordinate numbering comes
  from a bridge's configuration. This supports restricting confined
  devices to the fixed root bus.
* [smmuv3.c](https://github.com/qemu/qemu/blob/v11.1.2/hw/arm/smmuv3.c),
  `decode_ste` and `smmuv3_translate`, distinguishes invalid STE faults
  from silent configured aborts.

This source baseline is not an acceptance test of the supported binary.
Its requester identity, reset behavior and SMMU model must pass the
same contract tests. QEMU behavior cannot establish physical interconnect
draining or a board's loader compliance. The inherited Fiasco reference
checked locally is commit `50bbe8a981199e17865e8553a4eb02c387b339cf`,
`src/kern/arm/64/mem_space-arm-64.cpp`, `Mem_space::make_current` in the
non-virtualized build; the kernel's lineage ledger records the additional
copy-isolation boundary.

## Evidence still required

The architecture binding specifies regression obligations for command
completion and queue wrap; continuous and late
DMA; invalid versus valid abort; translated traffic; requester identity;
failed reset; and interrupt spoofing. These tests do not exist in this
documentation-only tree and have not passed.

Security closure remains gated on implementation and exact-target
conformance: both accelerators, each claimed confined bus and each loader/firmware combination. Loader drain,
device reset completion, DMA visibility and timeout quarantine require
executable evidence. The High DMA platform-evidence item remains open in
[TODO.md](../TODO.md). The board-port and security obligations are in
[plan.md](plan.md). A cited specification resolves an interpretation, not these
implementation and platform obligations.
