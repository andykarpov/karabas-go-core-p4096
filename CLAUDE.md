# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A Pentagon-4096 core (`p4096`) for the Karabas Go, Mini and Mini G boards (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST). The original ([AleksandrDneprCity/Pentagon-4096](https://github.com/AleksandrDneprCity/Pentagon-4096), MainBoard 10.7.1 / TopBoard 5.3.1) is a discrete-logic board without HDL: the core is written from its README and schematic. Docs, in Russian: `docs/PLAN.md` (decisions, phases, status), `docs/HW.md` (schematic reading: ports, memory pages, video, palette, raster, INT, BIOS v4.2 disassembly), `docs/QUESTIONS.md` (open questions for the author). Follow the phases; record a changed decision in PLAN.md.

User decisions (2026-11-19): the whole machine; all video modes and extended ports first; BIOS Setup settings in the OSD (the BIOS port registers stay, the OSD sets their reset values, an optional "Boot BIOS"); licence: the user writes to the author, meanwhile assume the open project may be used; core id `p4096`; repo local only (GitHub later, the user's call).

Status: Ф0 done and merged (2026-11-19). Ф1 Pentagon-128 on Mini G in progress, branch `f1-minig` (state in PLAN.md).

## Simulation

`make -C src sim-video` / `sim-int` / `sim-boot` (Verilator, `src/sim/run_p4096_sim.sh`): the machine `rtl/p4096/p4096.v` with a RAM / ROM model; frames compared with `p4096_vmodel.py` and with unreal-ng (emu-shot).

## Tools

- `src/tools/p4096_vmodel.py` — reference model of the picture (all modes); `python3 -I src/tools/p4096_vmodel.py demo DIR`.
- `make -C src measure-all` / `measure-report` — XST fit of the donor blocks (`src/measure`).
- Schematic: render the PDF (`Hardware/Export/PDF/*-sch.pdf` of the original repo) with `pdftoppm -r 250 -x -y -W -H`; `pdftotext -bbox` finds net labels. Sharper than the PNG export.
- Timing oracle for Pentagon-128 / 1024 (incl. #EFF7 16c and multicolor): unreal-ng via `emu-shot unreal --machine PENTAGON`, ZEsarUX `Pentagon --enable16c`.

## Rules of the core

The rules of the other karabas-go cores apply: standard video timing with syncs always present, `FT_CLK_OUT` about 8 MHz on Mini / Mini G, Go `FDC_*` outputs 0 when unused, Mini / Mini G drive T3 (`FLASH_CS_N`) = 0, OSD switch index = item position unless `"index"`, an OSD value shows 10 characters at most, FL slots 0..7 only, Verilog-2001 for XST (`sv2v` for SV), VHDL-93 for XST, imported code marked `karabas:`, builds through `src/Makefile`.

- Donor code (`src/rtl`) comes from karabas-go-core-baseconf 336bcd3 (z80-silicon, VG93 model + hrdy_fdc, GS, TurboSound, covox, SDRAM storage); keep every header as it is.
- **Ask the user before every check on the board** (and the HDMI capture). Ask before a firmware flash.
- One branch per phase of `docs/PLAN.md`, merged at its end. OSD look needs the user's approval (frame) before the merge.
- Heavy builds: Mini G only while working on one feature, all boards for a release; map with cost table 2 first. Simulations that run for minutes only after asking.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`). Its `MEMORY.md` is split by repo (section core-p4096, note `pentagon4096-survey.md`); commit and push it after every memory change.
