# Copyright 2020 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -group {CORE0} {sim:/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/inst_data_i}
add wave -noupdate -group {CORE0} {sim:/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/instr_decoded}
add wave -noupdate -group {CORE0} {sim:/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/fu_data}
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {0 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {0 ps} {15540 ns}
