`timescale 1ns / 1ps
// Self-checking testbench for the ESPRESSO-generated GF(2^4) blocks and the
// XOR-based (Mastrovito) reference multiplier.
// Exhaustive: all 256 multiplier input pairs and all 16 inverse inputs,
// compared against the golden-model vectors gf_mul.mem / gf_inv.mem.
// In Vivado, add model/vectors/gf_mul.mem and gf_inv.mem as simulation sources
// so they are copied next to the simulator and found by name.

module tb_gf16_sop;

    reg  [11:0] mul_vec [0:255];   // [11:8] a, [7:4] b, [3:0] a*b
    reg  [7:0]  inv_vec [0:15];    // [7:4] a, [3:0] a^-1

    reg  [3:0] a, b;
    wire [3:0] p, p_xor, y;
    integer i, errors;

    gf16_mul_sop u_mul     (.a(a), .b(b), .p(p));
    gf16_mul_xor u_mul_xor (.a(a), .b(b), .p(p_xor));   // Mastrovito reference
    gf16_inv_sop u_inv     (.a(a), .y(y));

    initial begin
        $readmemh("gf_mul.mem", mul_vec);
        $readmemh("gf_inv.mem", inv_vec);
        errors = 0;

        for (i = 0; i < 256; i = i + 1) begin
            a = mul_vec[i][11:8];
            b = mul_vec[i][7:4];
            #1;
            if (p !== mul_vec[i][3:0]) begin
                errors = errors + 1;
                $display("MUL MISMATCH a=%h b=%h : got %h expected %h", a, b, p, mul_vec[i][3:0]);
            end
            if (p_xor !== mul_vec[i][3:0]) begin
                errors = errors + 1;
                $display("MUL_XOR MISMATCH a=%h b=%h : got %h expected %h", a, b, p_xor, mul_vec[i][3:0]);
            end
        end

        for (i = 0; i < 16; i = i + 1) begin
            a = inv_vec[i][7:4];
            #1;
            if (y !== inv_vec[i][3:0]) begin
                errors = errors + 1;
                $display("INV MISMATCH a=%h : got %h expected %h", a, y, inv_vec[i][3:0]);
            end
        end

        if (errors == 0)
            $display("PASS: gf16_mul_sop, gf16_mul_xor (256/256) and gf16_inv_sop (16/16) match the golden model");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end

endmodule
