// Ф0 fit measure of the Pentagon-4096 core (XST only, never implemented): the donor blocks wired as in
// karabas-go-core-baseconf 336bcd3 (rtl/baseconf.v) around one main CPU, so XST keeps them all.
//   - main CPU: z80-silicon (z80s_t80pa, rtl/z80-silicon)
//   - ROM (8 pages + BIOS + 128K static RAM) and the GS memory in SDRAM: baseconf_storage + sdram2p
//   - General Sound (gs.v, z80-silicon inside)
//   - FDC: hrdy_fdc + the VG93 model (rtl/vg93)
//   - TurboSound: two YM2149 (turbosound.v), SoundDrive / Covox (covox.vhd)
// Not here (counted from other builds in docs/PLAN.md): SRAM 4 MB controller, video, ports and paging of the
// machine itself, kg_mcu2 / OSD / HDMI / audio of the board.
module p4096_measure (
    input  wire        clk,        // clk_sys (SDRAM side)
    input  wire        fclk,       // clk_bus 28 MHz
    input  wire        locked,
    input  wire        rst_n,
    input  wire        zpos, zneg,
    input  wire        int_n, nmi_n, wait_n,
    input  wire [7:0]  mem_di,     // data of the SRAM (main RAM) for the CPU
    output wire [15:0] a_o,
    output wire [7:0]  d_o,
    output wire        mreq_n_o, iorq_n_o, rd_n_o, wr_n_o, m1_n_o,
    input  wire        loader_act, loader_wr,
    input  wire [31:0] loader_a,
    input  wire [7:0]  loader_d,
    input  wire [7:0]  rompg,
    input  wire        rom_sel,
    // FDC drive side
    input  wire        fdc_rdata, fdc_wprt, fdc_tr00, fdc_index,
    output wire        fdc_side, fdc_wg, fdc_wr_data, fdc_step, fdc_dir, fdc_motor,
    output wire [1:0]  fdc_ds,
    // sound sums (XOR-folded so XST keeps every channel)
    output reg  [15:0] snd,
    // SDRAM
    output wire        sdram_clk,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba, sdram_dqm,
    output wire        sdram_ras_n, sdram_cas_n, sdram_we_n,
    inout  wire [15:0] sdram_dq
);
    wire [15:0] a;
    wire [7:0]  d, di;
    wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    wire fdc_oe_n, fdc_busy, fdc_intrq, fdc_drq;

    // ---- main CPU ----
    z80s_t80pa cpu(.RESET_n(rst_n), .CLK(fclk), .CEN_p(zpos), .CEN_n(zneg), .WAIT_n(wait_n & !fdc_busy),
        .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(1'b1), .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(), .A(a), .DI(di), .DO(d));
    assign a_o = a, d_o = d, mreq_n_o = mreq_n, iorq_n_o = iorq_n, rd_n_o = rd_n, wr_n_o = wr_n, m1_n_o = m1_n;

    // ---- FDC ----
    wire [7:0] fdc_data;
    hrdy_fdc fdc(.clk(fclk), .ds80(1'b0), .reset(!rst_n), .ena_cpu(zpos),
        .a(a), .d(d), .wr_n(wr_n), .rd_n(rd_n), .iorq_n(iorq_n),
        .cs_n(!(a[1:0] == 2'b11 && !a[7] && !iorq_n)), .csff_n(!(a[7:0] == 8'hff && !iorq_n)),
        .oe_n(fdc_oe_n), .dout(fdc_data), .busy(fdc_busy), .intrq_o(fdc_intrq), .drq_o(fdc_drq),
        .FDC_SIDE1(fdc_side), .FDC_RDATA(fdc_rdata), .FDC_WPRT(fdc_wprt), .FDC_TR00(fdc_tr00),
        .FDC_INDEX(fdc_index), .FDC_WG(fdc_wg), .FDC_WR_DATA(fdc_wr_data), .FDC_STEP(fdc_step),
        .FDC_DIR(fdc_dir), .FDC_MOTOR(fdc_motor), .FDC_DS(fdc_ds));

    // ---- TurboSound, Covox / SoundDrive ----
    reg [2:0] sound_div = 0;
    always @(posedge fclk) sound_div <= sound_div + 1'b1;
    wire ay_bdir = !iorq_n && !wr_n && a[15] && !a[1];
    wire [7:0] ts_data, s0a, s0b, s0c, s1a, s1b, s1c;
    turbosound ts(.RESET(!rst_n), .CLK(fclk), .CE(sound_div == 0), .BDIR(ay_bdir), .BC(a[14]), .DI(d),
        .DO(ts_data), .AY_MODE(1'b0), .SSG0_AUDIO_A(s0a), .SSG0_AUDIO_B(s0b), .SSG0_AUDIO_C(s0c),
        .SSG1_AUDIO_A(s1a), .SSG1_AUDIO_B(s1b), .SSG1_AUDIO_C(s1c), .MIDI_TX());
    wire [7:0] cv_a, cv_b, cv_c, cv_d, cv_fb;
    covox covox(.I_RESET(!rst_n), .I_CLK(fclk), .I_CS(1'b1), .I_ADDR(a[7:0]), .I_DATA(d), .I_WR_N(wr_n),
        .I_IORQ_N(iorq_n), .I_DOS(1'b0), .O_A(cv_a), .O_B(cv_b), .O_C(cv_c), .O_D(cv_d), .O_FB(cv_fb));

    // ---- GS ----
    wire gs_oe, gs_rd_n, gs_wr_n, gs_done;
    wire [7:0] gs_data, gs_din, gs_dout;
    wire [20:0] gs_addr;
    wire signed [14:0] gs_l, gs_r;
    wire gs_req = !gs_rd_n || !gs_wr_n;
    gs gs(.CLK(fclk), .RESET(!rst_n), .CE(sound_div[0]), .CE_N(!sound_div[0]), .MEM_WAIT(gs_req && !gs_done),
        .SAMPLE_T(), .A(a), .DI(d), .DO(gs_data), .OE(gs_oe), .WR_n(wr_n), .RD_n(rd_n), .IORQ_n(iorq_n),
        .M1_n(m1_n), .MA(gs_addr), .MDI(gs_din), .MDO(gs_dout), .MRFSH_n(), .MWE_n(gs_wr_n), .MRD_n(gs_rd_n),
        .OUT_L(gs_l), .OUT_R(gs_r));

    // ---- ROM / BIOS / static RAM in SDRAM (+ GS memory) ----
    wire [7:0] rom_data;
    wire rom_done, storage_busy;
    wire rom_req = rom_sel && !mreq_n && !rd_n && rfsh_n;
    baseconf_storage storage(.clk(clk), .reset(!locked), .sdram_init_n(locked),
        .rom_req(rom_req), .rom_wr(1'b0), .rom_addr({rompg[4:0], a[13:0]}), .rom_din(d), .rom_dout(rom_data),
        .rom_done(rom_done),
        .gs_req(gs_req), .gs_wr(!gs_wr_n), .gs_addr(gs_addr), .gs_din(gs_dout), .gs_dout(gs_din), .gs_done(gs_done),
        .loader_act(loader_act), .loader_wr(loader_wr), .loader_addr(loader_a), .loader_data(loader_d),
        .fl_wr(1'b0), .fl_a(32'd0), .fl_d(8'd0),
        .opl_addr(22'd0), .opl_req(1'b0), .opl_we(1'b0), .opl_wdata(8'd0), .opl_ack(), .opl_rdata(),
        .busy(storage_busy), .fault(), .sdram_clk(sdram_clk), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
        .sdram_dqm(sdram_dqm), .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_dq(sdram_dq));

    // ---- CPU data bus ----
    assign di = gs_oe ? gs_data :
                !fdc_oe_n ? fdc_data :
                (!iorq_n && a[15:14] == 2'b11 && !a[1]) ? ts_data :
                (!iorq_n && a[7:0] == 8'hff) ? {fdc_intrq, fdc_drq, 6'h3f} :
                rom_sel ? rom_data : mem_di;

    always @(posedge fclk)
        snd <= {s0a, s0b} ^ {s0c, s1a} ^ {s1b, s1c} ^ {cv_a, cv_b} ^ {cv_c, cv_d} ^ {cv_fb, 8'd0} ^
               {gs_l[14:0], 1'b0} ^ {gs_r[14:0], 1'b0} ^ {15'd0, storage_busy ^ rom_done};
endmodule
