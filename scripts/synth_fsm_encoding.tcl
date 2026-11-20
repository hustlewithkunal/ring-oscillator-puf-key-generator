# State-encoding study of the fuzzy-extractor sequencer (12 states) on the Zynq-7010:
# the same RTL synthesised with Vivado's FSM extraction forced to different encodings.
#   off        = keep the 4-bit binary encoding written in the RTL
#   one_hot / sequential / gray / johnson = Vivado re-encodes the recognised FSMs
# Out of context, 125 MHz constraint; f_max = 1 / (8 ns - WNS) (post-synthesis estimate).
#   vivado -mode batch -nojournal -nolog -source scripts/synth_fsm_encoding.tcl

set srcs {rtl/gf/gf16_mul_sop.v rtl/gf/gf16_mul_xor.v rtl/gf/gf16_inv_sop.v rtl/gf/gf16_mul.v
          rtl/ecc/bch_syndrome.v rtl/ecc/bch_chien_x.v rtl/ecc/bch_dec_2mul.v rtl/ecc/bch_enc.v
          rtl/ecc/rep_codec.v rtl/crypto/siphash24.v rtl/fe/fuzzy_extractor.v}
file mkdir docs/reports/fsm_encoding
set out [open docs/reports/fsm_encoding/summary.txt w]
puts $out [format "%-11s %5s %5s %8s %9s  %s" encoding LUTs FFs "WNS ns" "fmax MHz" "FSMs re-encoded"]
foreach enc {off one_hot sequential gray johnson} {
    read_verilog $srcs
    synth_design -top fuzzy_extractor -part xc7z010clg400-1 -mode out_of_context \
        -generic REP=3 -fsm_extraction $enc
    create_clock -name clk -period 8.0 [get_ports clk]
    set u [report_utilization -return_string]
    regexp {Slice LUTs\*?\s*\|\s*(\d+)} $u -> luts
    regexp {Slice Registers\s*\|\s*(\d+)} $u -> ffs
    set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
    # how many FSMs did Vivado recognise / re-encode (from the synthesis messages)
    set n [llength [get_msg_config -count -id {Synth 8-802}]]
    report_utilization -file docs/reports/fsm_encoding/util_$enc.rpt
    puts $out [format "%-11s %5d %5d %8.3f %9.1f  %s" $enc $luts $ffs $wns [expr {1000.0/(8.0-$wns)}] \
        [get_msg_config -count -id {Synth 8-802}]]
    close_design
    remove_files [get_files]
}
close $out
puts [read [open docs/reports/fsm_encoding/summary.txt r]]
