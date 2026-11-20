`timescale 1ns / 1ps
// End-to-end self-checking testbench for fuzzy_extractor against model/vectors/fe_r<REP>.mem.
// Run once per repetition factor:  xelab ... -generic_top "REP=1" (or 3, 5).
//
// For every vector (24 per file) the device goes through a full life cycle:
//   1. ENROL with w and the model's BCH messages -> helper and KCV must equal the model,
//      lock set, no key left behind
//   2. ENROL again                                -> must be rejected (one-time lock)
//   3. MAC before reconstruction                  -> must be rejected (no valid key)
//   4. RECONSTRUCT from w' (noisy re-read)        -> key_valid and the key must equal the model
//                                                   (cases 20-23: another board's response -> fail)
//   5. MAC with the vector's challenge            -> tag must equal the model (or be rejected)
// plus: secrets zeroised after every command, a wrong-KCV reconstruction on vector 0,
// and boot_locked = 1 at reset blocking enrolment.
// The key is internal and is only observed here through the hierarchical name dut.key_q.

module tb_fuzzy_extractor;

    parameter REP = 3;
    localparam N_VEC = 24;
    localparam VEC_FILE = (REP == 1) ? "fe_r1.mem" : (REP == 3) ? "fe_r3.mem" : "fe_r5.mem";

    localparam [2:0] CMD_MEASURE = 3'd1, CMD_ENROL = 3'd2, CMD_RECON = 3'd3,
                     CMD_LOCK    = 3'd4, CMD_MAC   = 3'd5;

    reg [731:0] vec [0:N_VEC-1];

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg          boot_locked = 1'b0;
    reg          cmd_valid = 1'b0;
    reg  [2:0]   cmd = 3'd0;
    reg  [55:0]  enrol_msg = 56'd0;
    reg  [127:0] helper_in = 128'd0;
    reg  [31:0]  kcv_in = 32'd0;
    reg  [63:0]  challenge = 64'd0;
    wire         busy, done, cmd_err, puf_req;
    reg          puf_valid = 1'b0;
    reg  [127:0] puf_resp = 128'd0;
    wire [127:0] helper_out, raw_resp;
    wire [31:0]  kcv_out;
    wire [63:0]  tag;
    wire         locked, key_valid, ecc_ok, kcv_ok;

    always #5 clk = ~clk;

    fuzzy_extractor #(.REP(REP), .USE_SOP(1), .AUTO_LOCK(1), .CHARACTERISATION(0)) dut (
        .clk(clk), .rst(rst), .boot_locked(boot_locked),
        .cmd_valid(cmd_valid), .cmd(cmd), .busy(busy), .done(done), .cmd_err(cmd_err),
        .puf_req(puf_req), .puf_valid(puf_valid), .puf_resp(puf_resp),
        .enrol_msg(enrol_msg), .helper_in(helper_in), .kcv_in(kcv_in),
        .helper_out(helper_out), .kcv_out(kcv_out),
        .challenge(challenge), .tag(tag),
        .locked(locked), .key_valid(key_valid), .ecc_ok(ecc_ok), .kcv_ok(kcv_ok),
        .raw_resp(raw_resp));

    // PUF stand-in: answers every request 4 cycles later with puf_data
    reg [127:0] puf_data = 128'd0;
    reg [2:0]   puf_wait = 3'd0;
    always @(posedge clk) begin
        puf_valid <= 1'b0;
        if (puf_req)
            puf_wait <= 3'd4;
        else if (puf_wait != 3'd0) begin
            puf_wait <= puf_wait - 3'd1;
            if (puf_wait == 3'd1) begin
                puf_valid <= 1'b1;
                puf_resp  <= puf_data;
            end
        end
    end

`ifdef FSM_TRACE
    // RTL values of the formal model's variables, every cycle (model/fe_fsm_model.py):
    // rst state op job locked key_valid ecc_ok kcv_ok key_set blk
    integer trace_fd;
    initial trace_fd = $fopen("fsm_trace.txt", "w");
    always @(posedge clk)
        $fdisplay(trace_fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", rst, dut.state, dut.op, dut.job,
                  dut.locked, dut.key_valid, dut.ecc_ok, dut.kcv_ok, (dut.key_q != 128'd0), dut.blk_i);
`endif

    integer errors, k, cyc, enrol_cyc, recon_cyc;
    reg [731:0] v;
    reg         exp_valid;

    task fail;
        input [8*40-1:0] what;
        begin
            errors = errors + 1;
            if (errors <= 15) $display("ERROR vector %0d: %0s", k, what);
        end
    endtask

    task run_cmd;                       // issue one command, wait for done, count cycles
        input  [2:0] c;
        output integer cycles;
        begin
            @(negedge clk);
            cmd       = c;
            cmd_valid = 1'b1;
            @(negedge clk);
            cmd_valid = 1'b0;
            cycles    = 1;
            while (!done && cycles < 2000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (!done) fail("command timed out");
        end
    endtask

    task check_wiped;                   // response-derived data must not linger
        begin
            if (dut.w_q !== 128'd0 || dut.rx_q !== 0 || dut.cw_q !== 0) fail("secret state not zeroised");
            if (raw_resp !== 128'd0) fail("raw response visible in secure build");
        end
    endtask

    task do_reset;
        input lock_at_boot;
        begin
            @(negedge clk);
            rst = 1'b1;
            boot_locked = lock_at_boot;
            repeat (2) @(negedge clk);
            rst = 1'b0;
        end
    endtask

    initial begin
        $readmemh(VEC_FILE, vec);
        errors = 0;

        for (k = 0; k < N_VEC; k = k + 1) begin
            v = vec[k];
            exp_valid = v[128];
            do_reset(1'b0);

            // 1. enrolment
            puf_data  = v[731:604];
            enrol_msg = v[603:548];
            run_cmd(CMD_ENROL, enrol_cyc);
            if (cmd_err)                     fail("enrol rejected");
            if (helper_out !== v[547:420])   fail("helper data differs from model");
            if (kcv_out !== v[419:388])      fail("KCV differs from model");
            if (!locked)                     fail("not locked after enrolment");
            if (key_valid || dut.key_q !== 0) fail("key left behind after enrolment");
            check_wiped;

            // 2. second enrolment must be refused and change nothing
            puf_data = v[387:260];
            run_cmd(CMD_ENROL, cyc);
            if (!cmd_err)                    fail("second enrolment accepted");
            if (helper_out !== v[547:420])   fail("helper changed by refused enrolment");

            // 3. MAC without a key must be refused
            challenge = v[127:64];
            run_cmd(CMD_MAC, cyc);
            if (!cmd_err)                    fail("MAC accepted without a valid key");

            // 4. reconstruction from the noisy re-read
            puf_data  = v[387:260];
            helper_in = v[547:420];
            kcv_in    = v[419:388];
            run_cmd(CMD_RECON, recon_cyc);
            if (key_valid !== exp_valid)     fail("key_valid differs from model");
            if (dut.key_q !== v[259:132])    fail("key differs from model");
            if (key_valid && !(ecc_ok && kcv_ok)) fail("key_valid without ecc_ok and kcv_ok");
            check_wiped;
            if (k == 0) $display("REP=%0d latency: ENROL %0d cycles, RECONSTRUCT %0d cycles (incl. 5-cycle PUF stand-in)",
                                 REP, enrol_cyc, recon_cyc);

            // 5. challenge-response
            run_cmd(CMD_MAC, cyc);
            if (exp_valid) begin
                if (cmd_err || tag !== v[63:0]) fail("MAC tag differs from model");
            end else if (!cmd_err)           fail("MAC accepted after failed reconstruction");

            // wrong KCV on a noiseless case: ECC succeeds, key must still be refused
            if (k == 0) begin
                kcv_in = v[419:388] ^ 32'd1;
                run_cmd(CMD_RECON, cyc);
                if (key_valid || !ecc_ok || kcv_ok || dut.key_q !== 0) fail("wrong KCV not rejected");
            end
        end

        // lock restored at boot blocks enrolment; LOCK command is idempotent
        k = -1;
        do_reset(1'b1);
        run_cmd(CMD_ENROL, cyc);
        if (!cmd_err || !locked)             fail("boot_locked did not block enrolment");
        run_cmd(CMD_LOCK, cyc);
        if (cmd_err || !locked)              fail("LOCK command failed");

        if (errors == 0)
            $display("PASS: fuzzy_extractor REP=%0d matches the golden model on all %0d vectors (enrol, lock, reconstruct, KCV, MAC)",
                     REP, N_VEC);
        else
            $display("FAIL: REP=%0d, %0d errors", REP, errors);
        $finish;
    end

endmodule
