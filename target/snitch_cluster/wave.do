onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -group MAIN {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/inst_data_i}
add wave -noupdate -group MAIN {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/instr_decoded}
add wave -noupdate -group MAIN {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/fu_data}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/clk_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/rst_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/hart_id_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/irq_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/flush_i_ready_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/inst_data_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/inst_ready_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/acc_qready_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/acc_pvalid_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/barrier_i}
add wave -noupdate -group SCHNIZO {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/instr_retired_spatz}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/clk_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/rst_ni}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/issue_valid_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/rsp_ready_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/fpu_rnd_mode_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/fpu_fmt_mode_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vfu_req_ready_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vfu_rsp_valid_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vfu_rsp_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vlsu_req_ready_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vlsu_rsp_valid_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vlsu_rsp_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vsldu_req_ready_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vsldu_rsp_valid_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/vsldu_rsp_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/sb_enable_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/sb_wrote_result_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/sb_read_result_i}
add wave -noupdate -group SPATZ_CONTROLLER {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_controller/sb_id_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/clk_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/rst_ni}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/testmode_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/waddr_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/wdata_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/we_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/wbe_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/fpu_buf_usage_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/raddr_i}
add wave -noupdate -group VRF {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/i_fu_stage/gen_rvv_block/i_spatz/i_vrf/re_i}
add wave -noupdate {/tb_bin/fix/i_snitch_cluster/i_cluster/gen_core[0]/i_snitch_cc/i_schnizo/internal_spatz_traces}
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
