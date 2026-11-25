"""bleuart's peer (docs/design-bluetooth.md, "The console", and "On QEMU against
Bumble"). Started by the Bluetooth suite's harness (tools/lib/erx/bt_domain.rb,
Bleuart) on Bumble's second controller:
  bleuart_peer.py shell|absent|present TRANSPORT
TRANSPORT is a Bumble transport name, tcp-client:127.0.0.1:PORT.

shell: the peer scans for the advertiser whose advertising data lists nus's UUID,
connects with no pairing, finds nus's rx and tx, subscribes to tx's notifications
and reads until the shell's prompt, `% `, ends what came. It then types each of
COMMANDS, a write of rx with response, and reads until the next prompt. It passes
when the answer to `ps -o comm` names no process of the system domain (SYSTEM_ONLY),
so the line runs a shell of root's session and not the system's, and the answer to
`echo hi` is its echoed line followed by `hi`. It then types UNTIL_INTERRUPTED, a
`top` that runs until it is interrupted: once its display has cleared the screen,
which it does only on a terminal, no prompt may come for SETTLE_SECONDS, and after
Ctrl-C one must come within INTERRUPT_SECONDS. It disconnects, scans and connects
again, and needs a new prompt; there `ps -o comm` must list at least one shell
(SHELL, a command shell's group) and no more than it did on the first connection,
so the shell the disconnect hung up is gone from root's session.

absent: the peer waits SETTLE_SECONDS, then scans for SCAN_SECONDS, and passes when
no advertising report in that time lists nus's UUID: once bleuart has stopped, no
handler holds nus and the Bluetooth domain advertises it no more.

present: the peer scans for at most START_SECONDS and passes once an advertising
report lists nus's UUID: bleuart has started again and attached nus.

Everything the radio sends is bounded before it is kept: at most MAX_REPORTS
advertising reports are looked at in a shell run, each notification may carry at
most MTU_MAX - 3 octets and all of them together at most MAX_OCTETS. The peer
prints one line, `bleuart passed MODE` or `bleuart failed REASON`, and exits 0 or 1;
REASON names counts and steps only, never the radio's bytes, so nothing a peer sends
reaches the harness's terminal. What the shell printed goes to standard error, which
the harness keeps in a file, escaped by repr() to ASCII.

Every wait is bounded: the peer's own waits by the constants below, which leave a
shell run well inside the harness's deadline for a peer (Serial::SECONDS), and each
GATT request by Bumble's request timeout. Each step prints what came back to
standard error, so a run the harness's deadline ends shows the step it was at.
"""

import asyncio
import sys

import bumble.core
from bumble.core import UUID, AdvertisingData, ProtocolError
from bumble.device import Device, Peer
from bumble.hci import Address
from bumble.transport import open_transport

NUS = UUID('6e400001-b5a3-f393-e0a9-e50e24dcca9e')
RX = UUID('6e400002-b5a3-f393-e0a9-e50e24dcca9e')
TX = UUID('6e400003-b5a3-f393-e0a9-e50e24dcca9e')
OWN_ADDRESS = 'F0:F1:F2:F3:F4:F6'
MTU_MAX = 517
MAX_REPORTS = 256
MAX_OCTETS = 64 * 1024
SCAN_SECONDS = 30
CONNECT_SECONDS = 15
PROMPT_SECONDS = 20
SETTLE_SECONDS = 5
INTERRUPT_SECONDS = 20
# A started bleuart's session boots before it attaches nus.
START_SECONDS = 120
PROMPT = b'% '
# A process the system domain runs and no session runs: the login service.
SYSTEM_ONLY = b'erx_login'
COMMANDS = (b'ps -o comm', b'echo hi')
# ps's name of a command shell's group: one line for each shell of root's session.
SHELL = b'{group,{erx_shell,server,'
INTERRUPT = b'\x03'
# What top writes before each display on a terminal (erx_cmd_top): it is running.
SCREEN_CLEARED = b'\x1b[H\x1b[2J'
# A command that runs until it is interrupted: top on a terminal shows a display, here
# of 5 processes, then the next one every 600 s, until Ctrl-C. A command reading the
# terminal will not do: a command's standard input there reads its end at once
# (docs/todo-shell.md).
UNTIL_INTERRUPTED = b'top -s 600 5'


class Failed(Exception):
    """The run's one failure path: what went wrong, in counts and steps."""


class Shell:
    """What tx brings back, each notification bounded before it is kept."""

    def __init__(self):
        self.received = bytearray()
        self.fault = None
        self.changed = asyncio.Event()

    def notified(self, value):
        if self.fault is not None:
            return
        if not isinstance(value, (bytes, bytearray)):
            self.fault = 'a notification that is not octets'
        elif len(value) > MTU_MAX - 3:
            self.fault = f'a notification of {len(value)} octets'
        elif len(self.received) + len(value) > MAX_OCTETS:
            self.fault = f'more than {MAX_OCTETS} octets back'
        else:
            self.received.extend(value)
        self.changed.set()

    async def reached(self, step, done, seconds, missing):
        """Waits at most seconds until done(what came) holds, keeping what came."""
        async def waited():
            while self.fault is None and not done(self.received):
                self.changed.clear()
                await self.changed.wait()
        try:
            await asyncio.wait_for(waited(), seconds)
        except asyncio.TimeoutError:
            print(f'{step}, {missing}: {bytes(self.received)!r}', file=sys.stderr, flush=True)
            raise Failed(f'{missing} within {seconds} s after {step}') from None
        if self.fault is not None:
            raise Failed(self.fault)

    async def answer(self, step, seconds=PROMPT_SECONDS):
        """Everything since the last answer, up to and including the next prompt."""
        await self.reached(step, lambda text: text.endswith(PROMPT), seconds, 'no prompt')
        text = bytes(self.received)
        self.received.clear()
        print(f'{step}: {text!r}', file=sys.stderr, flush=True)
        return text


async def advertiser(device):
    """The address of the first advertiser among MAX_REPORTS that lists nus."""
    found = asyncio.get_running_loop().create_future()
    seen = 0

    def report(advertisement):
        nonlocal seen
        if found.done():
            return
        seen += 1
        if NUS in lists(advertisement):
            found.set_result(advertisement.address)
        elif seen >= MAX_REPORTS:
            found.set_exception(Failed(f'no advertiser lists nus in {seen} reports'))

    device.on('advertisement', report)
    await device.start_scanning(active=False, filter_duplicates=True)
    try:
        return await asyncio.wait_for(found, SCAN_SECONDS)
    except asyncio.TimeoutError:
        raise Failed(f'no advertiser lists nus within {SCAN_SECONDS} s') from None
    finally:
        await device.stop_scanning()


def lists(advertisement):
    return advertisement.data.get(AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS) or []


def one_characteristic(service, uuid, name):
    found = service.get_characteristics_by_uuid(uuid)
    if len(found) != 1:
        raise Failed(f'nus has {len(found)} characteristics {name}')
    return found[0]


async def connected(device, step):
    """A connection to nus's advertiser, subscribed to tx, at the shell's prompt."""
    address = await advertiser(device)
    connection = await asyncio.wait_for(device.connect(address), CONNECT_SECONDS)
    peer = Peer(connection)
    services = await peer.discover_service(NUS)
    if len(services) != 1:
        raise Failed(f'{len(services)} services nus')
    await peer.discover_characteristics(service=services[0])
    rx = one_characteristic(services[0], RX, 'rx')
    tx = one_characteristic(services[0], TX, 'tx')
    line = Shell()
    await peer.subscribe(tx, line.notified)
    await line.answer(step)
    return connection, peer, rx, line


async def typed(peer, rx, line, command):
    await peer.write_value(rx, command + b'\r', with_response=True)
    return await line.answer(command.decode())


def shells(answer):
    """How many lines of ps's answer name a command shell's group; an answer without
    ps's COMMAND header, an error or an unknown keyword, fails the run."""
    rows = answer.replace(b'\r', b'').split(b'\n')
    if b'COMMAND' not in rows:
        raise Failed('ps -o comm did not answer its COMMAND header')
    return sum(row.startswith(SHELL) for row in rows)


async def shell(device):
    connection, peer, rx, line = await connected(device, 'the subscription')
    answers = {}
    for command in COMMANDS:
        answers[command] = await typed(peer, rx, line, command)
    if SYSTEM_ONLY in answers[b'ps -o comm']:
        raise Failed('ps on the line lists the system domain\'s login service')
    # Carriage returns aside: a command's output reaches the line CR CR LF
    # (docs/todo-session.md, a command's output through the console).
    if b'echo hi\nhi\n' not in answers[b'echo hi'].replace(b'\r', b''):
        raise Failed('echo hi did not answer hi')
    before = shells(answers[b'ps -o comm'])
    if before < 1:
        raise Failed('ps on the line lists no command shell')
    # UNTIL_INTERRUPTED runs until Ctrl-C interrupts it: once its display shows it
    # running, no prompt before the key, and one in time after it, is the
    # interrupt's, the line's ISIG having turned the key into the interrupt of the
    # shell's job.
    await peer.write_value(rx, UNTIL_INTERRUPTED + b'\r', with_response=True)
    await line.reached('top', lambda text: SCREEN_CLEARED in text, PROMPT_SECONDS, 'no display')
    await asyncio.sleep(SETTLE_SECONDS)
    if line.fault is not None or line.received.endswith(PROMPT):
        print(f'top: {bytes(line.received)!r}', file=sys.stderr, flush=True)
        raise Failed(line.fault or 'top ended before Ctrl-C')
    await peer.write_value(rx, INTERRUPT, with_response=True)
    await line.answer('Ctrl-C', INTERRUPT_SECONDS)
    await asyncio.wait_for(connection.disconnect(), CONNECT_SECONDS)
    await asyncio.sleep(SETTLE_SECONDS)
    connection, peer, rx, line = await connected(device, 'the reconnection')
    after = shells(await typed(peer, rx, line, b'ps -o comm'))
    if not 1 <= after <= before:
        raise Failed(f'ps lists {after} command shells after the reconnection, {before} before')
    await asyncio.wait_for(connection.disconnect(), CONNECT_SECONDS)


async def absent(device):
    await asyncio.sleep(SETTLE_SECONDS)
    listed = 0
    seen = 0

    def report(advertisement):
        nonlocal listed, seen
        seen += 1
        listed += NUS in lists(advertisement)

    device.on('advertisement', report)
    await device.start_scanning(active=False, filter_duplicates=False)
    await asyncio.sleep(SCAN_SECONDS)
    await device.stop_scanning()
    print(f'absent: {seen} reports, {listed} listing nus', file=sys.stderr, flush=True)
    # The domain keeps advertising its name with no nus, so no report at all is a
    # broken link or domain, not an absent service.
    if not seen:
        raise Failed('no advertising report came')
    if listed:
        raise Failed(f'{listed} of {seen} advertising reports list nus')


async def present(device):
    found = asyncio.get_running_loop().create_future()
    seen = 0

    def report(advertisement):
        nonlocal seen
        seen += 1
        if NUS in lists(advertisement) and not found.done():
            found.set_result(None)

    device.on('advertisement', report)
    await device.start_scanning(active=False, filter_duplicates=False)
    try:
        await asyncio.wait_for(found, START_SECONDS)
    except asyncio.TimeoutError:
        raise Failed(f'none of {seen} advertising reports lists nus within {START_SECONDS} s') from None
    finally:
        await device.stop_scanning()


async def run(mode, transport):
    async with await open_transport(transport) as hci:
        device = Device.with_hci('bleuart-peer', Address(OWN_ADDRESS), hci.source, hci.sink)
        await device.power_on()
        await {'shell': shell, 'absent': absent, 'present': present}[mode](device)


def main(argv):
    if len(argv) != 3 or argv[1] not in ('shell', 'absent', 'present') or \
            not argv[2].startswith('tcp-client:127.0.0.1:'):
        print('usage: bleuart_peer.py shell|absent|present tcp-client:127.0.0.1:PORT', file=sys.stderr)
        return 2
    try:
        asyncio.run(run(argv[1], argv[2]))
    except Failed as failure:
        print(f'bleuart failed {failure}', flush=True)
        return 1
    except ProtocolError as error:
        print(f'bleuart failed the radio answered {error.error_name}', flush=True)
        return 1
    except (asyncio.TimeoutError, bumble.core.TimeoutError, ConnectionError) as error:
        print(f'bleuart failed {type(error).__name__}', flush=True)
        return 1
    print(f'bleuart passed {argv[1]}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
