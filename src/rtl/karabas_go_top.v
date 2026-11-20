`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
-- Pentagon-4096 core (p4096) for Karabas Go
--
-- The machine is rtl/p4096/p4096.v (board free); this top gives it the board:
-- Clocks (the PLL of core-tsconf / core-baseconf): clk_bus 28.03 MHz = the machine, the MCU link, the OSD, HDMI in
-- the mode of the core; clk_sys 84.09 MHz = the SDRAM of the ROM (baseconf_storage, sdram2p); clk_8 7.97 MHz =
-- FT_CLK_OUT and DCM_CLKGEN of HDMI.
-- RAM: the SRAM, 2M x 16 = 4 MB, byte address {MA, lane}: MA = byte address / 2, the lane = bit 0 (0 = MD[7:0]).
-- A read takes one clk_bus (the address from flip-flops, the data into the input flip-flops at the next edge);
-- a write two, /WE low from the middle of the first to the middle of the second (ODDR2), the address and the data
-- stable for both (as core-profi / core-pcxt: /WE half a clock after the address).
-- ROM: the main ROM pages (core.json "roms", 16 KB each from address 0) in the SDRAM, baseconf_storage of
-- core-baseconf (port 1, through p4096_romcache); port 2: General Sound and the sample memory of the OPL4.
-- Video: p4096 -> p4096_scandbl (720 x 576 of 896 x 640 at 28 MHz) -> OSD -> HDMI.
-- Input: USB keyboard (hid_parser -> the matrix), joysticks of kg_mcu2 -> Kempston #1F.
-- Disks: TRD images A-D (p4096_fdd, wd1793), Nemo IDE (the CF card or HDF images, hdf_ata), CMOS of kg_mcu2.
-- Sound: AY / TurboSound, SoundDrive, General Sound, OPL4, the ADC; MIDI out on AY port A.
------------------------------------------------------------------------------------------------------------------*/
// karabas: made by src/tools/mktop.py from karabas_minig_top.v (do not edit it, change Mini G)
// The Go: VGA (the video DAC, V_CLK) instead of HDMI, no FT_CLK_OUT, no ADC, the floppy connector unused.

module karabas_go_top (
   //---------------------------
   input wire CLK_50MHZ,

	//---------------------------
	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,
	
   //---------------------------
   output wire [20:0] MA,
   inout wire [15:0] MD,
   output wire [1:0] MWR_N,
   output wire [1:0] MRD_N,

   //---------------------------
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

   //---------------------------
   output wire SD_CS_N,
   output wire SD_CLK,
   inout wire SD_DI,
   inout wire SD_DO,
	input wire SD_DET_N,

   //---------------------------
   output wire [7:0] VGA_R,
   output wire [7:0] VGA_G,
   output wire [7:0] VGA_B,
   output wire VGA_HS,
   output wire VGA_VS,
	output wire V_CLK,
	
	//---------------------------
	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	//---------------------------
	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,
	
	//---------------------------
	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

   //---------------------------	
	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,
	
	//---------------------------
	output wire DAC_LRCK,
   output wire DAC_DAT,
   output wire DAC_BCK,
   output wire DAC_MUTE,
	
	//---------------------------
	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SPI_FT_CS_N,
	input wire MCU_SPI_SD2_CS_N,	
	inout wire [1:0] MCU_SPI_IO,  // [0] INT of link v2 (N9), [1] unused (M11)
	
	//---------------------------
	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,
	
	//---------------------------
	output wire FLASH_CS_N,
	input wire  FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N	
   );
// karabas: made by src/tools/mktop_go.py from karabas_minig_top.v (do not edit it, change Mini G)

// unused signals yet
assign FLASH_CS_N 	= 1'b1;
assign FLASH_DI 		= 1'b1;
assign FLASH_SCK 		= 1'b0;
assign FLASH_WP_N 	= 1'b1;
assign FLASH_HOLD_N 	= 1'b1;

// system clocks
wire clk_sys, clk_8mhz, clk_bus, clk_bus_pll, clk_12mhz;
wire locked, areset;

// VCO 50 * 37 / 2 = 925 MHz, phase 0: clk_sys 84.09 MHz (/11), clk_8 7.97 MHz (/116), clk_bus 28.03 MHz (/33,
// every third edge of clk_sys), MIDI 12.01 MHz (/77). Its PLL output of clk_bus has no BUFG in kg_pll: it drives
// the BUFG of clk_bus and the BUFGMUXes of hdmi_pll (no BUFG in front of them).
wire [5:0] pll_clk;
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(116), .CLKOUT2_DIVIDE(33), .CLKOUT3_DIVIDE(77),
	.BUFG_MASK(6'b001011)
) pll (
	.clk_in			(CLK_50MHZ),
	.rst				(1'b0),
	.clk_out			(pll_clk),
	.locked			(locked)
);

// the configuration flash is not used: its select high
assign FLASH_CS_N   = 1'b1;
assign FLASH_DI     = 1'b1;
assign FLASH_SCK    = 1'b0;
assign FLASH_WP_N   = 1'b1;
assign FLASH_HOLD_N = 1'b1;


assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign BEEPER = 1'b0;
// the floppy connector: the core has no physical drive (all outputs 0 = inactive behind the inverters)
assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_DIR = 1'b0;
assign FDC_STEP = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;
assign FDC_SIDE_N = 1'b0;
assign UART_RX = 1'bz;
assign UART_TX = 1'bz;
assign UART_CTS = 1'bz;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'bz;
assign SD_DO = 1'bz;

// ---------- clocks: VCO 50 * 37 / 2 = 925 MHz: clk_sys /11 84.09, clk_8 /116 7.97, clk_bus /33 28.03, /77 12.01
wire clk_sys, clk_8mhz, clk_bus, clk_bus_pll, clk_12mhz;
wire locked, areset;
wire [5:0] pll_clk;
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(116), .CLKOUT2_DIVIDE(33), .CLKOUT3_DIVIDE(77),
	.BUFG_MASK(6'b001011)
) pll (
	.clk_in			(CLK_50MHZ),
	.rst				(1'b0),
	.clk_out			(pll_clk),
	.locked			(locked)
);
assign clk_sys = pll_clk[0];
assign clk_8mhz = pll_clk[1];
assign clk_bus_pll = pll_clk[2];
assign clk_12mhz = pll_clk[3];
BUFG bufg_clk_bus(.I(clk_bus_pll), .O(clk_bus));

// the clock of the MIDI synth SAM2695 (12 MHz) and its reset; the Go has no FT_CLK_OUT (the FT812 has a crystal)
ODDR2 u_midi_clk (.Q(MIDI_CLK), .C0(clk_12mhz), .C1(~clk_12mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
assign MIDI_RESET_N = 1'b1;
// V_CLK of the video DAC: the pixel clock (clk_bus) inverted, from clk_sys (bus_ce, as core-baseconf)
wire v_clk;
bus_ce bus_ce(.clk_sys(clk_sys), .clk_bus(clk_bus), .ce(), .v_clk(v_clk));

// SDRAM clock, inverted (sdram2p of baseconf_storage runs on clk_sys)
ODDR2 sdr_clock(.Q(SDR_CLK), .C0(clk_sys), .C1(~clk_sys), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0));

assign areset = ~locked;

// ---------- MCU (link v2) ----------
wire mcu_int;
assign MCU_SPI_IO[0] = mcu_int;   // INT of link v2 on N9
assign MCU_SPI_IO[1] = 1'bz;

// MCU_SCK is not on a clock pin of the Go (CLOCK_DEDICATED_ROUTE = FALSE in the ucf)
wire mcu_sck = MCU_SCK, mcu_sck_ibufg = MCU_SCK;

wire [55:0] mcu_kbd;
// the Nemo IDE bus of the machine (the CF card and hdf_ata below)
wire [2:0] ide_a;
wire [1:0] ide_cs_n;
wire ide_rd_n, ide_wr_n;
wire [15:0] ide_dout, ide_din, hdf_dout;

// the image files of the mcu (kg_mcu2 ENABLE_IMG, img_sdc inside): HDF0 slot 4, HDF1 slot 5 (hdf_ata)
wire [7:0] sdc_img_mounted, sdc_rd, sdc_wr, sdc_byte_in_data, sdc_byte_out_data;
wire [63:0] sdc_img_size;
wire [31:0] sdc_sector;
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] img_wp;
// floppies A-D (p4096_fdd in the machine): slots 0-3
wire [3:0] fdd_rd, fdd_wr;
wire [31:0] fdd_sector;
wire [7:0] fdd_out_data;
wire fdd_active;
wire fdd_own = !sdc_slot[2];
wire [7:0] ms_x, ms_y, mcu_ms_z, mcu_ms_b;
wire mcu_ms_wr;
wire [7:0] rtc_a, rtc_di, rtc_do;
wire rtc_wr;
wire [15:0] mcu_joy_l, mcu_joy_r;
wire [5:0] mcu_btns;
wire mcu_busy, dvi_only;
wire [7:0] hwid;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;
wire mcu_ft_spi_on, mcu_ft_vga_on, mcu_ft_reset, mcu_ft_sck, mcu_ft_mosi, mcu_ft_cs_n;
wire [1:0] ld_kind;
wire ld_active, ld_wr;
wire [31:0] ld_addr;
wire [7:0] ld_data;
wire [7:0] ld_slot;

localparam SW_N = 26;
wire [SW_N*8-1:0] softsw;
wire sw_wr;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(SW_N),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),
	.IMG_OUT_LATENCY(3),
	.ENABLE_PORTS(4'b0000),
	.ENABLE_RTC(1),
	.RTC_SKIP_0D(1),               // MC146818 (core.json rtc_mode 0): C / D are flags
	.ENABLE_AUX(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu(
	.CLK				(clk_bus),
	.N_RESET			(~areset),
	.MCU_SCK			(mcu_sck),
	.MCU_MOSI		(MCU_MOSI),
	.MCU_MISO		(MCU_MISO),
	.MCU_SS			(MCU_CS_N),
	.MCU_INT			(mcu_int),
	.MCU_SPI_FT_SS	(MCU_SPI_FT_CS_N),
	.MCU_SPI_SD2_SS(1'b1),
	.SW				(softsw),
	.SW_WR			(sw_wr),
	.SW_INDEX		(),
	.SW_VALUE		(),
	.HW_ID			(hwid),
	.DVI_ONLY		(dvi_only),
	.CORE_BUILD		(),
	.FW_BUILD		(),
	.BUSY				(mcu_busy),
	.BTNS				(mcu_btns),
	.RELOAD_REQ		(1'b0),
	.RELOAD_CORE	(8'd0),
	.BK_MOUNT		(1'b0),
	.BK_FLUSHED		(1'b0),
	.BK_SLOT			(3'd0),
	.BK_SIZE			(32'd0),
	.BK_KIND			(8'd0),
	.BK_RESULT		(8'd0),
	.KBD				(mcu_kbd),
	.KBD_WR			(),
	.PS2_CODE		(),
	.PS2_KIND		(),
	.PS2_WR			(),
	.MS_X				(ms_x),
	.MS_Y				(ms_y),
	.MS_Z				(mcu_ms_z),
	.MS_B				(mcu_ms_b),
	.MS_WR			(mcu_ms_wr),
	.JOY_L			(mcu_joy_l),
	.JOY_R			(mcu_joy_r),
	.JOY_WR			(),
	.PS2_CMD			(16'h0000),
	.PS2_CMD_WR		(1'b0),
	.LD_KIND			(ld_kind),
	.LD_SLOT			(ld_slot),
	.LD_SIZE			(),
	.LD_START		(),
	.LD_ACTIVE		(ld_active),
	.LD_END			(),
	.LD_ADDR			(ld_addr),
	.LD_DATA			(ld_data),
	.LD_WR			(ld_wr),
	.LD_READY		(1'b1),          // baseconf_storage queues the bytes (16 entries, as core-baseconf)
	.OSD_WR			(osd_wr),
	.OSD_WADDR		(osd_waddr),
	.OSD_WDATA		(osd_wdata),
	.OSD_EN			(osd_en),
	.OSD_FG			(osd_fg),
	.OSD_BG			(osd_bg),
	.OSD_ALPHA		(osd_alpha),
	.OSD_PX			(osd_px),
	.OSD_PY			(osd_py),
	.OSD_PW			(osd_pw),
	.OSD_PH			(osd_ph),
	.OSD_PLACE		(osd_place),
	.OSD_ZOOM		(osd_zoom),
	.SDC_IMG_MOUNTED(sdc_img_mounted),
	.SDC_IMG_SIZE	(sdc_img_size),
	.SDC_RD			(sdc_rd),
	.SDC_WR			(sdc_wr),
	.SDC_SECTOR		(sdc_sector),
	.SDC_BUSY		(sdc_busy),
	.SDC_DONE		(sdc_done),
	.SDC_ERROR		(sdc_error),
	.SDC_SLOT		(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_in_strobe),
	.SDC_BYTE_ADDR	(sdc_byte_addr),
	.SDC_BYTE_IN_DATA(sdc_byte_in_data),
	.SDC_BYTE_OUT_DATA(sdc_byte_out_data),
	.IMG_WP			(img_wp),
	.IMG_PHYS_WR	(),
	.IMG_PHYS		(),
	.IMG_FLUSH		(),
	.FDD_CHNG_WR	(),
	.FDD_CHNG		(),
	.FDD_CHNG_REQ	(1'b0),
	.FDD_CHNG_DS	(2'd0),
	.IMG_ACTIVE		(),
	.PORT_OUT_DATA	(),
	.PORT_OUT_WR	(),
	.PORT_OUT_READY(4'b1111),
	.PORT_IN_DATA	(32'd0),
	.PORT_IN_WR		(4'b0000),
	.PORT_CFG		(128'd0),
	.PORT_IN_FULL	(),
	.PORT_STAT		(),
	.PORT_STAT_WR	(),
	.RTC_A			(rtc_a),
	.RTC_DI			(rtc_di),
	.RTC_CS			(1'b1),
	.RTC_WR_N		(!rtc_wr),
	.MATRIX_CMD		(),
	.MATRIX_CMD_WR	(),
	.DEBUG_ADDR		(16'd0),
	.DEBUG_DATA		(16'd0),
	.RTC_DO			(rtc_do),
	.FT_SPI_ON		(mcu_ft_spi_on),
	.FT_VGA_ON		(mcu_ft_vga_on),
	.FT_RESET		(mcu_ft_reset),
	.FT_SCK			(mcu_ft_sck),
	.FT_MOSI			(mcu_ft_mosi),
	.FT_MISO			(FT_SPI_MISO),
	.FT_CS_N			(mcu_ft_cs_n),
	.SD2_SCK			(),
	.SD2_MOSI		(),
	.SD2_MISO		(1'b1),
	.SD2_CS_N		()
);

// the FT812 belongs to the mcu (its menus): the core does not use it
assign FT_SPI_CS_N = mcu_ft_spi_on ? mcu_ft_cs_n : 1'b1;
assign FT_SPI_SCK = mcu_ft_spi_on ? mcu_sck_ibufg : 1'b1;
assign FT_SPI_MOSI = mcu_ft_spi_on ? mcu_ft_mosi : 1'b1;
// the FT812 and the FPGA share the video DAC: the FT812 drives it when the firmware asks (its menus)
assign FT_OE_N = !mcu_ft_vga_on;

// ---------- OSD switches (core.json "osd" "index"): switch n = softsw[n*8 +: 8] ----------
wire sw_reset = softsw[0];               // 0 Reset (F12)
wire sw_magic = softsw[8];               // 1 Magic (F11): NMI
wire [1:0] sw_cpu = softsw[2*8 +: 2];    // 2 Turbo Off (3.5) / 7 / 14 MHz
wire [1:0] sw_int = softsw[3*8 +: 2];    // 3 INT Pentagon / Pent -2T / Firm / Firm -2T (bit 1 Firm, bit 0 the XJ3 jumper)
wire sw_int_firm = sw_int[1];
wire sw_int_xj3 = sw_int[0];
wire [2:0] sw_joy_l = softsw[4*8 +: 3];  // 4, 5 Joystick L / R: Kempston / Sinclair1 / Sinclair2 / Cursor / QAOPM / QAOPS
wire [2:0] sw_joy_r = softsw[5*8 +: 3];  //   (the codes of JOY_TYPE of hid_parser, as core-tsconf / core-profi)
// 6..9: the reset values of #FE37 (what BIOS Setup sets): 512 Ink (index I G R B), 512 mode Mono / Colour,
// FlashColor Off / On, GigaScreen Off / On; 10 Palette On / Off; 11 Video 720x576 / 768x608
wire [3:0] sw_ink512 = softsw[6*8 +: 4];
wire sw_col512 = softsw[7*8];
wire sw_flashcol = softsw[8*8];
wire sw_giga = softsw[9*8];
wire sw_pal_off = softsw[10*8];
wire sw_video_full = softsw[11*8];
// 12..17: the system (the reset values of the BIOS ports, what BIOS Setup sets; applied at the next reset)
wire [2:0] sw_mem = softsw[12*8 +: 3];   // Memory: the schemes 0-6 of #FC37 (README)
wire sw_d5_mem = softsw[13*8];           // 7FFD D5: Lock / Memory (#FC37 D4 = 1 / 0)
wire sw_plus3 = softsw[14*8];            // +3 mode (#FC37 D7)
wire sw_mtask = softsw[15*8];            // Multitask (#FC37 D6)
wire sw_boot_bios = softsw[16*8];        // Boot: Direct / BIOS (#FF37 = 23 as BIOS leaves it / 00: BIOS v4.2 runs)
wire [1:0] sw_reset_to = softsw[17*8 +: 2];   // Reset to (Direct): Gluk / Menu-128 / TR-DOS / BASIC 48
wire sw_turbo_nowait = softsw[18*8];     // 18 Turbo 14: Original (WAITP) / No wait
wire sw_mouse_off = softsw[19*8];        // 19 Mouse On / Off (Kempston mouse)
wire sw_sd_off = softsw[20*8];           // 20 SoundDrive On / Off
wire sw_gs_off = softsw[22*8];           // 22 General Sound On / Off
wire sw_opl4_off = softsw[23*8];         // 23 OPL4 (ZXM-MoonSound) On / Off
wire sw_opl4_nointerp = softsw[24*8];    // 24 OPL4 Interp On / Off (linear interpolation of the samples)
wire [1:0] vga_sync_pos = softsw[25*8 +: 2];  // 25 VGA Sync (Go only): bit 0 +H, bit 1 +V (0 = -H -V)
wire sw_hdd_image = softsw[21*8];        // 21 HDD Master: CF card / Image (HDF0); HDF1 = Slave (image)
reg [3:0] em;
always @(*)
	case (sw_mem)
		3'd0: em = 4'b0000; 3'd1: em = 4'b0001; 3'd2: em = 4'b0010; 3'd3: em = 4'b0011;
		3'd4: em = 4'b0111; 3'd5: em = 4'b1010; default: em = 4'b1110;
	endcase
wire [7:0] fc37_init = {sw_plus3, sw_mtask, 1'b0, !sw_d5_mem, em};
wire [7:0] ff37_init = sw_boot_bios ? 8'h00 : 8'h23;
wire [7:0] p7_init = (sw_reset_to == 2'd3) ? 8'h30 : (sw_reset_to == 2'd2) ? 8'h10 : 8'h00;
wire [1:0] hw_btn = mcu_btns[1:0];

// ---------- General Sound (gs.v of core-baseconf: z80-silicon at 14 MHz, ports #BB / #B3) ----------
// Its ROM (gs105b.rom, core.json at 80000000) and RAM: port 2 of baseconf_storage (the low 64 KB in block RAM,
// the rest in the SDRAM), as core-baseconf. OSD General Sound Off: reset, its ports do not answer, no sound.
wire [15:0] cpu_a;
wire cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n;
wire [20:0] gs_addr;
wire [7:0] gs_mdi, gs_mdo, gs_do_i, gs_do;
wire gs_rd_n, gs_wr_n, gs_done, gs_oe_i, gs_oe;
wire gs_req = !gs_rd_n || !gs_wr_n;
wire signed [14:0] gs_l, gs_r;
// ---------- OPL4 (ZXM-MoonSound, opl4_kg of core-baseconf): the declarations for the storage ----------
// The FL item "OPL4 ROM" (slot 6: 0-3 are the floppies, 4-5 the hard disks, the slots are shared by F and FL
// items): the YRW801 ROM into the sample memory (port 2 of the storage, at 400000)
wire fl_act = ld_active && ld_kind == 2'd2 && ld_slot == 8'd6;
wire fl_wr = ld_wr && fl_act;
wire [21:0] opl4_mem_addr;
wire opl4_mem_req, opl4_mem_we, opl4_mem_ack;
wire [7:0] opl4_mem_wdata;
wire [15:0] opl4_mem_rdata;

// ---------- the ROM loader and the storage (SDRAM) ----------
wire ld_rom_act = ld_active && ld_kind == 2'd0;
wire ld_rom_wr = ld_wr && ld_kind == 2'd0;
wire storage_busy, rom_req, rom_done, rom_wr;
wire [7:0] cpu_dout, rom_din;
wire [18:0] rom_addr;
wire [7:0] rom_q;
// the storage and its SDRAM controller: reset by the PLL lock and the reset keys (as core-baseconf)
reg [1:0] storage_key_rst = 2'b00;
always @(posedge clk_sys) storage_key_rst <= {storage_key_rst[0], sw_reset | hw_btn[0]};
baseconf_storage storage(
	.clk(clk_sys), .reset(!locked || storage_key_rst[1]), .sdram_init_n(locked),
	.rom_req(rom_req), .rom_wr(rom_wr), .rom_addr(rom_addr), .rom_din(rom_din), .rom_dout(rom_q), .rom_done(rom_done),
	.gs_req(gs_req), .gs_wr(!gs_wr_n), .gs_addr(gs_addr), .gs_din(gs_mdo), .gs_dout(gs_mdi), .gs_done(gs_done),
	.loader_act(ld_rom_act), .loader_wr(ld_rom_wr), .loader_addr(ld_addr), .loader_data(ld_data),
	.fl_wr(fl_wr), .fl_a(ld_addr), .fl_d(ld_data),
	.opl_addr(opl4_mem_addr), .opl_req(opl4_mem_req), .opl_we(opl4_mem_we), .opl_wdata(opl4_mem_wdata),
	.opl_ack(opl4_mem_ack), .opl_rdata(opl4_mem_rdata),
	.busy(storage_busy), .fault(), .sdram_clk(),
	.sdram_a(SDR_A), .sdram_ba(SDR_BA), .sdram_dqm(SDR_DQM),
	.sdram_ras_n(SDR_RAS_N), .sdram_cas_n(SDR_CAS_N), .sdram_we_n(SDR_WE_N), .sdram_dq(SDR_DQ)
);

// machine reset: the PLL, the loader, the storage not ready, the mcu busy, Reset (F12) and the button
reg [1:0] rst_s = 2'b11;
always @(posedge clk_bus) rst_s <= {rst_s[0], areset | ld_rom_act | storage_busy | mcu_busy | sw_reset | hw_btn[0]};
wire machine_reset = rst_s[1];
reg magic = 1'b0;
always @(posedge clk_bus) magic <= sw_magic | hw_btn[1];

// ---------- keyboard: USB report -> the Spectrum matrix ----------
wire [7:0] kbd_a;
wire [5:0] kbd_do;
wire [7:0] joy_do;
hid_parser hid_parser(
	.CLK				(clk_bus),
	.RESET			(areset),
	.KB_STATUS		(mcu_kbd[7:0]),
	.KB_DAT0			(mcu_kbd[15:8]),
	.KB_DAT1			(mcu_kbd[23:16]),
	.KB_DAT2			(mcu_kbd[31:24]),
	.KB_DAT3			(mcu_kbd[39:32]),
	.KB_DAT4			(mcu_kbd[47:40]),
	.KB_DAT5			(mcu_kbd[55:48]),
	.KB_SCANCODE	(8'd0),
	.KB_SCANCODE_UPD(1'b0),
	.JOY_TYPE_L		(sw_joy_l),      // Kempston -> JOY_DO, the others -> keys of the matrix
	.JOY_TYPE_R		(sw_joy_r),
	.JOY_L			(mcu_joy_l[12:0]),
	.JOY_R			(mcu_joy_r[12:0]),
	.KB_TYPE			(1'b1),
	.A					(kbd_a),
	.JOY_DO			(joy_do),
	.KB_DO			(kbd_do),
	.RTC_A			(8'd0),
	.RTC_DI			(8'd0),
	.RTC_DO_IN		(8'd0),
	.RTC_DO_OUT		(),
	.RTC_WR			(1'b0),
	.RTC_RD			(1'b0)
);

// Kempston #1F: 000 F U D L R (JOY_DO bits 0..4 of the pad set to Kempston; its bits 5..7, the extra buttons,
// stay off: Pentagon reads 0 there)
wire [4:0] kjoy = joy_do[4:0];

// ---------- mouse: USB -> kg_cursor -> Kempston (as core-zxuno) ----------
reg ms_upd = 1'b0;
always @(posedge clk_bus) if (mcu_ms_wr) ms_upd <= ~ms_upd;
wire [7:0] cursor_x, cursor_y;
wire [3:0] cursor_z;
wire [2:0] cursor_b;
kg_cursor #(.Z_W(4), .Z_NEG(1), .Z_ACC(1)) cursor(
	.clk				(clk_bus),
	.ms_x				(ms_x),
	.ms_y				(ms_y),
	.ms_z				(mcu_ms_z[3:0]),
	.ms_b				(mcu_ms_b[2:0]),
	.ms_upd			(ms_upd),
	.x					(cursor_x),
	.y					(cursor_y),
	.z					(cursor_z),
	.b					(cursor_b)
);

// tape in
reg tape_in_r = 1'b0;
always @(posedge clk_bus) tape_in_r <= TAPE_IN;

// ---------- General Sound: the processor (declarations above the storage) ----------
reg gs_ce = 1'b0;
always @(posedge clk_bus) gs_ce <= !gs_ce;
reg [1:0] gs_rst = 2'b11;
always @(posedge clk_bus) gs_rst <= {gs_rst[0], machine_reset | sw_gs_off};
gs gs(.CLK(clk_bus), .RESET(gs_rst[1]), .CE(gs_ce), .CE_N(!gs_ce), .MEM_WAIT(gs_req && !gs_done), .SAMPLE_T(),
	.A(cpu_a), .DI(cpu_dout), .DO(gs_do_i), .OE(gs_oe_i), .WR_n(cpu_wr_n), .RD_n(cpu_rd_n),
	.IORQ_n(cpu_iorq_n | sw_gs_off), .M1_n(cpu_m1_n), .MA(gs_addr), .MDI(gs_mdi), .MDO(gs_mdo),
	.MRFSH_n(), .MWE_n(gs_wr_n), .MRD_n(gs_rd_n), .OUT_L(gs_l), .OUT_R(gs_r));
assign gs_oe = gs_oe_i && !sw_gs_off;
assign gs_do = gs_do_i;

// ---------- OPL4: #C4..#C7 FM, #7E / #7F wave, not in TR-DOS; on clk_sys (84 MHz) as core-baseconf ----------
wire cpu_dos;
wire opl4_sel, opl4_irq;
wire [7:0] opl4_do_bus;
wire signed [15:0] opl4_l, opl4_r;
reg [7:0] opl4_do_r = 8'hFF;
always @(posedge clk_bus) opl4_do_r <= opl4_do_bus;
wire opl4_oe = opl4_sel && !cpu_rd_n && !cpu_iorq_n && !sw_opl4_off;
reg opl4_irq_r = 1'b0;
always @(posedge clk_bus) opl4_irq_r <= opl4_irq && !sw_opl4_off;
reg [1:0] opl4_rst_s = 2'b11;
always @(posedge clk_sys) opl4_rst_s <= {opl4_rst_s[0], machine_reset || fl_act || sw_opl4_off};
opl4_kg opl4(.CLK(clk_sys), .CLK28(clk_bus), .RESET(opl4_rst_s[1]),
	.A(cpu_a[7:0]), .DI(cpu_dout), .DO(opl4_do_bus), .IORQ_n(cpu_iorq_n || sw_opl4_off), .M1_n(cpu_m1_n),
	.RD_n(cpu_rd_n), .WR_n(cpu_wr_n), .DOS(cpu_dos), .INTERP(!sw_opl4_nointerp), .SEL(opl4_sel), .IRQ(opl4_irq),
	.MEM_ADDR(opl4_mem_addr), .MEM_REQ(opl4_mem_req), .MEM_WE(opl4_mem_we), .MEM_WDATA(opl4_mem_wdata),
	.MEM_ACK(opl4_mem_ack), .MEM_RDATA(opl4_mem_rdata),
	.OUT_L(opl4_l), .OUT_R(opl4_r), .SAMPLE_T());
// OUT_L / R of clk_sys (held for a sample period) into clk_bus registers, at half
reg signed [15:0] opl4_l_r = 16'sd0, opl4_r_r = 16'sd0;
always @(posedge clk_bus) begin
	opl4_l_r <= sw_opl4_off ? 16'sd0 : opl4_l;
	opl4_r_r <= sw_opl4_off ? 16'sd0 : opl4_r;
end

// ---------- the machine ----------
wire [21:0] mem_a;
wire mem_rd, mem_wr, mem_oe_n;
wire [7:0] mem_d, mem_q;
wire dot_we, line_start;
wire [9:0] dot_x;
wire [8:0] dot_line;
wire [17:0] dot_rgb;
wire [15:0] audio_l, audio_r;          // the machine (positive, 0..32144)
wire [15:0] mix_l, mix_r;              // + General Sound
wire tape_out;

p4096 p4096 (
	.clk				(clk_bus),
	.reset			(machine_reset),
	.turbo			(sw_cpu),
	.turbo14_wait	(!sw_turbo_nowait),
	.int_firm		(sw_int_firm),
	.int_xj3			(sw_int_xj3),
	.fe37_init		({sw_giga, sw_flashcol, sw_col512, sw_ink512}),
	.pal_en			(!sw_pal_off),
	.fc37_init		(fc37_init),
	.ff37_init		(ff37_init),
	.p7_init			(p7_init),
	.dos_init		(sw_reset_to == 2'd2),
	.gl_init			(sw_reset_to != 2'd0),
	.nmi				(magic),
	.kbd_a			(kbd_a),
	.kbd_d			(kbd_do[4:0]),
	.joy				(kjoy),
	.tape_in			(tape_in_r),
	.mouse_en		(!sw_mouse_off),
	.ms_x				(cursor_x),
	.ms_y				(cursor_y),
	.ms_z				(cursor_z),
	.ms_b				(cursor_b),
	.sd_en			(!sw_sd_off),
	.fdd_wp			(img_wp[3:0]),
	.fdd_img_mounted(sdc_img_mounted[3:0]),
	.fdd_img_size	(sdc_img_size),
	.fdd_sdc_rd		(fdd_rd),
	.fdd_sdc_wr		(fdd_wr),
	.fdd_sdc_sector(fdd_sector),
	.fdd_sdc_busy	(sdc_busy && fdd_own),
	.fdd_sdc_done	(sdc_done && fdd_own),
	.fdd_sdc_byte_addr(sdc_byte_addr),
	.fdd_sdc_byte_in_strobe(sdc_byte_in_strobe && fdd_own),
	.fdd_sdc_byte_in_data(sdc_byte_in_data),
	.fdd_sdc_byte_out_data(fdd_out_data),
	.fdd_active		(fdd_active),
	.ide_a			(ide_a),
	.ide_cs_n		(ide_cs_n),
	.ide_rd_n		(ide_rd_n),
	.ide_wr_n		(ide_wr_n),
	.ide_dout		(ide_dout),
	.ide_din			(ide_din),
	.rtc_a			(rtc_a),
	.rtc_di			(rtc_di),
	.rtc_wr			(rtc_wr),
	.rtc_do			(rtc_do),
	.tape_out		(tape_out),
	.mem_a			(mem_a),
	.mem_rd			(mem_rd),
	.mem_wr			(mem_wr),
	.mem_d			(mem_d),
	.mem_oe_n		(mem_oe_n),
	.mem_q			(mem_q),
	.rom_req			(rom_req),
	.rom_addr		(rom_addr),
	.rom_wr			(rom_wr),
	.rom_din			(rom_din),
	.rom_q			(rom_q),
	.rom_done		(rom_done),
	.dot_we			(dot_we),
	.dot_x			(dot_x),
	.dot_line		(dot_line),
	.dot_rgb			(dot_rgb),
	.line_start		(line_start),
	.audio_l			(audio_l),
	.audio_r			(audio_r),
	.midi_tx			(MIDI_TX),
	.cpu_a			(cpu_a),
	.cpu_dout		(cpu_dout),
	.cpu_iorq_n		(cpu_iorq_n),
	.cpu_rd_n		(cpu_rd_n),
	.cpu_wr_n		(cpu_wr_n),
	.ext_int			(opl4_irq_r),
	.cpu_dos			(cpu_dos),
	.ext_sel			(opl4_sel && !sw_opl4_off),
	.ext_oe			(gs_oe || opl4_oe),
	.ext_do			(opl4_oe ? opl4_do_r : gs_do),
	.cpu_m1_n		(cpu_m1_n),
	.int_n_o			()
);
assign TAPE_OUT = tape_out;

// ---------- Nemo IDE: the CF card of the board and hdf_ata (images on SD1) ----------
// As core-baseconf (ide_mux of the Profi core): the card is device 0 with HDD Master = CF card and gets the
// strobes then; the read data come from the card when it is device 0 and selected, else from hdf_ata (device 0
// with HDD Master = Image, device 1 always).
wire hdf_dev, hdf_dev1_here, hdf_led;
wire [1:0] hdf_rd, hdf_wr;
wire [31:0] hdf_sector;
wire [7:0] hdf_out_data;
wire hdf_own = sdc_slot[2:1] == 2'b10;
wire cf_sel = !sw_hdd_image;
assign WA = ide_a;
assign WCS_N = ide_cs_n | {2{!cf_sel}};
assign WRD_N = ide_rd_n || !cf_sel;
assign WWR_N = ide_wr_n || !cf_sel;
assign WRESET_N = !machine_reset;
assign WD = (!ide_wr_n && cf_sel) ? ide_dout : 16'hZZZZ;
assign ide_din = (cf_sel && !hdf_dev) ? WD : hdf_dout;
// one request at a time, the lowest slot first (img_sdc): the floppies (0-3) before the hard disks (4, 5)
assign sdc_rd = {2'b00, hdf_rd, fdd_rd};
assign sdc_wr = {2'b00, hdf_wr, fdd_wr};
assign sdc_sector = (fdd_rd != 4'd0 || fdd_wr != 4'd0) ? fdd_sector : hdf_sector;
assign sdc_byte_out_data = fdd_own ? fdd_out_data : hdf_out_data;
hdf_ata #(.ENABLE_RDB(0)) hdf_ata(.clk(clk_bus), .reset(areset), .ata_reset(machine_reset), .dev0_en(sw_hdd_image),
	.dev(hdf_dev), .dev1_here(hdf_dev1_here), .a(ide_a), .cs_n(ide_cs_n), .rd_n(ide_rd_n), .wr_n(ide_wr_n),
	.din(ide_dout), .dout(hdf_dout), .img_mounted(sdc_img_mounted[5:4]), .img_size(sdc_img_size),
	.sdc_rd(hdf_rd), .sdc_wr(hdf_wr), .sdc_sector(hdf_sector), .sdc_busy(sdc_busy && hdf_own),
	.sdc_done(sdc_done && hdf_own), .sdc_error(sdc_error), .sdc_byte_in_strobe(sdc_byte_in_strobe && hdf_own),
	.sdc_byte_addr(sdc_byte_addr), .sdc_byte_in_data(sdc_byte_in_data), .sdc_byte_out_data(hdf_out_data),
	.led(hdf_led));

// ---------- SRAM ----------
assign MA = mem_a[21:1];
assign MRD_N = {2{mem_oe_n}};
assign MD = mem_oe_n ? {mem_d, mem_d} : 16'hZZZZ;
// /WE: ODDR2, low from the falling edge in the first clock of the write to the falling edge in the second: D1 is
// taken at the falling edge of the first clock (mem_wr = 1), D0 at the rising edge that ends it (mem_wr still 1
// before that edge), D1 again at the falling edge of the second (mem_wr = 0). Address and data are stable for both
// clocks: 17.8 ns of setup and of hold around the pulse of 35.7 ns.
wire we_lo = mem_wr && !mem_a[0];
wire we_hi = mem_wr && mem_a[0];
ODDR2 #(.INIT(1'b1)) oddr_we0(.Q(MWR_N[0]), .C0(clk_bus), .C1(~clk_bus), .CE(1'b1), .D0(!we_lo), .D1(!we_lo),
	.R(1'b0), .S(1'b0));
ODDR2 #(.INIT(1'b1)) oddr_we1(.Q(MWR_N[1]), .C0(clk_bus), .C1(~clk_bus), .CE(1'b1), .D0(!we_hi), .D1(!we_hi),
	.R(1'b0), .S(1'b0));
// the input flip-flops: the byte of a read issued in the clock before
reg [15:0] md_q = 16'd0;
reg md_lane = 1'b0;
always @(posedge clk_bus) begin
	md_q <= MD;
	md_lane <= mem_a[0];
end
assign mem_q = md_lane ? md_q[15:8] : md_q[7:0];

// ---------- video: line doubler, OSD, HDMI ----------
wire [7:0] video_r, video_g, video_b, osd_r, osd_g, osd_b;
wire video_hs, video_vs, video_de, osd_hs, osd_vs, osd_de;
p4096_scandbl scandbl (
	.clk				(clk_bus),
	.dot_we			(dot_we),
	.dot_x			(dot_x),
	.dot_line		(dot_line),
	.dot_rgb			(dot_rgb),
	.line_start		(line_start),
	.full				(sw_video_full),
	.r					(video_r),
	.g					(video_g),
	.b					(video_b),
	.hs				(video_hs),
	.vs				(video_vs),
	.de				(video_de)
);

kg_l2_osd_overlay overlay(
	.wclk				(clk_bus),
	.osd_wr			(osd_wr),
	.osd_waddr		(osd_waddr),
	.osd_wdata		(osd_wdata),
	.osd_en			(osd_en),
	.osd_fg			(osd_fg),
	.osd_bg			(osd_bg),
	.osd_alpha		(osd_alpha),
	.osd_px			(osd_px),
	.osd_py			(osd_py),
	.osd_pw			(osd_pw),
	.osd_ph			(osd_ph),
	.osd_place		(osd_place),
	.osd_zoom		(osd_zoom),
	.icon_on			(8'd0),
	.icon_act		(8'd0),
	.clk				(clk_bus),
	.rgb_i			({video_r, video_g, video_b}),
	.hs_i				(video_hs),
	.vs_i				(video_vs),
	.de_i				(video_de),
	.rgb_o			({osd_r, osd_g, osd_b}),
	.hs_o				(osd_hs),
	.vs_o				(osd_vs),
	.de_o				(osd_de)
);

// the VGA DAC: the picture of the core with the OSD, or the FT812 (its pins high impedance then)
assign VGA_R = mcu_ft_vga_on ? 8'bZZZZZZZZ : osd_r;
assign VGA_G = mcu_ft_vga_on ? 8'bZZZZZZZZ : osd_g;
assign VGA_B = mcu_ft_vga_on ? 8'bZZZZZZZZ : osd_b;
assign VGA_HS = mcu_ft_vga_on ? 1'bZ : osd_hs ^ ~vga_sync_pos[0];   // positive syncs of the doubler
assign VGA_VS = mcu_ft_vga_on ? 1'bZ : osd_vs ^ ~vga_sync_pos[1];
assign V_CLK = mcu_ft_vga_on ? FT_CLK : v_clk;

// no ADC on the Go
wire signed [15:0] adc_mix_l = 16'sd0, adc_mix_r = 16'sd0;

// ---------- the mix: the machine at half + General Sound (15 bits signed) + ADC, saturated ----------
function [15:0] sat16(input signed [17:0] x);
	sat16 = (x > 18'sd32767) ? 16'h7FFF : (x < -18'sd32768) ? 16'h8000 : x[15:0];
endfunction
reg [15:0] mix_l_r = 16'd0, mix_r_r = 16'd0;
always @(posedge clk_bus) begin
	mix_l_r <= sat16($signed({3'b000, audio_l[15:1]}) + (sw_gs_off ? 18'sd0 : $signed({{3{gs_l[14]}}, gs_l})) +
	                 $signed({{2{adc_mix_l[15]}}, adc_mix_l}) + $signed({{3{opl4_l_r[15]}}, opl4_l_r[15:1]}));
	mix_r_r <= sat16($signed({3'b000, audio_r[15:1]}) + (sw_gs_off ? 18'sd0 : $signed({{3{gs_r[14]}}, gs_r})) +
	                 $signed({{2{adc_mix_r[15]}}, adc_mix_r}) + $signed({{3{opl4_r_r[15]}}, opl4_r_r[15:1]}));
end
assign mix_l = mix_l_r;
assign mix_r = mix_r_r;

// ---------- i2s DAC ----------
kg_pcm5102 #(.DIV_BITS(1)) PCM5102(
	.clk				(clk_bus),
	.reset			(areset),
	.left				(mix_l),
	.right			(mix_r),
	.din				(DAC_DAT),
	.bck				(DAC_BCK),
	.lrck				(DAC_LRCK)
);
assign DAC_MUTE = 1'b1;   // 1 = not muted

endmodule
