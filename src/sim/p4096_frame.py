#!/usr/bin/env python3
"""Helpers of run_p4096_sim.sh.

    p4096_frame.py hex IN OUT [SIZE]        binary -> one hex byte a line ($readmemh), padded with FF to SIZE
    p4096_frame.py ram OUT SEED             a RAM of 128 KB: random pages 5 / 7 (readable attributes), else 0
    p4096_frame.py png DUMP OUT             a dump of tb_p4096 (304 lines x 768 dots) -> PNG (lines doubled)
    p4096_frame.py cmp DUMP RAMHEX [scr7]   the dump against p4096_vmodel.render() of the same RAM (border 0,
                                            FLASH off): exit 1 on any difference
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))


def to_hex(src, dst, size=None):
    data = open(src, 'rb').read()
    if size:
        data = data + b'\xff' * (size - len(data))
    with open(dst, 'w') as f:
        f.write('\n'.join('%02x' % b for b in data) + '\n')


def make_ram(dst, seed):
    import random
    random.seed(seed)
    ram = bytearray(131072)
    for p in (5, 7):
        base = p * 16384
        for i in range(0x1800):
            ram[base + i] = random.getrandbits(8)
        for i in range(0x1800, 0x1B00):
            # no FLASH bit: the frame of the test is in the first half of the FLASH period anyway
            ram[base + i] = random.getrandbits(7)
    with open(dst, 'w') as f:
        f.write('\n'.join('%02x' % b for b in ram) + '\n')


def read_dump(path):
    vals = [int(x, 16) for x in open(path).read().split()]
    assert len(vals) == 304 * 768, len(vals)
    return [vals[y * 768:(y + 1) * 768] for y in range(304)]


def to_png(dump, out):
    from PIL import Image
    rows = read_dump(dump)
    im = Image.new('RGB', (768, 608))
    for y, row in enumerate(rows):
        for x, v in enumerate(row):
            c = (((v >> 8) & 15) * 17, ((v >> 4) & 15) * 17, (v & 15) * 17)
            im.putpixel((x, 2 * y), c)
            im.putpixel((x, 2 * y + 1), c)
    im.save(out)


def compare(dump, ramhex, scr7=False):
    import p4096_vmodel as vm
    ram = bytes(int(x, 16) for x in open(ramhex).read().split())
    pages = {p: bytearray(ram[p * 16384:(p + 1) * 16384]) for p in range(8)}
    regs = vm.Regs(scr7=scr7)
    pal = vm.std_palette()
    model = vm.render(pages, regs)
    rows = read_dump(dump)
    bad = 0
    for y in range(304):
        for x in range(768):
            want = model[y][x]
            want = 0 if want == -1 else pal[want]
            if rows[y][x] != want:
                if bad < 10:
                    print('diff line %d dot %d: rtl %03x model %03x' % (y, x, rows[y][x], want))
                bad += 1
    print('cmp: %d differences' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    a = sys.argv
    if len(a) >= 4 and a[1] == 'hex':
        to_hex(a[2], a[3], int(a[4]) if len(a) > 4 else None)
    elif len(a) == 4 and a[1] == 'ram':
        make_ram(a[2], int(a[3]))
    elif len(a) == 4 and a[1] == 'png':
        to_png(a[2], a[3])
    elif len(a) >= 4 and a[1] == 'cmp':
        sys.exit(compare(a[2], a[3], len(a) > 4 and a[4] == 'scr7'))
    else:
        print(__doc__)
        sys.exit(2)
