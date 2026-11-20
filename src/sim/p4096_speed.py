#!/usr/bin/env python3
"""CPU speed as BIOS v4.2 measures it (11A2: IM 2, HALT, then "ei; inc de; jp" counted until the next INT): the
loop once from the ROM (page 2, the reset page) and once from the RAM (8000), the counts are written to 5B00 / 5B02
(page 5) and read from the page dump of tb_p4096. Speed % = count * 2 / 89 (BIOS 0F95), 100 % = 4480 at 3.5 MHz.

    p4096_speed.py OUTDIR TB [TB_ARGS...]
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def measure(base):
    """Code at base: IM 2 (I = 7E, the vector 7F7F: inc de loop exit through jp (hl)), count DE between INTs,
    store it to the address in IX. Returns the bytes (position independent except the absolute jumps)."""
    c = [0xF3, 0x3E, 0x7E, 0xED, 0x47, 0xED, 0x5E,       # di; ld a,7E; ld i,a; im 2
         0x21, 0, 0, 0x11, 0, 0, 0xFB, 0x76]             # ld hl,first; ld de,0; ei; halt
    first = base + len(c)
    c[8], c[9] = first & 0xFF, first >> 8
    # the first INT returns to "first" through the handler (pop af: drop the return address, jp (hl))
    c += [0x21, 0, 0, 0x00, 0xFB]                        # first: ld hl,done; nop; ei
    loop = base + len(c)
    c += [0x13, 0xC3, loop & 0xFF, loop >> 8]           # loop: inc de; jp loop
    done = base + len(c)
    c[len(c) - 9 - 0 + 0] = c[len(c) - 9]               # (no-op, keep the layout readable)
    c[first - base + 1], c[first - base + 2] = done & 0xFF, done >> 8
    c += [0xF3, 0xDD, 0x73, 0x00, 0xDD, 0x72, 0x01,      # done: di; ld (ix+0),e; ld (ix+1),d
          0xED, 0x56, 0xC9]                              # im 1; ret (the return address of the caller)
    return c


def main():
    outdir, tb = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    ram_code = measure(0x8000)
    rom_code = measure(0x0200)
    p = [0xF3, 0x31, 0x00, 0xBE]                         # di; ld sp,BE00 (page 2)
    # the handler at 7F7F: pop af (the return address); jp (hl)
    p += [0x21, 0x7F, 0x7F, 0x36, 0xF1, 0x23, 0x36, 0xE9]  # ld hl,7F7F; ld (hl),F1; inc hl; ld (hl),E9
    p += [0x21, 0x00, 0x7E, 0x11, 0x01, 0x7E, 0x01, 0x00, 0x01, 0x36, 0x7F, 0xED, 0xB0]   # table 7E00..7F00 = 7F
    p += [0x21, 0x00, 0x03, 0x11, 0x00, 0x80, 0x01, len(ram_code), 0x00, 0xED, 0xB0]     # copy the RAM loop
    p += [0xDD, 0x21, 0x00, 0x5B, 0xCD, 0x00, 0x02]      # ld ix,5B00; call 0200 (ROM)
    p += [0xDD, 0x21, 0x02, 0x5B, 0xCD, 0x00, 0x80]      # ld ix,5B02; call 8000 (RAM)
    p += [0xF3, 0x76]
    img = bytearray(16384)
    img[0:len(p)] = bytes(p)
    img[0x200:0x200 + len(rom_code)] = bytes(rom_code)
    img[0x300:0x300 + len(ram_code)] = bytes(ram_code)
    src = os.path.join(HERE, '..', 'roms')
    rom = open(os.path.join(src, 'glukpen.rom'), 'rb').read() + open(os.path.join(src, 'tr5_03.rom'), 'rb').read() + \
        bytes(img) + open(os.path.join(src, 'basic48_128_std.rom'), 'rb').read()
    romhex = os.path.join(outdir, 'speed_rom.hex')
    with open(romhex, 'w') as f:
        f.write('\n'.join('%02x' % b for b in rom) + '\n')
    dump = os.path.join(outdir, 'speed_ram.txt')
    subprocess.run([tb, '+frames=4', '+rom=' + romhex, '+ramdump5b=' + dump] + extra, check=True,
                   stdout=subprocess.DEVNULL)
    v = [int(x, 16) for x in open(dump).read().split()]
    rom_n, ram_n = v[0] | (v[1] << 8), v[2] | (v[3] << 8)
    print('speed %s: ROM %d (%d %%), RAM %d (%d %%)' % (' '.join(extra) or '3.5 MHz', rom_n, rom_n * 2 // 89,
                                                        ram_n, ram_n * 2 // 89))


if __name__ == '__main__':
    main()
