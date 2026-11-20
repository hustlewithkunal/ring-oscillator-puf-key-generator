// Characterisation top level for the Zybo Z7-10: the RO-PUF measurement unit with three
// arrays ("virtual devices"), the heater, and a VIO core so that the host PC drives
// everything over JTAG (scripts/hw/*.tcl). This build deliberately exposes raw
// responses and counts: it is for measuring the PUF, never for holding a key.
//
// LEDs: LD0 busy, LD1 heater on, LD2 heartbeat (~1 Hz, flickers while heating),
//       LD3 toggles on every done.

`timescale 1ns / 1ps

module top_char (
    input  wire       sysclk,       // 125 MHz, pin K17
    output wire [3:0] led
);

    wire clk = sysclk;

    // ------------------------------------------------------------- VIO
    wire         v_rst, v_start_tog, v_mode, v_heat;
    wire [1:0]   v_arr, v_cfg_src;
    wire [3:0]   v_wlog;
    wire [2:0]   v_cfg;
    wire [6:0]   v_rd_pair;
    wire [383:0] v_cfg_host;        // configuration vector loaded by the host (helper data)

    wire         busy, done;
    wire [127:0] response;
    wire [383:0] cfg_best;
    wire [19:0]  rd_a, rd_b;
    reg  [15:0]  done_cnt = 16'd0;

    vio_char u_vio (
        .clk        (clk),
        .probe_in0  (response),         // 128
        .probe_in1  (busy),             // 1
        .probe_in2  (done_cnt),         // 16
        .probe_in3  (rd_a),             // 20
        .probe_in4  (rd_b),             // 20
        .probe_in5  (cfg_best[191:0]),  // 192
        .probe_in6  (cfg_best[383:192]),// 192
        .probe_out0 (v_rst),            // 1
        .probe_out1 (v_start_tog),      // 1
        .probe_out2 (v_mode),           // 1
        .probe_out3 (v_arr),            // 2
        .probe_out4 (v_wlog),           // 4
        .probe_out5 (v_cfg),            // 3
        .probe_out6 (v_cfg_src),        // 2
        .probe_out7 (v_rd_pair),        // 7
        .probe_out8 (v_heat),           // 1
        .probe_out9 (v_cfg_host[191:0]),   // 192
        .probe_out10(v_cfg_host[383:192]));// 192

    // start = any change of the VIO start toggle
    reg start_q = 1'b0;
    always @(posedge clk) start_q <= v_start_tog;
    wire start = v_start_tog ^ start_q;

    always @(posedge clk)
        if (v_rst)     done_cnt <= 16'd0;
        else if (done) done_cnt <= done_cnt + 16'd1;

    // pair configuration: 0 = one configuration for all pairs, 1 = result of the last
    // SELECT, 2 = vector loaded by the host (a stored enrolment, like helper data)
    wire [383:0] pair_cfg = (v_cfg_src == 2'd1) ? cfg_best :
                            (v_cfg_src == 2'd2) ? v_cfg_host : {128{v_cfg}};

    puf_measure #(.N_ARR(3), .CW(20)) u_puf (
        .clk(clk), .rst(v_rst), .start(start), .mode(v_mode), .arr_sel(v_arr),
        .wlog(v_wlog), .pair_cfg(pair_cfg), .busy(busy), .done(done),
        .response(response), .cfg_best(cfg_best),
        .rd_pair(v_rd_pair), .rd_cnt_a(rd_a), .rd_cnt_b(rd_b));

    // ------------------------------------------------------------ heater
    wire heat_alive;
    heater #(.N_FF(2048), .N_DSP(64)) u_heat (.clk(clk), .en(v_heat), .alive(heat_alive));

    // -------------------------------------------------------------- LEDs
    reg [26:0] hb = 27'd0;
    reg        done_led = 1'b0;
    always @(posedge clk) begin
        hb <= hb + 27'd1;
        if (done) done_led <= ~done_led;
    end
    // LD2 flickers while the heater runs (keeps the heater logic observable, so it stays)
    assign led = {done_led, hb[26] ^ heat_alive, v_heat, busy};

endmodule
