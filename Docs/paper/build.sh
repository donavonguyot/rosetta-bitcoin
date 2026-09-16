#!/usr/bin/env bash
# Build the paper from its sole Markdown source into a PDF and arXiv bundle.
set -euo pipefail

SRC="Docs/rosettabitcoin_paper_publication.md"
DIR="Docs/paper"
OUT="$DIR/out"
FINAL="output/pdf"

rm -rf "$OUT"
mkdir -p "$OUT" "$FINAL"

echo "[1/6] Generating substrate pipeline figure..."
FIGURE_PYTHON="${FIGURE_PYTHON:-python3}"
if ! "$FIGURE_PYTHON" -c 'import reportlab' >/dev/null 2>&1; then
  BUNDLED_PYTHON="/Users/donavonguyot/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
  if [[ -x "$BUNDLED_PYTHON" ]]; then
    FIGURE_PYTHON="$BUNDLED_PYTHON"
  else
    echo "error: reportlab is required to generate the pipeline figure" >&2
    exit 1
  fi
fi
"$FIGURE_PYTHON" "$DIR/figures/substrate_pipeline.py"
cp "$DIR/figures/substrate_pipeline.pdf" "$OUT/substrate_pipeline.pdf"

echo "[2/6] Preparing Markdown body..."
awk '/^## Abstract$/ { p=1 } p { print }' "$SRC" \
  | sed 's#](paper/figures/substrate_pipeline\.pdf)#](substrate_pipeline.pdf)#g' \
  > "$OUT/body.md"

echo "[3/6] Producing XeLaTeX source..."
(
  cd "$OUT"
  pandoc body.md ../meta.yaml -s \
    --from=markdown+pipe_tables+tex_math_dollars \
    -V documentclass=article -V fontsize=10pt \
    -V geometry:margin=0.82in -V linestretch=1.02 \
    -V colorlinks=true -V linkcolor=RoyalBlue -V urlcolor=RoyalBlue -V citecolor=RoyalBlue \
    -o rosettabitcoin.tex
)

echo "[4/6] Compiling PDF with XeLaTeX..."
(
  cd "$OUT"
  latexmk -pdf -xelatex -interaction=nonstopmode -halt-on-error rosettabitcoin.tex
)

echo "[5/6] Assembling arXiv bundle..."
cp "$OUT/rosettabitcoin.pdf" "$FINAL/rosettabitcoin.pdf"
cp "$DIR/claim_evidence_matrix.md" "$OUT/claim_evidence_matrix.md"
{
  printf '%s\n' 'arXiv bundle for “RosettaBitcoin: An Artifact-Backed Experience Report”.'
  printf '%s\n' 'Main source: rosettabitcoin.tex'
  printf '%s\n' 'Figure: substrate_pipeline.pdf'
  printf '%s\n' 'Compile: latexmk -pdf -xelatex rosettabitcoin.tex'
  printf '%s\n' 'The Markdown manuscript in the repository is the sole editorial source.'
} > "$OUT/00README.txt"
(
  cd "$OUT"
  tar -czf arxiv-rosettabitcoin.tar.gz rosettabitcoin.tex substrate_pipeline.pdf 00README.txt
)

latexmk -c "$OUT/rosettabitcoin.tex" >/dev/null 2>&1 || true
rm -f "$OUT/body.md" "$OUT/rosettabitcoin.xdv"

echo "[6/6] Verifying and packaging the diagnostic supplement..."
python3 "$DIR/supplement/verify.py"
python3 "$DIR/supplement/build.py"

echo "PDF: $FINAL/rosettabitcoin.pdf"
echo "arXiv bundle: $OUT/arxiv-rosettabitcoin.tar.gz"
echo "Supplement: $OUT/rosettabitcoin-mojo-diagnostic-supplement.tar.gz"
