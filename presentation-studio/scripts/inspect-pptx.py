"""Opens a .pptx with python-pptx and prints its structure. Used to check exports.
Usage: python3 scripts/inspect-pptx.py path/to/deck.pptx"""
import sys
from pptx import Presentation
from pptx.util import Emu

prs = Presentation(sys.argv[1])
print(f"slide size: {Emu(prs.slide_width).inches:.3f} x {Emu(prs.slide_height).inches:.3f} in, slides: {len(prs.slides)}")
for i, slide in enumerate(prs.slides, 1):
    print(f"--- slide {i}")
    for sh in slide.shapes:
        kind = sh.shape_type
        pos = f"x={Emu(sh.left).inches:.2f} y={Emu(sh.top).inches:.2f} w={Emu(sh.width).inches:.2f} h={Emu(sh.height).inches:.2f}"
        if sh.has_text_frame and sh.text_frame.text.strip():
            sizes = {r.font.size.pt for p in sh.text_frame.paragraphs for r in p.runs if r.font.size}
            print(f"  text  {sh.name:<12} {pos} size={sorted(sizes)} :: {sh.text_frame.text[:60]!r}")
        elif kind == 13:
            c = (sh.crop_left, sh.crop_right, sh.crop_top, sh.crop_bottom)
            print(f"  image {pos} crop(l,r,t,b)={tuple(round(v,3) for v in c)} {sh.image.content_type} {sh.image.size}")
        else:
            print(f"  shape {pos}")
    if slide.has_notes_slide and slide.notes_slide.notes_text_frame.text.strip():
        print(f"  notes: {slide.notes_slide.notes_text_frame.text[:70]!r}")
