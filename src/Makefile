# Pentagon-4096 core (p4096) for Karabas Go / Mini / Mini G, ISE 14.7.
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

.PHONY: measure-all measure-report clean

p4096_measure.ngc: measure/p4096_measure.xst measure/p4096_measure.prj $(call prj_src,measure/p4096_measure.prj)
	mkdir -p xst_measure/projnav.tmp
	$(XIL) xst -intstyle ise -ifn measure/p4096_measure.xst -ofn p4096_measure.syr > measure/xst_measure.log

measure-all: p4096_measure.ngc

measure-report:
	@for s in p4096_measure; do echo "== $$s"; grep -hE "Number of Slice LUTs|Number of Slice Registers|Number of Block RAM|DSP48A1s:|Maximum Frequency" $$s.syr 2>/dev/null || true; done

clean:
	rm -rf xst_measure _xmsgs xlnx_auto_0_xdb p4096_measure.{ngc,ngr,syr,lso} p4096_measure_xst.xrpt measure/xst_*.log
