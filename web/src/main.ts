/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's entry point, the one module `make web` bundles
 * (docs/design-web.md, "The client"): it brings in the stylesheet, which
 * esbuild writes as the bundle's one CSS file, and renders the page for the
 * URL's route. The page holds no markup of its own beyond the two files
 * index.html names, so every node the client shows is made by React from
 * the modules it imports, as text. The home route shows the machine's own
 * record and a /proc route the record of its path; the client has no view
 * yet for any other route, and says so rather than show a record under
 * another view's URL.
 */

import { createElement } from 'react';
import { createRoot } from 'react-dom/client';
import './client.css';
import { RecordPage } from './record.tsx';
import { type Route, parseRoute } from './routes.ts';

function page(route: Route | undefined) {
  const value = route?.value;
  switch (value?.kind) {
    case 'home': return createElement(RecordPage, { path: [] });
    case 'proc': return createElement(RecordPage, { path: value.path });
    default: return createElement('p', null, 'This address names no view of this client.');
  }
}

const root = document.createElement('div');
document.body.replaceChildren(root);
createRoot(root).render(page(parseRoute(window.location.pathname)));
