# RV32I self-test for rv32_core. Every check puts the computed value in a0 and the
# expected value in a1; a mismatch jumps to fail with the test number in t6.
# Result word at RESULT: 1 = all tests passed, 0x100 + n = test n failed. Ends in ebreak.

.equ RESULT, 0x1FC0
.equ BUF,    0x1F00

start:
        li   t6, 1                      # ---- 1: addi / add / sub
        li   t0, 100
        addi t1, t0, -42
        add  a0, t0, t1                 # 100 + 58
        li   a1, 158
        bne  a0, a1, fail
        li   t6, 2
        sub  a0, t1, t0                 # 58 - 100
        li   a1, -42
        bne  a0, a1, fail

        li   t6, 3                      # ---- 3: logic
        li   t0, 0x0F0F1234
        li   t1, 0x00FF00FF
        and  a0, t0, t1
        li   a1, 0x000F0034
        bne  a0, a1, fail
        or   a0, t0, t1
        li   a1, 0x0FFF12FF
        bne  a0, a1, fail
        xor  a0, t0, t1
        li   a1, 0x0FF012CB
        bne  a0, a1, fail
        andi a0, t0, 0x0F0
        li   a1, 0x030
        bne  a0, a1, fail
        ori  a0, t0, -1
        li   a1, -1
        bne  a0, a1, fail
        xori a0, t0, 0x7FF
        li   a1, 0x0F0F15CB
        bne  a0, a1, fail

        li   t6, 4                      # ---- 4: shifts
        li   t0, 0x80000011
        slli a0, t0, 4
        li   a1, 0x00000110
        bne  a0, a1, fail
        srli a0, t0, 4
        li   a1, 0x08000001
        bne  a0, a1, fail
        srai a0, t0, 4
        li   a1, 0xF8000001
        bne  a0, a1, fail
        li   t1, 36                     # only the low 5 bits count -> 4
        sll  a0, t0, t1
        li   a1, 0x00000110
        bne  a0, a1, fail
        srl  a0, t0, t1
        li   a1, 0x08000001
        bne  a0, a1, fail
        sra  a0, t0, t1
        li   a1, 0xF8000001
        bne  a0, a1, fail

        li   t6, 5                      # ---- 5: set-less-than
        li   t0, -5
        li   t1, 3
        slt  a0, t0, t1
        li   a1, 1
        bne  a0, a1, fail
        sltu a0, t0, t1                 # 0xFFFFFFFB > 3 unsigned
        bne  a0, zero, fail
        slti a0, t1, -1
        bne  a0, zero, fail
        sltiu a0, t1, -1                # 3 < 0xFFFFFFFF
        li   a1, 1
        bne  a0, a1, fail

        li   t6, 6                      # ---- 6: lui / auipc / x0
        lui  a0, 0xABCDE
        li   a1, 0xABCDE000
        bne  a0, a1, fail
here:   auipc a0, 0
        la   a1, here
        bne  a0, a1, fail
        li   t0, 77
        addi x0, t0, 1                  # writes to x0 are discarded
        bne  x0, zero, fail

        li   t6, 7                      # ---- 7: branches taken / not taken
        li   t0, -1
        li   t1, 1
        beq  t0, t1, fail
        bne  t0, t0, fail
        blt  t1, t0, fail               # 1 < -1 is false (signed)
        bge  t0, t1, fail
        bltu t0, t1, fail               # 0xFFFFFFFF < 1 is false (unsigned)
        bgeu t1, t0, fail
        beq  t0, t0, b1
        j    fail
b1:     bne  t0, t1, b2
        j    fail
b2:     blt  t0, t1, b3
        j    fail
b3:     bge  t1, t0, b4
        j    fail
b4:     bltu t1, t0, b5
        j    fail
b5:     bgeu t0, t1, b6
        j    fail
b6:
        li   t6, 8                      # ---- 8: jal / jalr link and target
        jal  ra, sub1
ret1:   la   a1, ret1
        bne  a0, a1, fail
        la   t0, sub1
        jalr ra, 0(t0)
ret2:   la   a1, ret2
        bne  a0, a1, fail
        j    t9
sub1:   mv   a0, ra
        ret

t9:     li   t6, 9                      # ---- 9: stores and loads
        li   s0, BUF
        li   t0, 0x8899AABB
        sw   t0, 0(s0)
        lw   a0, 0(s0)
        mv   a1, t0
        bne  a0, a1, fail
        lb   a0, 0(s0)                  # 0xBB sign-extended
        li   a1, 0xFFFFFFBB
        bne  a0, a1, fail
        lbu  a0, 1(s0)
        li   a1, 0xAA
        bne  a0, a1, fail
        lh   a0, 2(s0)                  # 0x8899 sign-extended
        li   a1, 0xFFFF8899
        bne  a0, a1, fail
        lhu  a0, 2(s0)
        li   a1, 0x8899
        bne  a0, a1, fail
        li   t0, 0x5A
        sb   t0, 1(s0)
        li   t0, 0x1234
        sh   t0, 2(s0)
        lw   a0, 0(s0)
        li   a1, 0x12345ABB
        bne  a0, a1, fail
        sw   zero, 4(s0)
        li   t0, 0x77
        sb   t0, 7(s0)
        lw   a0, 4(s0)
        li   a1, 0x77000000
        bne  a0, a1, fail

        li   t6, 10                     # ---- 10: loop (backward branch, counter)
        li   t0, 0
        li   t1, 0
loop:   addi t0, t0, 1
        add  t1, t1, t0
        li   t2, 10
        blt  t0, t2, loop
        li   a1, 55
        bne  t1, a1, fail

pass:   li   t0, 1
        li   t1, RESULT
        sw   t0, 0(t1)
        ebreak

fail:   addi t0, t6, 0x100
        li   t1, RESULT
        sw   t0, 0(t1)
        ebreak
