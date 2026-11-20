# Host-side helpers for the PUF characterisation design (top_char) over JTAG/VIO.
# Source this from a Vivado batch script, e.g. scripts/hw/char_smoke.tcl.

proc hw_connect {bitfile ltxfile} {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    open_hw_target
    set dev [lindex [get_hw_devices xc7z010*] 0]
    current_hw_device $dev
    set_property PROGRAM.FILE $bitfile $dev
    set_property PROBES.FILE  $ltxfile $dev
    set_property FULL_PROBES.FILE $ltxfile $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    return $dev
}

proc vio {} { return [lindex [get_hw_vios -of_objects [current_hw_device]] 0] }

proc probe {name} {
    set p [get_hw_probes -quiet $name -of_objects [vio]]
    if {$p eq ""} { set p [get_hw_probes -quiet *$name -of_objects [vio]] }
    if {$p eq ""} { error "no VIO probe matching $name" }
    return [lindex $p 0]
}

proc vset {name value} {
    set p [probe $name]
    set_property OUTPUT_VALUE_RADIX UNSIGNED $p
    set_property OUTPUT_VALUE $value $p
    commit_hw_vio $p
}

# lower-case hex string, left-padded with zeros to n digits
proc padhex {hex n} {
    set hex [string tolower $hex]
    return "[string repeat 0 [expr {$n - [string length $hex]}]]$hex"
}

proc vset_hex {name hexvalue} {
    set p [probe $name]
    set_property OUTPUT_VALUE_RADIX HEX $p
    set_property OUTPUT_VALUE $hexvalue $p
    commit_hw_vio $p
}

# load a 384-bit configuration vector (96 hex digits, MSB first) into the design
proc load_cfg {hex384} {
    vset_port_hex v_cfg_host 10 [string range $hex384 0 47]     ;# probe_out10 = bits 383:192
    vset_port_hex v_cfg_host 9  [string range $hex384 48 95]    ;# probe_out9  = bits 191:0
}

# VIO probe connected to probe_in<port> / probe_out<port> whose name starts with prefix.
# Vivado names the slices of one bus h2d_arg, h2d_arg_1, ... in no fixed port order
# (seen on the board: port 2 = "_1", port 3 = "_2", port 4 = no suffix), so slices
# must be selected by port, never by name.
proc probe_port {prefix port} {
    foreach p [get_hw_probes -of_objects [vio]] {
        if {[string match ${prefix}* [get_property NAME $p]] && [get_property PROBE_PORT $p] == $port} {
            return $p
        }
    }
    error "no VIO probe $prefix on port $port"
}

proc vset_port_hex {prefix port hex} {
    set p [probe_port $prefix $port]
    set_property OUTPUT_VALUE_RADIX HEX $p
    set_property OUTPUT_VALUE $hex $p
    commit_hw_vio $p
}

proc vget_port_hex {prefix port} {
    set p [probe_port $prefix $port]
    set_property INPUT_VALUE_RADIX HEX $p
    return [string tolower [get_property INPUT_VALUE $p]]
}

proc vget {name {radix HEX}} {
    set p [probe $name]
    set_property INPUT_VALUE_RADIX $radix $p
    refresh_hw_vio [vio]
    return [get_property INPUT_VALUE $p]
}

proc temperature {} {
    set s [lindex [get_hw_sysmons] 0]
    refresh_hw_sysmon $s
    return [get_property TEMPERATURE $s]
}

# one measurement; returns when the done counter has advanced
proc puf_run {mode arr wlog cfg_src cfg} {
    vset v_mode $mode
    vset v_arr $arr
    vset v_wlog $wlog
    vset v_cfg_src $cfg_src
    vset v_cfg $cfg
    set before [vget done_cnt UNSIGNED]
    set p [probe v_start_tog]
    set_property OUTPUT_VALUE_RADIX UNSIGNED $p
    set_property OUTPUT_VALUE [expr {1 - [get_property OUTPUT_VALUE $p]}] $p
    commit_hw_vio $p
    for {set t 0} {$t < 200} {incr t} {
        if {[vget done_cnt UNSIGNED] != $before && [vget busy UNSIGNED] == 0} { return }
        after 5
    }
    error "measurement timed out"
}

proc puf_response {arr {wlog 13} {cfg_src 0} {cfg 0}} {
    puf_run 0 $arr $wlog $cfg_src $cfg
    return [vget response HEX]
}

# raw counts of the last MEASURE: list of {count_a count_b} for pairs 0..127
proc puf_counts {} {
    set out {}
    for {set p 0} {$p < 128} {incr p} {
        vset v_rd_pair $p
        lappend out [list [vget rd_a UNSIGNED] [vget rd_b UNSIGNED]]
    }
    return $out
}

proc puf_reset {} {
    vset v_rst 1
    vset v_rst 0
}
