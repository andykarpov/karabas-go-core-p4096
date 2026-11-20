#!/bin/bash
# p4096 machine simulations (Verilator, tb_p4096.v). Usage: src/sim/run_p4096_sim.sh [video|boot|int] [frames]
#   video  the CPU in reset, random screen 5 in the RAM: frame 1 against src/tools/p4096_vmodel.py (seconds)
#   boot   the ROM set of core.json, the 128 menu: PNG of the last frame (frames, default 60);
#          TB_ARGS=+fc37=9a: the +3 mode (the +3 menu)
#   modes  Ф2: all video modes, the palette, FlashColor, GigaScreen against p4096_vmodel.py (p4096_modes.py)
#   mem    Ф3: the memory schemes 0-6 of #FC37 against the table of docs/HW.md (p4096_mem.py)
#   int    INT against the raster: int_test.asm here and in unreal-ng PENTAGON (emu-shot), the border stripes
#          must be at the same points (TB_ARGS="+firm" etc. for the other settings, no reference then)
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
	cat "$SRC/roms/glukpen.rom" "$SRC/roms/tr5_03.rom" "$SRC/roms/128_std.rom" "$SRC/roms/basic48_128_std.rom" \
		"$SRC/roms/plus341.rom" > "$OUT/rom.bin"
	$F hex "$OUT/rom.bin" "$OUT/rom.hex" 131072
	"$OUT/obj/tb" +frames="$N" +rom="$OUT/rom.hex" +dump="$OUT/boot.txt" +log="$OUT/boot.log" ${TB_ARGS} | tail -1
	$F png "$OUT/boot.txt" "$OUT/boot.png"
	echo "PNG: $OUT/boot.png"
	;;
int)
	# int_test.asm as ROM page 2 against int_test.sna in unreal-ng PENTAGON (emu-shot), builds PAD 0..3 (the
	# phase of HALT): the earliest stripe of the four is the INT position in both
	for P in 0 1 2 3; do
		(cd "$OUT" && /opt/sjasmplus/sjasmplus --nologo -DROM -DPAD=$P "$SIM/int_test.asm" > int_rom.log && \
			mv int_test.rom int_test_$P.rom && /opt/sjasmplus/sjasmplus --nologo -DPAD=$P "$SIM/int_test.asm" > int_sna.log && \
			mv int_test.sna int_test_$P.sna) || { cat "$OUT"/int_*.log; exit 1; }
		cat "$SRC/roms/glukpen.rom" "$SRC/roms/tr5_03.rom" "$OUT/int_test_$P.rom" "$SRC/roms/basic48_128_std.rom" > "$OUT/rom_int.bin"
		$F hex "$OUT/rom_int.bin" "$OUT/rom_int.hex" 65536
		"$OUT/obj/tb" +frames=3 +rom="$OUT/rom_int.hex" +dump="$OUT/int_$P.txt" +log="$OUT/int_$P.log" ${TB_ARGS} > /dev/null
		[ -f "$OUT/unreal_int_$P.png" ] || emu-shot unreal --machine PENTAGON --file "$OUT/int_test_$P.sna" wait:2 \
			shot:"$OUT/unreal_int_$P.png" > /dev/null
	done
	$F intset "$OUT"
	;;
modes)
	# Ф2: every video mode against the model (p4096_modes.py; a case name as the second argument: only it)
	shift; python3 -I "$SIM/p4096_modes.py" "$OUT" "$OUT/obj/tb" "$@"
	;;
mem)
	# Ф3: the memory schemes 0-6 of #FC37 (p4096_mem.py; scheme numbers as arguments: only them)
	shift; python3 -I "$SIM/p4096_mem.py" "$OUT" "$OUT/obj/tb" "$@"
	;;
*)
	echo "usage: $0 [video|boot|int|modes|mem] [frames | case]"; exit 2 ;;
esac
