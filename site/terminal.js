// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The live console in the hero. Without JavaScript the window shows a
// recorded session. With it, a "Boot erXos" button downloads v64 (an
// AArch64 machine in WebAssembly) and the gzip-compressed erXos boot image,
// boots the image with a disk and a network device attached, and attaches
// the machine's serial console (the PL011, v64's serial0) to an xterm.js
// terminal.
//
// Flow: boot.json (written by tools/build_site.rb, fetched past the cache)
// names the image, its sizes and its SHA-256, the disk, and v64's module and core,
// all under names that carry their digests. The image is downloaded with a progress bar,
// decompressed with DecompressionStream, checked against the SHA-256 and
// kept in memory, so Reset reboots without downloading again. The disk is
// published as the bytes it holds and where they go; it is checked the same
// way and kept in memory, sparse, with the guest's writes, so files written
// to /data survive Reset until the page is closed. Every file boot.json
// names is fetched from the page's own origin. Boot progress comes from
// milestones in the serial output.

// Guest memory and cores. One constant each, so either changes in one
// place; the readout on the case is built from the same two.
const RAM_MIB = 160;
const CPU_CORES = 1;
// No erx.hostlink=1: v64's machine has one UART, the console, so there is
// no host link UART to drive (docs/design-stopgap.md, "The command line").
const CMDLINE = "erx.watchdog=1,30,600";
const MANIFEST = "boot.json";
// The bounds on what boot.json may ask the page to hold: the image and the
// disk's published bytes must each fit in the guest's memory, and the
// disk, which keeps every sector the guest writes, in 2 GiB.
const MAX_DOWNLOAD_BYTES = RAM_MIB * 2 ** 20;
const MAX_DISK_BYTES = 2 ** 31;
const SECTOR_BYTES = 512;
// The disk holds what was written in chunks of this size.
const DISK_CHUNK_BYTES = 1 << 16;

// Where the machine's devices sit on its 32 virtio-mmio transports, which
// erXos's platform record says (config/platforms/qemu-virt.json): the disk
// on the last transport, the top page's, and the network device on the last
// transport of the page below, since a 4 KiB page holds eight transports
// and is one device's alone (docs/design-stopgap.md). v64 has no setting
// for a device's transport: it gives each the next one down from the last,
// the disks first and the network device after them, so on its own the
// network device would take the disk's page. The disk is therefore
// followed by blank read-only disks over the rest of its page, which the
// platform record names no driver for, and the network device falls on the
// transport the record names. virtio_slots models v64's placement rule;
// only test/site/terminal_test.mjs uses it, to check the placement against
// the platform record.
const VIRTIO_MMIO = { base: 0x0a000000, size: 0x200, count: 32, first_spi: 16 };
const NET_SLOT = 23;
// The network device on v64's fake router (its "fetch" backend): DHCP gives
// the guest 192.168.86.100, the router at 192.168.86.1 answers ARP, DNS and
// ICMP echo itself, and an HTTP request to port 80 becomes a fetch() by this
// page, to any host (a host named PORT.external is the visitor's own
// localhost:PORT). No CORS proxy (cors_proxy) and no relay server: nothing
// leaves the browser but those fetches, which the browser's rules govern.
const NET_DEVICE = Object.freeze({ type: "virtio", relay_url: "fetch" });

// The machine's virtio-blk disks, as v64's virtio_disks takes them: the
// disk, then the blank ones that fill the rest of its page.
function virtio_disks(disk) {
    // v64 gives the disks the transports above the network device's.
    const disk_count = VIRTIO_MMIO.count - 1 - NET_SLOT;
    return [{ buffer: disk },
            ...Array.from({ length: disk_count - 1 },
                          () => ({ buffer: new ArrayBuffer(SECTOR_BYTES), readonly: true }))];
}

// The transports v64 gives a machine with this many disks and a network
// device, each with its address and interrupt (SPI first_spi + slot, as on
// QEMU's virt machine).
function virtio_slots(disk_count) {
    const at = slot => ({ slot, base: VIRTIO_MMIO.base + slot * VIRTIO_MMIO.size,
                          intid: 32 + VIRTIO_MMIO.first_spi + slot });
    return { disks: Array.from({ length: disk_count }, (_, n) => at(VIRTIO_MMIO.count - 1 - n)),
             net: at(VIRTIO_MMIO.count - 1 - disk_count) };
}

// xterm.js from a CDN, pinned to exact versions and checked by Subresource
// Integrity.
const XTERM_CSS = { src: "https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.css",
    integrity: "sha384-8Xk9wy/gzEDUKrXtrmCFa2bBuK3BpjpDuL/p0SeKQX19Khl/M+lHOgD/CyYf7efP" };
const XTERM_JS = { src: "https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.js",
    integrity: "sha384-M169f14mRZOXm3hD/v2Ti0ThIT/RnAQagXA9nlE15yHAtrW19gdePJh/HaTzUOe/" };
const XTERM_FIT_JS = { src: "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.js",
    integrity: "sha384-iF+jqbuti4XlB64clWgFWYEscb+UnSRv3VgVikGYZu+otNFnSHr7y7NcKfBnGizn" };

// Serial output that marks a boot stage, in boot order, with what the
// status line says once it appears.
const MILESTONES = [
    { marker: "L4Re Microkernel", label: "Kernel up" },
    { marker: "erx: root task", label: "Starting the system domain" },
    { marker: "Erlang/OTP 29", label: "Starting Erlang" },
    { marker: "rc: the command shell", label: "Ready: type at the prompt" },
];
// The download is the first part of the progress bar; each milestone
// fills an equal share of the rest.
const DOWNLOAD_SHARE = 0.6;

// What the readout on the case says the machine is.
const MACHINE = `ARMv8-A \u00b7 ${CPU_CORES} ${CPU_CORES === 1 ? "core" : "cores"} \u00b7 ${RAM_MIB} MiB RAM`;

// The site test (test/site/terminal_test.mjs) imports this module under
// Node for its pure parts, the boot-log parse and the fault table; there is
// no page there, so nothing below touches one unless `document` exists.
const page = globalThis.document;

const reduced_motion = page ? matchMedia("(prefers-reduced-motion: reduce)").matches : false;
const mib = bytes => (bytes / (1 << 20)).toFixed(1);

const ui = page ? {
    console: page.getElementById("console"),
    screen: page.getElementById("erx-terminal"),
    state: page.querySelector("[data-erx-state]"),
    controls: page.querySelector("[data-erx-controls]"),
    boot: page.querySelector("[data-erx-boot]"),
    reset: page.querySelector("[data-erx-reset]"),
    faults: page.querySelector("[data-erx-faults]"),
    fault_select: page.querySelector("[data-erx-fault-select]"),
    fault_inject: page.querySelector("[data-erx-fault-inject]"),
    status: page.querySelector("[data-erx-status]"),
    machine: page.querySelector("[data-erx-machine]"),
    progress: page.querySelector("[data-erx-progress]"),
    hint: page.querySelector("[data-erx-hint]"),
} : {};

// The phases of the console and the label each shows beside the lamp. The
// phase colours the lamp and the readout; see .terminal[data-erx-phase] in
// style.css. Before the first boot the case has no phase.
const PHASE_LABELS = { booting: "Booting", live: "Live", stopped: "Stopped" };

function show_state(phase) {
    ui.state.textContent = PHASE_LABELS[phase];
    ui.console.dataset.erxPhase = phase;
}

function show_status(text, fraction) {
    ui.status.textContent = text;
    ui.progress.hidden = fraction === undefined;
    if(fraction !== undefined)
        ui.progress.firstElementChild.style.width = `${Math.round(Math.min(fraction, 1) * 100)}%`;
}

// The keys the chin shows: Boot before the first boot and once the machine
// has ended; the fault menu and Reset while a machine exists.
function show_keys(machine_exists) {
    ui.boot.hidden = machine_exists;
    ui.reset.hidden = !machine_exists;
    ui.faults.hidden = !machine_exists;
}

// ---- Hardware faults
//
// The visitor injects a fault into the running machine from a menu on the
// chin. Every fault is made in v64, never by a command typed into the guest,
// and reaches only the visitor's own emulator. An action takes the session
// (`emulator`, a V86, and the facts below) and returns, or resolves to, the
// one-line note the status line shows: what was done, with addresses, the
// interrupt and the seed. What v64 offers is reached through its CPU object,
// `emulator.v86.cpu`: the MMIO windows (`io`), the virtio devices and their
// transports, the GIC's lines (`set_irq`) and the devices by name.
//
// A fault that changes a v64 object pushes its undo onto `session.repairs`;
// a power cut runs them before the machine powers on again, so the new boot
// gets the hardware back whole, with the disk's contents as they were.

// The boot log the page keeps, from the first byte, to read the memory map
// from; the map is in its first few KiB.
const BOOT_LOG_LIMIT = 32768;
// The line that ends what the parse reads: the root task's first report
// comes after the bootstrapper's regions and sigma0's map.
const ROOT_TASK_MARK = "erx: root task: manifest";
// sigma0 names a resource's owner by task number; the root task, which is
// the system domain, is task 4.
const ROOT_TASK_OWNER = 4;
// v64's physical addresses are 40 bits wide.
const PHYS_LIMIT = 2n ** 40n;
// The largest range the parse accepts as the system domain's program.
const SYSTEM_RANGE_MAX = 64 << 20;
const PAGE = 4096;
// Where v64's virt machine puts RAM.
const GUEST_RAM_BASE = 0x40000000;

const RAM_LINE = /^\s*RAM: ([0-9a-f]{1,16}) - ([0-9a-f]{1,16}):/;
const ROOT_IP_LINE = /^\s*Roottask config\s+node: \d+\s+ip:([0-9a-f]{1,16})$/;
const REGION_LINE = /^\s*\[\s*([0-9a-f]{1,16}),\s*([0-9a-f]{1,16})\]\s*\{[^}]*\}\s*(\S+)\s+\S+$/;
const MAP_LINE = /^\[(\d{1,3}):([R-])([W-])([X-]):([0-9a-f]{1,16});([0-9a-f]{1,16})\]$/;

// A hex number from the log as a Number, or NaN when it is not a physical
// address v64 can have.
function physical(digits) {
    const value = BigInt(`0x${digits}`);
    return value < PHYS_LIMIT ? Number(value) : NaN;
}

const overlaps = (a, b) => a.start <= b.end && b.start <= a.end;

// The system domain's program in guest memory, read from the boot log: the
// range sigma0's RAM map gives the root task (owner 4) that is writable and
// holds the root task's entry point. It must lie in RAM, be whole pages, be
// at most SYSTEM_RANGE_MAX long and overlap none of the bootstrapper's
// regions that are not the root task's (the kernel's, sigma0's). Returns
// { range: { start, end }, entry } or { reason }. Only the first
// BOOT_LOG_LIMIT characters are read.
function parse_system_memory(log) {
    const lines = log.slice(0, BOOT_LOG_LIMIT).split("\n").map(line => line.replace(/\r$/, ""));
    let ram = null, entry = NaN, in_map = false;
    const others = [], owned = [];
    for(const line of lines) {
        let m;
        if(line.startsWith("RAM:---")) in_map = true;
        else if(line.startsWith("IOMEM:")) in_map = false;
        else if(in_map && (m = MAP_LINE.exec(line))) {
            if(Number(m[1]) === ROOT_TASK_OWNER && m[3] === "W")
                owned.push({ start: physical(m[5]), end: physical(m[6]) });
        }
        else if((m = RAM_LINE.exec(line))) ram ??= { start: physical(m[1]), end: physical(m[2]) };
        else if((m = ROOT_IP_LINE.exec(line))) entry = physical(m[1]);
        else if((m = REGION_LINE.exec(line)) && m[3] !== "Root")
            others.push({ start: physical(m[1]), end: physical(m[2]) });
    }
    if(!ram || !(ram.start <= ram.end)) return { reason: "the boot log names no RAM" };
    if(Number.isNaN(entry)) return { reason: "the boot log names no root task" };
    const range = owned.find(r => r.start <= entry && entry <= r.end);
    if(!range) return { reason: "no root-task memory holds the root task's entry" };
    if(range.start < ram.start || range.end > ram.end) return { reason: "the root task's memory lies outside RAM" };
    if(range.start % PAGE !== 0 || (range.end + 1) % PAGE !== 0) return { reason: "the root task's memory is not whole pages" };
    if(range.end - range.start + 1 > SYSTEM_RANGE_MAX) return { reason: "the root task's memory is too large" };
    if(others.some(other => Number.isNaN(other.start) || Number.isNaN(other.end) || overlaps(other, range)))
        return { reason: "the root task's memory overlaps the kernel's or sigma0's" };
    return { range, entry };
}

// `count` pseudo-random numbers below `limit` from `seed` (xorshift32), so
// the same seed picks the same places on every run.
function seeded_numbers(seed, count, limit) {
    let state = (seed >>> 0) || 1;
    return Array.from({ length: count }, () => {
        state ^= state << 13; state >>>= 0;
        state ^= state >>> 17;
        state ^= state << 5; state >>>= 0;
        return state % limit;
    });
}

// The machine's disk, the first virtio-blk device (v64's disk_devices()
// lists the same ones), on its virtio-mmio slot: its window, transport and
// interrupt. Null when the machine has no disk, or v64 has not built the
// machine yet (it creates emulator.v86 once its core is instantiated).
function disk_of(emulator) {
    const cpu = emulator.v86?.cpu;
    if(!cpu?.virtio_devices || cpu.virtio_transport !== "mmio") return null;
    const entry = cpu.virtio_devices.find(({ name }) => name === "virtio-blk");
    if(!entry) return null;
    const transport = cpu.virtio_mmio[entry.slot];
    return { cpu, slot: entry.slot, device: entry.device, transport, intid: transport.intid };
}

const hex_address = n => `0x${n.toString(16)}`;

// The disk's line stops following the device: an instance property shadows
// VirtioMmio.prototype.update_irq, which every raise and lower goes through.
function freeze_disk_line(session, disk) {
    disk.transport.update_irq = () => undefined;
    session.repairs.push(() => {
        delete disk.transport.update_irq;
        disk.transport.level = false;
        disk.cpu.set_irq(disk.intid, false);
    });
}

const DISK_BLOCK = 4096;
// Blocks below this are the partition table's; corruption starts past it.
const DISK_SKIP = 64 << 10;
const DISK_CORRUPT_BLOCKS = 8;
const RAM_FLIPS = 64;
const CPU_FREEZE_MS = 15000;
const CLOCK_JUMP_HOURS = 3;

const buffer_get = (buffer, start, length) => new Promise(resolve => buffer.get(start, length, resolve));
const buffer_set = (buffer, start, bytes) => new Promise(resolve => buffer.set(start, bytes, resolve));

// The disk's blocks that hold data: past the partition table, and not one
// byte value throughout, as erased or never-written blocks are.
async function used_blocks(buffer) {
    const used = [];
    const chunk = 1 << 20;
    for(let start = DISK_SKIP; start + DISK_BLOCK <= buffer.byteLength; start += chunk) {
        const span = Math.min(chunk, buffer.byteLength - start);
        const length = span - span % DISK_BLOCK;
        await new Promise(resolve => setTimeout(resolve));
        const bytes = new Uint8Array(await buffer_get(buffer, start, length));
        for(let at = 0; at < length; at += DISK_BLOCK) {
            const block = bytes.subarray(at, at + DISK_BLOCK);
            if(block.some(b => b !== block[0])) used.push(start + at);
        }
    }
    return used;
}

// Each injection that picks places takes the next seed, shown in its note.
let next_seed = 1;

// The menu's entries by name. `needs` names what an entry waits for ("disk",
// "system_memory"); `unsupported` is the reason an entry cannot be offered.
const FAULTS = {
    dead_disk: {
        label: "Dead disk", needs: "disk",
        action({ emulator, session }) {
            const disk = disk_of(emulator);
            const owner = disk.cpu.virtio_mmio_slots[disk.slot];
            const { base, size, handler } = disk.cpu.io.ranges[owner];
            disk.cpu.io.unregister_mmio(owner);
            session.repairs.push(() => {
                disk.cpu.virtio_mmio_slots[disk.slot] = disk.cpu.io.register_mmio(base, size, handler);
            });
            freeze_disk_line(session, disk);
            disk.cpu.set_irq(disk.intid, true);
            return `the disk's registers at ${hex_address(base)} are gone and its interrupt, INTID ${disk.intid}, is raised`;
        },
    },
    hung_disk: {
        label: "Hung disk", needs: "disk",
        action({ emulator, session }) {
            const disk = disk_of(emulator);
            freeze_disk_line(session, disk);
            disk.cpu.set_irq(disk.intid, false);
            return `the disk works on, but its interrupt, INTID ${disk.intid}, no longer reaches the processor`;
        },
    },
    irq_storm: {
        label: "Interrupt storm", needs: "disk",
        action({ emulator, session }) {
            const disk = disk_of(emulator);
            freeze_disk_line(session, disk);
            disk.cpu.set_irq(disk.intid, true);
            return `the disk's interrupt, INTID ${disk.intid}, is held asserted`;
        },
    },
    corrupt_disk: {
        label: "Corrupt disk", needs: "disk",
        async action({ emulator, still_current }) {
            const buffer = disk_of(emulator).device.backend.buffer;
            const used = await used_blocks(buffer);
            if(!still_current()) return "";
            if(used.length === 0) throw new Error("the disk holds no data to corrupt");
            const seed = next_seed++;
            const blocks = seeded_numbers(seed, DISK_CORRUPT_BLOCKS, used.length);
            const within = seeded_numbers(seed + 1, DISK_CORRUPT_BLOCKS, DISK_BLOCK);
            const offsets = [];
            for(let i = 0; i < DISK_CORRUPT_BLOCKS; i++) {
                const offset = used[blocks[i]] + within[i];
                const [byte] = new Uint8Array(await buffer_get(buffer, offset, 1));
                await buffer_set(buffer, offset, Uint8Array.of(byte ^ 0xff));
                offsets.push(hex_address(offset));
            }
            return `inverted ${DISK_CORRUPT_BLOCKS} bytes in data blocks (seed ${seed}) at ` +
                `${offsets.join(", ")}; read some files to see what erXos does`;
        },
    },
    corrupt_ram: {
        label: "Corrupt RAM", needs: "system_memory",
        action({ emulator, session }) {
            const { start, end } = session.memory.range;
            if(start < GUEST_RAM_BASE || end >= GUEST_RAM_BASE + (RAM_MIB << 20))
                throw new Error("the boot log's range lies outside this machine's RAM");
            const seed = next_seed++;
            const picks = seeded_numbers(seed, RAM_FLIPS, (end - start + 1) * 8);
            for(const pick of picks) {
                const address = start + Math.floor(pick / 8);
                const [byte] = emulator.read_memory(address, 1);
                emulator.write_memory(Uint8Array.of(byte ^ (1 << (pick % 8))), address);
            }
            return `flipped ${RAM_FLIPS} bit positions (seed ${seed}) in the system domain's program, ` +
                `${hex_address(start)}-${hex_address(end)}; nothing shows until it runs or reads them`;
        },
    },
    ram_fail: {
        label: "RAM fail", unsupported: "needs a change inside v64",
    },
    power_cut: {
        label: "Power cut",
        async action({ emulator, session, still_current }) {
            session.pausing = true;
            try {
                await emulator.stop();
                if(!still_current()) return "";
                for(const repair of session.repairs.splice(0)) repair();
                session.applied.clear();
                await emulator.restart("power-on");
                if(!still_current()) return "";
            } finally {
                session.pausing = false;
            }
            session.rewatch();
            show_state("booting");
            await emulator.run();
            return "the power went off and on; the machine boots again with the disk as it was at the cut";
        },
    },
    clock_jump: {
        label: "Clock jump", unsupported: "erXos has no wall clock yet",
        action({ emulator }) {
            emulator.v86.cpu.devices["pl031"].tick_offset += CLOCK_JUMP_HOURS * 3600;
            return `the real-time clock (PL031) moved ${CLOCK_JUMP_HOURS} hours ahead`;
        },
    },
    cpu_freeze: {
        label: "CPU freeze",
        async action({ emulator, session, still_current }) {
            session.pausing = true;
            try {
                await emulator.stop();
            } finally {
                session.pausing = false;
            }
            if(!still_current()) return "";
            show_status(`CPU freeze: the processor is stopped for ${CPU_FREEZE_MS / 1000} s`);
            await new Promise(resolve => setTimeout(resolve, CPU_FREEZE_MS));
            if(!still_current()) return "";
            await emulator.run();
            return `the processor stood still for ${CPU_FREEZE_MS / 1000} s and runs again; v64 stops the machine's ` +
                "clock with it, so erXos's own time did not move";
        },
    },
};

// The menu's groups, in order.
const FAULT_GROUPS = [
    { label: "Devices", faults: ["dead_disk", "hung_disk", "irq_storm", "corrupt_disk"] },
    { label: "Memory", faults: ["corrupt_ram", "ram_fail"] },
    { label: "Machine", faults: ["power_cut", "clock_jump", "cpu_freeze"] },
];

// Whether an entry can be injected, from facts about the running machine:
// { disk, disk_dead, memory } where `memory` is parse_system_memory's
// answer or null before the log reached it. Returns { enabled, reason }.
function fault_availability(fault, facts) {
    if(fault.unsupported) return { enabled: false, reason: fault.unsupported };
    if(fault.needs === "disk" && !facts.disk) return { enabled: false, reason: "this machine has no disk" };
    if(fault.needs === "disk" && facts.disk_dead) return { enabled: false, reason: "the disk is dead already" };
    if(fault.needs === "system_memory" && !facts.memory?.range)
        return { enabled: false, reason: facts.memory?.reason ?? "waiting for the boot log's memory map" };
    return { enabled: true, reason: "" };
}

function fault_facts(session) {
    return { disk: disk_of(session.emulator) !== null, disk_dead: session.applied.has("dead_disk"),
             memory: session.memory };
}

// The menu shows each entry's availability; it and Inject are usable only
// while a machine runs, is ready and no fault is in progress.
function render_faults(session) {
    const usable = Boolean(session?.ready && !session.ended && !session.busy);
    const facts = session ? fault_facts(session) : { disk: false, disk_dead: false, memory: null };
    for(const option of ui.fault_select.options) {
        const fault = FAULTS[option.value];
        const { enabled, reason } = fault_availability(fault, facts);
        option.disabled = !enabled;
        option.textContent = enabled ? fault.label : `${fault.label} (${reason})`;
    }
    const selected = ui.fault_select.selectedOptions[0];
    if(selected?.disabled) {
        const first = Array.from(ui.fault_select.options).find(option => !option.disabled);
        if(first) first.selected = true;
    }
    ui.fault_select.disabled = !usable;
    ui.fault_inject.disabled = !usable || ui.fault_select.selectedOptions[0]?.disabled !== false;
}

function build_fault_menu() {
    for(const group of FAULT_GROUPS) {
        const element = Object.assign(page.createElement("optgroup"), { label: group.label });
        for(const name of group.faults)
            element.append(Object.assign(page.createElement("option"), { value: name, textContent: FAULTS[name].label }));
        ui.fault_select.append(element);
    }
    render_faults(null);
}

function load_script({ src, integrity }) {
    return new Promise((resolve, reject) => {
        const script = Object.assign(document.createElement("script"),
            { src, integrity, crossOrigin: "anonymous", onload: resolve,
              onerror: () => reject(new Error("could not load the terminal")) });
        document.head.append(script);
    });
}

// Loads once; a retry after a failed boot reuses the same promise unless
// the load itself failed.
let xterm_loaded = null;
function load_xterm() {
    xterm_loaded ??= (async () => {
        document.head.append(Object.assign(document.createElement("link"),
            { rel: "stylesheet", href: XTERM_CSS.src, integrity: XTERM_CSS.integrity, crossOrigin: "anonymous" }));
        await load_script(XTERM_JS);
        await load_script(XTERM_FIT_JS);
        await document.fonts.load('12px "IBM Plex Mono"').catch(() => undefined);
    })().catch(error => { xterm_loaded = null; throw error; });
    return xterm_loaded;
}

async function fetch_manifest() {
    const response = await fetch(MANIFEST, { cache: "no-cache" });
    if(!response.ok) throw new Error(`boot manifest: HTTP ${response.status}`);
    return response.json();
}

const hex = buffer => Array.from(new Uint8Array(buffer), b => b.toString(16).padStart(2, "0")).join("");

// A file boot.json names, as an http or https URL on the page's own
// origin. A name that leads anywhere else is refused (another host, or a
// data: or blob: URL), and so is every name on a page whose origin is
// opaque, so the page fetches nothing for the machine but its own files.
function site_url(name) {
    const url = new URL(String(name), document.baseURI);
    if(location.origin === "null" || url.origin !== location.origin || !["http:", "https:"].includes(url.protocol))
        throw new Error("boot manifest: a file is not on this site");
    return url.href;
}

// Reads a stream to its end, calling on_progress with the bytes read so
// far, and returns them as a Blob. A stream longer than limit bytes is
// cancelled and fails, so a wrong file never fills the page's memory.
async function read_bounded(stream, limit, what, on_progress = () => undefined) {
    const chunks = [];
    let received = 0;
    for(const reader = stream.getReader();;) {
        const { done, value } = await reader.read();
        if(done) return new Blob(chunks);
        received += value.byteLength;
        if(received > limit) {
            reader.cancel().catch(() => undefined);
            throw new Error(`${what} download: too long`);
        }
        chunks.push(value);
        on_progress(received);
    }
}

// Downloads a file boot.json names, reporting the bytes received so far,
// and returns its content after checking its length and SHA-256. A file
// published gzip-compressed, which boot.json gives a compressed_bytes, is
// decompressed here; a host that adds Content-Encoding hands over bytes the
// browser already decompressed, and the gzip magic number tells the two
// cases apart. Aborting signal stops the download.
async function fetch_checked(what, { file, bytes, sha256, compressed_bytes }, { on_progress, signal } = {}) {
    const size = n => Number.isSafeInteger(n) && n >= 0 && n <= MAX_DOWNLOAD_BYTES;
    if(!size(bytes) || !(compressed_bytes === undefined || size(compressed_bytes)))
        throw new Error(`boot manifest: the ${what}'s size is not one the page holds`);
    const response = await fetch(site_url(file), { signal });
    if(!response.ok) throw new Error(`${what} download: HTTP ${response.status}`);
    const body = await read_bounded(response.body, Math.max(bytes, compressed_bytes ?? 0), what, on_progress);
    const head = new Uint8Array(await body.slice(0, 2).arrayBuffer());
    const gzipped = compressed_bytes !== undefined && head[0] === 0x1f && head[1] === 0x8b;
    const content = gzipped
        ? await (await read_bounded(body.stream().pipeThrough(new DecompressionStream("gzip")), bytes, what)).arrayBuffer()
        : await body.arrayBuffer();
    if(content.byteLength !== bytes) throw new Error(`${what} download: wrong length`);
    if(hex(await crypto.subtle.digest("SHA-256", content)) !== sha256)
        throw new Error(`${what} download: checksum mismatch`);
    return content;
}

// The machine's disk: byteLength bytes, of which only the chunks something
// wrote are held, every other byte reading as zero, so a 1.2 GiB medium
// costs the page only what has been written to it. v64 takes it as a disk
// of its own (an object with load, get and set, as src/buffer.js in v64
// describes) and writes the guest's writes into it, so a machine that
// Reset starts on the same disk finds them.
class SparseDisk {
    constructor(byteLength) {
        this.byteLength = byteLength;
        this.chunks = new Map();
        this.onload = undefined;
    }

    load() { this.onload?.({}); }

    get(start, length, done) {
        if(!this.holds(start, length)) return done(undefined, new Error("a read past the end of the disk"));
        const data = new Uint8Array(length);
        this.each(start, length, ({ chunk, in_chunk, in_request, count }) => {
            const held = this.chunks.get(chunk);
            if(held) data.set(held.subarray(in_chunk, in_chunk + count), in_request);
        });
        done(data);
    }

    set(start, data, done) {
        if(!this.holds(start, data.byteLength)) return done(new Error("a write past the end of the disk"));
        this.each(start, data.byteLength, ({ chunk, in_chunk, in_request, count }) => {
            if(!this.chunks.has(chunk)) this.chunks.set(chunk, new Uint8Array(DISK_CHUNK_BYTES));
            this.chunks.get(chunk).set(data.subarray(in_request, in_request + count), in_chunk);
        });
        done();
    }

    holds(start, length) {
        return Number.isSafeInteger(start) && Number.isSafeInteger(length) && start >= 0 && length >= 0 &&
            start + length <= this.byteLength;
    }

    // Calls visit once for each chunk the request's bytes fall in, in order,
    // with the chunk's index, where its part of the request starts in the
    // chunk and in the request, and that part's length.
    each(start, length, visit) {
        for(let in_request = 0; in_request < length;) {
            const in_chunk = (start + in_request) % DISK_CHUNK_BYTES;
            const count = Math.min(DISK_CHUNK_BYTES - in_chunk, length - in_request);
            visit({ chunk: Math.floor((start + in_request) / DISK_CHUNK_BYTES), in_chunk, in_request, count });
            in_request += count;
        }
    }
}

// The disk boot.json describes, from its downloaded content: each extent,
// an [offset, length] pair, takes the next length bytes of the content, and
// every other byte is zero. The extents must be whole sectors, in order,
// apart (the build joins touching ones), within the capacity, and use the
// content exactly.
function make_disk({ capacity, extents }, content) {
    const sectors = n => Number.isSafeInteger(n) && n >= 0 && n % SECTOR_BYTES === 0;
    if(!sectors(capacity) || capacity === 0 || capacity > MAX_DISK_BYTES || !Array.isArray(extents))
        throw new Error("boot manifest: the disk is not one the page holds");
    const disk = new SparseDisk(capacity);
    let end = -1, used = 0;
    for(const extent of extents) {
        const [offset, length] = Array.isArray(extent) ? extent : [];
        if(!sectors(offset) || !sectors(length) || length === 0 || offset <= end || offset + length > capacity ||
           used + length > content.byteLength)
            throw new Error("boot manifest: a disk extent is out of place");
        disk.set(offset, new Uint8Array(content, used, length), error => { if(error) throw error; });
        end = offset + length;
        used += length;
    }
    if(used !== content.byteLength) throw new Error("boot manifest: the disk's extents do not match its content");
    return disk;
}

function terminal_theme() {
    const css = getComputedStyle(document.documentElement);
    const token = name => css.getPropertyValue(name).trim();
    return { background: token("--code-bg"), foreground: token("--code-ink"),
             cursor: token("--code-prompt"), cursorAccent: token("--code-bg"),
             selectionBackground: "#4a4843" };
}

function open_terminal() {
    const term = new Terminal({
        fontFamily: '"IBM Plex Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace',
        fontSize: matchMedia("(max-width: 560px)").matches ? 11 : 12,
        lineHeight: 1.2, cursorBlink: !reduced_motion, scrollback: 5000,
        theme: terminal_theme(), convertEol: false,
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    const host = Object.assign(document.createElement("div"), { className: "xterm-host" });
    ui.screen.querySelector("pre").hidden = true;
    ui.screen.append(host);
    ui.screen.dataset.erxTerminal = "live";
    term.open(host);
    term.onData(data => {
        const bytes = new TextEncoder().encode(data);
        // serial0_send takes one character per byte.
        machine.current?.emulator.serial0_send(Array.from(bytes, b => String.fromCharCode(b)).join(""));
    });
    fit.fit();
    let pending = false;
    addEventListener("resize", () => {
        if(pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; fit.fit(); });
    });
    return term;
}

// The machine's whole lifecycle lives here: boot (download once, then
// start), reset (destroy, start again from the cached image), a fault the
// visitor injects, the machine's own end (it powers off, and Boot starts it
// again from the cached image) and failure (say what failed, offer the
// action that can recover). Each start makes a new session; listeners
// check it against `current`, so output from a machine Reset destroyed
// never reaches the terminal.
const machine = {
    V86: null,
    manifest: null,
    image: null,
    disk: null,
    term: null,
    current: null,

    start() {
        const session = {};
        this.current = session;
        let stage = 0, tail = "", queued = [], flush_scheduled = false;
        const flush = () => {
            flush_scheduled = false;
            if(this.current !== session) return;
            this.term.write(Uint8Array.from(queued));
            queued = [];
        };
        show_state("booting");
        show_status("Starting the machine", DOWNLOAD_SHARE);
        // net_device is a copy: v64 keeps the object it is given as its own
        // settings.
        session.emulator = new this.V86({
            cpu_type: "arm64", graphics_adapter: "none", cpu_cores: CPU_CORES,
            memory_size: RAM_MIB << 20, log_level: 0, wasm_path: site_url(this.manifest.emulator.wasm),
            kernel: { buffer: this.image.slice(0) }, cmdline: CMDLINE, virtio_disks: virtio_disks(this.disk),
            net_device: { ...NET_DEVICE }, jit_switches: { a64_page: 1 }, autostart: true,
        });
        session.emulator.add_listener("emulator-error", error => {
            if(this.current === session) this.fail(error);
        });
        session.emulator.add_listener("serial0-output-byte", byte => {
            if(this.current !== session) return;
            queued.push(byte);
            if(!flush_scheduled) { flush_scheduled = true; setTimeout(flush, 16); }
            if(stage === MILESTONES.length) return;
            tail = (tail + String.fromCharCode(byte)).slice(-128);
            while(stage < MILESTONES.length && tail.includes(MILESTONES[stage].marker)) {
                const { label } = MILESTONES[stage];
                stage += 1;
                show_status(label, DOWNLOAD_SHARE + (1 - DOWNLOAD_SHARE) * stage / MILESTONES.length);
                if(stage === MILESTONES.length) {
                    ui.progress.hidden = true;
                    show_state("live");
                    window.erx_ready_at = performance.now();
                    this.term.focus();
                }
            }
        });
    },

    async boot() {
        ui.boot.disabled = true;
        if(this.image && this.V86 && this.term) {
            show_keys(true);
            return this.reset();
        }
        window.erx_boot_clicked_at = performance.now();
        show_state("booting");
        // A failure of any one part stops the downloads still running, so
        // their progress never covers the error and Try again starts afresh.
        const downloads = new AbortController();
        const { signal } = downloads;
        try {
            show_status("Loading", 0);
            const xterm = load_xterm();
            const manifest = this.manifest = await fetch_manifest();
            const v64 = import(site_url(manifest.emulator.module));
            const on_progress = received => signal.aborted ||
                show_status(`Downloading ${mib(Math.min(received, manifest.compressed_bytes))} of ` +
                            `${mib(manifest.compressed_bytes)} MB`, received / manifest.compressed_bytes * DOWNLOAD_SHARE);
            const image = fetch_checked("image", { file: manifest.image, bytes: manifest.bytes, sha256: manifest.sha256,
                                                   compressed_bytes: manifest.compressed_bytes }, { on_progress, signal });
            const disk = fetch_checked("disk", manifest.disk ?? {}, { signal })
                .then(content => make_disk(manifest.disk, content));
            [this.image, { V86: this.V86 }, this.disk] = await Promise.all([image, v64, disk, xterm]);
            this.term ??= open_terminal();
            show_keys(true);
            this.start();
            this.watch(this.current);
        } catch(error) {
            downloads.abort();
            this.fail(error);
        }
    },

    async reset() {
        ui.reset.disabled = true;
        const old = this.current;
        this.current = null;
        try {
            await old?.emulator.destroy();
            this.term.reset();
            this.start();
            this.watch(this.current);
        } catch(error) {
            this.fail(error);
        } finally {
            ui.reset.disabled = false;
        }
    },

    // The page's own listeners on a session, beside the terminal's in
    // start(): the machine's end, readiness for faults (the shell's prompt
    // marker), and the boot log, kept up to BOOT_LOG_LIMIT characters until
    // the root task's first report, for parse_system_memory. A power cut
    // calls session.rewatch() to read the next boot the same way.
    watch(session) {
        const ready_marker = MILESTONES[MILESTONES.length - 1];
        let log = "", line = "", tail = "", reading = true;
        Object.assign(session, { applied: new Set(), repairs: [], memory: null, ready: false, rebooted: false });
        session.rewatch = () => {
            log = ""; line = ""; tail = ""; reading = true;
            Object.assign(session, { memory: null, ready: false, rebooted: true });
            render_faults(session);
        };
        session.emulator.add_listener("emulator-stopped", () => {
            if(this.current === session && !session.pausing) this.ended(session);
        });
        session.emulator.add_listener("serial0-output-byte", byte => {
            if(this.current !== session) return;
            const char = String.fromCharCode(byte);
            if(reading) {
                log += char;
                line = char === "\n" ? "" : line + char;
                if(line.startsWith(ROOT_TASK_MARK) || log.length >= BOOT_LOG_LIMIT) {
                    reading = false;
                    session.memory = parse_system_memory(log);
                    log = "";
                    render_faults(session);
                }
            }
            if(session.ready) return;
            tail = (tail + char).slice(-128);
            if(!tail.includes(ready_marker.marker)) return;
            session.ready = true;
            show_state("live");
            if(session.rebooted) show_status(ready_marker.label);
            render_faults(session);
        });
        render_faults(session);
    },

    // Injects one of FAULTS into the running machine. The menu is unusable
    // while a fault is in progress; the status line then says what was done,
    // or why it could not be. A fault that ends the machine reaches ended().
    async inject(name) {
        const session = this.current, fault = FAULTS[name];
        if(!fault || !session?.ready || session.ended || session.busy) return;
        if(!fault_availability(fault, fault_facts(session)).enabled) return;
        session.busy = true;
        session.fault = fault;
        session.menu_focused = ui.faults.contains(document.activeElement);
        render_faults(session);
        show_status(`${fault.label}: injecting the fault`);
        const still_current = () => this.current === session && !session.ended;
        try {
            const note = await fault.action({ emulator: session.emulator, session, still_current });
            if(!still_current()) return;
            session.applied.add(name);
            show_status(`${fault.label}: ${note}`);
        } catch(error) {
            if(!still_current()) return;
            show_status(`${fault.label}: could not inject it: ${error?.message ?? error}`);
        } finally {
            session.busy = false;
            if(still_current()) {
                session.fault = null;
                render_faults(session);
                if(session.menu_focused) ui.fault_select.focus();
            }
        }
    },

    // The machine stopped by itself: it powered off after a crash, or after
    // a halt typed at the console. Boot starts it again; focus on a key
    // that goes away moves to Boot.
    ended(session) {
        session.ended = true;
        const refocus = ui.faults.contains(document.activeElement) || document.activeElement === ui.reset ||
            (session.busy && session.menu_focused);
        render_faults(session);
        show_state("stopped");
        show_status(session.fault ? `${session.fault.label}: the machine is off` : "The machine is off");
        ui.boot.textContent = "Boot erXos";
        ui.boot.disabled = false;
        show_keys(false);
        if(refocus) ui.boot.focus();
    },

    // Before the machine exists the visitor can try the boot again; after,
    // Reset is the way back.
    fail(error) {
        show_status(`Could not start: ${error?.message ?? error}`);
        show_state("stopped");
        if(this.current) {
            this.current.ended = true;
            render_faults(this.current);
        }
        if(this.image && this.V86 && this.term) return;
        ui.boot.textContent = "Try again";
        ui.boot.disabled = false;
    },
};

function init() {
    if(!ui.screen || !ui.controls) return;
    ui.controls.hidden = false;
    ui.machine.textContent = MACHINE;
    const supported = typeof WebAssembly === "object" && typeof DecompressionStream === "function" &&
        globalThis.crypto?.subtle;
    if(!supported) {
        ui.boot.disabled = true;
        show_status("This browser cannot run the emulator");
        return;
    }
    ui.hint.hidden = false;
    ui.boot.addEventListener("click", () => machine.boot());
    ui.reset.addEventListener("click", () => machine.reset());
    build_fault_menu();
    ui.fault_select.addEventListener("change", () => render_faults(machine.current));
    ui.fault_inject.addEventListener("click", () => machine.inject(ui.fault_select.value));
    fetch_manifest().then(manifest =>
        show_status(`${mib(manifest.compressed_bytes + manifest.emulator.bytes)} MB download`)).catch(() => undefined);
}

if(page) init();

export { parse_system_memory, seeded_numbers, disk_of, fault_availability, FAULTS, FAULT_GROUPS, BOOT_LOG_LIMIT,
         virtio_disks, virtio_slots, NET_DEVICE };
