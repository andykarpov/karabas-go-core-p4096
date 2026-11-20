`timescale 1ns / 1ps
`default_nettype none
/*
 Pentagon-4096 machine, board free (docs/PLAN.md Ф1: Pentagon-128 part).

 clk = 28 MHz (clk_bus). The CPU (z80-silicon, ports of T80pa) runs on clk with the enables of 3.5 / 7 / 14 MHz,
 tied to the raster: a T-state of 3.5 MHz = 8 clocks = 2 points, it starts with px[0] = 0, ph = 0.

 Memory bus (the RAM, 4 MB, byte address {page[7:0], A13..A0}; the top maps it to the SRAM):
   mem_a / mem_rd / mem_wr / mem_d are registers; a read is issued for one clock (mem_rd = 1) and its byte
   comes as mem_q in the next clock; a write keeps mem_a / mem_d for two clocks, mem_wr = 1 in the first (the
   top makes /WE in the middle of them). Slots: the video at c5 % 8 = 0 (p4096_video.v), the CPU else; the
   writes of the CPU go through a one entry buffer (they never wait), its reads wait (WAIT) only when they
   come at a video slot in turbo 14.
 ROM (16 KB pages, rom_addr = {page, A13..A0}): rom_req while the CPU reads it, rom_done when rom_q holds the
   byte (baseconf_storage in the SDRAM); WAIT until then.

 Ф1: #FE / #F6 (border, its brightness by the address, beeper, tape), #7FFD (128K, the D5 latch), #xxFF read
 (attribute port), #1F Kempston, AY / TurboSound #FFFD / #BFFD, the TR-DOS ROM switch (no VG93 yet), INT of
 Pentagon-128 / Firm (+ the XJ3 correction).
*/
module p4096 (
	input  wire        clk,
	input  wire        reset,         // holds the CPU and the ports

	// settings (OSD)
	input  wire [1:0]  turbo,         // 0 3.5, 1 7, 2 14 MHz
	input  wire        turbo14_wait,  // 14 MHz: 1 = Original (WAITP: RAM accesses wait for their DRAM slot)
	input  wire        int_firm,      // OSD: the value of #FE37 D7 (INT_SEL) at reset and when the OSD changes it
	input  wire [6:0]  fe37_init,     // OSD: #FE37 D0-D6 at reset and when the OSD changes them (BIOS v4.2: 07)
	input  wire        pal_en,        // OSD Palette: 0 = the standard 16 colours (XJ1-XJ3 of the TopBoard)
	input  wire [7:0]  fc37_init,     // OSD: #FC37 at reset (memory scheme, D5 latch, multitasking, +3)
	input  wire [7:0]  ff37_init,     // #FF37 at reset: without BIOS 03 (BIOS ROM off, Gluk latch free), as BIOS leaves it
	input  wire [7:0]  p7_init,       // #7FFD at reset (OSD Reset to: Menu-128 00, BASIC 48 30, TR-DOS 10)
	input  wire        dos_init,      // TR-DOS at reset (OSD Reset to TR-DOS)
	input  wire        gl_init,       // the Gluk latch at reset: 1 = the normal ROM pages, 0 = Gluk Reset Service
	input  wire        int_xj3,       // the XJ3 jumper: INT 2 T earlier
	input  wire        nmi,           // Magic (the button / OSD: a rising edge starts it)

	// keyboard (hid_parser: A15..A8 in, the columns out, active low), Kempston (active high: F U D L R)
	output wire [7:0]  kbd_a,
	input  wire [4:0]  kbd_d,
	input  wire [4:0]  joy,
	input  wire        tape_in,
	// Kempston mouse (#FADF buttons, #FBDF X, #FFDF Y): kg_cursor of the top; buttons {middle, right, left} high
	input  wire        mouse_en,
	input  wire [7:0]  ms_x,
	input  wire [7:0]  ms_y,
	input  wire [3:0]  ms_z,
	input  wire [2:0]  ms_b,
	// SoundDrive / Covox (OSD)
	input  wire        sd_en,
	// CMOS (Gluk: #DFF7 address, #BFF7 data, open with #EFF7 D7): the clock registers of kg_mcu2 (RTC_A -> RTC_DO a
	// clock later; a write is RTC_CS and !RTC_WR_N for one clock)
	output reg  [7:0]  rtc_a = 8'd0,
	output wire [7:0]  rtc_di,
	output wire        rtc_wr,
	input  wire [7:0]  rtc_do,
	output reg         tape_out = 1'b0,

	// RAM
	output reg  [21:0] mem_a = 22'd0,
	output reg         mem_rd = 1'b0,
	output reg         mem_wr = 1'b0,
	output reg  [7:0]  mem_d = 8'd0,
	output reg         mem_oe_n = 1'b0,   // 1 in both clocks of a write: SRAM /OE high, the FPGA drives the data
	input  wire [7:0]  mem_q,

	// ROM
	output wire        rom_req,
	output wire [18:0] rom_addr,
	output wire        rom_wr,        // a write (static RAM, cache, the flash copy)
	output wire [7:0]  rom_din,       // its byte (from the write buffer of p4096_romcache)
	input  wire [7:0]  rom_q,
	input  wire        rom_done,

	// video (p4096_video.v)
	output wire        dot_we,
	output wire [9:0]  dot_x,
	output wire [8:0]  dot_line,
	output wire [17:0] dot_rgb,       // 6 bits a channel (p4096_video.v)
	output wire        line_start,

	// sound: signed, the sum of AY / TS, beeper and tape
	output reg  [15:0] audio_l = 16'd0,
	output reg  [15:0] audio_r = 16'd0,

	// debug / sim
	output wire [15:0] cpu_a,
	output wire [7:0]  cpu_dout,
	output wire        cpu_m1_n,
	output wire        int_n_o
);

// ---------------- raster ----------------
wire [1:0] ph;
wire [2:0] px;
wire [5:0] h;
wire [8:0] v;
wire [4:0] c5;
wire [21:0] vf_a;
wire [7:0] attr_port;
reg scr = 1'b0;
reg [2:0] border = 3'd0;
reg border_bri = 1'b0;
reg [7:0] eff7 = 8'd0;
reg [7:0] fc37 = 8'd0, fd37 = 8'd0, fe37 = 8'd0, ff37 = 8'd0;   // BIOS ports (write only)
wire int_go;
wire [4:0] scr_hi;
wire pal_we;
wire [11:0] pal_d;

p4096_video video (
	.clk(clk), .reset(1'b0), .pal_rst(reset),
	.scr(scr), .border(border), .border_bri(border_bri),
	.eff7(eff7), .fe37(fe37), .scr_hi(scr_hi), .frame_latch(int_go), .pal_en(pal_en), .pal_we(pal_we), .pal_d(pal_d),
	.vf_a(vf_a), .mem_q(mem_q),
	.ph(ph), .px(px), .h(h), .v(v), .c5(c5),
	.attr_port(attr_port),
	.dot_we(dot_we), .dot_x(dot_x), .dot_line(dot_line), .dot_rgb(dot_rgb), .line_start(line_start)
);

// ---------------- CPU clock ----------------
wire [2:0] cnt8 = {px[0], ph};
reg [1:0] turbo_r = 2'd0;
always @(posedge clk) if (cnt8 == 3'd7) turbo_r <= turbo;
// enables in the clock before the edge: the T-state of 3.5 MHz begins after cnt8 = 7
wire zpos = (turbo_r == 2'd0) ? (cnt8 == 3'd7) :
            (turbo_r == 2'd1) ? (cnt8[1:0] == 2'd3) : cnt8[0];
wire zneg = (turbo_r == 2'd0) ? (cnt8 == 3'd3) :
            (turbo_r == 2'd1) ? (cnt8[1:0] == 2'd1) : !cnt8[0];

wire [15:0] a;
wire [7:0] cpu_do;
reg  [7:0] cpu_di;
wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n;
wire wait_n;
reg int_n = 1'b1;
assign cpu_a = a;
assign cpu_dout = cpu_do;
assign cpu_m1_n = m1_n;
assign int_n_o = int_n;

z80s_t80pa cpu (
	.RESET_n(!reset), .CLK(clk), .CEN_p(zpos), .CEN_n(zneg),
	.WAIT_n(wait_n), .INT_n(int_n), .NMI_n(!nmi_p), .BUSRQ_n(1'b1),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n),
	.HALT_n(), .BUSAK_n(),
	.A(a), .DI(cpu_di), .DO(cpu_do)
);

// ---------------- ports: registers ----------------
reg [2:0] p7_page = 3'd0;      // 7FD0-2
reg spage0 = 1'b0;             // #7FFD D4: ROM 48
reg p7_d5 = 1'b0;              // 7FD5B
reg p7_d6 = 1'b0, p7_d7 = 1'b0;
reg p7_d5h = 1'b0;             // 7FD5 (DD77): D5 and not 7FD5_BLK, the memory bit
reg [2:0] dfd = 3'd0;          // #DFFD D0-D2 (DD79)
reg rr_1f = 1'b0, shrom = 1'b0, ra15m = 1'b0, fd1_4 = 1'b0, fd1_7 = 1'b0;   // #1FFD Scorpion / KAY (DD80)
reg p3_dos = 1'b0, p3_d1 = 1'b0, p3_d2 = 1'b0;                              // #1FFD +3 (DD81)
reg trap = 1'b0;               // the IN A,(n) / OUT (n),A trap (DD72, DD68:2)
wire rom_sel;                  // the CPU byte is not in the DRAM (memory map below)
reg mcache = 1'b0;             // the Magic pulse (DD143:1, about 60 ms on the board)
reg speaker = 1'b0;
reg dos = 1'b0;                // T_DOS

wire io = !iorq_n && m1_n;
wire iowr = io && !wr_n;
wire iord = io && !rd_n;
// #xxFD (DD71): A1 = 0, A2 = 1; A15 A14 A13 select
wire p_fd = !a[1] && a[2];
wire p_7ffd = p_fd && a[15:13] == 3'b011;
// /P_7FFDS: in the trap #7FFD answers on any A15 = 0 (#1FFD / #3FFD / #5FFD too): the soft decode of 128K
wire p_7ffds = p_7ffd || (trap && p_fd && !a[15]);
wire p_dffd = p_fd && a[15:13] == 3'b110;
wire p_1ffd = p_fd && a[15:13] == 3'b000;
wire p_fffd = p_fd && a[15:13] == 3'b111;
wire p_bffd = p_fd && a[15:13] == 3'b101;
// #FE / #F6 write: A0 = 0, A2 = 1, A6 = 1; read #FE: A0 = 0
wire p_fe_w = !a[0] && a[2] && a[6];
// Nemo IDE (DD155): A1 = A2 = 0, not TR-DOS; its ports are not the keyboard (until Ф4: no drive, FF)
wire p_ide = !a[1] && !a[2] && !dos;
wire p_fe_r = !a[0] && !p_ide;
// #xxFF read: A0-A7 all 1 (not in TR-DOS: the system port of the VG93)
wire p_ff = a[7:0] == 8'hFF && !dos;
// #xxF7 (DD90): A3 = 0, A2 = 1, A6 = 1; A14 A13 A12 = 110: #EFF7
wire p_eff7 = !a[3] && a[2] && a[6] && a[14:12] == 3'b110;
// BIOS ports #FC37-#FF37 (DD60), write only: A3 = A6 = A7 = 0, A2 = 1, A10 = 1; A9 A8 select
wire p_bios = !a[3] && !a[6] && !a[7] && a[2] && a[10];
// Kempston #1F: A5 = A7 = 0, A3 = 1, not TR-DOS
wire p_kj = !a[5] && !a[7] && a[3] && !dos;   // #FE (A0 = 0) has the priority in cpu_di
// CMOS (DD90 as #EFF7): #BFF7 (A14 A13 A12 = 011) data, #DFF7 (101) address; open with #EFF7 D7 (README)
wire p_rtcd = !a[3] && a[2] && a[6] && a[14:12] == 3'b011 && eff7[7];
wire p_rtca = !a[3] && a[2] && a[6] && a[14:12] == 3'b101 && eff7[7];
// Kempston mouse (/P_MOUSE, DD146): A0 = A1 = A2 = 1, A5 = 0, A6 = 1, A12 = 1, A15 = 1; A8 / A10 select
wire p_mouse = a[0] && a[1] && a[2] && !a[5] && a[6] && a[12] && a[15] && mouse_en;
// SoundDrive (standard ports of 1.05, TopBoard DD11 чек): #0F, #1F, #4F, #5F; Covox #FB; not in TR-DOS
reg [7:0] sd_a = 8'd0, sd_b = 8'd0, sd_c = 8'd0, sd_d = 8'd0, sd_fb = 8'd0;

// #FC37: EM0 D0-D1, EM1 D2-D3, 7FD5_BLK D4, HLOAD D5, MTASK_ON D6, MODE_3+ D7
wire [1:0] em0 = fc37[1:0], em1 = fc37[3:2];
wire blk = fc37[4];
wire mtask = fc37[6];
wire mode3 = fc37[7];
// RAM_48 = 7FD5B and 7FD5_BLK: D5 works as the 48K latch only with #FC37 D4 = 1
wire ram_48 = p7_d5 && blk;
wire rom_sp = ff37[0];
// /WRHR: the hard decoded writes (#7FFD D5-D7, #DFFD, #1FFD) are off in the trap and while (RAM_48 or MTASK_ON)
// with ROM_SP (docs/HW.md "Ловушка", чек полярности)
wire wrhr = !trap && !((ram_48 || mtask) && rom_sp);

reg iowr_d = 1'b0;
wire iowr_s = iowr && !iowr_d;     // the first clock of the write
always @(posedge clk) iowr_d <= iowr;

always @(posedge clk) begin
	if (reset) begin
		p7_page <= p7_init[2:0]; scr <= p7_init[3]; spage0 <= p7_init[4]; p7_d5 <= p7_init[5];
		p7_d6 <= p7_init[6]; p7_d7 <= p7_init[7]; p7_d5h <= p7_init[5] && !fc37_init[4];
		dfd <= 3'd0; rr_1f <= 1'b0; shrom <= 1'b0; ra15m <= 1'b0; fd1_4 <= 1'b0; fd1_7 <= 1'b0;
		p3_dos <= 1'b0; p3_d1 <= 1'b0; p3_d2 <= 1'b0;
		border <= 3'd0; border_bri <= 1'b0; tape_out <= 1'b0; speaker <= 1'b0;
		sd_a <= 8'd0; sd_b <= 8'd0; sd_c <= 8'd0; sd_d <= 8'd0; sd_fb <= 8'd0;
		eff7 <= 8'd0; fc37 <= fc37_init; fd37 <= 8'd0; ff37 <= ff37_init;
		fe37 <= {int_firm, fe37_init};
	end else if (!mode3 && (p3_dos || p3_d1 || p3_d2)) begin
		p3_dos <= 1'b0; p3_d1 <= 1'b0; p3_d2 <= 1'b0;   // DD81 held in reset while MODE_3+ = 0 (DD78:3, DD76:3)
	end else if ({int_firm, fe37_init} != osd_fe37_d) begin
		fe37 <= {int_firm, fe37_init};         // the OSD changed one of the settings of #FE37
	end else if (iowr_s) begin
		if (p_eff7) eff7 <= cpu_do;
		if (p_rtca) rtc_a <= cpu_do;
		if (!dos && sd_en)
			case (a[7:0])
				8'h0F: sd_a <= cpu_do;
				8'h1F: sd_b <= cpu_do;
				8'h4F: sd_c <= cpu_do;
				8'h5F: sd_d <= cpu_do;
				8'hFB: sd_fb <= cpu_do;
				default: ;
			endcase
		if (p_bios)
			case (a[9:8])
				2'd0: fc37 <= cpu_do;
				2'd1: fd37 <= cpu_do;
				2'd2: fe37 <= cpu_do;
				2'd3: ff37 <= cpu_do;
			endcase
		if (p_fe_w) begin
			border <= cpu_do[2:0];
			tape_out <= cpu_do[3];
			speaker <= cpu_do[4];
			border_bri <= !a[3];
		end
		// DD75 (soft, P_7FFDS, blocked by RAM_48): D0-D5; DD77 (hard, P_7FFD and WRHR): D5-D7
		if (p_7ffds && !ram_48) begin
			p7_page <= cpu_do[2:0];
			scr <= cpu_do[3];
			spage0 <= cpu_do[4];
			p7_d5 <= cpu_do[5];
		end
		if (p_7ffd && wrhr) begin
			p7_d5h <= cpu_do[5] && !blk;
			p7_d6 <= cpu_do[6];
			p7_d7 <= cpu_do[7];
		end
		if (p_dffd && wrhr)
			dfd <= cpu_do[2:0];
		// #1FFD: Scorpion / KAY register outside +3, the +3 register (A12 = 1) in +3 mode (reset otherwise)
		if (p_1ffd && wrhr && !mode3) begin
			rr_1f <= cpu_do[0]; shrom <= cpu_do[1]; ra15m <= cpu_do[3]; fd1_4 <= cpu_do[4]; fd1_7 <= cpu_do[7];
		end
		if (p_1ffd && wrhr && mode3 && a[12]) begin
			p3_dos <= cpu_do[0]; p3_d1 <= cpu_do[1]; p3_d2 <= cpu_do[2];
		end
	end
end

assign rtc_di = cpu_do;
assign rtc_wr = iowr_s && p_rtcd;

reg [7:0] osd_fe37_d = 8'd0;
always @(posedge clk) osd_fe37_d <= {int_firm, fe37_init};

// palette (TopBoard): #xxFF write outside TR-DOS with #FF37 D5 (PAL_ON); B = D0 D5 A8 A13, R = D1 D6 A9 A14,
// G = D4 D7 A12 A15 (the high bit first); the K155RU2 outputs are inverted: the level is the inverse
assign pal_we = iowr_s && p_ff && ff37[5];
assign pal_d = ~{cpu_do[1], cpu_do[6], a[9], a[14], cpu_do[4], cpu_do[7], a[12], a[15], cpu_do[0], cpu_do[5], a[8], a[13]};

// ---------------- TR-DOS ----------------
// on: M1 from 3Dxx while ROM 48 is on; off: M1 from the RAM (docs/HW.md "TR-DOS и ВГ93")
wire m1_fetch = !m1_n && !mreq_n;
always @(posedge clk) begin
	if (reset)
		dos <= dos_init;
	else if (mcache)
		dos <= 1'b1;                           // /MDOS: Magic forces TR-DOS
	else if (m1_fetch) begin
		if (a[15:14] != 2'b00)
			dos <= 1'b0;
		else if (a[13:8] == 6'h3D && spage0)
			dos <= 1'b1;
	end
end

// ---------------- the IN / OUT trap ----------------
// an opcode DB / D3 (11011x11) fetched from the RAM: the memory above 128 KB is off and #7FFD is soft decoded
// until the next opcode from the RAM (README 6, DD72 / DD68:2 taken at the end of M1)
reg [7:0] op_q = 8'h00;
reg op_ram = 1'b0, m1_d = 1'b1;
always @(posedge clk) begin
	m1_d <= m1_n;
	if (!m1_n && !mreq_n && !rd_n) begin
		op_q <= cpu_di;
		op_ram <= !rom_sel;
	end
	if (reset)
		trap <= 1'b0;
	else if (m1_n && !m1_d && op_ram)
		trap <= (op_q & 8'hF7) == 8'hD3;
end

// ---------------- memory map (docs/HW.md "Страницы памяти") ----------------
// RAM in 0000-3FFF: #EFF7 D3 or #1FFD D0 (Scorpion), or the +3 special mode
wire romram = eff7[3] || rr_1f;
wire special = mode3 && p3_dos;
// rom_sel (below): the CPU byte is not in the DRAM (ROMs, static RAM in the storage)

// page bits 0..2 (DD82 / DD83)
wire [2:0] pg_lo = special ? (p3_d2 ? {!(a[14] && a[15]), a[15] || (a[14] && p3_d1), a[14]} : {p3_d1, a[15], a[14]}) :
                   (a[15:14] == 2'b11) ? p7_page : {a[14], a[15], a[14]};
// page bits 3..7 (DD84-DD86) by EM0 / EM1, in the window C000 (HRAM: every window in multitasking, ош. 9)
reg mem256, mem512, mem1m, mem2m, mem4m;
always @(*) begin
	case (em0)
		2'd0: begin mem256 = 1'b0;  mem512 = 1'b0;  end
		2'd1: begin mem256 = p7_d6; mem512 = p7_d7; end
		2'd2: begin mem256 = dfd[0]; mem512 = dfd[1]; end
		2'd3: begin mem256 = fd1_4; mem512 = fd1_7; end
	endcase
	case ({em1[0], em0})
		3'd1: mem1m = p7_d5h;
		3'd2, 3'd6: mem1m = dfd[2];
		3'd7: mem1m = p7_d7;
		default: mem1m = 1'b0;
	endcase
	case (em1)
		2'd0: begin mem2m = 1'b0;  mem4m = 1'b0;  end
		2'd1: begin mem2m = p7_d6; mem4m = p7_d5h; end
		2'd2: begin mem2m = p7_d6; mem4m = p7_d7; end
		2'd3: begin mem2m = fd1_4; mem4m = fd1_7; end
	endcase
end
wire hram = (a[15:14] == 2'b11) || mtask;
// SCR256K..SCR4M: the screens of the current 128 KB block in multitasking (DD87, DD88:1), block 0 otherwise
assign scr_hi = mtask ? {mem4m, mem2m, mem1m, mem512, mem256} : 5'd0;
wire [4:0] pg_hi = (hram && !trap) ? {mem4m, mem2m, mem1m, mem512, mem256} : 5'd0;
wire [21:0] cpu_ma = {pg_hi, pg_lo, a[13:0]};
// ---------------- ROMs, static RAM, cache (docs/HW.md, scratchpad schematic reading of Ф3) ----------------
// The storage (SDRAM, 16 KB pages): main ROM 0-7, BIOS ROM 8-11, static RAM 16-23.
// Main ROM page (DD52 / DD56): {MODE_3+, SRA15, SRA14}; gl = the Gluk latch (DD49). RFLASH (#FF37 D6): any page
// by {MODE_3+, MODE_3+ ? 1FD2_3+ : RA15M, SPAGE0}, for the reads too.
reg gl1 = 1'b0, gl = 1'b1;
reg prnrom = 1'b0;                     // DD68:1: IN #FB sets, IN #7B clears, Magic sets
wire rflash = ff37[6];
wire [1:0] rom_lo = rflash ? {mode3 ? p3_d2 : ra15m, spage0} :
                    mode3 ? {p3_d2, spage0} :
                    (shrom || !gl) ? 2'b00 : {!dos ^ ra15m, dos || spage0};
wire [2:0] rom_page = {mode3, rom_lo};
wire blkr = romram || special;                         // BLKR: the window 0000 is DRAM (no external card)
wire w0 = (a[15:14] == 2'b00) && !blkr;
wire rsp_on = rom_sp && !prnrom;                        // DD54:2
wire emu = rsp_on && fd37[rom_page];                    // DD56: the ROM page from the static RAM (read only)
wire cache_on = prnrom && !ff37[4] && !fd37[0];         // DD58 (BLKR is in w0)
wire hld = fc37[5] && !p7_page[2] && (a[15:14] == 2'b11);   // HLOAD: static RAM at C000, #7FFD D1 D0, D2 = 0
assign rom_sel = w0 || hld;
wire st_wr = hld || (w0 && (cache_on || (rflash && rsp_on && !emu)));   // writable: static RAM, the flash
reg [4:0] st_page;
always @(*) begin
	if (hld)
		st_page = {2'b10, mode3, p7_page[1:0]};
	else if (cache_on)
		st_page = {2'b10, mode3, spage0 && !fd37[2], 1'b0};       // cache 32 KB (pages 0 / 2), 16 KB with HRMP2
	else if (emu)
		st_page = {2'b10, rom_page};
	else if (rsp_on)
		st_page = {2'b00, rom_page};
	else
		st_page = {3'b010, prnrom ? 2'b11 : ff37[3:2]};          // BIOS ROM (page 3 = the printer ROM)
end
wire [18:0] st_addr = {st_page, a[13:0]};
wire st_req = rom_sel && !mreq_n && (!rd_n || (!wr_n && st_wr));
// the byte cache of the storage (p4096_romcache.v): ROM reads without WAIT once cached
wire st_done, st_wbusy;
wire [7:0] st_q;
p4096_romcache romcache (
	.clk(clk), .reset(reset),
	.req(st_req), .wr(!wr_n), .addr(st_addr), .din(cpu_do), .done(st_done), .q(st_q), .wbusy(st_wbusy),
	.s_req(rom_req), .s_wr(rom_wr), .s_addr(rom_addr), .s_din(rom_din), .s_done(rom_done), .s_q(rom_q)
);
// the Gluk latch: /RSGLK (#FF37 D1) = 0 holds both flip-flops reset (page 0, Gluk Reset Service); after D1 = 1
// the first sets on M1 in 0000-3FFF, gl on the next M1 from the RAM. Without BIOS: gl = 1 at reset (gl_init)
always @(posedge clk) begin
	if (reset) begin
		gl1 <= 1'b0; gl <= gl_init;
	end else if (!ff37[1]) begin
		gl1 <= 1'b0; gl <= 1'b0;
	end else if (m1_fetch) begin
		if (a[15:14] == 2'b00) gl1 <= 1'b1;
		else if (gl1) gl <= 1'b1;
	end
end

// ---------------- Magic, #FB / #7B ----------------
// Magic (DD124:3, DD143): at the next M1 from the RAM in 4000-FFFF: NMI (a short pulse), MCACHE (PRNROM = 1,
// sticky; IN #7B ignored and TR-DOS forced while it lasts): the NMI handler 0066 comes from the cache (or the
// printer ROM, page 3 of the BIOS ROM, when the cache is off). The core holds MCACHE for 2^20 clocks (37 ms).
reg nmi_d = 1'b0, magic_arm = 1'b0;
reg [8:0] nmi_cnt = 9'd0;
reg [19:0] mc_cnt = 20'd0;
wire nmi_p = nmi_cnt != 9'd0;
// #FB / #7B read: A1 = 1, A2 = 0, A3 = A5 = A6 = 1; A7 = the new PRNROM
wire p_fb = a[1] && !a[2] && a[3] && a[5] && a[6];
reg iord_d = 1'b0;
always @(posedge clk) begin
	nmi_d <= nmi;
	iord_d <= iord;
	if (reset) begin
		magic_arm <= 1'b0; nmi_cnt <= 9'd0; mc_cnt <= 20'd0; mcache <= 1'b0; prnrom <= 1'b0;
	end else begin
		if (nmi && !nmi_d) magic_arm <= 1'b1;
		if (magic_arm && m1_fetch && a[15:14] != 2'b00) begin
			magic_arm <= 1'b0;
			nmi_cnt <= 9'd511;
			mc_cnt <= 20'hFFFFF;
			mcache <= 1'b1;
			prnrom <= 1'b1;
		end else begin
			if (nmi_cnt != 9'd0) nmi_cnt <= nmi_cnt - 9'd1;
			if (mc_cnt != 20'd0) mc_cnt <= mc_cnt - 20'd1;
			else mcache <= 1'b0;
			if (iord && !iord_d && p_fb && !mcache) prnrom <= a[7];
		end
	end
end

// ---------------- the RAM arbiter ----------------
wire cpu_ram = !mreq_n && rfsh_n && !rom_sel;
wire cpu_ram_rd = cpu_ram && !rd_n;
wire cpu_ram_wr = cpu_ram && !wr_n;
reg served = 1'b0;           // this memory cycle of the CPU has had its access (or its write is buffered)
reg wb_full = 1'b0;          // the write buffer
reg [21:0] wb_a = 22'd0;
reg [7:0] wb_d = 8'd0;
reg wr_hold = 1'b0;          // the second clock of a write
reg rd_cpu = 1'b0;           // mem_rd of this clock is a read of the CPU
reg rd_cpu_q = 1'b0;         // mem_q of this clock is the byte of the CPU
reg [7:0] cpu_q = 8'hFF;
wire video_next = (c5[2:0] == 3'd7);     // the next clock is a video slot
wire video_next2 = (c5[2:0] == 3'd6);    // a write now would run into it
// Turbo 14 "Original" (WAITP, DD115:2): the original DRAM runs at 7 MHz and a CPU request at 14 MHz waits for its
// slot (README: 290 % at 14 MHz). The exact rule is open (docs/QUESTIONS.md 10): here a RAM access of the CPU starts
// only where waitp_ok (WAITP_MASK of c5, the clock in the cell), tuned with src/sim/p4096_speed.py to the speed of the README.
// Reads only: a write goes into the buffer (its /WR is too short at 14 MHz to wait for the slot).
localparam [31:0] WAITP_MASK = 32'hF0F0F0C0;   // 301 % (the speed test of BIOS v4.2), README: about 290 %
wire waitp_ok = !(turbo_r == 2'd2 && turbo14_wait) || WAITP_MASK[c5];
wire rd_issue = !video_next && !wr_hold && !mem_wr && !wb_full && cpu_ram_rd && !served && waitp_ok;
wire wb_issue = !video_next && !video_next2 && !wr_hold && !mem_wr && wb_full;

always @(posedge clk) begin
	mem_rd <= 1'b0;
	mem_wr <= 1'b0;
	rd_cpu <= 1'b0;
	wr_hold <= mem_wr;
	mem_oe_n <= mem_wr;     // the hold clock of a write (the first one is set below)
	rd_cpu_q <= rd_cpu;
	if (rd_cpu_q) cpu_q <= mem_q;
	if (mreq_n) served <= 1'b0;
	if (video_next) begin
		mem_a <= vf_a;
		mem_rd <= 1'b1;
	end else if (wb_issue) begin
		mem_a <= wb_a;
		mem_d <= wb_d;
		mem_wr <= 1'b1;
		mem_oe_n <= 1'b1;
		wb_full <= 1'b0;
	end else if (rd_issue) begin
		mem_a <= cpu_ma;
		mem_rd <= 1'b1;
		rd_cpu <= 1'b1;
		served <= 1'b1;
	end
	// a write of the CPU into the buffer (once per memory cycle)
	if (cpu_ram_wr && !served && !wb_full && !reset) begin
		wb_a <= cpu_ma;
		wb_d <= cpu_do;
		wb_full <= 1'b1;
		served <= 1'b1;
	end
	if (reset) wb_full <= 1'b0;
end

// a read waits until it is issued (served): its byte is in mem_q in the clock after the issue (rd_cpu_q), in
// cpu_q later; the CPU takes it at an edge after the one that samples WAIT
wire ram_wait = cpu_ram_rd && !served;
wire ram_wait_wr = cpu_ram_wr && !served && wb_full;   // a second write while the buffer is full
// a write cycle to the storage window (MREQ without RD, not refresh: known from T1, before WAIT is sampled, /WR
// comes later) waits while the write buffer of the cache is busy
wire st_wait_wr = rom_sel && !mreq_n && rfsh_n && rd_n && st_wbusy && !st_done;
assign wait_n = !(st_req && !st_done) && !st_wait_wr && !ram_wait && !ram_wait_wr;
wire [7:0] ram_q = rd_cpu_q ? mem_q : cpu_q;

// ---------------- INT ----------------
// Pentagon-128 as unreal-ng (configs/pentagon128k: intstart 71635, "17988 T to paper", checked there on Across
// the Edge): 71680 T a frame, 32 T long. A line begins at h = 16 (T 0 of the line = h 16, px 0), the paper at
// v = 0, T 64. Matched to unreal-ng by src/sim/run_p4096_sim.sh int (the border stripes of int_test.asm at the
// same points): INT begins at v = 239, T 220 (h = 15, px 0). Firm: +48 T and 16 lines (v = 255 + 48 T = v 256,
// T 44); XJ3: 2 T earlier.
wire int_sel = fe37[7];                    // INT_SEL: 0 Pentagon, 1 Firm
wire [8:0] int_v = int_sel ? 9'd256 : 9'd239;
wire [7:0] int_t0 = int_sel ? 8'd44 : 8'd220;
wire [7:0] int_t = int_xj3 ? int_t0 - 8'd2 : int_t0;
wire [5:0] hrel = (h >= 6'd16) ? h - 6'd16 : h + 6'd40;
wire [7:0] line_t = {hrel, px[2:1]};        // the T of the line (0..223)
assign int_go = (v == int_v) && (line_t == int_t) && !px[0] && (ph == 2'd0);
// /INT ends at the acknowledge (INTA: /IORQ and /M1, DD12:3 resets DD23:2) or after 32 T at the latest (HC). The
// acknowledge matters in turbo: a short handler would take INT twice (the CPU speed test of BIOS v4.2 read 0 %).
reg [7:0] int_cnt = 8'd0;     // 32 T = 256 clocks
always @(posedge clk) begin
	if (int_go)
		int_cnt <= 8'd255;
	else if (!iorq_n && !m1_n)
		int_cnt <= 8'd0;
	else if (int_cnt != 8'd0)
		int_cnt <= int_cnt - 8'd1;
	int_n <= !(int_cnt != 8'd0 || int_go);
end

// ---------------- AY / TurboSound ----------------
wire ay_ce = (cnt8 == 3'd7);       // 3.5 MHz, the PSG at 1.75 MHz
wire ay_sel = io && (p_fffd || p_bffd);
wire [7:0] ay_do;
wire [7:0] s0a, s0b, s0c, s1a, s1b, s1c;
turbosound ts (
	.RESET(reset), .CLK(clk), .CE(ay_ce),
	.BDIR(ay_sel && !wr_n), .BC(ay_sel && a[14]), .DI(cpu_do), .DO(ay_do), .AY_MODE(1'b0),
	.SSG0_AUDIO_A(s0a), .SSG0_AUDIO_B(s0b), .SSG0_AUDIO_C(s0c),
	.SSG1_AUDIO_A(s1a), .SSG1_AUDIO_B(s1b), .SSG1_AUDIO_C(s1c),
	.MIDI_TX()
);

// ---------------- CPU data in ----------------
always @(*) begin
	if (!iorq_n && !m1_n)
		cpu_di = 8'hFF;                                    // INTA: IM 2 vector FF
	else if (iord) begin
		if (p_fe_r)
			cpu_di = {1'b1, tape_in, 1'b1, kbd_d};
		else if (p_fffd)
			cpu_di = ay_do;
		else if (p_eff7)
			cpu_di = {border[2], eff7[6], eff7[5], border[1], eff7[3], border[0], eff7[1], eff7[0]};
		else if (p_7ffd)
			cpu_di = {p7_d7, p7_d6, p7_d5, spage0, scr, p7_page};
		else if (p_rtcd)
			cpu_di = rtc_do;
		else if (p_mouse)
			cpu_di = !a[8] ? {ms_z, 1'b1, !ms_b[2], !ms_b[0], !ms_b[1]} : a[10] ? ms_y : ms_x;
		else if (p_kj)
			cpu_di = {3'b000, joy};
		else if (p_ff)
			cpu_di = attr_port;
		else
			cpu_di = 8'hFF;
	end else if (rom_sel)
		cpu_di = st_q;
	else
		cpu_di = ram_q;
end
assign kbd_a = a[15:8];

// ---------------- sound ----------------
// ABC stereo: A left, C right, B in both at half. The sum is unsigned and goes out as a positive signed value:
// silence = 0 (with the middle subtracted the board gave a DC of -10240 in silence, hw 2026-11-20).
reg [11:0] sum_l = 12'd0, sum_r = 12'd0;
reg tape_in_r = 1'b0;
always @(posedge clk) begin
	tape_in_r <= tape_in;
	sum_l <= {4'd0, s0a} + {4'd0, s1a} + {5'd0, s0b[7:1]} + {5'd0, s1b[7:1]} +
	         {4'd0, sd_a} + {4'd0, sd_b} + {5'd0, sd_fb[7:1]} +
	         (speaker ? 12'd384 : 12'd0) + (tape_out ? 12'd48 : 12'd0) + (tape_in_r ? 12'd48 : 12'd0);
	sum_r <= {4'd0, s0c} + {4'd0, s1c} + {5'd0, s0b[7:1]} + {5'd0, s1b[7:1]} +
	         {4'd0, sd_c} + {4'd0, sd_d} + {5'd0, sd_fb[7:1]} +
	         (speaker ? 12'd384 : 12'd0) + (tape_out ? 12'd48 : 12'd0) + (tape_in_r ? 12'd48 : 12'd0);
	audio_l <= {sum_l, 4'd0};
	audio_r <= {sum_r, 4'd0};
end

endmodule
`default_nettype wire
