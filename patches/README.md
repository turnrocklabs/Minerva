# Minerva patches

Custom patches applied to vendor submodules during `scripts/build-extensions.sh`.
The submodule source tree stays clean in `git status` — patches only exist on
disk inside the submodule during the build itself, then the submodule is reset.

## godot_wry

Patches matching `patches/godot_wry-*.patch` are applied automatically, in
lexical order, to `vendor/godot_wry` before `cargo build --release`. Current
patches:

- `godot_wry-fix-positioning.patch` — upstream uses `get_screen_position()` for
  the native overlay, which is wrong under Godot viewport scaling. Swap to
  `get_global_position()` so plugin panels render at the correct coordinates.
- `godot_wry-linux-xsetinputfocus.patch` — upstream `WebView::focus()` only
  calls `gtk_widget_grab_focus()`, which doesn't transfer X11 input focus.
  The webview is a child X window of Godot's X window; this patch adds an
  `XSetInputFocus` call on Linux so text inputs get keyboard events and show
  a blinking cursor.

## Adding a new patch

1. Make your changes inside the submodule (`vendor/godot_wry/...`).
2. Verify `cargo build --release` from `vendor/godot_wry/rust` succeeds.
3. Capture the diff from a clean-upstream base:
   ```sh
   cd vendor/godot_wry
   git diff > ../../patches/godot_wry-<topic>.patch
   git checkout -- .   # reset back to clean upstream
   ```
4. Re-run `scripts/build-extensions.sh` and confirm the patch still applies
   cleanly and the rebuilt binary lands in `src/addons/godot_wry/bin/`.
5. Commit the `.patch` file.

Patches are rebased onto upstream by hand when the submodule is bumped.
Keep them minimal and well-scoped so upstream drift doesn't break them all
at once.
