
`include "bsg_vanilla_defines.svh"

module instr_scheduler
import bsg_vanilla_pkg::*;
import bsg_manycore_pkg::*;
#(
    `BSG_INV_PARAM(pc_width_p)
)(
  input clk_i
  , input reset_i

  , input [pc_width_p-1:0] pc_r_i
  , input instruction_s instruction0_i
  , input decode_s decode0_i
  , input fp_decode_s fp_decode0_i
  , input instruction_s instruction1_i
  , input decode_s decode1_i
  , input fp_decode_s fp_decode1_i
  , input branch_predicted_taken_i

  , output logic is_dual_issue_o
  , output logic single_issue_is_int_o
  
  , output instruction_s instruction_int_o
  , output decode_s decode_int_o
  , output fp_decode_s fp_decode_int_o
  , output instruction_s instruction_fp_o
  , output decode_s decode_fp_o
  , output fp_decode_s fp_decode_fp_o
  , output logic instr_int_v_o
  , output logic instr_fp_v_o
  , output logic int_is_instr0_o
  , output logic fp_is_instr0_o
);

  // determine if dual issue
  logic is_dual_issue;
  logic waw, raw, war, data_hazard;

  logic instr01_dual_issue, instr10_dual_issue;
  logic instruction0_cross_regfile, instruction1_cross_regfile, instruction0_safe_control_flow;
  logic instruction0_is_fsw, instruction1_is_fsw;

  // determine whether a floating point instruction interacts with the integer regfile
  always_comb begin
    instruction0_cross_regfile = 1'b0;
    instruction1_cross_regfile = 1'b0;
    instruction0_is_fsw = 1'b0;
    instruction1_is_fsw = 1'b0;
    
    unique casez (instruction0_i)
        `RV32_FEQ_S, `RV32_FLT_S, `RV32_FLE_S,
        `RV32_FCLASS_S,
        `RV32_FCVT_S_W, `RV32_FCVT_S_WU,
        `RV32_FCVT_W_S, `RV32_FCVT_WU_S,
        `RV32_FMV_X_W, `RV32_FMV_W_X: begin
            instruction0_cross_regfile = 1'b1;
        end 
        `RV32_FSW_S: begin
            instruction0_is_fsw = 1'b1;
        end 
        default: begin // redundant
            instruction0_is_fsw = 1'b0;
            instruction0_cross_regfile = 1'b0;
        end
    endcase

    unique casez (instruction1_i)
        `RV32_FEQ_S, `RV32_FLT_S, `RV32_FLE_S,
        `RV32_FCLASS_S,
        `RV32_FCVT_S_W, `RV32_FCVT_S_WU,
        `RV32_FCVT_W_S, `RV32_FCVT_WU_S,
        `RV32_FMV_X_W, `RV32_FMV_W_X: begin
            instruction1_cross_regfile = 1'b1;
        end 
        `RV32_FSW_S: begin
            instruction1_is_fsw = 1'b1;
        end 
        default: begin // redundant
            instruction1_is_fsw = 1'b0;
            instruction1_cross_regfile = 1'b0;
        end
    endcase
  end

  assign is_dual_issue = ~pc_r_i[0] & ~data_hazard & (instr01_dual_issue | instr10_dual_issue);
  // assign is_dual_issue = 1'b0; // uncomment this and comment prev line to force single-issue
  assign instr01_dual_issue = (~decode0_i.is_fp_op & instruction0_safe_control_flow & ~instruction0_is_fsw) & (decode1_i.is_fp_op & ~instruction1_cross_regfile);
  assign instr10_dual_issue = (~decode1_i.is_fp_op & ~instruction1_is_fsw) & (decode0_i.is_fp_op & ~instruction0_cross_regfile);
  assign is_dual_issue_o = is_dual_issue;

  // if instruction 0 is a control flow instruction, determine whether it causes the PC to move non-sequentially - only ok if branch and we predict not taken
  assign instruction0_safe_control_flow = ~decode0_i.is_mret_op & ~decode0_i.is_jal_op & ~decode0_i.is_jalr_op
                                          & (~decode0_i.is_branch_op | (decode0_i.is_branch_op & ~branch_predicted_taken_i));

  // detect hazards
  assign data_hazard = (waw | raw | war);
  assign waw = decode1_i.write_frd & decode0_i.write_frd &
            (instruction1_i.rd == instruction0_i.rd);

  assign raw = decode0_i.write_frd &
            ((decode1_i.read_frs1 & (instruction1_i.rs1 == instruction0_i.rd)) | // frs1
             (decode1_i.read_frs2 & (instruction1_i.rs2 == instruction0_i.rd)) | // frs2
             (decode1_i.read_frs3 & (instruction1_i[31:27] == instruction0_i.rd))); // frs3

  assign war = decode1_i.write_frd &
            ((decode0_i.read_frs1 & (instruction0_i.rs1 == instruction1_i.rd)) | // frs1
             (decode0_i.read_frs2 & (instruction0_i.rs2 == instruction1_i.rd)) | // frs2
             (decode0_i.read_frs3 & (instruction0_i[31:27] == instruction1_i.rd))); // frs3

  // for single issue, whether we are issuing an int instruction or an fp instruction
  assign single_issue_is_int_o = pc_r_i[0] ? (~decode1_i.is_fp_op) : (~decode0_i.is_fp_op);

  // output control
  always_comb begin
    instr_int_v_o = 1'b0;
    instr_fp_v_o = 1'b0;
    int_is_instr0_o = 1'b0;
    fp_is_instr0_o = 1'b0;

    // instruction outputs
    instruction_fp_o = '0;
    decode_fp_o = '0;
    fp_decode_fp_o = '0;
    instruction_int_o = '0;
    decode_int_o = '0;
    fp_decode_int_o = '0;

    if (is_dual_issue) begin
        if (decode1_i.is_fp_op) begin
            instruction_fp_o = instruction1_i;
            decode_fp_o = decode1_i;
            fp_decode_fp_o = fp_decode1_i;
            instr_fp_v_o = 1'b1;

            instruction_int_o = instruction0_i;
            decode_int_o = decode0_i;
            fp_decode_int_o = fp_decode0_i;
            instr_int_v_o = 1'b1;
            int_is_instr0_o = 1'b1;
        end else begin
            instruction_fp_o = instruction0_i;
            decode_fp_o = decode0_i;
            fp_decode_fp_o = fp_decode0_i;
            instr_fp_v_o = 1'b1;
            fp_is_instr0_o = 1'b1;

            instruction_int_o = instruction1_i;
            decode_int_o = decode1_i;
            fp_decode_int_o = fp_decode1_i;
            instr_int_v_o = 1'b1;
        end
    end else if (pc_r_i[0] & decode1_i.is_fp_op) begin
        instruction_fp_o = instruction1_i;
        decode_fp_o = decode1_i;
        fp_decode_fp_o = fp_decode1_i;
        instr_fp_v_o = 1'b1;

    end else if (pc_r_i[0] & ~decode1_i.is_fp_op) begin
        instruction_int_o = instruction1_i;
        decode_int_o = decode1_i;
        fp_decode_int_o = fp_decode1_i;
        instr_int_v_o = 1'b1;

    end else if (decode0_i.is_fp_op) begin
        instruction_fp_o = instruction0_i;
        decode_fp_o = decode0_i;
        fp_decode_fp_o = fp_decode0_i;
        instr_fp_v_o = 1'b1;
        fp_is_instr0_o = 1'b1;

    end else begin
        instruction_int_o = instruction0_i;
        decode_int_o = decode0_i;
        fp_decode_int_o = fp_decode0_i;
        instr_int_v_o = 1'b1;
        int_is_instr0_o = 1'b1;
    end
  end

endmodule