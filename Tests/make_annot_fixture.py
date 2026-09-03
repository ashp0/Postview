#!/usr/bin/env python
"""Write a PDF whose page draws nothing and whose ANNOTATION draws everything.

This is the shape of the bug found on 2026-09-03: CGContextDrawPDFPage renders a
page's content stream and nothing else, so a page carrying its content in
annotations came out blank. `Operating Systems.pdf` (OSTEP) does exactly this on
its cover -- a 30-byte content stream and 33 annotations -- and Postview showed
the reader a blank first page while Preview showed the title.

Minimised here so the regression has a fixture that does not depend on anyone's
Desktop: one 200x200 page, an empty content stream, and one Square annotation
whose /AP /N form paints a 100x100 black square. Exactly 25% of the page is ink
if annotations are drawn and 0% if they are not, so the assertion needs no
tolerance to speak of.

Hand-built because CoreGraphics cannot author an appearance stream.
"""
import sys

def build():
    objs = {
        1: b"<< /Type /Catalog /Pages 2 0 R >>",
        2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3: (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
            b"/Contents 4 0 R /Resources << >> /Annots [5 0 R] >>"),
        5: (b"<< /Type /Annot /Subtype /Square /Rect [50 50 150 150] /F 4 "
            b"/AP << /N 6 0 R >> >>"),
    }
    empty = b"% the page itself draws nothing\n"
    objs[4] = b"<< /Length %d >>\nstream\n" % len(empty) + empty + b"endstream"
    ap = b"0 0 0 rg 0 0 100 100 re f\n"
    objs[6] = (b"<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] "
               b"/Resources << >> /Length %d >>\nstream\n" % len(ap) + ap + b"endstream")

    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for n in sorted(objs):
        offsets[n] = len(out)
        out += b"%d 0 obj\n" % n + objs[n] + b"\nendobj\n"
    start = len(out)
    out += b"xref\n0 %d\n" % (len(objs) + 1)
    out += b"0000000000 65535 f \n"
    for n in sorted(objs):
        out += b"%010d 00000 n \n" % offsets[n]
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objs) + 1, start))
    return bytes(out)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: make_annot_fixture.py <out.pdf>\n")
        sys.exit(2)
    data = build()
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    sys.stdout.write("wrote %s (%d bytes)\n" % (sys.argv[1], len(data)))
