# Disk image layout

`scripts/make-dmg-layout.m` generates a fresh `.DS_Store` on the mounted
installation volume. No Finder-generated binary template is stored in the
repository. The helper uses stock Apple Clang, Foundation, and CoreServices;
it needs no external packages or Finder Automation permission.

It selects icon view, hides the toolbar, positions `Portside.app` at (155, 220)
and the `Applications` shortcut at (485, 220), and references the hidden
`.background/background.png` image. Window bounds are (220, 160, 860, 588),
with 128-point icons and 14-point labels.

The background is generated at 2× resolution from the supplied logo by
`scripts/make-dmg-background.swift`. After mounting under `/Volumes`, packaging
generates a minimal single-leaf store with zeroed unused space. The native
background alias retains only names, IDs, dates, and a path relative to this
image's volume. The helper removes the mount-path extension, recursive alias
to the backing disk image, and all unknown extensions. It writes no modern
Finder bookmark/security records, which can include the builder's home paths
and host-volume identifiers even with minimal-bookmark options.

The helper resolves the sanitized alias through Apple's native API before
writing the store. Rebuild with `bash scripts/package-dmg.sh`, then remount
the resulting read-only image to check the layout and background. Merely
navigating to a still-writable staging image can display Finder's cached
pre-generation layout.
