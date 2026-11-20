# Out-of-context synthesis of the GF(2^4) blocks for the Zynq-7010 (Zybo Z7-10).
# Compares the ESPRESSO sum-of-products multiplier with the XOR (Mastrovito) one.
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/synth_gf.tcl
# Reports are written to docs/reports/synth_gf/.

set part    xc7z010clg400-1
set outdir  docs/reports/synth_gf
file mkdir $outdir

set summary [open $outdir/summary.txt w]
puts $summary [format "%-14s %6s %10s %14s" module LUTs "LUT levels" "path delay ns"]

foreach top {gf16_mul_sop gf16_mul_xor gf16_inv_sop} {
    read_verilog rtl/gf/$top.v
    synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
    report_utilization -file $outdir/${top}_utilization.rpt
    report_timing -from [all_inputs] -to [all_outputs] -max_paths 1 -file $outdir/${top}_timing.rpt

    set luts [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
    set path [lindex [get_timing_paths -from [all_inputs] -to [all_outputs] -max_paths 1] 0]
    set levels [get_property LOGIC_LEVELS $path]
    set delay  [get_property DATAPATH_DELAY $path]
    puts $summary [format "%-14s %6d %10d %14.3f" $top $luts $levels $delay]

    close_design
    remove_files [get_files]
}
close $summary
puts [read [open $outdir/summary.txt r]]
