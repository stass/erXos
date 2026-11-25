# Raspberry Pi 4

How to put erXos on a Raspberry Pi 4 Model B, boot it, check that its
SD card and Ethernet work, and boot builds over the network while you
develop. The board is a development build: its banner says `development
build: trusted code only`, so run only code you trust on it.

What the board layer is, why the card is laid out as it is and what the
firmware does with it are in
[the platform design](../design-platforms.md#raspberry-pi-4-model-b).

## What you need

* A Raspberry Pi 4 of any memory size. The board uses 1 GB whatever it
  has; the 4 GB board is the one that is tested.
* A microSD card of at least 1 GB.
* A 3.3 V USB-serial adapter for the console (never a 5 V one).
* For the Ethernet checks, a cable to a network with a DHCP server and a
  route to the internet, such as a home router.
* A screen on the micro-HDMI port labeled HDMI0, to see the kiosk. Plug it
  in before you power the board on.

Wire the console adapter to the 40-pin header: its ground to pin 6, its
receive line to pin 8 (GPIO 14, the Pi's transmit) and its transmit line
to pin 10 (GPIO 15). Open it at 115200 baud, 8N1, no flow control, for
example `screen -L /dev/cu.usbserial-XXXX 115200`; `-L` logs everything
to `screenlog.0`. A Glasgow Interface Explorer's UART applet can be the
adapter instead; it serves the console as a TCP port, port 2300 in the
setup this guide was checked with, which `nc localhost 2300` opens. The
board benchmarks' walk (`tools/erx bench NAME --env pi4-4gb-erxos
--console CONSOLE`) reads either: `CONSOLE` is a serial device's path,
or the applet's port as `tcp:HOST:PORT`, such as `tcp:localhost:2300`,
which the walk connects to and reads directly. The applet serves one
connection: a new one, such as `nc`'s, closes the one before, so close
`nc` before the walk starts, and do not open it while the walk runs,
which would end the walk with its console closed. The walk asks the
board to reboot over ssh; where ssh cannot, it types `reboot` on the
console itself. The port
has no authentication, so serve it on localhost, or reach a Glasgow on
another host through an ssh tunnel.
A second adapter on UART3, the host link, is optional:
ground to pin 9, receive to pin 7 (GPIO 4), transmit to pin 29 (GPIO 5),
also 115200 8N1. A development card's `cmdline.txt` holds `erx.hostlink=1`,
which turns the host link on; keep the file one line with no newline
at its end.

Typing into the serial console works, but pasting into it can drop
characters: the line has no flow control and its receive buffer holds
eight bytes. To paste, log in over SSH. The shell's editor finishes no
line that it read lost characters in, and rings the bell at Enter until
you empty the line. A loss just before `Ctrl-\` or `Ctrl-Z` at the
prompt, whose flush drops the unread input, is not caught: the line typed
before it stays and can run. A program that edits its own line in raw mode is not protected that
way, as on FreeBSD: it reads a NUL byte where input was lost, and a loss
just before `Ctrl-C`, `Ctrl-Z` or `Ctrl-\`, whose flush drops the unread
input, does not reach it at all.

## Update the bootloader, once

The board's bootloader must be dated 2022-12-01 or later, because the
card's first partition holds only `autoboot.txt` with `tryboot_a_b=1` and
each slot holds its own `config.txt`. A board with an older bootloader
shows nothing on the console and its green LED stays on. To reflash it:

1. On your computer, open Raspberry Pi Imager and pick the Raspberry Pi 4.
2. As the operating system pick *Misc utility images > Bootloader > SD
   Card Boot* and write it to a spare card, not the erXos card.
3. Put that card in the Pi and power it. When the green LED flashes in a
   steady pattern, power the Pi off.
4. Take the spare card out.

## Get the card

Build it from a checkout:

```sh
make pack PLATFORM=raspi4b
```

This builds the card the website offers, the kiosk and the Doom example
on it, so it needs `tools/erx fetch --example doom` first. The
development card is the same card without the Doom example, so it needs
no such fetch; build it, the one to netboot, with

```sh
tools/erx pack --platform raspi4b --medium
```

Either writes `build/production-image/raspi4b/`:

* `sdcard.img`, the card, 718 MiB;
* `sdcard.img.xz`, the same card compressed (about 38 MB), the form to
  copy to another machine;
* `sdcard.img.receipt.json`, the build record: the commit, whether the
  tree had changes, and the digests;
* `boot/`, the boot partition's files, which netbooting serves.

The website offers the same card as `sdcard-DIGEST.img.xz` with its
`sdcard-DIGEST.img.receipt.json`, where `DIGEST` is the first 16
hexadecimal digits of the card image's SHA-256. Check a downloaded card
before you write it:

```sh
xz -dc sdcard-DIGEST.img.xz | shasum -a 256
```

The line it prints starts with `DIGEST`, and the whole SHA-256 is the one
in the record.

### What is on the card

| Partition | Holds | Size |
| --- | --- | --- |
| 1 | the boot-selection record: `autoboot.txt` | 8 MiB, FAT16 |
| 2 | boot A: the firmware, `config.txt`, the device tree, `kernel8.img` | 192 MiB, FAT32 |
| 3 | boot B, the other slot | 192 MiB, FAT32 |
| 4 | the extended partition holding 5 to 8 | |
| 5 | system A: the slot's read-only system image | 63 MiB |
| 6 | system B | 63 MiB |
| 7 | the vault | 64 MiB |
| 8 | `/data`, a littlefs volume | 128 MiB or more |

The layout is defined in `abi/medium.txt`. To log in over SSH, put your
public key in `authorized_keys` on partition 1, the volume named `ERXOS`,
before you first boot.

## Write the card

Insert the card and find it.

On macOS:

```sh
diskutil list
```

On FreeBSD:

```sh
geom disk list
```

Pick the disk whose size is the card's (on macOS `/dev/diskN`, marked
`external, physical`; on FreeBSD `/dev/daN`). **Writing to the wrong disk
destroys what is on it, your own system disk included. Check the size and
the name twice.**

On macOS, from the compressed card:

```sh
diskutil unmountDisk /dev/diskN
xz -dc sdcard.img.xz | sudo dd of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

or from the raw image: `sudo dd if=sdcard.img of=/dev/rdiskN bs=4m`.
On FreeBSD:

```sh
xz -dc sdcard.img.xz | sudo dd of=/dev/daN bs=1m
```

`dd` ends with `752877568 bytes transferred`. Only the card's first
718 MiB are written; the rest of a larger card is left as it was.
Raspberry Pi Imager also writes a `.img.xz` as it is.

## First boot

Put the card in the Pi, plug in the Ethernet cable, start logging on the
console adapter, then power the Pi. On the console you see, in order:

1. BL31's banner, `NOTICE:  BL31: v2.15.0(release):v2.15.0` and a second
   line. Nothing at all means the bootloader is too old or the card is
   bad (see "When something fails").
2. bootstrap's memory line: `Total RAM: 948.0 MiB; available for
   Bootstrap/Sigma0/Kernel: 948.0 MiB`.
3. `Starting kernel at`, the erXos banner with `development build:
   trusted code only`, and Fiasco's start-up lines, `DT Platform:
   Raspberry Pi 4 Model B` among them.
4. After a minute or less, `rc: the command shell` and the `%` prompt.

At the prompt, try:

```sh
erl                 # the Erlang shell: (root_1@erxos)1>
1 + 2.              # prints 3
q().                # back to the command shell
dmesg               # the kernel's and the system's log
```

On the screen, the firmware's rainbow square and boot text give way to
the dashboard within about 60 seconds of the erXos banner. The console
shows `packages: admitted dashboard`, `erx_app: mounted /app` and
`erx_dashboard: shown`. `dmesg` holds a line `erx: device tree: /chosen:
framebuffer WIDTHxHEIGHT STRIDE FORMAT` (on a 1920x1080 screen the size
is `1920x1080`) and the display domain's `erx_fb: framebuffer ...` line
with the same numbers. `framebuffer absent` or `erx_fb: the framebuffer
is not driven:` names why there is no picture. Use HDMI0.

The root task also reports `erx: root task: board watchdog 4`: the
hardware watchdog is armed with a 4 second timeout, so a hung machine
resets itself and boots again.

## Check the SD card and Ethernet

Run these once after a change to the SD driver, the Ethernet driver or
the DHCP client. In the steps, `%` is the command shell's prompt.

1. **The card is identified.**

   ```sh
   dmesg | grep erx_blk
   ```

   prints `erx_blk: SD card, high capacity, N sectors, 4-bit bus at F Hz`
   (N times 512 is the card's size) and `erx_blk_service: partition table
   admitted; W windows`. `dmesg | grep erx_lfs` prints `erx_lfs: volume
   mounted`. A line `erx_blk: the SD card is not driven: REASON` means
   the driver refused the card, and REASON says at which step.

2. **`/data` is the card's volume.** `mount` lists `PID:/data on /data
   (littlefs)`. On a freshly written card `ls /data` prints nothing.
   Then

   ```sh
   echo written on the board > /data/hello
   cat /data/hello
   ```

   prints `written on the board`. A read-only error (`erofs`) means the
   session holds no `data` grant; an I/O error (`eio`) means no volume
   is behind it, which step 1's lines explain.

3. **`/data` survives a reset.** Wait five seconds, press Ctrl-G (the
   console prints `erx_console: Ctrl-G menu`), press `s` for the system's
   command shell, type `erl` and then `init:reboot().`. The board resets
   and boots again from BL31's banner. At the `%` prompt,
   `cat /data/hello` prints `written on the board`. (`erlang:halt().`
   asks for the machine to turn off instead, and the board halts in the
   firmware.)

4. **The Ethernet link is up.** `dmesg | grep erx_genet` prints
   `erx_genet: GENET v5, mtu 1500` and `erx_genet: link up, 1000 Mb/s
   full duplex` (100 or 10 Mb/s with a slower switch port). `erx_genet:
   the network device is not driven: REASON` means the driver refused the
   controller.

5. **A DHCP lease.** `ifconfig genet0` prints the board's `ether` address
   and an `inet A netmask M broadcast B` line, where A is the leased
   address, and `status: active`. With no `inet` line, run it again after
   30 seconds. `status: no carrier` means the link is down.

6. **The gateway answers.** With G the router's address:

   ```sh
   ping -c 3 G
   ```

   prints three `64 bytes from G` lines and `0.0% packet loss`.

7. **Names resolve.** `host www.freebsd.org` prints one or more `has
   address X` lines; `ping -c 3 X` shows replies from beyond the router.
   `;; connection timed out; no servers could be reached` means the lease
   named no name server that answers.

## Load code over SSH

[Loading code into a running machine](loading-code.md) explains the model
and what works today; this section is the board's steps.

On a development image you can replace a module of the running system
without writing a new card or rebooting. From your host, with the board
on the network and your key in root's `authorized_keys` (see "What is on
the card"):

```sh
tools/erx load --ssh ssh://root@BOARD-ADDRESS:2222 --system my_module.erl other.beam
```

`--ssh DEST` runs `ssh` for you, so your ssh configuration, agent and
known hosts apply. `DEST` is OpenSSH's destination, `[user@]host` or
`ssh://[user@]host[:port]`; the board listens on port 2222, so give the
port in the `ssh://` form or in your ssh configuration. Each file is a
compiled `MODULE.beam` or an Erlang source, which the tool compiles
first. `--system` loads into the system domain. The tool names exactly
one of `--ssh` and `--socket`, and exactly one of `--system` and
`--domain D`; no code facet is granted yet, so `--domain D` over SSH is
refused with `load: no code facet`.

The tool sends every module of the batch to the board over the SSH
connection, and the board's session loads them as one batch: either every
module is current afterwards or none changed. A batch larger than the code
protocol allows (`abi/services/code.txt`) is refused. A module name may hold letters, digits, `_`,
`.`, `-` and `@`, and may not begin with `-`; the tool refuses `DEST` and
names that break these rules before it starts `ssh`. On success it
prints one line, `loaded NAME ... (sent N of M modules)`. A failure
prints `load: NAME: REASON` on standard error, as the board reports it,
and the exit status is 1. After 120 seconds the tool gives up and stops
`ssh`; the outcome is then unknown, so check the board before you rely
on it.

To load each source of a directory when it changes, use `tools/erx watch
--ssh DEST --system DIR` (`--interval SECONDS` sets how often it looks).

On the board's own `rc` the same command is `load -s FILE.beam ...`, or
`load -s -m MODULE:BYTES ...` to read modules from standard input;
`load -v` prints each module with its hash.

**Whoever holds a key in root's `authorized_keys` can load code into the
system domain.** On development images root's SSH session holds the
install facet, and code loaded into the system domain runs with that
domain's authority, which reaches every domain. Treat each key in a
development card's `authorized_keys`, on partition 1 and in
`/root/.ssh/authorized_keys`, like root's password: put only keys you
control on the card, and remove a key from both files when you stop
trusting it. Release images carry no login key. Development images are
for trusted code only, as the boot banner says.

## Netbooting from a Mac

While you iterate on the boot image, the board can boot each build over
an Ethernet cable from your Mac instead of from a newly written card.
The card stays in the board and is written once. The unknown boot and the
TFTP address handling below are unconfirmed on a board, so keep the console log and `dnsmasq`'s log of your first
netboot.

**This is a development setup only.** With the network first in the boot
order, whatever answers DHCP and TFTP on the board's network chooses the
kernel the board runs, and that kernel then reads the card's `/data`,
the SSH host key and root's `authorized_keys` among it. Before a board
leaves your desk, restore the SD-card boot order with Imager's
*Bootloader > SD Card Boot* image, as in "Update the bootloader".

What differs from a card boot: a network boot loads no slot's partition,
so the board comes up as an unknown boot and starts no `system` window.
The `system` tree is empty and the packages in the system partition,
the kiosk among them, are absent. `/data`, root's `authorized_keys` and
the boot-selection record's volume still come from the card. A/B slots and
trials are tried only with the card first in the boot order.

A fresh checkout or git worktree builds nothing until its sources are
fetched and its tools bootstrapped: `tools/erx fetch` (with `--cache DIR`
it takes them from another checkout's `build/downloads` instead of the
network; `ERX_SOURCE_CACHE=DIR` points the setup steps at the same
directory), then `make oracle-bootstrap`.

You need the board, adapter and written card above, an Ethernet cable from
the Pi to the Mac (a USB Ethernet adapter on a Mac without a port) and
Homebrew's `dnsmasq` (`brew install dnsmasq`), which serves TFTP only.

1. **Set the EEPROM's boot order, once.** Write this `boot.conf`, with
   `TFTP_IP` the Mac's address on the cable from step 2:

   ```
   [all]
   BOOT_UART=1
   BOOT_ORDER=0xf12
   DHCP_TIMEOUT=5000
   TFTP_FILE_TIMEOUT=120000
   TFTP_IP=192.168.2.1
   ```

   `BOOT_ORDER` is read right to left: network, then the SD card, so a
   Mac that does not answer costs 5 seconds before the card boots.
   `BOOT_UART=1` puts the bootloader's DHCP and TFTP progress on the
   console. `TFTP_FILE_TIMEOUT` gives each file 120 seconds, since a
   development `kernel8.img` is about 70 MB. If the bootloader's log shows
   no address, also set `CLIENT_IP` (a free address on the cable's subnet)
   and `SUBNET` (`255.255.255.0`); with those and `TFTP_IP` it skips DHCP.
   Use a bootloader of 2025-09-23 or later.

   Put the configuration in the EEPROM with a recovery card. From
   `raspberrypi/rpi-eeprom`'s `firmware-2711/default/`, take
   `recovery.bin` and the newest `pieeprom-DATE.bin`, then

   ```sh
   python3 rpi-eeprom-config --config boot.conf --out pieeprom.bin pieeprom-DATE.bin
   printf '%s\nts: %s\n' "$(shasum -a 256 pieeprom.bin | cut -d' ' -f1)" "$(date -u +%s)" > pieeprom.sig
   ```

   and copy `recovery.bin`, `pieeprom.bin` and `pieeprom.sig` to a FAT32
   card. Boot the Pi from it; a green screen and a rapidly flashing green
   LED mean the EEPROM is written. Put the erXos card back.

2. **Share the Mac's link, each session.** In System Settings > General >
   Sharing, turn on Internet Sharing from the Mac's internet connection to
   the adapter the cable is on (`networksetup -listallhardwareports`
   names it). `ifconfig` shows the bridge it made, often `bridge100`,
   with the Mac's address on the cable; check that it is the `TFTP_IP` of
   step 1.

3. **Stage each build.** After `tools/erx pack --platform raspi4b --medium`, run

   ```sh
   tools/erx netboot
   ```

   It copies the boot files the card's build record lists into
   `~/erxos-tftp` (`--tftp DIR` names another), checks each against the
   record's SHA-256, and switches the TFTP root to the new build in one
   step. Stage while the board is off: a boot already under way can read
   its first files from the earlier build. It prints the commit, the
   `kernel8.img` digest and a `dnsmasq` command line with `INTERFACE` for
   the bridge of step 2. Run that line in a terminal of its own (it needs
   `sudo` to bind port 69, then runs as you; Ctrl-C stops it). `sudo` runs
   Homebrew's binary, which your account can rewrite, as it does Homebrew's
   other tools run as root. `tools/erx netboot` refuses a `~/erxos-tftp`
   that is a real directory. It keeps serving every later
   build. Power the Pi.

On the console you see the bootloader's DHCP and TFTP lines, then the
lines of "First boot" from BL31's banner on, with an `erx: boot value ...
slot ...` line naming the boot the firmware handed over. `dnsmasq` logs
each file it sends by its full path, which names your home directory:
cut it from the paths before a log goes anywhere public.

### Booting over HTTP

A board whose EEPROM boots over HTTP (boot order `0xf17`) fetches
`boot.sig` and then `boot.img` from `HTTP_HOST` under `HTTP_PATH`, and
boots the image only when the signature verifies against the public key
the EEPROM holds. Setting up that EEPROM is not covered here. With it in
place, after `tools/erx pack --platform raspi4b --medium`:

```sh
tools/erx netboot --key ~/keys/private.pem
tools/erx netboot serve
```

The first packs the boot files the card's build record lists into one
signed FAT image, its `cmdline.txt` ending in `erx.arg=` and a fresh
boot name, and points `~/erxos-http` (`--http DIR` names another) at it.
The key is the RSA-2048 private key whose public half the EEPROM holds;
it must be a file you own with no permission for group or others
(`chmod 600`), and it is read once, never copied. The second answers
`/erxos/boot.sig` and `/erxos/boot.img` and no other name at
`192.168.2.1:8080`, Internet Sharing's address on the cable (`--bind`,
`--port` and `--prefix`, the EEPROM's `HTTP_PATH`, name others), and
logs each request; Ctrl-C stops it. It keeps serving every later stage.

## When something fails

* **Nothing on the console, green LED on.** The bootloader is too old:
  reflash it as above. A card with one boot partition still boots on such
  a board, which tells an old bootloader from a bad card.
* **BL31's banner, then silence.** The card's `serial0` is not the mini
  UART the adapter is wired to; every stage after BL31 then writes UART0
  and the root task refuses the manifest. Check that the card was written
  from this build.
* **A domain ends.** `dmesg` shows `erx_domain: configured domain NAME
  (domain N) ended, REASON; restarting it`. For a fault, REASON is
  followed by where it struck: `{fault,K} at pc 0xP, cause 0xC, addr
  0xA`. `{fault,7}` is an asynchronous error; its pc is only presumed.
* **`erx_starter: start.conf cannot be read: eio`.** While the storage
  domain serves no volume, `/data` answers `eio`; this is a symptom of the
  card check's step 1 failing, not a fault of its own.

To report a failure, send the whole console log from power-on, the
failing command and what it printed, and `dmesg` typed right after it.
Name the card's make and size and, for an Ethernet step, the switch or
router the cable goes to.
