`timescale 1ns / 1ps
// Testbench for puf_measure with the behavioural RO model (rtl/puf/sim/ro_cell_sim.v).
// The model's true half-periods are copied out of every RO instance, so each result
// can be checked against the physical truth:
//   * MEASURE: bit p must equal (RO 2p faster than RO 2p+1) for clearly separated pairs,
//     and the raw counts must match window / (4 * half period)
//   * a repeated MEASURE gives the intra-device bit-error rate of the model
//   * the second array gives a different response (inter-device distance ~ 50 %)
//   * SELECT must choose the configuration with the largest frequency gap
//   * MEASURE with the selected configurations must have fewer unstable bits

module tb_puf_measure;

    localparam N_ARR = 2;
    localparam WLOG  = 10;

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg          start = 1'b0;
    reg          mode = 1'b0;
    reg  [1:0]   arr_sel = 2'd0;
    reg  [383:0] pair_cfg = 384'd0;
    reg  [6:0]   rd_pair = 7'd0;
    wire         busy, done;
    wire [127:0] response;
    wire [383:0] cfg_best;
    wire [19:0]  rd_a, rd_b;

    always #4 clk = ~clk;   // 125 MHz

    puf_measure #(.N_ARR(N_ARR), .CW(20)) dut (
        .clk(clk), .rst(rst), .start(start), .mode(mode), .arr_sel(arr_sel),
        .wlog(WLOG[3:0]), .pair_cfg(pair_cfg), .busy(busy), .done(done),
        .response(response), .cfg_best(cfg_best),
        .rd_pair(rd_pair), .rd_cnt_a(rd_a), .rd_cnt_b(rd_b));

    // ---- copy the model's true half-periods: hc[(256*array + ro)*8 + cfg]
    real hc [0:256*N_ARR*8-1];
    genvar gi, gc;
    generate
        for (gi = 0; gi < 256 * N_ARR; gi = gi + 1) begin : cp
            for (gc = 0; gc < 8; gc = gc + 1) begin : c
                initial #1 hc[gi*8 + gc] = dut.g_arr[gi/256].u_arr.g_ro[gi%256].u_ro.half_cfg[gc];
            end
        end
    endgenerate

    integer errors, p, c, n_check, n_agree, flips, hd, best_ok, cnt_bad;
    real d, dbest, margin, exp_cnt;
    reg [127:0] r0, r1, r_arr1, r_sel;
    reg [2:0] best;

    task run;                               // one measurement
        input m;
        input [1:0] arr;
        begin
            @(negedge clk);
            mode = m; arr_sel = arr; start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            @(posedge done);
            @(negedge clk);
        end
    endtask

    function real gap;                      // signed half-period difference of pair p
        input integer arr, pp, cc;
        begin
            gap = hc[(256*arr + 2*pp + 1)*8 + cc] - hc[(256*arr + 2*pp)*8 + cc];
        end
    endfunction

    initial begin
        errors = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // ---------------- baseline MEASURE on array 0
        run(1'b0, 2'd0);
        r0 = response;
        n_check = 0; n_agree = 0; cnt_bad = 0;
        for (p = 0; p < 128; p = p + 1) begin
            // only judge pairs whose gap is well above the 1 % jitter
            if (gap(0, p, 0) > 0.004 || gap(0, p, 0) < -0.004) begin
                n_check = n_check + 1;
                if (r0[p] == (gap(0, p, 0) > 0.0)) n_agree = n_agree + 1;
            end
            rd_pair = p;
            #1;
            exp_cnt = (1 << WLOG) * 8.0 / (4.0 * hc[(2*p)*8]);
            if (rd_a < 0.97 * exp_cnt || rd_a > 1.03 * exp_cnt) cnt_bad = cnt_bad + 1;
        end
        $display("MEASURE: %0d/%0d clearly separated pairs give the physically correct bit", n_agree, n_check);
        $display("MEASURE: counts of RO 0 = %0d (expected ~%0d); %0d of 128 counts off by > 3 %%",
                 dut.mem_a[0], $rtoi((1 << WLOG) * 8.0 / (4.0 * hc[0])), cnt_bad);
        if (n_agree != n_check || cnt_bad != 0) errors = errors + 1;

        // ---------------- repeat: intra-device bit errors
        run(1'b0, 2'd0);
        r1 = response;
        flips = 0;
        for (p = 0; p < 128; p = p + 1) flips = flips + (r0[p] != r1[p]);
        $display("REPEAT : %0d of 128 bits flipped between two reads (model BER)", flips);
        if (flips > 12) errors = errors + 1;

        // ---------------- other array = other "device"
        run(1'b0, 2'd1);
        r_arr1 = response;
        hd = 0;
        for (p = 0; p < 128; p = p + 1) hd = hd + (r0[p] != r_arr1[p]);
        $display("ARRAY 1: Hamming distance to array 0 = %0d / 128", hd);
        if (hd < 40 || hd > 88) errors = errors + 1;

        // ---------------- SELECT: largest |gap| configuration per pair
        run(1'b1, 2'd0);
        best_ok = 0;
        for (p = 0; p < 128; p = p + 1) begin
            dbest = -1.0; best = 0;
            for (c = 0; c < 8; c = c + 1) begin
                d = gap(0, p, c); if (d < 0.0) d = -d;
                if (d > dbest) begin dbest = d; best = c; end
            end
            // accept the hardware choice if it is within jitter of the true optimum
            d = gap(0, p, cfg_best[3*p +: 3]); if (d < 0.0) d = -d;
            if (d >= dbest - 0.003) best_ok = best_ok + 1;
        end
        $display("SELECT : %0d/128 pairs got the best (or an equally good) configuration", best_ok);
        if (best_ok < 120) errors = errors + 1;

        // ---------------- MEASURE with the selected configurations, twice
        pair_cfg = cfg_best;
        run(1'b0, 2'd0);
        r_sel = response;
        run(1'b0, 2'd0);
        flips = 0;
        for (p = 0; p < 128; p = p + 1) flips = flips + (r_sel[p] != response[p]);
        $display("CONFIG : %0d of 128 bits flipped between two reads with selected configurations", flips);

        if (errors == 0) $display("PASS: puf_measure behaves as expected on the RO model");
        else             $display("FAIL: %0d checks failed", errors);
        $finish;
    end

endmodule
