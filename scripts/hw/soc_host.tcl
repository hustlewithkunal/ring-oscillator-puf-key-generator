# Host side of the SoC mailbox (top_soc bitstream) over JTAG/VIO.
# Source after puf_host.tcl (uses hw_connect, vio, probe, padhex).
#
# Protocol: wait until the firmware is in sync (d2h_seq == h2d_seq and status != 0),
# write the arguments and the command, then change h2d_seq last; wait for the echo.

proc vset_probe_hex {name hex} {
    set p [probe $name]
    set_property OUTPUT_VALUE_RADIX HEX $p
    set_property OUTPUT_VALUE $hex $p
    commit_hw_vio $p
}

proc vget_hex {name} {
    set p [probe $name]
    set_property INPUT_VALUE_RADIX HEX $p
    return [string tolower [get_property INPUT_VALUE $p]]
}

# 8 words -> 64 hex digits, word 0 in the least significant position
proc words_to_hex {words} {
    set hex ""
    foreach w [lreverse $words] { append hex [format %08x [expr {$w & 0xFFFFFFFF}]] }
    return $hex
}

proc hex_to_words {hex n} {
    set hex [padhex $hex [expr {8 * $n}]]
    set words {}
    for {set k [expr {$n - 1}]} {$k >= 0} {incr k -1} {
        lappend words [expr "0x[string range $hex [expr {8 * ($n - 1 - $k)}] [expr {8 * ($n - 1 - $k) + 7}]]"]
    }
    return [lreverse $words]
}

proc soc_wait_sync {{timeout_ms 5000}} {
    set t0 [clock milliseconds]
    while {1} {
        refresh_hw_vio [vio]
        set d [expr "0x[vget_hex d2h_seq]"]
        set h [get_property OUTPUT_VALUE [probe h2d_seq]]
        set st [expr "0x[vget_hex d2h_status]"]
        if {$d == [expr "0x$h"] && $st != 0} { return }
        if {[clock milliseconds] - $t0 > $timeout_ms} { error "firmware not responding (d2h_seq $d, h2d_seq $h, status $st)" }
        after 2
    }
}

# soc_cmd cmd ?args? -> {status {data0 .. data23}}
proc soc_cmd {cmd {args_words {}}} {
    soc_wait_sync
    set a [concat $args_words [lrepeat [expr {24 - [llength $args_words]}] 0]]
    vset_port_hex h2d_arg 2 [words_to_hex [lrange $a 0 7]]      ;# probe_out2 = words 0..7
    vset_port_hex h2d_arg 3 [words_to_hex [lrange $a 8 15]]     ;# probe_out3 = words 8..15
    vset_port_hex h2d_arg 4 [words_to_hex [lrange $a 16 23]]    ;# probe_out4 = words 16..23
    vset_probe_hex h2d_cmd [format %02x $cmd]
    set seq [expr {("0x[get_property OUTPUT_VALUE [probe h2d_seq]]" + 1) & 0xFF}]
    vset_probe_hex h2d_seq [format %02x $seq]
    set t0 [clock milliseconds]
    while {1} {
        refresh_hw_vio [vio]
        if {[expr "0x[vget_hex d2h_seq]"] == $seq} break
        if {[clock milliseconds] - $t0 > 10000} { error "command $cmd timed out" }
        after 2
    }
    set status [expr "0x[vget_hex d2h_status]"]
    set data [concat [hex_to_words [vget_port_hex d2h_data 2] 8] [hex_to_words [vget_port_hex d2h_data 3] 8] \
                     [hex_to_words [vget_port_hex d2h_data 4] 8]]
    return [list $status $data]
}

proc st_bit {status bit} { return [expr {($status >> $bit) & 1}] }
proc st_text {s} {
    return "key_valid=[st_bit $s 4] locked=[st_bit $s 3] cmd_err=[st_bit $s 2] ecc_ok=[st_bit $s 5] kcv_ok=[st_bit $s 6]"
}

proc soc_reset {} {
    vset_probe_hex v_rst 1
    vset_probe_hex v_rst 0
    after 50
}
