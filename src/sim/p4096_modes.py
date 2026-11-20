#!/usr/bin/env python3
"""Ф2 video modes against src/tools/p4096_vmodel.py: for each case a ROM program (page 2, the reset page) sets the
ports and halts, the RAM is random (pages 4..7, readable attributes in 5 / 7), tb_p4096 dumps a frame, the frame
must equal vm.to_rgb(vm.render()) dot for dot.

    p4096_modes.py OUTDIR TB [CASE...]     (run_p4096_sim.sh modes)
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import p4096_frame as pf      # noqa: E402
import p4096_vmodel as vm     # noqa: E402


def out(port, val):
    return [0x01, port & 0xFF, port >> 8, 0x3E, val & 0xFF, 0xED, 0x79]     # ld bc,port; ld a,val; out (c),a


def rom(ports, palette=None, giga=False):
    """ROM page 2: di, sp, the port writes; palette: #FF37 = 20, after INT each index as the border, then its
    entry (#xxFF, the address high byte carries A8..A15); giga: after INT #7FFD = 08 (screen 7, switched)."""
    code = [0xF3, 0xC3, 0x00, 0x01]                  # di; jp #0100
    img = bytearray([0] * 16384)
    img[0:4] = bytes(code)
    img[0x38] = 0xC9                                # IM 0 / RST 38: ret
    p = [0x31, 0xF0, 0xBF]                          # ld sp,#BFF0 (page 2, not shown)
    for port, val in ports:
        p += out(port, val)
    if palette or giga:
        p += [0xFB, 0x76]                           # ei; halt (INT at line 239: the border until line 0)
    if palette:
        for i, c in enumerate(palette):
            p += out(0x00F6 if i & 8 else 0x00FE, i & 7)
            w = (~c) & 0xFFF                        # the K155RU2 outputs are inverted
            r, g, b = (w >> 8) & 15, (w >> 4) & 15, w & 15
            d = ((b >> 3) & 1) | (((r >> 3) & 1) << 1) | (((g >> 3) & 1) << 4) | (((b >> 2) & 1) << 5) | \
                (((r >> 2) & 1) << 6) | (((g >> 2) & 1) << 7)
            hi = ((b >> 1) & 1) | (((r >> 1) & 1) << 1) | (((g >> 1) & 1) << 4) | ((b & 1) << 5) | \
                ((r & 1) << 6) | ((g & 1) << 7)
            p += out((hi << 8) | 0xFF, d)
        p += out(0x00FE, 0)
    if giga:
        p += out(0x7FFD, 0x08)
    p += [0xF3, 0x76]                               # di; halt
    img[0x100:0x100 + len(p)] = bytes(p)
    return bytes(img)


CASES = {
    #        ports (port, value)                              Regs of the model
    'std':     ([], dict()),
    'scr7':    ([(0x7FFD, 0x08)], dict(scr7=True)),
    'border':  ([(0x00F6, 3)], dict(border=3, border_bri=True)),
    'mx':      ([(0xEFF7, 0x20)], dict(eff7=0x20)),
    '512mono': ([(0xEFF7, 0x02), (0xFE37, 0x0E)], dict(eff7=0x02, fe37=0x0E)),
    '512col':  ([(0xEFF7, 0x02), (0xFE37, 0x10)], dict(eff7=0x02, fe37=0x10)),
    '512mx':   ([(0xEFF7, 0x22), (0xFE37, 0x10)], dict(eff7=0x22, fe37=0x10)),
    '16col':   ([(0xEFF7, 0x01)], dict(eff7=0x01)),
    '384':     ([(0xEFF7, 0x40), (0x00FE, 1)], dict(eff7=0x40, border=1)),
    '384mx':   ([(0xEFF7, 0x60), (0x00FE, 2)], dict(eff7=0x60, border=2)),
    'flashcolor': ([(0xFE37, 0x20)], dict(fe37=0x20)),
    '512fc':   ([(0xEFF7, 0x02), (0xFE37, 0x30)], dict(eff7=0x02, fe37=0x30)),
    'palette': ([(0xFF37, 0x20)], dict()),
    'giga':    ([(0xFE37, 0x40)], dict(fe37=0x40, giga_active=True)),
}


def make_ram(path, seed):
    random.seed(seed)
    ram = bytearray(131072)
    for pg in (4, 5, 6, 7):
        for i in range(16384):
            ram[pg * 16384 + i] = random.getrandbits(8)
    for pg in (5, 7):                                # readable attributes (the demo of the model)
        for i in range(0x1800, 0x1B00):
            ram[pg * 16384 + i] = 0x07 | ((i & 7) << 3) | (0x40 if i & 32 else 0) | (0x80 if i & 64 else 0)
    with open(path, 'w') as f:
        f.write('\n'.join('%02x' % b for b in ram) + '\n')
    return ram


def main():
    outdir, tb = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or list(CASES)
    src = os.path.join(HERE, '..', 'roms')
    ramhex = os.path.join(outdir, 'modes_ram.hex')
    make_ram(ramhex, 7)
    fails = 0
    for name in names:
        ports, kw = CASES[name]
        pal = None
        if name == 'palette':
            random.seed(11)
            pal = [random.getrandbits(12) for _ in range(16)]
        img = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
            rom(ports, pal, name == 'giga') + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
        romhex = os.path.join(outdir, 'modes_rom.hex')
        with open(romhex, 'w') as f:
            f.write('\n'.join('%02x' % b for b in img) + '\n')
        dump = os.path.join(outdir, 'mode_%s.txt' % name)
        # giga: the frame right after the switch (the next INT latches #7FFD D3 again and ends the alternation)
        subprocess.run([tb, '+frames=%d' % (1 if name == 'giga' else 2), '+rom=' + romhex, '+ram=' + ramhex, '+dump=' + dump],
                       check=True, stdout=subprocess.DEVNULL)
        pf.to_png(dump, os.path.join(outdir, 'mode_%s.png' % name))
        if name == 'giga':
            bad = min(pf.compare(dump, ramhex, regs=vm.Regs(frame_odd=o, **kw), quiet=True) for o in (False, True))
        else:
            bad = pf.compare(dump, ramhex, regs=vm.Regs(palette=pal, **kw), quiet=True)
        print('%-11s %s' % (name, 'ok' if bad == 0 else '%d differences' % bad))
        if bad:
            pf.compare(dump, ramhex, regs=vm.Regs(palette=pal, **kw))
            fails += 1
    print('modes: %d of %d differ' % (fails, len(names)))
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
