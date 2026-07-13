# Screenotate

Screenotate is a native macOS prototype for leaving task-like **resume markers** on any app surface. Markers are attached to the foreground app and window title, disappear when you leave that context, and return when you come back.

## Try it

1. Run `scripts/package-app.sh`.
2. Open `dist/Screenotate.app`.
3. In Cursor—or any other app—press **Control–Option–A**.
4. Type what you need to remember and press Return.
5. Switch away and return to see the marker follow its context.

The checkmark-bubble menu bar icon can also add a marker or open the data folder.
Launchers and local automations can open `screenotate://new` to start capture.

## Sticky notes and highlights

- Choose **New sticky note…** for a persistent multiline pad attached to the current app/window.
- Choose **New checklist…** and enter one item per line to place a checkable list without leaving the surface.
- Choose **Draw highlight around something…**, then drag a rectangle around any visible item.
- Highlights and notes disappear when you leave that surface and return when you come back.
- Use **Clear drawings on this surface…** to remove its highlights.

Automation URLs: `screenotate://note`, `screenotate://checklist`, `screenotate://draw`, `screenotate://new`, and `screenotate://import`.

## Adopt an existing checklist without copying

1. Leave the checklist visible in Cursor or another app.
2. Choose **Screenotate → Adopt visible checklist…** from the menu-bar icon.
3. The first time, macOS asks you to grant Screenotate Accessibility permission. This is required to read visible interface text; the data stays on your Mac.
4. Review the detected lines. Likely tasks are preselected.
5. Choose **Create markers**.

You can also open `screenotate://import` from a launcher or local automation.

## Chronicle data

Screenotate stores local data in:

```text
~/Library/Application Support/Screenotate/
├── annotations.json
└── chronicle-events.jsonl
```

The append-only event stream uses schema `screenotate.chronicle.v1` and records creation, import, completion, reopening, and deletion with the source app/window context.

Visible markers are included in Chronicle's normal screen capture and OCR history. The JSONL file is a companion structured export for a local agent or a future direct connector; Chronicle does **not** currently expose a public custom-event ingestion API, so Screenotate does not claim that this file is ingested automatically.

## Current scope

- Native floating markers across macOS Spaces and fullscreen apps
- Context restoration based on application bundle ID and window title
- One global capture shortcut
- Completion and deletion events
- Local-only persistence
- Permission-aware adoption of visible interface text through macOS Accessibility
- Persistent multiline sticky notes
- Manually created multi-item checklists
- Persistent highlighter rectangles drawn directly around screen content

Planned after interaction validation: browser URL/file-path anchors, OCR fallback for apps with weak Accessibility support, editing, and automatic reposition persistence.
