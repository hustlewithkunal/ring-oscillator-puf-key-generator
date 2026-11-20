`timescale 1ns / 1ps
// Whole-system simulation: soc (RV32I core running sw/firmware.mem, fuzzy extractor)
// + puf_measure with the behavioural RO model (2 arrays, short window for speed).
// The testbench is the host: it writes the mailbox and waits for the echoed sequence
// number, exactly as scripts/hw/soc_host.tcl does over JTAG on the board.
//
// Scenario (the project demo):
//   PING; ENROL device 0 (baseline); RECONSTRUCT device 0 -> key valid; AUTH twice ->
//   identical tags; second ENROL -> refused (locked); RECONSTRUCT on device 1 with
//   device 0's helper data -> key invalid, AUTH refused;
//   reset; ENROL device 0 with configurable ROs; LOAD_HELPER (host copy); RECONSTRUCT
//   -> key valid; AUTH -> tag.

module tb_soc;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #4 clk = ~clk;

    reg  [7:0]   h2d_seq = 8'd0, h2d_cmd = 8'd0;
    reg  [767:0] h2d_arg = 768'd0;
    wire [7:0]   d2h_seq;
    wire [31:0]  d2h_status;
    wire [767:0] d2h_data;
    wire [3:0]   led;
    wire         trap, key_valid;

    wire         puf_start, puf_mode, puf_busy, puf_done;
    wire [1:0]   puf_arr;
    wire [383:0] puf_cfg, puf_cfg_best;
    wire [127:0] puf_response;

    soc #(.REP(3), .USE_SOP(1), .FW_FILE("firmware.mem")) dut (
        .clk(clk), .rst(rst), .boot_locked(1'b0),
        .puf_start(puf_start), .puf_mode(puf_mode), .puf_arr(puf_arr), .puf_cfg(puf_cfg),
        .puf_busy(puf_busy), .puf_done(puf_done), .puf_response(puf_response),
        .puf_cfg_best(puf_cfg_best),
        .h2d_seq(h2d_seq), .h2d_cmd(h2d_cmd), .h2d_arg(h2d_arg),
        .d2h_seq(d2h_seq), .d2h_status(d2h_status), .d2h_data(d2h_data),
        .sw(4'b0001), .btn(4'd0), .led(led), .trap(trap), .key_valid(key_valid));

    wire [19:0] rd_a, rd_b;
    puf_measure #(.N_ARR(2), .CW(20)) u_puf (
        .clk(clk), .rst(rst), .start(puf_start), .mode(puf_mode), .arr_sel(puf_arr),
        .wlog(4'd8), .pair_cfg(puf_cfg), .busy(puf_busy), .done(puf_done),
        .response(puf_response), .cfg_best(puf_cfg_best),
        .rd_pair(7'd0), .rd_cnt_a(rd_a), .rd_cnt_b(rd_b));

    integer errors = 0;
    reg [543:0] helper;          // 17 words
    reg [63:0]  tag1, tag2;

    // status bits
    localparam ST_CMDERR = 2, ST_LOCKED = 3, ST_KEYVALID = 4, ST_ECC = 5, ST_KCV = 6;

    task host;                   // one mailbox transaction
        input [7:0]   cmd;
        input [767:0] arg;
        integer t;
        begin
            t = 0;                              // wait until the firmware has booted (status
            while ((d2h_seq != h2d_seq || d2h_status == 32'd0) && t < 100000) begin   // != 0) and is in sync
                @(negedge clk);
                t = t + 1;
            end
            @(negedge clk);
            h2d_cmd = cmd;
            h2d_arg = arg;
            @(negedge clk);
            h2d_seq = h2d_seq + 8'd1;          // the sequence number is written last
            t = 0;
            while (d2h_seq != h2d_seq && t < 4000000) begin
                @(negedge clk);
                t = t + 1;
            end
            if (d2h_seq != h2d_seq) begin
                $display("TIMEOUT cmd %0d", cmd);
                errors = errors + 1;
            end
        end
    endtask

    task expect;
        input cond;
        input [8*48-1:0] what;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("ERROR: %0s (status %h)", what, d2h_status);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;

        host(8'd1, 768'd0);
        expect(d2h_data[31:0] == 32'h52563332, "PING answer");
        $display("PING    : firmware %h, version %h", d2h_data[31:0], d2h_data[63:32]);

        // ---------------- baseline RO-PUF
        host(8'd2, {672'd0, 32'd0, 32'd0, 32'h00ABCDEF, 32'h12345678});   // dev 0, baseline
        expect(!d2h_status[ST_CMDERR] && d2h_status[ST_LOCKED], "enrol accepted and locked");
        helper = d2h_data[543:0];
        $display("ENROL   : status %h, helper %h..., kcv %h", d2h_status, d2h_data[127:96], d2h_data[159:128]);

        host(8'd4, 768'd0);                                                // RECONSTRUCT dev 0
        expect(d2h_status[ST_KEYVALID] && d2h_status[ST_ECC] && d2h_status[ST_KCV], "key valid on device 0");
        $display("RECON 0 : status %h (key_valid %b)", d2h_status, d2h_status[ST_KEYVALID]);

        host(8'd5, {704'd0, 64'h0123456789ABCDEF});
        tag1 = d2h_data[63:0];
        host(8'd5, {704'd0, 64'h0123456789ABCDEF});
        tag2 = d2h_data[63:0];
        expect(tag1 == tag2 && tag1 != 64'd0, "same challenge -> same tag");
        host(8'd5, {704'd0, 64'h0123456789ABCDEE});
        expect(d2h_data[63:0] != tag1, "different challenge -> different tag");
        $display("AUTH    : tag %h (repeat %h)", tag1, tag2);

        host(8'd2, {672'd0, 32'd0, 32'd0, 32'h0, 32'h1});
        expect(d2h_status[ST_CMDERR] && d2h_data[543:0] == helper, "second enrolment refused, helper kept");
        $display("ENROL 2 : status %h (cmd_err %b)", d2h_status, d2h_status[ST_CMDERR]);

        host(8'd4, {736'd0, 32'd1});                                       // RECONSTRUCT dev 1
        expect(!d2h_status[ST_KEYVALID], "other device: key invalid");
        host(8'd5, {704'd0, 64'h0123456789ABCDEF});
        expect(d2h_status[ST_CMDERR] && d2h_data[63:0] == 64'd0, "other device: authentication refused");
        $display("DEVICE 1: reconstruct key_valid %b, auth refused %b", dut.key_valid, d2h_status[ST_CMDERR]);

        // ---------------- configurable RO-PUF after a reset (lock cleared: boot_locked = 0)
        @(negedge clk); rst = 1'b1; repeat (3) @(negedge clk); rst = 1'b0;
        host(8'd2, {672'd0, 32'd0, 32'd1, 32'h00112233, 32'h44556677});   // dev 0, configurable
        expect(!d2h_status[ST_CMDERR], "configurable enrolment accepted");
        helper = d2h_data[543:0];
        $display("ENROL C : status %h, configuration word0 %h", d2h_status, d2h_data[191:160]);
        expect(d2h_data[543:160] == u_puf.cfg_best, "helper holds the selected configuration");

        host(8'd3, {224'd0, helper});                                      // host restores helper
        host(8'd4, 768'd0);
        expect(d2h_status[ST_KEYVALID], "configurable: key valid");
        host(8'd5, {704'd0, 64'hFEEDFACECAFEBEEF});
        expect(!d2h_status[ST_CMDERR] && d2h_data[63:0] != 64'd0, "configurable: authenticated");
        $display("RECON C : status %h, tag %h", d2h_status, d2h_data[63:0]);

        if (trap) begin errors = errors + 1; $display("ERROR: CPU trapped"); end
        if (errors == 0) $display("PASS: SoC firmware, fuzzy extractor and PUF work end to end");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
