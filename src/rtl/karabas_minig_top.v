`timescale 1ns / 1ps
/*-------------------------------------------------------------------------------------------------------------------
-- Pentagon-4096 core (p4096) for Karabas Mini rev.G
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
-- core-baseconf (port 1; GS / OPL4 ports tied off in Ф1); the CPU waits (WAIT) for each ROM byte.
-- Video: p4096 -> p4096_scandbl (720 x 576 of 896 x 640 at 28 MHz) -> OSD -> HDMI.
-- Input: USB keyboard (hid_parser -> the matrix), joysticks of kg_mcu2 -> Kempston #1F.
------------------------------------------------------------------------------------------------------------------*/

module karabas_minig_top (
	//------------------ global clock --------
	input wire 				CLK_50MHZ,

	//------------------ esp8266 uart --------
	inout wire 				UART_RX,
	inout wire 				UART_TX,
	inout wire 				UART_CTS,

	//------------------ sram ----------------
	output wire [20:0] 	MA,
	inout wire [15:0] 	MD,
	output wire [1:0] 	MWR_N,
	output wire [1:0] 	MRD_N,

	//------------------ sdram ---------------
	output wire [1:0] 	SDR_BA,
	output wire [12:0] 	SDR_A,
	output wire 			SDR_CLK,
	output wire [1:0] 	SDR_DQM,
	output wire 			SDR_WE_N,
	output wire 			SDR_CAS_N,
	output wire 			SDR_RAS_N,
	inout wire [15:0] 	SDR_DQ,

	//------------------ sd2 -----------------
	output wire 			SD_CS_N,
	output wire 			SD_CLK,
	inout wire 				SD_DI,
	inout wire 				SD_DO,
	input wire 				SD_DET_N,

	//------------------ ft812 rgb + sync ----
	input wire [7:0] 		VGA_R,
	input wire [7:0] 		VGA_G,
	input wire [7:0] 		VGA_B,
	input wire 				VGA_HS,
	input wire 				VGA_VS,

	//------------------ dvi / hdmi ----------
	output wire [3:0] 	TMDS_P,
	output wire [3:0] 	TMDS_N,

	//------------------ ft812 spi and ctl ---
	inout wire 				FT_SPI_CS_N,
	inout wire 			FT_SPI_SCK,
	input wire 				FT_SPI_MISO,
	inout wire 			FT_SPI_MOSI,
	input wire 				FT_INT_N,
	input wire 				FT_CLK,
	input wire 				FT_DE,
	output wire 			FT_CLK_OUT,

	//------------------ cf card -------------
	output wire [2:0] 	WA,
	output wire [1:0] 	WCS_N,
	output wire 			WRD_N,
	output wire 			WWR_N,
	output wire 			WRESET_N,
	inout wire [15:0] 	WD,

	//------------------ analog in/out -------
	output wire 			TAPE_OUT,
	input wire 				TAPE_IN,

	//------------------ i2s dac -------------
	output wire          DAC_BCK,
	output wire          DAC_WS,
	output wire          DAC_DAT,

	//------------------ adc -----------------
	output wire 			ADC_CLK,
	inout wire 				ADC_BCK,
	inout wire 				ADC_LRCK,
	input wire 				ADC_DOUT,

	//------------------ esp32 i2s and cs ----
	inout wire           ESP32_SPI_CS_N,
	input wire           ESP32_PCM_BCK,
	input wire           ESP32_PCM_RLCK,
	input wire           ESP32_PCM_DAT,

	//------------------ mcu spi -------------
	input wire 				MCU_CS_N,
	input wire 				MCU_SCK,
	input wire 				MCU_MOSI,
	output wire 			MCU_MISO,
	inout wire [5:0] 		MCU_IO,  // [0] burst cs_n, [1] burst ready, [2] sd2 cs_n, [3] ft cs_n

	//------------------ midi ----------------
	output wire 			MIDI_TX,

	//------------------ optional flash ------
	output wire 			FLASH_CS_N,
	input wire  			FLASH_DO,
	output wire 			FLASH_DI,
	output wire 			FLASH_SCK,
	output wire 			FLASH_WP_N,
	output wire 			FLASH_HOLD_N
);

// T3 (FLASH_CS_N) = 0: the ~CS of the SDRAM on the Mini rev G2 (karabas-go-notes mini-g2-sdram-cs)
assign FLASH_CS_N   = 1'b0;
assign FLASH_DI     = 1'b1;
assign FLASH_SCK    = 1'b0;
assign FLASH_WP_N   = 1'b1;
assign FLASH_HOLD_N = 1'b1;

assign WA = 3'b000;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'hZZZZ;

assign ESP32_SPI_CS_N = 1'b1;
assign UART_RX = 1'bz;
assign UART_TX = 1'bz;
assign UART_CTS = 1'bz;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;
assign SD_DI = 1'bz;
assign SD_DO = 1'bz;
assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;
assign MIDI_TX = 1'b1;

// ---------- clocks: VCO 50 * 37 / 2 = 925 MHz: clk_sys /11 84.09, clk_8 /116 7.97, clk_bus /33 28.03, /77 12.01
wire clk_sys, clk_8mhz, clk_bus, clk_bus_pll;
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
BUFG bufg_clk_bus(.I(clk_bus_pll), .O(clk_bus));

// the FT812 must always get a clock (karabas-go-notes ft-clk-out-required)
ODDR2 u_ft_clk (.Q(FT_CLK_OUT), .C0(clk_8mhz), .C1(~clk_8mhz), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// SDRAM clock, inverted (sdram2p of baseconf_storage runs on clk_sys)
ODDR2 sdr_clock(.Q(SDR_CLK), .C0(clk_sys), .C1(~clk_sys), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0));

assign areset = ~locked;

// ---------- MCU (link v2) ----------
wire mcu_int;
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[5:2] = 4'bzzzz;

// MCU_SCK on a global buffer (see core-tsconf); FT_SPI_SCK takes it before the BUFG
wire mcu_sck_ibufg, mcu_sck;
IBUFG ibufg_mcu_sck(.I(MCU_SCK), .O(mcu_sck_ibufg));
BUFG bufg_mcu_sck(.I(mcu_sck_ibufg), .O(mcu_sck));

wire [55:0] mcu_kbd;
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

localparam SW_N = 6;
wire [SW_N*8-1:0] softsw;
wire sw_wr;

kg_mcu2 #(
	.CAPS(16'h0000),
	.SW_N(SW_N),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(0),
	.ENABLE_PORTS(4'b0000),
	.ENABLE_RTC(0),
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
	.MCU_SPI_FT_SS	(MCU_IO[3]),
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
	.MS_X				(),
	.MS_Y				(),
	.MS_Z				(),
	.MS_B				(),
	.MS_WR			(),
	.JOY_L			(mcu_joy_l),
	.JOY_R			(mcu_joy_r),
	.JOY_WR			(),
	.PS2_CMD			(16'h0000),
	.PS2_CMD_WR		(1'b0),
	.LD_KIND			(ld_kind),
	.LD_SLOT			(),
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
	.SDC_IMG_MOUNTED(),
	.SDC_IMG_SIZE	(),
	.SDC_RD			(8'd0),
	.SDC_WR			(8'd0),
	.SDC_SECTOR		(32'd0),
	.SDC_BUSY		(),
	.SDC_DONE		(),
	.SDC_ERROR		(),
	.SDC_SLOT		(),
	.SDC_BYTE_IN_STROBE(),
	.SDC_BYTE_ADDR	(),
	.SDC_BYTE_IN_DATA(),
	.SDC_BYTE_OUT_DATA(8'd0),
	.IMG_WP			(),
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
	.RTC_A			(8'd0),
	.RTC_DI			(8'd0),
	.RTC_CS			(1'b0),
	.RTC_WR_N		(1'b1),
	.MATRIX_CMD		(),
	.MATRIX_CMD_WR	(),
	.DEBUG_ADDR		(16'd0),
	.DEBUG_DATA		(16'd0),
	.RTC_DO			(),
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

// ---------- OSD switches (core.json "osd" "index"): switch n = softsw[n*8 +: 8] ----------
wire sw_reset = softsw[0];               // 0 Reset (F12)
wire sw_magic = softsw[8];               // 1 Magic (F11): NMI
wire [1:0] sw_cpu = softsw[2*8 +: 2];    // 2 Turbo Off (3.5) / 7 / 14 MHz
wire [1:0] sw_int = softsw[3*8 +: 2];    // 3 INT Pentagon / Pent -2T / Firm / Firm -2T (bit 1 Firm, bit 0 the XJ3 jumper)
wire sw_int_firm = sw_int[1];
wire sw_int_xj3 = sw_int[0];
wire [2:0] sw_joy_l = softsw[4*8 +: 3];  // 4, 5 Joystick L / R: Kempston / Sinclair1 / Sinclair2 / Cursor / QAOPM / QAOPS
wire [2:0] sw_joy_r = softsw[5*8 +: 3];  //   (the codes of JOY_TYPE of hid_parser, as core-tsconf / core-profi)
wire [1:0] hw_btn = mcu_btns[1:0];

// ---------- the ROM loader and the storage (SDRAM) ----------
wire ld_rom_act = ld_active && ld_kind == 2'd0;
wire ld_rom_wr = ld_wr && ld_kind == 2'd0;
wire storage_busy, rom_req, rom_done;
wire [18:0] rom_addr;
wire [7:0] rom_q;
// the storage and its SDRAM controller: reset by the PLL lock and the reset keys (as core-baseconf)
reg [1:0] storage_key_rst = 2'b00;
always @(posedge clk_sys) storage_key_rst <= {storage_key_rst[0], sw_reset | hw_btn[0]};
baseconf_storage storage(
	.clk(clk_sys), .reset(!locked || storage_key_rst[1]), .sdram_init_n(locked),
	.rom_req(rom_req), .rom_wr(1'b0), .rom_addr(rom_addr), .rom_din(8'd0), .rom_dout(rom_q), .rom_done(rom_done),
	.gs_req(1'b0), .gs_wr(1'b0), .gs_addr(21'd0), .gs_din(8'd0), .gs_dout(), .gs_done(),
	.loader_act(ld_rom_act), .loader_wr(ld_rom_wr), .loader_addr(ld_addr), .loader_data(ld_data),
	.fl_wr(1'b0), .fl_a(32'd0), .fl_d(8'd0),
	.opl_addr(22'd0), .opl_req(1'b0), .opl_we(1'b0), .opl_wdata(8'd0), .opl_ack(), .opl_rdata(),
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

// tape in
reg tape_in_r = 1'b0;
always @(posedge clk_bus) tape_in_r <= TAPE_IN;

// ---------- the machine ----------
wire [21:0] mem_a;
wire mem_rd, mem_wr, mem_oe_n;
wire [7:0] mem_d, mem_q;
wire dot_we, line_start;
wire [9:0] dot_x;
wire [8:0] dot_line;
wire [17:0] dot_rgb;
wire [15:0] audio_l, audio_r;
wire tape_out;

p4096 p4096 (
	.clk				(clk_bus),
	.reset			(machine_reset),
	.turbo			(sw_cpu),
	.int_firm		(sw_int_firm),
	.int_xj3			(sw_int_xj3),
	.nmi				(magic),
	.kbd_a			(kbd_a),
	.kbd_d			(kbd_do[4:0]),
	.joy				(kjoy),
	.tape_in			(tape_in_r),
	.tape_out		(tape_out),
	.mem_a			(mem_a),
	.mem_rd			(mem_rd),
	.mem_wr			(mem_wr),
	.mem_d			(mem_d),
	.mem_oe_n		(mem_oe_n),
	.mem_q			(mem_q),
	.rom_req			(rom_req),
	.rom_addr		(rom_addr),
	.rom_q			(rom_q),
	.rom_done		(rom_done),
	.dot_we			(dot_we),
	.dot_x			(dot_x),
	.dot_line		(dot_line),
	.dot_rgb			(dot_rgb),
	.line_start		(line_start),
	.audio_l			(audio_l),
	.audio_r			(audio_r),
	.cpu_a			(),
	.cpu_m1_n		(),
	.int_n_o			()
);
assign TAPE_OUT = tape_out;

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

// FT_CLK: the pixel clock of the FT812 (the menus of the mcu on HDMI)
wire ft_clk_ibufg, ft_clk_int;
IBUFG ibufg_ft_clk(.I(FT_CLK), .O(ft_clk_ibufg));
BUFG bufg_ft_clk(.I(ft_clk_ibufg), .O(ft_clk_int));

wire [7:0] hdmi_freq;
kg_hdmi_ft #(.CLKRATE(28030303), .REF_MHZ(8'd28), .SAMPLERATE(48000), .OUTPUT_REG(1)) hdmi_top(
	.clk				(ft_clk_int),
	.clk_ref			(clk_bus),
	.clk_ref_pll	(clk_bus_pll),
	.clk_8			(clk_8mhz),
	.reset			(areset),
	.vga_rgb			({osd_r, osd_g, osd_b}),
	.vga_hs			(osd_hs),
	.vga_vs			(osd_vs),
	.vga_de			(osd_de),
	.ft_rgb			({VGA_R, VGA_G, VGA_B}),
	.ft_hs			(VGA_HS),
	.ft_vs			(VGA_VS),
	.ft_de			(FT_DE),
	.ft_sel			(mcu_ft_vga_on),
	.audio_en		(~dvi_only),
	.audio_l			(audio_l),
	.audio_r			(audio_r),
	.tmds_p			(TMDS_P),
	.tmds_n			(TMDS_N),
	.freq				(hdmi_freq)
);

// ---------- i2s DAC ----------
kg_pcm5102 #(.DIV_BITS(2)) PCM5102(
	.clk				(clk_bus),
	.reset			(areset),
	.left				(audio_l),
	.right			(audio_r),
	.din				(DAC_DAT),
	.bck				(DAC_BCK),
	.lrck				(DAC_WS)
);

endmodule
