# =============================================================================
# setup_project.tcl  —  Impulse  |  Single-Cycle 32-bit CPU
# =============================================================================
# Creates the Vivado project with all RTL and testbench sources configured
# and ready for simulation. Does NOT compile or run any simulations.
#
# Vivado Tcl console:
#   source C:/Users/kapily/Downloads/custom_cpu/vivado/setup_project.tcl
#
# Then simulate any TB manually:
#   set_property top tb_cpu [get_filesets sim_1]
#   launch_simulation
#   run all
#   close_simulation
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set rtl_dir    [file normalize [file join $script_dir .. rtl]]
set tb_dir     [file normalize [file join $script_dir .. tb]]

puts ""
puts "==================================================================="
puts "  Impulse  |  Single-Cycle CPU  |  Project Setup"
puts "==================================================================="

# ── Detect simulator ──────────────────────────────────────────────────────────
if {[info commands create_project] ne ""} {
    set SIM_TOOL "vivado"
} elseif {[info commands vlib] ne ""} {
    set SIM_TOOL "modelsim"
} else {
    puts "\[ERROR\]  Cannot detect simulator (neither create_project nor vlib found)."
    puts "         Source this script from Vivado's Tcl console or ModelSim/Questa."
    return
}

puts "\[INFO\]  Simulator : $SIM_TOOL"
puts "\[INFO\]  RTL dir   : $rtl_dir"
puts "\[INFO\]  TB dir    : $tb_dir"
puts ""

# =============================================================================
# ── VIVADO ────────────────────────────────────────────────────────────────────
# =============================================================================
if {$SIM_TOOL eq "vivado"} {

    set proj_dir [file normalize [file join $script_dir project]]

    create_project -force impulse $proj_dir -part xc7a35tcpg236-1

    set_property simulator_language Mixed         [current_project]
    set_property target_language   Verilog        [current_project]
    set_property default_lib       xil_defaultlib [current_project]

    # ── RTL sources ───────────────────────────────────────────────────────────
    set rtl_files [glob -nocomplain -directory $rtl_dir *.v]

    if {[llength $rtl_files] == 0} {
        error "No RTL .v files found in $rtl_dir"
    }
    add_files -fileset sources_1 -norecurse $rtl_files
    # defines.v is `included by other files — must be added first, then marked
    # as a header so Vivado skips standalone compilation of it.
    set_property file_type {Verilog Header} [get_files */defines.v]
    set_property include_dirs [list $rtl_dir] [get_filesets sources_1]
    update_compile_order -fileset sources_1
    set_property top cpu_top [get_filesets sources_1]
    puts "\[INFO\]  RTL sources added ([llength $rtl_files] files)."

    # ── Testbenches ───────────────────────────────────────────────────────────
    set tb_files [list \
        [file join $tb_dir tb_memcpy.sv    ] \
        [file join $tb_dir tb_array_sum.sv ] \
        [file join $tb_dir tb_minmax.sv    ] \
        [file join $tb_dir tb_sort.sv      ] \
        [file join $tb_dir tb_factorial.sv ] \
        [file join $tb_dir tb_bitops.sv    ] \
        [file join $tb_dir tb_gcd.sv       ] \
        [file join $tb_dir tb_power.sv     ] \
        [file join $tb_dir tb_isqrt.sv     ] \
        [file join $tb_dir tb_collatz.sv   ] \
        [file join $tb_dir tb_fibonacci.sv ] \
        [file join $tb_dir tb_bsearch.sv   ] \
        [file join $tb_dir tb_cpu.sv       ] \
    ]
    add_files -fileset sim_1 -norecurse $tb_files
    # Filter by NAME =~ *.sv so we only touch the TB files, not the inherited
    # RTL .v files that sim_1 also sees from sources_1.
    set_property file_type SystemVerilog \
        [get_files -of_objects [get_filesets sim_1] -filter {NAME =~ *.sv}]
    set_property include_dirs [list $rtl_dir] [get_filesets sim_1]
    set_property xsim.simulate.runtime "" [get_filesets sim_1]
    set_property top     tb_cpu        [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    update_compile_order -fileset sim_1
    puts "\[INFO\]  Testbenches added (13 files)."

    puts ""
    puts "==================================================================="
    puts "  Impulse  |  Project ready (Vivado)."
    puts "  To simulate, pick a TB top and launch from the GUI or Tcl:"
    puts "    set_property top tb_cpu \[get_filesets sim_1\]"
    puts "    launch_simulation"
    puts "    run all"
    puts "    close_simulation"
    puts "==================================================================="

}

puts ""
