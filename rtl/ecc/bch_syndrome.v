// BCH(15,7,2) syndromes S1 = r(alpha), S3 = r(alpha^3) over GF(2^4), p(x) = x^4 + x + 1.
// Each received bit i that is set contributes the constant alpha^i (S1) or alpha^(3i) (S3),
// so both syndromes are pure XOR networks: no GF multiplier is needed.

`timescale 1ns / 1ps

module bch_syndrome (
    input  wire [14:0] r,
    output reg  [3:0]  s1,
    output reg  [3:0]  s3
);

    function [3:0] alpha_pow;          // alpha^n, n = 0..14
        input integer n;
        case (n)
            0: alpha_pow = 4'h1;   1: alpha_pow = 4'h2;   2: alpha_pow = 4'h4;
            3: alpha_pow = 4'h8;   4: alpha_pow = 4'h3;   5: alpha_pow = 4'h6;
            6: alpha_pow = 4'hC;   7: alpha_pow = 4'hB;   8: alpha_pow = 4'h5;
            9: alpha_pow = 4'hA;  10: alpha_pow = 4'h7;  11: alpha_pow = 4'hE;
           12: alpha_pow = 4'hF;  13: alpha_pow = 4'hD;  14: alpha_pow = 4'h9;
            default: alpha_pow = 4'h0;
        endcase
    endfunction

    integer i;
    always @* begin
        s1 = 4'h0;
        s3 = 4'h0;
        for (i = 0; i < 15; i = i + 1) begin
            if (r[i]) begin
                s1 = s1 ^ alpha_pow(i);
                s3 = s3 ^ alpha_pow((3 * i) % 15);
            end
        end
    end

endmodule
