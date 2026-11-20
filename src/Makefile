# Pentagon-4096 core (p4096) for Karabas Go / Mini / Mini G, ISE 14.7.
#
#   make minig            one board: synthesis, implementation, bitstream, p4096.kg (Mini G only until Ф5)
#   make minig-xst        one step: <board>-xst (.ngc), <board>-impl (.bin), <board>-core (.kg)
#   make minig-report     LUTs, slices, block RAMs and the timing result of the last build (and of -coremode)
#   make minig-coremode   the timing of the last build in the mode of the core of HDMI (pcf_core.py, as core-zxuno)
#   make sim-video        Verilator: the standard screen against tools/p4096_vmodel.py (seconds)
#   make sim-int          Verilator + unreal-ng: INT against the raster (int_test.asm, about half a minute)
#   make sim-boot         Verilator: the 128 menu boots (60 frames, about 40 s)
#
# Inputs per board: karabas_<board>.prj (the source list, the shared modules as "../modules/rtl/..."), .xst,
# .ucf, .ut. A step runs again when one of its inputs is newer than its output.
#
#   make measure-all      Ф0: XST of measure/p4096_measure.v (z80-silicon + ROM / GS in SDRAM + GS + VG93 +
#                         TurboSound + SoundDrive), never implemented
#   make measure-report   LUTs, FFs, block RAMs and the XST clock estimate of the measure
#   make clean            the intermediate files

ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
SHELL = /bin/bash
.SHELLFLAGS = -e -o pipefail -c
XIL = source $(ISE_SETTINGS) > /dev/null;
prj_src = $(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' $(1) 2>/dev/null)

PART = xc6slx25-ftg256-2
BOARDS = minig
KG = p4096.kg
JSON = core.json
# map / par as core-zxuno; cost table 2 first (karabas-go-notes map-cost-table-2-first)
MAP_T_minig = 2
MAP_OPT = -logic_opt off -ol high -xe n -xt 0 -register_duplication off -r 4 -global_opt off -mt 2 -detail -ir off -pr b -lc off -power off
PAR_OPT = -ol high -xe n -mt 4
INCLUDES = $(wildcard ../modules/rtl/mcu/*.vh)

.PHONY: measure-all measure-report clean sim-video sim-int sim-boot $(BOARDS) $(BOARDS:=-xst) $(BOARDS:=-impl) $(BOARDS:=-core) $(BOARDS:=-report) minig-coremode

define board
SRC_$(1) := $$(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' karabas_$(1).prj)

karabas_$(1).ngc: karabas_$(1).prj karabas_$(1).xst $$(SRC_$(1)) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	$(XIL) xst -intstyle ise -ifn karabas_$(1).xst -ofn karabas_$(1).syr

karabas_$(1).bin: karabas_$(1).ngc karabas_$(1).ucf karabas_$(1).ut
	$(XIL) ngdbuild -intstyle ise -dd _ngo -nt timestamp -uc karabas_$(1).ucf -p $(PART) karabas_$(1).ngc karabas_$(1).ngd
	$(XIL) map -intstyle ise -p $(PART) -w $(MAP_OPT) -t $(MAP_T_$(1)) -o karabas_$(1)_map.ncd karabas_$(1).ngd karabas_$(1).pcf
	$(XIL) par -w -intstyle ise $(PAR_OPT) karabas_$(1)_map.ncd karabas_$(1).ncd karabas_$(1).pcf
	$(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml karabas_$(1).twx karabas_$(1).ncd -o karabas_$(1).twr karabas_$(1).pcf -ucf karabas_$(1).ucf
	$(XIL) bitgen -intstyle ise -f karabas_$(1).ut karabas_$(1).ncd

kg_$(1).stamp: karabas_$(1).bin $(JSON) $$(wildcard roms/*)
	python3 make_core.py $(JSON) $(KG) --boards $(1)
	touch $$@

$(1): kg_$(1).stamp
$(1)-xst: karabas_$(1).ngc
$(1)-impl: karabas_$(1).bin
$(1)-core: kg_$(1).stamp
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs):" karabas_$(1)_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" karabas_$(1).par | sort -u
	@if [ -f karabas_$(1)_core.twr ]; then echo "mode of the core (-coremode):"; \
		grep -E "constraints? (was|were) met|constraints? not met|Timing errors" karabas_$(1)_core.twr | sort -u; fi
endef
$(foreach b,$(BOARDS),$(eval $(call board,$(b))))

minig-coremode: karabas_minig_core.twr
karabas_minig_core.twr: karabas_minig.bin pcf_core.py
	python3 pcf_core.py karabas_minig.pcf karabas_minig_core.pcf
	$(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths karabas_minig.ncd -o karabas_minig_core.twr karabas_minig_core.pcf \
		| tee karabas_minig_core.log | grep -E "ERROR|WARNING" || true
	@! grep -q "No timing constraints found" karabas_minig_core.twr || { echo "trce did not read karabas_minig_core.pcf"; \
		rm -f karabas_minig_core.twr; exit 1; }

sim-video:
	sim/run_p4096_sim.sh video
sim-int:
	sim/run_p4096_sim.sh int
sim-boot:
	sim/run_p4096_sim.sh boot 60

p4096_measure.ngc: measure/p4096_measure.xst measure/p4096_measure.prj $(call prj_src,measure/p4096_measure.prj)
	mkdir -p xst_measure/projnav.tmp
	$(XIL) xst -intstyle ise -ifn measure/p4096_measure.xst -ofn p4096_measure.syr > measure/xst_measure.log

measure-all: p4096_measure.ngc

measure-report:
	@for s in p4096_measure; do echo "== $$s"; grep -hE "Number of Slice LUTs|Number of Slice Registers|Number of Block RAM|DSP48A1s:|Maximum Frequency" $$s.syr 2>/dev/null || true; done

clean:
	rm -rf xst_measure _xmsgs xlnx_auto_0_xdb p4096_measure.{ngc,ngr,syr,lso} p4096_measure_xst.xrpt measure/xst_*.log
	rm -f kg_*.stamp
	rm -rf xst _ngo iseconfig
	rm -f $(foreach b,$(BOARDS),$(addprefix karabas_$(b),.ngc .ngd .ngr .syr .lso .bld .pcf .ncd _map.ncd _map.ngm \
		_map.map _map.mrp _map.xrpt .par .pad _pad.csv _pad.txt .twr .twx .unroutes .xpi .ptwx .bgn .bit .drc \
		_bitgen.xwbt _summary.xml _usage.xml _xst.xrpt _ngdbuild.xrpt _par.xrpt _guide.ncd _core.pcf _core.twr _core.log))
