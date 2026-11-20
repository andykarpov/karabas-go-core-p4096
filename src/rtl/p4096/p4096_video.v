`timescale 1ns / 1ps
`default_nettype none
/*
 Pentagon-4096 video (docs/HW.md "Развёртка", "Видеоадрес", "Пиксельный тракт", "Цвет", "Палитра 4096"), all
 modes as src/tools/p4096_vmodel.py draws them (the reference of the simulation, dot for dot; its CHECK points are
 the open questions of docs/QUESTIONS.md).

 Counters (clk = 28 MHz, 4 clocks a point of 7 MHz, 2 a dot of 14 MHz):
   ph 0..3   the clock in the point          px 0..7   the point in the cell
   h  8..63  the cell: 32..63 paper, 8..15 right border, 16..23 blank and HSYNC, 24..31 left border
   v  0..319 the line: 0..191 paper, 192..239 bottom border, 240..255 frame pulse, 256..319 top border
             (v counts at the start of h = 16: a line of the picture is h = 16..63, 8..15)
   c5 = {px, ph}: the clock in the cell, 0..31.

 Memory: four fetch slots a cell, at c5 = 0, 8, 16, 24 (slot n = c5[4:3]). vf_a is the address of the slot issued
 in the next clock (p4096.v decides at c5 % 8 = 7); its byte comes as mem_q at c5 % 8 = 1. A cell fetches the
 bytes of the next one, which go to the decoder at the start of that cell. "main" = the screen page (5 / 7: page bit
 0 = VM_A1 = 1), "alt" = "page 4" (4 / 6: bit 0 = 0); bit 1 = GGSCR (#7FFD D3 or the GigaScreen alternation).
   standard     s0 pixels main 4000, s1 attribute main 5800 (multicolor #EFF7 D5: main 6000 at the pixel address)
   512x192      s0 pixels main 4000, s1 attribute A13 = 0, s2 pixels main 6000, s3 attribute A13 = 1 (colour: main
                5800 / 7800, colour multicolor: alt C000 / E000 at the pixel address; mono: none used)
   16 colors    s0 alt C000, s1 main 4000, s2 alt E000, s3 main 6000 (pixel address), 2 points a byte
   384x304      the paper as the mode says; the border cells: sides main 6000 / 7800 + H4..H0, top / bottom
                alt C000 / C800 + D800 / D900 (pixels / attributes, lines of the border), corners show the border
 Output: one dot of 14 MHz every 2 clocks (dot_x 0..895 from h = 16, dot_line = v), the colour as 6 bits a
 channel m = 4 * level (level 0..15 of the palette), a FlashColor INK point = INK + 3 * PAPER: the 8-bit value is
 17 * m / 4 (p4096_scandbl).
*/
module p4096_video (
	input  wire        clk,
	input  wire        reset,
	input  wire        pal_rst,      // the machine reset: the standard palette (what BIOS v4.2 writes)

	// the machine
	input  wire        scr,          // #7FFD D3
	input  wire [2:0]  border,       // #FE D0..D2 (B R G)
	input  wire        border_bri,   // the last border write was to #F6 (A3 = 0)
	input  wire [7:0]  eff7,         // D0 16 colors, D1 512x192, D5 multicolor, D6 384x304
	input  wire [7:0]  fe37,         // D0-D3 512 ink B R G I, D4 512 colour, D5 FlashColor, D6 GigaScreen auto
	input  wire        frame_latch,  // KI1024S: the GigaScreen latch takes #7FFD D3 (once a frame, with INT)
	input  wire        pal_en,       // 0: the standard 16 colours (the old path of the TopBoard, XJ1-XJ3)
	input  wire        pal_we,       // a write of #xxFF with #FF37 D5: the entry of the index on the output
	input  wire [11:0] pal_d,        // {R, G, B} levels (already inverted as the outputs of the K155RU2)

	// the memory slots
	output wire [21:0] vf_a,
	input  wire [7:0]  mem_q,

	// the counters
	output reg  [1:0]  ph = 2'd0,
	output reg  [2:0]  px = 3'd0,
	output reg  [5:0]  h = 6'd8,
	output reg  [8:0]  v = 9'd0,
	output wire [4:0]  c5,

	// port #FF: the last attribute (FF on the border)
	output reg  [7:0]  attr_port = 8'hFF,

	// the dots
	output reg         dot_we = 1'b0,
	output reg  [9:0]  dot_x = 10'd0,
	output reg  [8:0]  dot_line = 9'd0,
	output reg  [17:0] dot_rgb = 18'd0,     // {R, G, B} 6 bits each: 4 * level, or INK + 3 * PAPER
	output reg         line_start = 1'b0    // the first clock of h = 16 (the clock of dot_x = 0)
);

assign c5 = {px, ph};

wire m16 = eff7[0];
wire m512 = eff7[1];
wire mmx = eff7[5];
wire m384 = eff7[6];
wire col512 = fe37[4];
wire fc_on = fe37[5] && !m16;      // fc of DD109 / DD110
wire giga_on = fe37[6];

// ---------------- counters ----------------
wire pt_end = (ph == 2'd3);
wire cell_end = pt_end && (px == 3'd7);
wire [5:0] h_next = (h == 6'd63) ? 6'd8 : h + 6'd1;
reg [4:0] frame = 5'd0;    // frame[4] = FLASH (16 frames on, 16 off), frame[0] = 2FRM

always @(posedge clk) begin
	if (reset) begin
		ph <= 2'd0; px <= 3'd0; h <= 6'd8; v <= 9'd0;
	end else begin
		ph <= ph + 2'd1;
		if (pt_end) px <= px + 3'd1;
		if (cell_end) begin
			h <= h_next;
			if (h_next == 6'd16) begin
				v <= (v == 9'd319) ? 9'd0 : v + 9'd1;
				// FLASH and 2FRM count frame pulses (KI1024, v 240..255): outside the picture
				if (v == 9'd239) frame <= frame + 5'd1;
			end
		end
	end
end

// ---------------- GigaScreen auto (DD111:1, DD113, DD109:2) ----------------
reg scr_latch = 1'b0;
always @(posedge clk) if (frame_latch) scr_latch <= scr;
wire ggscr = (giga_on && (scr ^ scr_latch)) ? (frame[0] ^ v[0]) : scr;
wire [7:0] page_main = {5'b00000, 1'b1, ggscr, 1'b1};
wire [7:0] page_alt  = {5'b00000, 1'b1, ggscr, 1'b0};

// ---------------- fetch ----------------
// the cell whose bytes the slot of the next clock fetches: the one after the cell of that slot
wire [5:0] h_slot = (c5 == 5'd31) ? h_next : h;
wire [5:0] fh = (h_slot == 6'd63) ? 6'd8 : h_slot + 6'd1;
wire [4:0] c5n = c5 + 5'd1;
wire [1:0] slot = c5n[4:3];
wire [4:0] col = fh[4:0];

wire v_paper = (v < 9'd192);
wire v_top = (v >= 9'd256);                    // lines 0..63 of the top border
wire v_bot = (v >= 9'd192) && (v < 9'd240);    // lines 0..47 of the bottom border
wire [5:0] ly = v[5:0];                        // v - 256 (top) / v - 192 (bottom): both are v[5:0]
// the visible border cells of 384x304 (h 24..31 left, 8..15 right; the paper columns h 32..63)
wire fh_side = !fh[5] && fh[3];               // 8..15, 24..31
// cell kinds: 0 border, 1 paper of the mode, 2 a border cell of 384x304 (standard decode)
wire [1:0] fkind = (fh[5] && v_paper) ? 2'd1 :
                   (m384 && ((fh_side && v_paper) || (fh[5] && (v_top || v_bot)))) ? 2'd2 : 2'd0;

// ZX addresses: pixels {V7, V6, V2, V1, V0, V5, V4, V3, col}, attributes {1, 1, 0, V7, V6, V5, V4, V3, col}
wire [12:0] pa  = {v[7], v[6], v[2], v[1], v[0], v[5:3], col};
wire [12:0] aa  = {3'b110, v[7], v[6], v[5:3], col};
// lines of the border (384x304): pixels C000 / C800 + {L2..L0, L5..L3, col}, attributes D800 / D900
wire [12:0] aa_lb = {3'b110, 1'b0, v_bot, ly[5:3], col};

reg        f_alt;
reg        f_a13;
reg [12:0] f_off;
always @(*) begin
	f_alt = 1'b0; f_a13 = 1'b0; f_off = pa;
	if (fkind == 2'd2) begin
		if (v_paper) begin                         // sides: main, A13 = 1
			f_a13 = 1'b1;
			f_off = slot[0] ? aa : pa;
		end else begin                             // top / bottom: alt, A13 = 0
			f_alt = 1'b1;
				f_off = slot[0] ? aa_lb : {1'b0, v_bot, ly[2:0], ly[5:3], col};
		end
	end else if (m16) begin
		f_alt = !slot[0];
		f_a13 = slot[1];
		f_off = pa;
	end else if (m512) begin
		f_a13 = slot[1];
		if (!slot[0])
			f_off = pa;
		else if (mmx) begin
			f_alt = 1'b1;
			f_off = pa;
		end else
			f_off = aa;
	end else begin                                 // standard / multicolor
		f_a13 = slot[0] && mmx;
		f_off = (slot[0] && !mmx) ? aa : pa;
	end
end
assign vf_a = {f_alt ? page_alt : page_main, f_a13, f_off};

reg [7:0] nx0 = 8'd0, nx1 = 8'd0, nx2 = 8'd0, nx3 = 8'd0;
reg [1:0] fkind_nx = 2'd0;
reg [7:0] b0 = 8'd0, b1 = 8'd0, b2 = 8'd0, b3 = 8'd0;
reg [1:0] kind = 2'd0;
always @(posedge clk) begin
	if (c5 == 5'd1)  nx0 <= mem_q;
	if (c5 == 5'd9)  nx1 <= mem_q;
	if (c5 == 5'd17) nx2 <= mem_q;
	if (c5 == 5'd25) nx3 <= mem_q;
	if (c5 == 5'd0) fkind_nx <= (h_next[5] && v_paper) ? 2'd1 :
		(m384 && ((!h_next[5] && h_next[3] && v_paper) || (h_next[5] && (v_top || v_bot)))) ? 2'd2 : 2'd0;
	if (cell_end) begin
		kind <= fkind_nx;
		b0 <= nx0; b1 <= nx1; b2 <= nx2; b3 <= nx3;
		attr_port <= (fkind_nx != 2'd0) ? nx1 : 8'hFF;
	end
end

// ---------------- palette (TopBoard: three K155RU2 16 x 4) ----------------
function [11:0] std_pal(input [3:0] x);
	reg [3:0] lv;
	begin
		lv = x[3] ? 4'd15 : 4'd10;
		std_pal = {x[1] ? lv : 4'd0, x[2] ? lv : 4'd0, x[0] ? lv : 4'd0};
	end
endfunction

reg [11:0] pal [0:15];

// ---------------- decode of a dot ----------------
wire [3:0] d = {px, ph[1]};           // the dot of 14 MHz in the cell
wire flash = frame[4];
reg [7:0] pbyte, abyte;
reg pbit;
reg [3:0] idx_a, idx_b;               // the index (and the PAPER index of a FlashColor mix)
reg mix;
always @(*) begin
	pbyte = b0; abyte = b1; pbit = 1'b0; mix = 1'b0;
	idx_a = {border_bri, border}; idx_b = 4'd0;
	if (kind != 2'd0) begin
		if (kind == 2'd1 && m16) begin
			pbyte = d[3] ? (d[2] ? b3 : b2) : (d[2] ? b1 : b0);
			idx_a = d[1] ? {pbyte[7], pbyte[5:3]} : {pbyte[6], pbyte[2:0]};
		end else if (kind == 2'd1 && m512) begin
			pbyte = d[3] ? b2 : b0;
			abyte = d[3] ? b3 : b1;
			pbit = pbyte[~d[2:0]];
			if (!col512)
				idx_a = pbit ? fe37[3:0] : 4'd0;
			else if (fc_on && abyte[7]) begin
				mix = pbit;
				idx_a = pbit ? {abyte[6], abyte[2:0]} : 4'd0;
				idx_b = {abyte[6], abyte[5:3]};
			end else
				idx_a = (pbit ^ (abyte[7] & flash)) ? {abyte[6], abyte[2:0]} : {abyte[6], abyte[5:3]};
		end else begin                        // standard, multicolor, the border cells of 384x304
			pbit = pbyte[~px];
			if (fc_on && abyte[7]) begin
				mix = pbit;
				idx_a = pbit ? {abyte[6], abyte[2:0]} : 4'd0;
				idx_b = {abyte[6], abyte[5:3]};
			end else
				idx_a = (pbit ^ (abyte[7] & flash)) ? {abyte[6], abyte[2:0]} : {abyte[6], abyte[5:3]};
		end
	end
end

wire [11:0] ca = pal_en ? pal[idx_a] : std_pal(idx_a);
wire [11:0] cb = pal_en ? pal[idx_b] : std_pal(idx_b);
// 6 bits a channel: 4 * level, or INK + 3 * PAPER
function [5:0] chan(input m, input [3:0] a, input [3:0] b);
	chan = m ? {2'b00, a} + {2'b00, b} + {1'b0, b, 1'b0} : {a, 2'b00};
endfunction

wire hblank = (h >= 6'd16) && (h < 6'd24);
wire vblank = (v >= 9'd240) && (v < 9'd256);
wire [17:0] rgb = (hblank || vblank) ? 18'd0 :
	{chan(mix, ca[11:8], cb[11:8]), chan(mix, ca[7:4], cb[7:4]), chan(mix, ca[3:0], cb[3:0])};

// a write of the palette takes the index on the output (the border while the BIOS writes it)
reg [3:0] idx_out = 4'd0;
integer i;
always @(posedge clk) begin
	idx_out <= idx_a;
	if (pal_rst) begin
		for (i = 0; i < 16; i = i + 1) pal[i] <= std_pal(i);
	end else if (pal_we)
		pal[idx_out] <= pal_d;
end

// dot position: x = ((h - 16) mod 56) * 16 + px * 2 + ph[1]
wire [5:0] hrel = (h >= 6'd16) ? h - 6'd16 : h + 6'd40;
always @(posedge clk) begin
	dot_we <= 1'b1;
	dot_x <= {hrel, px, ph[1]};
	dot_line <= v;
	dot_rgb <= rgb;
	line_start <= (h == 6'd16) && (c5 == 5'd0);
end

endmodule
`default_nettype wire
