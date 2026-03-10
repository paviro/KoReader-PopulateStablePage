# Populate Missing Stable Page Metadata

This KOReader plugin backfills missing stable page metadata in book sidecar files.

## Compatibility

- Requires a KOReader nightly build, or a stable release newer than KOReader 2025.10 "Ghost".

## What it does

- Scans the selected folder and all subfolders for books with sidecar metadata.
- For supported crengine documents, populates missing required stable page fields.
- Required fields for this plugin are:
  - `pagemap_doc_pages`
  - `pagemap_use_page_labels`
- Also writes optional stable page fields when missing and available:
  - `pagemap_current_page_label`
  - `pagemap_last_page_label`
  - `pagemap_show_page_labels`
  - `pagemap_chars_per_synthetic_page`
- Keeps existing per-book values as-is by default (does not overwrite them).
- Optional checkbox in the confirmation dialog can overwrite per-book stable page settings that differ from current global values and recompute page metadata.
- Uses current global KOReader settings for per-book display flags only when those per-book flags are missing.
- When overwrite mode is enabled, per-book display flags and synthetic page size are aligned to the current global values.

## Install

1. Copy the plugin folder `populatestablepage.koplugin` into your KOReader `plugins` directory.
2. Restart KOReader.

The final path should look like:

`.../koreader/plugins/populatestablepage.koplugin/`

## Where to find it

Open KOReader File Manager, then go to:

`Tools -> More tools -> Populate missing stable page metadata`

## Notes

- Before running, the plugin can optionally apply recommended global defaults:
  - `pagemap_chars_per_synthetic_page = 1500`
  - `pagemap_synthetic_overrides = true`
- A log file is kept only when issues are found (for example failed books or unsupported/no-pagemap books).
