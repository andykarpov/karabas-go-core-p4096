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
	input  wire        int_firm,      // 0 Pentagon, 1 Firm (+16 lines, +48 T)
	input  wire        int_xj3,       // the XJ3 jumper: INT 2 T earlier
	input  wire        nmi,           // Magic (1: NMI held)

	// keyboard (hid_parser: A15..A8 in, the columns out, active low), Kempston (active high: F U D L R)
	output wire [7:0]  kbd_a,
	input  wire [4:0]  kbd_d,
	input  wire [4:0]  joy,
	input  wire        tape_in,
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
	input  wire [7:0]  rom_q,
	input  wire        rom_done,

	// video (p4096_video.v)
	output wire        dot_we,
	output wire [9:0]  dot_x,
	output wire [8:0]  dot_line,
	output wire [11:0] dot_rgb,
	output wire        line_start,

	// sound: signed, the sum of AY / TS, beeper and tape
	output reg  [15:0] audio_l = 16'd0,
	output reg  [15:0] audio_r = 16'd0,

	// debug / sim
	output wire [15:0] cpu_a,
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

p4096_video video (
	.clk(clk), .reset(1'b0),
	.scr(scr), .border(border), .border_bri(border_bri),
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
assign cpu_m1_n = m1_n;
assign int_n_o = int_n;

z80s_t80pa cpu (
	.RESET_n(!reset), .CLK(clk), .CEN_p(zpos), .CEN_n(zneg),
	.WAIT_n(wait_n), .INT_n(int_n), .NMI_n(!nmi), .BUSRQ_n(1'b1),
	.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n), .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n),
	.HALT_n(), .BUSAK_n(),
	.A(a), .DI(cpu_di), .DO(cpu_do)
);

// ---------------- ports: registers ----------------
reg [2:0] p7_page = 3'd0;      // 7FD0-2
reg spage0 = 1'b0;             // #7FFD D4: ROM 48
reg p7_d5 = 1'b0;              // 7FD5B
reg p7_d6 = 1'b0, p7_d7 = 1'b0;
reg speaker = 1'b0;
reg dos = 1'b0;                // T_DOS

wire io = !iorq_n && m1_n;
wire iowr = io && !wr_n;
wire iord = io && !rd_n;
// #xxFD (DD71): A1 = 0, A2 = 1; A15 A14 A13 select
wire p_fd = !a[1] && a[2];
wire p_7ffd = p_fd && a[15:13] == 3'b011;
wire p_fffd = p_fd && a[15:13] == 3'b111;
wire p_bffd = p_fd && a[15:13] == 3'b101;
// #FE / #F6 write: A0 = 0, A2 = 1, A6 = 1; read #FE: A0 = 0
wire p_fe_w = !a[0] && a[2] && a[6];
wire p_fe_r = !a[0];
// #xxFF read: A0-A7 all 1 (not in TR-DOS: the system port of the VG93)
wire p_ff = a[7:0] == 8'hFF && !dos;
// Kempston #1F: A5 = A7 = 0, A3 = 1, not TR-DOS
wire p_kj = !a[5] && !a[7] && a[3] && !dos;   // #FE (A0 = 0) has the priority in cpu_di

// RAM_48 = 7FD5B and 7FD5_BLK (#FC37 D4; Ф1: 1, the D5 latch of Pentagon-128)
wire ram_48 = p7_d5;

reg iowr_d = 1'b0;
wire iowr_s = iowr && !iowr_d;     // the first clock of the write
always @(posedge clk) iowr_d <= iowr;

always @(posedge clk) begin
	if (reset) begin
		p7_page <= 3'd0; scr <= 1'b0; spage0 <= 1'b0; p7_d5 <= 1'b0; p7_d6 <= 1'b0; p7_d7 <= 1'b0;
		border <= 3'd0; border_bri <= 1'b0; tape_out <= 1'b0; speaker <= 1'b0;
	end else if (iowr_s) begin
		if (p_fe_w) begin
			border <= cpu_do[2:0];
			tape_out <= cpu_do[3];
			speaker <= cpu_do[4];
			border_bri <= !a[3];
		end
		if (p_7ffd && !ram_48) begin
			p7_page <= cpu_do[2:0];
			scr <= cpu_do[3];
			spage0 <= cpu_do[4];
			p7_d5 <= cpu_do[5];
		end
		if (p_7ffd) begin
			p7_d6 <= cpu_do[6];
			p7_d7 <= cpu_do[7];
		end
	end
end

// ---------------- TR-DOS ----------------
// on: M1 from 3Dxx while ROM 48 is on; off: M1 from the RAM (docs/HW.md "TR-DOS и ВГ93")
wire m1_fetch = !m1_n && !mreq_n;
always @(posedge clk) begin
	if (reset)
		dos <= 1'b0;
	else if (m1_fetch) begin
		if (a[15:14] != 2'b00)
			dos <= 1'b0;
		else if (a[13:8] == 6'h3D && spage0)
			dos <= 1'b1;
	end
end

// ---------------- memory map ----------------
wire rom_sel = a[15:14] == 2'b00;
// page bits 0..2: C000 -> #7FFD D0-D2, 8000 -> 2, 4000 -> 5 (Ф1: 128K, page bits 3..7 = 0)
wire [2:0] ram_page = (a[15:14] == 2'b11) ? p7_page : {a[14], a[15], a[14]};
wire [21:0] cpu_ma = {5'b00000, ram_page, a[13:0]};
// ROM page {SRA15, SRA14} (gl = 1): 0 Gluk, 1 TR-DOS, 2 Menu-128, 3 BASIC 48
wire [1:0] rom_page = {!dos, dos || spage0};   // SRA15 = not T_DOS, SRA14 = T_DOS or SPAGE0
assign rom_addr = {3'b000, rom_page, a[13:0]};
assign rom_req = rom_sel && !mreq_n && !rd_n;

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
wire rd_issue = !video_next && !wr_hold && !mem_wr && !wb_full && cpu_ram_rd && !served;
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
assign wait_n = !(rom_req && !rom_done) && !ram_wait && !ram_wait_wr;
wire [7:0] ram_q = rd_cpu_q ? mem_q : cpu_q;

// ---------------- INT ----------------
// Pentagon-128 as unreal-ng (configs/pentagon128k: intstart 71635, "17988 T to paper", checked there on Across
// the Edge): 71680 T a frame, 32 T long. A line begins at h = 16 (T 0 of the line = h 16, px 0), the paper at
// v = 0, T 64. Matched to unreal-ng by src/sim/run_p4096_sim.sh int (the border stripes of int_test.asm at the
// same points): INT begins at v = 239, T 220 (h = 15, px 0). Firm: +48 T and 16 lines (v = 255 + 48 T = v 256,
// T 44); XJ3: 2 T earlier.
wire [8:0] int_v = int_firm ? 9'd256 : 9'd239;
wire [7:0] int_t0 = int_firm ? 8'd44 : 8'd220;
wire [7:0] int_t = int_xj3 ? int_t0 - 8'd2 : int_t0;
wire [5:0] hrel = (h >= 6'd16) ? h - 6'd16 : h + 6'd40;
wire [7:0] line_t = {hrel, px[2:1]};        // the T of the line (0..223)
wire int_go = (v == int_v) && (line_t == int_t) && !px[0] && (ph == 2'd0);
reg [7:0] int_cnt = 8'd0;     // 32 T = 256 clocks
always @(posedge clk) begin
	if (int_go)
		int_cnt <= 8'd255;
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
		else if (p_7ffd)
			cpu_di = {p7_d7, p7_d6, p7_d5, spage0, scr, p7_page};
		else if (p_kj)
			cpu_di = {3'b000, joy};
		else if (p_ff)
			cpu_di = attr_port;
		else
			cpu_di = 8'hFF;
	end else if (rom_sel)
		cpu_di = rom_q;
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
	         (speaker ? 12'd384 : 12'd0) + (tape_out ? 12'd48 : 12'd0) + (tape_in_r ? 12'd48 : 12'd0);
	sum_r <= {4'd0, s0c} + {4'd0, s1c} + {5'd0, s0b[7:1]} + {5'd0, s1b[7:1]} +
	         (speaker ? 12'd384 : 12'd0) + (tape_out ? 12'd48 : 12'd0) + (tape_in_r ? 12'd48 : 12'd0);
	audio_l <= {sum_l, 4'd0};
	audio_r <= {sum_r, 4'd0};
end

endmodule
`default_nettype wire
