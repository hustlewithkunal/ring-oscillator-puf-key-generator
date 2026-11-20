// SystemVerilog assertions for rtl/fe/fuzzy_extractor.v, attached with `bind`
// (the RTL itself is unchanged). Compile with:  xvlog -sv tb/fe_sva.sv
// State / op encodings as in fuzzy_extractor.v.

`timescale 1ns / 1ps

module fe_sva (
    input logic         clk,
    input logic         rst,
    input logic [3:0]   state,
    input logic [1:0]   op,
    input logic         cmd_valid,
    input logic [2:0]   cmd,
    input logic         done,
    input logic         cmd_err,
    input logic         puf_req,
    input logic         locked,
    input logic         key_valid,
    input logic         ecc_ok,
    input logic         kcv_ok,
    input logic [127:0] key_q,
    input logic [127:0] w_q,
    input logic [127:0] raw_resp
);
    localparam S_IDLE = 4'd0, S_MEAS_REQ = 4'd1, S_FINISH = 4'd11;
    localparam OP_ENROL = 2'd1, OP_MAC = 2'd3;
    localparam CMD_ENROL = 3'd2;

    // (xsim does not support default clocking/disable iff: written out per property)

    // A1  key valid only after ECC success and a matching key-check value
    a_key_ecc:      assert property (@(posedge clk) disable iff (rst) key_valid |-> ecc_ok && kcv_ok);
    // A2  the lock is sticky (only reset clears it)
    a_lock_sticky:  assert property (@(posedge clk) disable iff (rst) locked |=> locked);
    // A3  no enrolment ever starts while locked
    a_no_enrol:     assert property (@(posedge clk) disable iff (rst) !(state == S_MEAS_REQ && op == OP_ENROL && locked));
    // A4  ENROL issued while locked is answered with done + cmd_err and nothing else
    a_enrol_reject: assert property (@(posedge clk) disable iff (rst) state == S_IDLE && cmd_valid && cmd == CMD_ENROL && locked
                                     |=> done && cmd_err && state == S_IDLE);
    // A5  the MAC only ever runs with a valid key
    a_mac_key:      assert property (@(posedge clk) disable iff (rst) (op == OP_MAC && state != S_IDLE) |-> key_valid);
    // A6  no key left behind: idle without a valid key means the key register is zero
    a_zeroise:      assert property (@(posedge clk) disable iff (rst) (state == S_IDLE && !key_valid) |-> key_q == '0);
    // A7  the response register is wiped once a command finishes
    a_wipe_w:       assert property (@(posedge clk) disable iff (rst) state == S_FINISH |=> w_q == '0);
    // A8  secure build: the raw response port is always zero
    a_no_raw:       assert property (@(posedge clk) disable iff (rst) raw_resp == '0);
    // A9  done and puf_req are single-cycle pulses
    a_done_pulse:   assert property (@(posedge clk) disable iff (rst) done |=> !done);
    a_req_pulse:    assert property (@(posedge clk) disable iff (rst) puf_req |=> !puf_req);
    // A10 every accepted command finishes (bounded liveness; the slowest, r = 1
    //     reconstruction, takes about 210 cycles with the testbench PUF)
    a_finishes:     assert property (@(posedge clk) disable iff (rst) (state == S_IDLE && cmd_valid) |-> ##[1:400] done);
    // A11 key_valid only rises at the end of a command (never in the middle)
    a_kv_rise:      assert property (@(posedge clk) disable iff (rst) $rose(key_valid) |-> $past(state) == 4'd10);

    // cover points (xsim does not support `cover property`): count how often the
    // interesting situations occur, printed at the end of the simulation
    integer n_valid = 0, n_reject = 0, n_ecc_fail = 0;
    logic kv_q = 1'b0;
    always @(posedge clk) begin
        kv_q <= key_valid;
        if (!rst && key_valid && !kv_q) n_valid = n_valid + 1;
        if (!rst && state == S_IDLE && cmd_valid && cmd == CMD_ENROL && locked) n_reject = n_reject + 1;
        if (!rst && state == S_FINISH && op == 2'd2 && !ecc_ok) n_ecc_fail = n_ecc_fail + 1;
    end
    final $display("SVA COVER: %0d valid keys, %0d refused enrolments, %0d ECC failures",
                   n_valid, n_reject, n_ecc_fail);
endmodule

// xsim only applies a bind that sits in an elaborated top module, so the bind is
// wrapped here and fe_sva_bind is passed to xelab as a second top.
module fe_sva_bind;
bind fuzzy_extractor fe_sva u_fe_sva (
    .clk(clk), .rst(rst), .state(state), .op(op), .cmd_valid(cmd_valid), .cmd(cmd),
    .done(done), .cmd_err(cmd_err), .puf_req(puf_req), .locked(locked),
    .key_valid(key_valid), .ecc_ok(ecc_ok), .kcv_ok(kcv_ok), .key_q(key_q), .w_q(w_q),
    .raw_resp(raw_resp));
endmodule
