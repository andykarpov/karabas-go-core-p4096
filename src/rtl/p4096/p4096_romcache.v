`timescale 1ns / 1ps
`default_nettype none
/*
 A byte cache of the storage (ROMs, static RAM) for the CPU of p4096: 4096 entries, direct mapped by the address
 bits 11..0, {valid, tag = bits 18..12, byte} in block RAM. The original reads its ROM (EEPROM) without wait states
 at 7 MHz; a byte from the SDRAM (baseconf_storage) takes 10..17 clocks of 84 MHz, the BIOS v4.2 speed test read
 161 % instead of 200 % from the ROM at 7 MHz.
 - A read hit answers in the clock after the address (the CPU samples WAIT later at any speed); a miss goes to the
   storage and fills the entry.
 - A write is posted: address and byte go into a one entry buffer at once (the entry of the cache is updated in the
   same clock), the buffer keeps the request to the storage until it is done. /WR of the CPU at 7 / 14 MHz is
   shorter than a write of the SDRAM: without the buffer the request ended before the storage took it and the
   cache kept the old byte (the static RAM test of BIOS v4.2 broke at 7 MHz). A read miss waits for the buffer.
 - reset clears the entries (4096 clocks; the machine is held in reset meanwhile, also while the firmware loads
   the ROMs) and drops nothing of a write in progress.

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
	output wire        wbusy,         // a write is in the buffer (p4096.v holds a following write cycle with WAIT)

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

// the write buffer
reg wpend = 1'b0;                 // a write waits for the storage
reg wseen = 1'b0;                 // the write cycle of the CPU has been taken (until req drops)
reg [18:0] waddr = 19'd0;
reg [7:0] wdata = 8'd0;
wire wpost = req && wr && !wseen && !wpend;

// read side of the storage: a miss, when no write is pending
wire rd_go = req && !wr && !wpend && !clearing;

// write port of the cache: clear; a posted write; the fill of a read miss
wire fill = rd_go && s_done;
always @(posedge clk) begin
	if (reset || clearing) begin
		mem[clr] <= 16'd0;
		clr <= clr + 12'd1;
		if (reset) clearing <= 1'b1;
		else if (clr == 12'hFFF) clearing <= 1'b0;
	end else if (wpost)
		mem[addr[11:0]] <= {1'b1, addr[18:12], din};
	else if (fill)
		mem[addr[11:0]] <= {1'b1, addr[18:12], s_q};
end

always @(posedge clk) begin
	if (!req) wseen <= 1'b0;
	if (wpost) begin
		wpend <= 1'b1;
		wseen <= 1'b1;
		waddr <= addr;
		wdata <= din;
	end else if (wpend && s_done)
		wpend <= 1'b0;
end

// read port: the entry of the current address, one clock later
always @(posedge clk) begin
	rq <= mem[addr[11:0]];
	addr_d <= addr;
	req_d <= req;
end

wire hit = !clearing && rq[15] && rq[14:8] == addr[18:12] && addr_d == addr;
wire rd_hit = req && !wr && req_d && hit;
assign s_req = wpend || (rd_go && ((req_d && !hit) || s_done));
assign s_wr = wpend;
assign s_addr = wpend ? waddr : addr;
assign s_din = wdata;
assign done = rd_hit || (rd_go && s_done) || (req && wr && (wseen || wpost));
assign q = rd_hit ? rq[7:0] : s_q;
assign wbusy = wpend;

endmodule
`default_nettype wire
