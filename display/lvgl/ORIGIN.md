# Source origin

LVGL, the stopgap native widget renderer behind `erx_ui_renderer`
([design-display.md](../../docs/design-display.md#the-widget-server)), is
the git submodule `lvgl/` beside this file.

| | |
| --- | --- |
| Upstream repository | `https://github.com/lvgl/lvgl` |
| Release | v9.6.0 |
| Commit | `80ca777e37a2b176770726a02e07a6fb79ef0b39` |
| Release archive | `https://github.com/lvgl/lvgl/archive/refs/tags/v9.6.0.tar.gz` |
| Release archive SHA-256 | `b20ee3acc1bba13c62d854f9ebd62e4c51e0b443b1e0225892e86442defa84df` |
| erXos's fork | `https://github.com/stass/lvgl` |

The submodule is cloned from erXos's fork, and the superproject's gitlink
records the commit it is checked out at: that commit is the pin, and this
file documents it. `git submodule update` checks out the recorded commit; a
checkout moved to another commit, or holding changes, is still built, with
a warning naming the difference. The commit above is the one upstream's `v9.6.0`
tag names, and the archive is the release that tag produced, recorded so
the import can be checked against what upstream published. erXos's patches
to LVGL are commits on a branch of the fork; moving the recorded commit to
one of them is how a patch lands, and this file then names the branch and
the commit the patches start from.

License: MIT, whose text is the submodule's `LICENCE.txt`; the copyright
holders of bundled third-party code are listed in its `COPYRIGHTS.md`.

The build compiles the C sources under `src/` with `display/lvgl/lv_conf.h`
and nothing else: no script, makefile or generator of the submodule runs.
Fetch it with `git submodule update --init display/lvgl/lvgl`. `tools/erx
fetch` runs that with `--depth 1` when it is not checked out, so the clone
holds no history; `git fetch --unshallow` in it brings the history for
patch work.
