# Paper build tooling

Builds the RosettaBitcoin paper from its Markdown source into a shareable PDF
and an arXiv-ready LaTeX bundle.

## Source of truth

`../rosettabitcoin_paper_publication.md` (i.e. `Docs/rosettabitcoin_paper_publication.md`).
Edit the paper there; this folder only builds it.

## Build

From the repository root:

```bash
bash Docs/paper/build.sh
```

Outputs land in `Docs/paper/out/`:

| File | Use |
|---|---|
| `rosettabitcoin.pdf` | Compiled single-column manuscript |
| `rosettabitcoin.tex` | arXiv-ready LaTeX source |
| `substrate_pipeline.pdf` | Reproducible evidence-pipeline figure |
| `arxiv-rosettabitcoin.tar.gz` | The arXiv submission bundle (.tex + figure + 00README) |

The delivery PDF is also copied to `output/pdf/rosettabitcoin.pdf`.

## Requirements

- `pandoc`
- A LaTeX toolchain with **XeLaTeX** (`texlive-xetex`, `latexmk`) — the paper
  uses Unicode (→, ×, §, ·, em dashes), so XeLaTeX/LuaLaTeX is required, not pdfLaTeX.
- `python3` + `matplotlib` (for the figure).

## What the build does

1. Regenerates the substrate pipeline figure.
2. Reads the manuscript body from its `Abstract` heading; title metadata comes
   from `meta.yaml`.
3. Runs Pandoc → `rosettabitcoin.tex` (single-column `article`, 11pt, 1in margins).
4. Compiles with `latexmk -xelatex` → `rosettabitcoin.pdf`.
5. Packages `arxiv-rosettabitcoin.tar.gz`.

## Evidence and supplement

- `claim_evidence_matrix.md` maps every numerical/status claim to its evidence.
- `endorsement_response.md` is the concise PR response.
- `supplement/` contains the upload-ready Mojo diagnostic companion source.

The published companion supplement DOI is `10.5281/zenodo.22114337`.

Verify and package the supplement with:

```bash
python3 Docs/paper/supplement/verify.py
python3 Docs/paper/supplement/build.py
```

## Submitting to arXiv

1. Category: `cs.SE` (primary), `cs.MA` (cross-list) is a reasonable fit.
2. Upload `arxiv-rosettabitcoin.tar.gz`. If prompted for a processor, choose **XeLaTeX**.
3. First-time submitters may need an endorsement for the category — see arXiv's
   endorsement policy.
4. The abstract on the arXiv form should match the paper's Abstract section.
