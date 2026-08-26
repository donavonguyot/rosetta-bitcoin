#!/usr/bin/env python3
"""Generate the evidence-pipeline figure as a vector PDF."""

from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.pdfgen import canvas

OUT = Path(__file__).resolve().parent / "substrate_pipeline.pdf"
WIDTH, HEIGHT = 760, 154
labels = [
    ("Raw blocks", "and failures"),
    ("Blocker facts", ""),
    ("Fixtures and", "rule cards"),
    ("Port-owned", "proofs"),
    ("Validators", "and imports"),
    ("Project reports", ""),
]
fills = ["#E8EEF7", "#EAF4EA", "#FFF3D6", "#F4E9F7", "#E6F3F5", "#E8EEF7"]


def main() -> None:
    pdf = canvas.Canvas(str(OUT), pagesize=(WIDTH, HEIGHT), pageCompression=1)
    edge = HexColor("#34495E")
    box_width, box_height, gap = 106, 58, 18
    left, bottom = 18, 62

    for index, (lines, fill) in enumerate(zip(labels, fills)):
        x = left + index * (box_width + gap)
        pdf.setFillColor(HexColor(fill))
        pdf.setStrokeColor(edge)
        pdf.setLineWidth(1.1)
        pdf.roundRect(x, bottom, box_width, box_height, 6, stroke=1, fill=1)
        pdf.setFillColor(edge)
        pdf.setFont("Helvetica", 9.4)
        if lines[1]:
            pdf.drawCentredString(x + box_width / 2, bottom + 33, lines[0])
            pdf.drawCentredString(x + box_width / 2, bottom + 20, lines[1])
        else:
            pdf.drawCentredString(x + box_width / 2, bottom + 26, lines[0])
        if index < len(labels) - 1:
            start = x + box_width + 3
            end = x + box_width + gap - 3
            y = bottom + box_height / 2
            pdf.setStrokeColor(edge)
            pdf.setFillColor(edge)
            pdf.line(start, y, end, y)
            pdf.line(end, y, end - 5, y + 3)
            pdf.line(end, y, end - 5, y - 3)

    pdf.setFillColor(edge)
    pdf.setFont("Helvetica-Oblique", 8.5)
    pdf.drawCentredString(
        WIDTH / 2,
        29,
        "Each transition preserves provenance; only validated imports become reported claims.",
    )
    pdf.showPage()
    pdf.save()


if __name__ == "__main__":
    main()

