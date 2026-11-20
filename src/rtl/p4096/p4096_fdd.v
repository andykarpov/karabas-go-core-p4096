`timescale 1ns / 1ps
`default_nettype none
/*
 The floppy controller of p4096: the VG93 (WD1793) on the TR-DOS ports, the drives A-D on disk images (TRD) of the
 file mounter of the mcu (kg_mcu2 ENABLE_IMG, img_sdc inside: slots 0-3).
 - wd1793 of MiSTer (rtl/fdd/wd1793.v): 16 sectors of 256 bytes a track, a track = track * 2 + side in the image
   (TRD); RWMODE (the image is written back).
 - Ports (docs/HW.md "TR-DOS и ВГ93", ош. 1): A0 = A1 = A2 = A3 = 1 and the TR-DOS ports open (T_DOS or #EFF7 D7);
   A7 = 0: the VG93 registers by A6 A5 (#1F command / status, #3F track, #5F sector, #7F data); A7 = 1: the system
   port #FF: write D0 D1 drive, D2 /MR, D3 HLT, D4 side (0 = side 1), D6 density; read D7 INTRQ, D6 DRQ.
 - The images: one wd1793 for the four drives. Each drive keeps the size of its image (taken when it is mounted);
   a new drive selected, or the image of the selected one mounted, gives wd1793 a mount (img_mounted pulse with
   that size), as a disk inserted. READY = the selected drive has an image.
 - A sector goes to / from the mcu directly (img_sdc: 5-15 ms a sector, the time of a real drive); a copy of the
   images in the SDRAM would make it faster (later).
 - The strobes are held from the CPU access to the next ce of wd1793 (3.5 MHz): a turbo access is shorter
   (as core-orionpro).
*/
module p4096_fdd (
	input  wire        clk,
	input  wire        reset,

	// the CPU (p4096.v: io and the decode of the ports)
	input  wire        sel,          // an IO access to the TR-DOS ports (A0-A3 = 1, ports open)
	input  wire        rd,
	input  wire        wr,
	input  wire [7:0]  a,
	input  wire [7:0]  din,
	output wire [7:0]  dout,
	input  wire [3:0]  wp,           // write protect of the drives (OSD)

	// the image files (slots 0-3 of kg_mcu2)
	input  wire [3:0]  img_mounted,
	input  wire [63:0] img_size,
	output reg  [3:0]  sdc_rd = 4'd0,
	output reg  [3:0]  sdc_wr = 4'd0,
	output reg  [31:0] sdc_sector = 32'd0,
	input  wire        sdc_busy,     // of slots 0-3 only (the top masks them)
	input  wire        sdc_done,
	input  wire [8:0]  sdc_byte_addr,
	input  wire        sdc_byte_in_strobe,
	input  wire [7:0]  sdc_byte_in_data,
	output wire [7:0]  sdc_byte_out_data,
	output wire        active        // a sector in flight (an icon / LED)
);

// ---------------- the system port #FF ----------------
reg [7:0] sys = 8'h00;
wire sys_acc = sel && a[7];
wire vg_acc = sel && !a[7];
always @(posedge clk)
	if (reset) sys <= 8'h00;
	else if (sys_acc && wr) sys <= din;
wire [1:0] drv = sys[1:0];

// ---------------- clock enable, held strobes ----------------
reg [2:0] div = 3'd0;
always @(posedge clk) div <= div + 3'd1;
wire ce = div == 3'd0;
reg rd_s = 1'b0, wr_s = 1'b0, acc_d = 1'b0;
reg [1:0] a_s = 2'd0;
reg [7:0] d_s = 8'd0;
always @(posedge clk) begin
	acc_d <= vg_acc && (rd || wr);
	if (vg_acc && (rd || wr) && !acc_d) begin   // the start of the access
		rd_s <= rd;
		wr_s <= wr;
		a_s <= a[6:5];
		d_s <= din;
	end else if (ce && !(vg_acc && (rd || wr))) begin
		rd_s <= 1'b0;
		wr_s <= 1'b0;
	end
end

// ---------------- the images of the drives ----------------
reg [19:0] size0 = 20'd0, size1 = 20'd0, size2 = 20'd0, size3 = 20'd0;
reg [3:0] here = 4'd0;
reg [1:0] drv_d = 2'd0;
reg [3:0] mnt_cnt = 4'd0;                  // the mount pulse of wd1793 (several ce)
always @(posedge clk) begin
	if (img_mounted[0]) begin size0 <= img_size[19:0]; here[0] <= img_size != 64'd0; end
	if (img_mounted[1]) begin size1 <= img_size[19:0]; here[1] <= img_size != 64'd0; end
	if (img_mounted[2]) begin size2 <= img_size[19:0]; here[2] <= img_size != 64'd0; end
	if (img_mounted[3]) begin size3 <= img_size[19:0]; here[3] <= img_size != 64'd0; end
	drv_d <= drv;
	if (img_mounted[drv] || drv != drv_d)
		mnt_cnt <= 4'd15;
	else if (ce && mnt_cnt != 4'd0)
		mnt_cnt <= mnt_cnt - 4'd1;
end
wire [19:0] size_sel = (drv == 2'd0) ? size0 : (drv == 2'd1) ? size1 : (drv == 2'd2) ? size2 : size3;

// ---------------- wd1793 ----------------
wire [31:0] sd_lba;
wire sd_rd, sd_wr;
reg sd_ack = 1'b0;
reg [8:0] sd_buff_addr_r = 9'd0;
reg [7:0] sd_buff_dout = 8'd0;
reg sd_buff_wr = 1'b0;
wire [7:0] sd_buff_din;
wire [7:0] vg_dout;
wire drq, intrq;
wire [8:0] sd_buff_addr = (st == ST_WR || st == ST_WR_WAIT) ? sdc_byte_addr : sd_buff_addr_r;

wd1793 #(.RWMODE(1), .EDSK(0)) vg (
	.clk_sys(clk), .ce(ce), .reset(reset || !sys[2]), .io_en(1'b1),
	.rd(rd_s), .wr(wr_s), .addr(vg_acc && (rd || wr) ? a[6:5] : a_s), .din(d_s), .dout(vg_dout),
	.drq(drq), .intrq(intrq), .busy(),
	.wp(wp[drv]), .size_code(3'd1), .layout(1'b0), .side(!sys[4]), .ready(here[drv]),
	.img_mounted(mnt_cnt != 4'd0), .img_size(size_sel), .prepare(),
	.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
	.input_active(1'b0), .input_addr(20'd0), .input_data(8'd0), .input_wr(1'b0),
	.buff_addr(), .buff_read(), .buff_din(8'd0)
);

assign dout = a[7] ? {intrq, drq, 6'b111111} : vg_dout;

// ---------------- sd_* of wd1793 <-> sdc_* of the mcu ----------------
localparam ST_IDLE = 3'd0, ST_RD = 3'd1, ST_RD_WAIT = 3'd2, ST_WR = 3'd3, ST_WR_WAIT = 3'd4, ST_END = 3'd5;
reg [2:0] st = ST_IDLE;
reg [1:0] cur = 2'd0;
assign sdc_byte_out_data = sd_buff_din;
assign active = st != ST_IDLE;
always @(posedge clk) begin
	sd_buff_wr <= 1'b0;
	if (reset) begin
		st <= ST_IDLE; sdc_rd <= 4'd0; sdc_wr <= 4'd0; sd_ack <= 1'b0;
	end else case (st)
		ST_IDLE:
			if ((sd_rd || sd_wr) && here[drv]) begin
				cur <= drv;
				sdc_sector <= sd_lba;
				sd_ack <= 1'b1;
				st <= sd_rd ? ST_RD : ST_WR;
			end
		ST_RD: begin
			sdc_rd[cur] <= 1'b1;
			if (sdc_busy && sdc_rd[cur]) begin
				sdc_rd <= 4'd0;
				st <= ST_RD_WAIT;
			end
		end
		ST_RD_WAIT: begin
			if (sdc_byte_in_strobe) begin
				sd_buff_addr_r <= sdc_byte_addr;
				sd_buff_dout <= sdc_byte_in_data;
				sd_buff_wr <= 1'b1;
			end
			if (sdc_done) st <= ST_END;
		end
		ST_WR: begin
			sdc_wr[cur] <= 1'b1;
			if (sdc_busy && sdc_wr[cur]) begin
				sdc_wr <= 4'd0;
				st <= ST_WR_WAIT;
			end
		end
		ST_WR_WAIT:
			if (sdc_done) st <= ST_END;
		default: begin                       // ST_END: wd1793 sees sd_ack fall, then its request ends
			sd_ack <= 1'b0;
			if (!sd_rd && !sd_wr) st <= ST_IDLE;
		end
	endcase
end

endmodule
`default_nettype wire
