#!/bin/bash
# p4096 machine simulations (Verilator, tb_p4096.v). Usage: src/sim/run_p4096_sim.sh [video|boot] [frames]
#   video  the CPU in reset, random screen 5 in the RAM: frame 1 against src/tools/p4096_vmodel.py (seconds)
#   boot   the ROM set of core.json, the 128 menu: PNG of the last frame (frames, default 60)
# Output in src/sim/build/p4096. Verilator, not iverilog: z80-silicon has registers without an initial value
# (see core-tsconf run_z80s_sim.sh), --x-initial 0 is their value in the FPGA.
set -e
SIM="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$SIM")"
RTL="$SRC/rtl"
OUT="$SIM/build/p4096"
mkdir -p "$OUT"
WHAT=${1:-video}
N=${2:-60}

if [ ! -x "$OUT/obj/tb" ] || [ -n "$(find "$RTL/p4096" "$SIM/tb_p4096.v" -newer "$OUT/obj/tb" 2>/dev/null)" ]; then
	verilator --binary --timing --default-language 1364-2005 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
		--x-initial 0 --x-assign 0 -O2 --top-module tb_p4096 -Mdir "$OUT/obj" -o tb \
		"$SIM/tb_p4096.v" "$RTL/p4096/p4096.v" "$RTL/p4096/p4096_video.v" \
		"$RTL/z80-silicon/z80s_t80pa.v" "$RTL/z80-silicon/z80_silicon_cen.v" \
		"$RTL/sound/turbosound.v" "$RTL/sound/ym2149.v" > "$OUT/build.log" 2>&1 \
		|| { grep -m10 "%Error" "$OUT/build.log"; echo "no build"; exit 1; }
fi

F="python3 -I $SIM/p4096_frame.py"
case $WHAT in
video)
	$F ram "$OUT/ram.hex" 1
	"$OUT/obj/tb" +hold +frames=1 +ram="$OUT/ram.hex" +dump="$OUT/video.txt" | tail -1
	$F png "$OUT/video.txt" "$OUT/video.png"
	$F cmp "$OUT/video.txt" "$OUT/ram.hex"
	;;
boot)
	cat "$SRC/roms/glukpen.rom" "$SRC/roms/tr5_03.rom" "$SRC/roms/128_std.rom" "$SRC/roms/basic48_128_std.rom" > "$OUT/rom.bin"
	$F hex "$OUT/rom.bin" "$OUT/rom.hex" 65536
	"$OUT/obj/tb" +frames="$N" +rom="$OUT/rom.hex" +dump="$OUT/boot.txt" +log="$OUT/boot.log" ${TB_ARGS} | tail -1
	$F png "$OUT/boot.txt" "$OUT/boot.png"
	echo "PNG: $OUT/boot.png"
	;;
*)
	echo "usage: $0 [video|boot] [frames]"; exit 2 ;;
esac
