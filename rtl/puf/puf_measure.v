// RO-PUF measurement unit: N_ARR arrays of 256 configurable ROs (128 pairs each),
// one pair measured at a time with two gated counters.
//
// For pair p of the selected array:
//   1. enable RO 2p and RO 2p+1 only (others stay off: less coupling, less self-heating)
//   2. let them settle, clear both counters
//   3. open the gate for 2^wlog cycles of clk; each counter counts the edges of its
//      RO's toggle output (RO frequency / 2) in that RO's own clock domain
//   4. close the gate, wait, stop the ROs; the counts are now static and are read
//      into the clk domain without a synchroniser
//   5. response bit p = (count A > count B)
//
// Modes:
//   MODE_MEASURE  128-bit response; pair p uses configuration pair_cfg[3p+2:3p]
//                 (all zero = baseline RO-PUF)
//   MODE_SELECT   for every pair try all 8 configurations and keep the one with the
//                 largest |count A - count B| (most reliable bit) -> cfg_best
//                 (configurable-RO enrolment, Maiti & Schaumont 2011)
// Raw counts of the last MEASURE are readable through rd_pair (for characterisation).

`timescale 1ns / 1ps

module puf_measure #(
    parameter N_ARR = 3,            // independent RO arrays ("virtual devices")
    parameter CW    = 20            // counter width
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,     // pulse, sampled when !busy
    input  wire          mode,      // 0 = MEASURE, 1 = SELECT
    input  wire [1:0]    arr_sel,   // which array
    input  wire [3:0]    wlog,      // gate window = 2^wlog clk cycles (8..15)
    input  wire [383:0]  pair_cfg,  // MEASURE: configuration of pair p at [3p+2:3p]
    output reg           busy,
    output reg           done,      // one-cycle pulse
    output reg  [127:0]  response,
    output reg  [383:0]  cfg_best,  // SELECT result
    input  wire [6:0]    rd_pair,
    output wire [CW-1:0] rd_cnt_a,
    output wire [CW-1:0] rd_cnt_b
);

    localparam [2:0] S_IDLE   = 3'd0,
                     S_SETTLE = 3'd1,
                     S_CLEAR  = 3'd2,
                     S_GATE   = 3'd3,
                     S_DRAIN  = 3'd4,
                     S_EVAL   = 3'd5,
                     S_OFF    = 3'd6;

    reg [2:0]  state;
    reg        mode_q;
    reg [1:0]  arr_q;
    reg [3:0]  wlog_q;
    reg [6:0]  pair;
    reg [2:0]  cfg_try;         // SELECT: configuration being tried
    reg [2:0]  cur_cfg;
    reg        run;             // selected pair enabled
    reg        clr;             // clears the counters (asynchronous in the RO domains)
    reg        gate;
    reg [15:0] timer;
    reg [CW-1:0] best_d;
    reg [2:0]  best_c;

    // ----------------------------------------------------------- RO arrays
    wire [256*N_ARR-1:0] tog_all;
    wire [255:0] en_pair = run ? ({254'd0, 2'b11} << {pair, 1'b0}) : 256'd0;

    genvar a;
    generate
        for (a = 0; a < N_ARR; a = a + 1) begin : g_arr
            ro_array #(.N_RO(256)) u_arr (
                .en (arr_q == a ? en_pair : 256'd0),
                .cfg(cur_cfg),
                .tog(tog_all[256*a +: 256]));
        end
    endgenerate

    // the two toggle signals of the selected pair become the counter clocks
    wire clk_a = tog_all[256*arr_q + {pair, 1'b0}];
    wire clk_b = tog_all[256*arr_q + {pair, 1'b1}];

    // --------------------------------------------- counters (RO clock domains)
    (* ASYNC_REG = "TRUE" *) reg [1:0] gs_a, gs_b;
    reg [CW-1:0] cnt_a, cnt_b;

    always @(posedge clk_a or posedge clr)
        if (clr) begin gs_a <= 2'b00; cnt_a <= {CW{1'b0}}; end
        else     begin gs_a <= {gs_a[0], gate}; if (gs_a[1]) cnt_a <= cnt_a + 1'b1; end

    always @(posedge clk_b or posedge clr)
        if (clr) begin gs_b <= 2'b00; cnt_b <= {CW{1'b0}}; end
        else     begin gs_b <= {gs_b[0], gate}; if (gs_b[1]) cnt_b <= cnt_b + 1'b1; end

    // counts are static in S_EVAL (gate closed, ROs drained), so plain sampling is safe
    wire [CW-1:0] diff = (cnt_a > cnt_b) ? (cnt_a - cnt_b) : (cnt_b - cnt_a);

    // ------------------------------------------------- raw count memory
    reg [CW-1:0] mem_a [0:127];
    reg [CW-1:0] mem_b [0:127];
    assign rd_cnt_a = mem_a[rd_pair];
    assign rd_cnt_b = mem_b[rd_pair];

    // ------------------------------------------------------------ control
    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            mode_q   <= 1'b0;
            arr_q    <= 2'd0;
            wlog_q   <= 4'd13;
            pair     <= 7'd0;
            cfg_try  <= 3'd0;
            cur_cfg  <= 3'd0;
            run      <= 1'b0;
            clr      <= 1'b1;
            gate     <= 1'b0;
            timer    <= 16'd0;
            best_d   <= {CW{1'b0}};
            best_c   <= 3'd0;
            response <= 128'd0;
            cfg_best <= 384'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    clr <= 1'b1;
                    if (start) begin
                        busy    <= 1'b1;
                        mode_q  <= mode;
                        arr_q   <= arr_sel;
                        wlog_q  <= (wlog < 4'd8) ? 4'd8 : (wlog > 4'd15) ? 4'd15 : wlog;
                        pair    <= 7'd0;
                        cfg_try <= 3'd0;
                        cur_cfg <= mode ? 3'd0 : pair_cfg[2:0];
                        best_d  <= {CW{1'b0}};
                        best_c  <= 3'd0;
                        run     <= 1'b1;
                        timer   <= 16'd0;
                        state   <= S_SETTLE;
                    end
                end
                S_SETTLE: begin                         // ROs start, multiplexers settle
                    timer <= timer + 16'd1;
                    if (timer == 16'd31) begin
                        clr   <= 1'b1;
                        timer <= 16'd0;
                        state <= S_CLEAR;
                    end
                end
                S_CLEAR: begin                          // release the counter clear
                    clr   <= 1'b0;
                    timer <= timer + 16'd1;
                    if (timer == 16'd7) begin
                        gate  <= 1'b1;
                        timer <= 16'd0;
                        state <= S_GATE;
                    end
                end
                S_GATE: begin
                    timer <= timer + 16'd1;
                    if (timer == (16'd1 << wlog_q) - 16'd1) begin
                        gate  <= 1'b0;
                        timer <= 16'd0;
                        state <= S_DRAIN;
                    end
                end
                S_DRAIN: begin                          // gate-low reaches both RO domains
                    timer <= timer + 16'd1;
                    if (timer == 16'd15) begin
                        run   <= 1'b0;                  // stop the ROs: counts frozen
                        timer <= 16'd0;
                        state <= S_EVAL;
                    end
                end
                S_EVAL: begin
                    timer <= timer + 16'd1;
                    if (timer == 16'd3) begin
                        timer <= 16'd0;
                        if (!mode_q) begin
                            response[pair] <= (cnt_a > cnt_b);
                            mem_a[pair]    <= cnt_a;
                            mem_b[pair]    <= cnt_b;
                        end else if (cfg_try == 3'd0 || diff > best_d) begin
                            best_d <= diff;
                            best_c <= cfg_try;
                            if (cfg_try == 3'd7) cfg_best[3*pair +: 3] <= cfg_try;
                        end else if (cfg_try == 3'd7) begin
                            cfg_best[3*pair +: 3] <= best_c;
                        end
                        state <= S_OFF;
                    end
                end
                S_OFF: begin                            // next configuration / pair
                    if (mode_q && cfg_try != 3'd7) begin
                        cfg_try <= cfg_try + 3'd1;
                        cur_cfg <= cfg_try + 3'd1;
                        run     <= 1'b1;
                        state   <= S_SETTLE;
                    end else if (pair != 7'd127) begin
                        pair    <= pair + 7'd1;
                        cfg_try <= 3'd0;
                        cur_cfg <= mode_q ? 3'd0 : pair_cfg[3*(pair + 7'd1) +: 3];
                        best_d  <= {CW{1'b0}};
                        run     <= 1'b1;
                        state   <= S_SETTLE;
                    end else begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
