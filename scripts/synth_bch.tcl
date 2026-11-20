# Out-of-context synthesis of the hand-HLS BCH decoders for the Zynq-7010 (Zybo Z7-10):
# {1, 2} GF multipliers x {ESPRESSO SOP, XOR Mastrovito} multiplier implementation.
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/synth_bch.tcl
# Reports are written to docs/reports/synth_bch/. f_max is a post-synthesis estimate
# from a 4 ns clock constraint: f_max = 1 / (period - WNS).
#
# Each configuration is synthesised twice:
#   hier = -flatten_hierarchy none     every GF block stays a separate, fixed resource,
#                                      which is exactly the allocation assumed by the HLS schedule
#   flat = -flatten_hierarchy rebuilt  Vivado's default: optimises across module boundaries

set part    xc7z010clg400-1
set period  4.0
set outdir  docs/reports/synth_bch
file mkdir $outdir

set sources {
    rtl/gf/gf16_mul_sop.v rtl/gf/gf16_mul_xor.v rtl/gf/gf16_inv_sop.v rtl/gf/gf16_mul.v
    rtl/ecc/bch_syndrome.v rtl/ecc/bch_chien_x.v rtl/ecc/bch_dec_1mul.v rtl/ecc/bch_dec_2mul.v
}
set configs {
    {bch_dec_1mul 1 34}
    {bch_dec_1mul 0 34}
    {bch_dec_2mul 1 18}
    {bch_dec_2mul 0 18}
}

set summary [open $outdir/summary.txt w]
puts $summary [format "%-14s %-5s %-5s %5s %5s %8s %9s %8s %12s" \
    module mult synth LUTs FFs "WNS ns" "fmax MHz" cycles "decode ns"]

foreach flatten {none rebuilt} {
foreach cfg $configs {
    lassign $cfg top use_sop cycles
    set mode [expr {$flatten eq "none" ? "hier" : "flat"}]
    set tag  [expr {$use_sop ? "sop" : "xor"}]_$mode
    read_verilog $sources
    synth_design -top $top -part $part -mode out_of_context -generic USE_SOP=$use_sop \
        -flatten_hierarchy $flatten
    create_clock -name clk -period $period [get_ports clk]

    report_utilization    -file $outdir/${top}_${tag}_utilization.rpt
    report_timing_summary -file $outdir/${top}_${tag}_timing.rpt

    # same numbers as the "Slice LUTs" / "Slice Registers" rows of report_utilization
    set util [report_utilization -return_string]
    regexp {Slice LUTs\*?\s*\|\s*(\d+)} $util -> luts
    regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
    set wns  [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
    set fmax [expr {1000.0 / ($period - $wns)}]
    set tdec [expr {$cycles * 1000.0 / $fmax}]
    puts $summary [format "%-14s %-5s %-5s %5d %5d %8.3f %9.1f %8d %12.1f" \
        $top [expr {$use_sop ? "sop" : "xor"}] $mode $luts $ffs $wns $fmax $cycles $tdec]

    close_design
    remove_files [get_files]
}
}
close $summary
puts [read [open $outdir/summary.txt r]]
