// Small multi-cycle RV32I processor core.
//
// Implements the full RV32I base integer instruction set except the CSR/counter
// instructions: LUI AUIPC JAL JALR, BEQ BNE BLT BGE BLTU BGEU, LB LH LW LBU LHU,
// SB SH SW, ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI, ADD SUB SLL SLT SLTU XOR
// SRL SRA OR AND. FENCE is a no-op. ECALL / EBREAK / any unknown opcode stop the core
// and raise `trap` (used by the firmware self-test to signal pass/fail).
//
// One instruction takes 3 cycles (+1 for loads/stores, +bus wait states):
//   FETCH   bus read at pc, wait for ready, latch the instruction
//   DECODE  read rs1/rs2 from the register file, form the immediate
//   EXEC    ALU / branch / jump; write rd; or compute the load/store address
//   MEM     bus access for loads and stores
// Bus: PicoRV32-style native interface. mem_valid stays high until mem_ready;
// mem_wstrb = 0 means read. Misaligned accesses are not supported (not generated
// by the firmware).

`timescale 1ns / 1ps

module rv32_core #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst,
    output reg         mem_valid,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    output reg         trap
);

    localparam [1:0] S_FETCH = 2'd0, S_DECODE = 2'd1, S_EXEC = 2'd2, S_MEM = 2'd3;

    reg [1:0]  state;
    reg [31:0] pc, ir, rs1v, rs2v, imm;
    reg [31:0] regs [0:31];

    // ---------------------------------------------------------------- decode
    wire [6:0] opcode = ir[6:0];
    wire [4:0] rd     = ir[11:7];
    wire [2:0] funct3 = ir[14:12];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];
    wire       f7_20  = ir[30];

    localparam [6:0] OP_LUI = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL = 7'b1101111,
                     OP_JALR = 7'b1100111, OP_BRANCH = 7'b1100011, OP_LOAD = 7'b0000011,
                     OP_STORE = 7'b0100011, OP_IMM = 7'b0010011, OP_REG = 7'b0110011,
                     OP_FENCE = 7'b0001111;

    reg [31:0] imm_dec;
    always @* begin
        case (opcode)
            OP_LUI, OP_AUIPC: imm_dec = {ir[31:12], 12'd0};
            OP_JAL:           imm_dec = {{12{ir[31]}}, ir[19:12], ir[20], ir[30:21], 1'b0};
            OP_BRANCH:        imm_dec = {{20{ir[31]}}, ir[7], ir[30:25], ir[11:8], 1'b0};
            OP_STORE:         imm_dec = {{21{ir[31]}}, ir[30:25], ir[11:7]};
            default:          imm_dec = {{21{ir[31]}}, ir[30:20]};      // I-type
        endcase
    end

    // ------------------------------------------------------------------ ALU
    // operand select and add/subtract are decoded in DECODE and registered, so the
    // EXEC adder path starts at flip-flops (it missed 125 MHz by 0.02 ns when these
    // were decoded from the instruction register in the same cycle)
    reg         is_imm, sub;
    wire [31:0] op_b     = is_imm ? imm : rs2v;
    wire [4:0]  shamt    = op_b[4:0];
    wire [31:0] sum      = sub ? rs1v - op_b : rs1v + op_b;
    wire        lt_s     = ($signed(rs1v) < $signed(op_b));
    wire        lt_u     = (rs1v < op_b);
    // arithmetic shift in its own signed expression: inside a ?: with an unsigned
    // operand Verilog would evaluate >>> as a logical shift
    wire signed [31:0] sra_res = $signed(rs1v) >>> shamt;

    reg [31:0] alu;
    always @* begin
        case (funct3)
            3'b000: alu = sum;
            3'b001: alu = rs1v << shamt;
            3'b010: alu = {31'd0, lt_s};
            3'b011: alu = {31'd0, lt_u};
            3'b100: alu = rs1v ^ op_b;
            3'b101: alu = f7_20 ? sra_res : (rs1v >> shamt);
            3'b110: alu = rs1v | op_b;
            default: alu = rs1v & op_b;
        endcase
    end

    reg take;
    always @* begin
        case (funct3)
            3'b000:  take = (rs1v == rs2v);
            3'b001:  take = (rs1v != rs2v);
            3'b100:  take = lt_s;
            3'b101:  take = !lt_s;
            3'b110:  take = lt_u;
            3'b111:  take = !lt_u;
            default: take = 1'b0;
        endcase
    end

    // ------------------------------------------------------ load data path
    wire [31:0] ls_addr = rs1v + imm;
    wire [1:0]  boff    = mem_addr[1:0];
    wire [31:0] shifted = mem_rdata >> {boff, 3'b000};
    reg  [31:0] load_val;
    always @* begin
        case (funct3)
            3'b000:  load_val = {{24{shifted[7]}},  shifted[7:0]};     // LB
            3'b001:  load_val = {{16{shifted[15]}}, shifted[15:0]};    // LH
            3'b100:  load_val = {24'd0, shifted[7:0]};                 // LBU
            3'b101:  load_val = {16'd0, shifted[15:0]};                // LHU
            default: load_val = mem_rdata;                             // LW
        endcase
    end

    // --------------------------------------------------------- sequencer
    integer k;
    initial for (k = 0; k < 32; k = k + 1) regs[k] = 32'd0;

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_FETCH;
            pc        <= RESET_PC;
            ir        <= 32'd0;
            rs1v      <= 32'd0;
            rs2v      <= 32'd0;
            imm       <= 32'd0;
            is_imm    <= 1'b0;
            sub       <= 1'b0;
            mem_valid <= 1'b0;
            mem_addr  <= 32'd0;
            mem_wdata <= 32'd0;
            mem_wstrb <= 4'd0;
            trap      <= 1'b0;
        end else if (!trap) begin
            case (state)
                S_FETCH: begin
                    if (!mem_valid) begin
                        mem_valid <= 1'b1;
                        mem_addr  <= pc;
                        mem_wstrb <= 4'd0;
                    end else if (mem_ready) begin
                        mem_valid <= 1'b0;
                        ir        <= mem_rdata;
                        state     <= S_DECODE;
                    end
                end
                S_DECODE: begin
                    rs1v   <= regs[rs1];
                    rs2v   <= regs[rs2];
                    imm    <= imm_dec;
                    is_imm <= (opcode == OP_IMM);
                    sub    <= (opcode == OP_REG) && f7_20;
                    state <= S_EXEC;
                end
                S_EXEC: begin
                    state <= S_FETCH;
                    pc    <= pc + 32'd4;
                    case (opcode)
                        OP_LUI:   if (rd != 0) regs[rd] <= imm;
                        OP_AUIPC: if (rd != 0) regs[rd] <= pc + imm;
                        OP_JAL: begin
                            if (rd != 0) regs[rd] <= pc + 32'd4;
                            pc <= pc + imm;
                        end
                        OP_JALR: begin
                            if (rd != 0) regs[rd] <= pc + 32'd4;
                            pc <= (rs1v + imm) & ~32'd1;
                        end
                        OP_BRANCH: if (take) pc <= pc + imm;
                        OP_IMM, OP_REG: if (rd != 0) regs[rd] <= alu;
                        OP_LOAD, OP_STORE: begin
                            pc        <= pc;                // advanced after the access
                            mem_valid <= 1'b1;
                            mem_addr  <= ls_addr;
                            if (opcode == OP_STORE) begin
                                mem_wdata <= rs2v << {ls_addr[1:0], 3'b000};
                                case (funct3[1:0])
                                    2'b00:   mem_wstrb <= 4'b0001 << ls_addr[1:0];
                                    2'b01:   mem_wstrb <= 4'b0011 << ls_addr[1:0];
                                    default: mem_wstrb <= 4'b1111;
                                endcase
                            end else begin
                                mem_wstrb <= 4'd0;
                            end
                            state <= S_MEM;
                        end
                        OP_FENCE: ;                         // no-op
                        default: begin                      // ECALL, EBREAK, illegal
                            trap <= 1'b1;
                            pc   <= pc;
                        end
                    endcase
                end
                S_MEM: begin
                    if (mem_ready) begin
                        mem_valid <= 1'b0;
                        mem_wstrb <= 4'd0;
                        if (opcode == OP_LOAD && rd != 0) regs[rd] <= load_val;
                        pc    <= pc + 32'd4;
                        state <= S_FETCH;
                    end
                end
            endcase
        end
    end

endmodule
