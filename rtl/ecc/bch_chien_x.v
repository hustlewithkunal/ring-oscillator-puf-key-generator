// Chien-search constants for position i (0..14):
//   x  = alpha^-i,  x2 = alpha^-2i  =  x^2
// Bit i of the received word is in error iff Lambda(x) = 1 + L1*x + L2*x2 = 0.
// A 4-input lookup table (one LUT per output bit), so x^2 needs no multiplier.

`timescale 1ns / 1ps

module bch_chien_x (
    input  wire [3:0] i,
    output reg  [3:0] x,
    output reg  [3:0] x2
);

    always @* begin
        case (i)
            4'd0:  begin x = 4'h1; x2 = 4'h1; end
            4'd1:  begin x = 4'h9; x2 = 4'hD; end
            4'd2:  begin x = 4'hD; x2 = 4'hE; end
            4'd3:  begin x = 4'hF; x2 = 4'hA; end
            4'd4:  begin x = 4'hE; x2 = 4'hB; end
            4'd5:  begin x = 4'h7; x2 = 4'h6; end
            4'd6:  begin x = 4'hA; x2 = 4'h8; end
            4'd7:  begin x = 4'h5; x2 = 4'h2; end
            4'd8:  begin x = 4'hB; x2 = 4'h9; end
            4'd9:  begin x = 4'hC; x2 = 4'hF; end
            4'd10: begin x = 4'h6; x2 = 4'h7; end
            4'd11: begin x = 4'h3; x2 = 4'h5; end
            4'd12: begin x = 4'h8; x2 = 4'hC; end
            4'd13: begin x = 4'h4; x2 = 4'h3; end
            4'd14: begin x = 4'h2; x2 = 4'h4; end
            default: begin x = 4'h0; x2 = 4'h0; end
        endcase
    end

endmodule
