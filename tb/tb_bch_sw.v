`timescale 1ns / 1ps
// Hardware/software comparison: runs sw/tests/bch_sw.S (BCH decoding in RV32I software)
// on rv32_core and measures the cycles of the decode loop between the two stores to MARK.
// The program checks every result against the golden model (mismatch count at 0x1FC0).

module tb_bch_sw;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #4 clk = ~clk;

    wire        mem_valid, mem_ready, trap;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;

    rv32_core u_cpu (
        .clk(clk), .rst(rst), .mem_valid(mem_valid), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready), .trap(trap));

    soc_ram #(.WORDS(2048), .INIT_FILE("bch_sw.mem")) u_ram (
        .clk(clk), .sel(mem_valid), .addr(mem_addr), .wdata(mem_wdata), .wstrb(mem_wstrb),
        .rdata(mem_rdata), .ready(mem_ready));

    integer cycles = 0, t_start = -1, t_end = -1, instr = 0, instr0 = 0, instr1 = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (u_cpu.state == 2'd2) instr <= instr + 1;
        if (mem_valid && mem_ready && mem_wstrb != 0 && mem_addr == 32'h1F80) begin
            if (t_start < 0) begin t_start <= cycles; instr0 <= instr; end
            else             begin t_end   <= cycles; instr1 <= instr; end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        wait (trap || cycles > 2000000);
        @(posedge clk);
        if (!trap || t_end < 0)
            $display("FAIL: program did not finish");
        else
            $display("BCH_SW: %0d decodes, %0d mismatches, %0d cycles in the timed loop = %0d cycles per decode (%0d instructions per decode)",
                     64, u_ram.mem[32'h1FC0 >> 2], t_end - t_start, (t_end - t_start) / 64,
                     (instr1 - instr0) / 64);
        $finish;
    end

endmodule
