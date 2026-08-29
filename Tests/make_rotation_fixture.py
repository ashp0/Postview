#!/usr/bin/env python3
"""Builds a small PDF whose four pages carry /Rotate 0, 90, 180 and 270.

Rotated pages are everywhere (scans, landscape slides) and the rendering
transform has to swap width/height and orient the content correctly. Each page
is a 400x200 landscape media box with a black square in the PDF-space bottom
left corner, so the test can check both the reported size and where the ink
actually lands after rotation.
"""
import sys

def build():
    objs = {}
    objs[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    kids = " ".join(f"{3+2*i} 0 R" for i in range(4))
    objs[2] = f"<< /Type /Pages /Kids [{kids}] /Count 4 >>".encode()
    for i, rot in enumerate((0, 90, 180, 270)):
        pnum, cnum = 3 + 2*i, 4 + 2*i
        objs[pnum] = (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] "
                      f"/Rotate {rot} /Contents {cnum} 0 R >>").encode()
        # grey field over the whole page + a black square at PDF-space (0,0)
        stream = b"0.75 g 0 0 400 200 re f 0 g 0 0 50 50 re f"
        objs[cnum] = b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream)

    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for num in sorted(objs):
        offsets[num] = len(out)
        out += b"%d 0 obj\n" % num + objs[num] + b"\nendobj\n"

    xref = len(out)
    n = max(objs) + 1
    out += b"xref\n0 %d\n" % n
    out += b"0000000000 65535 f \n"
    for num in range(1, n):
        out += b"%010d 00000 n \n" % offsets[num]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (n, xref)
    return bytes(out)

if __name__ == "__main__":
    open(sys.argv[1], "wb").write(build())
    print(f"wrote {sys.argv[1]}")
