#!/usr/bin/env python3
"""Reference model of the Pentagon-4096 picture (Ф0): what one frame shows for given memory and registers.

Built from the README / video_modes.txt of AleksandrDneprCity/Pentagon-4096 (434fff9) and checked against the
schematic reading in docs/HW.md (address multiplexers DD39-DD46, DD104-DD110, colour path DD119 / DD120,
palette on the TopBoard). Open points are marked CHECK and listed in docs/QUESTIONS.md.

The model works on the pixel level of the 14 MHz clock: one row is 2 * 384 = 768 sub-pixels (a 7 MHz pixel is
two of them, a 512 mode pixel one), the frame is 384 x 304 visible pixels (the 384x304 mode shows all of it,
the other modes put the 256 x 192 paper at (64, 64) with the border around, CHECK the top border height).

Memory: a dict {page number (16 KB, 0..255): bytearray(16384)}, missing pages read 0.

    python3 -I p4096_vmodel.py demo OUTDIR     renders every mode of a synthetic memory to PNG (needs PIL)
"""
import sys

PAPER_X, PAPER_Y = 64, 64          # paper origin inside the 384 x 304 window (CHECK top: 64 or 56 lines)
W7, H = 384, 304                   # window in 7 MHz pixels / lines


def zx_pix_addr(y, col):
    """ZX screen offset of the pixel byte of line y (0..191), column col (0..31)."""
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | col


def zx_attr_addr(y, col):
    return 0x1800 | ((y >> 3) << 5) | col


class Regs:
    """Register state seen by the picture."""
    def __init__(self, eff7=0, fe37=0, scr7=False, border=0, border_bri=False, palette=None, flash=False,
                 giga_active=False, frame_odd=False, mtask_block=0, palette_on=True):
        self.eff7 = eff7          # #EFF7: D0 16col, D1 512, D5 multicolor, D6 384x304
        self.fe37 = fe37          # #FE37: D0-2 ink B R G, D3 ink bright, D4 512 colour, D5 FlashColor, D6 giga
        self.scr7 = scr7          # #7FFD D3
        self.border = border      # #FE D0-2 (B R G)
        self.border_bri = border_bri  # last border write went to #F6 (A3 = 0)
        self.palette = palette    # 16 entries of 12 bit RGB (R in bits 11-8); None = standard 16 colours
        self.flash = flash        # FLASH phase (frame counter bit)
        self.giga_active = giga_active  # program switched #7FFD D3 since the frame latch (with fe37 D6)
        self.frame_odd = frame_odd      # 2FRM
        self.mtask_block = mtask_block  # SCR256K..SCR4M: block of 128 KB of the screen (multitasking), else 0
        self.palette_on = palette_on

    m16 = property(lambda s: bool(s.eff7 & 0x01))
    m512 = property(lambda s: bool(s.eff7 & 0x02))
    mmx = property(lambda s: bool(s.eff7 & 0x20))
    m384 = property(lambda s: bool(s.eff7 & 0x40))
    col512 = property(lambda s: bool(s.fe37 & 0x10))
    flashcolor = property(lambda s: bool(s.fe37 & 0x20) and not s.m16)
    giga = property(lambda s: bool(s.fe37 & 0x40))


def std_palette():
    """Index (bit 0 B, 1 R, 2 G, 3 bright) -> 12 bit RGB; levels CHECK against the BIOS v4.2 init."""
    pal = []
    for i in range(16):
        lv = 0xF if i & 8 else 0xC
        b, r, g = (i & 1) * lv, ((i >> 1) & 1) * lv, ((i >> 2) & 1) * lv
        pal.append((r << 8) | (g << 4) | b)
    return pal


def rgb(pal_entry):
    r, g, b = (pal_entry >> 8) & 15, (pal_entry >> 4) & 15, pal_entry & 15
    return (r * 17, g * 17, b * 17)


def attr_index(attr, ink):
    """Palette index of an attribute byte: INK bits 0-2 + bright 6, PAPER bits 3-5 + bright 6."""
    bri = 8 if attr & 0x40 else 0
    return (attr & 7) | bri if ink else ((attr >> 3) & 7) | bri


class Mem:
    def __init__(self, pages, regs):
        self.pages, self.r = pages, regs

    def rd(self, page, off):
        p = self.pages.get(page)
        return p[off & 0x3FFF] if p is not None else 0

    def screen_page(self, line):
        """Page bits 1..7 of the video address: GGSCR (screen 5 / 7, GigaScreen) and the 128 KB block."""
        ggscr = self.r.scr7
        if self.r.giga and self.r.giga_active:
            ggscr = bool(self.r.frame_odd) ^ bool(line & 1)   # DD113:1: 2FRM xor V0 (CHECK V0 = this line bit)
        return (self.r.mtask_block << 3) | 4 | (2 if ggscr else 0)   # bit 2 always 1: pages 4-7 of the block

    def main(self, line, a13, off):
        """A byte of the screen page (bit 0 of the page = 1: page 5 / 7) at A13 = a13."""
        return self.rd(self.screen_page(line) | 1, (a13 << 13) | off)

    def alt(self, line, a13, off):
        """A byte of 'page 4' (bit 0 of the page = 0: page 4 / 6 of the block, CHECK page 6 with screen 7)."""
        return self.rd(self.screen_page(line), (a13 << 13) | off)


def render(pages, regs):
    """Returns rows of 768 palette indices (14 MHz sub-pixels) for the 384 x 304 window; -1 = blank."""
    m = Mem(pages, regs)
    border = (regs.border & 7) | (8 if regs.border_bri else 0)
    rows = []
    for wy in range(H):
        row = [border] * (2 * W7)
        y = wy - PAPER_Y
        for col in range(32):
            if 0 <= y < 192:
                out = char_row(m, regs, wy, y, col)
                x0 = 2 * (PAPER_X + 8 * col)
                row[x0:x0 + 16] = out
        if regs.m384:
            fill_384(m, regs, wy, row)
        rows.append(row)
    return rows


def char_row(m, r, line, y, col):
    """16 sub-pixel indices of one character cell of the paper."""
    pa = zx_pix_addr(y, col)
    if r.m16:
        # 4 fetches {"3","2"} = 00 p4 C000(+0), 01 p5 4000, 10 p4 E000, 11 p5 6000 (DD106 / DD107 with "2", "3");
        # the latch takes the bus every 2 pixels, INK half first (CHECK the order, docs/QUESTIONS.md 7)
        bytes4 = [m.alt(line, 0, pa), m.main(line, 0, pa), m.alt(line, 1, pa), m.main(line, 1, pa)]
        out = []
        for b in bytes4:
            ink = (b & 7) | (8 if b & 0x40 else 0)
            paper = ((b >> 3) & 7) | (8 if b & 0x80 else 0)     # AO7 is the bright of the PAPER half
            out += [ink, ink, paper, paper]
        return out
    if r.m512:
        # two characters of 8 pixels at 14 MHz: odd one (left, CHECK) from A13 = 0, even one from A13 = 1
        out = []
        for a13 in (0, 1):
            pix = m.main(line, a13, pa)
            if not r.col512:
                ink = (r.fe37 & 7) | (8 if r.fe37 & 8 else 0)   # 512_B / R / G -> AO0-2, 512_I -> AO6
                for bit in range(8):
                    out.append(ink if pix & (0x80 >> bit) else 0)
                continue
            if r.mmx:
                attr = m.alt(line, a13, pa)           # attributes 8x1 in page 4 C000 / E000
            else:
                attr = m.main(line, a13, zx_attr_addr(y, col))   # 5800 / 7800
            for bit in range(8):
                out.append(pixel_index(r, attr, bool(pix & (0x80 >> bit))))
        return out                                    # 16 sub-pixels
    pix = m.main(line, 0, pa)
    attr = m.main(line, 1, pa) if r.mmx else m.main(line, 0, zx_attr_addr(y, col))
    out = []
    for bit in range(8):
        idx = pixel_index(r, attr, bool(pix & (0x80 >> bit)))
        out += [idx, idx]
    return out


def pixel_index(r, attr, pix):
    """Index of one pixel, or ('mix', INK, PAPER) for an INK point of a FlashColor cell (docs/HW.md)."""
    if r.flashcolor and attr & 0x80:
        if not pix:
            return 0                                          # PAPER points black (FBLANK)
        return ('mix', attr_index(attr, True), attr_index(attr, False))
    if attr & 0x80 and r.flash:
        pix = not pix
    return attr_index(attr, pix)


def fill_384(m, r, wy, row):
    """Border area of the 384x304 mode (video_modes.txt, final variant; CHECK corners and line origin)."""
    y = wy - PAPER_Y
    for c7 in range(48):
        x7 = 8 * c7
        in_paper_x = PAPER_X <= x7 < PAPER_X + 256
        if 0 <= y < 192 and in_paper_x:
            continue
        if 0 <= y < 192:
            # side columns: H5 = 1 -> A13 = 1 (6000 / 7800), right columns H = 40..47 -> low byte 08..0F,
            # left H = 56..63 -> 18..1F
            hcol = 0x08 + (c7 - 40) if c7 >= 40 else 0x18 + c7
            pix = m.main(wy, 1, zx_pix_addr(y, 0) | hcol)
            attr = m.main(wy, 1, zx_attr_addr(y, 0) | hcol)
        else:
            # top / bottom: page 4 (384_A1 = 0), pixels C000.. / C800.., attributes D800 / D900 (CHECK)
            if not in_paper_x:
                continue                                   # corners: not described (docs/QUESTIONS.md 5)
            col = (x7 - PAPER_X) // 8
            if y < 0:
                ly = wy                                    # top lines 0..63
                pix = m.alt(wy, 0, zx_pix_addr(ly, col) & 0x07FF)
                attr = m.alt(wy, 0, 0x1800 | ((ly >> 3) << 5) | col)
            else:
                ly = y - 192                               # bottom lines 0..47
                pix = m.alt(wy, 0, 0x0800 | (zx_pix_addr(ly, col) & 0x07FF))
                attr = m.alt(wy, 0, 0x1900 | ((ly >> 3) << 5) | col)
        for bit in range(8):
            idx = pixel_index(r, attr, bool(pix & (0x80 >> bit)))
            row[2 * (x7 + bit):2 * (x7 + bit) + 2] = [idx, idx]


def to_rgb(rows, regs):
    """Indices -> RGB; a FlashColor point = 1/4 INK + 3/4 PAPER (gate duty of /F14 | F7, CHECK)."""
    pal = regs.palette if (regs.palette and regs.palette_on) else std_palette()
    res = []
    for row in rows:
        line = []
        for v in row:
            if isinstance(v, tuple):
                ink, paper = rgb(pal[v[1]]), rgb(pal[v[2]])
                line.append(tuple((a + 3 * b) // 4 for a, b in zip(ink, paper)))
            else:
                line.append(rgb(pal[v]))
        res.append(line)
    return res


def save_png(rows_rgb, path):
    from PIL import Image
    h, w = len(rows_rgb), len(rows_rgb[0])
    im = Image.new('RGB', (w, h * 2))
    for y, row in enumerate(rows_rgb):
        for x, c in enumerate(row):
            im.putpixel((x, 2 * y), c)
            im.putpixel((x, 2 * y + 1), c)
    im.save(path)


def demo(outdir):
    import os, random
    random.seed(1)
    pages = {p: bytearray(random.getrandbits(8) for _ in range(16384)) for p in (4, 5, 6, 7)}
    for p in (5, 7):                                   # readable attributes in the standard area
        for i in range(0x1800, 0x1B00):
            pages[p][i] = 0x07 | ((i & 7) << 3) | (0x40 if i & 32 else 0) | (0x80 if i & 64 else 0)
    modes = {'std': Regs(), 'mx': Regs(eff7=0x20), '512mono': Regs(eff7=0x02, fe37=0x0E),
             '512col': Regs(eff7=0x02, fe37=0x10), '512mx': Regs(eff7=0x22, fe37=0x10),
             '16col': Regs(eff7=0x01), '384': Regs(eff7=0x40, border=1), 'flashcolor': Regs(fe37=0x20),
             'giga': Regs(fe37=0x40, giga_active=True)}
    os.makedirs(outdir, exist_ok=True)
    for name, r in modes.items():
        save_png(to_rgb(render(pages, r), r), os.path.join(outdir, name + '.png'))
        print(name)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'demo':
        demo(sys.argv[2])
    else:
        print(__doc__)
