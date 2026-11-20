// Repetition code of odd length REP over N data bits (combinational).
// Layout, as in model/repetition.py: data bit j occupies code bits j*REP .. j*REP+REP-1.

`timescale 1ns / 1ps

module rep_encode #(
    parameter N   = 120,
    parameter REP = 1
) (
    input  wire [N-1:0]     data,
    output wire [N*REP-1:0] code
);

    genvar j;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_bit
            assign code[j*REP +: REP] = {REP{data[j]}};
        end
    endgenerate

endmodule


// Majority-vote decoder: data bit j = 1 iff more than REP/2 of its REP copies are 1.
module rep_decode #(
    parameter N   = 120,
    parameter REP = 1
) (
    input  wire [N*REP-1:0] code,
    output wire [N-1:0]     data
);

    function majority;
        input [REP-1:0] copies;
        integer t, ones;
        begin
            ones = 0;
            for (t = 0; t < REP; t = t + 1)
                ones = ones + copies[t];
            majority = (ones > REP / 2);
        end
    endfunction

    genvar j;
    generate
        for (j = 0; j < N; j = j + 1) begin : g_bit
            assign data[j] = majority(code[j*REP +: REP]);
        end
    endgenerate

endmodule
