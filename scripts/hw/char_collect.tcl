# Collect PUF characterisation data from the board (top_char bitstream).
#   vivado -mode batch -nojournal -nolog -source scripts/hw/char_collect.tcl -tclargs <step> [reads]
# Steps:
#   counts  raw counts of all pairs, baseline configuration      -> data/hw_counts/arr<a>_cfg0.csv
#   room    <reads> responses per array at room temperature       -> data/hw_base/arr<a>/room.txt
#           + configurable-RO enrolment (SELECT) and <reads> responses with it
#                                                                 -> data/hw_cfg/arr<a>/room.txt, cfg.txt
#   warm    heater on, wait for the die temperature to settle, then the same reads
#                                                                 -> .../warm.txt (needs cfg.txt from room)
# Response files: one 32-digit hex response per line, bit i = pair i (bit 0 = LSB), with
# the die temperature of each read in a "# temp" comment line before the data.

set root [file normalize [file dirname [info script]]/../..]
source $root/scripts/hw/puf_host.tcl

set step  [lindex $argv 0]
set reads [expr {[llength $argv] > 1 ? [lindex $argv 1] : 100}]
set wlog  13

hw_connect $root/build/top_char.bit $root/build/top_char.ltx
puf_reset
vset v_heat 0

proc write_lines {path lines} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -translation lf
    foreach l $lines { puts $f $l }
    close $f
}

# n reads of one array; cfg_src 0 = baseline (cfg 0), 2 = host-loaded configuration
proc collect {arr n cfg_src} {
    global wlog
    set lines [list "# array $arr, wlog $wlog, cfg_src $cfg_src, start temp [temperature] C"]
    for {set k 0} {$k < $n} {incr k} {
        set r [puf_response $arr $wlog $cfg_src 0]
        if {$k % 10 == 0} { lappend lines "# temp [temperature]" }
        lappend lines [padhex $r 32]
    }
    lappend lines "# end temp [temperature] C"
    return $lines
}

# configurable-RO enrolment: SELECT the most reliable configuration of every pair
# and return it as 96 hex digits (it is stored like helper data and loaded back)
proc select_cfg {arr} {
    puf_run 1 $arr $::wlog 0 0
    refresh_hw_vio [vio]
    return "[padhex [vget_port_hex cfg_best 6] 48][padhex [vget_port_hex cfg_best 5] 48]"
}

switch $step {
    counts {
        foreach arr {0 1 2} {
            puf_response $arr $wlog 0 0
            set lines [list "pair,count_a,count_b"]
            set p 0
            foreach c [puf_counts] { lappend lines "$p,[lindex $c 0],[lindex $c 1]"; incr p }
            write_lines $root/data/hw_counts/arr${arr}_cfg0.csv $lines
            puts "COUNTS array $arr done"
        }
    }
    room - warm {
        if {$step eq "warm"} {
            vset v_heat 1
            set t0 [temperature]
            set prev $t0
            for {set m 0} {$m < 30} {incr m} {             ;# up to ~10 minutes
                after 20000
                set t [temperature]
                puts "HEAT [expr {($m + 1) * 20}] s: $t C"
                if {$m >= 5 && $t - $prev < 0.3} break
                set prev $t
            }
            puts "WARM start $t0 C -> [temperature] C"
        }
        foreach arr {0 1 2} {
            write_lines $root/data/hw_base/arr$arr/$step.txt [collect $arr $reads 0]
            set cfgfile $root/data/hw_cfg/arr$arr/cfg.txt
            if {$step eq "room"} {
                write_lines $cfgfile [list [select_cfg $arr]]
            }
            set f [open $cfgfile r]; set cfg [string trim [read $f]]; close $f
            load_cfg $cfg
            write_lines $root/data/hw_cfg/arr$arr/$step.txt [collect $arr $reads 2]
            puts "COLLECT $step array $arr done, temp [temperature] C"
        }
        vset v_heat 0
    }
    default { error "unknown step $step" }
}
close_hw_target
