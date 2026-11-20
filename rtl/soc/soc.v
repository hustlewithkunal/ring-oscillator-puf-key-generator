// PUF key-generator SoC: RV32I core + 8 KB RAM + fuzzy extractor + PUF control +
// host mailbox + GPIO. The RO arrays (puf_measure) are instantiated at the top level
// (fixed placement names) and connected through the puf_* ports.
//
// Memory map (addr[31:28] selects the block; every access takes one wait state):
//   0x0000_0000  RAM 8 KB: firmware, stack, helper data
//   0x1000_0000  key generator
//     +0x00 W  FE_CMD        command to the fuzzy extractor (1 MEASURE .. 5 MAC)
//     +0x04 R  FE_STATUS     {kcv_ok, ecc_ok, key_valid, locked, cmd_err, done, busy}
//                            = bits {6,5,4,3,2,1,0}
//     +0x08 W  ENROL_MSG0    BCH messages [31:0]
//     +0x0C W  ENROL_MSG1    BCH messages [55:32]
//     +0x10..0x1C W HELPER_IN[0..3]   +0x20 W KCV_IN
//     +0x24 W  CHAL0  +0x28 W CHAL1
//     +0x30..0x3C R HELPER_OUT[0..3]  +0x40 R KCV_OUT
//     +0x44 R  TAG0   +0x48 R TAG1
//     +0x50 W  PUF_CTRL      bit 0: start SELECT (configurable-RO enrolment)
//           R               {select_done, puf_busy} = bits {1,0}
//     +0x54 RW DEV_SEL       RO array used by the key generator (0..2)
//     +0x80..0xAC RW PAIR_CFG[0..11]  RO configuration of every pair (384 bits)
//     +0xC0..0xEC R  CFG_BEST[0..11]  result of the last SELECT
//   0x2000_0000  host mailbox (JTAG/VIO)
//     +0x000 R H2D_SEQ  +0x004 R H2D_CMD  +0x040..0x09C R H2D_ARG[0..23]
//     +0x100 W D2H_SEQ  +0x104 W D2H_STATUS +0x140..0x19C W D2H_DATA[0..23]
//   0x3000_0000  GPIO
//     +0x00 RW LED[3:0]   +0x04 R {btn[3:0], sw[3:0]}   +0x08 R cycle counter
//
// The key exists only inside fuzzy_extractor; no address reads it.

`timescale 1ns / 1ps

module soc #(
    parameter REP       = 3,
    parameter USE_SOP   = 1,
    parameter FW_FILE   = "firmware.mem"
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         boot_locked,

    // PUF measurement unit (top level)
    output wire         puf_start,
    output wire         puf_mode,           // 0 MEASURE, 1 SELECT
    output wire [1:0]   puf_arr,
    output wire [383:0] puf_cfg,
    input  wire         puf_busy,
    input  wire         puf_done,
    input  wire [127:0] puf_response,
    input  wire [383:0] puf_cfg_best,

    // host mailbox
    input  wire [7:0]   h2d_seq,
    input  wire [7:0]   h2d_cmd,
    input  wire [767:0] h2d_arg,
    output reg  [7:0]   d2h_seq,
    output reg  [31:0]  d2h_status,
    output reg  [767:0] d2h_data,

    // board I/O
    input  wire [3:0]   sw,
    input  wire [3:0]   btn,
    output reg  [3:0]   led,
    output wire         trap,
    output wire         key_valid
);

    // ------------------------------------------------------------- CPU + bus
    wire        mem_valid;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;
    reg         mem_ready;

    rv32_core u_cpu (
        .clk(clk), .rst(rst), .mem_valid(mem_valid), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready), .trap(trap));

    wire sel_ram = mem_valid && (mem_addr[31:28] == 4'h0);
    wire sel_io  = mem_valid && (mem_addr[31:28] != 4'h0);
    wire [31:0] ram_rdata;
    wire        ram_ready;

    soc_ram #(.WORDS(2048), .INIT_FILE(FW_FILE)) u_ram (
        .clk(clk), .sel(sel_ram), .addr(mem_addr), .wdata(mem_wdata), .wstrb(mem_wstrb),
        .rdata(ram_rdata), .ready(ram_ready));

    // peripherals: one wait state, write on the first cycle of the request
    reg        io_ready;
    reg [31:0] io_rdata;
    wire       io_req   = sel_io && !io_ready;
    wire       io_write = io_req && (mem_wstrb != 4'd0);
    wire [3:0] blk      = mem_addr[31:28];
    wire [9:0] off      = mem_addr[9:0];

    always @* begin
        mem_ready = ram_ready | io_ready;
        mem_rdata = ram_ready ? ram_rdata : io_rdata;
    end

    // -------------------------------------------------- fuzzy extractor regs
    reg         fe_cmd_valid;
    reg  [2:0]  fe_cmd;
    reg  [55:0] enrol_msg;
    reg  [127:0] helper_in;
    reg  [31:0] kcv_in;
    reg  [63:0] challenge;
    reg         fe_done_seen;
    wire        fe_busy, fe_done, fe_cmd_err, fe_locked, fe_ecc_ok, fe_kcv_ok;
    wire [127:0] helper_out, fe_raw;
    wire [31:0] kcv_out;
    wire [63:0] tag;
    wire        fe_puf_req;
    reg         fe_puf_valid;

    fuzzy_extractor #(.REP(REP), .USE_SOP(USE_SOP), .AUTO_LOCK(1), .CHARACTERISATION(0)) u_fe (
        .clk(clk), .rst(rst), .boot_locked(boot_locked),
        .cmd_valid(fe_cmd_valid), .cmd(fe_cmd), .busy(fe_busy), .done(fe_done), .cmd_err(fe_cmd_err),
        .puf_req(fe_puf_req), .puf_valid(fe_puf_valid), .puf_resp(puf_response),
        .enrol_msg(enrol_msg), .helper_in(helper_in), .kcv_in(kcv_in),
        .helper_out(helper_out), .kcv_out(kcv_out),
        .challenge(challenge), .tag(tag),
        .locked(fe_locked), .key_valid(key_valid), .ecc_ok(fe_ecc_ok), .kcv_ok(fe_kcv_ok),
        .raw_resp(fe_raw));

    // --------------------------------------------------------- PUF control
    reg  [1:0]   dev_sel;
    reg  [383:0] pair_cfg;
    // requests are latched (fe_puf_req is a one-cycle pulse) and started one at a time;
    // *_wait marks the measurement in flight so its done goes to the right requester
    reg          meas_req, meas_wait, sel_req, sel_wait, sel_done;

    wire puf_idle = !puf_busy && !meas_wait && !sel_wait;
    assign puf_start = puf_idle && (meas_req || sel_req);
    assign puf_mode  = !meas_req;                       // measurement requests have priority
    assign puf_arr   = dev_sel;
    assign puf_cfg   = pair_cfg;

    always @(posedge clk) begin
        if (rst) begin
            meas_req     <= 1'b0;
            meas_wait    <= 1'b0;
            sel_req      <= 1'b0;
            sel_wait     <= 1'b0;
            sel_done     <= 1'b0;
            fe_puf_valid <= 1'b0;
        end else begin
            fe_puf_valid <= 1'b0;
            if (fe_puf_req) meas_req <= 1'b1;
            if (io_write && blk == 4'h1 && off == 10'h050 && mem_wdata[0]) begin
                sel_req  <= 1'b1;
                sel_done <= 1'b0;
            end
            if (puf_start) begin
                if (meas_req) begin meas_req <= 1'b0; meas_wait <= 1'b1; end
                else          begin sel_req  <= 1'b0; sel_wait  <= 1'b1; end
            end
            if (puf_done && meas_wait) begin meas_wait <= 1'b0; fe_puf_valid <= 1'b1; end
            if (puf_done && sel_wait)  begin sel_wait  <= 1'b0; sel_done     <= 1'b1; end
        end
    end

    // -------------------------------------------------------------- writes
    reg [31:0] cycles;
    integer w;
    always @(posedge clk) begin
        cycles <= rst ? 32'd0 : cycles + 32'd1;
        fe_cmd_valid <= 1'b0;
        if (rst) begin
            fe_cmd       <= 3'd0;
            enrol_msg    <= 56'd0;
            helper_in    <= 128'd0;
            kcv_in       <= 32'd0;
            challenge    <= 64'd0;
            fe_done_seen <= 1'b0;
            dev_sel      <= 2'd0;
            pair_cfg     <= 384'd0;
            d2h_seq      <= 8'd0;
            d2h_status   <= 32'd0;
            d2h_data     <= 768'd0;
            led          <= 4'd0;
        end else begin
            if (fe_done) fe_done_seen <= 1'b1;
            if (io_write) begin
                case (blk)
                    4'h1: begin
                        if (off == 10'h000) begin
                            fe_cmd       <= mem_wdata[2:0];
                            fe_cmd_valid <= 1'b1;
                            fe_done_seen <= 1'b0;
                        end
                        if (off == 10'h008) enrol_msg[31:0]  <= mem_wdata;
                        if (off == 10'h00C) enrol_msg[55:32] <= mem_wdata[23:0];
                        for (w = 0; w < 4; w = w + 1)
                            if (off == 10'h010 + 4 * w) helper_in[32*w +: 32] <= mem_wdata;
                        if (off == 10'h020) kcv_in <= mem_wdata;
                        if (off == 10'h024) challenge[31:0]  <= mem_wdata;
                        if (off == 10'h028) challenge[63:32] <= mem_wdata;
                        if (off == 10'h054) dev_sel <= mem_wdata[1:0];
                        for (w = 0; w < 12; w = w + 1)
                            if (off == 10'h080 + 4 * w) pair_cfg[32*w +: 32] <= mem_wdata;
                    end
                    4'h2: begin
                        if (off == 10'h100) d2h_seq    <= mem_wdata[7:0];
                        if (off == 10'h104) d2h_status <= mem_wdata;
                        for (w = 0; w < 24; w = w + 1)
                            if (off == 10'h140 + 4 * w) d2h_data[32*w +: 32] <= mem_wdata;
                    end
                    4'h3: if (off == 10'h000) led <= mem_wdata[3:0];
                    default: ;
                endcase
            end
        end
    end

    // --------------------------------------------------------------- reads
    reg [31:0] rd;
    always @* begin
        rd = 32'd0;
        case (blk)
            4'h1: begin
                if (off == 10'h004) rd = {25'd0, fe_kcv_ok, fe_ecc_ok, key_valid, fe_locked,
                                          fe_cmd_err, fe_done_seen, fe_busy};
                for (w = 0; w < 4; w = w + 1)
                    if (off == 10'h030 + 4 * w) rd = helper_out[32*w +: 32];
                if (off == 10'h040) rd = kcv_out;
                if (off == 10'h044) rd = tag[31:0];
                if (off == 10'h048) rd = tag[63:32];
                if (off == 10'h050) rd = {30'd0, sel_done, puf_busy | sel_req | sel_wait | meas_req | meas_wait};
                if (off == 10'h054) rd = {30'd0, dev_sel};
                for (w = 0; w < 12; w = w + 1) begin
                    if (off == 10'h080 + 4 * w) rd = pair_cfg[32*w +: 32];
                    if (off == 10'h0C0 + 4 * w) rd = puf_cfg_best[32*w +: 32];
                end
            end
            4'h2: begin
                if (off == 10'h000) rd = {24'd0, h2d_seq};
                if (off == 10'h004) rd = {24'd0, h2d_cmd};
                for (w = 0; w < 24; w = w + 1)
                    if (off == 10'h040 + 4 * w) rd = h2d_arg[32*w +: 32];
            end
            4'h3: begin
                if (off == 10'h000) rd = {28'd0, led};
                if (off == 10'h004) rd = {24'd0, btn, sw};
                if (off == 10'h008) rd = cycles;
            end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        io_ready <= io_req;
        if (io_req) io_rdata <= rd;
    end

endmodule
