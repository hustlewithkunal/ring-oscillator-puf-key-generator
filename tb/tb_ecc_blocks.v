`timescale 1ns / 1ps
// Exhaustive self-checking testbench for the small ECC blocks:
//   bch_enc    all 128 messages against model/vectors/bch_enc.mem
//   rep_decode every input pattern for REP = 1, 3, 5 against a popcount reference
//   rep_encode every input for REP = 3 and 5, then decoded back
// In Vivado, add model/vectors/bch_enc.mem as a simulation source.

module tb_ecc_blocks;

    reg [23:0] enc_vec [0:127];   // [22:16] message, [14:0] codeword

    reg  [6:0]  msg;
    wire [14:0] cw;
    bch_enc u_enc (.msg(msg), .cw(cw));

    reg  [4:0] code5;             // one data bit, all copies
    wire       d1, d3, d5;
    rep_decode #(.N(1), .REP(1)) u_dec1 (.code(code5[0]),   .data(d1));
    rep_decode #(.N(1), .REP(3)) u_dec3 (.code(code5[2:0]), .data(d3));
    rep_decode #(.N(1), .REP(5)) u_dec5 (.code(code5),      .data(d5));

    reg  [3:0]  data4;            // 4 data bits through encode -> decode
    wire [11:0] c3;
    wire [19:0] c5;
    wire [3:0]  back3, back5;
    rep_encode #(.N(4), .REP(3)) u_e3 (.data(data4), .code(c3));
    rep_encode #(.N(4), .REP(5)) u_e5 (.data(data4), .code(c5));
    rep_decode #(.N(4), .REP(3)) u_b3 (.code(c3), .data(back3));
    rep_decode #(.N(4), .REP(5)) u_b5 (.code(c5), .data(back5));

    integer k, ones, errors;

    initial begin
        $readmemh("bch_enc.mem", enc_vec);
        errors = 0;

        for (k = 0; k < 128; k = k + 1) begin
            msg = enc_vec[k][22:16];
            #1;
            if (cw !== enc_vec[k][14:0]) begin
                errors = errors + 1;
                $display("BCH_ENC MISMATCH msg=%h got %h expected %h", msg, cw, enc_vec[k][14:0]);
            end
        end

        for (k = 0; k < 32; k = k + 1) begin
            code5 = k;
            #1;
            ones = code5[0] + code5[1] + code5[2] + code5[3] + code5[4];
            if (d1 !== code5[0] ||
                d3 !== ((code5[0] + code5[1] + code5[2]) >= 2) ||
                d5 !== (ones >= 3)) begin
                errors = errors + 1;
                $display("REP_DECODE MISMATCH copies=%b: d1=%b d3=%b d5=%b", code5, d1, d3, d5);
            end
        end

        for (k = 0; k < 16; k = k + 1) begin
            data4 = k;
            #1;
            if (c3 !== {{3{data4[3]}}, {3{data4[2]}}, {3{data4[1]}}, {3{data4[0]}}} ||
                back3 !== data4 || back5 !== data4) begin
                errors = errors + 1;
                $display("REP_ENCODE MISMATCH data=%b code3=%b", data4, c3);
            end
        end

        if (errors == 0)
            $display("PASS: bch_enc (128/128), rep_decode (REP 1/3/5, all patterns), rep_encode round trip");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
