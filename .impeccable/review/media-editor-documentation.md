# Media editor: ordinary-extension design comparison

Date: 2026-10-29. Artifact: `Sources/Cutmark/MediaEditorWorkspace.swift`, with `MediaEditorTimeline.swift`. Direction: `.impeccable/surfaces/sources-cutmark-timelineeditorwindow-swift.md`.

This is an ordinary functional extension of the incumbent native application, not a replacement visual identity. Under new-work's ordinary-extension rule, this scoped record completes documentation without creating a global `DESIGN.md` or `.impeccable/design.json`. Existing Theme, menu and other approved surfaces remain authoritative. No new global tokens, brand metaphor, or web component translations are introduced.

## Comparison against the incumbent

- Colors: workspace chrome uses `Theme.paper`, `canvas`, `surface`, `ink`, `muted`, `border` and `accent`. These resolve through the user's `Look` rather than freezing the brand-kit comment's hex colors. Timeline lane colors use existing accent, warn and live values; their editor-specific meanings are video, overlay and audio. The playhead uses danger. These are local timeline encodings, not changes to global semantic definitions. Black preview backing and white thumbnail captions are media presentation treatments.
- Typography: labels and headings use `Theme.sans`, which provides bundled Inter with system fallback and the existing text-size factor. Timing uses `Theme.mono`, which means even-width digits within the sans face, not a newly introduced monospace family. SF Symbols provide control imagery. This operating surface does not introduce a display family or override the incumbent Nunito heading helper.
- Components: export and insertion actions reuse `AccentButtonStyle`; import reuses `IconButtonStyle`; speed selection uses `CutmarkMenuButton`; compact panels use `cutmarkPopover`. `MenuKit.swift` remains the menu and panel authority. Existing Theme and MenuKit files have no diff in the reviewed worktree.
- Shape and density: local preview, search and thumbnail radii are 8, 7 and 6 points; time fields use 5 points. This follows an incumbent system that already uses local 7–9 point control radii alongside `Theme.radius` (12), rather than treating 12 as a mandatory radius for every control. These local measurements are observations, not new global scales.
- Layout: at 1120 points and above the browser is 252 points wide and the inspector 246. Below that threshold the panels move behind header controls. The central preview remains dominant and the timeline remains visible. Header height is 48 points; the timeline has a resize divider. These are surface-specific decisions.
- State clarity: source preview shows source metadata and a Back to edit action in the inspector. Timeline clip controls belong to the timeline preview. The reviewed source screenshot reflects that distinction.

## Evidence and scope

The documenter inspected `Theme.swift`, `MenuKit.swift`, `Shell.swift` control definitions, workspace source and timeline theme references. Four supplied native captures were opened and inspected: `/tmp/cutmark-media-shots/editor-wide.png`, `editor-compact.png`, `editor-source.png`, and `editor-dark.png`. They show the named layout/state, including the source metadata inspector and dark appearance. They use synthetic media fixtures and NSHostingView raster capture with a production paused composition frame; they are development evidence, not shipping assets.

The parent finish review reports SHIP within scope after the source-inspector ambiguity and overlay/audio left-trim offset corrections, with nine targeted tests passing. Those test outcomes are recorded as supplied review evidence, not rerun by the documenter. No web design detector ran. This record does not certify interactive testing, continuous playback, audio listening approval, installed-release behavior, or all appearance/text-size combinations.

No pre-existing design drift was established by this scoped comparison. Existing radius variation and dynamic palettes are implementation facts, not reasons to normalize other screens. No unrelated drift was repaired. No shipping raster assets were added by this extension. Recheck this record after subsequent visual changes.
