# Pentagon-4096 core for Karabas Go / Mini / Mini G

[Русская версия](README.ru.md)

The Pentagon-4096 for the Karabas Go board family (Xilinx Spartan-6 XC6SLX25). The original is the board of [AleksandrDneprCity/Pentagon-4096](https://github.com/AleksandrDneprCity/Pentagon-4096) (MainBoard 10.7.1, TopBoard 5.3.1): discrete logic without HDL, so this core is written from its README and its schematic. The reading of the schematic (ports, memory pages, video modes, palette, raster, INT, the BIOS v4.2) is in [docs/HW.md](docs/HW.md) (Russian).

| Board | Core file | Video | Sound |
|---|---|---|---|
| Karabas Go | `p4096.kg` | VGA | I2S DAC (PCM5102) |
| Karabas Mini | `p4096.kg` | HDMI | HDMI, analog output (sigma-delta) |
| Karabas Mini G | `p4096.kg` | HDMI | HDMI, I2S DAC |

The core file is in `src/`. The ROMs are in it (`core.json` "roms", loaded by the firmware): Gluk Reset Service, TR-DOS 5.03, the 128K menu and BASIC 48, the +3 ROM 4.1, the BIOS v4.2 of the Pentagon-4096 and the GS ROM 1.05b.

Status: build 26112020. Mini G: the machine, all video modes, the memory schemes, the BIOS v4.2 tests, TR-DOS from images, the CF card, the GS, the OPL4 and the MIDI were checked on a board. The Go and Mini builds have not been run on a board.

## Features

- **Machine:** Z80 (z80-silicon) at 3.5 / 7 / 14 MHz, the raster and INT of the Pentagon (or of the "firm" variant, with the XJ3 jumper), the Turbo 14 wait states of the original (WAITP) or none.
- **Memory:** 4 MB of RAM, the seven extension schemes of port FC37 (128K, Pentagon 1M, Profi 1M, 1FFD 512K, KAY 4M, Profi + Pentagon, Profi + 1FFD), the D5 lock of 7FFD, the +3 mode, the static RAM over the ROM pages, the cache FB / 7B, the multitask mode (the hardware part), the IN / OUT trap.
- **Video:** the standard screen, 16 colors, 512 x 192 (mono or colour), multicolour 8 x 1, 384 x 304, FlashColor, GigaScreen, the palette of 16 of 4096 colours; line-doubled to 720 x 576 (or 768 x 608 with the whole border) at 48.8 Hz.
- **BIOS:** the BIOS v4.2 runs (Boot = BIOS) with its RAM test and Setup; without it the OSD sets what Setup sets (the reset values of the BIOS ports FC37..FF37).
- **Disks:** the VG93 with four TRD images (A..D) on SD1; Nemo IDE on the CF card of the board or on HDF images on SD1 (Master, Slave).
- **Sound:** TurboSound (two AY), the beeper and the tape, SoundDrive / Covox, **General Sound** (ports BB / B3, 2 MB), **OPL4** (ZXM-MoonSound: FM and the wavetable with the YRW801 ROM, ports C4..C7 and 7E / 7F), the MIDI synth of the board on the AY port A (`PLAY "Y1..."` of the 128K BASIC); on the Mini / Mini G its sound and the line in come back through the ADC into the mix.
- **Clock:** the RTC of the board as the MC146818 CMOS of the Gluk (ports EFF7 / DFF7 / BFF7).
- **Controllers:** the USB keyboard, two joysticks (Kempston, Sinclair 1 / 2, Cursor, QAOP), the Kempston mouse.

Not done: RS-232 and the ESP8266, DivMMC / DivIDE, the printer, the writing of the flash ROM back to the SD card (the copy in the SDRAM lives until power off), the task menu of the multitask mode.

## Getting started

1. Copy `p4096.kg` (one file for Go, Mini and Mini G) to the root of the SD card of the firmware.
2. Make a folder `/p4096` on the SD card for the disk images (`.trd`, `.hdf`).
3. The OPL4 ROM `yrw801.rom` (2 MB, not included): `/p4096/yrw801.rom`; the core also takes it from `/baseconf` or `/tsconf`.
4. Choose Pentagon-4096 in the core menu: the Gluk Reset Service starts. Mount a TRD image with **Menu+F5** (Disk A).

"Menu" is the Windows key of the keyboard. **F11** is the Magic button (NMI), **F12** the reset.

## OSD menu

| Page | Item | Values | Hotkey |
|---|---|---|---|
| | Turbo | Off / 7 MHz / 14 MHz | Menu+F2 |
| | INT | Pentagon / Pent -2T / Firm / Firm -2T | |
| | Joystick L, Joystick R | Kempston / Sinclair1 / Sinclair2 / Cursor / QAOPM / QAOPS | |
| | Mouse | On / Off | |
| | Magic | NMI | F11 |
| | Reset | | F12 |
| Video | 512 Ink | the ink of 512 x 192 mono (16 colours) | |
| Video | 512 mode, FlashColor, GigaScreen | the reset values of FE37 | |
| Video | Palette | On / Off | |
| Video | Output | 720x576 / 768x608 | |
| Video | VGA Sync (Go) | -H -V / +H -V / -H +V / +H +V | |
| System | Turbo 14 | Original / No wait | |
| System | Memory | the schemes of FC37 | |
| System | 7FFD D5 | Lock / Memory | |
| System | +3 mode, Multitask | Off / On | |
| System | Boot | Direct / BIOS | |
| System | Reset to | Gluk / Menu-128 / TR-DOS / BASIC 48 | |
| Sound | SoundDrive, General Snd, OPL4, OPL4 Interp | On / Off | |
| Sound | OPL4 ROM | the YRW801 file | |
| Disks | Disk A..D | TRD images | Menu+F5 / Menu+F6 (A / B) |
| Disks | HDD Master | CF card / Image | |
| Disks | HDF0, HDF1 | HDF images (Master, Slave) | |

The System items are applied at the next reset.

## Ports

| Device | Ports |
|---|---|
| 128K, extended memory | 7FFD, DFFD, 1FFD, EFF7 |
| BIOS | FC37 (memory scheme), FD37 (static RAM over the ROM), FE37 (video), FF37 (BIOS ROM, Gluk latch, palette write, flash) |
| Palette | a write to xxFF with FF37 D5 = 1 (the colour in the data and the high address bits, HW.md) |
| Attribute port | read FF (outside TR-DOS) |
| TR-DOS (VG93) | 1F, 3F, 5F, 7F, FF (only while TR-DOS is on) |
| Nemo IDE | A1 = A2 = 0 (not in TR-DOS): A0 = 0 the registers of the drive (A7..A5), A0 = 1 (11) the high byte of the data |
| CMOS (MC146818) | EFF7 (D7 = on), DFF7 (address), BFF7 (data) |
| Kempston joystick / mouse | 1F / FBDF (x), FFDF (y), FADF (buttons) |
| SoundDrive / Covox | 0F, 1F, 4F, 5F / FB |
| General Sound | BB (command / status), B3 (data) |
| OPL4 | C4 / C5 FM bank 0, C6 / C7 FM bank 1, 7E / 7F wavetable (not in TR-DOS) |

While the OPL4 is on, its ports C4 / C6 / 7E (A0 = 0) do not reach port FE.

## Building

Clone with `--recursive` (the `modules` submodule). ISE 14.7: `cd src && make go`, `make mini`, `make minig` (one after the other: the boards share `xst/`). The Go and Mini tops are made from the Mini G top by `src/tools/mktop.py`. Simulations (Verilator, seconds to a minute): `make sim-video`, `sim-modes`, `sim-int`, `sim-boot`; the reference model of the picture is `src/tools/p4096_vmodel.py`. The plan and the design notes are in [docs/PLAN.md](docs/PLAN.md) (Russian).

## Licence

GPL v3 ([LICENSE](LICENSE)). The Pentagon-4096 board and its BIOS: (c) AleksandrDneprCity. z80-silicon: GPL-3 (`src/rtl/z80-silicon/LICENSE`); opl3_fpga: LGPL-3 (`src/rtl/sound/opl4/opl3/COPYING.LESSER`); wd1793 of MiSTer: GPL. The 128K, 48K and +3 ROMs are (c) Amstrad, which allows their distribution with emulators; Gluk Reset Service, TR-DOS and the GS ROM belong to their authors. Imported files keep the licence headers of their authors.
