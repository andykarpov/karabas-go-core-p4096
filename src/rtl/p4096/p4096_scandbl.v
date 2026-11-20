`timescale 1ns / 1ps
`default_nettype none
/*
 Line doubler of p4096: a line of the machine (1792 clocks, 896 dots of 14 MHz) is written into one half of the
 buffer while the other half (the line before) is read twice at one dot a clock. The output is the 576p frame of
 core-tsconf (docs/PLAN.md Ф0 "Вывод"): 896 clocks x 640 lines at 28 MHz (48.8 Hz), 720 x 576 active.

 The picture of the machine is 384 x 304 points (border 64 | paper 256 | border 64; lines 64 | 192 | 48); the
 window crops 12 points left / right and 8 lines top / bottom: dots 152..871 of the line (dot 0 = h 16), lines
 L = 8..295 (L = 0 is v = 256, the first line of the top border).
 Output line O = 2 * (L of the line read) + half: active O 16..591, VSYNC O 597..601, HSYNC clocks 20..83,
 active clocks 152..871 (positive syncs, as kg_hdmi_ft takes them from the other cores).
*/
module p4096_scandbl (
	input  wire        clk,
	input  wire        dot_we,
	input  wire [9:0]  dot_x,
	input  wire [8:0]  dot_line,
	input  wire [11:0] dot_rgb,
	input  wire        line_start,

	output reg  [7:0]  r = 8'd0,
	output reg  [7:0]  g = 8'd0,
	output reg  [7:0]  b = 8'd0,
	output reg         hs = 1'b0,
	output reg         vs = 1'b0,
	output reg         de = 1'b0
);

localparam HS_BEG = 10'd20, HS_END = 10'd84, DE_BEG = 10'd152, DE_END = 10'd872;
localparam O_ACT_BEG = 10'd16, O_ACT_END = 10'd592, O_VS_BEG = 10'd597, O_VS_END = 10'd602;

reg [11:0] buf_mem [0:2047];
always @(posedge clk)
	if (dot_we) buf_mem[{dot_line[0], dot_x}] <= dot_rgb;

// read side
reg [9:0] ox = 10'd0;
reg half = 1'b0;
reg rbank = 1'b0;
reg [8:0] lr = 9'd0;       // L of the line read
always @(posedge clk) begin
	if (line_start) begin
		ox <= 10'd0;
		half <= 1'b0;
		rbank <= !dot_line[0];
		// the line before: L(v - 1), L(v) = (v - 256) mod 320
		lr <= (dot_line >= 9'd257) ? dot_line - 9'd257 : (dot_line == 9'd0) ? 9'd63 : dot_line + 9'd63;
	end else if (ox == 10'd895) begin
		ox <= 10'd0;
		half <= 1'b1;
	end else
		ox <= ox + 10'd1;
end

wire [9:0] o = {lr, half};
reg [11:0] q = 12'd0;
reg de0 = 1'b0, hs0 = 1'b0, vs0 = 1'b0;
always @(posedge clk) begin
	q <= buf_mem[{rbank, ox}];
	de0 <= (ox >= DE_BEG) && (ox < DE_END) && (o >= O_ACT_BEG) && (o < O_ACT_END);
	hs0 <= (ox >= HS_BEG) && (ox < HS_END);
	vs0 <= (o >= O_VS_BEG) && (o < O_VS_END);
	r <= de0 ? {q[11:8], q[11:8]} : 8'd0;
	g <= de0 ? {q[7:4], q[7:4]} : 8'd0;
	b <= de0 ? {q[3:0], q[3:0]} : 8'd0;
	de <= de0;
	hs <= hs0;
	vs <= vs0;
end

endmodule
`default_nettype wire
