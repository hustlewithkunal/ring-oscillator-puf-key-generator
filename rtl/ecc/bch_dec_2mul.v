// BCH(15,7,2) decoder: hand-HLS schedule with TWO GF(2^4) multipliers (MA, MB).
// Design notes (DFG, ASAP/ALAP, schedule, binding): docs/Phase4_BCH_HLS.md
//
// Schedule (one row = one clock cycle):
//   SYN         S1, S3 <- syndromes(r)                         XOR network only
//   P           MA = S1 * S1,  MB = S3 * S1^-1    L2 <- MA ^ MB,  L1 <- S1
//   CHIEN x15   position i = 0..14, one cycle each:
//                 MA = L1 * x_i,  MB = L2 * x_i^2   bit i in error iff 1 ^ MA ^ MB == 0
//   CHECK       ok = (roots == deg Lambda), clear the mask on failure
//
// Latency is constant: done rises 18 cycles after start is sampled.
// Same interface and behaviour as bch_dec_1mul, so the two are interchangeable.

`timescale 1ns / 1ps

module bch_dec_2mul #(
    parameter USE_SOP = 1           // 1: ESPRESSO multipliers, 0: Mastrovito XOR multipliers
) (
    input  wire        clk,
    input  wire        rst,         // synchronous, active high
    input  wire        start,       // sampled in IDLE together with r
    input  wire [14:0] r,           // received word
    output wire        busy,
    output reg         done,        // one-cycle pulse; outputs hold until the next start
    output reg  [3:0]  s1,
    output reg  [3:0]  s3,
    output reg  [3:0]  l1,
    output reg  [3:0]  l2,
    output reg  [14:0] err_mask,
    output wire [14:0] corrected,
    output reg         ok
);

    localparam IDLE  = 3'd0,
               SYN   = 3'd1,
               P     = 3'd2,
               CHIEN = 3'd3,
               CHECK = 3'd4;

    reg [2:0]  state;
    reg [14:0] r_q;
    reg [3:0]  i;           // Chien position
    reg [1:0]  roots;       // a degree-2 locator has at most 2 roots

    wire [3:0] syn1, syn3, inv_s1, x, x2, pa, pb;
    reg  [3:0] aa, ab, ba, bb;

    bch_syndrome u_syn   (.r(r_q), .s1(syn1), .s3(syn3));
    gf16_inv_sop u_inv   (.a(s1), .y(inv_s1));
    bch_chien_x  u_chien (.i(i), .x(x), .x2(x2));
    gf16_mul #(.USE_SOP(USE_SOP)) u_mul_a (.a(aa), .b(ab), .p(pa));
    gf16_mul #(.USE_SOP(USE_SOP)) u_mul_b (.a(ba), .b(bb), .p(pb));

    // binding: operands of MA and MB in each control step
    always @* begin
        if (state == P) begin
            aa = s1;  ab = s1;          // MA: S1^2
            ba = s3;  bb = inv_s1;      // MB: S3 * S1^-1
        end else begin
            aa = l1;  ab = x;           // MA: L1 * x_i
            ba = l2;  bb = x2;          // MB: L2 * x_i^2
        end
    end

    wire is_root = ((4'h1 ^ pa ^ pb) == 4'h0);
    wire ok_now  = (s1 == 4'h0) ? (s3 == 4'h0)
                                : (roots == ((l2 != 4'h0) ? 2'd2 : 2'd1));

    assign busy      = (state != IDLE);
    assign corrected = r_q ^ err_mask;

    always @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            done     <= 1'b0;
            ok       <= 1'b0;
            r_q      <= 15'd0;
            s1       <= 4'h0;
            s3       <= 4'h0;
            l1       <= 4'h0;
            l2       <= 4'h0;
            err_mask <= 15'd0;
            i        <= 4'd0;
            roots    <= 2'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    r_q   <= r;
                    state <= SYN;
                end
                SYN: begin
                    s1    <= syn1;
                    s3    <= syn3;
                    state <= P;
                end
                P: begin
                    l1       <= s1;
                    l2       <= pa ^ pb;            // S1^2 + S3 * S1^-1
                    i        <= 4'd0;
                    roots    <= 2'd0;
                    err_mask <= 15'd0;
                    state    <= CHIEN;
                end
                CHIEN: begin
                    if (is_root) begin
                        err_mask[i] <= 1'b1;
                        roots       <= roots + 2'd1;
                    end
                    if (i == 4'd14) state <= CHECK;
                    else            i     <= i + 4'd1;
                end
                CHECK: begin
                    ok    <= ok_now;
                    if (!ok_now) err_mask <= 15'd0;
                    done  <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
