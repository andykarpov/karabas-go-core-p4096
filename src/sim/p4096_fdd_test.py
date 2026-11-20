#!/usr/bin/env python3
"""Ф4 floppy: a ROM program opens the TR-DOS ports (#EFF7 D7), restores the drive A (#FF = 3C, #1F = 08), reads
sector 9 of track 0 (#5F = 9, #1F = 80) of a TRD image into 6000.. (page 5) and writes the status after the read
and the bytes E7, E1 of the sector (the TR-DOS id 10, the first free sector) to 5B00..5B02; tb_p4096 serves the
image as the mcu does. Then the same for track 1 side 1 (TRD track 3) sector 1: its byte 0 to 5B03.

    p4096_fdd_test.py OUTDIR TB [TB_ARGS...]
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def out(port, val):
    return [0x01, port & 0xFF, port >> 8, 0x3E, val & 0xFF, 0xED, 0x79]


def wait_intrq():
    # loop: in a,(#FF); rla; jr nc,loop
    return [0xDB, 0xFF, 0x17, 0x30, 0xFB]


def read_sector(dest):
    # ld hl,dest; loop: in a,(#FF); bit 7 -> done (INTRQ); bit 6 -> in a,(#7F); ld (hl),a; inc hl
    return [0x21, dest & 0xFF, dest >> 8,
            0xDB, 0xFF, 0xCB, 0x7F, 0x20, 0x0A,       # in a,(FF); bit 7,a; jr nz,done (+10)
            0xCB, 0x77, 0x28, 0xF6,                   # bit 6,a; jr z,loop (-10)
            0xDB, 0x7F, 0x77, 0x23, 0x18, 0xF0]       # in a,(7F); ld (hl),a; inc hl; jr loop (-16)


def main():
    outdir, tb = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    img = bytearray(655360)
    info = 8 * 256                                    # track 0, sector 9
    img[info + 0xE1] = 0x01; img[info + 0xE2] = 0x01  # first free sector / track
    img[info + 0xE3] = 0x16                           # disk type: 80 tracks, 2 sides
    img[info + 0xE7] = 0x10                           # TR-DOS id
    img[3 * 4096 + 0] = 0x5A                          # TRD track 3 = track 1 side 1, sector 1
    p = [0xF3, 0x31, 0x00, 0xBE] + out(0xEFF7, 0x80) + out(0x00FF, 0x3C) + out(0x001F, 0x08) + wait_intrq()
    p += out(0x005F, 9) + out(0x001F, 0x80) + read_sector(0x6000)
    p += [0xDB, 0x1F, 0x32, 0x01, 0x5B]               # in a,(1F): status -> 5B01
    p += [0x3A, 0xE7, 0x60, 0x32, 0x00, 0x5B, 0x3A, 0xE1, 0x60, 0x32, 0x02, 0x5B]
    # track 1 (seek: #7F = 1, #1F = 18), side 1 (#FF D4 = 0), sector 1
    p += out(0x007F, 1) + out(0x001F, 0x18) + wait_intrq() + out(0x00FF, 0x2C)
    p += out(0x005F, 1) + out(0x001F, 0x80) + read_sector(0x6100)
    p += [0x3A, 0x00, 0x61, 0x32, 0x03, 0x5B, 0xF3, 0x76]
    rom = bytearray(16384)
    rom[0:len(p)] = bytes(p)
    src = os.path.join(HERE, '..', 'roms')
    full = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
        bytes(rom) + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
    romhex = os.path.join(outdir, 'fdd_rom.hex')
    trdhex = os.path.join(outdir, 'fdd_trd.hex')
    with open(romhex, 'w') as f:
        f.write('\n'.join('%02x' % b for b in full) + '\n')
    with open(trdhex, 'w') as f:
        f.write('\n'.join('%02x' % b for b in img) + '\n')
    dump = os.path.join(outdir, 'fdd_res.txt')
    subprocess.run([tb, '+frames=6', '+rom=' + romhex, '+trd=' + trdhex, '+ramdump5b=' + dump] + extra, check=True,
                   stdout=subprocess.DEVNULL)
    v = [int(x, 16) for x in open(dump).read().split()]
    ok = v[0] == 0x10 and v[2] == 0x01 and (v[1] & 0x1D) == 0 and v[3] == 0x5A
    print('fdd %s: id %02X, status %02X, E1 %02X, T1S1 %02X: %s' % (' '.join(extra) or '3.5 MHz', v[0], v[1], v[2], v[3],
                                                                 'ok' if ok else 'WRONG'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
