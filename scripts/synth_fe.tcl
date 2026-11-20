# Out-of-context synthesis of the complete fuzzy extractor (BCH decoder, SipHash core,
# repetition codec, sequencer) for REP = 1, 3, 5 on the Zynq-7010, at the 125 MHz system clock.
# f_max = 1 / (period - WNS) is a post-synthesis estimate.
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/synth_fe.tcl

set part    xc7z010clg400-1
set period  8.0
set outdir  docs/reports/synth_fe
file mkdir $outdir

set sources {
    rtl/gf/gf16_mul_sop.v rtl/gf/gf16_mul_xor.v rtl/gf/gf16_inv_sop.v rtl/gf/gf16_mul.v
    rtl/ecc/bch_syndrome.v rtl/ecc/bch_chien_x.v rtl/ecc/bch_dec_2mul.v
    rtl/ecc/bch_enc.v rtl/ecc/rep_codec.v rtl/crypto/siphash24.v rtl/fe/fuzzy_extractor.v
}

set summary [open $outdir/summary.txt w]
puts $summary [format "%-16s %5s %5s %5s %8s %9s" config LUTs FFs "LUT%" "WNS ns" "fmax MHz"]

foreach rep {1 3 5} {
    read_verilog $sources
    synth_design -top fuzzy_extractor -part $part -mode out_of_context -generic REP=$rep
    create_clock -name clk -period $period [get_ports clk]

    report_utilization    -file $outdir/fe_r${rep}_utilization.rpt
    report_utilization -hierarchical -file $outdir/fe_r${rep}_utilization_hier.rpt
    report_timing_summary -file $outdir/fe_r${rep}_timing.rpt

    set util [report_utilization -return_string]
    regexp {Slice LUTs\*?\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*([\d.]+)} $util -> luts lutpct
    regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
    set wns  [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
    set fmax [expr {1000.0 / ($period - $wns)}]
    puts $summary [format "%-16s %5d %5d %5s %8.3f %9.1f" "REP=$rep" $luts $ffs $lutpct $wns $fmax]

    close_design
    remove_files [get_files]
}
close $summary
puts [read [open $outdir/summary.txt r]]
