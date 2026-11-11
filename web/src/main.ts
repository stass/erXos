/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The client's entry point, the one module `make web` bundles
 * (docs/design-web.md, "The client"): it brings in the stylesheet, which
 * esbuild writes as the bundle's one CSS file, and gives the page its
 * heading. The page holds no markup of its own beyond the two files
 * index.html names, so every node the client shows is made here or by
 * the modules it imports, as text.
 */

import './client.css';

const heading = document.createElement('h1');
heading.textContent = 'erXos';
document.body.replaceChildren(heading);
