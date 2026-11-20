# Verify that a routed design uses exactly the locked RO routes of constraints/puf_routes.xdc.
#   vivado -mode batch -nojournal -nolog -source scripts/check_puf_routes.tcl -tclargs <routed.dcp>

set root [file normalize [file dirname [info script]]/..]
open_checkpoint [lindex $argv 0]

set expected {}
set f [open $root/constraints/puf_routes.xdc r]
while {[gets $f line] >= 0} {
    if {[regexp {^set_property FIXED_ROUTE \{(.*)\} \[get_nets \{(.*)\}\]$} $line -> route net]} {
        dict set expected $net [string trim $route]
    }
}
close $f

set same 0
set diff 0
dict for {net route} $expected {
    set actual [string trim [get_property ROUTE [get_nets $net]]]
    # compare with whitespace normalised
    if {[regsub -all {\s+} $actual " "] eq [regsub -all {\s+} $route " "]} {
        incr same
    } else {
        incr diff
        if {$diff <= 3} { puts "ROUTE_DIFF $net" }
    }
}
puts "ROUTE_CHECK [dict size $expected] RO nets: $same identical, $diff different"
