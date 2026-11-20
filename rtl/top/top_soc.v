// SoC top level for the Zybo Z7-10: RV32I SoC + fuzzy extractor + RO-PUF (3 arrays),
// with a VIO mailbox so the host PC talks to the firmware over JTAG
// (scripts/hw/soc_host.tcl). This is the secure build: no raw response, no key and no
// RO count is visible anywhere -- only helper data, status and MAC tags.
//
// Board controls:
//   SW1:SW0  device select (RO array 0..2) for commands that pass device 0xFF
//   SW3      boot lock (emulated one-time fuse: 1 = enrolment locked from reset)
//   BTN0     reset
//   LD0 key valid, LD1 locked, LD2 last authentication answered, LD3 heartbeat

`timescale 1ns / 1ps

module top_soc (
    input  wire       sysclk,       // 125 MHz, pin K17
    input  wire [3:0] sw,
    input  wire [3:0] btn,
    output wire [3:0] led
);

    wire clk = sysclk;

    // ------------------------------------------------- reset and input sync
    wire       v_rst;
    reg  [2:0] rst_sync = 3'b111;
    reg  [3:0] sw_q = 4'd0, sw_qq = 4'd0;
    reg  [3:0] btn_q = 4'd0, btn_qq = 4'd0;
    always @(posedge clk) begin
        sw_q  <= sw;   sw_qq  <= sw_q;
        btn_q <= btn;  btn_qq <= btn_q;
        rst_sync <= {rst_sync[1:0], btn_qq[0] | v_rst};
    end
    wire rst = rst_sync[2];

    // ------------------------------------------------------- host mailbox
    wire [7:0]   h2d_seq, h2d_cmd, d2h_seq;
    wire [767:0] h2d_arg, d2h_data;
    wire [31:0]  d2h_status;
    wire         trap, key_valid;

    vio_soc u_vio (
        .clk        (clk),
        .probe_in0  (d2h_seq),              // 8
        .probe_in1  (d2h_status),           // 32
        .probe_in2  (d2h_data[255:0]),      // 256
        .probe_in3  (d2h_data[511:256]),    // 256
        .probe_in4  (d2h_data[767:512]),    // 256
        .probe_in5  ({trap, key_valid, led}),   // 6
        .probe_out0 (h2d_seq),              // 8
        .probe_out1 (h2d_cmd),              // 8
        .probe_out2 (h2d_arg[255:0]),       // 256
        .probe_out3 (h2d_arg[511:256]),     // 256
        .probe_out4 (h2d_arg[767:512]),     // 256
        .probe_out5 (v_rst));               // 1

    // ------------------------------------------------------------ PUF
    wire         puf_start, puf_mode, puf_busy, puf_done;
    wire [1:0]   puf_arr;
    wire [383:0] puf_cfg, puf_cfg_best;
    wire [127:0] puf_response;
    wire [19:0]  unused_a, unused_b;

    puf_measure #(.N_ARR(3), .CW(20)) u_puf (
        .clk(clk), .rst(rst), .start(puf_start), .mode(puf_mode), .arr_sel(puf_arr),
        .wlog(4'd13), .pair_cfg(puf_cfg), .busy(puf_busy), .done(puf_done),
        .response(puf_response), .cfg_best(puf_cfg_best),
        .rd_pair(7'd0), .rd_cnt_a(unused_a), .rd_cnt_b(unused_b));

    // ------------------------------------------------------------- SoC
    soc #(.REP(3), .USE_SOP(1), .FW_FILE("firmware.mem")) u_soc (
        .clk(clk), .rst(rst), .boot_locked(sw_qq[3]),
        .puf_start(puf_start), .puf_mode(puf_mode), .puf_arr(puf_arr), .puf_cfg(puf_cfg),
        .puf_busy(puf_busy), .puf_done(puf_done), .puf_response(puf_response),
        .puf_cfg_best(puf_cfg_best),
        .h2d_seq(h2d_seq), .h2d_cmd(h2d_cmd), .h2d_arg(h2d_arg),
        .d2h_seq(d2h_seq), .d2h_status(d2h_status), .d2h_data(d2h_data),
        .sw(sw_qq), .btn(btn_qq), .led(led), .trap(trap), .key_valid(key_valid));

endmodule
