`timescale 1ns / 1ps
/*
 tb_p4096: the machine p4096.v with a RAM of 128 KB (pages 0..7), the ROM of 64 KB (pages 0..3, rom_done
 ROM_LAT clocks after the request, as baseconf_storage in the SDRAM) and the frame of the dots dumped as text.

 Plusargs:
   +rom=FILE    the ROM, hex bytes (64 KB)          +ram=FILE  the RAM at start, hex bytes (128 KB)
   +hold        the CPU stays in reset (the video of the RAM as loaded)
   +frames=N    run N frames (from the top line of the window, v = 256)
   +dump=FILE   the last frame: 304 lines of 768 dots (12-bit RGB hex), the window of p4096_scandbl
   +turbo=T     0 / 1 / 2     +firm  INT Firm     +xj3  XJ3
   +log=FILE    INT / port log (one line per INT start and per OUT)
*/
module tb_p4096;

reg clk = 1'b0;
always #17.84 clk = ~clk;

reg [7:0] ram [0:131071];
reg [7:0] rom [0:65535];
integer i, frames, nframe, fd, fl, rom_lat;
reg hold, firm, xj3;
reg [1:0] turbo;
reg [8*256-1:0] fname;

wire [21:0] mem_a;
wire mem_rd, mem_wr;
wire [7:0] mem_d;
reg [7:0] mem_q = 8'h00;
wire rom_req;
wire [18:0] rom_addr;
reg [7:0] rom_q = 8'h00;
reg rom_done = 1'b0;
wire dot_we, line_start;
wire [9:0] dot_x;
wire [8:0] dot_line;
wire [17:0] dot_rgb;
wire [7:0] kbd_a;
wire [15:0] audio_l, audio_r, cpu_a;
wire cpu_m1_n, int_n, tape_out;
reg reset = 1'b1;

p4096 dut (
	.clk(clk), .reset(reset),
	.turbo(turbo), .int_firm(firm), .int_xj3(xj3), .nmi(1'b0), .fe37_init(7'h07), .pal_en(1'b1),
	.kbd_a(kbd_a), .kbd_d(5'b11111), .joy(5'b00000), .tape_in(1'b0), .tape_out(tape_out),
	.mem_a(mem_a), .mem_rd(mem_rd), .mem_wr(mem_wr), .mem_d(mem_d), .mem_oe_n(), .mem_q(mem_q),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_q(rom_q), .rom_done(rom_done),
	.dot_we(dot_we), .dot_x(dot_x), .dot_line(dot_line), .dot_rgb(dot_rgb), .line_start(line_start),
	.audio_l(audio_l), .audio_r(audio_r),
	.cpu_a(cpu_a), .cpu_m1_n(cpu_m1_n), .int_n_o(int_n)
);

// RAM: the byte of a read in the next clock (the input register of the top); a write in its first clock
always @(posedge clk) begin
	if (mem_rd) mem_q <= ram[mem_a[16:0]];
	if (mem_wr) ram[mem_a[16:0]] <= mem_d;
end

// ROM: rom_done rom_lat clocks after rom_req with the same address
reg [18:0] rom_tag = 19'h7FFFF;
integer rom_cnt = 0;
always @(posedge clk) begin
	if (!rom_req) begin
		rom_done <= 1'b0;
		rom_cnt <= 0;
	end else if (rom_addr != rom_tag) begin
		rom_tag <= rom_addr;
		rom_done <= 1'b0;
		rom_cnt <= 1;
	end else if (rom_cnt < rom_lat)
		rom_cnt <= rom_cnt + 1;
	else begin
		rom_q <= rom[rom_addr[15:0]];
		rom_done <= 1'b1;
	end
end

// frame dump: window lines L = 0..303 (v = 256.. 319, 0..239), dots 128..895
reg [17:0] frame_buf [0:304*768-1];
integer L;
always @(posedge clk) begin
	if (line_start && dot_line == 9'd256) nframe = nframe + 1;
	if (dot_we && nframe == frames && dot_x >= 10'd128) begin
		L = (dot_line >= 9'd256) ? dot_line - 256 : dot_line + 64;
		if (L < 304) frame_buf[L * 768 + dot_x - 128] = dot_rgb;
	end
end

// log: INT starts and OUTs, in T-states of 3.5 MHz from the start
integer clocks = 0, nwr = 0;
reg [15:0] last_pc = 16'd0;
integer trace_n = 0, int_clk = 0, halt_clk = 0;
reg inta_d = 1'b0;
reg int_n_d = 1'b1;
always @(posedge clk) begin
	clocks = clocks + 1;
	int_n_d <= int_n;
	if (!dut.m1_n && !dut.mreq_n && !dut.rd_n) begin
		if (fl != 0 && trace_n > 0 && dut.a != last_pc) begin
			$fwrite(fl, "M1 %04x clk %0d\n", dut.a, clocks);
			trace_n = trace_n - 1;
		end
		last_pc = dut.a;
	end
	if (mem_wr) nwr = nwr + 1;
	if (int_n_d && !int_n) int_clk = clocks;
	if (fl != 0 && !dut.m1_n && !dut.iorq_n && !inta_d)
		$fwrite(fl, "INTA %0d clocks after INT, halt start phase %0d\n", clocks - int_clk, (halt_clk - int_clk) % 32);
	inta_d = !dut.m1_n && !dut.iorq_n;
	if (fl != 0 && int_n_d && !int_n)
		$fwrite(fl, "INT clk %0d v %0d pc %04x writes %0d p7ffd %02x\n", clocks, dut.v, last_pc, nwr,
			{dut.p7_d7, dut.p7_d6, dut.p7_d5, dut.spage0, dut.scr, dut.p7_page});
end

initial begin
	nframe = 0;
	fl = 0;
	if (!$value$plusargs("frames=%d", frames)) frames = 2;
	if (!$value$plusargs("trace=%d", trace_n)) trace_n = 0;
	if (!$value$plusargs("romlat=%d", rom_lat)) rom_lat = 6;
	if (!$value$plusargs("turbo=%d", turbo)) turbo = 2'd0;
	hold = $test$plusargs("hold");
	firm = $test$plusargs("firm");
	xj3 = $test$plusargs("xj3");
	for (i = 0; i < 131072; i = i + 1) ram[i] = 8'h00;
	for (i = 0; i < 65536; i = i + 1) rom[i] = 8'hFF;
	if ($value$plusargs("rom=%s", fname)) $readmemh(fname, rom);
	if ($value$plusargs("ram=%s", fname)) $readmemh(fname, ram);
	if ($value$plusargs("log=%s", fname)) fl = $fopen(fname, "w");
	repeat (20) @(posedge clk);
	if (!hold) reset = 1'b0;
	wait (nframe == frames + 1);
	if ($value$plusargs("dump=%s", fname)) begin
		fd = $fopen(fname, "w");
		for (i = 0; i < 304 * 768; i = i + 1) $fwrite(fd, "%05x\n", frame_buf[i]);
		$fclose(fd);
	end
	if (fl != 0) $fclose(fl);
	$display("tb_p4096: %0d frames, %0d clocks", frames, clocks);
	$finish;
end

endmodule
