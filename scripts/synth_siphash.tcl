# Out-of-context synthesis of the SipHash-2-4 core for the Zynq-7010 (Zybo Z7-10).
# Constrained to the 125 MHz system clock; f_max = 1 / (period - WNS) is a post-synthesis estimate.
#
# Run from the project root:
#   vivado -mode batch -nojournal -nolog -source scripts/synth_siphash.tcl

set part    xc7z010clg400-1
set period  8.0
set outdir  docs/reports/synth_siphash
file mkdir $outdir

read_verilog rtl/crypto/siphash24.v
synth_design -top siphash24 -part $part -mode out_of_context
create_clock -name clk -period $period [get_ports clk]

report_utilization    -file $outdir/siphash24_utilization.rpt
report_timing_summary -file $outdir/siphash24_timing.rpt

set util [report_utilization -return_string]
regexp {Slice LUTs\*?\s*\|\s*(\d+)} $util -> luts
regexp {Slice Registers\s*\|\s*(\d+)} $util -> ffs
regexp {CARRY4\s*\|\s*(\d+)} [report_utilization -return_string] -> carry
set path [lindex [get_timing_paths -max_paths 1 -setup] 0]
set wns    [get_property SLACK $path]
set levels [get_property LOGIC_LEVELS $path]
set fmax   [expr {1000.0 / ($period - $wns)}]

set summary [open $outdir/summary.txt w]
puts $summary [format "%-10s %5s %5s %6s %8s %7s %9s" module LUTs FFs CARRY4 "WNS ns" levels "fmax MHz"]
puts $summary [format "%-10s %5d %5d %6s %8.3f %7d %9.1f" siphash24 $luts $ffs $carry $wns $levels $fmax]
close $summary
puts [read [open $outdir/summary.txt r]]
