// Single-port RAM for the SoC (inferred as block RAM), with byte write enables and
// one cycle of read latency. Initialised from INIT_FILE (firmware image, $readmemh).
// Bus side: answers a request on the cycle after `sel`, with `ready` for one cycle.

`timescale 1ns / 1ps

module soc_ram #(
    parameter WORDS     = 2048,             // 8 KB
    parameter INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        sel,                 // request for this RAM (held until ready)
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output reg  [31:0] rdata,
    output reg         ready
);

    (* ram_style = "block" *) reg [31:0] mem [0:WORDS-1];

    initial if (INIT_FILE != "") $readmemh(INIT_FILE, mem);

    wire [$clog2(WORDS)-1:0] idx = addr[$clog2(WORDS)+1:2];

    always @(posedge clk) begin
        ready <= sel && !ready;
        if (sel && !ready) begin
            if (wstrb[0]) mem[idx][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[idx][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[idx][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[idx][31:24] <= wdata[31:24];
            rdata <= mem[idx];
        end
    end

endmodule
