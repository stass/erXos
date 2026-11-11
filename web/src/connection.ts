/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's connection (docs/design-web.md, "The client"): the WebSocket
 * to /ws, hello, the page's views, one next per rendered update, and
 * reconnection.
 *
 * step() is the pure core: it takes one input (the socket opened, closed or
 * delivered a message; the page rendered a view's update; the retry timer
 * fired) and returns the next state and the actions connect() performs. The
 * page names its views once, as targets, and start() encodes their opens
 * then, so a target that does not encode fails the page at its start, never
 * on a socket. On every new socket the core sends hello and opens view I+1
 * for target I: view numbers only grow on one connection (erx_web_conn), and
 * each socket is a new connection. It sends a view's next only after the
 * page has rendered the update before it, so the machine holds at most one
 * update per view. When the socket is lost every view is stale until a new
 * update replaces it, and the core reconnects after 1 s, doubling to 30 s,
 * back to 1 s once a welcome arrives. A bye for another build ends the
 * client, since no reconnect can change the build; any other bye reconnects.
 *
 * A reconnect reopens every view, so a target is never `trace`: a trace
 * starts only from a user's action (W6), which the type Reopenable makes the
 * only way to start one.
 *
 * Machine messages are untrusted: one that does not decode, or names a view
 * that is not waiting for an update, closes the socket.
 */

import {
  type Body,
  type ByeReason,
  type Browser,
  type Name,
  type Target,
  decodeMachine,
  encodeBrowser,
  protocolHash,
} from './generated/proto.ts';

export const RETRY_FIRST_MS = 1000;
export const RETRY_MAX_MS = 30_000;

/* A target a reconnect may open again without a user's action. */
export type Reopenable = Exclude<Target, { readonly tag: 'trace' }>;

export type Input =
  | { readonly kind: 'opened' }
  | { readonly kind: 'message'; readonly bytes: Uint8Array }
  | { readonly kind: 'rendered'; readonly index: number }
  | { readonly kind: 'closed' }
  | { readonly kind: 'retry' };

/* index is the position of the view's target in the page's list. */
export type Action =
  | { readonly kind: 'connect' }
  | { readonly kind: 'send'; readonly bytes: Uint8Array }
  | { readonly kind: 'close' }
  | { readonly kind: 'wait'; readonly ms: number }
  | { readonly kind: 'show'; readonly index: number; readonly body: Body }
  | { readonly kind: 'ended'; readonly index: number; readonly reason: Name }
  | { readonly kind: 'stale' }
  | { readonly kind: 'bye'; readonly reason: ByeReason };

/*
 * A view on the open socket is `asked` while the machine owes it an update,
 * `rendering` while the page renders the update it got and its next waits
 * for that, and `ended` once the machine ended it.
 */
type Pull = 'asked' | 'rendering' | 'ended';

/*
 * connecting: a socket is being opened; open: hello and the opens went out,
 * and pulls holds one entry per target; refused: a bye for another build
 * came, and the close ends the client; waiting: the retry timer runs.
 * greeting is hello followed by each target's open, encoded once.
 */
export type State = {
  readonly phase: 'connecting' | 'open' | 'refused' | 'waiting';
  readonly greeting: readonly Uint8Array[];
  readonly pulls: readonly Pull[];
  readonly delay: number;
};

type Step = { readonly state: State; readonly actions: Action[] };

/* View I+1 shows target I on every socket. */
const viewOf = (index: number): number => index + 1;
const indexOf = (view: number): number => view - 1;

export function start(targets: readonly Reopenable[]): Step {
  const greeting = [encode({ tag: 'hello', hash: protocolHash() }),
                    ...targets.map((target, index) => encode({ tag: 'open', view: viewOf(index), target }))];
  return { state: { phase: 'connecting', greeting, pulls: [], delay: RETRY_FIRST_MS }, actions: [{ kind: 'connect' }] };
}

export function step(state: State, input: Input): Step {
  switch (input.kind) {
    case 'opened':
      return state.phase === 'connecting' ? opened(state) : unchanged(state);
    case 'message':
      return state.phase === 'open' ? message(state, input.bytes) : unchanged(state);
    case 'rendered':
      return state.phase === 'open' && state.pulls[input.index] === 'rendering'
        ? { state: pulled(state, input.index, 'asked'), actions: [send({ tag: 'next', view: viewOf(input.index) })] }
        : unchanged(state);
    case 'closed':
      return closed(state);
    case 'retry':
      return state.phase === 'waiting'
        ? { state: { ...state, phase: 'connecting' }, actions: [{ kind: 'connect' }] }
        : unchanged(state);
  }
}

function opened(state: State): Step {
  return {
    state: { ...state, phase: 'open', pulls: state.greeting.slice(1).map(() => 'asked') },
    actions: state.greeting.map((bytes) => ({ kind: 'send', bytes })),
  };
}

function message(state: State, bytes: Uint8Array): Step {
  const decoded = decodeMachine(bytes);
  if (!decoded.ok) return { state, actions: [{ kind: 'close' }] };
  const machine = decoded.value;
  switch (machine.tag) {
    case 'welcome':
      return { state: { ...state, delay: RETRY_FIRST_MS }, actions: [] };
    case 'update': {
      const index = indexOf(machine.view);
      if (state.pulls[index] !== 'asked') return { state, actions: [{ kind: 'close' }] };
      return { state: pulled(state, index, 'rendering'), actions: [{ kind: 'show', index, body: machine.body }] };
    }
    case 'ended': {
      const index = indexOf(machine.view);
      if (state.pulls[index] === undefined || state.pulls[index] === 'ended') return { state, actions: [{ kind: 'close' }] };
      return { state: pulled(state, index, 'ended'), actions: [{ kind: 'ended', index, reason: machine.reason }] };
    }
    case 'bye':
      return machine.reason === 'mismatch'
        ? { state: { ...state, phase: 'refused' }, actions: [{ kind: 'bye', reason: machine.reason }, { kind: 'close' }] }
        : { state, actions: [{ kind: 'bye', reason: machine.reason }] };
  }
}

/* A refused client stays closed; any other loss waits out the delay and doubles it. */
function closed(state: State): Step {
  switch (state.phase) {
    case 'waiting':
      return unchanged(state);
    case 'refused':
      return { state: { ...state, pulls: [] }, actions: [{ kind: 'stale' }] };
    case 'connecting':
    case 'open':
      return {
        state: { ...state, phase: 'waiting', pulls: [], delay: Math.min(state.delay * 2, RETRY_MAX_MS) },
        actions: [{ kind: 'stale' }, { kind: 'wait', ms: state.delay }],
      };
  }
}

const unchanged = (state: State): Step => ({ state, actions: [] });

function pulled(state: State, index: number, pull: Pull): State {
  return { ...state, pulls: state.pulls.map((old, at) => (at === index ? pull : old)) };
}

const send = (message: Browser): Action => ({ kind: 'send', bytes: encode(message) });

/*
 * A browser message. A next always encodes, being a view number below the
 * page's few targets; hello and the opens are encoded at start(), so a page
 * whose target does not encode fails there, before any socket.
 */
function encode(message: Browser): Uint8Array {
  const encoded = encodeBrowser(message);
  if (!encoded.ok) throw new Error(`the client's ${message.tag} does not encode: ${encoded.reason}`);
  return encoded.bytes;
}

/* What the page does with the core's view actions. */
export type Page = {
  readonly show: (index: number, body: Body) => void;
  readonly ended: (index: number, reason: Name) => void;
  readonly stale: () => void;
  readonly bye: (reason: ByeReason) => void;
};

/*
 * The effects around step(): the WebSocket to /ws of the page's own origin,
 * which the front end checks, and the retry timer. A socket the browser
 * refuses to make counts as one that closed. The returned function is the
 * page's report that it rendered a view's update.
 */
export function connect(targets: readonly Reopenable[], page: Page): (index: number) => void {
  let socket: WebSocket | undefined;
  let current = start(targets);
  const url = new URL('/ws', window.location.origin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';

  const apply = (next: Step): void => {
    current = next;
    for (const action of next.actions) perform(action);
  };
  const feed = (input: Input): void => apply(step(current.state, input));
  const open = (): void => {
    try {
      socket = new WebSocket(url);
    } catch {
      socket = undefined;
      window.setTimeout(() => feed({ kind: 'closed' }), 0);
      return;
    }
    const made = socket;
    made.binaryType = 'arraybuffer';
    made.onopen = () => feed({ kind: 'opened' });
    made.onmessage = (event: MessageEvent) =>
      event.data instanceof ArrayBuffer ? feed({ kind: 'message', bytes: new Uint8Array(event.data) }) : made.close();
    made.onclose = () => feed({ kind: 'closed' });
  };
  const perform = (action: Action): void => {
    switch (action.kind) {
      case 'connect': open(); return;
      case 'send': socket?.send(new Uint8Array(action.bytes)); return;
      case 'close': socket?.close(); return;
      case 'wait': window.setTimeout(() => feed({ kind: 'retry' }), action.ms); return;
      case 'show': page.show(action.index, action.body); return;
      case 'ended': page.ended(action.index, action.reason); return;
      case 'stale': page.stale(); return;
      case 'bye': page.bye(action.reason); return;
    }
  };

  apply(current);
  return (index: number) => feed({ kind: 'rendered', index });
}
