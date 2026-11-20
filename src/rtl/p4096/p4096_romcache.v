`timescale 1ns / 1ps
`default_nettype none
/*
 A byte cache of the storage (ROMs, static RAM) for the CPU of p4096: 4096 entries, direct mapped by the address
 bits 11..0, {valid, tag = bits 18..12, byte} in block RAM. The original reads its ROM (EEPROM) without wait states
 at 7 MHz; a byte from the SDRAM (baseconf_storage) takes 10..17 clocks of 84 MHz, the BIOS v4.2 speed test read
 161 % instead of 200 % from the ROM at 7 MHz. A hit answers in the clock after the address (the CPU samples WAIT
 later at any speed); a miss goes to the storage and fills the entry; a write goes to the storage and updates the
 entry. reset clears the entries (4096 clocks, the machine is held in reset meanwhile, also while the firmware loads
 the ROMs).

 cpu side: req / wr / addr / din (as p4096.v drives rom_*), done, q
 storage side: s_req / s_wr / s_addr / s_din, s_done, s_q (baseconf_storage rom_*)
*/
module p4096_romcache (
	input  wire        clk,
	input  wire        reset,

	input  wire        req,
	input  wire        wr,
	input  wire [18:0] addr,
	input  wire [7:0]  din,
	output wire        done,
	output wire [7:0]  q,

	output wire        s_req,
	output wire        s_wr,
	output wire [18:0] s_addr,
	output wire [7:0]  s_din,
	input  wire        s_done,
	input  wire [7:0]  s_q
);

reg [15:0] mem [0:4095];          // {valid, tag[6:0], byte}
reg [15:0] rq = 16'd0;            // the entry of addr_d
reg [18:0] addr_d = 19'd0;
reg [11:0] clr = 12'd0;
reg clearing = 1'b1;
reg req_d = 1'b0;

// write port: clear, or fill / update when the storage answered
wire fill = req && s_done && !clearing;
always @(posedge clk) begin
	if (reset || clearing) begin
		mem[clr] <= 16'd0;
		clr <= clr + 12'd1;
		if (reset) clearing <= 1'b1;
		else if (clr == 12'hFFF) clearing <= 1'b0;
	end else if (fill)
		mem[addr[11:0]] <= {1'b1, addr[18:12], wr ? din : s_q};
end

// read port: the entry of the current address, one clock later
always @(posedge clk) begin
	rq <= mem[addr[11:0]];
	addr_d <= addr;
	req_d <= req;
end

wire hit = !clearing && rq[15] && rq[14:8] == addr[18:12] && addr_d == addr;
// a read waits one clock for the entry; a hit never goes to the storage; a write always does
wire rd_hit = req && !wr && req_d && hit;
assign s_req = req && !clearing && (wr || (req_d && !hit) || s_done);
assign s_wr = wr;
assign s_addr = addr;
assign s_din = din;
assign done = rd_hit || (req && s_done);
assign q = rd_hit ? rq[7:0] : s_q;

endmodule
`default_nettype wire
