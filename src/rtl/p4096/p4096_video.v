`timescale 1ns / 1ps
`default_nettype none
/*
 Pentagon-4096 video (docs/HW.md "Развёртка", "Видеоадрес", "Цвет"). Ф1: the standard screen 256x192 and the border.

 Counters (clk = 28 MHz, 4 clocks a point of 7 MHz):
   ph 0..3   the clock in the point
   px 0..7   the point in the cell (pixel of 7 MHz)
   h  8..63  the cell (56 cells = 448 points a line): 32..63 paper, 8..15 right border, 16..23 blank and HSYNC,
             24..31 left border
   v  0..319 the line: 0..191 paper, 192..239 bottom border, 240..255 frame pulse, 256..319 top border.
             v counts at the start of h = 16 (the rising edge of NOR(H3, H5) of the schematic), so a line of the
             picture is h = 16..63, 8..15.
   c5 = {px, ph}: the clock in the cell, 0..31.

 Memory: four fetch slots a cell, at c5 = 0, 8, 16, 24 (slot n = c5[4:3]; Ф1 uses 0 = pixels, 1 = attribute).
 vf_a is the address of the slot that is issued in the next clock (the arbiter of p4096.v decides in the clock
 c5 % 8 = 7); the byte comes as mem_q in the clock after the issue (c5 % 8 = 1). A cell fetches the bytes of the
 next one; they go to the shift register at the start of that cell.
 Address as the schematic (VM_A0 = A13, VM_A1 = page bit 0, 8/64PX): standard mode VM_A0 = 0, VM_A1 = 1, page
 {SCR bits 3..7 = 0, 1, GGSCR = #7FFD D3, 1} = 5 or 7.

 Output: a dot of 14 MHz in every second clock (dot_x 0..895 from h = 16, dot_line = v), the colour as 4 bits a
 channel (the levels of the palette of BIOS v4.2: 0 / 10 / 15).
*/
module p4096_video (
	input  wire        clk,
	input  wire        reset,

	// the machine
	input  wire        scr,          // #7FFD D3
	input  wire [2:0]  border,       // #FE D0..D2 (G R B = D2 D1 D0)
	input  wire        border_bri,   // the last border write was to #F6 (A3 = 0)

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
	output reg  [11:0] dot_rgb = 12'd0,     // {R, G, B} 4 bits each
	output reg         line_start = 1'b0    // the first clock of h = 16 (the clock of dot_x = 0)
);

assign c5 = {px, ph};

// ---------------- counters ----------------
wire pt_end = (ph == 2'd3);
wire cell_end = pt_end && (px == 3'd7);
wire [5:0] h_next = (h == 6'd63) ? 6'd8 : h + 6'd1;
reg [4:0] frame = 5'd0;    // frame[4] = FLASH (16 frames on, 16 off)

always @(posedge clk) begin
	if (reset) begin
		ph <= 2'd0; px <= 3'd0; h <= 6'd8; v <= 9'd0;
	end else begin
		ph <= ph + 2'd1;
		if (pt_end) px <= px + 3'd1;
		if (cell_end) begin
			h <= h_next;
			if (h_next == 6'd16) begin
				if (v == 9'd319) begin
					v <= 9'd0;
					frame <= frame + 5'd1;
				end else
					v <= v + 9'd1;
			end
		end
	end
end

// the cell whose bytes the slot of the next clock fetches: the one after the cell of that slot (cell 31 fetches
// cell 32 = column 0); at c5 = 31 the next slot is in the next cell already
wire [5:0] h_slot = (c5 == 5'd31) ? h_next : h;
wire [5:0] fh = (h_slot == 6'd63) ? 6'd8 : h_slot + 6'd1;
wire paper_v = (v < 9'd192);
wire fetch_paper = h_next[5] && paper_v;   // H5 = 1: the paper columns (the cell after h, taken at c5 = 0)
// slot of the next clock: c5 + 1
wire [4:0] c5n = c5 + 5'd1;
wire attr_slot = c5n[3];                 // slot 1 (c5 = 8): the attribute (8/64PX = 1)
// RAM address (docs/HW.md "Видеоадрес"): A0-4 = H0-4, A5-7 = V3-5, then pixels: A8 = V0, A9 = V1, A10 = V2,
// A11 = V6, A12 = V7; attributes: A8 = V6, A9 = V7, A10 = 0, A11 = 384_A2 = 1, A12 = 1. A13 = VM_A0 = 0.
wire [12:0] pix_a  = {v[7], v[6], v[2], v[1], v[0], v[5:3], fh[4:0]};
wire [12:0] attr_a = {1'b1, 1'b1, 1'b0, v[7], v[6], v[5:3], fh[4:0]};
wire [7:0] vpage = {5'b00000, 1'b1, scr, 1'b1};   // page 5 / 7 (stage bit 2 = 1, bit 1 = GGSCR, bit 0 = VM_A1)
assign vf_a = {vpage, 1'b0, attr_slot ? attr_a : pix_a};

// ---------------- fetch, shift register ----------------
reg [7:0] pix_nx = 8'd0, attr_nx = 8'd0;
reg fetched_paper = 1'b0;
reg [7:0] shift = 8'd0, attr = 8'd0;
reg paper = 1'b0;       // the current cell is paper
always @(posedge clk) begin
	if (c5 == 5'd1) pix_nx <= mem_q;
	if (c5 == 5'd9) attr_nx <= mem_q;
	if (c5 == 5'd0) fetched_paper <= fetch_paper;
	if (cell_end) begin
		paper <= fetched_paper;
		shift <= pix_nx;
		attr <= attr_nx;
		attr_port <= fetched_paper ? attr_nx : 8'hFF;
	end else if (pt_end)
		shift <= {shift[6:0], 1'b0};
end

// ---------------- colour ----------------
wire hblank = (h >= 6'd16) && (h < 6'd24);
wire vblank = (v >= 9'd240) && (v < 9'd256);
wire ink = shift[7] ^ (attr[7] & frame[4]);
// index {bright, G, R, B}
wire [3:0] idx = !paper ? {border_bri, border} :
                 ink ? {attr[6], attr[2:0]} : {attr[6], attr[5:3]};
wire [3:0] lvl = idx[3] ? 4'd15 : 4'd10;
wire [11:0] rgb = (hblank || vblank) ? 12'd0 :
	{idx[1] ? lvl : 4'd0, idx[2] ? lvl : 4'd0, idx[0] ? lvl : 4'd0};

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
