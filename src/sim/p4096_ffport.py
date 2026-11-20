#!/usr/bin/env python3
"""The attribute port #FF as BIOS v4.2 tests it (1165): the attributes filled with AA, then IN A,(#FF) 2560 times,
the reads equal to AA counted (to 5B00 / 5B01); a second count in the mode 512x192 (#EFF7 = 02, as BIOS).

    p4096_ffport.py OUTDIR TB [TB_ARGS...]
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def out(port, val):
    return [0x01, port & 0xFF, port >> 8, 0x3E, val & 0xFF, 0xED, 0x79]


def count(dst):
    # ld hl,0: ld bc,0A00 (2560); loop: in a,(FF); cp AA; jr nz,+1; inc hl; dec bc; ld a,b; or c; jr nz,loop; ld (dst),hl
    return [0x21, 0x00, 0x00, 0x01, 0x00, 0x0A,
            0xDB, 0xFF, 0xFE, 0xAA, 0x20, 0x01, 0x23, 0x0B, 0x78, 0xB1, 0x20, 0xF4,
            0x22, dst & 0xFF, dst >> 8]


def main():
    outdir, tb = sys.argv[1], sys.argv[2]
    p = [0xF3, 0x31, 0x00, 0xBE]
    p += [0x21, 0x00, 0x58, 0x11, 0x01, 0x58, 0x01, 0xFF, 0x02, 0x36, 0xAA, 0xED, 0xB0]   # 5800..5AFF = AA
    p += [0x21, 0x00, 0x78, 0x11, 0x01, 0x78, 0x01, 0xFF, 0x02, 0x36, 0xAA, 0xED, 0xB0]   # 7800..7AFF = AA
    p += count(0x5B00) + out(0xEFF7, 0x02) + count(0x5B02) + [0xF3, 0x76]
    rom = bytearray(16384)
    rom[0:len(p)] = bytes(p)
    src = os.path.join(HERE, '..', 'roms')
    full = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
        bytes(rom) + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
    romhex = os.path.join(outdir, 'ff_rom.hex')
    with open(romhex, 'w') as f:
        f.write('\n'.join('%02x' % b for b in full) + '\n')
    dump = os.path.join(outdir, 'ff_res.txt')
    subprocess.run([tb, '+frames=3', '+rom=' + romhex, '+ramdump5b=' + dump] + sys.argv[3:], check=True,
                   stdout=subprocess.DEVNULL)
    v = [int(x, 16) for x in open(dump).read().split()]
    print('ffport %s: std %d, 512 %d of 2560' % (' '.join(sys.argv[3:]) or '3.5 MHz', v[0] | v[1] << 8, v[2] | v[3] << 8))


if __name__ == '__main__':
    main()
