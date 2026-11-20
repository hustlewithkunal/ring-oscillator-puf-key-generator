`timescale 1ns / 1ps
// Self-checking testbench for siphash24 against model/vectors/siphash.mem:
// the 64 reference vectors, 200 random cases, and the KDF/KCV/MAC messages
// exactly as the fuzzy extractor uses them. For every vector the message is
// split into blocks (last block = remaining bytes + length byte) and the
// latency is checked against 3 * blocks + 5 cycles.
// In Vivado, add model/vectors/siphash.mem as a simulation source.

module tb_siphash24;

    localparam N_VEC = 278;

    reg [711:0] vec [0:N_VEC-1];   // [711:584] key, [583:576] len, [575:64] msg, [63:0] tag

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg          init = 1'b0;
    reg  [127:0] key = 128'd0;
    reg          blk_valid = 1'b0;
    reg  [63:0]  blk = 64'd0;
    reg          blk_last = 1'b0;
    wire         ready, tag_valid;
    wire [63:0]  tag;

    always #5 clk = ~clk;

    siphash24 dut (
        .clk(clk), .rst(rst), .init(init), .key(key),
        .blk_valid(blk_valid), .blk(blk), .blk_last(blk_last),
        .ready(ready), .tag_valid(tag_valid), .tag(tag));

    integer k, b, n_blocks, len, cycles, errors, lat_errors;
    reg [711:0] v;
    reg [511:0] msg;

    initial begin
        $readmemh("siphash.mem", vec);
        errors = 0;
        lat_errors = 0;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;

        for (k = 0; k < N_VEC; k = k + 1) begin
            v        = vec[k];
            len      = v[583:576];
            msg      = v[575:64];
            n_blocks = len / 8 + 1;

            // load the key
            @(negedge clk);
            key  = v[711:584];
            init = 1'b1;
            @(negedge clk);
            init = 1'b0;

            // feed the blocks as soon as the core is ready, count cycles from the first one
            cycles = 0;
            for (b = 0; b < n_blocks; b = b + 1) begin
                while (!ready) begin
                    @(negedge clk);
                    cycles = cycles + 1;
                end
                blk_valid = 1'b1;
                blk_last  = (b == n_blocks - 1);
                if (blk_last)   // remaining bytes (already zero padded) + length byte
                    blk = {len[7:0], msg[64*b +: 56] & ((56'd1 << (8 * (len % 8))) - 56'd1)};
                else
                    blk = msg[64*b +: 64];
                @(negedge clk);
                cycles = cycles + 1;
                blk_valid = 1'b0;
                blk_last  = 1'b0;
            end
            while (!tag_valid) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            if (tag !== v[63:0]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH vector %0d (len %0d): got %h expected %h", k, len, tag, v[63:0]);
            end
            if (cycles != 3 * n_blocks + 5) begin
                lat_errors = lat_errors + 1;
                if (lat_errors <= 5)
                    $display("LATENCY vector %0d: %0d cycles for %0d blocks, expected %0d",
                             k, cycles, n_blocks, 3 * n_blocks + 5);
            end
        end

        if (errors == 0 && lat_errors == 0)
            $display("PASS: siphash24 matches all %0d vectors (64 reference, 200 random, 14 design messages); latency = 3*blocks + 5 cycles",
                     N_VEC);
        else
            $display("FAIL: %0d tag mismatches, %0d latency mismatches", errors, lat_errors);
        $finish;
    end

endmodule
