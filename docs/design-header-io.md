# The Raspberry Pi 4's header: GPIO, I2C, SPI and PWM

The Raspberry Pi 4 Model B brings 28 of its SoC's general-purpose pins,
GPIO 0 to 27, out to its 40-pin header, and four kinds of block can
drive them: the GPIO controller itself, the I2C masters (Broadcom's BSC),
the SPI masters and the PWM controllers. This document says how a pin
comes to belong to one of them, which domain may hold each block, the
file trees their holders serve, how another domain is granted a pin or a
bus, where the bus clocks come from, and the first consumers: a TPM
module on SPI for the vault, a real-time clock module on I2C, and an LED
and a button on GPIO. It extends the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule) and the
Raspberry Pi 4's placement in
[design-platforms.md](design-platforms.md#what-the-manifest-says). The
random generator, the watchdog, the firmware's mailbox and audio are
decided elsewhere and are not covered here.

In this document "GPIO *n*" is the SoC's pin number and "header pin *p*"
is the physical pin of the 40-pin header; the two differ (GPIO 17 is
header pin 11).

Decisions every reader needs:

* **One pin map per board decides every pin's use.** The platform
  record holds a **header map**: the device that sets pin functions, and
  one row for each of GPIO 0 to 27 naming what the pin is for (a bus
  device of the record, the console, the host link, JTAG, a reserved
  use, or plain GPIO) and, for a bus pin, its alternate function and
  pull. Everything that depends on pins is generated from that one
  table: the `gpio=` lines of `config.txt` that make the firmware set
  each bus pin's function before the kernel runs, the set of pins a GPIO
  driver may ever touch, which bus devices are driven, and the manifest
  check that keeps the pin controller out of untrusted hands.
* **The firmware sets the bus pins, so no bus needs a run-time pin
  holder.** I2C, SPI and the vault's TPM work with no domain holding the
  GPIO page.
* **Whoever holds the pin controller holds the console's wires.** The
  GPIO page sets the function and pull of every pin, the console's and
  the host link's included, and reads every pin's level. A manifest
  therefore gives the pin controller to no domain, to the system domain,
  or to a domain that holds only such units, which property 8 of the
  manifest check proves from the header map. The Pi 4's manifests give
  it to no domain, and serve no `/dev/gpio`, until Open decision 1
  settles its home.
* **A pin, a chip select or a PWM channel is held by one grant at a
  time.** The first grant to open one of its files holds it; another
  grant's open answers `ebusy`; the hold ends when the holder's last file
  on it is closed or the holder's grant ends, and the resource goes back
  to its idle state. Every operation is checked against the live hold
  when it is applied. There is no release verb to forget.
* **Plan 9 style trees, one per block.** `/dev/gpio`, `/dev/i2c1`,
  `/dev/spi0`, `/dev/pwm0` and `/dev/rtc`, each served by its driver
  through `erx_fs` and reached through a facet the manifest grants. Each
  `ctl` takes one short line; inspection state goes to `/proc`.
* **Transfers are polled, and a transfer times out only when the wire
  stops.** The I2C and SPI drivers bind no interrupt line. A transfer's
  timeout runs only while the controller has nothing for the driver to
  do, so a driver delayed by its scheduler never fails a healthy device.
* **Bus clocks are board facts.** I2C and SPI divide the core clock,
  which `config.txt` fixes from the record's value. No driver hard-codes
  a clock rate.

## Context

### The hardware

From the BCM2711 ARM Peripherals datasheet (release 4, build 2022-01-18;
cited as DS with its section), the Pi 4's reduced schematics and
Raspberry Pi's documentation:

| Block | Registers | Interrupt | Notes |
| --- | --- | --- | --- |
| GPIO | `0x7e200000`, one page: GPFSEL0-5 (3 bits a pin: `000` input, `001` output, the rest alternate functions), GPSET, GPCLR, GPLEV, event status GPEDS, rising and falling edge enables, and four pull registers GPIO_PUP_PDN_CNTRL_REG0-3, 2 bits a pin (DS 5.2); no lock or protection register | four lines, one per bank and one for all (DS 5.1); VC IRQs 49 to 52 (DS 6.2.4, Table 102), record lines 145 to 148 | bank 0 is GPIO 0 to 27, all on the header (DS 5.1; schematics, J8) |
| I2C (BSC) | BSC0 `0x7e205000`, BSC1 `0x7e804000`, BSC3 `0x7e205600`, BSC4 `0x7e205800`, BSC5 `0x7e205a80`, BSC6 `0x7e205c00`; eight registers C, S, DLEN, A, FIFO, DIV, DEL, CLKT; a 16-byte FIFO; DLEN 16 bits (DS 3.2) | VC IRQ 53, "OR of all I2C", record line 149; the OR takes I2C0 to I2C7, the HDMI masters BSC2 and BSC7 included (DS 6.2.4, Figure 6) | BSC2 and BSC7 "are dedicated for use by the HDMI interfaces and should not be accessed" (DS 3.2); SCL = core clock / CDIV, CDIV rounded down to even (DS 3.2, Table 30) |
| SPI | SPI0 `0x7e204000`, SPI3 `0x7e204600`, SPI4 `0x7e204800`, SPI5 `0x7e204a00`, SPI6 `0x7e204c00`; CS, FIFO, CLK, DLEN, LTOH, DC (DS 9.5, Table 159) | VC IRQ 54, "OR of all SPI", record line 150 (DS 6.2.4) | SCLK = core clock / CDIV, CDIV even (DS 9.5); the polled procedure is DS 9.6.1; the FIFO takes 64 bytes (DS 9.6.2). PACTL_CS, which says which I2C or SPI master raised its line, lies in this page at `0x7e204e00` (DS 6.2.4) |
| PWM | PWM0 `0x7e20c000`, PWM1 `0x7e20c800`, one page; two channels each; in M/S mode a channel is high for DAT of every RNG cycles of `clk_pwm` (DS 8.1, 8.4, 8.6) | none (DS Table 102) | `clk_pwm` is "nominally 100MHz, but can be varied by the clock manager" (DS 8.1) |
| Clock manager (CPRMAN) | `0x7e101000`; the datasheet documents only the general-purpose clocks, with the password `0x5a` in bits 31:24, BUSY bit 7, ENAB bit 4, MASH bits 10:9, SRC bits 3:0 (`1` the oscillator) and DIVI bits 23:12 of the divisor (DS 5.4, Tables 99 and 100) | | the PWM clock's control and divisor are at offsets `0xa0` and `0xa4`, in the same format (FreeBSD `bcm2835_clkman.h:36`, `bcm2835_clkman.c:70-72`) |

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

* **The GPIO page reads every pin, whatever its function.** "The pin
  level registers return the actual value of the pin" (DS 5.2, Table
  74), and the block diagram (DS 5.1, Figure 4) wires the pad's input
  buffer straight to the level, edge-detect and pin-level registers; the
  function select steers only the alternate function's input and the
  output and direction multiplexers. So GPLEV0 bit 15 follows the
  console's receive line while GPIO 15 is in ALT5, and its edge
  detectors see that line too. The board probe below records whether the
  silicon agrees. Independently of that, writing `000` to a pin's
  function field makes it an input whose level GPLEV returns by
  definition (DS Tables 64 and 65).
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
  `gpio=5=a4,pu`, line 79); and, on a development card only,
  `enable_jtag_gpio=1` (lines 129-134). So on a development card GPIO 22
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
* **The controllers wait for their FIFOs.** The BSC sends nothing more
  while its FIFO is empty ("No further data will be transmitted until
  more data is written", TXE) and stalls every operation while it is
  full (RXF) (DS 3.2, S register). SPI generates no clocks while its
  receive FIFO is full (RXF, DS 9.5, CS register). A late driver
  therefore costs time, never data.
* **The I2C master can repeat a start only from a write to a read of the
  same device**, by changing direction and length while the write is
  still running (DS 3.3.2, steps 4 to 7). The datasheet's steps put the
  write's byte in the FIFO before the start, so the write can finish,
  and end with a stop, before the read is set up. FreeBSD starts the
  write with an empty FIFO, which the controller cannot finish, sets up
  the read, and only then supplies the write's bytes
  (`bcm2835_bsc.c:34-80`, `599-640`).

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
real-time clock driver reads the status register and refuses a time
while its oscillator-stopped flag is set, reads seven BCD registers
from 0, follows the century bit's toggles, and after a set writes the
status back with that flag clear
(`sys/dev/iicbus/rtc/ds3231.c:125-140`, `479-596`, registers in
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
I2C and the SPI controllers outside the mini UART's unit in the devices
domain, a TPM module with the SPI controller it sits on in the vault's
domain, and the GPIO controller in no domain. `config.txt` sets the
console's, the host link's and JTAG's pins as above.

## The construction: one map of the header

The design rests on one table. The platform record gains `header`: the
path of its **pin controller**, the device whose registers set the pins'
functions (on the Pi 4 the GPIO controller), and one row for each of
GPIO 0 to 27, each with a **use** and, for a pin a block other than GPIO
drives, a **function** and a **pull**:

| Use | Meaning | Function and pull |
| --- | --- | --- |
| `gpio` | a pin for plain GPIO, served by the pin controller's driver where a manifest gives that controller a holder | none |
| a device path of the record | the pin is that device's, set by the firmware | the function's Table 94 name, such as `SDA1`; the pull, `none`, `up` or `down` |
| `jtag` | the ARM's JTAG, on development cards | the function's name, such as `ARM_TMS` |
| `reserved` | nothing touches the pin | none |

A checked-in table of the SoC's bank-0 pins, `hw/pins/bcm2711.txt`, is
written from DS 5.3, Table 94, as the CMSIS-SVD files are written from
the register chapters. It has one row per pin, with its power-on pull
and its six alternate functions, and one row per controller that owns
any of those functions, with its base address, the signals that are its
own (`SDA1` and `SCL1` for BSC1 at `0x7e804000`) and which of them it
cannot work without (SDA and SCL; SCLK, MOSI and MISO; TXD and RXD). The
Raspberry Pi 4's map is:

| GPIO | Header pin | Use | Function, pull |
| --- | --- | --- | --- |
| 0, 1 | 27, 28 | `reserved` (the HAT EEPROM) | |
| 2, 3 | 3, 5 | BSC1 | `SDA1`, `SCL1`; `none` (the board's pull-ups) |
| 4, 5 | 7, 29 | the host link, UART3 | `TXD3` `none`, `RXD3` `up` |
| 6 | 31 | `gpio` | |
| 7 to 11 | 26, 24, 21, 19, 23 | SPI0 | `SPI0_CE1_N`, `SPI0_CE0_N`, `SPI0_MISO`, `SPI0_MOSI`, `SPI0_SCLK`; `none` |
| 12, 13 | 32, 33 | `gpio` | |
| 14, 15 | 8, 10 | the console, the mini UART | `TXD1`, `RXD1`; `none` |
| 16 to 21 | 36, 11, 12, 35, 38, 40 | `gpio` | |
| 22 to 27 | 15, 16, 18, 22, 37, 13 | `jtag` | `ARM_TRST` to `ARM_TMS` |

The header pins are the schematics' J8. The GPIO pins are 6, 12, 13 and
16 to 21; GPIO 18 and 19, PWM0's pins, are plain GPIO while PWM is not
driven ([PWM](#pwm)). A `gpio` row gives no `config.txt` line, so a pin
that no domain drives keeps its power-on state, an input with Table 94's
pull.

**What is generated from it.** The record reader checks the map and the
build derives from it, so nothing else states a pin:

1. **`config.txt`.** Each row with a device use gives one `gpio=N=aK,pX`
   line, K the function's alternate number from the SoC table, X the
   pull; the `jtag` rows give `enable_jtag_gpio=1` on a development card
   and nothing on a release card. The host link's lines come from its
   rows, so `OVERLAY_PINS` is deleted; the console's rows give lines too,
   which agree with what `enable_uart=1` forces.
2. **The pin controller's record carries `PINS`**, a 28-bit mask of the
   `gpio` rows, through the manifest's device row and its holder's
   record, as the network record carries `MAC`
   ([design-device-tree.md](design-device-tree.md#facts-into-records)),
   on a manifest that gives the controller a holder.
3. **Which bus devices are driven.** A bus device that a map row names
   has its class's role (below) and a record; a device of the same
   controller that no row names is a row of no kind, held with its unit
   and driven by nobody
   ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
   An SPI tree has a directory for each chip select the map names.
4. **Who may hold the pin controller.** The rows the map gives the
   `console` and `hostlink` paths make the pin controller's unit one
   whose registers set those paths' pin functions, which property 8
   restricts ([The pin controller and the
   console](#the-pin-controller-and-the-console)).

**What the reader refuses**, each with a diagnostic naming the row: a
map without exactly one row for each of GPIO 0 to 27; a pin controller
that is not a device path of the record; a function that is not one of
the pin's six in the SoC table; a function that is a signal of another
controller than the one at the row's device's base; a device use that
is not a path of the record, or names a device of no kind; a driven
device, the console's and the host link's UARTs among them, that is
missing a signal its controller cannot work without or names one signal
on two rows; a driven bus device that no row names; a `gpio` or
`reserved` row with a function. A pull on a `gpio` row is refused too: a
GPIO pin's pull is its holder's to set.

Every rule about pins follows from the map instead of from a list:

* **Only the pin controller's driver writes pin functions and pulls at
  run time.** The firmware writes every bus pin before the kernel runs;
  the GPIO driver writes only pins in `PINS`, and only `000` or `001`
  into their function fields: its register core takes a pin only from
  the set its record gave it and has no way to write an alternate
  function. That limits what the driver's clients can ask; it does not
  limit the domain that holds the page, which the next section places.
* **The console's, the host link's, the HAT EEPROM's and JTAG's pins are
  never served**, since none of them is a `gpio` row. On a development
  card GPIO 27 is JTAG's TMS, so a GPIO driver serving "pins 2 to 27"
  would break the probe the card exists to offer; the map makes that
  impossible to write.
* **Only header pins are served, but the registers are shared with bank
  1.** The map has rows for bank 0 only, so the firmware's pins in banks
  1 and 2 cannot be named. Their fields are not all in other registers,
  though: GPFSEL2 holds GPIO 20 to 29 (DS Table 66), PUP_PDN_CNTRL_REG1
  GPIO 16 to 31 (DS Table 91), and the edge enables GPREN0 and GPFEN0
  GPIO 0 to 31 (DS Tables 78 and 80), so the GPIO driver's
  read-modify-writes of those registers carry bank 1's GPIO 28 to 31
  through unchanged. That is sound only while nothing else writes those
  registers after boot. The design requires it of the firmware: the
  VideoCore writes the GPIO page at boot from `config.txt` and not
  afterwards. Raspberry Pi's documentation does not promise it; the
  board probe's two readings a minute apart are evidence, not proof, and
  a firmware that broke the rule would race the driver.
* **No driver claims another block's pins.** A bus driver finds its
  pins already set when it starts, so the vault's SPI driver depends on
  no other domain, and there is no claim protocol between drivers.
* **A pin is never both a bus pin and a GPIO pin.** It has one row.

## Placement: units and domains

The unit rule makes the units; the manifest places them.

| Unit | Devices | Line | Holder |
| --- | --- | --- | --- |
| `gpio` | the GPIO controller, the pin controller | 145 (bank 0); 146 to 148 go to no unit, as GENET's second line does | no domain on the Pi 4's manifests; its home once run-time GPIO is built is Open decision 1 |
| `i2c` | BSC1, driven; BSC0 and BSC3 to BSC6, which share BSC1's line and BSC0's page, and BSC2 and BSC7 where the board's tree lists them, of no kind | 149, shared | the devices domain |
| `spi` | SPI0, driven; SPI3 to SPI6 of no kind, which share its page and line | 150, shared | the devices domain; the vault's domain on a manifest with a TPM |
| `pwm` | PWM0 and PWM1, on one page | none | no domain until PWM is built; then the devices domain, with PWM0 driven |
| `clocks` | the clock manager | none | no domain; if PWM needs its clock written, the pin controller's home ([PWM](#pwm)) |

The device-kind table (`include/erx/device_kinds.h`) gains a row per
driven class, each a new value of `mf_device_role` with its peripheral's
CMSIS-SVD source written from the datasheet: `i2c` (`hw/svd/bsc`) and
`spi` (`hw/svd/bcm2711_spi`); `gpio` (`hw/svd/bcm2711_gpio`) with the
GPIO package; `pwm` (`hw/svd/pwm`) and, if its clock needs a write,
`clock` (`hw/svd/cprman`, naming only the PWM clock's two registers)
with PWM. The compatible strings are the board's tree's, which the board
probe lists; FreeBSD matches `brcm,bcm2711-gpio`, `brcm,bcm2835-i2c`,
`brcm,bcm2835-spi`, `brcm,bcm2835-pwm` and `brcm,bcm2711-cprman`, which
is what the rows expect until the probe says otherwise.

### The pin controller and the console

The GPIO page holds the function and the pull of every pin, the
console's GPIO 14 and 15 and the host link's GPIO 4 and 5 among them,
and has no lock (DS 5.2, Table 63). The kernel gives memory-mapped
registers only as whole pages
([design-system.md](design-system.md#devices)), so whoever holds the
page holds all of it, and any code in the holding domain can write any
field whatever the GPIO driver's own `PINS` check says. A holder can:

* **take the console's line**, by rewriting GPIO 14's or 15's function
  or pull; the console, and with it the kernel's panic report, leaves
  the header;
* **read the console's input for certain**, by switching GPIO 15 to an
  input, sampling it and switching it back, at the cost of the bytes the
  mini UART misses while it is away; at a passphrase prompt, which does
  not echo, that looks like a mistyped passphrase;
* **read it silently**, if the silicon matches DS Figure 4, by sampling
  GPLEV0 bit 15 while the pin stays in ALT5;
* **do the same to the host link**, whose transport trusts physical
  access to its wires ([design-live.md](design-live.md#the-host-link)).

Writing to the operator by toggling GPIO 14 as an output, or injecting
input through a pull, depends on timing and electrical facts no source
read for this design settles; the design does not rest on them either
way.

The rule "no domain can read a passphrase typed at the login prompt"
([design-system.md](design-system.md#devices)) therefore needs the pin
controller's holder in the console's trusted base. The board probe's
GPLEV step decides only whether the read can be silent; no result of it
makes an untrusted holder safe.

**The property.** Property 8 of the manifest check
([design-system.md](design-system.md#the-manifest)) gains a clause
derived from the header map: a unit whose registers set the function of
a pin that the map gives to `console` or `hostlink` is held by no domain,
by the system domain, or by a domain that holds only such units. On the
Pi 4 that unit is `gpio`, the unit of the map's pin controller. The unit
rule groups devices that share a page or a line, and so cannot see a
control path that crosses pages; the map is where the board states that
path, and the clause turns it into a check, so the next board's pin
controller is covered by its own map rather than by a list of device
classes. The check fails the build naming property 8, the unit and the
holder.

The Pi 4's manifests give `gpio` to no domain. I2C, SPI and the TPM need
no run-time pin holder, so nothing but run-time GPIO waits on where the
pin controller lives (Open decision 1).

### The buses

**The TPM takes the whole SPI unit.** SPI0 and SPI3 to SPI6 share one
page and one line, so a manifest that gives the TPM module's controller
to the vault's domain gives it all five, and the devices domain then
serves no SPI tree. That is the placement
[design-platforms.md](design-platforms.md#device-secrets) already
states; the unit rule only makes explicit that it takes all of SPI. A
TPM on I2C would instead give the vault the whole I2C unit, and with it
the RTC's bus, and QEMU's TPM on I2C is no reason to change the board's
choice; the TPM on SPI is tested on the board.

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

**The PWM clock** is described with PWM below, which is built only when
a consumer needs it.

## The trees

Each block's driver serves its tree through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)). A
`ctl` file takes one line of at most 32 bytes, with or without its
newline, and any other write fails with `einval`, as the device
service's `ctl` does ([design-system.md](design-system.md#devices)).
Reads of `ctl` fail with `eacces`. Names are plain decimal or hexadecimal
digits, so no name needs escaping.

Settings belong to the hold, and a hold lasts while its holder keeps a
file of the resource open ([Holding and granting](#holding-and-granting)).
A client that configures a pin, a chip select or a channel and then
uses it keeps one of its files open across both, as the examples under
[The first consumers](#the-first-consumers) do; a `ctl` written by a
lone `echo` is undone when `echo` exits.

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
timeout (CLKT) or a stalled transfer answers `etimedout`.
`cat /dev/i2c1/68/reg8 | od -x` dumps a device's registers. A register
read writes its register address to the device first, so no read of a
`reg8` or `reg16` file is free of writes to the device that answers.

### `/dev/spi0`

One directory per chip select the map names, `0` (CE0, GPIO 8) and `1`
(CE1, GPIO 7), each holding:

* `ctl`: `mode 0` to `mode 3` (CPOL and CPHA); `speed HZ`, from 7,630 Hz
  (CDIV 65534) up to the rate CDIV 2 gives, met with the smallest even
  divisor that does not run the bus faster than asked. The settings
  belong to the hold and return to `mode 0` and 1 MHz when it ends.
* `data`: a write of at most `spi_transfer_max` bytes, 4096, is one
  transfer with the chip select held for all of it; a longer write fails
  with `einval`. The bytes clocked in during the transfer are the
  handle's **response**. A read returns the response's first bytes, as
  many as asked, and keeps the rest for the next read; a read with no
  response returns nothing. A write while the handle still holds
  response bytes fails with `ebusy`, so no response is lost unread. A
  flushed write's transfer still runs to its end, and its response is
  dropped; closing the handle drops it too.

### `/dev/pwm0`

One directory per channel, `0` (GPIO 18) and `1` (GPIO 19), each holding
`ctl`: `period NS`, `duty NS`, `enable`, `disable`. The channel runs in
M/S mode: RNG is the period and DAT the high time, each in ticks of the
PWM clock, rounded to the nearest tick (DS 8.4). `enable` fails with
`einval` while the period is under one tick or more than 2^32 - 1 ticks,
or the duty is longer than the period; a `period` or `duty` that would
break that rule on an enabled channel fails the same way and changes
nothing. A channel is disabled with period 0 when its hold ends. The
tree exists once PWM is built ([PWM](#pwm)).

### `/dev/rtc`

One file, `time`. A read answers the UTC time as decimal seconds since
1970 and a newline. A write of such a line sets the clock. The years
are 2000 to 2099; a write outside them fails with `einval`. A read
fails with `einval` while the chip's oscillator-stopped flag is set, as
FreeBSD's refuses (`ds3231.c:493-494`), with `eio` when the chip does
not answer, and with `eio` when the registers do not decode (below). The
driver writes the chip's time only when `time` is written, never at its
start. Which chip answers at the configured address is the manifest's
statement: a reply that decodes does not prove the device is a DS3231,
and each read writes the register pointer to whatever answers.

## Holding and granting

**The hold.** One pure core, `erx_hold`, shared by the GPIO, SPI and PWM
trees, decides who holds a pin, a chip select or a channel. Its state is
a map from resource to holder, a grant, and the holder's open handles on
it. Its events are an open by a grant, the close of a handle, a grant's
end, and an operation by a handle:

* an open of any file of a resource by a grant that does not hold it,
  while another grant does, answers `ebusy`; an open by the holder, or
  of a free resource, succeeds and adds the handle;
* when the holder's last handle on the resource closes, or the holder
  ends, the core answers the resource's release, and the driver puts it
  in its idle state;
* an operation (a `ctl` line, a `value` write, an `event` wait, a
  transfer) is applied only if its handle is still an open handle of
  the resource's current holder; otherwise it answers `eio` and changes
  nothing.

The core's state lives in the driver process, which also applies every
effect, so the check and the effect are one step of one process: a
request that a grant's helper sent before the grant's end, and that
reaches the driver after the release and after another grant's open,
finds its handle gone. The tree's `open/3` runs in the grant's own
process (`erx_fs_grant.erl:685`), so it names the grant by `self()`; the
driver monitors each holder, so a grant that ends without closing its
handles still releases. I2C needs no hold: every transfer is whole, the
driver serializes them, and holding the bus is holding every device on
it.

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
| `rtc` | `rtc` | `bus`, a device; `chip`, an identifier of a closed set (`ds3231`); `address`, 8 to 119 | `/dev/rtc` |

`pins` is a grant's **scope**: rows of one service may differ in it, and
it is how an app gets its LED's pin and no other, with the existing
typed scope parameters of a facet row; its grant's tree has directories
for those pins alone. `bus`, `chip` and `address` are the `rtc`
service's **configuration**: they say which chip answers the clock, so
every row of one server must state the same three. `rtc_grant` checks
that they agree, that `bus` names a device of kind `i2c` that a map row
names (so it is driven), and that the `rtc` server holds that device's
unit; a row that fails any of these fails the build with the row and the
field.

A domain mounts each granted facet at its point, from `erx_ns`'s table
of facet mounts
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
Nothing starts because the module might exist. If a second chip's
service comes to repeat the same hardware facts on many rows, those
facts move to the service's declaration rather than growing the
agreement check.

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
| `erx_hold` | the holder of each pin, chip select and channel, and whether an operation's handle is live, as above |
| `erx_gpio_core` | the `ctl` grammar; from a pin in `PINS` and a request, the register writes: the GPFSEL field (register `pin div 10`, shift `3 * (pin rem 10)`), the pull field (register `pin div 16`, shift `2 * (pin rem 16)`), GPSET or GPCLR, the edge enables, each a read-modify-write that changes only the pin's field; from a GPEDS0 value, the served pins that fired and the bits to clear |
| `erx_bsc_core` | a transfer as a state machine: from the request and each status read, the next action (fill or drain the FIFO, start, set up the repeated start, finish) and its result; the service interval and the stall limit |
| `erx_spi_core` | the `ctl` grammar, the divisor, and the held transfer: from the CS flags, what to write to and read from the FIFO next, chunk by chunk; the service interval and the stall limit |
| `erx_pwm_core` | the `ctl` grammar and RNG and DAT from period, duty and clock |
| `erx_rtc_ds3231` | the status and the seven time registers to seconds, and seconds to the registers |

**The repeated start.** A `reg8` or `reg16` read is one state machine
in `erx_bsc_core`, ordered so that the write cannot end before the read
is set up:

1. clear the FIFO and the status bits; write A, the device's address,
   and DLEN, the register address's length (1 or 2);
2. write C with I2CEN and ST, the FIFO still empty, which starts the
   write; the controller sends the address and then waits for data
   (TXE);
3. poll S until TA is set; ERR answers `eio`;
4. write DLEN, the read's length, and C with I2CEN, ST and READ, which
   the controller takes as the next transfer;
5. write the register address's bytes to the FIFO; the controller sends
   them, then a repeated start and the read;
6. drain the FIFO until DONE.

A delay between any two steps leaves the write waiting on its empty
FIFO, so no scheduling delay turns the repeated start into a stop. This
is FreeBSD's order (`bcm2835_bsc.c:599-640`), not the datasheet's
(DS 3.3.2), whose step 2 fills the FIFO first. A plain `data` write is
steps 1 and 2 with DLEN its length, then filling the FIFO until DONE; a
plain read is the same with READ in step 2, then draining the FIFO until
DONE. FreeBSD's wait for
TA has no bound; here it is a poll under the stall limit.

**Polling.** A transfer is a loop of status reads. A read that finds
work (bytes to move, a phase to start, DONE, ERR or CLKT) acts on it and
polls again at once. A read that finds none waits the **service
interval** before the next: half the time one full FIFO takes on the
wire at the bus speed (16 bytes of 9 bits for I2C, 64 bytes of 8 bits
for SPI), rounded down to whole milliseconds; when that is zero, the
driver polls again at once, yielding between polls as any Erlang
process does. At 100 kHz I2C waits 0 ms (a full FIFO takes 1.44 ms); SPI
waits 2 ms at 100 kHz and 0 ms above 256 kHz.

A transfer answers `etimedout` when its polls have found no work for its
**stall limit**: 10 ms plus four FIFO times at the bus speed, counted
from the last poll that found work. Because the controllers wait for
their FIFOs, a driver that the scheduler delays finds work when it runs
again; the stall limit is crossed only by a controller or a device that
has stopped. A transfer of n bytes therefore never fails for the
driver's lateness, and takes at most n times the stall limit even
against a device that stretches every byte. At 10 MHz a 4096-byte SPI
transfer is 3.3 ms of wire time and its stall limit is 10.2 ms; a
driver descheduled for 20 ms in its middle finishes it.

After `etimedout` the driver clears the FIFO and the status bits, and
disables and enables the controller before the next transfer. That
bounds the request; it does not make a device release the bus. A device
that holds SDA or SCL low makes every transfer on the bus fail until it
lets go or loses power. Clocking the bus free needs its pins as GPIO,
which no bus driver holds, so that recovery is not offered.

**The held transfer.** `erx_spi_core`'s transfer is a sequence of
**chunks** under one chip select: the caller's pure step takes the
bytes the previous chunk clocked in and answers the next chunk, at most
4096 bytes, or `done`. The chip select is asserted (TA set) from the
first chunk until `done`, and between chunks the controller waits on an
empty FIFO. A `data` write is the one-chunk case. The held transfer ends
with `done`; at the caller's deadline, if it gives one, or at a stall,
it clears TA, which releases the chip select, clears the FIFOs and
answers `etimedout`. Whether SPI0 holds its clock while its transmit
FIFO is empty in mid-transfer is implied by DS 9.6.1's polled procedure
but not stated; the board's loopback with a pause between chunks
checks it.

**GPIO events.** The GPIO driver binds line 145, a direct line, with
`erx_irq_line:attach/2`. A delivery reads GPEDS0, clears the bits of
`PINS` that are set, counts an edge for each, answers the `event` reads
waiting on those pins, and acknowledges. It enables edge detection only
on pins of `PINS`; the board probe checks that nothing else enables
detection on bank 0 at boot, since a bit outside `PINS` is never cleared
and a level held on it would raise the line again.

**What a device returns is untrusted.** Bytes read from an I2C or SPI
device go to the client unchanged and unparsed. The RTC driver is the
one parser of device output here: `erx_rtc_ds3231` takes the status
register, `0x0f`, and the seven time registers from 0, with the masks
of FreeBSD's `ds3231reg.h`:

* seconds and minutes, mask `0x7f`, below 60;
* hours: with bit 6 clear, 24-hour, mask `0x3f`, below 24; with bit 6
  set, 12-hour, mask `0x1f`, 1 to 12 with the PM bit `0x20`, taken as
  12 AM = 0, 1 to 11 AM as they are, 12 PM = 12, 1 to 11 PM plus 12;
* weekday, mask `0x07`, read and not used;
* date, mask `0x3f`, a day the month has; month, mask `0x1f`, 1 to 12;
* the century bit, `0x80` of the month register, must be clear;
* year, mask `0xff`, 2000 plus its two digits.

Every nibble must be a decimal digit. Anything else is `eio`, never a
time: a set century bit is an encoding this driver does not write, so a
year past 2099 is never folded back into the range. A read whose status
has OSF (bit 7) set is `einval`. A write sets the seven registers from 0
in one transfer, in 24-hour mode with the century bit clear and the
weekday as FreeBSD writes it, its day of the week plus one
(`ds3231.c:568`); if the status read before it
had OSF set, the driver then writes the status back with OSF clear and
the alarm flags A1F and A2F written as 1, which leaves them as they were
(`ds3231.c:125-140`, `583-597`). The parser has a fuzz target. The `ctl`
grammars parse another domain's input and share one fuzz target over
the trees' `ctl` lines and walk names.

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

## PWM

PWM has no consumer in the first set (a fan, LED dimming and servos are
the likely ones), and QEMU does not model it, so it is built when a
consumer needs it. Until then the map's GPIO 18 and 19 are `gpio` rows
and no domain holds the `pwm` or `clocks` units. Building it means:

1. **Read the clock first.** The board probe already logs the PWM
   clock's control and divisor registers. If the firmware leaves
   `clk_pwm` running from a known source at a known rate, the record's
   PWM row carries that rate as its `clock` and nothing writes the clock
   manager. The firmware drives PWM itself for analogue audio
   (`config_txt-audio.adoc`, `audio_pwm_mode`), so whether it leaves
   the clock alone when erXos plays no audio is part of what the probe
   reads.
2. **Otherwise, write it once, in the pin controller's home.** The clock
   manager is the same kind of authority as the pin controller: the
   design takes it to clock the UARTs and the SD controller as well
   (likely, unverified: the firmware lists UART, CORE and EMMC2 clocks,
   but no source read here places their registers in this page). Its
   unit goes where Open decision 1 puts the pin controller, never to the
   PWM's holder, and when the record states that the console's clock
   comes from it, property 8's clause covers it as it covers the pin
   controller. The write obeys DS 5.4, Table 99, which forbids changing
   SRC or MASH while BUSY is set or in the same write that asserts ENAB:
   1. read CTL; if BUSY is set, write CTL with the password, its own SRC
      and MASH unchanged and ENAB clear, and poll until BUSY clears, at
      most 10 polls 1 ms apart;
   2. write CTL with the password, SRC 1 (the oscillator), MASH 0
      (integer division) and ENAB clear;
   3. write DIV with the password, DIVI the record's divisor and DIVF 0;
   4. write CTL with the password, SRC 1, MASH 0 and ENAB set, which
      changes only ENAB;
   5. poll until BUSY sets, at most 10 polls 1 ms apart.

   A BUSY that does not clear in step 1 or set in step 5 is a failure:
   the writer stops there and never uses KILL, which DS Table 99 says
   may glitch. FreeBSD's `bcm2835_clkman_set_frequency` writes source 6
   and ENAB clear in one write while the clock may be busy
   (`bcm2835_clkman.c:134`); this sequence does not. The record reader
   refuses a target that does not divide the oscillator's rate by an
   integer from 2 to 4095 (MASH 0 allows 1, DS Table 96). With a 54 MHz
   oscillator (to be confirmed from the board's tree) the target is
   27 MHz, DIVI 2, a resolution of 37 ns.
3. **Carry the result to the PWM driver.** `enable` answers `eio` when
   the clock is not running, so the PWM driver must know. With the
   system domain as the clock's home, the write runs before the
   configured domains are created and its result is a fact of PWM0's
   record (its `clock`, 0 when the clock did not start), which the
   devices domain receives at each creation and so keeps across its
   restarts. With a domain of its own as the home, that domain starts
   before the PWM's holder and the fact needs a route this design does
   not yet name; it is settled with PWM's build, under the design rule
   that a new route is designed before it is built.

The PWM driver, `erx_pwm_core` and `/dev/pwm0` are as described above.

## The first consumers

**A TPM module on SPI, for the vault.** A manifest with a TPM places the
`spi` unit in the vault's domain. There the TPM driver is the unit's one
driver process; it uses `erx_spi_core` and the SPI register module as a
library, serves no tree, and finds SPI0's pins set by the firmware, so
the TPM's bytes cross no other domain and the vault depends on no other
domain for them. The chip select is the module's, CE0 or CE1.

A TPM on SPI paces its transactions itself (TCG PC Client Platform TPM
Profile 1.03 v22, section 6.4.5): a transaction is a command byte that
gives the direction and a size of 1 to 64 bytes, three address bytes,
and the data. The TPM may insert wait states after the address: while
the last bit the master clocks in during a byte is 0, the TPM is not
ready, and the master clocks another byte and looks again; once it is
1, the whole transaction's data follows with no further flow control.
On a write the master drives the first data byte during the wait
states, and the byte that ends with a 1 counts as sent. The TPM "may
insert any number of wait states", up to the timeout of the register
accessed.

The vault's TPM framing is therefore a step function of the held
transfer ([Drivers](#drivers)): the header as the first chunk; while the
last bit clocked in is 0, one wait byte (the first data byte on a
write, a filler on a read); then the data, at most 64 bytes, as one
chunk. Its deadline is the timeout the vault's TPM design gives for the
register accessed; at that deadline the held transfer releases the chip
select, clears the FIFOs and answers `etimedout`, and the vault's design
says what follows. Every transaction is at most 68 bytes plus its wait
bytes, so the 4096-byte chunk bound never binds it. The vault's
response decoder stays the bounded, fuzzed parser of what the TPM
returns. QEMU's model has no TPM on SPI, so this consumer is tested on
the board alone.

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

**An LED and a button on GPIO**, on a manifest that gives the pin
controller a holder. An LED with its resistor from GPIO 13 (header pin
33) to a ground pin, lit for a minute from `rc`:

```
{echo out 1; sleep 60} > /dev/gpio/13/ctl
```

The block's output holds `ctl` open, so the hold, and the LED, last
until `sleep` ends; then the pin returns to its idle state. A button
from GPIO 16 (header pin 36) to a ground pin, printing a line at each
press until interrupted:

```
{echo pull up; echo edge falling; cat /dev/gpio/16/event} > /dev/gpio/16/ctl
```

An app granted `pins [13, 16]` sees those two directories and nothing
else, and holds each pin while it keeps a file of it open.

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
* The hold's check and an operation's effect are one step of the driver
  process, so an operation sent before its grant ended cannot act after
  another grant took the resource.
* The tree's callbacks run in the grant's processes and call the driver;
  a read that waits, an `event` or a transfer, runs in the file's helper,
  so it holds up no other file of the grant
  ([design-files.md](design-files.md#serving-the-erx_fs-behaviour)).
* A client that goes away during a transfer does not stop it; the
  driver finishes and drops the answer.
* A stalled transfer costs at most its stall limit and a controller
  reset. A device that holds the bus low keeps failing transfers until
  it lets go; the stall limit bounds each request, not the device.
* The GPIO driver's read-modify-writes of GPFSEL2, PUP_PDN_CNTRL_REG1,
  GPREN0 and GPFEN0 carry bank 1's fields through, which is sound only
  while the firmware does not write those registers after boot
  ([the map](#the-construction-one-map-of-the-header)).

## Refusals and error results

| Request | Answer |
| --- | --- |
| an open of a pin's, chip select's or channel's file held by another grant | `ebusy` |
| an operation by a handle that is no longer an open handle of the current holder | `eio` |
| a `ctl` line not in its grammar, longer than 32 bytes, or with bytes after its newline | `einval` |
| a read of a `ctl` | `eacces` |
| a `value` write on an input pin, or of anything but `0` or `1` | `einval` |
| an `event` read with `edge none` | `einval` |
| a walk to a pin outside the grant's `pins`, an address outside `08` to `77`, a chip select or channel the tree does not have | `enoent` |
| an I2C write longer than 4096 bytes, or past the end of `reg8` or `reg16` | `einval` |
| an I2C device that does not acknowledge | `eio` |
| a clock stretched past CLKT, or a transfer stalled past its stall limit | `etimedout` |
| an SPI write longer than 4096 bytes | `einval` |
| an SPI write while the handle holds unread response bytes | `ebusy` |
| a PWM `enable` with a period of no ticks or past 32 bits, or a duty longer than the period | `einval` |
| a PWM `enable` whose clock is not running | `eio` |
| an RTC read while the oscillator stopped | `einval` |
| an RTC read with no answer, or registers that do not decode, a set century bit among them | `eio` |
| an RTC write outside 2000 to 2099, or not a decimal line | `einval` |
| a handle of a driver incarnation that has ended | `eio` |

At build time the record reader refuses a header map as listed above,
and the manifest check refuses: a holder of the pin controller's unit
other than no domain, the system domain or a domain holding only such
units (property 8); a `gpio` row's `pins` outside the map's `gpio` rows;
`rtc` rows of one server that disagree, or whose `bus` is not a driven
`i2c` device of a unit the server holds.

## Security

* The console's and the host link's pins are reachable only from the
  trusted base: the pin controller's unit is held by no domain, the
  system domain or a domain holding only such units, which property 8
  proves from the header map. Its holder, whichever domain that is,
  joins the console's trusted base: no placement keeps a compromised
  holder from reading or taking the console's line, and `PINS` and a
  restricted SVD discipline correct driver code without limiting the
  domain that holds the page.
* The clock manager goes to no domain, and if PWM needs it written,
  only to the pin controller's home ([PWM](#pwm)).
* A grant reaches only what its tree shows: a GPIO grant its `pins`; an
  I2C grant every device on the bus, the RTC included, since
  serializing transfers keeps them whole but does not separate devices;
  an SPI or PWM grant the whole controller's chip selects or channels,
  one holder each.
* Driving a pin is driving a wire. A holder that sets an output against
  something else that drives the same wire can damage the board; that
  is the wiring's, and the operator's, as on any UNIX system that offers
  GPIO.
* The trees show no text a device wrote: I2C and SPI bytes are data to
  the reader, and the RTC answers a number the system domain parses
  with a bound. Inspection values go through the inspector's escaping.
  The RTC decoder and the vault's TPM response decoder are the two
  parsers of what a header device returns, each with its fuzz target.
* The RTC's time comes from a device on a bus in the devices domain, so
  the wall-clock keeper treats it as a hint, not as truth; how much it
  trusts it is the time design's.
* JTAG's pins are never served, on either kind of card, and a release
  card's `config.txt` has no `enable_jtag_gpio`, which the `config.txt`
  writer's test checks. That is not proof that hardware debugging is
  off on a release boot; the release's debug state is verified on its
  own, outside this design.

## Verification

**Host tests of the pure cores.** Every core builds and runs on the
host. Each case is paired with a seeded fault that must make it fail,
so the case is known to reach the code it tests.

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_hold`, exhaustive over two grants, two resources and every order of open, close, end and operation up to depth 6 | at most one holder per resource; `ebusy` exactly when another grant holds it; a resource with no handle of its holder is released exactly once; an operation is applied exactly when its handle is an open handle of the current holder, so the order end(A), open(B), operation(A) refuses the last | releasing at the first close instead of the last, which a grant with two handles exposes; the operation check removed, which that order exposes |
| `erx_gpio_core` register writes | `out 1` on GPIO 17 changes only bits 21 to 23 of GPFSEL1 and sets bit 17 of GPSET0; `pull up` on GPIO 21 changes only bits 10 and 11 of PUP_PDN_CNTRL_REG1; `out 1` on GPIO 21 leaves GPFSEL2's bits for GPIO 28 and 29 as read | a function shift of `3 * (pin rem 10) + 1`; a GPFSEL write that is not a read-modify-write, which zeroes GPIO 28 and 29 |
| `erx_gpio_core` served set | every request for a pin outside `PINS` is refused, for every pin 0 to 27 and each of the map's rows | the `PINS` check removed |
| `erx_gpio_core` events | a GPEDS0 value with bits inside and outside `PINS` clears and counts only those inside | clearing the whole register |
| `erx_bsc_core` repeated start, against a BSC model that ends a write with a stop as soon as DLEN bytes have left an empty FIFO and READ and ST are not pending, with any number of idle polls inserted between any two steps | a `reg8` read gives a repeated start and the read's bytes, for every insertion | the register address written to the FIFO before the first ST, as in DS 3.3.2, which the model ends with a stop when polls are inserted before READ and ST |
| `erx_bsc_core` errors | a status with ERR answers `eio`, CLKT `etimedout`, and a status that never shows work `etimedout` at the stall limit | ERR ignored; the stall limit removed, which the test's own timeout catches |
| the stall limit, `erx_spi_core` against a model controller with a clock | a 4096-byte transfer at 10 MHz with a 20 ms pause of the driver in its middle completes; a controller that stops moving bytes fails at 10 ms plus four FIFO times | the stall clock counted from the transfer's start instead of the last poll that found work, which fails the paused healthy transfer |
| `erx_spi_core` transfer | against a register model that loops MOSI to MISO, every length from 1 to 200 returns what was sent | one byte dropped when the FIFO refills |
| `erx_spi_core` held transfer | three chunks keep TA set from the first to `done`; a deadline clears TA and both FIFOs and answers `etimedout` | TA cleared between chunks |
| the `data` response | a 4-byte response read as 1 byte and then 3 returns all four in order; a write with bytes unread answers `ebusy` | the rest dropped after a short read |
| the vault's TPM framing step, with the vault's TPM design, against a model TPM that inserts 0 to 3 wait states on reads and writes | each transaction carries its data once, after the last wait state | the data sent right after the header without looking at the last bit |
| `erx_pwm_core` | 27 MHz, 20 ms period, 1.5 ms duty gives RNG 540000 and DAT 40500; 100 ns gives 3 ticks (2.7); duty above period and zero ticks are refused | rounding down instead of to nearest, which the 100 ns case exposes |
| `erx_rtc_ds3231` | known register images, in 24-hour and 12-hour mode, decode to their seconds and encode back in 24-hour mode with the century bit clear; 12 AM is hour 0, 12 PM hour 12, 11 PM hour 23; a non-decimal nibble, 60 seconds, February 30, month 13 and a set century bit are `eio`; OSF gives `einval`; the status written after a set clears OSF and writes A1F and A2F as 1 | the nibble check removed; 12 AM taken as hour 12; the century bit ignored |
| the header map reader | the Pi 4's map is accepted and gives the `config.txt` lines and the `PINS` mask above | for each refusal of the reader, one map that breaks only it: a missing pin, a function not the pin's, the console on GPIO 13, `SDA1` on an SPI0 row, SPI0 without SCLK, a `gpio` row with a function, a driven bus that no row names |
| the `config.txt` writer | the Pi 4's card has `gpio=2-3=a0,pn`, SPI0's and UART3's lines, none for GPIO 18 and 19, `core_freq=500`, `core_freq_fixed=1`, and `enable_jtag_gpio=1` on a development card only | `jtag` rows written as `gpio=` lines on a release card |
| property 8's pin controller clause | the Pi 4's development manifest passes, with `gpio` given to no domain | the same manifest giving `gpio` to the devices domain, which fails naming property 8 and the unit |
| `gpio_grant` and `rtc_grant` | the development manifest passes | a `pins` holding GPIO 14; two `rtc` rows with different addresses; an `rtc` row whose `bus` names SPI0 |

**Fuzz targets**, landing with the parsers: the trees' `ctl` lines and
walk names, one target over the grammars; the RTC's register decoder;
the header map reader, as part of the platform record's.

**The QEMU `raspi4b` suite**, under TCG, on the devices the probe found,
with `-device ds1338,bus=i2c-bus.1,address=0x68` and `-device
m25p16,bus=spi` added. Its first run settles the open [Model] questions
and its result is recorded; a case the model cannot run is left out and
named, never passed by default.

| Case | Passes when | Seeded fault |
| --- | --- | --- |
| RTC through `/dev/rtc/time` (the ds1338 keeps the DS3231's time registers 0 to 6 and a status register at `0x0f` that the driver reads, unverified until this case runs) | a written time reads back within 5 s | the driver's register order swapped |
| `/dev/i2c1/68/reg8` | 7 bytes at offset 0 are the BCD of the time just written | the repeated start replaced by a stop and a new start, if the model distinguishes them; otherwise the case only checks the bytes |
| a missing device, `/dev/i2c1/50/data` | the read answers `eio` | ERR ignored, which returns bytes |
| SPI flash identification through `/dev/spi0/0/data` | a write of `9f 00 00 00` reads back the flash's three ID bytes after the first | the chip select field written as 1 |
| holds, on a chip select | a second session's open of a held `/dev/spi0/0/ctl` answers `ebusy`, and succeeds after the first session ends | release on first close |
| GPIO output, with the GPIO package | `out 1` and `out 0` on GPIO 21 read back on `value`, if the model reflects outputs on GPLEV | GPCLR written for 1 |

**The board checklist**, run by hand on the 4 GB board, as 1b-I's other
checks are ([plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap)):

1. **Probe at boot** (the root holds every page on the stopgap, so it
   reads them once and logs them): the device-tree nodes of GPIO, every
   BSC, every SPI, both PWMs and the clock manager with their paths,
   compatible strings, bases, lines and status, which settles the kind
   rows, BSC5's base (the datasheet's `0x7e205a80`) and whether BSC2 and
   BSC7 are listed; GPFSEL0 to GPFSEL2, PUP_PDN_CNTRL_REG0 and REG1 and
   the bank-0 edge enables at boot and after a minute; the PWM clock's
   control and divisor, which say whether the firmware leaves `clk_pwm`
   running; the oscillator's rate.
2. **GPLEV and the console**: the probe samples GPLEV0 for a few seconds
   while keys are typed at the console and logs whether bit 15 changes.
   That records whether the pin controller's holder could read the
   console silently, as DS Figure 4 predicts; it does not bear on where
   the holder may be, since switching the pin to input reads it either
   way.
3. **SPI loopback**: a jumper wire from header pin 19 (GPIO 10, MOSI) to
   header pin 21 (GPIO 9, MISO). 4096 bytes written to
   `/dev/spi0/0/data` read back unchanged at 1 MHz and at 10 MHz, and a
   three-chunk held transfer with a 50 ms pause between chunks, run by a
   test module in the SPI unit's holder, reads back unchanged. Seeded fault: the wire removed, which reads all ones
   or all zeros.
4. **The core clock**: SCLK on header pin 23, measured with a frequency
   counter or a logic analyser during 4096-byte transfers at CDIV 50,
   agrees with the record's core clock divided by 50 within 1%; without
   an instrument the result is recorded as unmeasured, not inferred from
   transfer times, which polling pauses distort.
5. **RTC**: with a DS3231 module on header pins 1 (3.3 V), 3 and 5 and a
   ground pin, a time written survives a power cut of ten minutes within
   two seconds. Seeded fault: the module unplugged, which reads `eio`.
6. **TPM**, on a manifest with one: the vault's TPM driver reads the
   module's identification, through wait states if the module inserts
   them; its own checks are the vault design's.
7. **GPIO loopback**, with the GPIO package: a jumper cap on header pins
   31 and 32 joins GPIO 6 and GPIO 12. `out 1` and `out 0` on one read
   back on the other's `value`, with `edge both` on the other, each
   change answers an `event` read. Seeded fault: the same with the
   jumper removed and `pull down` set, which must read `0` whatever the
   output.
8. **PWM**, with PWM: a jumper cap on header pins 11 and 12 joins GPIO
   18 to GPIO 17. With `period 100000000` and `duty 50000000` (10 Hz,
   half) and `edge rising` on GPIO 17, its edge count rises by 10 a
   second, slow enough that no edge coalesces with the next; with
   `duty 0` it stops. Seeded fault: `disable`, after which the count
   stops.

## Performance

Polled transfers cost CPU while they wait: back-to-back polls while a
FIFO lasts under a millisecond, and a timer message per service
interval otherwise. That is negligible for the RTC and the TPM's short
transfers and unmeasured for long SPI transfers; the watch list gets the
measurement that settles it, the CPU time and bus time of 4096-byte SPI
transfers at 10 MHz on the board, before any consumer needs throughput
(DMA for SPI, which a display would need, is out of scope and makes the
controller a DMA device of
[design-platforms.md](design-platforms.md#dma)).

## Alternatives considered

* **Run-time pin claims between drivers**, each bus driver asking the
  GPIO driver to set its pins at start. It needs a protocol between
  drivers, a list of pins never to give out, and, with the TPM's SPI in
  the vault's domain and GPIO elsewhere, a dependency of the vault on
  another domain at every start. Letting the firmware set the bus pins
  from one generated map deletes all three, and leaves the buses
  needing no pin holder at all. The cost is that changing which pins a
  bus uses needs a new card build, which is also how FreeBSD and the
  Pi's own firmware configure buses: at boot, from overlays and
  `config.txt`.
* **GPIO in the devices domain.** It keeps the GPIO driver out of the
  trusted base, and gives a domain outside it the console's and the host
  link's wires: a compromised devices domain could take the console or
  read what is typed at it. No probe result retires that, so it would
  be a security residual against a stated commitment, not a placement.
* **A console domain holding the mini UART and the pin controller.** It
  moves the login and the secure line out of the system domain and
  changes property 8's UART clause, more accepted rules than either
  option of Open decision 1, for no gain over them.
* **The PWM clock set by the kernel through the firmware's mailbox**
  (the firmware's clock id for PWM). It widens the mailbox chokepoint
  beyond its two calls, as the core clock's alternative below would,
  and whether the firmware honours a PWM rate there is unverified.
* **Interrupt-driven I2C and SPI.** Line 149 is shared by every I2C
  master, the HDMI masters included, and the register that
  says which one raised it is in the SPI unit's page. Each driver would
  join a line owner and read every master's status at each delivery,
  for transfers that take a millisecond. Polling with a stall limit is
  simpler, and interrupts can be added behind the same core if a
  measurement asks.
* **A total deadline per transfer**, from its length and the bus speed.
  It counts the driver's own scheduling delays against the device, so a
  busy domain fails healthy transfers; the stall limit counts only time
  in which the wire is not moving.
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
  only GPL-licensed overlay sources state. A module row in the platform
  record would avoid the overlays but needs a new record fact and a
  rebuild per module. The facet row's parameters carry the same three
  facts, checked by the manifest check, with no new mechanism.
* **A header map per build kind**, serving GPIO 22 to 27 on release
  cards. No consumer needs six more pins, and two maps of one board
  would have to change together.
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

1. **Where the units that control the console's wires live**: the pin
   controller, and the clock manager if PWM needs its clock written.
   Run-time GPIO, its `/dev/gpio`, the LED and the button wait on this
   answer, and nothing else does: the header map, I2C, the RTC, SPI and
   the TPM go ahead with the pin controller held by no domain. The
   options, both of which property 8's clause allows:
   * **The system domain.** No new domain, and no new authority, since
     the system domain already holds the root authority. It adds code
     that uses that authority: a `/dev/gpio` server parsing other
     domains' `ctl` lines, an interrupt binding and a register path,
     whose defects act with the root authority and whose faults reset
     the machine. It adds the pin controller to the system domain's
     devices, which today are the console's and the host link's UARTs
     ([design-system.md](design-system.md#devices)), and to the devices
     in `docs/design.md`'s placement decision.
   * **One trusted domain of its own**, holding the pin controller, and
     the clock manager if PWM needs it, and nothing else: the PCIe
     domain's pattern for system-wide configuration authority
     ([design-system.md](design-system.md#the-manifest), property 3).
     The trusted code is the same as in the system domain; a defect in
     it reaches the GPIO page, not the root authority. It costs one ERTS
     instance's memory and start, the price
     [design-platforms.md](design-platforms.md#what-the-manifest-says)
     already pays for each unconfined DMA unit of a Pi 4 release
     manifest, and it adds a domain to the trusted base and to
     `docs/design.md`'s placement decision.

   Recommendation, from both advisors and this design: a domain of its
   own, since serving pins to apps is neither the system domain's
   policy nor its console, and the project already has the pattern for
   this kind of authority. The system domain is a sound fallback if one
   ERTS instance is judged too dear.

## References

* BCM2711 ARM Peripherals, release 4, build 2022-01-18, githash
  `cfcff44`, `https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf`
  (SHA-256 `d6e16ea089a1716e80621f99a26e130a2379f0a81d945dc22e4f80dc49dcdc78`):
  sections 2.3, 3.1 to 3.3 (Tables 24, 26 and 30), 5.1 (Figure 4), 5.2
  (Tables 63 to 66, 74, 78, 80, 90 and 91), 5.3 (Table 94), 5.4 (Tables
  96, 99 and 100), 6.2.4 (Table 102, Figure 6), 8.1 to 8.6, 9.5 and 9.6.
* Raspberry Pi 4 reduced schematics,
  `https://datasheets.raspberrypi.com/rpi4/raspberry-pi-4-reduced-schematics.pdf`
  (SHA-256 `0ee3fd2b4976b1d614fc817b0d28564226d3ee8656a9108ccb69c099715d2374`):
  J8 and its ID_SD and ID_SC note.
* TCG PC Client Platform TPM Profile (PTP) Specification, Family 2.0,
  Level 00, Revision 01.03 v22, 22 May 2017,
  `https://medias.cdn.trustedcomputinggroup.org/production/TCG_PC_Client_Platform_TPM_Profile_PTP_2_0_r1_03_v22_8599279b6a.pdf`
  (SHA-256 `9a59782702a010a2436de2943e6ffc0695ddaad4ffc7c7ad72f0b69111bc35ac`):
  section 6.4.5, Flow Control.
* Raspberry Pi documentation, commit `c6a64966af136da21a1e55551c5a395cb6987fce`,
  CC BY-SA 4.0: `config_txt-gpio.adoc` (SHA-256
  `4ad5c0286da3f97f4eb0031af2377c11bd89d78c81f92c3c022187b942b454c0`),
  `config_txt-overclocking.adoc` (`b19ff813e00b3b422b3a200b9d3ed1b3acffd272dcc20bf4eda8fa8a676a5b9c`),
  `config_txt-audio.adoc` (`da6bfd55abcaf52f7856efccd1f2bfbafe90ac4174f1c48f7c18211975a6365f`),
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
