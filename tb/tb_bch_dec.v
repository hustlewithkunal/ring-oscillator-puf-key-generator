`timescale 1ns / 1ps
// Self-checking testbench for the hand-HLS BCH(15,7,2) decoders.
// Four DUTs run side by side on every vector of model/vectors/bch_dec.mem:
//   dut 0: bch_dec_1mul, ESPRESSO multiplier     dut 1: bch_dec_1mul, XOR multiplier
//   dut 2: bch_dec_2mul, ESPRESSO multipliers    dut 3: bch_dec_2mul, XOR multipliers
// Every intermediate value (S1, S3, Lambda1, Lambda2, error mask, corrected, ok)
// is compared with the golden model, and the latency of each decode is measured.
// In Vivado, add model/vectors/bch_dec.mem as a simulation source.

module tb_bch_dec;

    localparam N_VEC = 17488;
    localparam N_DUT = 4;

    reg [67:0] vec [0:N_VEC-1];   // see the header of bch_dec.mem for the layout

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg        start = 1'b0;
    reg [14:0] r = 15'd0;

    wire [N_DUT-1:0]    busy, done, ok;
    wire [4*N_DUT-1:0]  s1, s3, l1, l2;
    wire [15*N_DUT-1:0] err_mask, corrected;

    always #5 clk = ~clk;

    genvar g;
    generate
        for (g = 0; g < N_DUT; g = g + 1) begin : dut
            if (g < 2) begin : one_mul
                bch_dec_1mul #(.USE_SOP(g == 0)) u (
                    .clk(clk), .rst(rst), .start(start), .r(r),
                    .busy(busy[g]), .done(done[g]),
                    .s1(s1[4*g +: 4]), .s3(s3[4*g +: 4]), .l1(l1[4*g +: 4]), .l2(l2[4*g +: 4]),
                    .err_mask(err_mask[15*g +: 15]), .corrected(corrected[15*g +: 15]), .ok(ok[g]));
            end else begin : two_mul
                bch_dec_2mul #(.USE_SOP(g == 2)) u (
                    .clk(clk), .rst(rst), .start(start), .r(r),
                    .busy(busy[g]), .done(done[g]),
                    .s1(s1[4*g +: 4]), .s3(s3[4*g +: 4]), .l1(l1[4*g +: 4]), .l2(l2[4*g +: 4]),
                    .err_mask(err_mask[15*g +: 15]), .corrected(corrected[15*g +: 15]), .ok(ok[g]));
            end
        end
    endgenerate

    integer k, d, n, errors;
    integer lat_min [0:N_DUT-1];
    integer lat_max [0:N_DUT-1];
    integer fails   [0:N_DUT-1];
    reg [N_DUT-1:0] finished;
    reg [67:0] v;

    task check_dut;
        input integer id;
        input integer latency;
        begin
            if (latency < lat_min[id]) lat_min[id] = latency;
            if (latency > lat_max[id]) lat_max[id] = latency;
            if ({s1[4*id +: 4], s3[4*id +: 4], l1[4*id +: 4], l2[4*id +: 4],
                 err_mask[15*id +: 15], corrected[15*id +: 15], ok[id]}
                !== {v[51:48], v[47:44], v[43:40], v[39:36], v[34:20], v[18:4], v[0]}) begin
                fails[id] = fails[id] + 1;
                errors    = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH dut%0d vector %0d r=%h: got S1=%h S3=%h L1=%h L2=%h mask=%h corr=%h ok=%b, expected S1=%h S3=%h L1=%h L2=%h mask=%h corr=%h ok=%b",
                             id, k, v[66:52], s1[4*id +: 4], s3[4*id +: 4], l1[4*id +: 4], l2[4*id +: 4],
                             err_mask[15*id +: 15], corrected[15*id +: 15], ok[id],
                             v[51:48], v[47:44], v[43:40], v[39:36], v[34:20], v[18:4], v[0]);
            end
        end
    endtask

    initial begin
        $readmemh("bch_dec.mem", vec);
        errors = 0;
        for (d = 0; d < N_DUT; d = d + 1) begin
            lat_min[d] = 1000;
            lat_max[d] = 0;
            fails[d]   = 0;
        end

        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        for (k = 0; k < N_VEC; k = k + 1) begin
            v = vec[k];
            // start is sampled by every DUT on the next rising edge ("cycle 0")
            @(negedge clk);
            r     = v[66:52];
            start = 1'b1;
            @(posedge clk);
            #1 start = 1'b0;

            finished = {N_DUT{1'b0}};
            n = 0;
            while (finished != {N_DUT{1'b1}} && n < 100) begin
                @(posedge clk);
                #1 n = n + 1;
                for (d = 0; d < N_DUT; d = d + 1) begin
                    if (done[d] && !finished[d]) begin
                        finished[d] = 1'b1;
                        check_dut(d, n);
                    end
                end
            end
            if (finished != {N_DUT{1'b1}}) begin
                $display("TIMEOUT at vector %0d (finished = %b)", k, finished);
                errors = errors + 1;
            end
        end

        $display("--------------------------------------------------------------");
        $display("dut  architecture        multiplier   latency (cycles)  mismatches");
        $display("0    1 GF multiplier     ESPRESSO     %0d..%0d             %0d", lat_min[0], lat_max[0], fails[0]);
        $display("1    1 GF multiplier     XOR          %0d..%0d             %0d", lat_min[1], lat_max[1], fails[1]);
        $display("2    2 GF multipliers    ESPRESSO     %0d..%0d             %0d", lat_min[2], lat_max[2], fails[2]);
        $display("3    2 GF multipliers    XOR          %0d..%0d             %0d", lat_min[3], lat_max[3], fails[3]);
        if (errors == 0)
            $display("PASS: all 4 decoders match the golden model on %0d vectors", N_VEC);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
