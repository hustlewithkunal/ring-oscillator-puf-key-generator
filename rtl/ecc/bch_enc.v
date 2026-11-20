// BCH(15,7,2) systematic encoder: cw = {msg, parity}, parity = msg(x) * x^8 mod g(x),
// g(x) = x^8 + x^7 + x^6 + x^4 + 1. Combinational: the loop is the usual LFSR division
// unrolled over the 7 message bits (MSB first), so it synthesises to a small XOR network.

`timescale 1ns / 1ps

module bch_enc (
    input  wire [6:0]  msg,
    output wire [14:0] cw
);

    localparam [7:0] G_LOW = 8'hD1;     // g(x) without the x^8 term: x^7 + x^6 + x^4 + 1

    reg [7:0] rem;
    reg       fb;
    integer   i;

    always @* begin
        rem = 8'd0;
        for (i = 6; i >= 0; i = i - 1) begin
            fb  = msg[i] ^ rem[7];
            rem = {rem[6:0], 1'b0} ^ (fb ? G_LOW : 8'd0);
        end
    end

    assign cw = {msg, rem};

endmodule
