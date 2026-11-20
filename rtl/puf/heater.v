// On-chip heater for the warm-board reliability test. When enabled it burns dynamic
// power to raise the die temperature (read back through the XADC over JTAG):
//   * N_FF toggle flip-flops that flip EVERY cycle (q <= ~q), each feeding a 5-input
//     XOR register: an odd number of toggling inputs, so every XOR output also toggles
//     every cycle (a fan-in with an even count would cancel out and stay constant)
//   * N_DSP DSP48 multiply-accumulators fed by an LFSR (the design uses no other DSPs)
// DONT_TOUCH stops synthesis from merging the identical toggle registers.
//
// (A first version, q <= ~q ^ (q[i+1] & q[i+7]), had an all-ones fixed point and
//  stopped toggling almost at once: it produced no measurable heating.)

`timescale 1ns / 1ps

module heater #(
    parameter N_FF  = 2048,
    parameter N_DSP = 64
) (
    input  wire clk,
    input  wire en,
    output wire alive           // observable output, keeps the heater from being removed
);

    (* DONT_TOUCH = "TRUE" *) reg [N_FF-1:0] q = {N_FF/2{2'b01}};
    (* DONT_TOUCH = "TRUE" *) reg [N_FF-1:0] x = {N_FF{1'b0}};

    integer i;
    always @(posedge clk) begin
        if (en) begin
            q <= ~q;
            for (i = 0; i < N_FF; i = i + 1)
                x[i] <= q[i] ^ q[(i + 1) % N_FF] ^ q[(i + 2) % N_FF] ^ q[(i + 5) % N_FF] ^ q[(i + 11) % N_FF];
        end
    end

    // LFSR data for the multipliers (x^32 + x^22 + x^2 + x + 1)
    reg [31:0] lfsr = 32'hACE1_2468;
    always @(posedge clk)
        if (en) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    wire [N_DSP-1:0] dsp_bit;
    genvar d;
    generate
        for (d = 0; d < N_DSP; d = d + 1) begin : g_dsp
            // no DONT_TOUCH here: it would stop the registers being absorbed into the
            // DSP48 and the multipliers would be built from LUTs (tried: 39k LUTs)
            // 24 x 17 unsigned fits the DSP48E1 25 x 18 signed multiplier: one DSP each
            // (25 x 18 unsigned needs 3 DSPs; 64 of those overflowed the 80 DSPs into LUTs)
            (* use_dsp = "yes" *) reg [47:0] acc = 48'd0;
            reg [23:0] a = 24'd0;
            reg [16:0] b = 17'd0;
            always @(posedge clk) begin
                if (en) begin
                    a   <= lfsr[23:0] ^ d;
                    b   <= {lfsr[12:0], lfsr[31:28]} ^ (d * 7);
                    acc <= acc + a * b;
                end
            end
            assign dsp_bit[d] = acc[47] ^ acc[23];
        end
    endgenerate

    assign alive = ^x ^ ^dsp_bit;

endmodule
