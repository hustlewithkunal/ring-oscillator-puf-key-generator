`timescale 1ns / 1ps
// Runs sw/tests/core_selftest.S (assembled to core_selftest.mem) on rv32_core + soc_ram.
// The program checks every RV32I instruction class itself and stores 1 (pass) or
// 0x100 + test number (fail) at address 0x1FC0, then executes ebreak.

module tb_rv32_core;

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

    soc_ram #(.WORDS(2048), .INIT_FILE("core_selftest.mem")) u_ram (
        .clk(clk), .sel(mem_valid), .addr(mem_addr), .wdata(mem_wdata), .wstrb(mem_wstrb),
        .rdata(mem_rdata), .ready(mem_ready));

    integer cycles = 0, instr = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (u_cpu.state == 2'd2) instr <= instr + 1;      // one EXEC per instruction
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        wait (trap || cycles > 20000);
        @(posedge clk);
        if (!trap)
            $display("FAIL: core did not reach ebreak (pc = %h)", u_cpu.pc);
        else if (u_ram.mem[32'h1FC0 >> 2] == 32'd1)
            $display("PASS: RV32I self-test passed (%0d instructions, %0d cycles, CPI %0d.%02d)",
                     instr, cycles, cycles / instr, (cycles * 100 / instr) % 100);
        else
            $display("FAIL: self-test reported %h (0x100 + failing test number), pc = %h",
                     u_ram.mem[32'h1FC0 >> 2], u_cpu.pc);
        $finish;
    end

endmodule
