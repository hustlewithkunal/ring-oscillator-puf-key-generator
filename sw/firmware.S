# PUF key-generator firmware for rv32_core (assemble with sw/rvasm.py).
#
# Command loop: the host writes H2D_CMD and H2D_ARG[], then changes H2D_SEQ. The
# firmware executes the command, writes D2H_DATA[] and D2H_STATUS, and finally echoes
# the sequence number in D2H_SEQ (the host waits for it). At boot the firmware echoes
# the current H2D_SEQ once (status 0xB007xxxx); the host must only send a command when
# D2H_SEQ == H2D_SEQ, so commands sent while the firmware boots cannot be lost.
#
#   cmd 1 PING          data0 = 'RV32', data1 = firmware version
#   cmd 2 ENROL         arg0/arg1 = BCH messages [31:0]/[55:32], arg2 bit0 = configurable RO,
#                       arg3 = device (0..2, 0xFF = switches)
#                       -> helper data stored in RAM and returned in data0..data16
#   cmd 3 LOAD_HELPER   arg0..arg16 = helper data -> RAM
#   cmd 4 RECONSTRUCT   arg0 = device; uses the helper data in RAM
#   cmd 5 AUTH          arg0/arg1 = challenge -> data0/data1 = MAC tag
#   cmd 6 LOCK
#   cmd 7 STATUS        data0 = {btn, sw}, data1 = device, data2 = last tag ok
#   cmd 8 ECHO          data[k] = arg[k] (link test of the whole mailbox)
# D2H_STATUS = key-generator status {kcv_ok, ecc_ok, key_valid, locked, cmd_err, done, busy}
#              | command << 16 (0xEE << 16 for an unknown command)
#
# Helper data in RAM (17 words): offset[0..3], kcv, pair configuration[0..11].
# LEDs: LD0 key valid, LD1 locked, LD2 last authentication answered, LD3 heartbeat.

.equ FE,          0x10000000
.equ FE_CMD,      0x00
.equ FE_STATUS,   0x04
.equ FE_MSG0,     0x08
.equ FE_MSG1,     0x0C
.equ FE_HIN,      0x10
.equ FE_KCVIN,    0x20
.equ FE_CHAL0,    0x24
.equ FE_CHAL1,    0x28
.equ FE_HOUT,     0x30
.equ FE_KCVOUT,   0x40
.equ FE_TAG0,     0x44
.equ FE_TAG1,     0x48
.equ FE_PUFCTRL,  0x50
.equ FE_DEV,      0x54
.equ FE_CFG,      0x80
.equ FE_CFGBEST,  0xC0

.equ MB,          0x20000000
.equ MB_SEQ,      0x000
.equ MB_CMD,      0x004
.equ MB_ARG,      0x040
.equ MB_DSEQ,     0x100
.equ MB_DSTAT,    0x104
.equ MB_DATA,     0x140

.equ GPIO,        0x30000000
.equ HELPER,      0x1800          # 17 words of helper data
.equ HELPER_KCV,  0x1810
.equ HELPER_CFG,  0x1814
.equ VERSION,     0x00010000

start:
        li   sp, 0x1FF0
        li   s0, FE
        li   s1, MB
        li   s2, GPIO
        li   s4, 0                  # last authentication answered
        lw   s3, MB_SEQ(s1)         # ignore whatever the host left before reset
        li   a0, HELPER             # clear the helper data area
        li   a1, 17
clr:    sw   zero, 0(a0)
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, clr
        li   t0, 0xB0070000         # boot marker, then echo the sequence number:
        sw   t0, MB_DSTAT(s1)       # the host sends nothing until d2h_seq == h2d_seq,
        sw   s3, MB_DSEQ(s1)        # so no command can be lost during boot

# ------------------------------------------------------------------ main loop
loop:
        lw   t0, FE_STATUS(s0)      # LEDs from the key-generator status
        srli t1, t0, 4
        andi t1, t1, 1              # LD0 = key_valid (bit 4)
        srli t2, t0, 2
        andi t2, t2, 2              # LD1 = locked    (bit 3)
        or   t1, t1, t2
        slli t2, s4, 2              # LD2 = last authentication answered
        or   t1, t1, t2
        lw   t2, 8(s2)              # LD3 = cycle counter bit 25 (~1.9 Hz)
        srli t2, t2, 22
        andi t2, t2, 8
        or   t1, t1, t2
        sw   t1, 0(s2)

        lw   t0, MB_SEQ(s1)
        beq  t0, s3, loop
        mv   s3, t0
        lw   s6, MB_CMD(s1)

        li   t1, 1
        beq  s6, t1, cmd_ping
        li   t1, 2
        beq  s6, t1, cmd_enrol
        li   t1, 3
        beq  s6, t1, cmd_load
        li   t1, 4
        beq  s6, t1, cmd_recon
        li   t1, 5
        beq  s6, t1, cmd_auth
        li   t1, 6
        beq  s6, t1, cmd_lock
        li   t1, 7
        beq  s6, t1, cmd_status
        li   t1, 8
        beq  s6, t1, cmd_echo
        li   s6, 0xEE               # unknown command
        lw   a0, FE_STATUS(s0)
        j    reply

# a0 = key-generator status; reply = status | cmd << 16, then echo the sequence number
reply:
        slli t0, s6, 16
        or   a0, a0, t0
        sw   a0, MB_DSTAT(s1)
        sw   s3, MB_DSEQ(s1)
        j    loop

# ------------------------------------------------------------------ commands
cmd_ping:
        li   t0, 0x52563332         # 'RV32'
        sw   t0, MB_DATA(s1)
        li   t0, VERSION
        sw   t0, MB_DATA+4(s1)
        lw   a0, FE_STATUS(s0)
        j    reply

cmd_enrol:
        lw   a0, MB_ARG+12(s1)
        call set_dev
        lw   t0, MB_ARG(s1)
        sw   t0, FE_MSG0(s0)
        lw   t0, MB_ARG+4(s1)
        sw   t0, FE_MSG1(s0)
        lw   t0, MB_ARG+8(s1)
        andi t0, t0, 1
        beqz t0, enrol_base
        li   t0, 1                  # configurable RO: SELECT the best configurations
        sw   t0, FE_PUFCTRL(s0)
wait_sel:
        lw   t0, FE_PUFCTRL(s0)
        andi t0, t0, 2
        beqz t0, wait_sel
        li   a0, FE+FE_CFGBEST
        li   a1, HELPER_CFG
        li   a2, 12
        call copy
        j    enrol_go
enrol_base:
        li   a0, HELPER_CFG         # baseline RO-PUF: configuration 0 everywhere
        li   a1, 12
zcfg:   sw   zero, 0(a0)
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, zcfg
enrol_go:
        li   a0, HELPER_CFG         # configuration -> PUF
        li   a1, FE+FE_CFG
        li   a2, 12
        call copy
        li   a0, 2                  # ENROL
        call fe_cmd
        mv   s5, a0
        andi t0, s5, 4              # rejected (locked): keep the stored helper data
        bnez t0, enrol_out
        li   a0, FE+FE_HOUT         # offset -> RAM
        li   a1, HELPER
        li   a2, 4
        call copy
        lw   t0, FE_KCVOUT(s0)
        li   t1, HELPER_KCV
        sw   t0, 0(t1)
enrol_out:
        li   a0, HELPER             # helper data -> host
        li   a1, MB+MB_DATA
        li   a2, 17
        call copy
        mv   a0, s5
        j    reply

cmd_load:
        li   a0, MB+MB_ARG
        li   a1, HELPER
        li   a2, 17
        call copy
        lw   a0, FE_STATUS(s0)
        j    reply

cmd_recon:
        lw   a0, MB_ARG(s1)
        call set_dev
        li   a0, HELPER_CFG         # stored configuration -> PUF
        li   a1, FE+FE_CFG
        li   a2, 12
        call copy
        li   a0, HELPER             # stored offset and KCV -> key generator
        li   a1, FE+FE_HIN
        li   a2, 4
        call copy
        li   t1, HELPER_KCV
        lw   t0, 0(t1)
        sw   t0, FE_KCVIN(s0)
        li   a0, 3                  # RECONSTRUCT
        call fe_cmd
        li   s4, 0
        j    reply

cmd_auth:
        lw   t0, MB_ARG(s1)
        sw   t0, FE_CHAL0(s0)
        lw   t0, MB_ARG+4(s1)
        sw   t0, FE_CHAL1(s0)
        li   a0, 5                  # MAC
        call fe_cmd
        andi t0, a0, 4              # cmd_err: no valid key
        seqz s4, t0
        lw   t0, FE_TAG0(s0)
        sw   t0, MB_DATA(s1)
        lw   t0, FE_TAG1(s0)
        sw   t0, MB_DATA+4(s1)
        bnez s4, reply
        sw   zero, MB_DATA(s1)      # refused: no tag
        sw   zero, MB_DATA+4(s1)
        j    reply

cmd_lock:
        li   a0, 4                  # LOCK
        call fe_cmd
        j    reply

cmd_echo:                           # link test: data[k] = arg[k], k = 0..23
        li   a0, MB+MB_ARG
        li   a1, MB+MB_DATA
        li   a2, 24
        call copy
        lw   a0, FE_STATUS(s0)
        j    reply

cmd_status:
        lw   t0, 4(s2)
        sw   t0, MB_DATA(s1)
        lw   t0, FE_DEV(s0)
        sw   t0, MB_DATA+4(s1)
        sw   s4, MB_DATA+8(s1)
        lw   a0, FE_STATUS(s0)
        j    reply

# ---------------------------------------------------------------- subroutines
# set_dev(a0): RO array for the key generator; 0xFF = take it from switches SW1:SW0
set_dev:
        li   t0, 0xFF
        bne  a0, t0, sd_set
        lw   a0, 4(s2)
sd_set: andi a0, a0, 3
        li   t0, 3                  # only arrays 0..2 exist
        bne  a0, t0, sd_ok
        li   a0, 0
sd_ok:  sw   a0, FE_DEV(s0)
        ret

# fe_cmd(a0): issue a key-generator command, wait until done; returns the status in a0
fe_cmd:
        sw   a0, FE_CMD(s0)
fc_w:   lw   a0, FE_STATUS(s0)
        andi t0, a0, 2
        beqz t0, fc_w
        ret

# copy(a0 = source, a1 = destination, a2 = words)
copy:
        lw   t0, 0(a0)
        sw   t0, 0(a1)
        addi a0, a0, 4
        addi a1, a1, 4
        addi a2, a2, -1
        bnez a2, copy
        ret
