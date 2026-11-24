# Helpers that let the build scripts run on Vivado versions other than 2024.2
# (the version the project was developed and measured with). Sourced by
# build_soc.tcl and build_char.tcl.
#
# compat_open_project: opens RTL_Project_Vivado, or creates it on a fresh system.
#   If that project was saved by a different Vivado version, it is left untouched
#   (an older Vivado cannot open a newer project, and a newer one would upgrade it
#   in place) and a separate project RTL_Project_Vivado_v<version> is used instead.
# compat_vio <name>: creates the VIO debug core with whichever VIO version this
#   Vivado provides, or upgrades an existing core that is locked to another version.

set COMPAT_TESTED "2024.2"
set COMPAT_PART   "xc7z010clg400-1"

proc compat_xpr_version {xpr} {
    # the .xpr header says e.g. <!-- Product Version: Vivado v2024.2 (64-bit) -->
    set f [open $xpr r]
    set head [read $f 2000]
    close $f
    if {[regexp {Product Version: Vivado v([0-9]+\.[0-9]+)} $head -> v]} { return $v }
    return ""
}

proc compat_open_project {} {
    global COMPAT_TESTED COMPAT_PART
    set here [version -short]
    regexp {^[0-9]+\.[0-9]+} $here here
    if {$here ne $COMPAT_TESTED} {
        puts "COMPAT: running Vivado $here; the project was developed with $COMPAT_TESTED."
        puts "COMPAT: the build should work, but a different tool version places the non-RO"
        puts "COMPAT: logic differently, so the PUF responses will differ from the reported ones."
    }
    set name RTL_Project_Vivado
    set xpr  $name/$name.xpr
    if {[file exists $xpr]} {
        set saved [compat_xpr_version $xpr]
        if {$saved ne "" && $saved ne $here} {
            puts "COMPAT: $xpr was saved by Vivado $saved; leaving it untouched."
            set name RTL_Project_Vivado_v[string map {. _} $here]
            set xpr  $name/$name.xpr
        }
    }
    if {[file exists $xpr]} {
        open_project $xpr
    } else {
        puts "COMPAT: creating project $name"
        create_project $name $name -part $COMPAT_PART
    }
}

proc compat_vio {name} {
    set ip [get_ips -quiet $name]
    if {$ip eq ""} {
        set defs [get_ipdefs -all -quiet xilinx.com:ip:vio:*]
        if {[llength $defs] == 0} { error "no VIO IP (xilinx.com:ip:vio) in this Vivado installation" }
        set vlnv [lindex [lsort -dictionary $defs] end]   ;# objects print as their VLNV
        puts "COMPAT: creating $name from $vlnv"
        create_ip -vlnv $vlnv -module_name $name
    } elseif {[get_property IS_LOCKED $ip]} {
        puts "COMPAT: $name is locked to another Vivado version, upgrading it"
        upgrade_ip $ip
    }
}
