# Cross-build stability check: read N baseline responses per array from the current
# top_char bitstream into data/hw_rebuild_check/ (does not touch the main dataset).
#   vivado -mode batch -nojournal -nolog -source scripts/hw/char_stability.tcl -tclargs [N]
set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl
set n [expr {[llength $argv] > 0 ? [lindex $argv 0] : 20}]
hw_connect $root/build/top_char.bit $root/build/top_char.ltx
puf_reset
vset v_heat 0
foreach arr {0 1 2} {
    file mkdir $root/data/hw_rebuild_check/arr$arr
    set f [open $root/data/hw_rebuild_check/arr$arr/room.txt w]
    fconfigure $f -translation lf
    puts $f "# rebuilt bitstream (unrelated change), array $arr, temp [temperature] C"
    for {set k 0} {$k < $n} {incr k} { puts $f [padhex [puf_response $arr 13 0 0] 32] }
    close $f
    puts "STABILITY array $arr done"
}
close_hw_target
