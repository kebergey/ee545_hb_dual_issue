/**
 *    vanilla_core.v
 *
 *    Link to schematic:
 *    https://docs.google.com/presentation/d/1ZeRHYhqMHJQ0mRgDTilLuWQrZF7On-Be_KNNosgeW0c/edit?usp=sharing
 *
 */

`include "bsg_manycore_defines.svh"
`include "bsg_vanilla_defines.svh"

module vanilla_core
  import bsg_vanilla_pkg::*;
  import bsg_manycore_pkg::*;
  import bsg_manycore_addr_pkg::*;
  #(`BSG_INV_PARAM(data_width_p)
    , `BSG_INV_PARAM(dmem_size_p)
    
    , `BSG_INV_PARAM(icache_entries_p)
    , `BSG_INV_PARAM(icache_tag_width_p)

    , `BSG_INV_PARAM(x_cord_width_p)
    , `BSG_INV_PARAM(y_cord_width_p)

    , `BSG_INV_PARAM(pod_x_cord_width_p)
    , `BSG_INV_PARAM(pod_y_cord_width_p)
    , `BSG_INV_PARAM(barrier_dirs_p)

    , `BSG_INV_PARAM(icache_block_size_in_words_p)
   
    , localparam barrier_lg_dirs_lp=`BSG_SAFE_CLOG2(barrier_dirs_p+1)
    , parameter credit_counter_width_p=`BSG_WIDTH(32)

    // For network input FIFO credit counting
      // By default, 3 credits are needed, because the round trip to get the credit back takes three cycles.
      // ID->EXE->FIFO->CREDIT.
    , `BSG_INV_PARAM(fwd_fifo_els_p)
    , localparam lg_fwd_fifo_els_lp=`BSG_WIDTH(fwd_fifo_els_p)

    , dmem_addr_width_lp=`BSG_SAFE_CLOG2(dmem_size_p)
    , pc_width_lp=(icache_tag_width_p+`BSG_SAFE_CLOG2(icache_entries_p))
    , reg_addr_width_lp = RV32_reg_addr_width_gp
    , data_mask_width_lp=(data_width_p>>3)

    , parameter debug_p=0
  )
  (
    input clk_i
    // network_reset_i used in icache to reset the icache write counter 
    // so that icache can be written by remote packets while the tile is still in freeze reset.
    , input network_reset_i
    , input reset_i

    , input [pc_width_lp-1:0] pc_init_val_i

    // to network
    , output remote_req_s remote_req_o
    , output logic remote_req_v_o
    , input remote_req_credit_i

    // from network
    , input icache_v_i
    , input [pc_width_lp-1:0] icache_pc_i
    , input [data_width_p-1:0] icache_instr_i
    , output logic icache_yumi_o
    
    , input ifetch_v_i
    , input [data_width_p-1:0] ifetch_instr_i
  
    , input remote_dmem_v_i
    , input remote_dmem_w_i
    , input [dmem_addr_width_lp-1:0] remote_dmem_addr_i
    , input [data_mask_width_lp-1:0] remote_dmem_mask_i
    , input [data_width_p-1:0] remote_dmem_data_i
    , output logic [data_width_p-1:0] remote_dmem_data_o
    , output logic remote_dmem_yumi_o

    , input [reg_addr_width_lp-1:0] float_remote_load_resp_rd_i
    , input [data_width_p-1:0] float_remote_load_resp_data_i
    , input float_remote_load_resp_v_i
    , input float_remote_load_resp_force_i
    , output logic float_remote_load_resp_yumi_o

    , input [reg_addr_width_lp-1:0] int_remote_load_resp_rd_i
    , input [data_width_p-1:0] int_remote_load_resp_data_i
    , input int_remote_load_resp_v_i
    , input int_remote_load_resp_force_i
    , output logic int_remote_load_resp_yumi_o

    , input invalid_eva_access_i

    // remote interrupt interface
    , input remote_interrupt_set_i
    , input remote_interrupt_clear_i
    , output logic remote_interrupt_pending_bit_o

    // remaining credits
    , input [credit_counter_width_p-1:0] out_credits_used_i    

    // barrier interface
    , input barrier_data_i
    , output barrier_data_o
    , output [barrier_dirs_p-1:0] barrier_src_r_o
    , output [barrier_lg_dirs_lp-1:0] barrier_dest_r_o

    // pod csr coord.
    , output [pod_x_cord_width_p-1:0] cfg_pod_x_o
    , output [pod_y_cord_width_p-1:0] cfg_pod_y_o
   
    // For debugging + reset
    , input [x_cord_width_p-1:0] global_x_i
    , input [y_cord_width_p-1:0] global_y_i
  );



  // reset edge down detect
  logic reset_r;
  bsg_dff #(.width_p(1)) reset_dff (
    .clk_i(clk_i)
    ,.data_i(reset_i)
    ,.data_o(reset_r)
  );  

  wire reset_down = reset_r & ~reset_i;


  // pipeline signals
  // ctrl signals set to zero when reset_i is high.
  // data signals are not reset to zero.
  logic id_en, exe_en, mem_ctrl_en, mem_data_en, fp_exe_ctrl_en, fp_exe_data_en, flw_wb_ctrl_en, flw_wb_data_en;
  
  id_signals_s id_int_r, id_int_n, id_fp_r, id_fp_n;
  exe_signals_s exe_int_r, exe_int_n, exe_fp_r, exe_fp_n;
  mem_ctrl_signals_s mem_ctrl_int_r, mem_ctrl_int_n, mem_ctrl_fp_r, mem_ctrl_fp_n;
  mem_data_signals_s mem_data_int_r, mem_data_int_n, mem_data_fp_r, mem_data_fp_n;

  wb_ctrl_signals_s wb_ctrl_r, wb_ctrl_n;
  wb_data_signals_s wb_data_r, wb_data_n;
  fp_exe_ctrl_signals_s fp_exe_ctrl_n, fp_exe_ctrl_r;
  fp_exe_data_signals_s fp_exe_data_n, fp_exe_data_r;
  flw_wb_ctrl_signals_s flw_wb_ctrl_n, flw_wb_ctrl_r;
  flw_wb_data_signals_s flw_wb_data_n, flw_wb_data_r;

  // icache
  //
  localparam lg_icache_block_size_in_words_lp = `BSG_SAFE_CLOG2(icache_block_size_in_words_p);
  logic icache_v_li;
  logic icache_w_li;
  logic icache_read_pc_plus4_li, icache_read_pc_plus8_li;

  logic [pc_width_lp-1:0] icache_w_pc;
  logic [data_width_p-1:0] icache_winstr;

  logic [pc_width_lp-1:0] pc_n, pc_r;
  logic [pc_width_lp-1:0] pc_mem_ctrl_int_n, pc_mem_ctrl_int_r, pc_mem_ctrl_fp_n, pc_mem_ctrl_fp_r;
  instruction_s instruction0, instruction1, instruction_fp, instruction_int;
  logic icache_miss;
  logic icache_flush;
  logic icache_flush_r_lo;
  logic icache_branch_predicted_taken_lo;

  logic [pc_width_lp-1:0] jalr_prediction; 
  logic [pc_width_lp-1:0] pred_or_jump_addr; 

  logic int_is_instr0_lo, fp_is_isntr0_lo, is_dual_issue_lo;

  decode_s decode0, decode1, decode_int, decode_fp;
  fp_decode_s fp_decode0, fp_decode1, fp_decode_int, fp_decode_fp;
  logic instr_int_v_lo, instr_fp_v_lo, single_issue_is_int_lo;
 
 
  icache #(
    .icache_tag_width_p(icache_tag_width_p)
    ,.icache_entries_p(icache_entries_p)
    ,.icache_block_size_in_words_p(icache_block_size_in_words_p)
  ) icache0 (
    .clk_i(clk_i)
    ,.network_reset_i(network_reset_i)
    ,.reset_i(reset_i)
   
    ,.v_i(icache_v_li)
    ,.w_i(icache_w_li)
    ,.flush_i(icache_flush)
    ,.read_pc_plus4_i(icache_read_pc_plus4_li)
    ,.read_pc_plus8_i(icache_read_pc_plus8_li)

    ,.w_pc_i(icache_w_pc)
    ,.w_instr_i(icache_winstr)
    
    //,.int_is_instr0_i(int_is_instr0_lo)
    ,.instr0_decode_i(decode0)
    ,.is_dual_issue_i(is_dual_issue_lo)

    ,.pc_i(pc_n)
    ,.jalr_prediction_i(jalr_prediction)

    ,.instr0_o(instruction0)
    ,.instr1_o(instruction1)
    
    ,.pred_or_jump_addr_o(pred_or_jump_addr)
    ,.pc_r_o(pc_r)
    ,.icache_miss_o(icache_miss)
    ,.icache_flush_r_o(icache_flush_r_lo)
    ,.branch_predicted_taken_o(icache_branch_predicted_taken_lo)
  );

  wire [pc_width_lp-1:0] pc_plus4 = pc_r + 1'b1;
  wire [pc_width_lp-1:0] pc_plus8 = pc_r + 2'b10;

  // ifetch counter
  logic [lg_icache_block_size_in_words_lp-1:0] ifetch_count_r;
  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
      ifetch_count_r <= '0;
    end
    else begin
      if (ifetch_v_i) begin
        ifetch_count_r <= ifetch_count_r + 1'b1;
      end
    end
  end

  // debug pc
  // synopsys translate_off
  wire [data_width_p-1:0] if_pc = {{(data_width_p-pc_width_lp-2){1'b0}}, pc_r, 2'b00};
  wire [data_width_p-1:0] id_pc = (id_int_r.pc_plus4 - 'd4);
  wire [data_width_p-1:0] exe_pc = (exe_int_r.pc_plus4 - 'd4);
  /* if we wanted the PCs to be accurate vvv
  wire [data_width_p-1:0] id_int_pc = (id_int_r.pc_plus4 - 'd4);
  wire [data_width_p-1:0] id_fp_pc = (id_fp_r.pc_plus4 - 'd4);
  wire [data_width_p-1:0] id_pc = is_dual_issue_lo ? 
                  (int_is_instr0_lo ? id_fp_pc : id_int_pc) :
                  (single_issue_is_int_lo ? id_int_pc : id_fp_pc);
  wire [data_width_p-1:0] exe_int_pc = (exe_int_r.pc_plus4 - 'd4);
  wire [data_width_p-1:0] exe_fp_pc = (exe_fp_r.pc_plus4 - 'd4);
  wire [data_width_p-1:0] exe_pc = (exe_fp_r.valid & exe_int_r.valid) ? 
                  ((exe_int_pc > exe_fp_pc) ? exe_int_pc : exe_fp_pc) :
                  (exe_int_r.valid ? exe_int_pc : exe_fp_pc);
  */
  // synopsys translate_on

  // instruction decode
  //

  cl_decode decode0_inst (
    .instruction_i(instruction0)
    ,.decode_o(decode0)
    ,.fp_decode_o(fp_decode0)
  ); 

  cl_decode decode1_inst (
    .instruction_i(instruction1)
    ,.decode_o(decode1)
    ,.fp_decode_o(fp_decode1)
  ); 

  instr_scheduler # (
    .pc_width_p(pc_width_lp)
  ) instr_scheduler_inst (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.pc_r_i(pc_r)
    ,.instruction0_i(instruction0)
    ,.decode0_i(decode0)
    ,.fp_decode0_i(fp_decode0)
    ,.instruction1_i(instruction1)
    ,.decode1_i(decode1)
    ,.fp_decode1_i(fp_decode1)
    ,.branch_predicted_taken_i(icache_branch_predicted_taken_lo)

    ,.is_dual_issue_o(is_dual_issue_lo)
    ,.single_issue_is_int_o(single_issue_is_int_lo)
    
    ,.instruction_int_o(instruction_int)
    ,.decode_int_o(decode_int)
    ,.fp_decode_int_o(fp_decode_int)
    ,.instruction_fp_o(instruction_fp)
    ,.decode_fp_o(decode_fp)
    ,.fp_decode_fp_o(fp_decode_fp)
    ,.instr_int_v_o(instr_int_v_lo)
    ,.instr_fp_v_o(instr_fp_v_lo)
    ,.int_is_instr0_o(int_is_instr0_lo)
    ,.fp_is_instr0_o(fp_is_isntr0_lo)
);


  //////////////////////////////
  //                          //
  //        ID STAGE          //
  //                          //
  //////////////////////////////

  bsg_dff_reset_en #(
    .width_p($bits(id_signals_s))
  ) id_int_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(id_en)
    ,.data_i(id_int_n)
    ,.data_o(id_int_r)
  );
  
  bsg_dff_reset_en #(
    .width_p($bits(id_signals_s))
  ) id_fp_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(id_en)
    ,.data_i(id_fp_n)
    ,.data_o(id_fp_r)
  );

  // int regfile
  //
  logic int_rf_wen;
  logic [reg_addr_width_lp-1:0] int_rf_waddr;
  logic [data_width_p-1:0] int_rf_wdata;
 
  logic [1:0] int_rf_read;
  logic [1:0][data_width_p-1:0] int_rf_rdata;
  logic [reg_addr_width_lp-1:0] int_rf_rs1, int_rf_rs2;

  regfile #(
    .width_p(data_width_p)
    ,.els_p(RV32_reg_els_gp)
    ,.num_rs_p(2)
    ,.x0_tied_to_zero_p(1)
  ) int_rf (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.w_v_i(int_rf_wen)
    ,.w_addr_i(int_rf_waddr)
    ,.w_data_i(int_rf_wdata)

    ,.r_v_i(int_rf_read)
    ,.r_addr_i({int_rf_rs2, int_rf_rs1})
    ,.r_data_o(int_rf_rdata)
  );
  

  //  int scoreboard
  //
  logic int_dependency_int, int_dependency_fp, int_dependency;
  logic int_sb_score;
  logic [reg_addr_width_lp-1:0] int_sb_score_id;
  logic int_sb_clear;
  logic [reg_addr_width_lp-1:0] int_sb_clear_id;
  logic [reg_addr_width_lp-1:0] int_sb_rs1, int_sb_rs2, int_sb_rd;
  logic int_sb_read_rs1, int_sb_read_rs2, int_sb_write_rd;

  scoreboard #(
    .els_p(RV32_reg_els_gp)
    ,.num_src_port_p(2)
    ,.num_clear_port_p(1)
    ,.x0_tied_to_zero_p(1)
  ) int_sb (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
  
    ,.src_id_i({int_sb_rs2, int_sb_rs1})
    ,.dest_id_i(id_int_r.instruction.rd)

    ,.op_reads_rf_i({id_int_r.decode.read_rs2, id_int_r.decode.read_rs1})
    ,.op_writes_rf_i(id_int_r.decode.write_rd)

    ,.score_i(int_sb_score)
    ,.score_id_i(int_sb_score_id)

    ,.clear_i(int_sb_clear)
    ,.clear_id_i(int_sb_clear_id)

    ,.dependency_o(int_dependency)
  );

  // mux scoreboard inputs and distribute outputs
  assign int_sb_rs1 = id_int_r.valid ? id_int_r.instruction.rs1 : id_fp_r.instruction.rs1;
  assign int_sb_rs2 = id_int_r.instruction.rs2;
  assign int_sb_rd = id_int_r.valid ? id_int_r.instruction.rd : id_fp_r.instruction.rd;
  assign int_sb_read_rs1 = (id_int_r.valid & id_int_r.decode.read_rs1) | (id_fp_r.valid & id_fp_r.decode.read_rs1);
  assign int_sb_read_rs2 = (id_int_r.valid & id_int_r.decode.read_rs2);
  assign int_sb_write_rd = (id_int_r.valid & id_int_r.decode.write_rd) | (id_fp_r.valid & id_fp_r.decode.write_rd);
  assign int_dependency_int = int_dependency & id_int_r.valid;
  assign int_dependency_fp = int_dependency & id_fp_r.valid;

  // FP regfile
  //
  logic [1:0] float_rf_wen;
  logic [1:0][reg_addr_width_lp-1:0] float_rf_waddr;
  logic [1:0][fpu_recoded_data_width_gp-1:0] float_rf_wdata;
  logic [reg_addr_width_lp-1:0] float_rf_waddr0, float_rf_waddr1;
  logic [fpu_recoded_data_width_gp-1:0] float_rf_wdata0, float_rf_wdata1;

  // for debug
  assign float_rf_wdata0 = float_rf_wdata[0];
  assign float_rf_wdata1 = float_rf_wdata[1];
  assign float_rf_waddr0 = float_rf_waddr[0];
  assign float_rf_waddr1 = float_rf_waddr[1];
 
  logic [2:0] float_rf_read;
  logic [2:0][fpu_recoded_data_width_gp-1:0] float_rf_rdata;
  logic [reg_addr_width_lp-1:0] float_rf_frs1, float_rf_frs2, float_rf_frs3;
  logic [fpu_recoded_data_width_gp-1:0] float_rf_rdata0, float_rf_rdata1, float_rf_rdata2;
  assign float_rf_rdata0 = float_rf_rdata[0];
  assign float_rf_rdata1 = float_rf_rdata[1];
  assign float_rf_rdata2 = float_rf_rdata[2];

  regfile #(
    .width_p(fpu_recoded_data_width_gp)
    ,.els_p(RV32_reg_els_gp)
    ,.num_rs_p(3)
    ,.x0_tied_to_zero_p(0)
    ,.num_rd_p(2)
  ) float_rf (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.w_v_i(float_rf_wen)
    ,.w_addr_i(float_rf_waddr)
    ,.w_data_i(float_rf_wdata)

    ,.r_v_i(float_rf_read)
    ,.r_addr_i({instruction_fp[31:27], float_rf_frs2, float_rf_frs1})
    ,.r_data_o(float_rf_rdata)
  );


  // FP scoreboard
  //
  logic float_dependency_int, float_dependency_fp;
  logic [1:0] float_dependency_int_split, float_dependency_fp_split;
  logic float_sb_score_fdiv, float_sb_score_mem;
  logic [reg_addr_width_lp-1:0] float_sb_score_id_fdiv, float_sb_score_id_mem;
  logic float_sb_clear_mem, float_sb_clear_fdiv;
  logic [reg_addr_width_lp-1:0] float_sb_clear_mem_id, float_sb_clear_fdiv_id;

  scoreboard #(
    .els_p(RV32_reg_els_gp)
    ,.x0_tied_to_zero_p(0)
    ,.num_src_port_p(2) // int only needs to check two ports, never reads frs3
    ,.num_clear_port_p(2)
  ) float_sb_int0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
  
    ,.src_id_i({id_int_r.instruction.rs2, id_int_r.instruction.rs1})
    ,.dest_id_i(id_int_r.instruction.rd)

    ,.op_reads_rf_i({id_int_r.decode.read_frs2, id_int_r.decode.read_frs1})
    ,.op_writes_rf_i(id_int_r.decode.write_frd)

    ,.score_i(float_sb_score_mem)
    ,.score_id_i(float_sb_score_id_mem)

    ,.clear_i({float_sb_clear_mem, float_sb_clear_fdiv})
    ,.clear_id_i({float_sb_clear_mem_id, float_sb_clear_fdiv_id})

    ,.dependency_o(float_dependency_int_split[0])
  );

  scoreboard #(
    .els_p(RV32_reg_els_gp)
    ,.x0_tied_to_zero_p(0)
    ,.num_src_port_p(3)
    ,.num_clear_port_p(2)
  ) float_sb_fp0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
  
    ,.src_id_i({id_fp_r.instruction[31:27], id_fp_r.instruction.rs2, id_fp_r.instruction.rs1})
    ,.dest_id_i(id_fp_r.instruction.rd)

    ,.op_reads_rf_i({id_fp_r.decode.read_frs3, id_fp_r.decode.read_frs2, id_fp_r.decode.read_frs1})
    ,.op_writes_rf_i(id_fp_r.decode.write_frd)

    ,.score_i(float_sb_score_mem)
    ,.score_id_i(float_sb_score_id_mem)

    ,.clear_i({float_sb_clear_mem, float_sb_clear_fdiv})
    ,.clear_id_i({float_sb_clear_mem_id, float_sb_clear_fdiv_id})

    ,.dependency_o(float_dependency_fp_split[0])
  );

  
  scoreboard #(
    .els_p(RV32_reg_els_gp)
    ,.x0_tied_to_zero_p(0)
    ,.num_src_port_p(2) // int only needs to check two ports, never reads frs3
    ,.num_clear_port_p(2)
  ) float_sb_int1 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
  
    ,.src_id_i({id_int_r.instruction.rs2, id_int_r.instruction.rs1})
    ,.dest_id_i(id_int_r.instruction.rd)

    ,.op_reads_rf_i({id_int_r.decode.read_frs2, id_int_r.decode.read_frs1})
    ,.op_writes_rf_i(id_int_r.decode.write_frd)

    ,.score_i(float_sb_score_fdiv)
    ,.score_id_i(float_sb_score_id_fdiv)

    ,.clear_i({float_sb_clear_mem, float_sb_clear_fdiv})
    ,.clear_id_i({float_sb_clear_mem_id, float_sb_clear_fdiv_id})

    ,.dependency_o(float_dependency_int_split[1])
  );

  scoreboard #(
    .els_p(RV32_reg_els_gp)
    ,.x0_tied_to_zero_p(0)
    ,.num_src_port_p(3)
    ,.num_clear_port_p(2)
  ) float_sb_fp1 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
  
    ,.src_id_i({id_fp_r.instruction[31:27], id_fp_r.instruction.rs2, id_fp_r.instruction.rs1})
    ,.dest_id_i(id_fp_r.instruction.rd)

    ,.op_reads_rf_i({id_fp_r.decode.read_frs3, id_fp_r.decode.read_frs2, id_fp_r.decode.read_frs1})
    ,.op_writes_rf_i(id_fp_r.decode.write_frd)

    ,.score_i(float_sb_score_fdiv)
    ,.score_id_i(float_sb_score_id_fdiv)

    ,.clear_i({float_sb_clear_mem, float_sb_clear_fdiv})
    ,.clear_id_i({float_sb_clear_mem_id, float_sb_clear_fdiv_id})

    ,.dependency_o(float_dependency_fp_split[1])
  );

  assign float_dependency_fp = |float_dependency_fp_split;
  assign float_dependency_int = |float_dependency_int_split;

  // FCSR
  //
  logic fcsr_v_li;
  logic [2:0] fcsr_funct3_li;
  logic [reg_addr_width_lp-1:0] fcsr_rs1_li;
  fcsr_s fcsr_data_li;
  logic [11:0] fcsr_addr_li;
  fcsr_s fcsr_data_lo;
  logic fcsr_data_v_lo;
  logic [1:0] fcsr_fflags_v_li;
  fflags_s [1:0] fcsr_fflags_li;
  frm_e frm_r;

  fcsr fcsr0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    
    ,.v_i(fcsr_v_li)
    ,.funct3_i(fcsr_funct3_li)
    ,.rs1_i(fcsr_rs1_li)
    ,.data_i(fcsr_data_li)
    ,.addr_i(fcsr_addr_li)
    ,.data_o(fcsr_data_lo)
    ,.data_v_o(fcsr_data_v_lo)
    // [0] fpu_int -> MEM
    // [1] fpu_float, fdiv -> FP_WB
    ,.fflags_v_i(fcsr_fflags_v_li)
    ,.fflags_i(fcsr_fflags_li)
    ,.frm_o(frm_r)
  );

  
  // MCSR
  logic mcsr_we_li;
  logic [data_width_p-1:0] mcsr_data_li;
  logic [data_width_p-1:0] mcsr_data_lo;

  logic mcsr_instr_executed_li;
  logic mcsr_interrupt_entered_li;
  logic mcsr_mret_called_li;
  logic [pc_width_lp-1:0] mcsr_npc_r_li;

  csr_mstatus_s mstatus_r;
  csr_interrupt_vector_s mip_r;
  csr_interrupt_vector_s mie_r;
  logic [pc_width_lp-1:0] mepc_r;
  logic [credit_counter_width_p-1:0] credit_limit_r;
   
  logic mcsr_barsend_li;

  mcsr #(
    .pc_width_p(pc_width_lp)
    ,.credit_counter_width_p(credit_counter_width_p)
    ,.cfg_pod_width_p(pod_y_cord_width_p+pod_x_cord_width_p)
    ,.barrier_dirs_p(barrier_dirs_p)
  ) mcsr0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.remote_interrupt_set_i(remote_interrupt_set_i)
    ,.remote_interrupt_clear_i(remote_interrupt_clear_i)

    ,.we_i      (mcsr_we_li)
    ,.addr_i    (id_int_r.instruction[31:20])
    ,.funct3_i  (id_int_r.instruction.funct3)
    ,.data_i    (mcsr_data_li)
    ,.rs1_i     (id_int_r.instruction.rs1)
    ,.data_o    (mcsr_data_lo)

    ,.cfg_pod_reset_val_i({global_y_i[y_cord_width_p-1-:pod_y_cord_width_p]
			   ,global_x_i[x_cord_width_p-1-:pod_x_cord_width_p]}
			  )
    ,.cfg_pod_r_o({cfg_pod_y_o,cfg_pod_x_o})
    ,.instr_executed_i(mcsr_instr_executed_li)
    ,.interrupt_entered_i(mcsr_interrupt_entered_li)
    ,.mret_called_i(mcsr_mret_called_li)
    ,.npc_r_i(mcsr_npc_r_li)

    ,.barsend_i(mcsr_barsend_li)
    ,.barrier_data_i(barrier_data_i)
    ,.barrier_data_o(barrier_data_o)

    ,.mstatus_r_o(mstatus_r)
    ,.mip_r_o(mip_r)
    ,.mie_r_o(mie_r)
    ,.mepc_r_o(mepc_r)
    ,.credit_limit_o(credit_limit_r)
    ,.barrier_src_r_o(barrier_src_r_o)
    ,.barrier_dest_r_o(barrier_dest_r_o)
  );

  // Sensitivity list like this is disliked by Verilator 4.213
  `ifndef VERILATOR
   always @ (cfg_pod_y_o or cfg_pod_x_o)
     begin
	$display("%m cfg_pod_r changing to y=%b x=%b"
		 , cfg_pod_y_o
		 , cfg_pod_x_o);
     end
  `endif
   
  // synopsys translate_off
  wire [pc_width_lp+2-1:0] mepc_00 = {mepc_r, 2'b00};
  // synopsys translate_on

  assign remote_interrupt_pending_bit_o = mip_r.remote; // make it accessible by remote packet.

  // Interrupt can be taken when mstatus.mie=1 and enable and pending bits are both on for an interrupt source,
  // When icache miss is not already in progress (e.g. no icache bubble in EXE, MEM or WB)
  wire remote_interrupt_ready = mip_r.remote & mie_r.remote;
  wire trace_interrupt_ready = mip_r.trace & mie_r.trace;
  wire interrupt_ready = mstatus_r.mie
                       & (remote_interrupt_ready | trace_interrupt_ready)
                       & ~(exe_int_r.icache_miss | mem_ctrl_int_r.icache_miss | wb_ctrl_r.icache_miss);

  // calculate mem address offset
  //
  wire [RV32_Iimm_width_gp-1:0] mem_addr_op2 = id_int_r.decode.is_store_op
    ? `RV32_Simm_12extract(id_int_r.instruction)
    : (id_int_r.decode.is_load_op
      ? `RV32_Iimm_12extract(id_int_r.instruction)
      : '0);

  // 'aq' register
  // When amo_op with aq is issued to EXE, 'aq' register is set.
  // While 'aq' is set, subsequent memory ops (e.g. load, store, lr, AMO) cannot be isssued, until 'aq' is cleared.
  // When the amoswap result returns and clears the scoreboard, it also clears the 'aq'.
  // Even if amoswap.w.aq has x0 as rd, 'aq' bit is set.
  // Since AMO op is only supported for remote, only remote resp can clear the 'aq'.
  logic aq_r;
  logic aq_clear;
  logic aq_set;
  logic [reg_addr_width_lp-1:0] aq_rd_r;

  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
      aq_r <= 1'b0;
      aq_rd_r <= '0;
    end
    else begin
      if (aq_set) begin
        aq_r <= 1'b1;
        aq_rd_r <= id_int_r.instruction.rd;
      end
      else if (aq_clear) begin
        aq_r <= 1'b0;
      end
    end
  end


  // FP_EXE forwarding muxes
  //
  
  // select between rs1 and frs1
  logic [fpu_recoded_data_width_gp-1:0] frs1_select_val;
  logic select_rs1_to_fp_exe;

  bsg_mux #(
    .els_p(2)
    ,.width_p(fpu_recoded_data_width_gp)
  ) frs1_select_mux (
    .data_i({{1'b0, int_rf_rdata[0]}, float_rf_rdata[0]})
    ,.sel_i(select_rs1_to_fp_exe)
    ,.data_o(frs1_select_val)
  );
  
  logic [1:0] frs1_forward_v;
  logic [1:0] frs2_forward_v;
  logic [1:0] frs3_forward_v;
  logic [fpu_recoded_data_width_gp-1:0] frs1_to_fp_exe;
  logic [fpu_recoded_data_width_gp-1:0] frs2_to_fp_exe;
  logic [fpu_recoded_data_width_gp-1:0] frs3_to_fp_exe;
  logic [fpu_recoded_data_width_gp-1:0] frs1_rf_wdata_val, frs2_rf_wdata_val, frs3_rf_wdata_val;

  // forwarded values can come from either FP regfile write port (but only one will match)
  assign frs1_rf_wdata_val = frs1_forward_v[0] ? float_rf_wdata[0] : float_rf_wdata[1];
  assign frs2_rf_wdata_val = frs2_forward_v[0] ? float_rf_wdata[0] : float_rf_wdata[1];
  assign frs3_rf_wdata_val = frs3_forward_v[0] ? float_rf_wdata[0] : float_rf_wdata[1];

  // select the forwarded data if either FP regfile write port has valid data
  bsg_mux #(
    .els_p(2)
    ,.width_p(fpu_recoded_data_width_gp)
  ) frs1_fwd_mux (
    .data_i({frs1_rf_wdata_val, frs1_select_val})
    ,.sel_i(|frs1_forward_v)
    ,.data_o(frs1_to_fp_exe)
  );

  bsg_mux #(
    .els_p(2)
    ,.width_p(fpu_recoded_data_width_gp)
  ) frs2_fwd_mux (
    .data_i({frs2_rf_wdata_val, float_rf_rdata[1]})
    ,.sel_i(|frs2_forward_v)
    ,.data_o(frs2_to_fp_exe)
  );

  bsg_mux #(
    .els_p(2)
    ,.width_p(fpu_recoded_data_width_gp)
  ) frs3_fwd_mux (
    .data_i({frs3_rf_wdata_val, float_rf_rdata[2]})
    ,.sel_i(|frs3_forward_v)
    ,.data_o(frs3_to_fp_exe)
  );


  // EXE FORWARDING MUX
  logic [data_width_p-1:0] fsw_data;
  recFNToFN #(
    .expWidth(fpu_recoded_exp_width_gp)
    ,.sigWidth(fpu_recoded_sig_width_gp) 
  ) frs2_to_fn (
    .in(float_rf_rdata[1])
    ,.out(fsw_data)
  );

  logic [data_width_p-1:0] exe_result;
  logic [data_width_p-1:0] mem_result;
  logic [1:0] rs1_forward_sel;
  logic [1:0] rs2_forward_sel;
  logic [data_width_p-1:0] rs1_forward_val;
  logic [data_width_p-1:0] rs2_forward_val;
  logic rs1_forward_v;
  logic rs2_forward_v;

  bsg_mux #(
    .els_p(3)
    ,.width_p(data_width_p)
  ) exe_rs1_fwd_mux (
    .data_i({wb_data_r.rf_data, mem_result, exe_result})
    ,.sel_i(rs1_forward_sel)
    ,.data_o(rs1_forward_val)
  );
  
  bsg_mux #(
    .els_p(3)
    ,.width_p(data_width_p)
  ) exe_rs2_fwd_mux (
    .data_i({wb_data_r.rf_data, mem_result, exe_result})
    ,.sel_i(rs2_forward_sel)
    ,.data_o(rs2_forward_val)
  );

  logic [data_width_p-1:0] rs1_val_to_exe;
  logic [data_width_p-1:0] rs2_val_to_exe;

  assign rs1_val_to_exe = rs1_forward_v
    ? rs1_forward_val
    : int_rf_rdata[0];
  
  assign rs2_val_to_exe = id_int_r.decode.read_frs2
    ? fsw_data
    : (rs2_forward_v
      ? rs2_forward_val
      : int_rf_rdata[1]);


  //////////////////////////////
  //                          //
  //        EXE STAGE         //
  //                          //
  //////////////////////////////

  bsg_dff_reset_en #(
    .width_p($bits(exe_signals_s))
  ) exe_int_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(exe_en)
    ,.data_i(exe_int_n)
    ,.data_o(exe_int_r)
  );

  bsg_dff_reset_en #(
    .width_p($bits(exe_signals_s))
  ) exe_fp_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(exe_en)
    ,.data_i(exe_fp_n)
    ,.data_o(exe_fp_r)
  );


  // ALU
  //
  logic [data_width_p-1:0] alu_result;
  logic [pc_width_lp-1:0] alu_jalr_addr;
  logic alu_jump_now;

  alu #(
    .pc_width_p(pc_width_lp)
  ) alu0 (
    .rs1_i(exe_int_r.rs1_val)
    ,.rs2_i(exe_int_r.rs2_val)
    ,.pc_plus4_i(exe_int_r.pc_plus4)
    ,.op_i(exe_int_r.instruction)
    ,.result_o(alu_result)
    ,.jalr_addr_o(alu_jalr_addr)
    ,.jump_now_o(alu_jump_now)
  );


  // save pc+4 of jalr/jal for predicting jalr branch target
  // For risc-v, hints for saving return address for jalr/jal are encoded implicitly in the rd used.
  // For jalr/jal, save the pc+4 when rd = x1 or x5.
  wire jalr_prediction_write_en = (exe_int_r.decode.is_jal_op | exe_int_r.decode.is_jalr_op)
    & ((exe_int_r.instruction.rd == 5'd1) | (exe_int_r.instruction.rd == 5'd5));

  bsg_dff_reset_en_bypass #(
    .width_p(pc_width_lp)
  ) jalr_pred_dff (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(jalr_prediction_write_en)
    ,.data_i(exe_int_r.pc_plus4[2+:pc_width_lp])
    ,.data_o(jalr_prediction)
  ); 

  // alu/csr result mux
  wire [data_width_p-1:0] alu_or_csr_result = exe_int_r.decode.is_csr_op
    ? exe_int_r.rs2_val
    : alu_result;


  // IDIV
  //
  logic idiv_v_li;
  logic idiv_ready_and_lo;
  logic idiv_v_lo;
  logic [reg_addr_width_lp-1:0] idiv_rd_lo;
  logic [data_width_p-1:0] idiv_result_lo;
  logic idiv_yumi_li;

  idiv idiv0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.v_i(idiv_v_li)
    ,.rs1_i(exe_int_r.rs1_val)
    ,.rs2_i(exe_int_r.rs2_val)
    ,.rd_i(exe_int_r.instruction.rd)
    ,.op_i(exe_int_r.decode.idiv_op)
    ,.ready_and_o(idiv_ready_and_lo)
  
    ,.v_o(idiv_v_lo)
    ,.rd_o(idiv_rd_lo)
    ,.result_o(idiv_result_lo)
    ,.yumi_i(idiv_yumi_li)
  );
  

  // LSU
  //
  logic lsu_remote_req_v_lo;
  logic lsu_dmem_v_lo;
  logic lsu_dmem_w_lo;
  logic [dmem_addr_width_lp-1:0] lsu_dmem_addr_lo;
  logic [data_width_p-1:0] lsu_dmem_data_lo;
  logic [data_mask_width_lp-1:0] lsu_dmem_mask_lo;
  logic lsu_reserve_lo;
  logic [1:0] lsu_byte_sel_lo;

  lsu #(
    .data_width_p(data_width_p)
    ,.pc_width_p(pc_width_lp)
    ,.dmem_size_p(dmem_size_p)
  ) lsu0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.exe_decode_i(exe_int_r.decode)
    ,.exe_rs1_i(exe_int_r.rs1_val)
    ,.exe_rs2_i(exe_int_r.rs2_val)
    ,.exe_rd_i(exe_int_r.instruction.rd)
    ,.mem_offset_i(exe_int_r.mem_addr_op2)
    ,.pc_plus4_i(exe_int_r.pc_plus4)
    ,.icache_miss_i(exe_int_r.icache_miss)

    ,.remote_req_o(remote_req_o)
    ,.remote_req_v_o(lsu_remote_req_v_lo)

    ,.dmem_v_o(lsu_dmem_v_lo)
    ,.dmem_w_o(lsu_dmem_w_lo)
    ,.dmem_addr_o(lsu_dmem_addr_lo)
    ,.dmem_data_o(lsu_dmem_data_lo)
    ,.dmem_mask_o(lsu_dmem_mask_lo)

    ,.reserve_o(lsu_reserve_lo)

    ,.byte_sel_o(lsu_byte_sel_lo)
  );


  // npc_r ('true nextf pc')
  // this keeps track of what should be the next PC of the instruction that was last in EXE (i.e. latest committed instruction).
  // this is updated when a valid instruction moves out of EXE (or FP_EXE)
  // For non-control instructions, this is pc+4.
  // For control instructions, this is the branch/jump target. 
  // This is used for setting mepc_r, when the interrupt is taken.
  // this is different from pc_n in IF, which could have mispredicted pc.
  logic npc_write_en;
  logic [pc_width_lp-1:0] npc_n, npc_r; 

  bsg_dff_en_bypass #(
    .width_p(pc_width_lp)
  ) npc_dff (
    .clk_i(clk_i)
    ,.en_i(npc_write_en)
    ,.data_i(npc_n)
    ,.data_o(npc_r)
  );


  // synopsys translate_off
  wire [pc_width_lp+2-1:0] npc_00 = {npc_r, 2'b00}; // for debugging
  // synopsys translate_on


  // 0 = forward branch (always predict 'not taken')
  // 1 = backward branch (always predict 'taken')
  // 'branch underpredict' means that branch was predicted to be "not taken", but actually needs to be taken.
  // 'branch overpredict' means that branch was predicted to be "taken", but actually needs to be not taken.
  // In either cases, the frontend should be flushed. 
  wire branch_under_predict = (alu_jump_now & ~exe_int_r.branch_predicted_taken);
  wire branch_over_predict  = (~alu_jump_now & exe_int_r.branch_predicted_taken); 
  wire branch_mispredict = (branch_under_predict | branch_over_predict) & exe_int_r.decode.is_branch_op;
  wire jalr_mispredict = exe_int_r.decode.is_jalr_op & (alu_jalr_addr != exe_int_r.pred_or_jump_addr[2+:pc_width_lp]);

  always_comb begin
    if (exe_int_r.decode.is_jalr_op) begin
      npc_n = alu_jalr_addr;
    end
    else if (exe_int_r.decode.is_mret_op) begin
      npc_n = mepc_r;
    end
    else if (exe_int_r.decode.is_jal_op | (exe_int_r.decode.is_branch_op & alu_jump_now)) begin
      npc_n = exe_int_r.pred_or_jump_addr[2+:pc_width_lp];
    end
    else begin
      npc_n = (exe_int_r.pc_plus4[2+:pc_width_lp] > exe_fp_r.pc_plus4[2+:pc_width_lp]) ? exe_int_r.pc_plus4[2+:pc_width_lp] : exe_fp_r.pc_plus4[2+:pc_width_lp];
    end
  end




  //////////////////////////////
  //                          //
  //      FP EXE STAGE        //
  //                          //
  //////////////////////////////

  bsg_dff_reset_en #(
    .width_p($bits(fp_exe_ctrl_signals_s))
  ) fp_exe_ctrl_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(fp_exe_ctrl_en)
    ,.data_i(fp_exe_ctrl_n)
    ,.data_o(fp_exe_ctrl_r)
  );

  bsg_dff_en #(
    .width_p($bits(fp_exe_data_signals_s))
  ) fp_exe_data_pipeline (
    .clk_i(clk_i)
    ,.en_i(fp_exe_data_en)
    ,.data_i(fp_exe_data_n)
    ,.data_o(fp_exe_data_r)
  );

  // FPU FLOAT
  //
  logic stall_fpu1_li;
  logic stall_fpu2_li;

  logic imul_v_lo;
  logic [data_width_p-1:0] imul_result_lo;
  logic [reg_addr_width_lp-1:0] imul_rd_lo;

  logic fpu_float_v_lo;
  logic [fpu_recoded_data_width_gp-1:0] fpu_float_result_lo;
  fflags_s fpu_float_fflags_lo;
  logic [reg_addr_width_lp-1:0] fpu_float_rd_lo;

  logic fpu1_v_r;
  logic [reg_addr_width_lp-1:0] fpu1_rd_r;

  fpu_float fpu_float0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.stall_fpu1_i(stall_fpu1_li)
    ,.stall_fpu2_i(stall_fpu2_li)

    ,.imul_v_i(exe_int_r.decode.is_imul_op)
    ,.imul_rs1_i(exe_int_r.rs1_val)
    ,.imul_rs2_i(exe_int_r.rs2_val)
    ,.imul_rd_i(exe_int_r.instruction.rd)

    ,.fp_v_i(fp_exe_ctrl_r.fp_decode.is_fpu_float_op)
    ,.fpu_float_op_i(fp_exe_ctrl_r.fp_decode.fpu_float_op)
    ,.fp_rs1_i(fp_exe_data_r.rs1_val)
    ,.fp_rs2_i(fp_exe_data_r.rs2_val)
    ,.fp_rs3_i(fp_exe_data_r.rs3_val)
    ,.fp_rd_i(fp_exe_ctrl_r.rd)
    ,.fp_rm_i(fp_exe_ctrl_r.rm)

    ,.imul_v_o(imul_v_lo)
    ,.imul_result_o(imul_result_lo)
    ,.imul_rd_o(imul_rd_lo)

    ,.fp_v_o(fpu_float_v_lo)
    ,.fp_result_o(fpu_float_result_lo)
    ,.fp_fflags_o(fpu_float_fflags_lo)
    ,.fp_rd_o(fpu_float_rd_lo)
  
    ,.fpu1_v_r_o(fpu1_v_r)
    ,.fpu1_rd_o(fpu1_rd_r)
  );
 
  // FPU INT - computes float op that writes back to INT regfile. 
  logic [data_width_p-1:0] fpu_int_result_lo;
  fflags_s fpu_int_fflags_lo;

  fpu_int fpu_int0(
    .fp_rs1_i(fp_exe_data_r.rs1_val)
    ,.fp_rs2_i(fp_exe_data_r.rs2_val)
    ,.fpu_int_op_i(fp_exe_ctrl_r.fp_decode.fpu_int_op)
    ,.fp_rm_i(fp_exe_ctrl_r.rm)

    ,.result_o(fpu_int_result_lo)
    ,.fflags_o(fpu_int_fflags_lo)
  );

  // FPU div sqrt - this writes back to FP regfile.
  logic fdiv_fsqrt_v_li;
  logic fdiv_fsqrt_ready_and_lo;
  logic fdiv_fsqrt_v_lo;
  logic [fpu_recoded_data_width_gp-1:0] fdiv_fsqrt_result_lo;
  fflags_s fdiv_fsqrt_fflags_lo;
  logic [reg_addr_width_lp-1:0] fdiv_fsqrt_rd_lo;
  logic fdiv_fsqrt_yumi_li;

  fpu_fdiv_fsqrt fpu_fdiv_fsqrt0 (
    .clk_i(clk_i)
    ,.reset_i(reset_i)

    ,.v_i(fdiv_fsqrt_v_li)
    ,.rd_i(fp_exe_ctrl_r.rd)
    ,.rm_i(fp_exe_ctrl_r.rm)
    ,.fp_rs1_i(fp_exe_data_r.rs1_val)
    ,.fp_rs2_i(fp_exe_data_r.rs2_val)
    ,.fsqrt_i(fp_exe_ctrl_r.fp_decode.is_fsqrt_op)
    ,.ready_and_o(fdiv_fsqrt_ready_and_lo)

    ,.v_o(fdiv_fsqrt_v_lo)
    ,.result_o(fdiv_fsqrt_result_lo)
    ,.fflags_o(fdiv_fsqrt_fflags_lo)
    ,.sqrtOpOut_o()
    ,.rd_o(fdiv_fsqrt_rd_lo)
    ,.yumi_i(fdiv_fsqrt_yumi_li)
  );


  

  //////////////////////////////
  //                          //
  //        MEM STAGE         //
  //                          //
  //////////////////////////////

  bsg_dff_reset_en #(
    .width_p($bits(mem_ctrl_signals_s))
  ) mem_ctrl_int_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(mem_ctrl_en)
    ,.data_i(mem_ctrl_int_n)
    ,.data_o(mem_ctrl_int_r)
  );

  bsg_dff_en #(
    .width_p($bits(mem_data_signals_s))
  ) mem_data_int_pipeline (
    .clk_i(clk_i)
    ,.en_i(mem_data_en)
    ,.data_i(mem_data_int_n)
    ,.data_o(mem_data_int_r)
  );

  bsg_dff_reset_en #(
    .width_p($bits(mem_ctrl_signals_s))
  ) mem_ctrl_fp_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(mem_ctrl_en)
    ,.data_i(mem_ctrl_fp_n)
    ,.data_o(mem_ctrl_fp_r)
  );

  bsg_dff_en #(
    .width_p($bits(mem_data_signals_s))
  ) mem_data_fp_pipeline (
    .clk_i(clk_i)
    ,.en_i(mem_data_en)
    ,.data_i(mem_data_fp_n)
    ,.data_o(mem_data_fp_r)
  );

  logic dmem_v_li;
  logic dmem_w_li;
  logic [data_width_p-1:0] dmem_data_li;
  logic [dmem_addr_width_lp-1:0] dmem_addr_li;
  logic [data_mask_width_lp-1:0] dmem_mask_li;
  logic [data_width_p-1:0] dmem_data_lo;

  bsg_mem_1rw_sync_mask_write_byte #(
    .els_p(dmem_size_p)
    ,.data_width_p(data_width_p)
    ,.latch_last_read_p(1)
  ) dmem (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.v_i(dmem_v_li)
    ,.w_i(dmem_w_li)
    ,.addr_i(dmem_addr_li)
    ,.data_i(dmem_data_li)
    ,.write_mask_i(dmem_mask_li)
    ,.data_o(dmem_data_lo)
  );

  assign remote_dmem_data_o = dmem_data_lo;

  // local load buffer
  //
  logic local_load_en;
  logic local_load_en_r;
  logic [data_width_p-1:0] local_load_data_r;

  bsg_dff_reset #(
    .width_p(1)
  ) local_load_en_dff (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.data_i(local_load_en)
    ,.data_o(local_load_en_r)
  );

  bsg_dff_en_bypass #(
    .width_p(data_width_p)
  ) local_load_buffer (
    .clk_i(clk_i)
    ,.en_i(local_load_en_r)
    ,.data_i(dmem_data_lo)
    ,.data_o(local_load_data_r)
  );

  // local load packer
  //
  logic [data_width_p-1:0] local_load_packed_data;

  load_packer local_lp (
    .mem_data_i(local_load_data_r)
    ,.unsigned_load_i(mem_ctrl_int_r.is_load_unsigned)
    ,.byte_load_i(mem_ctrl_int_r.is_byte_op)
    ,.hex_load_i(mem_ctrl_int_r.is_hex_op)
    ,.part_sel_i(mem_ctrl_int_r.byte_sel)
    ,.load_data_o(local_load_packed_data) 
  );

  // load reservation registers
  logic reserved_r;
  logic [dmem_addr_width_lp-1:0] reserved_addr_r;

  logic make_reserve;
  logic break_reserve;

  // synopsys sync_set_reset "reset_i"
  always_ff @ (posedge clk_i) begin
    if (reset_i) begin
      reserved_r <= 1'b0;
      reserved_addr_r <= '0;
    end
    else begin
      if (make_reserve) begin
        reserved_r <= 1'b1;
        reserved_addr_r <= dmem_addr_li;
        // synopsys translate_off
        if (debug_p)
          $display("[INFO][VCORE] making reservation. t=%0t, addr=%x, x=%0d, y=%0d", $time, dmem_addr_li, global_x_i, global_y_i);
        // synopsys translate_on
      end
      else if (break_reserve) begin
        reserved_r <= 1'b0;
        // synopsys translate_off
        if (debug_p)
          $display("[INFO][VCORE] breaking reservation. t=%0t, x=%0d, y=%0d.", $time, global_x_i, global_y_i);
        // synopsys translate_on
      end
    end
  end


  //////////////////////////////
  //                          //
  //        WB STAGE          //
  //                          //
  //////////////////////////////

  bsg_dff_reset #(
    .width_p($bits(wb_ctrl_signals_s))
  ) wb_ctrl_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.data_i(wb_ctrl_n)
    ,.data_o(wb_ctrl_r)
  );

  bsg_dff #(
    .width_p($bits(wb_data_signals_s))
  ) wb_data_pipeline (
    .clk_i(clk_i)
    ,.data_i(wb_data_n)
    ,.data_o(wb_data_r)
  );

  //////////////////////////////
  //                          //
  //    FLW WB STAGE          //
  //                          //
  //////////////////////////////

  bsg_dff_reset_en #(
    .width_p($bits(flw_wb_ctrl_signals_s))
  ) flw_wb_ctrl_pipeline (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.en_i(flw_wb_ctrl_en)
    ,.data_i(flw_wb_ctrl_n)
    ,.data_o(flw_wb_ctrl_r)
  );

  bsg_dff_en #(
    .width_p($bits(flw_wb_data_signals_s))
  ) flw_wb_data_pipeline (
    .clk_i(clk_i)
    ,.en_i(flw_wb_data_en)
    ,.data_i(flw_wb_data_n)
    ,.data_o(flw_wb_data_r)
  );

  logic select_remote_flw;
  logic [data_width_p-1:0] flw_data;
  bsg_mux #(
    .width_p(data_width_p)
    ,.els_p(2)
  ) flw_recFN_mux (
    .data_i({float_remote_load_resp_data_i, flw_wb_data_r.rf_data})
    ,.sel_i(select_remote_flw)
    ,.data_o(flw_data)
  );

  logic [fpu_recoded_data_width_gp-1:0] flw_recoded_data;
  fNToRecFN #(
    .expWidth(fpu_recoded_exp_width_gp)
    ,.sigWidth(fpu_recoded_sig_width_gp)
  ) flw_to_RecFN (
    .in(flw_data)
    ,.out(flw_recoded_data)
  );


  //////////////////////////////
  //                          //
  //      CONTROL LOGIC       //
  //                          //
  //////////////////////////////

  // IF stall signals
  logic stall_icache_store;

  // ID stall signals
  logic stall_depend_long_op, stall_depend_long_op_int, stall_depend_long_op_fp;
  logic stall_depend_local_load, stall_depend_local_load_int, stall_depend_local_load_fp;
  logic stall_depend_imul, stall_depend_imul_fp, stall_depend_imul_int;
  logic stall_bypass, stall_bypass_int, stall_bypass_fp;
  logic stall_lr_aq;
  logic stall_fence;
  logic stall_amo_aq;
  logic stall_amo_rl;
  logic stall_remote_req;
  logic stall_remote_credit;
  logic stall_fdiv_busy;
  logic stall_idiv_busy;
  logic stall_fcsr;
  logic stall_barrier;

  // MEM stall signals
  logic stall_remote_ld_wb;
  logic stall_ifetch_wait;
  
  // FP_WB stall signals
  logic stall_remote_flw_wb;

  wire stall_id_fp = stall_depend_long_op_fp
    | stall_depend_local_load_fp
    | stall_bypass_fp
    | stall_fdiv_busy;

  wire stall_id_int = stall_depend_long_op_int
    | stall_depend_local_load_int
    | stall_bypass_int
    | stall_lr_aq
    | stall_fence
    | stall_amo_aq
    | stall_amo_rl
    | stall_remote_req
    | stall_remote_credit
    | stall_idiv_busy
    | stall_fcsr
    | stall_barrier;

  wire stall_id = (stall_id_int & id_int_r.valid) | (stall_id_fp & id_fp_r.valid);
  
  /* note: these still exist, for performance counter purposes
     stall_depend_long_op
    | stall_depend_local_load
    | stall_depend_imul
    | stall_bypass
    | stall_lr_aq
    | stall_fence
    | stall_amo_aq
    | stall_amo_rl
    | stall_remote_req
    | stall_remote_credit
    | stall_fdiv_busy
    | stall_idiv_busy
    | stall_fcsr
    | stall_barrier;
  */

  wire stall_all = stall_icache_store
    | stall_remote_ld_wb
    | stall_ifetch_wait
    | stall_remote_flw_wb;

  // flush condition
  // 1) branch/jalr mispredict
  // 2) mret in EXE
  // 3) interrupt taken
  wire flush = (branch_mispredict | jalr_mispredict) | (exe_int_r.decode.is_mret_op) | interrupt_ready;
  wire icache_miss_in_pipe = id_int_r.icache_miss | exe_int_r.icache_miss | mem_ctrl_int_r.icache_miss | wb_ctrl_r.icache_miss;

  // ID stage is not stalled and not flushed.
  wire id_issue = ~stall_id & ~stall_all & ~flush;
  // wire id_issue_int = ~stall_id_int & ~stall_all & ~flush;
  // wire id_issue_fp = ~stall_id_fp & ~stall_all & ~flush;

  // Next PC logic
  always_comb begin
    icache_read_pc_plus4_li = 1'b0;
    icache_read_pc_plus8_li = 1'b0;

    if (reset_down) begin
      pc_n = pc_init_val_i;
    end
    else if (wb_ctrl_r.icache_miss) begin
      pc_n = pc_r;
    end
    else if (interrupt_ready) begin
      if (remote_interrupt_ready) begin
        pc_n = `REMOTE_INTERRUPT_JUMP_ADDR;
      end
      else begin
        pc_n = `TRACE_INTERRUPT_JUMP_ADDR;
      end
    end
    else if (exe_int_r.decode.is_mret_op) begin
      pc_n = mepc_r;
    end
    else if (branch_mispredict) begin
      pc_n = alu_jump_now
        ? exe_int_r.pred_or_jump_addr[2+:pc_width_lp]
        : exe_int_r.pc_plus4[2+:pc_width_lp];
    end
    else if (jalr_mispredict) begin
      pc_n = alu_jalr_addr;
    end
    else if (decode_int.is_branch_op & icache_branch_predicted_taken_lo & ~is_dual_issue_lo) begin
      pc_n = pred_or_jump_addr;
    end
    else if (decode_int.is_jal_op | decode_int.is_jalr_op) begin
      pc_n = pred_or_jump_addr;
    end
    else if (is_dual_issue_lo) begin
      icache_read_pc_plus8_li = 1'b1;
      pc_n = pc_plus8;
    end else begin
      icache_read_pc_plus4_li = 1'b1;
      pc_n = pc_plus4;
    end
  end
  
  // debug printing for interrupt and mret
  // synopsys translate_off

  always_ff @ (negedge clk_i) begin
    if (~reset_i & ~stall_all & interrupt_ready) begin
      if (remote_interrupt_ready) begin
        $display("[INFO][VCORE] Remote interrupt taken. t=%0t, x=%0d, y=%0d, mepc=%h",
          $time, global_x_i, global_y_i, {npc_r, 2'b00});
      end
      else begin
        $display("[INFO][VCORE] Trace interrupt taken. t=%0t, x=%0d, y=%0d, mepc=%h",
          $time, global_x_i, global_y_i, {npc_r, 2'b00});
      end
    end

    if (~reset_i & ~stall_all & exe_int_r.decode.is_mret_op) begin
      $display("[INFO][VCORE] mret called. t=%0t, x=%0d, y=%0d, mepc=%h",
        $time, global_x_i, global_y_i, {mepc_r, 2'b00});
    end

/*    if (jalr_mispredict)
      $display("[INFO][VCORE] jalr_mispredict. t=%0t, x=%0d, y=%0d, true=%x pred=%x\n", 
	       $time, global_x_i, global_y_i, 
	       { alu_jalr_addr, 2'b00 },
	       { exe_int_r.pred_or_jump_addr[2+:pc_width_lp], 2'b00 }
	       );
 */
  end
  // synopsys translate_on



  // icache logic
  wire read_icache = (icache_miss_in_pipe & ~flush)
    ? wb_ctrl_r.icache_miss
    : (~icache_miss | flush | reset_down);

  assign icache_v_li = icache_v_i | ifetch_v_i
    | (read_icache & ~reset_i & ~stall_all & ~(stall_id & ~flush));

  assign icache_w_li = icache_v_i | ifetch_v_i;

  assign icache_w_pc = ifetch_v_i
    ? {pc_r[pc_width_lp-1:lg_icache_block_size_in_words_lp], ifetch_count_r}
    : icache_pc_i;

  assign icache_winstr = ifetch_v_i
    ? ifetch_instr_i
    : icache_instr_i;

  assign icache_yumi_o = icache_v_i & ~ifetch_v_i;

  assign icache_flush = flush | icache_miss_in_pipe;
  
  assign stall_icache_store = icache_v_i & icache_yumi_o;


  logic id_int_valid, id_fp_valid;
  logic [pc_width_lp-1:0] id_int_pc_plus4, id_fp_pc_plus4;
  
  // IF -> ID_INT and ID_FP
  always_comb begin
    // common case
    id_int_valid = is_dual_issue_lo ? 1'b1 : (single_issue_is_int_lo ? 1'b1 : 1'b0);
    id_fp_valid = is_dual_issue_lo ? 1'b1 : (single_issue_is_int_lo ? 1'b0 : 1'b1);
    id_int_pc_plus4 = ~is_dual_issue_lo ? pc_plus4 : (int_is_instr0_lo ? pc_plus4 : pc_plus8);
    id_fp_pc_plus4 = ~is_dual_issue_lo ? pc_plus4 : (int_is_instr0_lo ? pc_plus8 : pc_plus4);

    id_int_n = '{
      pc_plus4: {{(data_width_p-pc_width_lp-2){1'b0}}, id_int_pc_plus4, 2'b0},
      pred_or_jump_addr: {{(data_width_p-pc_width_lp-2){1'b0}}, pred_or_jump_addr, 2'b0},
      instruction: instruction_int,
      decode: decode_int,
      fp_decode: fp_decode_int,
      icache_miss: 1'b0,
      valid: id_int_valid,
      branch_predicted_taken:  icache_branch_predicted_taken_lo
    };

    id_fp_n = '{
      pc_plus4: {{(data_width_p-pc_width_lp-2){1'b0}}, id_fp_pc_plus4, 2'b0},
      pred_or_jump_addr: {{(data_width_p-pc_width_lp-2){1'b0}}, pred_or_jump_addr, 2'b0},
      instruction: instruction_fp,
      decode: decode_fp,
      fp_decode: fp_decode_fp,
      icache_miss: 1'b0,
      valid: id_fp_valid,
      branch_predicted_taken: '0 // not used in this pipeline
    };

    if (stall_all) begin
      id_en = 1'b0;
    end
    else begin
      if (reset_down | flush) begin
        id_en = 1'b1;
        id_int_n = '0;
        id_fp_n = '0;
      end    
      else if (stall_id) begin
        id_en = 1'b0;
      end
      // When stall_id is high, icache miss should not be flushing ID.
      else if (icache_miss_in_pipe | icache_flush_r_lo) begin
        id_en = 1'b1;
        id_int_n = '0;
        id_fp_n = '0;
      end
      else if (icache_miss) begin
        id_en = 1'b1;
        id_int_n = '{
          pc_plus4: {{(data_width_p-pc_width_lp-2){1'b0}}, pc_plus4, 2'b0},
          pred_or_jump_addr: '0,
          instruction: '0,
          decode: '0,
          fp_decode: '0,
          icache_miss: 1'b1,
          valid: 1'b0,
          branch_predicted_taken: 1'b0
        };
        id_fp_n = '{
          pc_plus4: {{(data_width_p-pc_width_lp-2){1'b0}}, pc_plus4, 2'b0},
          pred_or_jump_addr: '0,
          instruction: '0,
          decode: '0,
          fp_decode: '0,
          icache_miss: 1'b0, // no need to propagate through both int/fp pipelines
          valid: 1'b0,
          branch_predicted_taken: 1'b0
        };
      end
      else begin
        // common case
        id_en = 1'b1;
      end
    end
  end

  // regfile read
  wire rf_read_en = ~(stall_id | stall_all);
  assign int_rf_read[0] = (id_int_n.decode.read_rs1 | id_fp_n.decode.read_rs1) & rf_read_en;
  assign int_rf_read[1] = (id_int_n.decode.read_rs2 | id_fp_n.decode.read_rs2) & rf_read_en;
  assign int_rf_rs1 = (id_int_valid & id_int_n.decode.read_rs1) ? instruction_int.rs1 : instruction_fp.rs1;
  assign int_rf_rs2 = (id_int_valid & id_int_n.decode.read_rs2) ? instruction_int.rs2 : instruction_fp.rs2;

  assign float_rf_read[0] = (id_int_n.decode.read_frs1 | id_fp_n.decode.read_frs1) & rf_read_en;
  assign float_rf_read[1] = (id_int_n.decode.read_frs2 | id_fp_n.decode.read_frs2) & rf_read_en;
  assign float_rf_read[2] = (id_int_n.decode.read_frs3 | id_fp_n.decode.read_frs3) & rf_read_en;
  assign float_rf_frs1 = (id_fp_valid & id_fp_n.decode.read_frs1) ? instruction_fp.rs1 : instruction_int.rs1;
  assign float_rf_frs2 = (id_fp_valid & id_fp_n.decode.read_frs2) ? instruction_fp.rs2 : instruction_int.rs2;

  // helpful control signals; (used to be id_rs1, id_rs1, etc., now split)
  wire [reg_addr_width_lp-1:0] id_int_rs1 = id_int_r.instruction.rs1;
  wire [reg_addr_width_lp-1:0] id_int_rs2 = id_int_r.instruction.rs2;
  wire [reg_addr_width_lp-1:0] id_int_rs3 = id_int_r.instruction[31:27];
  wire [reg_addr_width_lp-1:0] id_fp_rs1 = id_fp_r.instruction.rs1;
  wire [reg_addr_width_lp-1:0] id_fp_rs2 = id_fp_r.instruction.rs2;
  wire [reg_addr_width_lp-1:0] id_fp_rs3 = id_fp_r.instruction[31:27];
  wire [reg_addr_width_lp-1:0] id_int_rd = id_int_r.instruction.rd;
  wire [reg_addr_width_lp-1:0] id_fp_rd = id_fp_r.instruction.rd;

  wire remote_req_in_exe = lsu_remote_req_v_lo;
  wire local_load_in_exe = lsu_dmem_v_lo & ~lsu_dmem_w_lo;
  wire id_int_rs1_non_zero = id_int_rs1 != '0;
  wire id_int_rs2_non_zero = id_int_rs2 != '0;
  wire id_int_rd_non_zero = id_int_rd != '0;
  wire id_fp_rs1_non_zero = id_fp_rs1 != '0;
  wire id_fp_rs2_non_zero = id_fp_rs2 != '0;
  wire id_fp_rd_non_zero = id_fp_rd != '0;
  // wire id_rs1_non_zero = id_rs1 != '0;
  // wire id_rs2_non_zero = id_rs2 != '0;
  // wire id_rd_non_zero = id_rd != '0;
  wire int_remote_load_in_exe = remote_req_in_exe & exe_int_r.decode.is_load_op & exe_int_r.decode.write_rd;
  wire float_remote_load_in_exe = remote_req_in_exe & exe_int_r.decode.is_load_op & exe_int_r.decode.write_frd;
  wire fdiv_fsqrt_in_fp_exe = fp_exe_ctrl_r.fp_decode.is_fdiv_op | fp_exe_ctrl_r.fp_decode.is_fsqrt_op;
  wire remote_credit_pending = (out_credits_used_i != '0);

  // int rs dependencies
  wire id_int_rs1_equal_exe_int_rd = (id_int_rs1 == exe_int_r.instruction.rd);
  wire id_int_rs2_equal_exe_int_rd = (id_int_rs2 == exe_int_r.instruction.rd);
  wire id_int_rs3_equal_exe_int_rd = (id_int_rs3 == exe_int_r.instruction.rd);

  wire id_int_rs1_equal_fp_exe_ctrl_rd = (id_int_rs1 == fp_exe_ctrl_r.rd);
  wire id_int_rs2_equal_fp_exe_ctrl_rd = (id_int_rs2 == fp_exe_ctrl_r.rd);
  wire id_int_rs3_equal_fp_exe_ctrl_rd = (id_int_rs3 == fp_exe_ctrl_r.rd);

  wire id_int_rs1_equal_mem_int_rd = (id_int_rs1 == mem_ctrl_int_r.rd_addr);
  wire id_int_rs2_equal_mem_int_rd = (id_int_rs2 == mem_ctrl_int_r.rd_addr);
  wire id_int_rs3_equal_mem_int_rd = (id_int_rs3 == mem_ctrl_int_r.rd_addr);
  wire id_int_rs1_equal_mem_fp_rd = (id_int_rs1 == mem_ctrl_fp_r.rd_addr);
  wire id_int_rs2_equal_mem_fp_rd = (id_int_rs2 == mem_ctrl_fp_r.rd_addr);
  wire id_int_rs3_equal_mem_fp_rd = (id_int_rs3 == mem_ctrl_fp_r.rd_addr);

  wire id_int_rs1_equal_wb_rd = (id_int_rs1 == wb_ctrl_r.rd_addr);
  wire id_int_rs2_equal_wb_rd = (id_int_rs2 == wb_ctrl_r.rd_addr);
  
  // fp rs dependencies
  wire id_fp_rs1_equal_exe_int_rd = (id_fp_rs1 == exe_int_r.instruction.rd);
  wire id_fp_rs2_equal_exe_int_rd = (id_fp_rs2 == exe_int_r.instruction.rd);
  wire id_fp_rs3_equal_exe_int_rd = (id_fp_rs3 == exe_int_r.instruction.rd);

  wire id_fp_rs1_equal_fp_exe_ctrl_rd = (id_fp_rs1 == fp_exe_ctrl_r.rd);
  wire id_fp_rs2_equal_fp_exe_ctrl_rd = (id_fp_rs2 == fp_exe_ctrl_r.rd);
  wire id_fp_rs3_equal_fp_exe_ctrl_rd = (id_fp_rs3 == fp_exe_ctrl_r.rd);

  wire id_fp_rs1_equal_mem_int_rd = (id_fp_rs1 == mem_ctrl_int_r.rd_addr);
  wire id_fp_rs2_equal_mem_int_rd = (id_fp_rs2 == mem_ctrl_int_r.rd_addr);
  wire id_fp_rs3_equal_mem_int_rd = (id_fp_rs3 == mem_ctrl_int_r.rd_addr);
  wire id_fp_rs1_equal_mem_fp_rd = (id_fp_rs1 == mem_ctrl_fp_r.rd_addr);
  wire id_fp_rs2_equal_mem_fp_rd = (id_fp_rs2 == mem_ctrl_fp_r.rd_addr);
  wire id_fp_rs3_equal_mem_fp_rd = (id_fp_rs3 == mem_ctrl_fp_r.rd_addr);
  wire id_fp_rs1_equal_wb_rd = (id_fp_rs1 == wb_ctrl_r.rd_addr);
  wire id_fp_rs2_equal_wb_rd = (id_fp_rs2 == wb_ctrl_r.rd_addr);

  // wire id_rs1_equal_exe_rd = (id_rs1 == exe_r.instruction.rd);
  // wire id_rs2_equal_exe_rd = (id_rs2 == exe_r.instruction.rd);
  // wire id_rs3_equal_exe_rd = (id_rs3 == exe_r.instruction.rd);
  // wire id_rs1_equal_fp_exe_ctrl_rd = (id_rs1 == fp_exe_ctrl_r.rd);
  // wire id_rs2_equal_fp_exe_ctrl_rd = (id_rs2 == fp_exe_ctrl_r.rd);
  // wire id_rs3_equal_fp_exe_ctrl_rd = (id_rs3 == fp_exe_ctrl_r.rd);
  // wire id_rs1_equal_mem_rd = (id_rs1 == mem_ctrl_r.rd_addr);
  // wire id_rs2_equal_mem_rd = (id_rs2 == mem_ctrl_r.rd_addr);
  // wire id_rs3_equal_mem_rd = (id_rs3 == mem_ctrl_r.rd_addr);
  // wire id_rs1_equal_wb_rd = (id_rs1 == wb_ctrl_r.rd_addr);
  // wire id_rs2_equal_wb_rd = (id_rs2 == wb_ctrl_r.rd_addr);

  // stall_depend_long_op (idiv, fdiv, remote_load, atomic)
  wire frs2_int_sb_clear_now = id_int_r.decode.read_frs2 & (((id_int_rs2 == float_sb_clear_mem_id) & float_sb_clear_mem) | ((id_int_rs2 == float_sb_clear_fdiv_id) & float_sb_clear_fdiv));
  wire rs1_fp_sb_clear_now = id_fp_r.decode.read_rs1 & (id_fp_rs1 == int_sb_clear_id) & int_sb_clear & id_fp_rs1_non_zero; 
  // TODO will need to integrate 2x float fb clear signals when double fp write back is integrated
  // wire rs1_sb_clear_now = id_r.decode.read_rs1 & (id_rs1 == int_sb_clear_id) & int_sb_clear & id_rs1_non_zero; 
  // wire frs2_sb_clear_now = id_r.decode.read_frs2 & (id_rs2 == float_sb_clear_id) & float_sb_clear;

  // TODO mux scoreboard inputs and outputs based on instruction decode logic! 
  assign stall_depend_long_op_int = (int_dependency_int | float_dependency_int | frs2_int_sb_clear_now); 
  assign stall_depend_long_op_fp =  (int_dependency_fp | float_dependency_fp | rs1_fp_sb_clear_now);
  assign stall_depend_long_op = stall_depend_long_op_int | stall_depend_long_op_fp; // for performance counters

  // assign stall_depend_long_op = (int_dependency | float_dependency)
  //   | (id_r.decode.is_fp_op
  //       ? rs1_sb_clear_now
  //       : frs2_sb_clear_now);

  // stall_depend_local_load (lw, flw, lr, lr.aq)
  assign stall_depend_local_load_fp = local_load_in_exe &
    ((id_fp_r.decode.read_rs1  & id_fp_rs1_equal_exe_int_rd & exe_int_r.decode.write_rd & id_fp_rs1_non_zero)
    |(id_fp_r.decode.read_frs1 & id_fp_rs1_equal_exe_int_rd & exe_int_r.decode.write_frd)
    |(id_fp_r.decode.read_frs2 & id_fp_rs2_equal_exe_int_rd & exe_int_r.decode.write_frd)
    |(id_fp_r.decode.read_frs3 & id_fp_rs3_equal_exe_int_rd & exe_int_r.decode.write_frd)); 
    // FP can read from rs1 and frs1/2/3, only INT can perform local loads

  assign stall_depend_local_load_int = local_load_in_exe &
    ((id_int_r.decode.read_rs1  & id_int_rs1_equal_exe_int_rd & exe_int_r.decode.write_rd & id_int_rs1_non_zero)
    |(id_int_r.decode.read_rs2  & id_int_rs2_equal_exe_int_rd & exe_int_r.decode.write_rd & id_int_rs2_non_zero)
    |(id_int_r.decode.read_frs2 & id_int_rs2_equal_exe_int_rd & exe_int_r.decode.write_frd));
  // INT pipeline can read from rs1/2 and frs2, only INT can perform local loads

  assign stall_depend_local_load = stall_depend_local_load_fp | stall_depend_local_load_int; // for performance counters

  // // stall_depend_local_load (lw, flw, lr, lr.aq)
  // assign stall_depend_local_load = local_load_in_exe &
  //   ((id_r.decode.read_rs1  & id_rs1_equal_exe_rd & exe_r.decode.write_rd & id_rs1_non_zero)
  //   |(id_r.decode.read_rs2  & id_rs2_equal_exe_rd & exe_r.decode.write_rd & id_rs2_non_zero)
  //   |(id_r.decode.read_frs1 & id_rs1_equal_exe_rd & exe_r.decode.write_frd)
  //   |(id_r.decode.read_frs2 & id_rs2_equal_exe_rd & exe_r.decode.write_frd)
  //   |(id_r.decode.read_frs3 & id_rs3_equal_exe_rd & exe_r.decode.write_frd));


  // stall_depend_imul
  assign stall_depend_imul_int = exe_int_r.decode.is_imul_op &
    ((id_int_r.decode.read_rs1 & id_int_rs1_equal_exe_int_rd & id_int_rs1_non_zero)
    |(id_int_r.decode.read_rs2 & id_int_rs2_equal_exe_int_rd & id_int_rs2_non_zero)); // INT can read from rs1/2

  assign stall_depend_imul_fp = exe_int_r.decode.is_imul_op &
    (id_fp_r.decode.read_rs1 & id_fp_rs1_equal_exe_int_rd & id_fp_rs1_non_zero); // FP can read from rs1

  assign stall_depend_imul = stall_depend_imul_int | stall_depend_imul_fp; // for performance counters

  // stall_bypass
  // FP side - uses frs1/2/3 and can use rs1
  wire stall_bypass_fp_frs = 
     (id_fp_r.decode.read_frs1 & id_fp_rs1_equal_fp_exe_ctrl_rd & fp_exe_ctrl_r.fp_decode.is_fpu_float_op)
    |(id_fp_r.decode.read_frs2 & id_fp_rs2_equal_fp_exe_ctrl_rd & fp_exe_ctrl_r.fp_decode.is_fpu_float_op)
    |(id_fp_r.decode.read_frs3 & id_fp_rs3_equal_fp_exe_ctrl_rd & fp_exe_ctrl_r.fp_decode.is_fpu_float_op)
    |(id_fp_r.decode.read_frs1 & (id_fp_rs1 == fpu1_rd_r) & fpu1_v_r)
    |(id_fp_r.decode.read_frs2 & (id_fp_rs2 == fpu1_rd_r) & fpu1_v_r)
    |(id_fp_r.decode.read_frs3 & (id_fp_rs3 == fpu1_rd_r) & fpu1_v_r)
    |(id_fp_r.decode.read_frs1 & id_fp_rs1_equal_mem_int_rd & mem_ctrl_int_r.write_frd)
    |(id_fp_r.decode.read_frs2 & id_fp_rs2_equal_mem_int_rd & mem_ctrl_int_r.write_frd)
    |(id_fp_r.decode.read_frs3 & id_fp_rs3_equal_mem_int_rd & mem_ctrl_int_r.write_frd);
    // relates to the fpu_float unit and mem stages

  wire stall_bypass_fp_rs1 = (id_fp_r.decode.read_rs1 & id_fp_rs1_non_zero) &
    ((id_fp_rs1_equal_fp_exe_ctrl_rd & fp_exe_ctrl_r.fp_decode.is_fpu_int_op)
    |((id_fp_rs1 == imul_rd_lo) & imul_v_lo)
    |(id_fp_rs1_equal_exe_int_rd & exe_int_r.decode.write_rd)
    |(id_fp_rs1_equal_mem_int_rd & mem_ctrl_int_r.write_rd)
    |(id_fp_rs1_equal_mem_fp_rd & mem_ctrl_fp_r.write_rd)
    |(id_fp_rs1_equal_wb_rd & wb_ctrl_r.write_rd));
    // FP and INT sides can both write back to the int regfile, so need to track separate mem_ctrl and exe values

  // INT side - can read from frs2 in the FSW case, no forwarding paths
  wire stall_bypass_int_frs2 = id_int_r.decode.read_frs2 &
    ((id_int_rs2_equal_fp_exe_ctrl_rd & fp_exe_ctrl_r.fp_decode.is_fpu_float_op)
    |((id_int_rs2 == fpu1_rd_r) & fpu1_v_r)
    |((id_int_rs2 == fpu_float_rd_lo) & fpu_float_v_lo)
    |(id_int_rs2_equal_mem_int_rd & mem_ctrl_int_r.write_frd)
    |((id_int_rs2 == flw_wb_ctrl_r.rd_addr) & flw_wb_ctrl_r.valid));
    // handles forwarding bypass from the fpu_float unit, memory, and flw
    // is_fpu_float_op indicates that the fpu_float is used, which should not be set for any INT instructions (no need to OR with INT pipeline)
    // fpu1_rd_r -> output of fpu_float (val output early for hazard detection)
    // fpu_float_rd_lo -> the actual finished fpu_float output, ready for the next stage
    
  assign stall_bypass_fp = stall_bypass_fp_frs | stall_bypass_fp_rs1;
  assign stall_bypass_int = stall_bypass_int_frs2;
  assign stall_bypass = stall_bypass_int | stall_bypass_fp; // for performance counters

  // stall_lr_aq
  assign stall_lr_aq = id_int_r.decode.is_lr_aq_op & (reserved_r | lsu_reserve_lo) & ~break_reserve;

  // stall_fence
  assign stall_fence = id_int_r.decode.is_fence_op & (remote_credit_pending | remote_req_in_exe);
  
  // stall_amo_aq
  assign stall_amo_aq = aq_r & ~aq_clear &
    (id_int_r.decode.is_load_op
    |id_int_r.decode.is_store_op
    |id_int_r.decode.is_amo_op
    |id_int_r.decode.is_lr_aq_op
    |id_int_r.decode.is_lr_op);

  // stall_amo_rl
  // If there is a remote request in EXE, there is a technically remote request pending, even if the credit counter has not yet been decremented.
  assign stall_amo_rl = id_int_r.decode.is_amo_op & id_int_r.decode.is_amo_rl
    & (remote_credit_pending | remote_req_in_exe);

  // stall_remote_req - credit counter system for remote memory requests
  logic [lg_fwd_fifo_els_lp-1:0] remote_req_counter_r;
  wire local_mem_op_restore = (lsu_dmem_v_lo & ~exe_int_r.decode.is_lr_op & ~exe_int_r.decode.is_lr_aq_op) & ~stall_all;
  wire id_remote_req_op = (id_int_r.decode.is_load_op | id_int_r.decode.is_store_op | id_int_r.decode.is_amo_op | id_int_r.icache_miss);
  wire memory_op_issued = id_remote_req_op & id_issue;
  wire [lg_fwd_fifo_els_lp-1:0] remote_req_available =
    remote_req_counter_r +
    remote_req_credit_i +
    local_mem_op_restore +
    invalid_eva_access_i;

  always_ff @ (posedge clk_i) begin
    if (reset_i)
      remote_req_counter_r <= (lg_fwd_fifo_els_lp)'(fwd_fifo_els_p);
    else
      remote_req_counter_r <= remote_req_available - memory_op_issued;
  end 

  assign stall_remote_req = id_remote_req_op & (remote_req_available == '0);
  
  // stall_remote_credit
  logic credit_cout;
  logic [credit_counter_width_p-1:0] credit_sum;
  assign {credit_cout, credit_sum} = out_credits_used_i + (remote_req_in_exe
                                                          ? (exe_int_r.icache_miss ? icache_block_size_in_words_p : 1)
                                                          : '0);
  assign stall_remote_credit = id_remote_req_op & ((credit_sum >= credit_limit_r) | credit_cout);

  // stall_fdiv_busy
  assign stall_fdiv_busy = (id_fp_r.fp_decode.is_fdiv_op | id_fp_r.fp_decode.is_fsqrt_op) & (fdiv_fsqrt_ready_and_lo
    ? (fp_exe_ctrl_r.fp_decode.is_fdiv_op | fp_exe_ctrl_r.fp_decode.is_fsqrt_op)
    : 1'b1);

  // stall_idiv_busy
  assign stall_idiv_busy = id_int_r.decode.is_idiv_op & (idiv_ready_and_lo
    ? exe_int_r.decode.is_idiv_op
    : 1'b1);

  // stall_fcsr
  assign stall_fcsr = (id_int_r.decode.is_csr_op)
    & ((id_int_r.instruction[31:20] == `RV32_CSR_FFLAGS_ADDR)
      |(id_int_r.instruction[31:20] == `RV32_CSR_FCSR_ADDR))
    & (fp_exe_ctrl_r.fp_decode.is_fpu_float_op
      |fp_exe_ctrl_r.fp_decode.is_fpu_int_op
      |fp_exe_ctrl_r.fp_decode.is_fdiv_op
      |fp_exe_ctrl_r.fp_decode.is_fsqrt_op
      |(~fdiv_fsqrt_ready_and_lo)
      |fdiv_fsqrt_v_lo
      |fpu1_v_r
      |fpu_float_v_lo);
  // CSR ops are INT issued instructions, but we stall them if they relate to FP status registers and FP instructions are still in flight


  // FP_EXE forwarding mux control logic
  //
  assign select_rs1_to_fp_exe = id_fp_r.decode.read_rs1;
  assign frs1_forward_v[0] = id_fp_r.decode.read_frs1 & (id_fp_rs1 == float_rf_waddr[0]) & float_rf_wen[0];
  assign frs2_forward_v[0] = id_fp_r.decode.read_frs2 & (id_fp_rs2 == float_rf_waddr[0]) & float_rf_wen[0];
  assign frs3_forward_v[0] = id_fp_r.decode.read_frs3 & (id_fp_rs3 == float_rf_waddr[0]) & float_rf_wen[0];
  assign frs1_forward_v[1] = id_fp_r.decode.read_frs1 & (id_fp_rs1 == float_rf_waddr[1]) & float_rf_wen[1];
  assign frs2_forward_v[1] = id_fp_r.decode.read_frs2 & (id_fp_rs2 == float_rf_waddr[1]) & float_rf_wen[1];
  assign frs3_forward_v[1] = id_fp_r.decode.read_frs3 & (id_fp_rs3 == float_rf_waddr[1]) & float_rf_wen[1];
  // FP regfile now has dual-port writes

  // Added additional forwarding path from FP mem stage
  // EXE forwarding mux control logic
  // [0] = exe
  // [1] = mem
  // [2] = wb
  logic [2:0] has_forward_data_rs1;
  logic [2:0] has_forward_data_rs2;

  assign has_forward_data_rs1[0] =
    ((fp_exe_ctrl_r.fp_decode.is_fpu_int_op & id_int_rs1_equal_fp_exe_ctrl_rd)
    |(exe_int_r.decode.write_rd & id_int_rs1_equal_exe_int_rd))
    & id_int_rs1_non_zero; // from INT EXE stage or fpu_int unit (FPU_EXE stage)
  assign has_forward_data_rs1[1] =
    ((mem_ctrl_int_r.write_rd & id_int_rs1_equal_mem_int_rd)
    |(imul_v_lo & (imul_rd_lo == id_int_rs1))
    |(mem_ctrl_fp_r.write_rd & id_int_rs1_equal_mem_fp_rd))
    & id_int_rs1_non_zero; // from mem stage or imul, or from fp-side mem_ctrl stage (fpu_int values passed are to this register)
  assign has_forward_data_rs1[2] =
    wb_ctrl_r.write_rd & id_int_rs1_equal_wb_rd
    & id_int_rs1_non_zero; // from wb stage

  bsg_priority_encode #(
    .width_p(3)
    ,.lo_to_hi_p(1)
  ) rs1_forward_pe0 (
    .i(has_forward_data_rs1)
    ,.addr_o(rs1_forward_sel)
    ,.v_o(rs1_forward_v)
  );

  assign has_forward_data_rs2[0] =
    ((fp_exe_ctrl_r.fp_decode.is_fpu_int_op & id_int_rs2_equal_fp_exe_ctrl_rd)
    |(exe_int_r.decode.write_rd & id_int_rs2_equal_exe_int_rd))
    & id_int_rs2_non_zero; // from INT EXE stage or fpu_int unit (FPU_EXE stage)
  assign has_forward_data_rs2[1] =
    ((mem_ctrl_int_r.write_rd & id_int_rs2_equal_mem_int_rd)
    |(imul_v_lo & (imul_rd_lo == id_int_rs2))
    |(mem_ctrl_fp_r.write_rd & id_int_rs2_equal_mem_fp_rd))
    & id_int_rs2_non_zero; // from mem stage or imul, or from fp-side mem_ctrl stage (fpu_int values passed are to this register)
  assign has_forward_data_rs2[2] =
    wb_ctrl_r.write_rd & id_int_rs2_equal_wb_rd
    & id_int_rs2_non_zero; // from wb stage

  bsg_priority_encode #(
    .width_p(3)
    ,.lo_to_hi_p(1)
  ) rs2_forward_pe0 (
    .i(has_forward_data_rs2)
    ,.addr_o(rs2_forward_sel)
    ,.v_o(rs2_forward_v)
  );

  // AMO aq control
  assign aq_set = (id_int_r.decode.is_amo_op & id_int_r.decode.is_amo_aq) & id_issue;
  assign aq_clear = int_rf_wen & (int_rf_waddr == aq_rd_r);


  // FCSR control
  assign fcsr_v_li = (id_int_r.decode.is_csr_op) & id_issue; 
  assign fcsr_funct3_li = id_int_r.instruction.funct3;
  assign fcsr_rs1_li = id_int_r.instruction.rs1;
  assign fcsr_data_li = rs1_val_to_exe[7:0];
  assign fcsr_addr_li = id_int_r.instruction[31:20];


  // interrupt / CSR control
  assign mcsr_we_li = (id_int_r.decode.is_csr_op) & id_issue;
  assign mcsr_data_li = rs1_val_to_exe;
  assign mcsr_instr_executed_li = id_int_r.valid & id_issue & mstatus_r.mie; // trace interrupt pending can be set outside interrupt.
  assign mcsr_interrupt_entered_li = interrupt_ready & ~stall_all;
  assign mcsr_mret_called_li = exe_int_r.decode.is_mret_op & ~stall_all;
  assign mcsr_npc_r_li = npc_r;
  
  // barrier control
  assign mcsr_barsend_li = id_int_r.decode.is_barsend_op & id_issue;
  assign stall_barrier = id_int_r.decode.is_barrecv_op & (barrier_data_i != barrier_data_o);

  // ID_INT -> EXE_INT, ID_FP -> EXE_FP
  // update npc_r, when the pipeline is not stalled, and there is a valid instruction in EXE/FP_EXE;
  always_comb begin
    // common case - notes: nops propagated here via the valid bits
    exe_int_n = '{
      pc_plus4: id_int_r.pc_plus4,
      valid: id_int_r.valid,
      pred_or_jump_addr: id_int_r.pred_or_jump_addr,
      instruction: id_int_r.instruction,
      decode: id_int_r.decode,
      rs1_val: rs1_val_to_exe,
      // rs2_val carries csr load values
      // if csr addr matches any of fcsr addr, then fcsr_data_v_lo will be asserted.
      rs2_val: (id_int_r.decode.is_csr_op
                    ? (fcsr_data_v_lo
                      ? (data_width_p)'(fcsr_data_lo)
                      : mcsr_data_lo)
                    : rs2_val_to_exe),
      mem_addr_op2: mem_addr_op2,
      icache_miss: id_int_r.icache_miss,
      branch_predicted_taken: id_int_r.branch_predicted_taken
    };

    // for fp_op, we still want to keep track of npc_r.
    // so we set the valid and pc_plus4.
    exe_fp_n = '{
      pc_plus4: id_fp_r.pc_plus4,
      valid: id_fp_r.valid,
      pred_or_jump_addr: '0,
      instruction: '0,
      decode: '0,
      rs1_val: '0,
      rs2_val: '0,
      mem_addr_op2: '0,
      icache_miss: 1'b0,
      branch_predicted_taken: 1'b0
    };

    if (stall_all) begin
      exe_en = 1'b0;
      npc_write_en = 1'b0;
    end
    else begin
      npc_write_en = ((exe_int_r.valid | exe_fp_r.valid) & mstatus_r.mie) | exe_int_r.decode.is_mret_op;
      if (flush | stall_id) begin
        exe_en = 1'b1;
        exe_fp_n = '0;
        exe_int_n = '0;
      end
      else begin
        exe_en = 1'b1;
      end
    end
  end

  // idiv input control
  assign idiv_v_li = exe_int_r.decode.is_idiv_op & ~stall_all;

  // int scoreboard set logic
  assign int_sb_score = ~stall_all & (exe_int_r.decode.is_idiv_op | exe_int_r.decode.is_amo_op | int_remote_load_in_exe);
  assign int_sb_score_id = exe_int_r.instruction.rd;  

  // exe_result - used in data forwarding
  assign exe_result = fp_exe_ctrl_r.fp_decode.is_fpu_int_op
    ? fpu_int_result_lo
    : alu_or_csr_result;

  // remote request control
  assign remote_req_v_o = lsu_remote_req_v_lo & ~stall_all;

  // ID_FP -> FP_EXE
  frm_e fpu_rm;
  assign fpu_rm = frm_e'((id_fp_r.instruction.funct3 == eDYN)
    ? frm_r
    : id_fp_r.instruction.funct3);

  always_comb begin
    fp_exe_ctrl_n = '{
      rd: id_fp_r.instruction.rd,
      fp_decode: id_fp_r.fp_decode,
      rm: fpu_rm
    };
    fp_exe_data_n = '{
      rs1_val: frs1_to_fp_exe,
      rs2_val: frs2_to_fp_exe,
      rs3_val: frs3_to_fp_exe
    };

    if (stall_all) begin
      fp_exe_ctrl_en = 1'b0;
      fp_exe_data_en = 1'b0;
    end
    else begin
      if (flush | stall_id | ~id_fp_r.valid) begin
        // put nop in fp_exe.
        // we hold the data inputs steady in the case of a stall,
        // or if there is not a floating point operation
        // to avoid unnecessarily toggling of the FP unit
        fp_exe_ctrl_en = 1'b1;
        fp_exe_ctrl_n.fp_decode.is_fpu_float_op = 1'b0;
        fp_exe_ctrl_n.fp_decode.is_fpu_int_op   = 1'b0;
        fp_exe_ctrl_n.fp_decode.is_fdiv_op  = 1'b0;
        fp_exe_ctrl_n.fp_decode.is_fsqrt_op = 1'b0;
        fp_exe_data_en = 1'b0;
      end
      else begin
        fp_exe_ctrl_en = 1'b1;
        fp_exe_data_en = 1'b1;
      end
    end
  end  

  // fdiv control 
  assign fdiv_fsqrt_v_li = fdiv_fsqrt_in_fp_exe & ~stall_all;

  // FP scoreboard set logic
  // assign float_sb_score = ~stall_all & (fdiv_fsqrt_in_fp_exe | float_remote_load_in_exe);
  // assign float_sb_score_id = fdiv_fsqrt_in_fp_exe
  //   ? fp_exe_ctrl_r.rd
  //   : exe_int_r.instruction.rd;
  assign float_sb_score_fdiv = ~stall_all & fdiv_fsqrt_in_fp_exe;
  assign float_sb_score_mem = ~stall_all & float_remote_load_in_exe;
  assign float_sb_score_id_fdiv = fp_exe_ctrl_r.rd;
  assign float_sb_score_id_mem = exe_int_r.instruction.rd;


  // EXE_INT -> MEM_INT, FP_EXE -> MEM
  always_comb begin
    // common case
    mem_ctrl_int_n = '{
      rd_addr: exe_int_r.instruction.rd,
      write_rd: exe_int_r.decode.write_rd,
      write_frd: exe_int_r.decode.write_frd,
      is_byte_op: exe_int_r.decode.is_byte_op,
      is_hex_op: exe_int_r.decode.is_hex_op,
      is_load_unsigned: exe_int_r.decode.is_load_unsigned,
      local_load: local_load_in_exe,
      byte_sel: lsu_byte_sel_lo,
      icache_miss: exe_int_r.icache_miss,
      valid: exe_int_r.valid
    };
    mem_data_int_n = '{
      exe_result: alu_or_csr_result
    };

    mem_ctrl_fp_n = '{
      rd_addr: fp_exe_ctrl_r.rd,
      write_rd: fp_exe_ctrl_r.fp_decode.is_fpu_int_op,
      write_frd: 1'b0,
      is_byte_op: 1'b0,
      is_hex_op: 1'b0,
      is_load_unsigned: 1'b0,
      local_load: 1'b0,
      byte_sel: '0,
      icache_miss: 1'b0,
      valid: exe_fp_r.valid
    };
    mem_data_fp_n = '{
      exe_result: fpu_int_result_lo
    };
    // ^^ this register is only used for integer writeback
    // floating point results from the fpu_unit do not flow through a mem stage
    // (results are written back immediately)

    fcsr_fflags_v_li[0] = fp_exe_ctrl_r.fp_decode.is_fpu_int_op;
    fcsr_fflags_li[0] = fpu_int_fflags_lo;

    if (stall_all) begin
      mem_ctrl_en = 1'b0;
      mem_data_en = 1'b0;
    end
    else if (exe_int_r.decode.is_idiv_op | (remote_req_in_exe & ~exe_int_r.icache_miss)) begin
      mem_ctrl_en = 1'b1;
      mem_data_en = 1'b1;
      mem_ctrl_int_n = '0;
      mem_data_int_n = '0;
      mem_ctrl_fp_n = '0;
      mem_data_fp_n = '0;
    end
    else begin
      mem_ctrl_en = 1'b1;
      mem_data_en = 1'b1;
    end
  end  

 
  // DMEM ctrl logic
  always_comb begin
    if (stall_all) begin
      dmem_v_li = remote_dmem_v_i;
      dmem_w_li = remote_dmem_w_i;
      dmem_addr_li = remote_dmem_addr_i;
      dmem_data_li = remote_dmem_data_i;
      dmem_mask_li = remote_dmem_mask_i;
      remote_dmem_yumi_o = remote_dmem_v_i;
      local_load_en = 1'b0;
    end
    else begin
      if (lsu_dmem_v_lo) begin
        dmem_v_li = 1'b1;
        dmem_w_li = lsu_dmem_w_lo;
        dmem_addr_li = lsu_dmem_addr_lo;
        dmem_data_li = lsu_dmem_data_lo;
        dmem_mask_li = lsu_dmem_mask_lo;
        remote_dmem_yumi_o = 1'b0;
        local_load_en = ~lsu_dmem_w_lo;
      end
      else begin
        dmem_v_li = remote_dmem_v_i;
        dmem_w_li = remote_dmem_w_i;
        dmem_addr_li = remote_dmem_addr_i;
        dmem_data_li = remote_dmem_data_i;
        dmem_mask_li = remote_dmem_mask_i;
        remote_dmem_yumi_o = remote_dmem_v_i;
        local_load_en = 1'b0;
      end
    end
  end

  // reservation logic
  // lr creates a reservation on DMEM address.
  // Any store to this address breaks the reservation.
  // When the reservation is valid, lr.aq stalls until the reservation is broken. 
  assign make_reserve = lsu_reserve_lo & ~stall_all;
  assign break_reserve = reserved_r & (reserved_addr_r == dmem_addr_li) & dmem_v_li & dmem_w_li;

  // stall_ifetch_wait

  assign stall_ifetch_wait = mem_ctrl_int_r.icache_miss &
    ~((ifetch_count_r == lg_icache_block_size_in_words_lp'(icache_block_size_in_words_p-1)) & ifetch_v_i);

  // mem_result
  assign mem_result = imul_v_lo
    ? imul_result_lo
    : (mem_ctrl_int_r.local_load
      ? local_load_packed_data
      : (mem_ctrl_int_r.write_rd 
        ? mem_data_int_r.exe_result
        : mem_data_fp_r.exe_result));
  // note: only one of these conditions will be true at one time

  wire mem_result_valid = imul_v_lo | mem_ctrl_int_r.write_rd | mem_ctrl_fp_r.write_rd | mem_ctrl_int_r.write_frd;
  // no need to check the FP pipeline's write_frd bit, since our FP regfile has two write ports (one for mem ops, one for FP ops)
  // wire mem_result_valid = imul_v_lo | mem_ctrl_r.write_rd | mem_ctrl_r.write_frd;
 
 
  // MEM_FP and MEM_INT -> WB
  always_comb begin
    wb_ctrl_n.write_rd = 1'b0;
    wb_ctrl_n.rd_addr = '0;
    wb_data_n.rf_data = '0;
    wb_ctrl_n.icache_miss = 1'b0;
    wb_ctrl_n.clear_sb = 1'b0;
    int_remote_load_resp_yumi_o = 1'b0;
    idiv_yumi_li = 1'b0;
    stall_remote_ld_wb = 1'b0;

    // int remote_load_resp and icache response are mutually exclusive events.
    if (int_remote_load_resp_force_i) begin
      wb_ctrl_n.write_rd = 1'b1;
      wb_ctrl_n.rd_addr = int_remote_load_resp_rd_i;
      wb_data_n.rf_data = int_remote_load_resp_data_i;
      wb_ctrl_n.clear_sb = 1'b1;
      stall_remote_ld_wb = mem_result_valid | mem_ctrl_int_r.icache_miss;
      int_remote_load_resp_yumi_o = 1'b1;
    end
    else if (mem_ctrl_int_r.icache_miss & ifetch_v_i) begin
      wb_ctrl_n.icache_miss = 1'b1;
    end
    else begin
      if (imul_v_lo) begin
        wb_ctrl_n.write_rd = 1'b1;
        wb_ctrl_n.rd_addr = imul_rd_lo;
        wb_data_n.rf_data = imul_result_lo;
      end
      else if (mem_ctrl_int_r.write_rd) begin
        wb_ctrl_n.write_rd = 1'b1;
        wb_ctrl_n.rd_addr = mem_ctrl_int_r.rd_addr;
        wb_data_n.rf_data = mem_ctrl_int_r.local_load
          ? local_load_packed_data
          : mem_data_int_r.exe_result;
      end
      else if (mem_ctrl_fp_r.write_rd) begin
        wb_ctrl_n.write_rd = 1'b1;
        wb_ctrl_n.rd_addr = mem_ctrl_fp_r.rd_addr;
        wb_data_n.rf_data = mem_data_fp_r.exe_result;
      end
      else begin
        if (int_remote_load_resp_v_i) begin
          wb_ctrl_n.write_rd = 1'b1;
          wb_ctrl_n.rd_addr = int_remote_load_resp_rd_i;
          wb_data_n.rf_data = int_remote_load_resp_data_i;
          wb_ctrl_n.clear_sb = 1'b1;
          int_remote_load_resp_yumi_o = 1'b1;
        end
        else if (idiv_v_lo) begin
          wb_ctrl_n.write_rd = 1'b1;
          wb_ctrl_n.rd_addr = idiv_rd_lo;
          wb_data_n.rf_data = idiv_result_lo;
          wb_ctrl_n.clear_sb = 1'b1;
          idiv_yumi_li = 1'b1;
        end
      end
    end
  end


  // WB 
  assign int_rf_wdata = wb_data_r.rf_data;
  assign int_rf_waddr = wb_ctrl_r.rd_addr;
  assign int_rf_wen = wb_ctrl_r.write_rd;

  // int scoreboard clear logic
  assign int_sb_clear = wb_ctrl_r.write_rd & wb_ctrl_r.clear_sb;
  assign int_sb_clear_id = wb_ctrl_r.rd_addr;


  // MEM -> FLW_WB
  always_comb begin
    flw_wb_ctrl_en = ~stall_all;
    flw_wb_data_en = ~stall_all;
    flw_wb_ctrl_n = '{
      valid: mem_ctrl_int_r.write_frd,
      rd_addr: mem_ctrl_int_r.rd_addr
    };
    flw_wb_data_n = '{
      rf_data: local_load_data_r
    };
  end

  
  // FP_WB
  // fcsr exception handling
  // float scoreboard clear logic
  // float_rf_*[0], float_sb_clear*[0] -> dedicated to INT FP mem ops (local/remote loads)
  // float_rf_*[1], float_sb_clear*[1] -> dedicated to FP ops
  always_comb begin
    stall_remote_flw_wb = 1'b0;

    float_remote_load_resp_yumi_o = 1'b0;
    fdiv_fsqrt_yumi_li = 1'b0;

    float_rf_wen[0] = 1'b0;
    float_rf_waddr[0] = '0;
    float_rf_wdata[0] = '0;
    float_rf_wen[1] = 1'b0;
    float_rf_waddr[1] = '0;
    float_rf_wdata[1] = '0;
    select_remote_flw = 1'b0;

    float_sb_clear_mem = 1'b0;
    float_sb_clear_mem_id = float_remote_load_resp_rd_i;
    float_sb_clear_fdiv = 1'b0;
    float_sb_clear_fdiv_id = '0;

    fcsr_fflags_v_li[1] = 1'b0;
    fcsr_fflags_li[1] = fpu_float_fflags_lo;
    
    if (float_remote_load_resp_force_i) begin
      select_remote_flw = 1'b1;
      float_rf_wen[0] = 1'b1;
      float_rf_waddr[0] = float_remote_load_resp_rd_i;
      float_rf_wdata[0] = flw_recoded_data;
      float_remote_load_resp_yumi_o = 1'b1;
      stall_remote_flw_wb = flw_wb_ctrl_r.valid | fpu_float_v_lo;

      float_sb_clear_mem = 1'b1;
      float_sb_clear_mem_id = float_remote_load_resp_rd_i;
    end
    else if (flw_wb_ctrl_r.valid) begin
      select_remote_flw = 1'b0;
      float_rf_wen[0] = 1'b1;
      float_rf_waddr[0] = flw_wb_ctrl_r.rd_addr;
      float_rf_wdata[0] = flw_recoded_data; 
    end else if (float_remote_load_resp_v_i) begin
      select_remote_flw = 1'b1;
      float_rf_wen[0] = 1'b1;
      float_rf_waddr[0] = float_remote_load_resp_rd_i;
      float_rf_wdata[0] = flw_recoded_data;
      float_remote_load_resp_yumi_o = 1'b1;

      float_sb_clear_mem = 1'b1;
      float_sb_clear_mem_id = float_remote_load_resp_rd_i;
    end
    
    if (fpu_float_v_lo) begin
      float_rf_wen[1] = 1'b1;
      float_rf_waddr[1] = fpu_float_rd_lo;
      float_rf_wdata[1] = fpu_float_result_lo;
      fcsr_fflags_v_li[1] = 1'b1;
      fcsr_fflags_li[1] = fpu_float_fflags_lo;
    end
    else if (fdiv_fsqrt_v_lo) begin
        fdiv_fsqrt_yumi_li = 1'b1;
        float_rf_wen[1] = 1'b1;
        float_rf_waddr[1] = fdiv_fsqrt_rd_lo;
        float_rf_wdata[1] = fdiv_fsqrt_result_lo;

        float_sb_clear_fdiv = 1'b1;
        float_sb_clear_fdiv_id = fdiv_fsqrt_rd_lo;

        fcsr_fflags_v_li[1] = 1'b1;
        fcsr_fflags_li[1] = fdiv_fsqrt_fflags_lo;
    end  
  end

  // fpu_float stall control
  assign stall_fpu1_li = stall_all;
  assign stall_fpu2_li = stall_remote_flw_wb;

  // synopsys translate_off
  always_ff @ (negedge clk_i) begin
    if (~reset_i) begin

      if (idiv_v_li) begin
        assert(idiv_ready_and_lo) else $error("idiv_op issued when idiv is not ready.");
      end

      if (fdiv_fsqrt_v_li) begin
        assert(fdiv_fsqrt_ready_and_lo) else $error("fdiv_fsqrt_op issued, when fdiv_fsqrt is not ready.");
      end

      assert(~id_int_r.decode.unsupported) else $error("Unsupported instruction: %8x", id_int_r.instruction);
      assert(~id_fp_r.decode.unsupported) else $error("Unsupported instruction: %8x", id_fp_r.instruction);
    end
  end
  // synopsys translate_on

  // debug messages for tracking behavior
  always_ff @ (posedge clk_i) begin
        if (id_issue & id_int_r.valid)
          $info("[DEBUG][VCORE] Instruction issued. t=%0t, instr=%h", $time, id_int_r.instruction);
        if (id_issue & id_fp_r.valid)
          $info("[DEBUG][VCORE] Instruction issued. t=%0t, instr=%h", $time, id_fp_r.instruction);
        if (int_rf_wen)
          $info("[DEBUG][VCORE] Integer regfile writeback occurred. t=%0t, addr=%h, data=%h", $time, int_rf_waddr, int_rf_wdata);
        if (float_rf_wen[0])
          $info("[DEBUG][VCORE] Floating point regfile writeback occured. t=%0t, addr=%h, data=%h", $time, float_rf_waddr[0], float_rf_wdata[0]);
        if (float_rf_wen[1])
          $info("[DEBUG][VCORE] Floating point regfile writeback occured. t=%0t, addr=%h, data=%h", $time, float_rf_waddr[1], float_rf_wdata[1]); 
        if (float_remote_load_resp_v_i & float_remote_load_resp_yumi_o)  
          $info("[DEBUG][VCORE] Floating point load response received. t=%0t, addr=%h, data=%h, select_remote_flw=%h, float_remote_load_resp_data_i=%h, flw_data=%h, flw_recoded_data=%h, flw_wb_data_r.rf_data=%h", 
          $time, float_rf_waddr[0], float_rf_wdata[0], select_remote_flw, float_remote_load_resp_data_i, flw_data, flw_recoded_data, flw_wb_data_r.rf_data);
        if (id_issue & id_int_r.valid & id_fp_r.valid)
          $info("[DEBUG][VCORE] Dual-issued an instruction. t=%0t, int pipeline pc_plus4=%h, fp pipeline pc_plus4=%h", $time, id_int_r.pc_plus4, id_fp_r.pc_plus4); 
    end

    // performance counters per-tile, to be aggregrated post-sim
    integer dual_issue_ctr;
    integer dual_fp_wb_ctr;
    integer remote_flw_ctr;
    integer fp_op_fp_wb_ctr;
    logic init_counters;

    always_ff @ (posedge clk_i) begin
      if (init_counters) begin
        dual_issue_ctr <= '0;
        dual_fp_wb_ctr <= '0;
        remote_flw_ctr <= '0;
        fp_op_fp_wb_ctr <= '0;
      end
      else begin
          if (id_issue & id_int_r.valid & id_fp_r.valid & ~reset_i) begin 
            dual_issue_ctr <= dual_issue_ctr + 1;
            // $info("detected dual-issue, adding to counter, dual_issue_ctr=%0d",dual_issue_ctr+1);
          end
          if (float_rf_wen[0] & float_rf_wen[1] & ~reset_i) begin
            dual_fp_wb_ctr <= dual_fp_wb_ctr + 1;
            // $info("detected dual FP writeback, dual_fp_wb_ctr=%0d",dual_fp_wb_ctr+1);
          end
          if (float_remote_load_resp_v_i & float_remote_load_resp_yumi_o & ~reset_i) begin
            remote_flw_ctr <= remote_flw_ctr + 1;
            // $info("detected remote FLW writeback, remote_flw_ctr=%0d",remote_flw_ctr+1);
          end
          if (id_issue & id_fp_r.valid & id_fp_r.decode.write_frd) begin
            fp_op_fp_wb_ctr <= fp_op_fp_wb_ctr + 1;
            // $info("detected FP op that writes back to FP regfile, fp_op_fp_wb_ctr=%0d",fp_op_fp_wb_ctr+1);
          end
      end
    end

    string current_path, ctr_file;
    integer ctr_fd;

    initial begin
      current_path = $sformatf("%m");
      ctr_file = $sformatf("%s_dual_issue_perf_cnt.txt",current_path);
      init_counters = 1'b1;
      repeat(3) @(posedge clk_i);
      init_counters = 1'b0;
    end

    final begin
        $info("Outputting dual_issue_ctr=%0d, dual_fp_wb_ctr=%0d, remote_flw_ctr=%0d, fp_op_fp_wb_ctr=%0d to %s", 
              dual_issue_ctr, dual_fp_wb_ctr, remote_flw_ctr, fp_op_fp_wb_ctr, ctr_file);
        ctr_fd = $fopen(ctr_file, "w");
        $fwrite(ctr_fd, "dual_issue_ctr,dual_fp_wb_ctr,remote_flw_ctr,fp_op_fp_wb_ctr\n");
        $fwrite(ctr_fd, "%0d,%0d,%0d,%0d",dual_issue_ctr,dual_fp_wb_ctr,remote_flw_ctr,fp_op_fp_wb_ctr);
        $fclose(ctr_fd);
    end

endmodule

`BSG_ABSTRACT_MODULE(vanilla_core)
