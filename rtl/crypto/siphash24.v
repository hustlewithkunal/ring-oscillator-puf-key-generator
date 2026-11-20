// SipHash-2-4 core (Aumasson & Bernstein, 2012): 128-bit key, 64-bit tag.
// Used as the KDF, the key-check value and the MAC of the PUF key generator.
//
// Iterative: one SipRound per clock, and every round goes register -> register
// (nothing from the ports or the final XOR is chained into a round), so the
// critical path is a single SipRound.
//   init                   v0..v3 <- key ^ constants                       1 cycle
//   each message block     v3 ^= m; 2 rounds; v0 ^= m                       3 cycles
//   after the last block   v2 ^= 0xff, 4 rounds; tag = v0 ^ v1 ^ v2 ^ v3     5 cycles
// A message of B blocks therefore takes 3B + 5 cycles from its first block.
//
// Byte order follows the reference implementation (little-endian):
//   key[7:0] is key byte 0, key[63:0] = k0, key[127:64] = k1
//   blk[7:0] is the first byte of the 8-byte block
// The caller formats the message: every block but the last is 8 message bytes;
// the last block holds the remaining 0..7 bytes and the message length (mod 256)
// in blk[63:56], exactly as in model/siphash.py.

`timescale 1ns / 1ps

module siphash24 (
    input  wire         clk,
    input  wire         rst,        // synchronous, active high
    input  wire         init,       // start a new message with this key (only when ready)
    input  wire [127:0] key,
    input  wire         blk_valid,  // absorb one block (only when ready)
    input  wire [63:0]  blk,
    input  wire         blk_last,   // this is the final, length-formatted block
    output wire         ready,
    output reg          tag_valid,  // one-cycle pulse
    output reg  [63:0]  tag
);

    localparam IDLE  = 3'd0,
               COMP1 = 3'd1,        // first compression round
               COMP2 = 3'd2,        // second compression round, then v0 ^= m
               FIN   = 3'd3,        // four finalisation rounds
               OUT   = 3'd4;        // tag = v0 ^ v1 ^ v2 ^ v3

    reg [2:0]  state;
    reg [1:0]  fin_cnt;
    reg        last_q;
    reg [63:0] m_q;
    reg [63:0] v0, v1, v2, v3;

    // ---------------------------------------------------------------- SipRound
    function [255:0] sipround;      // {v0, v1, v2, v3} -> {v0, v1, v2, v3}
        input [63:0] a0, a1, a2, a3;
        reg   [63:0] b0, b1, b2, b3;
        begin
            b0 = a0 + a1;   b1 = {a1[50:0], a1[63:51]} ^ b0;   b0 = {b0[31:0], b0[63:32]};
            b2 = a2 + a3;   b3 = {a3[47:0], a3[63:48]} ^ b2;
            b0 = b0 + b3;   b3 = {b3[42:0], b3[63:43]} ^ b0;
            b2 = b2 + b1;   b1 = {b1[46:0], b1[63:47]} ^ b2;   b2 = {b2[31:0], b2[63:32]};
            sipround = {b0, b1, b2, b3};
        end
    endfunction

    wire [255:0] rnd = sipround(v0, v1, v2, v3);
    wire [63:0]  n0 = rnd[255:192], n1 = rnd[191:128], n2 = rnd[127:64], n3 = rnd[63:0];

    assign ready = (state == IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            fin_cnt   <= 2'd0;
            last_q    <= 1'b0;
            m_q       <= 64'd0;
            v0        <= 64'd0;
            v1        <= 64'd0;
            v2        <= 64'd0;
            v3        <= 64'd0;
            tag_valid <= 1'b0;
            tag       <= 64'd0;
        end else begin
            tag_valid <= 1'b0;
            case (state)
                IDLE: begin
                    if (init) begin
                        v0 <= key[63:0]   ^ 64'h736f6d6570736575;
                        v1 <= key[127:64] ^ 64'h646f72616e646f6d;
                        v2 <= key[63:0]   ^ 64'h6c7967656e657261;
                        v3 <= key[127:64] ^ 64'h7465646279746573;
                    end else if (blk_valid) begin
                        v3     <= v3 ^ blk;
                        m_q    <= blk;
                        last_q <= blk_last;
                        state  <= COMP1;
                    end
                end
                COMP1: begin
                    {v0, v1, v2, v3} <= {n0, n1, n2, n3};
                    state <= COMP2;
                end
                COMP2: begin                                       // round 2, then v0 ^= m
                    v0 <= n0 ^ m_q;
                    v1 <= n1;
                    v2 <= last_q ? (n2 ^ 64'hff) : n2;
                    v3 <= n3;
                    fin_cnt <= 2'd0;
                    state   <= last_q ? FIN : IDLE;
                end
                FIN: begin
                    {v0, v1, v2, v3} <= {n0, n1, n2, n3};
                    fin_cnt <= fin_cnt + 2'd1;
                    if (fin_cnt == 2'd3) state <= OUT;
                end
                OUT: begin
                    tag       <= v0 ^ v1 ^ v2 ^ v3;
                    tag_valid <= 1'b1;
                    state     <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
