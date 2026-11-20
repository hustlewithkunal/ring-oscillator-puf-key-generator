// Code-offset fuzzy extractor with enrol / reconstruct / measure sequencer and one-time lock.
// Bit-exact hardware version of model/fuzzy_extractor.py (see docs/Phase5_Fuzzy_Extractor.md).
//
//   ENROL        measure w; c = Rep_r(BCH(m_0) .. BCH(m_n-1)); helper = w_used ^ c;
//                K = KDF(w_used); kcv = MAC(K, "KCV")[31:0]; K is then zeroised
//                (key_valid stays 0) and the lock is set if AUTO_LOCK.
//   RECONSTRUCT  measure w'; majority-decode (w'_used ^ helper); BCH-decode every block
//                (FAIL on any decoder failure); w = Rep_r(cw) ^ helper; K = KDF(w);
//                key_valid = 1 only if the recomputed KCV equals the stored one.
//   MAC          tag = SipHash(K, challenge), only while key_valid.
//   LOCK         set the sticky lock bit (also restored from boot_locked at reset).
//   MEASURE      one raw measurement; visible on raw_resp only if CHARACTERISATION = 1.
//
// Security properties (proved in Phase 7):
//   * key_valid is set only after the BCH decoder succeeded on every block (ecc_ok)
//     and the key-check value matched.
//   * ENROL is rejected while locked; locked is never cleared except by reset.
// The key K and the response w never appear on any port.

`timescale 1ns / 1ps

module fuzzy_extractor #(
    parameter REP              = 3,     // repetition factor: 1, 3 or 5
    parameter USE_SOP          = 1,     // GF multiplier: 1 = ESPRESSO, 0 = XOR (Mastrovito)
    parameter AUTO_LOCK        = 1,     // lock automatically after a successful enrolment
    parameter CHARACTERISATION = 0      // 1 = expose raw responses (never in the secure build)
) (
    input  wire         clk,
    input  wire         rst,            // synchronous, active high
    input  wire         boot_locked,    // lock state restored during reset

    // command interface: accepted when cmd_valid && !busy
    input  wire         cmd_valid,
    input  wire [2:0]   cmd,
    output wire         busy,
    output reg          done,           // one-cycle pulse when a command finishes
    output reg          cmd_err,        // valid with done: command was rejected

    // PUF measurement unit
    output reg          puf_req,        // one-cycle pulse: start a measurement
    input  wire         puf_valid,      // one-cycle pulse with the response
    input  wire [127:0] puf_resp,

    // enrolment / helper data (public)
    input  wire [55:0]  enrol_msg,      // random BCH messages, block i at [7i+6:7i]
    input  wire [127:0] helper_in,      // offset for RECONSTRUCT (bits above USED ignored)
    input  wire [31:0]  kcv_in,
    output reg  [127:0] helper_out,     // offset produced by ENROL (zero padded)
    output reg  [31:0]  kcv_out,

    // challenge-response
    input  wire [63:0]  challenge,
    output reg  [63:0]  tag,

    // status
    output reg          locked,
    output reg          key_valid,
    output reg          ecc_ok,
    output reg          kcv_ok,
    output wire [127:0] raw_resp        // zero unless CHARACTERISATION
);

    // ------------------------------------------------------------ commands
    localparam [2:0] CMD_MEASURE = 3'd1,
                     CMD_ENROL   = 3'd2,
                     CMD_RECON   = 3'd3,
                     CMD_LOCK    = 3'd4,
                     CMD_MAC     = 3'd5;

    // ------------------------------------------------- code dimensions
    localparam integer BLK     = 15 * REP;              // response bits per BCH block
    localparam integer NBLK    = 128 / BLK;             // 8, 2, 1
    localparam integer USED    = NBLK * BLK;            // 120, 90, 75
    localparam integer NCW     = 15 * NBLK;             // BCH code bits
    localparam integer KDF_LEN = 1 + (USED + 7) / 8;    // KDF message bytes: 16, 13, 11
    localparam integer NB_KDF  = KDF_LEN / 8 + 1;       // SipHash blocks per KDF half
    localparam [7:0]   KDF_LEN8 = KDF_LEN;              // length byte of the last block

    localparam [127:0] KDF_KEY  = 128'h00000031762d46444b2d4655502d4f52;  // "RO-PUF-KDF-v1"
    localparam [63:0]  KCV_BLK  = 64'h030000000056434b;                   // "KCV", length 3
    localparam [63:0]  MAC_LAST = 64'h0800000000000000;                   // length 8

    // ------------------------------------------------------------ state
    localparam [3:0] S_IDLE      = 4'd0,
                     S_MEAS_REQ  = 4'd1,
                     S_MEAS_WAIT = 4'd2,
                     S_ENC       = 4'd3,
                     S_REPDEC    = 4'd4,
                     S_BCH_START = 4'd5,
                     S_BCH_WAIT  = 4'd6,
                     S_REBUILD   = 4'd7,
                     S_H_INIT    = 4'd8,
                     S_H_BLK     = 4'd9,
                     S_H_WAIT    = 4'd10,
                     S_FINISH    = 4'd11;

    localparam [1:0] OP_MEASURE = 2'd0, OP_ENROL = 2'd1, OP_RECON = 2'd2, OP_MAC = 2'd3;
    localparam [1:0] J_KDF_LO = 2'd0, J_KDF_HI = 2'd1, J_KCV = 2'd2, J_MAC = 2'd3;

    reg [3:0]     state;
    reg [1:0]     op;
    reg [1:0]     job;
    reg [1:0]     hb;           // SipHash block index within the current job
    reg [3:0]     blk_i;        // BCH block index
    reg [127:0]   w_q;          // response (secret): measured, then rebuilt
    reg [127:0]   key_q;        // key K (secret)
    reg [55:0]    msg_q;
    reg [127:0]   hlp_q;
    reg [31:0]    kcv_ref;
    reg [63:0]    chal_q;
    reg [NCW-1:0] rx_q;         // BCH input after majority vote
    reg [NCW-1:0] cw_q;         // corrected BCH codewords

    assign busy = (state != S_IDLE);

    // ------------------------------------------------- enrolment encoder
    wire [NCW-1:0]  cw_enr;
    wire [USED-1:0] c_enr;
    genvar b;
    generate
        for (b = 0; b < NBLK; b = b + 1) begin : g_enc
            bch_enc u_enc (.msg(msg_q[7*b +: 7]), .cw(cw_enr[15*b +: 15]));
        end
    endgenerate
    rep_encode #(.N(NCW), .REP(REP)) u_rep_enr (.data(cw_enr), .code(c_enr));

    // ---------------------------------------- reconstruction datapath
    wire [NCW-1:0]  rx_comb;
    wire [USED-1:0] c_rb;
    rep_decode #(.N(NCW), .REP(REP)) u_rep_dec (.code(w_q[USED-1:0] ^ hlp_q[USED-1:0]), .data(rx_comb));
    rep_encode #(.N(NCW), .REP(REP)) u_rep_rb  (.data(cw_q), .code(c_rb));

    wire        dec_start = (state == S_BCH_START);
    wire        dec_done, dec_ok;
    wire [14:0] dec_corr;
    bch_dec_2mul #(.USE_SOP(USE_SOP)) u_dec (
        .clk(clk), .rst(rst), .start(dec_start), .r(rx_q[15*blk_i +: 15]),
        .busy(), .done(dec_done), .s1(), .s3(), .l1(), .l2(), .err_mask(),
        .corrected(dec_corr), .ok(dec_ok));

    // ------------------------------------------------------- SipHash jobs
    wire [191:0] kdf_msg = {{(184 - USED){1'b0}}, w_q[USED-1:0],
                            (job == J_KDF_LO) ? 8'h01 : 8'h02};
    reg  [63:0]  sip_blk;
    reg          sip_last;
    always @* begin
        case (job)
            J_KDF_LO, J_KDF_HI: begin
                sip_last = (hb == NB_KDF - 1);
                sip_blk  = sip_last ? {KDF_LEN8, kdf_msg[64*hb +: 56]} : kdf_msg[64*hb +: 64];
            end
            J_KCV: begin
                sip_last = 1'b1;
                sip_blk  = KCV_BLK;
            end
            default: begin                      // J_MAC
                sip_last = (hb == 2'd1);
                sip_blk  = sip_last ? MAC_LAST : chal_q;
            end
        endcase
    end

    wire         sip_ready, sip_tag_valid;
    wire [63:0]  sip_tag;
    wire         sip_init  = (state == S_H_INIT);
    wire         sip_valid = (state == S_H_BLK) && sip_ready;
    wire [127:0] sip_key   = (job == J_KDF_LO || job == J_KDF_HI) ? KDF_KEY : key_q;
    siphash24 u_sip (
        .clk(clk), .rst(rst), .init(sip_init), .key(sip_key),
        .blk_valid(sip_valid), .blk(sip_blk), .blk_last(sip_last),
        .ready(sip_ready), .tag_valid(sip_tag_valid), .tag(sip_tag));

    // ---------------------------------------------- characterisation port
    generate
        if (CHARACTERISATION) begin : g_char
            reg [127:0] raw_q;
            always @(posedge clk)
                if (rst)                                                   raw_q <= 128'd0;
                else if (state == S_MEAS_WAIT && puf_valid && op == OP_MEASURE) raw_q <= puf_resp;
            assign raw_resp = raw_q;
        end else begin : g_secure
            assign raw_resp = 128'd0;
        end
    endgenerate

    // ------------------------------------------------------------ sequencer
    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            op         <= OP_MEASURE;
            job        <= J_KDF_LO;
            hb         <= 2'd0;
            blk_i      <= 4'd0;
            w_q        <= 128'd0;
            key_q      <= 128'd0;
            msg_q      <= 56'd0;
            hlp_q      <= 128'd0;
            kcv_ref    <= 32'd0;
            chal_q     <= 64'd0;
            rx_q       <= {NCW{1'b0}};
            cw_q       <= {NCW{1'b0}};
            done       <= 1'b0;
            cmd_err    <= 1'b0;
            puf_req    <= 1'b0;
            helper_out <= 128'd0;
            kcv_out    <= 32'd0;
            tag        <= 64'd0;
            locked     <= boot_locked;
            key_valid  <= 1'b0;
            ecc_ok     <= 1'b0;
            kcv_ok     <= 1'b0;
        end else begin
            done    <= 1'b0;
            puf_req <= 1'b0;
            case (state)
                S_IDLE: if (cmd_valid) begin
                    cmd_err <= 1'b0;
                    case (cmd)
                        CMD_MEASURE: begin
                            op    <= OP_MEASURE;
                            state <= S_MEAS_REQ;
                        end
                        CMD_ENROL: begin
                            if (locked) begin
                                cmd_err <= 1'b1;
                                done    <= 1'b1;
                            end else begin
                                op         <= OP_ENROL;
                                msg_q      <= enrol_msg;
                                key_q      <= 128'd0;
                                key_valid  <= 1'b0;
                                ecc_ok     <= 1'b0;
                                kcv_ok     <= 1'b0;
                                helper_out <= 128'd0;
                                kcv_out    <= 32'd0;
                                state      <= S_MEAS_REQ;
                            end
                        end
                        CMD_RECON: begin
                            op        <= OP_RECON;
                            hlp_q     <= helper_in;
                            kcv_ref   <= kcv_in;
                            key_q     <= 128'd0;
                            key_valid <= 1'b0;
                            ecc_ok    <= 1'b0;
                            kcv_ok    <= 1'b0;
                            state     <= S_MEAS_REQ;
                        end
                        CMD_LOCK: begin
                            locked <= 1'b1;
                            done   <= 1'b1;
                        end
                        CMD_MAC: begin
                            if (!key_valid) begin
                                cmd_err <= 1'b1;
                                done    <= 1'b1;
                            end else begin
                                op     <= OP_MAC;
                                chal_q <= challenge;
                                job    <= J_MAC;
                                state  <= S_H_INIT;
                            end
                        end
                        default: begin
                            cmd_err <= 1'b1;
                            done    <= 1'b1;
                        end
                    endcase
                end

                S_MEAS_REQ: begin
                    puf_req <= 1'b1;
                    state   <= S_MEAS_WAIT;
                end
                S_MEAS_WAIT: if (puf_valid) begin
                    case (op)
                        OP_ENROL: begin w_q <= puf_resp; state <= S_ENC;    end
                        OP_RECON: begin w_q <= puf_resp; state <= S_REPDEC; end
                        default:  state <= S_FINISH;                    // MEASURE
                    endcase
                end

                // -------- enrolment: helper = w_used ^ codeword
                S_ENC: begin
                    helper_out <= {{(128 - USED){1'b0}}, w_q[USED-1:0] ^ c_enr};
                    job        <= J_KDF_LO;
                    state      <= S_H_INIT;
                end

                // -------- reconstruction: majority vote, BCH per block, rebuild w
                S_REPDEC: begin
                    rx_q  <= rx_comb;
                    blk_i <= 4'd0;
                    state <= S_BCH_START;
                end
                S_BCH_START: state <= S_BCH_WAIT;
                S_BCH_WAIT: if (dec_done) begin
                    if (!dec_ok) begin
                        state <= S_FINISH;                              // ECC failure
                    end else begin
                        cw_q[15*blk_i +: 15] <= dec_corr;
                        if (blk_i == NBLK - 1) begin
                            ecc_ok <= 1'b1;
                            state  <= S_REBUILD;
                        end else begin
                            blk_i <= blk_i + 4'd1;
                            state <= S_BCH_START;
                        end
                    end
                end
                S_REBUILD: begin
                    w_q   <= {{(128 - USED){1'b0}}, c_rb ^ hlp_q[USED-1:0]};
                    job   <= J_KDF_LO;
                    state <= S_H_INIT;
                end

                // -------- SipHash jobs: KDF low, KDF high, KCV  /  MAC
                S_H_INIT: begin
                    hb    <= 2'd0;
                    state <= S_H_BLK;
                end
                S_H_BLK: if (sip_ready) begin
                    if (sip_last) state <= S_H_WAIT;
                    else          hb    <= hb + 2'd1;
                end
                S_H_WAIT: if (sip_tag_valid) begin
                    case (job)
                        J_KDF_LO: begin
                            key_q[63:0] <= sip_tag;
                            job         <= J_KDF_HI;
                            state       <= S_H_INIT;
                        end
                        J_KDF_HI: begin
                            key_q[127:64] <= sip_tag;
                            job           <= J_KCV;
                            state         <= S_H_INIT;
                        end
                        J_KCV: begin
                            if (op == OP_ENROL) begin
                                kcv_out <= sip_tag[31:0];
                                key_q   <= 128'd0;                      // enrolment never leaves a key
                                if (AUTO_LOCK) locked <= 1'b1;
                            end else if (sip_tag[31:0] == kcv_ref && ecc_ok) begin
                                kcv_ok    <= 1'b1;
                                key_valid <= 1'b1;
                            end else begin
                                key_q <= 128'd0;                        // wrong key: zeroise
                            end
                            state <= S_FINISH;
                        end
                        default: begin                                  // J_MAC
                            tag   <= sip_tag;
                            state <= S_FINISH;
                        end
                    endcase
                end

                S_FINISH: begin
                    w_q   <= 128'd0;                                    // response-derived data no
                    rx_q  <= {NCW{1'b0}};                               // longer needed: with the
                    cw_q  <= {NCW{1'b0}};                               // helper they would reveal w
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
