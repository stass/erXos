// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The live console in the hero. Without JavaScript the window shows a
// recorded session. With it, a "Boot erXos" button downloads v64 (an
// AArch64 machine in WebAssembly) and the gzip-compressed erXos boot image,
// boots the image with a disk attached, and attaches the machine's serial
// console (the PL011, v64's serial0) to an xterm.js terminal.
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

const reduced_motion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const mib = bytes => (bytes / (1 << 20)).toFixed(1);

const ui = {
    console: document.getElementById("console"),
    screen: document.getElementById("erx-terminal"),
    state: document.querySelector("[data-erx-state]"),
    controls: document.querySelector("[data-erx-controls]"),
    boot: document.querySelector("[data-erx-boot]"),
    reset: document.querySelector("[data-erx-reset]"),
    status: document.querySelector("[data-erx-status]"),
    machine: document.querySelector("[data-erx-machine]"),
    progress: document.querySelector("[data-erx-progress]"),
    hint: document.querySelector("[data-erx-hint]"),
};

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
// start), reset (destroy, start again from the cached image) and failure
// (say what failed, offer the action that can recover). Each start makes a
// new session; listeners check it against `current`, so output from a
// machine Reset destroyed never reaches the terminal.
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
        session.emulator = new this.V86({
            cpu_type: "arm64", graphics_adapter: "none", cpu_cores: CPU_CORES,
            memory_size: RAM_MIB << 20, log_level: 0, wasm_path: site_url(this.manifest.emulator.wasm),
            kernel: { buffer: this.image.slice(0) }, cmdline: CMDLINE, virtio_disks: [{ buffer: this.disk }],
            jit_switches: { a64_page: 1 }, autostart: true,
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
            ui.boot.hidden = true;
            ui.reset.hidden = false;
            this.start();
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
        } catch(error) {
            this.fail(error);
        } finally {
            ui.reset.disabled = false;
        }
    },

    // Before the machine exists the visitor can try the boot again; after,
    // Reset is the way back.
    fail(error) {
        show_status(`Could not start: ${error?.message ?? error}`);
        show_state("stopped");
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
    fetch_manifest().then(manifest =>
        show_status(`${mib(manifest.compressed_bytes + manifest.emulator.bytes)} MB download`)).catch(() => undefined);
}

init();
