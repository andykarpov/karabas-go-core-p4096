#!/usr/bin/env python3
"""Ф3 memory schemes of #FC37 (docs/HW.md "Страницы памяти"): for each scheme a ROM program writes a signature to
C000 for every combination of the page bits it uses (#7FFD D0-D2 + the extension ports), tb_p4096 dumps the
first two bytes of every physical 16 KB page of the 4 MB, and the physical page of each combination must be the
one of the table of HW.md (the last combination that maps to a page owns its signature). The other windows are
checked too: 4000 = page 5, 8000 = page 2 (their signatures must stay untouched by the C000 writes).

    p4096_mem.py OUTDIR TB [SCHEME...]      (run_p4096_sim.sh mem)
"""
import itertools
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# scheme: #FC37 value (D4 = 0: #7FFD D5 is a memory bit) and the bits used:
#   name -> list of (port, bit) in the order of the page bits they drive per HW.md, the page bit number
SCHEMES = {
    # n: (fc37, [(port, data bit, page bit), ...])
    0: (0x00, []),
    1: (0x01, [(0x7FFD, 6, 3), (0x7FFD, 7, 4), (0x7FFD, 5, 5)]),
    2: (0x02, [(0xDFFD, 0, 3), (0xDFFD, 1, 4), (0xDFFD, 2, 5)]),
    3: (0x03, [(0x1FFD, 4, 3), (0x1FFD, 7, 4)]),
    4: (0x07, [(0x1FFD, 4, 3), (0x1FFD, 7, 4), (0x7FFD, 7, 5), (0x7FFD, 6, 6), (0x7FFD, 5, 7)]),
    5: (0x0A, [(0xDFFD, 0, 3), (0xDFFD, 1, 4), (0xDFFD, 2, 5), (0x7FFD, 6, 6), (0x7FFD, 7, 7)]),
    6: (0x0E, [(0xDFFD, 0, 3), (0xDFFD, 1, 4), (0xDFFD, 2, 5), (0x1FFD, 4, 6), (0x1FFD, 7, 7)]),
}


def out(port, val):
    return [0x01, port & 0xFF, port >> 8, 0x3E, val & 0xFF, 0xED, 0x79]


def program(bits):
    combos = list(itertools.product((0, 1), repeat=len(bits)))
    p = [0xF3, 0x31, 0x00, 0x80,                    # di; ld sp,#8000 (not used)
         0x21, 0x55, 0x5A, 0x22, 0x00, 0x40,        # ld hl,#5A55: ld (#4000),hl  (page 5)
         0x21, 0x22, 0x2A, 0x22, 0x00, 0x80]        # ld hl,#2A22: ld (#8000),hl  (page 2)
    sig = []
    for n, hb in enumerate(combos):
        for lo in range(8):
            v = {0x7FFD: lo, 0xDFFD: 0, 0x1FFD: 0}
            for (port, dbit, _), b in zip(bits, hb):
                if b:
                    v[port] |= 1 << dbit
            p += out(0x1FFD, v[0x1FFD]) + out(0xDFFD, v[0xDFFD]) + out(0x7FFD, v[0x7FFD])
            idx = n * 8 + lo + 1
            p += [0x21, idx & 0xFF, 0xA0 | (idx >> 8), 0x22, 0x00, 0xC0]   # ld hl,sig: ld (#C000),hl
            page = lo
            for (_, _, pbit), b in zip(bits, hb):
                page |= b << pbit
            sig.append((page, idx))
    p += out(0x7FFD, 0) + [0xF3, 0x76]
    img = bytearray(16384)
    img[0:len(p)] = bytes(p)
    assert len(p) < 16384, len(p)
    return bytes(img), sig


def trap_program():
    """Scheme 1 (#7FFD D6 = page bit 3). #7FFD = 40 (page 8); from the RAM (8000): ld a,1; out (#FD),a -> the
    trap: port 01FD is #7FFD (soft decode), D6 (hard) stays: page 9; ld hl,#1234; ld (#C000),hl; then from the ROM
    again #7FFD = 41 the normal way and a second signature to see the hard decode works (page 9 again: 5678)."""
    ram = [0x3E, 0x01, 0xD3, 0xFD, 0x21, 0x34, 0x12, 0x22, 0x00, 0xC0, 0xC3, 0x40, 0x01]   # ... jp #0140
    p = [0xF3, 0x31, 0x00, 0x80] + out(0x7FFD, 0x40)
    p += [0x21, 0x00, 0x02, 0x11, 0x00, 0x80, 0x01, len(ram), 0x00, 0xED, 0xB0, 0xC3, 0x00, 0x80]  # ldir; jp #8000
    img = bytearray(16384)
    img[0:len(p)] = bytes(p)
    img[0x200:0x200 + len(ram)] = bytes(ram)
    q = out(0x7FFD, 0x42) + [0x21, 0x78, 0x56, 0x22, 0x00, 0xC0, 0xF3, 0x76]   # page 10: 5678
    img[0x140:0x140 + len(q)] = bytes(q)
    return bytes(img)


def static_program():
    """HLOAD (#FC37 = 20): static RAM pages 0..3 at C000 (#7FFD D1 D0) get 2 bytes each (d*16+1, d*16+2) at FFFE;
    then #FC37 = 00, #FF37 = 03, #FD37 = 0F (pages 0-3 of the ROM from the static RAM), #7FFD = 10 (BASIC 48 =
    page 3): ld hl,(3FFE) -> 5B00 (page 5); #7FFD = 00 (Menu-128 = page 2): -> 5B02. Expect 3132 and 2122."""
    p = [0xF3, 0x31, 0x00, 0xBE] + out(0xFC37, 0x20)
    for d in range(4):
        p += out(0x7FFD, d) + [0x21, d * 16 + 1, d * 16 + 2, 0x22, 0xFE, 0xFF]   # ld hl,..: ld (FFFE),hl
    p += out(0xFC37, 0x00) + out(0xFF37, 0x03) + out(0xFD37, 0x0F)
    p += out(0x7FFD, 0x10) + [0x2A, 0xFE, 0x3F, 0x22, 0x00, 0x5B]                # ld hl,(3FFE): ld (5B00),hl
    p += out(0x7FFD, 0x00) + [0x2A, 0xFE, 0x3F, 0x22, 0x02, 0x5B]
    p += [0xF3, 0x76]
    # the code runs from the ROM page 2 until #FD37 maps page 2 to the static RAM: run it from the RAM (8000)
    loader = [0xF3, 0x21, 0x00, 0x02, 0x11, 0x00, 0x80, 0x01, len(p), 0x00, 0xED, 0xB0, 0xC3, 0x00, 0x80]
    img = bytearray(16384)
    img[0:len(loader)] = bytes(loader)
    img[0x200:0x200 + len(p)] = bytes(p)
    return bytes(img)


def main():
    outdir, tb = sys.argv[1], sys.argv[2]
    names = [int(x) for x in sys.argv[3:]] or sorted(SCHEMES)
    src = os.path.join(HERE, '..', 'roms')
    fails = 0
    for n in names:
        fc37, bits = SCHEMES[n]
        img, sig = program(bits)
        romimg = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
            img + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
        romhex = os.path.join(outdir, 'mem_rom.hex')
        with open(romhex, 'w') as f:
            f.write('\n'.join('%02x' % b for b in romimg) + '\n')
        dump = os.path.join(outdir, 'mem_%d.txt' % n)
        frames = 2 + len(sig) // 600
        subprocess.run([tb, '+frames=%d' % frames, '+rom=' + romhex, '+fc37=%02x' % fc37, '+pagedump=' + dump],
                       check=True, stdout=subprocess.DEVNULL)
        got = [int(x[2:4] + x[0:2], 16) for x in open(dump).read().split()]
        want = [0] * 256
        for page, idx in sig:
            want[page] = idx | 0xA000 if idx < 256 else (idx & 0xFF) | ((0xA0 | (idx >> 8)) << 8)
        for page, idx in sig:
            want[page] = (idx & 0xFF) | ((0xA0 | (idx >> 8)) << 8)
        # 4000 / 8000 writes went to pages 5 / 2 first; C000 writes to those pages come later and overwrite
        for pg, v in ((5, 0x5A55), (2, 0x2A22)):
            if not any(page == pg for page, _ in sig):
                want[pg] = v
        bad = [(p, got[p], want[p]) for p in range(256) if got[p] != want[p]]
        print('scheme %d (#FC37 %02X, %d combinations): %s' % (n, fc37, len(sig),
              'ok' if not bad else '%d pages differ, first %s' % (len(bad), ['%d: %04x want %04x' % b for b in bad[:4]])))
        fails += bool(bad)
    if not sys.argv[3:]:
        romimg = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
            trap_program() + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
        romhex = os.path.join(outdir, 'mem_rom.hex')
        with open(romhex, 'w') as f:
            f.write('\n'.join('%02x' % b for b in romimg) + '\n')
        dump = os.path.join(outdir, 'mem_trap.txt')
        subprocess.run([tb, '+frames=1', '+rom=' + romhex, '+fc37=01', '+pagedump=' + dump], check=True,
                       stdout=subprocess.DEVNULL)
        got = [int(x[2:4] + x[0:2], 16) for x in open(dump).read().split()]
        ok = got[9] == 0x1234 and got[10] == 0x5678 and got[1] != 0x1234 and got[8] != 0x1234
        print('trap (OUT (#FD),A from the RAM, scheme 1): %s (page 1 %04x, 8 %04x, 9 %04x, 10 %04x)' %
              ('ok' if ok else 'WRONG', got[1], got[8], got[9], got[10]))
        fails += not ok
    if not sys.argv[3:]:
        romimg = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
            static_program() + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
        romhex = os.path.join(outdir, 'mem_rom.hex')
        with open(romhex, 'w') as f:
            f.write('\n'.join('%02x' % b for b in romimg) + '\n')
        for t in ('0', '1', '2'):
            dump = os.path.join(outdir, 'mem_static.txt')
            subprocess.run([tb, '+frames=1', '+rom=' + romhex, '+turbo=' + t, '+romlat=16', '+ramdump5b=' + dump], check=True,
                           stdout=subprocess.DEVNULL)
            v = [int(x, 16) for x in open(dump).read().split()]
            ok = v == [0x31, 0x32, 0x21, 0x22]
            print('static RAM (HLOAD write, #FD37 read) turbo %s: %s %s' % (t, 'ok' if ok else 'WRONG', v))
            fails += not ok
    print('mem: %d failed' % fails)
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
