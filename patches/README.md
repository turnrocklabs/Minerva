# Minerva patches

Custom patches applied to vendor submodules during `scripts/build-extensions.sh`.
WRY patches remain in its worktree after the build. Setup recognizes already
applied patches and preserves contributor edits; it never resets the worktree.
Conflicts stop the build and name the patch that needs attention.

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
- `godot_wry-document-navigation-lock.patch` — adds an opt-in construction-time
  exact initial-file navigation lock and blocks new windows for privileged
  documents; ordinary remote WebViews remain ungated. On GTK the native hook
  cannot distinguish frames, so locked documents also block iframe navigation.
- `godot_wry-pinned-wry-source.patch` routes Cargo to the checksum-verified,
  build-local WRY 0.50.5 source prepared by `scripts/apply-wry-patches.py`.
- `wry-0.50.5-file-ipc-request-uri.patch` prevents GTK, WKWebView, WebView2,
  and Android IPC from panicking on authority-free `file:///` documents. It
  substitutes `/` only as inert request metadata; native navigation keeps the
  exact file URL and the wrapper still authenticates the body's capability.
