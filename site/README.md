# erXos website

The landing page for erXos: one static page, plain HTML and CSS, no
JavaScript and no build step.

## Viewing it

Open `site/index.html` in a browser. Any static file server works too:

```
ruby -run -e httpd site -p 8000
```

Then visit <http://localhost:8000/>. Without network access the page
falls back to system fonts and still renders.

## Files

* `index.html` is the page. Its sections, in order: the hero (logo, the
  question, a status-light panel and a short spec list), the idea and
  goals, the five principles, the architecture with a layer sketch, the
  current status, and "Try it" with a recorded console session. The logo
  is inlined as an SVG path taken from `erxos-logo.svg` at the top of the
  tree, filled with `currentColor` so it follows light and dark themes.
* `style.css` holds every style. Colours are tokens on `:root`, redefined
  for dark mode. The status lights are CSS only; their blinking stops
  under `prefers-reduced-motion`.

The text follows the README's "Current status". When that section
changes, update the Status section here to match; claim nothing the
README does not.

## Fonts

Loaded at run time from Google Fonts:

| Font | Use | License |
| --- | --- | --- |
| Archivo (variable, width and weight axes) | headings (widest cut) and body | SIL Open Font License 1.1 |
| IBM Plex Mono | labels, the layer sketch, the terminal | SIL Open Font License 1.1 |

The page sends no tracking or analytics requests.

## Where the terminal goes

The "Try it" section holds a terminal panel. Its body is
`<div id="erx-terminal" data-erx-terminal="recorded">`, which contains a
recorded session from the README's transcript in a `<pre>`.

The terminal step replaces the contents of `#erx-terminal` with an
xterm.js terminal attached to erXos running in the browser under v64.
Keep the recorded `<pre>` in the HTML as the fallback for readers without
JavaScript, and let the script swap it out only once the emulator has
started. The panel's title bar reads "Recorded session"; change it when
the session is live.

## Open items

* The footer links (Source, Architecture, Roadmap) point at `#` until the
  source repository has a public address; a TODO comment marks them.
