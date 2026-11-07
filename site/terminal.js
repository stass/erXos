// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The live console in the hero. Without JavaScript the window shows a
// recorded session. With it, a "Boot erXos" button downloads v64 (an
// AArch64 machine in WebAssembly) and the gzip-compressed erXos boot image,
// boots the image, and attaches the machine's serial console (the PL011,
// v64's serial0) to an xterm.js terminal.
//
// Flow: boot.json (written by tools/build_site.rb, fetched past the cache)
// names the image, its sizes and its SHA-256, and v64's module and core,
// all under names that carry their digests. The image is downloaded with a progress bar,
// decompressed with DecompressionStream, checked against the SHA-256 and
// kept in memory, so Reset reboots without downloading again. Boot progress
// comes from milestones in the serial output.

// Guest memory. One constant, so a smaller image can lower it in one place.
const RAM_MIB = 512;
const CMDLINE = "erx.watchdog=1,30,600";
const MANIFEST = "boot.json";

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
    { marker: "Eshell V", label: "Ready: type at the prompt" },
];
// The download is the first part of the progress bar; each milestone
// fills an equal share of the rest.
const DOWNLOAD_SHARE = 0.6;

const reduced_motion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const mib = bytes => (bytes / (1 << 20)).toFixed(1);

const ui = {
    screen: document.getElementById("erx-terminal"),
    state: document.querySelector("[data-erx-state]"),
    controls: document.querySelector("[data-erx-controls]"),
    boot: document.querySelector("[data-erx-boot]"),
    reset: document.querySelector("[data-erx-reset]"),
    status: document.querySelector("[data-erx-status]"),
    progress: document.querySelector("[data-erx-progress]"),
    hint: document.querySelector("[data-erx-hint]"),
};

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

// Downloads the image, reporting the bytes received so far, and returns the
// decompressed image after checking its length and SHA-256. A host that
// adds Content-Encoding hands over bytes the browser already decompressed;
// the gzip magic number tells the two cases apart.
async function fetch_image(manifest, on_progress) {
    const response = await fetch(manifest.image);
    if(!response.ok) throw new Error(`image download: HTTP ${response.status}`);
    const chunks = [];
    let received = 0;
    for(const reader = response.body.getReader();;) {
        const { done, value } = await reader.read();
        if(done) break;
        chunks.push(value);
        received += value.byteLength;
        on_progress(received);
    }
    const body = new Blob(chunks);
    const head = new Uint8Array(await body.slice(0, 2).arrayBuffer());
    const gzipped = head[0] === 0x1f && head[1] === 0x8b;
    const image = gzipped
        ? await new Response(body.stream().pipeThrough(new DecompressionStream("gzip"))).arrayBuffer()
        : await body.arrayBuffer();
    if(image.byteLength !== manifest.bytes) throw new Error("image download: wrong length");
    if(hex(await crypto.subtle.digest("SHA-256", image)) !== manifest.sha256)
        throw new Error("image download: checksum mismatch");
    return image;
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
        ui.state.textContent = "Booting";
        show_status("Starting the machine", DOWNLOAD_SHARE);
        session.emulator = new this.V86({
            cpu_type: "arm64", graphics_adapter: "none", cpu_cores: 1,
            memory_size: RAM_MIB << 20, log_level: 0, wasm_path: this.manifest.emulator.wasm,
            kernel: { buffer: this.image.slice(0) }, cmdline: CMDLINE,
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
                    ui.state.textContent = "Live";
                    window.erx_ready_at = performance.now();
                    this.term.focus();
                }
            }
        });
    },

    async boot() {
        ui.boot.disabled = true;
        window.erx_boot_clicked_at = performance.now();
        try {
            show_status("Loading", 0);
            const xterm = load_xterm();
            const manifest = this.manifest = await fetch_manifest();
            const v64 = import(new URL(manifest.emulator.module, document.baseURI).href);
            this.image = await fetch_image(manifest, received =>
                show_status(`Downloading ${mib(Math.min(received, manifest.compressed_bytes))} of ` +
                            `${mib(manifest.compressed_bytes)} MB`, received / manifest.compressed_bytes * DOWNLOAD_SHARE));
            [{ V86: this.V86 }] = await Promise.all([v64, xterm]);
            this.term ??= open_terminal();
            ui.boot.hidden = true;
            ui.reset.hidden = false;
            this.start();
        } catch(error) {
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
        ui.state.textContent = "Stopped";
        if(this.image && this.V86 && this.term) return;
        ui.boot.textContent = "Try again";
        ui.boot.disabled = false;
    },
};

function init() {
    if(!ui.screen || !ui.controls) return;
    ui.controls.hidden = false;
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
        show_status(`${mib(manifest.compressed_bytes + manifest.emulator.bytes)} MB download, runs in your browser`)).catch(() => undefined);
}

init();
