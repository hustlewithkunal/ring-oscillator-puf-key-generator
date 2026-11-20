// GF(2^4) multiplier wrapper: one place to choose the implementation.
//   USE_SOP = 1 : ESPRESSO-minimised sum of products (gf16_mul_sop, the project's ESPRESSO block)
//   USE_SOP = 0 : XOR-based Mastrovito multiplier    (gf16_mul_xor, half the LUTs on 7-series)

`timescale 1ns / 1ps

module gf16_mul #(
    parameter USE_SOP = 1
) (
    input  wire [3:0] a,
    input  wire [3:0] b,
    output wire [3:0] p
);

    generate
        if (USE_SOP) begin : g_sop
            gf16_mul_sop u_mul (.a(a), .b(b), .p(p));
        end else begin : g_xor
            gf16_mul_xor u_mul (.a(a), .b(b), .p(p));
        end
    endgenerate

endmodule
