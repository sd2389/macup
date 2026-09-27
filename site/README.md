# MacUp site

The project's landing page. One static page, no build step, no dependencies:
`index.html`, `styles.css`, and real screenshots of the app in `screenshots/`.

Preview it locally:

```bash
python3 -m http.server 4173 --directory site
```

The screenshots are captured from the app itself with
`MacUp --snapshot-dir <dir>` (see `scripts/build-app.sh` and
`Apps/MacUpApp/MacUpApp/App/Snapshots.swift`), so they always show the real
UI rather than a mockup. Re-capture them after a UI change.

To publish on GitHub Pages, point Pages at this folder on the default branch.
