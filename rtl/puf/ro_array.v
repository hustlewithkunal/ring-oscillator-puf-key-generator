// One array of N_RO configurable ring oscillators. RO 2p and 2p+1 form pair p.
// Placement (one RO per slice, pairs in vertically adjacent slices) comes from
// constraints/puf_placement.xdc; instance names g_ro[i].u_ro are used there.

`timescale 1ns / 1ps

module ro_array #(
    parameter N_RO = 256
) (
    input  wire [N_RO-1:0] en,      // one enable per RO
    input  wire [2:0]      cfg,     // shared path configuration (only enabled ROs matter)
    output wire [N_RO-1:0] tog      // RO frequency / 2
);

    genvar i;
    generate
        for (i = 0; i < N_RO; i = i + 1) begin : g_ro
            ro_cell u_ro (.en(en[i]), .cfg(cfg), .tog(tog[i]));
        end
    endgenerate

endmodule
