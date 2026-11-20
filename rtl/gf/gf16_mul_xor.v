// GF(2^4) multiplier p = a * b, p(x) = x^4 + x + 1 -- XOR-based (Mastrovito) form.
// Reference design for comparison with the ESPRESSO sum-of-products version.
//
// 1. Polynomial product c(x) = a(x) * b(x), degree <= 6:
//      c_k = XOR of a_i & b_j over all i + j = k          (16 AND gates)
// 2. Reduction with x^4 = x + 1, x^5 = x^2 + x, x^6 = x^3 + x^2:
//      p0 = c0 ^ c4
//      p1 = c1 ^ c4 ^ c5
//      p2 = c2 ^ c5 ^ c6
//      p3 = c3 ^ c6

`timescale 1ns / 1ps

module gf16_mul_xor (
    input  wire [3:0] a,
    input  wire [3:0] b,
    output wire [3:0] p
);

    wire [6:0] c;

    assign c[0] = a[0] & b[0];
    assign c[1] = (a[1] & b[0]) ^ (a[0] & b[1]);
    assign c[2] = (a[2] & b[0]) ^ (a[1] & b[1]) ^ (a[0] & b[2]);
    assign c[3] = (a[3] & b[0]) ^ (a[2] & b[1]) ^ (a[1] & b[2]) ^ (a[0] & b[3]);
    assign c[4] = (a[3] & b[1]) ^ (a[2] & b[2]) ^ (a[1] & b[3]);
    assign c[5] = (a[3] & b[2]) ^ (a[2] & b[3]);
    assign c[6] = a[3] & b[3];

    assign p[0] = c[0] ^ c[4];
    assign p[1] = c[1] ^ c[4] ^ c[5];
    assign p[2] = c[2] ^ c[5] ^ c[6];
    assign p[3] = c[3] ^ c[6];

endmodule
