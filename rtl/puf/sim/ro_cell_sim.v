// Behavioural simulation model of ro_cell (NOT synthesisable). Compile this file
// instead of rtl/puf/ro_cell.v in simulation: a zero-delay LUT loop would hang the
// simulator.
//
// Each instance gets its own random frequency (process variation), a different
// small shift for each of the 8 configurations, and per-half-period jitter (noise),
// so the measurement logic sees realistic, slightly noisy pair comparisons.

`timescale 1ns / 1ps

module ro_cell (
    input  wire       en,
    input  wire [2:0] cfg,
    output wire       tog
);

    parameter real NOMINAL_HALF_NS = 1.40;      // ~357 MHz RO
    parameter real SIGMA_PROCESS   = 0.005;     // 0.5 % RO-to-RO variation
    parameter real SIGMA_CFG       = 0.003;     // per-configuration shift
    parameter real SIGMA_JITTER    = 0.010;     // per half period

    real half_cfg [0:7];
    real base;
    integer c;
    reg  osc = 1'b1;
    reg  t   = 1'b0;

    function real gauss;        // approx. N(0,1) from 12 uniforms
        input integer dummy;
        integer k;
        real s;
        begin
            s = 0.0;
            for (k = 0; k < 12; k = k + 1)
                s = s + $urandom % 10000 / 10000.0;
            gauss = s - 6.0;
        end
    endfunction

    initial begin
        base = NOMINAL_HALF_NS * (1.0 + SIGMA_PROCESS * gauss(0));
        for (c = 0; c < 8; c = c + 1)
            half_cfg[c] = base * (1.0 + SIGMA_CFG * gauss(c));
    end

    always begin
        if (en) begin
            #(half_cfg[cfg] * (1.0 + SIGMA_JITTER * gauss(1)));
            osc = ~osc;
        end else begin
            osc = 1'b1;
            @(posedge en);
        end
    end

    always @(posedge osc) t <= ~t;

    assign tog = t;

endmodule
