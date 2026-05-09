# Unitree G1 Docs Mirror

`mirror_g1_docs.py` rebuilds a local, flat copy of the Unitree G1 markdown docs
from `unitree_g1_dev/g1-doc-index.json`.

Default output:

```bash
python3 unitree_g1_dev/tools/mirror_g1_docs.py
```

The generated mirror is written to:

```text
unitree_g1_dev/g1-docs/
  index.json
  index.md
  pages/
  raw/
  assets/
```

Page filenames encode the original document hierarchy while staying flat:

```text
00_about_G1.md
01_Operational_guidance.md
01_00_quick_start.md
04_09_time_sync_interface.md
```

By default the tool mirrors markdown plus doc-friendly assets: images, PDFs, and
small text-like files. Videos, audio files, and archives remain as original URLs
unless explicitly requested:

```bash
python3 unitree_g1_dev/tools/mirror_g1_docs.py --asset-mode all
```

Use `--help` for alternate index/output paths and request limits.

## Compress Mirrored Images

On macOS, shrink large image assets with `sips`:

```bash
python3 unitree_g1_dev/tools/optimize_g1_doc_assets.py
```

This keeps filenames stable for JPEGs, converts large PNGs to high-quality
JPEGs when that is materially smaller, and rewrites markdown links.
