# One-off diagnostic: dump the worst 15 setup paths on the clk_sys domain
# (the emu|pll|...divclk clock our audio/CPU logic runs on) with full node
# detail, so we can see WHICH registers are actually failing instead of just
# the aggregate slack/TNS numbers in Arcade-SegaVCO.sta.summary.
#
# Run from the project directory (where Arcade-SegaVCO.qpf lives), against an
# already-compiled project (uses the existing db/ from the last full compile
# -- does not re-run the fitter):
#
#   quartus_sta Arcade-SegaVCO -t sim/report_worst_paths.tcl
#
# Output: output_files/worst_paths.rpt

project_open Arcade-SegaVCO
create_timing_netlist
read_sdc
update_timing_netlist

set clk "emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"

report_timing -setup -npaths 15 -detail full_path \
    -to_clock $clk -from_clock $clk \
    -panel_name "Worst Setup Paths" \
    -file "output_files/worst_paths.rpt"

project_close
