// BCH(15,7,2) decoder: hand-HLS schedule with ONE shared GF(2^4) multiplier.
// Design notes (DFG, ASAP/ALAP, schedule, binding): docs/Phase4_BCH_HLS.md
//
// Schedule (one row = one clock cycle, M = the shared multiplier):
//   SYN         S1, S3 <- syndromes(r)                      XOR network only
//   P1          M = S1 * S1          L2 <- M,  L1 <- S1
//   P2          M = S3 * S1^-1       L2 <- L2 ^ M          (L2 = S3/S1 + S1^2)
//   CHIEN x30   position i = 0..14, two cycles each:
//                 phase 0: M = L1 * x_i     acc <- 1 ^ M
//                 phase 1: M = L2 * x_i^2   bit i in error iff acc ^ M == 0
//   CHECK       ok = (roots == deg Lambda), clear the mask on failure
//
// Latency is constant: done rises 34 cycles after start is sampled, whatever
// the error pattern (no data-dependent timing). S1 = 0 needs no special path:
// L1 = L2 = 0 then, Lambda = 1 has no roots, and CHECK decides on S3 alone.

`timescale 1ns / 1ps

module bch_dec_1mul #(
    parameter USE_SOP = 1           // 1: ESPRESSO multiplier, 0: Mastrovito XOR multiplier
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
               P1    = 3'd2,
               P2    = 3'd3,
               CHIEN = 3'd4,
               CHECK = 3'd5;

    reg [2:0]  state;
    reg [14:0] r_q;
    reg [3:0]  i;           // Chien position
    reg        phase;       // Chien sub-step
    reg [3:0]  acc;         // 1 + L1*x_i, kept between the two Chien sub-steps
    reg [1:0]  roots;       // a degree-2 locator has at most 2 roots

    wire [3:0] syn1, syn3, inv_s1, x, x2, mp;
    reg  [3:0] ma, mb;

    bch_syndrome u_syn   (.r(r_q), .s1(syn1), .s3(syn3));
    gf16_inv_sop u_inv   (.a(s1), .y(inv_s1));
    bch_chien_x  u_chien (.i(i), .x(x), .x2(x2));
    gf16_mul #(.USE_SOP(USE_SOP)) u_mul (.a(ma), .b(mb), .p(mp));

    // binding: operands of the shared multiplier in each control step
    always @* begin
        case (state)
            P1:      begin ma = s1;  mb = s1;     end
            P2:      begin ma = s3;  mb = inv_s1; end
            default: begin
                if (!phase) begin ma = l1; mb = x;  end
                else        begin ma = l2; mb = x2; end
            end
        endcase
    end

    wire is_root = ((acc ^ mp) == 4'h0);
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
            phase    <= 1'b0;
            acc      <= 4'h0;
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
                    state <= P1;
                end
                P1: begin
                    l1    <= s1;
                    l2    <= mp;                    // S1^2
                    state <= P2;
                end
                P2: begin
                    l2       <= l2 ^ mp;            // + S3 * S1^-1
                    i        <= 4'd0;
                    phase    <= 1'b0;
                    roots    <= 2'd0;
                    err_mask <= 15'd0;
                    state    <= CHIEN;
                end
                CHIEN: begin
                    if (!phase) begin
                        acc   <= 4'h1 ^ mp;         // 1 + L1*x
                        phase <= 1'b1;
                    end else begin
                        phase <= 1'b0;
                        if (is_root) begin
                            err_mask[i] <= 1'b1;
                            roots       <= roots + 2'd1;
                        end
                        if (i == 4'd14) state <= CHECK;
                        else            i     <= i + 4'd1;
                    end
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
