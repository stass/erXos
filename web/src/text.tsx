/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Text, the one component that renders a MachineText (docs/design-web.md,
 * "The client", W2): the text's line escape, its plain runs as text nodes and
 * its escape tokens in a styled span, the whole in an element whose
 * unicode-bidi is isolate, so a right-to-left run reorders only within its
 * own text. React writes every string here as a text node, never as markup.
 */

import type { MachineText } from './text.ts';

export function Text({ value }: { readonly value: MachineText }) {
  return (
    <span className="machine-text">
      {value.runs().map((run, at) => (run.kind === 'plain' ? run.text : <span key={at} className="token">{run.text}</span>))}
    </span>
  );
}
