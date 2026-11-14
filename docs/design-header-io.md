# The Raspberry Pi 4's header: GPIO, I2C, SPI and PWM

The Raspberry Pi 4 Model B brings 28 of its SoC's general-purpose pins,
GPIO 0 to 27, out to its 40-pin header, and four kinds of block can
drive them: the GPIO controller itself, the I2C masters (Broadcom's BSC),
the SPI masters and the PWM controllers. This document says which domain
holds each block, how a pin comes to belong to one of them, the file trees
their holders serve, how another domain is granted a pin or a bus, where
the bus clocks come from, and the first three consumers: a TPM module on
SPI for the vault, a real-time clock module on I2C, and an LED and a
button on GPIO. It extends the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule) and the
Raspberry Pi 4's placement in
[design-platforms.md](design-platforms.md#what-the-manifest-says). The
random generator, the watchdog, the firmware's mailbox and audio are
decided elsewhere and are not covered here.

In this document "GPIO *n*" is the SoC's pin number and "header pin *p*"
is the physical pin of the 40-pin header; the two differ (GPIO 17 is
header pin 11).

Decisions every reader needs:

* **One pin map per board decides every pin's owner.** The platform
  record holds a **header map**: one row for each of GPIO 0 to 27, naming
  what the pin is for (a bus device of the record, the console, the host
  link, JTAG, a reserved use, or plain GPIO) and, for a bus pin, the
  alternate function the datasheet gives it. Everything that depends on
  pins is generated from that one table: the `gpio=` lines of `config.txt`
  that make the firmware set each bus pin's function before the kernel
  runs, the set of pins the GPIO driver may ever touch, and which bus
  devices are driven. No driver sets another block's pins at run time.
* **The firmware sets the bus pins; the GPIO driver touches only GPIO
  pins.** The console's, the host link's, the HAT EEPROM's and JTAG's
  pins, and every bus pin, are outside the GPIO driver's set by
  construction, not by a list of exceptions.
* **A pin, a chip select or a PWM channel is held by one grant at a
  time.** The first grant to open one of its files holds it; another
  grant's open answers `ebusy`; the hold ends when the holder's last file
  on it is closed or the holder's grant ends, and the resource goes back
  to its idle state. There is no release verb to forget.
* **Plan 9 style trees, one per block.** `/dev/gpio`, `/dev/i2c1`,
  `/dev/spi0`, `/dev/pwm0` and `/dev/rtc`, each served by its driver
  through `erx_fs` and reached through a facet the manifest grants. Each
  `ctl` takes one short line; inspection state goes to `/proc`.
* **Transfers are polled.** The I2C and SPI drivers bind no interrupt
  line: every wait has a deadline computed from the transfer's length and
  the bus speed. Only GPIO edge events use an interrupt.
* **Bus clocks are board facts.** I2C and SPI divide the core clock, which
  `config.txt` fixes from the record's value; the PWM clock is set once
  at boot from the crystal oscillator. No driver hard-codes a clock rate.

## Context

### The hardware

From the BCM2711 ARM Peripherals datasheet (release 1, build 2022-01-18;
cited as DS with its section), the Pi 4's reduced schematics and
Raspberry Pi's documentation:

| Block | Registers | Interrupt | Notes |
| --- | --- | --- | --- |
| GPIO | `0x7e200000`, one page: GPFSEL0-5 (3 bits a pin: `000` input, `001` output, the rest alternate functions), GPSET, GPCLR, GPLEV, event status GPEDS, rising and falling edge enables, and four pull registers GPIO_PUP_PDN_CNTRL_REG0-3, 2 bits a pin (DS 5.2) | four lines, one per bank and one for all (DS 5.1); VC IRQs 49 to 52 (DS 6.2.4, Table 102), record lines 145 to 148 | bank 0 is GPIO 0 to 27, all on the header (DS 5.1; schematics, J8) |
| I2C (BSC) | BSC0 `0x7e205000`, BSC1 `0x7e804000`, BSC3 `0x7e205600`, BSC4 `0x7e205800`, BSC5 `0x7e205a80`, BSC6 `0x7e205c00`; eight registers C, S, DLEN, A, FIFO, DIV, DEL, CLKT; a 16-byte FIFO; DLEN 16 bits (DS 3.2) | VC IRQ 53, "OR of all I2C", record line 149; the OR takes I2C0 to I2C7, the HDMI masters BSC2 and BSC7 included (DS 6.2.4, Figure 6) | BSC2 and BSC7 "are dedicated for use by the HDMI interfaces and should not be accessed" (DS 3.2); SCL = core clock / CDIV, CDIV rounded down to even (DS 3.2, Table 30) |
| SPI | SPI0 `0x7e204000`, SPI3 `0x7e204600`, SPI4 `0x7e204800`, SPI5 `0x7e204a00`, SPI6 `0x7e204c00`; CS, FIFO, CLK, DLEN, LTOH, DC (DS 9.5, Table 159) | VC IRQ 54, "OR of all SPI", record line 150 (DS 6.2.4) | SCLK = core clock / CDIV, CDIV even (DS 9.5); the polled procedure is DS 9.6.1; the FIFO takes 64 bytes (DS 9.6.2). PACTL_CS, which says which I2C or SPI master raised its line, lies in this page at `0x7e204e00` (DS 6.2.4) |
| PWM | PWM0 `0x7e20c000`, PWM1 `0x7e20c800`, one page; two channels each; in M/S mode a channel is high for DAT of every RNG cycles of `clk_pwm` (DS 8.1, 8.4, 8.6) | none (DS Table 102) | `clk_pwm` is "nominally 100MHz", set in the clock manager (DS 8.1) |
| Clock manager (CPRMAN) | `0x7e101000`; the datasheet documents only the general-purpose clocks, with the password `0x5a` in bits 31:24, BUSY bit 7, ENAB bit 4, SRC bits 3:0 (`1` the oscillator) and DIVI bits 23:12 (DS 5.4, Tables 99 and 100) | | the PWM clock's control and divisor are at offsets `0xa0` and `0xa4`, in the same format (FreeBSD `bcm2835_clkman.h:36`, `bcm2835_clkman.c:70-72`) |

Record line numbers follow the platform record's convention: the
VideoCore peripheral IRQ plus 96, as the mini UART's line 125 is AUX, VC
IRQ 29.

Alternate functions and power-on pulls per pin are DS 5.3, Table 94: for
example GPIO 2 and 3 are SDA1 and SCL1 in ALT0, GPIO 7 to 11 are SPI0's
CE1, CE0, MISO, MOSI and SCLK in ALT0, GPIO 18 and 19 are PWM0's two
channels in ALT5, GPIO 14 and 15 are the mini UART's TXD1 and RXD1 in
ALT5, GPIO 4 and 5 are UART3's TXD3 and RXD3 in ALT4, and GPIO 22 to 27
are the ARM's JTAG in ALT4.

Further facts that shape the design:

* **The pin level register shows every pin.** "The pin level registers
  return the actual value of the pin" (DS 5.2, Table 74), whatever the
  pin's function. Whoever holds the GPIO page can therefore sample the
  console's receive line, GPIO 15, and with it what is typed at the login
  prompt. Whether the level follows a pin in an alternate function is
  inferred from that sentence and is for the board probe below.
* **The firmware sets pins from `config.txt`.** A `gpio=` line sets a pin
  set's function (`ip`, `op`, `a0` to `a5`) and pull (`pu`, `pd`, `pn`)
  at boot, later lines overriding earlier ones (Raspberry Pi
  documentation, `config_txt-gpio.adoc`); `enable_jtag_gpio=1` puts GPIO
  22 to 27 in ALT4 for the ARM's JTAG (same file). The firmware sets no
  pins from an overlay
  ([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)).
* **The tree writes `config.txt` today** (`tools/lib/erx/boot_partition.rb`):
  `enable_uart=1`, which puts GPIO 14 and 15 in ALT5; the host link's
  pins as a hard-coded table, `OVERLAY_PINS` (`gpio=4=a4,pn`,
  `gpio=5=a4,pu`, lines 50-55); and, on a development card only,
  `enable_jtag_gpio=1` (lines 104-111). So on a development card GPIO 22
  to 27 belong to JTAG.
* **GPIO 0 and 1 are the HAT EEPROM's.** The schematics' J8 note: "These
  pins are reserved for HAT ID EEPROM ... DO NOT USE these pins for
  anything other than attaching an I2C ID EEPROM."
* **GPIO 2 and 3 have pull-ups on the board**, fixed 1.8 kOhm resistors
  (`gpio-on-raspberry-pi.adoc`).
* **The core clock is fixed by `config.txt`.** `core_freq_fixed=1`
  "disables active scaling of the core clock frequency and ensures that
  any peripherals that use the core clock will maintain a consistent
  speed"; the Pi 4's `core_freq` default is 500 MHz, and a 4Kp60 display
  mode raises it (`config_txt-overclocking.adoc`). The datasheet's
  150 MHz and 250 MHz figures for the BSC and SPI are BCM2835 numbers
  (DS 3.2, 9.5), as is the 500 MHz PLLD FreeBSD's clock manager divides
  (`bcm2835_clkman.c:150`).
* **The I2C master can repeat a start only in one way:** a read that
  follows a write to the same device, by starting the write, waiting for
  its TA bit and then setting READ and ST (DS 3.3.2, steps 5 to 7;
  FreeBSD's `bcm2835_bsc.c:34-60` and its transfer, lines 490-660).

### What FreeBSD does

FreeBSD releng/15.1 drives these blocks with `bcm2835_gpio.c`, which
matches `brcm,bcm2711-gpio` and never touches pins a device tree marks
read-only or reserved; `bcm2835_bsc.c`, `bcm2835_spi.c` and
`bcm2835_pwm.c`, which match the BCM2835 strings and divide fixed
BCM2835 clocks (`bcm2835_bscreg.h:33`, `bcm2835_spireg.h:33`); and
`bcm2835_clkman.c` for the PWM clock. A child device claims its pins
with `gpiobus_acquire_pin`, which answers `EBUSY` for a pin already
mapped, and releases them with `gpiobus_release_pin`, which panics on a
pin not mapped (`sys/dev/gpio/gpiobus.c:425-462`). The user interfaces
are ioctls on `/dev/gpioc0`, `/dev/iic0` (`I2CRDWR` over a list of
`iic_msg`, `sys/dev/iicbus/iic.h:35-66`) and `/dev/spigen0.0`
(`SPIGENIOC_TRANSFER`, `sys/sys/spigenio.h:34-52`). The DS3231
real-time clock driver reads seven BCD registers from 0, refuses a time
while the oscillator-stopped flag is set, and clears that flag after a
set (`sys/dev/iicbus/rtc/ds3231.c:479-596`, registers in
`ds3231reg.h`). FreeBSD is the reference for what the protocols do,
not for the Pi 4's clocks.

### What QEMU's model has

QEMU 11.1.3's `raspi.rst` lists the GPIO controller, "Peripheral SPI
controller (SPI)" and "Broadcom Serial Controller (I2C)" as implemented
and PWM as missing. A probe on 2026-11-14 (Apple Silicon macOS, Homebrew
QEMU 11.1.3, `qemu-system-aarch64 -M raspi4b -S` with the monitor's
`info qtree` and `info mtree -f`, no guest code) shows:

* a `bcm2838_gpio` at `0xfe200000`, one page;
* one `bcm2835-spi`, at `0xfe204000` (0x18 bytes): SPI0 only; the rest of
  the page is RAM, so SPI3 to SPI6 are absent;
* three `bcm2835-i2c`, at `0xfe205000`, `0xfe804000` and `0xfe805000`
  (0x24 bytes each), on buses `i2c-bus.0` to `i2c-bus.2`; BSC3 to BSC6
  are absent;
* no PWM; a `bcm2835-cprman` at `0xfe101000` to `0xfe102fff`, whose PWM
  clock output reads 0 Hz;
* `-device ds1338,bus=i2c-bus.1,address=0x68` and `-device m25p16,bus=spi`
  are accepted. The model offers `tpm-tis-i2c` but no TPM on SPI.

Which `i2c-bus.N` is which base, how the interrupts are wired, whether
the flash's chip select is connected and whether GPIO output reads back
on GPLEV are not shown; the QEMU suite below settles them.

### What erXos does today

Nothing drives the header. The Pi 4's platform record
(`config/platforms/raspi4b.json`) has the console's, the host link's, the
network's, the SD controller's and the framebuffer's units, and its
development manifest (`config/manifest/raspi4b-development.txt`) places
them in the system, network, storage and display domains; there is no
devices domain yet. The placement table of
[design-platforms.md](design-platforms.md#what-the-manifest-says) puts
GPIO, I2C and the SPI controllers outside the mini UART's unit in the
devices domain, and a TPM module with the SPI controller it sits on in
the vault's domain. `config.txt` sets the console's, the host link's and
JTAG's pins as above.

## The construction: one map of the header

The design rests on one table. The platform record gains `header`, one
row for each of GPIO 0 to 27, each with a **use** and, for a pin a
block other than GPIO drives, a **function** and a **pull**:

| Use | Meaning | Function and pull |
| --- | --- | --- |
| `gpio` | the GPIO driver serves the pin | none |
| a device path of the record | the pin is that device's, set by the firmware | the function's Table 94 name, such as `SDA1`; the pull, `none`, `up` or `down` |
| `jtag` | the ARM's JTAG, on development cards | the function's name, such as `ARM_TMS` |
| `reserved` | nothing touches the pin | none |

A checked-in table of the SoC's bank-0 pins, `hw/pins/bcm2711.txt`, one
row per pin with its power-on pull and its six alternate functions, is
written from DS 5.3, Table 94, as the CMSIS-SVD files are written from
the register chapters. The Raspberry Pi 4's map is:

| GPIO | Header pin | Use | Function, pull |
| --- | --- | --- | --- |
| 0, 1 | 27, 28 | `reserved` (the HAT EEPROM) | |
| 2, 3 | 3, 5 | BSC1 | `SDA1`, `SCL1`; `none` (the board's pull-ups) |
| 4, 5 | 7, 29 | the host link, UART3 | `TXD3` `none`, `RXD3` `up` |
| 6 | 31 | `gpio` | |
| 7 to 11 | 26, 24, 21, 19, 23 | SPI0 | `SPI0_CE1_N`, `SPI0_CE0_N`, `SPI0_MISO`, `SPI0_MOSI`, `SPI0_SCLK`; `none` |
| 12, 13 | 32, 33 | `gpio` | |
| 14, 15 | 8, 10 | the console, the mini UART | `TXD1`, `RXD1`; `none` |
| 16, 17 | 36, 11 | `gpio` | |
| 18, 19 | 12, 35 | PWM0 | `PWM0_0`, `PWM0_1`; `none` |
| 20, 21 | 38, 40 | `gpio` | |
| 22 to 27 | 15, 16, 18, 22, 37, 13 | `jtag` | `ARM_TRST` to `ARM_TMS` |

The header pins are the schematics' J8. The GPIO pins served are 6, 12,
13, 16, 17, 20 and 21.

**What is generated from it.** The record reader checks the map and the
build derives from it, so nothing else states a pin:

1. **`config.txt`.** Each row with a device use gives one `gpio=N=aK,pX`
   line, K the function's alternate number from the SoC table, X the
   pull; the `jtag` rows give `enable_jtag_gpio=1` on a development card
   and nothing on a release card. The host link's lines come from its
   rows, so `OVERLAY_PINS` is deleted; the console's rows give lines too,
   which agree with what `enable_uart=1` forces.
2. **The GPIO device's record carries `PINS`**, a 28-bit mask of the
   `gpio` rows, through the manifest's device row and the `given` (or
   system domain) record, as the network record carries `MAC`
   ([design-device-tree.md](design-device-tree.md#facts-into-records)).
3. **Which bus devices are driven.** A bus device that a map row names
   has its class's role (below) and a record; a device of the same
   controller that no row names is a row of no kind, held with its unit
   and driven by nobody
   ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).

**What the reader refuses**, each with a diagnostic naming the row: a
map without exactly one row for each of GPIO 0 to 27; a function that is
not one of the pin's six in the SoC table; a device use that is not a
path of the record, or names a device of no kind; the `console` and
`hostlink` paths not each named by exactly their UART's two rows; a
driven bus device that no row names; a `gpio` or `reserved` row with a
function. A pull on a `gpio` row is refused too: a GPIO pin's pull is
its holder's to set.

Every rule about pins follows from the map instead of from a list:

* **Only the GPIO driver writes pin functions and pulls at run time.**
  The firmware writes every bus pin before the kernel runs; the GPIO
  driver writes only pins in `PINS`, and only `000` or `001` into their
  function fields: its register core takes a pin only from the set its
  record gave it and has no way to write an alternate function.
* **The console's, the host link's, the HAT EEPROM's and JTAG's pins are
  never touched**, since none of them is a `gpio` row. On a development
  card GPIO 27 is JTAG's TMS, so a GPIO driver serving "pins 2 to 27"
  would break the probe the card exists to offer; the map makes that
  impossible to write.
* **Only header pins are served.** The map has rows for bank 0 only, so
  the firmware's run-time pins in banks 1 and 2 cannot be named. Bank
  0's function fields lie in GPFSEL0 to GPFSEL2 and its pulls in
  PUP_PDN_CNTRL_REG0 and REG1 (DS 5.2), so no read-modify-write the GPIO
  driver makes reaches a bank-1 or bank-2 field.
* **No driver claims another block's pins.** A bus driver finds its
  pins already set when it starts, so the vault's SPI driver depends on
  no other domain, and there is no claim protocol between drivers.
* **A pin is never both a bus pin and a GPIO pin.** It has one row.

## Placement: units and domains

The unit rule makes the units; the manifest places them.

| Unit | Devices | Line | Holder |
| --- | --- | --- | --- |
| `gpio` | the GPIO controller | 145 (bank 0); 146 to 148 go to no unit, as GENET's second line does | the system domain (Open decision 1) |
| `i2c` | BSC1, driven; BSC0 and BSC3 to BSC6, which share BSC1's line and BSC0's page, and BSC2 and BSC7 where the board's tree lists them, of no kind | 149, shared | the devices domain |
| `spi` | SPI0, driven; SPI3 to SPI6 of no kind, which share its page and line | 150, shared | the devices domain; the vault's domain on a manifest with a TPM |
| `pwm` | PWM0, driven; PWM1 of no kind, on the same page | none | the devices domain |
| `clocks` | the clock manager | none | the system domain (Open decision 2) |

The device-kind table (`include/erx/device_kinds.h`) gains a row per
driven class, `gpio`, `i2c`, `spi`, `pwm` and `clock`, each a new value
of `mf_device_role`, with its peripheral's CMSIS-SVD source written from
the datasheet (`hw/svd/bcm2711_gpio`, `bsc`, `bcm2711_spi`, `pwm`, and
`cprman` naming only the PWM clock's two registers). The compatible
strings are the board's tree's, which the board probe lists; FreeBSD
matches `brcm,bcm2711-gpio`, `brcm,bcm2835-i2c`, `brcm,bcm2835-spi`,
`brcm,bcm2835-pwm` and `brcm,bcm2711-cprman`, which is what the rows
expect until the probe says otherwise.

**Why GPIO goes with the console.** The GPIO page sets the functions of
the console's pins and shows their levels (DS 5.2, Table 74). A domain
that holds it can take the console's line away by changing GPIO 14's
function, and, if the level register follows a pin in ALT5 as DS 5.2
reads, can read what is typed at the login prompt by sampling GPLEV0 bit
15, against the rule that "no domain can read a passphrase typed at the
login prompt" ([design-system.md](design-system.md#devices)). The
design already puts the console's UART unit in the system domain for
that reason; the page that controls the UART's pins belongs with it.
The cost is the GPIO driver and its tree in the trusted base, a few
hundred lines of Erlang over one pure core. The clock manager goes there
for the same reason: it clocks the UARTs and the SD controller, so a
holder outside the trusted base could stop them.

**The TPM takes the whole SPI unit.** SPI0 and SPI3 to SPI6 share one
page and one line, so a manifest that gives the TPM module's controller
to the vault's domain gives it all five, and the devices domain then
serves no SPI tree. That is the placement
[design-platforms.md](design-platforms.md#device-secrets) already
states; the unit rule only makes explicit that it takes all of SPI.

**I2C and SPI interrupts are not used.** Line 149 carries every I2C
master's interrupt, the HDMI masters' included
(DS 6.2.4, Figure 6), and the register that says which master raised it
lies in the SPI unit's page. Polling needs neither, and the transfers
are short (below). Each unit's line still has its IRQ object, made by
the give, and nothing binds it.

## Clocks

**The core clock.** I2C and SPI divide the VideoCore's core clock. The
record's BSC1 and SPI0 rows carry it as their `clock`, as the PL011s
carry theirs, and the record reader refuses rows that disagree. The
`config.txt` writer emits `core_freq=` and `core_freq_fixed=1` from that
one value, as it emits `init_uart_clock` from the PL011s' (`pl011_clock`
in `boot_partition.rb`), so the firmware is asked for exactly the rate
the drivers divide. The Pi 4's value is 500 MHz, the documented default;
the board checklist measures it (below), and a record with a display
mode that raises the core clock is the display design's to refuse. The
mini UART is unaffected: the firmware programs its divisor for the clock
it fixed.

**The PWM clock.** No firmware setting sets `clk_pwm`, and its source,
the clock manager, holds every clock of the SoC. At boot, before the
configured domains are created, the system domain's `erx_cprman` writes
the PWM clock once, as FreeBSD's `bcm2835_clkman_set_frequency` does
(`bcm2835_clkman.c:118-178`) but from the crystal oscillator, SRC `1`
(DS 5.4, Table 99), instead of a PLL whose BCM2711 rate no permissive
source gives: stop the clock, wait for BUSY to clear, at most 10 polls
1 ms apart, write DIVI, enable with SRC `1`, wait for BUSY to set, and
then ends. The PWM row's `clock` is the target rate and the clock
manager's row's `clock` the oscillator's, both from the board's tree; the
record reader refuses a target that does not divide the oscillator by an
integer from 2 to 4095. With a 54 MHz oscillator (to be confirmed from
the board's tree) the target is 27 MHz, DIVI 2, a resolution of 37 ns.
A clock that does not start is logged and the PWM tree answers `eio` to
`enable`; nothing else depends on it. Under QEMU the model has no PWM.

## The trees

Each block's driver serves its tree through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
`ctl` file takes one line of at most 32 bytes, with or without its
newline, and any other write fails with `einval`, as the device
service's `ctl` does ([design-system.md](design-system.md#devices)).
Reads of `ctl` fail with `eacces`. Names are plain decimal or hexadecimal
digits, so no name needs escaping.

### `/dev/gpio`

One directory per pin of the grant's scope, named by its GPIO number
(`6`, `12`, ...), each holding:

* `ctl`: `in`; `out 0` or `out 1`, which sets the level and the
  direction in one step, so an output never starts at a stale level;
  `pull up`, `pull down` or `pull none`; `edge rising`, `edge falling`,
  `edge both` or `edge none`.
* `value`: a read at offset 0 answers `0\n` or `1\n`, the pin's level,
  and at any other offset nothing, so `cat` prints one line; a write of
  `0` or `1` sets an output's level and fails with `einval` on an input.
* `event`: a read waits until an enabled edge has occurred since the
  handle's last read, or since its open, and answers the level then, as
  `0\n` or `1\n`. Edges between two reads coalesce, as the event status
  bit does (DS 5.2). With `edge none` a read fails with `einval`, and a
  waiting read is answered `einval` when the edge is turned off. A flush
  cancels a waiting read.

A pin's **idle state** is input with no pull and no edge detection: the
state that drives nothing. The driver puts every pin of `PINS` in it at
its start, and a pin returns to it when its hold ends, so no holder
inherits another's settings.

### `/dev/i2c1`

One directory per 7-bit address from `08` to `77`, two lower-case
hexadecimal digits; the reserved addresses below and above, the general
call among them, have no file (the I2C-bus specification's ranges, not
checked against it for this design). Each holds three files that differ
only in how a register address precedes the data, so no file has a mode
to set:

* `data`, size 0: a write is one write transfer of its bytes; a read is
  one read transfer of the bytes asked; the offset is ignored.
* `reg8`, size 256: a read at offset N writes the byte N, repeats the
  start and reads, ending at 256; a write at offset N is one write
  transfer of N and the bytes, refused with `einval` past 256.
* `reg16`, size 65536: the same with a two-byte big-endian register
  address, as 24C32-class EEPROMs take.

A transfer is at most `i2c_transfer_max` bytes, 4096: a longer read
returns that many, and a longer write fails with `einval` rather than be
split, since a split would change what the device sees. The bus runs at
100 kHz, the standard rate, CDIV the record's clock divided by 100,000
and rounded up to even, so the bus never runs faster than asked; there
is no `ctl` and so no bus-wide setting one grantee could change under
another. A device that does not acknowledge answers `eio`, as FreeBSD's
driver answers it (`bcm2835_bsc.c:612-614, 648-649`); a clock-stretch
timeout (CLKT) or a transfer past its deadline answers `etimedout`.
`cat /dev/i2c1/68/reg8 | od -x` dumps a device's registers.

### `/dev/spi0`

One directory per chip select, `0` (CE0, GPIO 8) and `1` (CE1, GPIO 7),
each holding:

* `ctl`: `mode 0` to `mode 3` (CPOL and CPHA); `speed HZ`, from 7,630 Hz
  (CDIV 65534) up to the rate CDIV 2 gives, met with the smallest even
  divisor that does not run the bus faster than asked. The settings belong to the holder
  and return to `mode 0` and 1 MHz when the hold ends.
* `data`: a write of at most `spi_transfer_max` bytes, 4096, is one
  transfer with the chip select held for all of it; the bytes clocked in
  during it are kept for the handle's next read, which returns them and
  drops them. A read with nothing kept returns nothing. A longer write
  fails with `einval`.

### `/dev/pwm0`

One directory per channel, `0` (GPIO 18) and `1` (GPIO 19), each holding
`ctl`: `period NS`, `duty NS`, `enable`, `disable`. The channel runs in
M/S mode: RNG is the period and DAT the high time, each in ticks of the
PWM clock, rounded to the nearest tick (DS 8.4). `enable` fails with
`einval` while the period is under one tick or more than 2^32 - 1 ticks,
or the duty is longer than the period; a `period` or `duty` that would
break that rule on an enabled channel fails the same way and changes
nothing. A channel is disabled with period 0 when its hold ends.

### `/dev/rtc`

One file, `time`. A read answers the UTC time as decimal seconds since
1970 and a newline. A write of such a line sets the clock. The years
are 2000 to 2099, the chip's two BCD digits; a write outside them fails
with `einval`. A read fails with `einval` while the chip's
oscillator-stopped flag is set, as FreeBSD's refuses
(`ds3231.c:493-494`), with `eio` when the chip does not answer, and with
`eio` when the registers do not decode (below). The driver writes the
chip only when `time` is written, never at its start, so a different
device at the same address is read and never written.

## Holding and granting

**The hold.** One pure core, `erx_hold`, shared by the GPIO, SPI and PWM
trees, decides who holds a pin, a chip select or a channel. Its state is
a map from resource to holder, a grant, and the holder's open handles on
it; its events are an open by a grant, the close of a handle, and a
grant's end. An open of any file of a resource by a grant that does not
hold it, while another grant does, answers `ebusy`; an open by the
holder, or of a free resource, succeeds and adds the handle. When the
holder's last handle on the resource closes, or the holder ends, the
core answers the resource's release, and the driver puts it in its idle
state. The tree's `open/3` runs in the grant's own process
(`erx_fs_grant.erl:685`), so it names the grant by `self()`; the driver
monitors each holder, so a grant that ends without closing its handles
still releases. I2C needs no hold: every transfer is whole, the driver
serializes them, and holding the bus is holding every device on it.

This is FreeBSD's acquire-or-`EBUSY` rule, with the release made a
consequence of closing or ending instead of a call a client must make.

**Grants.** Each tree is a service of its holder, of an interface that
`abi/services` declares, granted by `facet` rows as the storage domain's
`data` is ([design-system.md](design-system.md#facets-a-configured-domain-serves)):

| Service | Interface | Parameters | Mount point |
| --- | --- | --- | --- |
| `gpio` | `gpio` | `pins`, a set of GPIO numbers, optional, checked by `gpio_grant` to lie in the map's `gpio` rows; without it the grant shows every served pin | `/dev/gpio` |
| `i2c1` | `i2c` | none | `/dev/i2c1` |
| `spi0` | `spi` | none | `/dev/spi0` |
| `pwm0` | `pwm` | none | `/dev/pwm0` |
| `rtc` | `rtc` | `bus`, a device; `chip`, an identifier of a closed set (`ds3231`); `address`, 8 to 119; checked by `rtc_grant`, which refuses rows of one server that disagree | `/dev/rtc` |

The `pins` parameter is how an app gets its LED's pin and no other, with
the existing typed scope parameters of a facet row; its grant's tree has
directories for those pins alone. A domain mounts each granted facet at
its point, from `erx_ns`'s table of facet mounts
([design-files.md](design-files.md#building-binding-and-mounting)); each
point is an empty directory of every release. Under an administrator's
`/dev`, the device service's tree, the mounts resolve by the longest
prefix, so `ls /dev` lists the catalogue and not the trees: no union
mount exists, and none is added for this.

The interfaces' limits, `i2c_transfer_max`, `spi_transfer_max` and
`header_ctl_max` (32), are declared with them, so the drivers and the
host tests take them from one place.

**The RTC's configuration is its grant.** Which chip answers the clock,
on which bus and at which address, is written on the facet row that
grants `rtc`, normally to the system domain. The mint starts the chip
driver at its first grant; a manifest with no `rtc` row starts none.
Nothing starts because the module might exist.

## Drivers

Each block has one driver process in its holder, under the holder's
supervisor (a configured domain's unit supervisor, or a supervisor of
the system release), over the device NIF, in an application per device
class: `erx_gpio`, `erx_i2c`, `erx_spi`, `erx_pwm` and `erx_rtc`. Each
splits as every erXos driver does
([style](style.md#functional-core)): a pure core that decides, a thin
module that reads and writes the registers by name, and the tree module.

| Core | Decides |
| --- | --- |
| `erx_hold` | the holder of each pin, chip select and channel, as above |
| `erx_gpio_core` | the `ctl` grammar; from a pin in `PINS` and a request, the register writes: the GPFSEL field (register `pin div 10`, shift `3 * (pin rem 10)`), the pull field (register `pin div 16`, shift `2 * (pin rem 16)`), GPSET or GPCLR, the edge enables; from a GPEDS0 value, the served pins that fired and the bits to clear |
| `erx_bsc_core` | a transfer as a state machine: from the request and each status read, the next action (fill or drain the FIFO, start, repeat the start, finish) and its result; the deadline |
| `erx_spi_core` | the `ctl` grammar, the divisor, and the polled transfer of DS 9.6.1: from the CS flags, what to write to and read from the FIFO next |
| `erx_pwm_core` | the `ctl` grammar and RNG and DAT from period, duty and clock |
| `erx_rtc_ds3231` | the seven time registers to seconds and back |

**Polling.** A transfer polls its controller's status register in a
tight loop of at most 64 reads, then once a millisecond, until its
**deadline**: four times the time its bits take at the bus speed, plus
10 ms, a pure function of the core. An I2C read of 7 bytes at 100 kHz
takes about 0.8 ms of bus time; a 4096-byte transfer about 0.4 s, the
longest a client waits behind another's transfer. A transfer past its
deadline answers `etimedout`, and the driver clears the FIFO, clears the
status bits and disables and enables the controller before the next.
FreeBSD's wait for TA before a repeated start has no bound
(`bcm2835_bsc.c:610-617`); here it is one of the polls under the
deadline.

**GPIO events.** The GPIO driver binds line 145, a direct line, with
`erx_irq_line:attach/2`. A delivery reads GPEDS0, clears the bits of
`PINS` that are set, counts an edge for each, answers the `event` reads
waiting on those pins, and acknowledges. It enables edge detection only
on pins of `PINS`; the board probe checks that nothing else enables
detection on bank 0 at boot, since a bit outside `PINS` is never cleared
and a level held on it would raise the line again.

**What a device returns is untrusted.** Bytes read from an I2C or SPI
device go to the client unchanged and unparsed. The RTC driver is the
one parser of device output here: `erx_rtc_ds3231` takes the seven bytes
from register 0 (seconds, minutes, hours, weekday, date, month with the
century bit, year; `ds3231reg.h`) and accepts them only when every
nibble is a decimal digit and each field is in range for its place
(seconds and minutes below 60, hours below 24 or 1 to 12 with the PM bit,
a date the month has, months 1 to 12); anything else is `eio`, never a
time. The century bit is ignored and the year is 2000 plus the BCD
year. The parser has a fuzz target. The `ctl` grammars parse another
domain's input and share one fuzz target over the three trees' `ctl`
lines and walk names.

**The record's role in a restart.** A driver that crashes is restarted by
its supervisor and resets its block: the GPIO driver puts every pin of
`PINS` in its idle state, the I2C and SPI drivers reset their
controllers, the PWM driver disables both channels. Its holds were its
own state, so they end with it. Each handle carries the driver
incarnation's reference, and the tree reaches the driver by its local
registered name, so a handle of the old incarnation answers `eio` and the
client opens again, as a file client does after a server restart
([design-files.md](design-files.md#building-binding-and-mounting)). A
register access that aborts ends the domain, as everywhere
([design-system.md](design-system.md#devices)).

## The first consumers

**A TPM module on SPI, for the vault.** A manifest with a TPM places the
`spi` unit in the vault's domain. There the TPM driver is the unit's one
driver process; it uses `erx_spi_core` and the SPI register module as a
library, serves no tree, and finds SPI0's pins set by the firmware, so
the TPM's bytes cross no other domain and the vault depends on no other
domain for them. The chip select is the module's, CE0 or CE1, and the
transfer primitive keeps the chip select held across one transfer of up
to 4096 bytes. The TPM's own framing over SPI, its wait states included,
is the TCG PC Client Platform TPM Profile's and the vault's TPM design's;
whether that framing needs to read bytes in the middle of a held
transfer is unverified here, and if it does, the primitive becomes a
list of segments under one held chip select, still one call. QEMU's
model has no TPM on SPI, so this consumer is tested on the board alone.

**An I2C real-time clock, for the wall clock without a network.** A
DS3231 module on GPIO 2 and 3 (header pins 3 and 5, with 3.3 V and a
ground). The manifest grants `rtc` to the system domain with
`chip ds3231`, `address 104` (0x68, the module's usual address,
unverified against Maxim's datasheet here) and `bus` naming BSC1's row.
The system domain's wall-clock keeper, designed with network time, reads
`/dev/rtc/time` at boot as one bounded line of at most 21 bytes and
writes it after each correction; how it ranks the RTC against network
time is that design's. A board without the module reads `eio`, and the
inspector shows the RTC absent.

**An LED and a button on GPIO.** An LED with its resistor from GPIO 13
(header pin 33) to a ground pin: `echo out 1 > /dev/gpio/13/ctl`. A
button from GPIO 16 (header pin 36) to a ground pin: `echo pull up >
/dev/gpio/16/ctl`, `echo edge falling > /dev/gpio/16/ctl`, and a read of
`/dev/gpio/16/event` returns at each press. An app granted
`pins [13, 16]` sees those two directories and nothing else.

## Inspection

Each driver reports to its domain's inspector, at
`[domains, D, header, Block, ...]`, shown under `/proc/domains/D/header/`
([design-live.md](design-live.md#the-proc-tree)), a schema addition of
the inspector: for each served pin its holder (a `proc_id()` of the
grant), direction, pull, edge, level and edge count; for the I2C bus its
transfers, `eio` and `etimedout` counts and its divisor; for each chip
select its holder, mode and actual speed; for each PWM channel its
holder, RNG, DAT and whether it runs, with the clock's state; for the
RTC whether it answers and whether its oscillator stopped. A value the
driver cannot know is `unknown`.

## Concurrency and failure

* Each driver is one process, so its block sees one request at a time:
  an I2C or SPI transfer runs to its end before the next starts, and a
  GPIO register update is one read-modify-write by the one process that
  writes those registers. Requests wait in the driver's queue, bounded by
  each grant's `in_flight`.
* The tree's callbacks run in the grant's processes and call the driver;
  a read that waits, an `event` or a transfer, runs in the file's helper,
  so it holds up no other file of the grant
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* A client that goes away during a transfer does not stop it; the
  driver finishes and drops the answer.
* A device that holds the clock low or never answers costs one deadline
  and a controller reset; it cannot block the bus for longer.
* The firmware writes GPFSEL0 to GPFSEL2 at boot only, as far as its
  documentation says; the board probe checks that it does not later,
  since a firmware write there would race the GPIO driver's
  read-modify-write of a field it does not own.

## Refusals and error results

| Request | Answer |
| --- | --- |
| an open of a pin's, chip select's or channel's file held by another grant | `ebusy` |
| a `ctl` line not in its grammar, longer than 32 bytes, or with bytes after its newline | `einval` |
| a read of a `ctl` | `eacces` |
| a `value` write on an input pin, or of anything but `0` or `1` | `einval` |
| an `event` read with `edge none` | `einval` |
| a walk to a pin outside the grant's `pins`, an address outside `08` to `77`, a chip select or channel the tree does not have | `enoent` |
| an I2C write longer than 4096 bytes, or past the end of `reg8` or `reg16` | `einval` |
| an I2C device that does not acknowledge | `eio` |
| a clock stretched past CLKT, or a transfer past its deadline | `etimedout` |
| an SPI write longer than 4096 bytes | `einval` |
| a PWM `enable` with a period of no ticks or past 32 bits, or a duty longer than the period | `einval` |
| a PWM `enable` whose clock did not start at boot | `eio` |
| an RTC read while the oscillator stopped | `einval` |
| an RTC read with no answer, or registers that do not decode | `eio` |
| an RTC write outside 2000 to 2099, or not a decimal line | `einval` |
| a handle of a driver incarnation that has ended | `eio` |

At build time the record reader refuses a header map as listed above,
and the manifest check refuses a `gpio` row's `pins` outside the map's
`gpio` rows and `rtc` rows of one server that disagree.

## Security

* The console's and the host link's pins and clocks are in the system
  domain's hands alone: the GPIO page and the clock manager are its
  units (Open decisions 1 and 2), and the GPIO driver's register core
  can name only `PINS`.
* A grant reaches only what its tree shows: a GPIO grant its `pins`; an
  I2C grant every device on the bus; an SPI or PWM grant the whole
  controller's chip selects or channels, one holder each.
* Driving a pin is driving a wire. A holder that sets an output against
  something else that drives the same wire can damage the board; that
  is the wiring's, and the operator's, as on any UNIX system that offers
  GPIO.
* The trees show no text a device wrote: I2C and SPI bytes are data to
  the reader, and the RTC answers a number the system domain parses
  with a bound. Inspection values go through the inspector's escaping.
* The RTC's time comes from a device on a bus in the devices domain, so
  the wall-clock keeper treats it as a hint, not as truth; how much it
  trusts it is the time design's.

## Verification

**Host tests of the pure cores.** Every core builds and runs on the
host. Each case is paired with a seeded fault that must make it fail,
so the case is known to reach the code it tests.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_hold`, exhaustive over two grants, two resources and every order of open, close and end up to depth 6 | at most one holder per resource; `ebusy` exactly when another grant holds it; a resource with no handle of its holder is released exactly once | releasing at the first close instead of the last, which a grant with two handles exposes |
| `erx_gpio_core` register writes | `out 1` on GPIO 17 changes only bits 21 to 23 of GPFSEL1 and sets bit 17 of GPSET0; `pull up` on GPIO 21 changes only bits 10 and 11 of PUP_PDN_CNTRL_REG1 | a function shift of `3 * (pin rem 10) + 1` |
| `erx_gpio_core` served set | every request for a pin outside `PINS` is refused, for every pin 0 to 27 and each of the map's rows | the `PINS` check removed |
| `erx_gpio_core` events | a GPEDS0 value with bits inside and outside `PINS` clears and counts only those inside | clearing the whole register |
| `erx_bsc_core` repeated start | a `reg8` read produces DLEN 1, the address byte, ST, a wait for TA, DLEN n, READ and ST, in that order | ST written with READ before TA is seen |
| `erx_bsc_core` errors | a status with ERR answers `eio`, CLKT `etimedout`, and a status that never shows TA or DONE `etimedout` at the deadline | ERR ignored; the deadline removed, which the test's own timeout catches |
| `erx_spi_core` transfer | against a register model that loops MOSI to MISO, every length from 1 to 200 returns what was sent | one byte dropped when the FIFO refills |
| `erx_pwm_core` | 27 MHz, 20 ms period, 1.5 ms duty gives RNG 540000 and DAT 40500; duty above period and zero ticks are refused | rounding down instead of to nearest |
| `erx_rtc_ds3231` | known register images decode to their seconds and encode back; a non-decimal nibble, 60 seconds, February 30 and month 13 are `eio` | the nibble check removed |
| the header map reader | the Pi 4's map is accepted and gives the `config.txt` lines and the `PINS` mask above | for each refusal of the reader, one map that breaks only it: a missing pin, a function not the pin's, the console on GPIO 13, a `gpio` row with a function, a driven bus that no row names |
| the `config.txt` writer | the Pi 4's card has `gpio=2-3=a0,pn`, SPI0's, PWM0's and UART3's lines, `core_freq=500`, `core_freq_fixed=1`, and `enable_jtag_gpio=1` on a development card only | `jtag` rows written as `gpio=` lines on a release card |
| the manifest check, `gpio_grant` and `rtc_grant` | the development manifest passes | a `pins` holding GPIO 14; two `rtc` rows with different addresses |

**Fuzz targets**, landing with the parsers: the trees' `ctl` lines and
walk names, one target over the three grammars; the RTC's register
decoder; the header map reader, as part of the platform record's.

**The QEMU `raspi4b` suite**, under TCG, on the devices the probe found,
with `-device ds1338,bus=i2c-bus.1,address=0x68` and `-device
m25p16,bus=spi` added. Its first run settles the open [Model] questions
and its result is recorded; a case the model cannot run is left out and
named, never passed by default.

| Case | Passes when | Seeded fault |
| --- | --- | --- |
| RTC through `/dev/rtc/time` (the ds1338 keeps the DS3231's time registers 0 to 6, unverified until this case runs) | a written time reads back within 5 s | the driver's register order swapped |
| `/dev/i2c1/68/reg8` | 7 bytes at offset 0 are the BCD of the time just written | the repeated start replaced by a stop and a new start, if the model distinguishes them; otherwise the case only checks the bytes |
| a missing device, `/dev/i2c1/50/data` | the read answers `eio` | ERR ignored, which returns bytes |
| SPI flash identification through `/dev/spi0/0/data` | a write of `9f 00 00 00` reads back the flash's three ID bytes after the first | the chip select field written as 1 |
| GPIO output | `out 1` and `out 0` on GPIO 21 read back on `value`, if the model reflects outputs on GPLEV | GPCLR written for 1 |
| holds | a second session's open of a held pin answers `ebusy`, and succeeds after the first session ends | release on first close |

**The board checklist**, run by hand on the 4 GB board, as 1b-I's other
checks are ([plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap)):

1. **Probe at boot** (the root holds every page on the stopgap, so it
   reads them once and logs them): the device-tree nodes of GPIO, every
   BSC, every SPI, both PWMs and the clock manager with their paths,
   compatible strings, bases, lines and status, which settles the kind
   rows, BSC5's base (the datasheet's `0x7e205a80`) and whether BSC2 and
   BSC7 are listed; GPFSEL0 to GPFSEL2, PUP_PDN_CNTRL_REG0 and REG1 and
   the bank-0 edge enables at boot and after a minute; the PWM clock's
   control and divisor; the oscillator's rate.
2. **GPIO loopback**: a jumper cap on header pins 31 and 32 joins GPIO 6
   and GPIO 12. `out 1` and `out 0` on one read back on the other's
   `value`, with `edge both` on the other, each change answers an
   `event` read. Seeded fault: the same with the jumper removed and
   `pull down` set, which must read `0` whatever the output.
3. **GPLEV and the console**: the probe samples GPLEV0 for a few seconds
   while keys are typed at the console and logs whether bit 15 changes,
   which records whether the level follows a pin in ALT5, the fact Open
   decision 1 rests on.
4. **SPI loopback**: a jumper wire from header pin 19 (GPIO 10, MOSI) to
   header pin 21 (GPIO 9, MISO). 4096 bytes written to
   `/dev/spi0/0/data` read back unchanged at 1 MHz and at 10 MHz; the
   time of 100 transfers at a fixed divisor gives the core clock to 1%.
   Seeded fault: the wire removed, which reads all ones or all zeros.
5. **PWM**: a jumper cap on header pins 11 and 12 joins GPIO 18 to GPIO
   17. With `period 100000000` and `duty 50000000` (10 Hz, half) and
   `edge rising` on GPIO 17, its edge count rises by 10 a second, slow
   enough that no edge coalesces with the next; with `duty 0` it stops.
   Seeded fault: `disable`, after which the count stops.
6. **RTC**: with a DS3231 module on header pins 1 (3.3 V), 3 and 5 and a ground pin, a time
   written survives a power cut of ten minutes within two seconds.
   Seeded fault: the module unplugged, which reads `eio`.
7. **TPM**, on a manifest with one: the vault's TPM driver reads the
   module's identification; its own checks are the vault design's.

## Performance

Polled transfers cost CPU while they wait: up to 64 status reads and
then a timer message a millisecond. That is negligible for the RTC and
the TPM's short transfers and unmeasured for long SPI transfers; the
watch list gets the measurement that settles it, the CPU time and bus
time of 4096-byte SPI transfers at 10 MHz on the board, before any
consumer needs throughput (DMA for SPI, which a display would need, is
out of scope and makes the controller a DMA device of
[design-platforms.md](design-platforms.md#dma)).

## Alternatives considered

* **Run-time pin claims between drivers**, each bus driver asking the
  GPIO driver to set its pins at start. It needs a protocol between
  drivers, a list of pins never to give out, and, with the TPM's SPI in
  the vault's domain and GPIO elsewhere, a dependency of the vault on
  another domain at every start. Letting the firmware set the bus pins
  from one generated map deletes all three. The cost is that changing
  which pins a bus uses needs a new card build, which is also how
  FreeBSD and the Pi's own firmware configure buses: at boot, from
  overlays and `config.txt`.
* **GPIO in the devices domain**, as the placement table had it. It
  keeps the trusted base smaller by the GPIO driver, and gives the
  devices domain the console's pins and their levels (above).
* **Interrupt-driven I2C and SPI.** Line 149 is shared by every I2C
  master, the HDMI masters included, and the register that
  says which one raised it is in the SPI unit's page. Each driver would
  join a line owner and read every master's status at each delivery,
  for transfers that take a millisecond. Polling under a deadline is
  simpler, and interrupts can be added behind the same core if a
  measurement asks.
* **A `ctl` for the I2C bus speed.** Every I2C device supports standard
  mode, no consumer needs fast mode, and a bus-wide setting is state one
  grantee changes under another.
* **Per-address I2C grants.** A `addresses` parameter would let an app
  hold one device on a shared bus. No consumer needs it yet; the bus is
  granted whole.
* **Chips as bus children from the device tree**, described by an
  overlay named in `config.txt`, as FreeBSD and Linux take them. It needs
  a new class of fact in the root's tree reader, overlay files from the
  firmware's distribution on every card, and compatible strings that
  only GPL-licensed overlay sources state. The facet row's parameters
  carry the same three facts, checked by the manifest check, with no new
  mechanism.
* **The core clock from the firmware's mailbox**, read at boot. It widens
  the mailbox chokepoint the design keeps to two functions; fixing the
  clock in `config.txt` from the record gives the same number with no
  run-time authority over the firmware.
* **FreeBSD's ioctl interfaces** (`/dev/iic0`'s `I2CRDWR`,
  `/dev/spigen0.0`'s `SPIGENIOC_TRANSFER`). They are what a ported
  FreeBSD program would call; the trees are what `cat`, `echo` and `od`
  reach, and a POSIX-layer translation of those ioctls onto the trees is
  possible later without changing them.

## Open decisions

1. **GPIO's holder.** The GPIO page controls and shows the console's
   pins. Recommendation: the system domain, with the clock manager,
   which moves GPIO's row of the placement table in
   [design-platforms.md](design-platforms.md#what-the-manifest-says) and
   the list of the devices domain's devices in
   [design-system.md](design-system.md#devices). The alternative keeps
   GPIO in the devices domain and records a security residual: a
   compromised devices domain can take or read the console's line. The
   board checklist's GPLEV step confirms the hazard before the move is
   built.
2. **The PWM clock.** Recommendation: the clock manager in the system
   domain, written once at boot from the oscillator by `erx_cprman`,
   whose SVD names only the PWM clock's two registers. This is a system
   domain process touching a device's registers outside the console and
   host link, which [design-system.md](design-system.md#drivers) says the
   system domain otherwise does not do. The alternative is to build PWM
   only when a consumer needs it, since it is the weakest of the four
   (fan, LED dimming, servos) and QEMU does not model it.
3. **Where a chip on a bus is configured.** Recommendation: the
   parameters of the facet row that grants the chip's tree, as above.
   The alternative is a module row in the platform record, carried to
   the bus's holder in its record, which needs a new record fact and a
   rebuild per module but keeps hardware out of the manifest.
4. **A TPM on SPI or on I2C.** The SPI unit goes whole to the vault, so a
   board with an SPI TPM has no user SPI, and QEMU cannot test it, since
   it models a TPM on I2C only. Recommendation: keep SPI, as
   [design-platforms.md](design-platforms.md#device-secrets) states, and
   test the TPM on the board; an I2C TPM would give the vault the whole
   I2C unit instead, and with it the RTC's bus.
5. **JTAG's pins on a release card.** They stay unserved, so a release
   card serves seven GPIO pins. Recommendation: keep one map for both
   kinds; a map per build kind would serve six more pins on release
   cards at the cost of a second table to keep in step.

## References

* BCM2711 ARM Peripherals, release 1, build 2022-01-18, githash
  `cfcff44`, `https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf`
  (SHA-256 `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78`):
  sections 2.3, 3.1 to 3.3 (Tables 24 and 30), 5.1 to 5.4 (Tables 74,
  94, 99 and 100), 6.2.4 (Table 102, Figure 6), 8.1 to 8.6, 9.5 and 9.6.
* Raspberry Pi 4 reduced schematics,
  `https://datasheets.raspberrypi.com/rpi4/raspberry-pi-4-reduced-schematics.pdf`
  (SHA-256 `0ee3fd2b4976b1d614fc817b0d28564226d3ee8656a9108ccb69c099715d2374`):
  J8 and its ID_SD and ID_SC note.
* Raspberry Pi documentation, commit `c6a64966af136da21a1e55551c5a395cb6987fce`,
  CC BY-SA 4.0: `config_txt-gpio.adoc` (SHA-256
  `4ad5c0286da3f97f4eb0031af2377c11bd89d78c81f92c3c022187b942b454c0`),
  `config_txt-overclocking.adoc` (`b19ff813e00b3b422b3a200b9d3ed1b3acffd272dcc20bf4eda8fa8a676a5b9c`),
  `gpio-on-raspberry-pi.adoc` (`2c6d14324ae8e4972b63e93d7e653c7117189ec9f061d033631a99bf3ca2519f`).
* FreeBSD releng/15.1, commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
  BSD-2-Clause: `sys/arm/broadcom/bcm2835/bcm2835_gpio.c`
  (`783b718c...`), `bcm2835_bsc.c` (`aece9844...`), `bcm2835_bscreg.h`
  (`f5cec4ee...`), `bcm2835_spi.c` (`ea5d8544...`), `bcm2835_spireg.h`
  (`c4401a46...`), `bcm2835_pwm.c` (`8715c3fc...`), `bcm2835_clkman.c`
  (`696bd6c2...`), `bcm2835_clkman.h` (`906eb75a...`),
  `sys/dev/gpio/gpiobus.c` (`1e84e42c...`); and, fetched for this
  design from the FreeBSD GitHub mirror at the same commit,
  `sys/dev/iicbus/rtc/ds3231.c`
  (`62b7d80afdfe892bad7f62dc54518266fcc5c87dfbd95be8ded614ce3dffa046`),
  `sys/dev/iicbus/rtc/ds3231reg.h`
  (`66126c2d3c77cb01e1533de5926983c00ccfbdb395c1fb199338b7ae58bc5e94`),
  `sys/dev/iicbus/iic.h`
  (`baf8ca167587089391fcbd5ac718e85592a83974053d156e18e769a4b1def558`),
  `sys/sys/spigenio.h`
  (`2ac9daeb447df9acf0ba1ce6b14cdbc71e40359f7c8ae89e166cc9076a5c49ce`).
* QEMU 11.1.3, `docs/system/arm/raspi.rst`
  (SHA-256 `379cf16708455fe77de384fea8af12bbde68e66a49610976f3b64b7b7b9931d7`),
  and the probe of the `raspi4b` machine described under Context.
