/**
 *    regfile_synth.v
 *
 *    synthesized register file
 *
 *    @author tommy
 */

`include "bsg_defines.sv"

module regfile_synth
  #(`BSG_INV_PARAM(width_p)
    , `BSG_INV_PARAM(els_p)
    , `BSG_INV_PARAM(num_rs_p)
    , `BSG_INV_PARAM(x0_tied_to_zero_p)
    , `BSG_INV_PARAM(num_rd_p)

    , localparam addr_width_lp=`BSG_SAFE_CLOG2(els_p)
  )
  (
    input clk_i
    , input reset_i

    , input [num_rd_p-1:0] w_v_i
    , input [num_rd_p-1:0][addr_width_lp-1:0] w_addr_i
    , input [num_rd_p-1:0][width_p-1:0] w_data_i
    
    , input [num_rs_p-1:0] r_v_i
    , input [num_rs_p-1:0][addr_width_lp-1:0] r_addr_i
    , output logic [num_rs_p-1:0][width_p-1:0] r_data_o
  );

  wire unused = reset_i;
  
  logic [num_rs_p-1:0][addr_width_lp-1:0] r_addr_r;


  always_ff @ (posedge clk_i)
    for (integer i = 0; i < num_rs_p; i++)
      if (r_v_i[i]) r_addr_r[i] <= r_addr_i[i];


  if (num_rd_p == 1) begin: single_wb
    if (x0_tied_to_zero_p) begin: xz
      // x0 is tied to zero.
      logic [width_p-1:0] mem_r [els_p-1:1];
      
      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = (r_addr_r[i] == '0)? '0 : mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i)
        if (w_v_i & (w_addr_i != '0))
          mem_r[w_addr_i] <= w_data_i;


    end
    else begin: xnz
      // x0 is not tied to zero.
      logic [width_p-1:0] mem_r [els_p-1:0];
    
      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i)
        if (w_v_i)
          mem_r[w_addr_i] <= w_data_i;
      
    end
  end
  else begin: dual_wb
  if (x0_tied_to_zero_p) begin: xz
      // x0 is tied to zero.
      logic [width_p-1:0] mem_r [els_p-1:1];
      
      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = (r_addr_r[i] == '0)? '0 : mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i) begin
        if (w_v_i[0] & (w_addr_i[0] != '0))
          mem_r[w_addr_i[0]] <= w_data_i[0];
          
        if (w_v_i[1] & (w_addr_i[1] != '0) & (w_addr_i[0] != w_addr_i[1]))
          mem_r[w_addr_i[1]] <= w_data_i[1];
      end

    end
    else begin: xnz
      // x0 is not tied to zero.
      logic [width_p-1:0] mem_r [els_p-1:0];
    
      for (genvar i = 0; i < num_rs_p; i++)
        assign r_data_o[i] = mem_r[r_addr_r[i]];

      always_ff @ (posedge clk_i) begin
         if (w_v_i[0] & ~w_v_i[1]) begin
            mem_r[w_addr_i[0]] <= w_data_i[0];
          end else if (w_v_i[1] & ~w_v_i[0]) begin
            mem_r[w_addr_i[1]] <= w_data_i[1];
          end else if (w_v_i[0] & w_v_i[1] & (w_addr_i[0] != w_addr_i[1])) begin
            mem_r[w_addr_i[0]] <= w_data_i[0];
            mem_r[w_addr_i[1]] <= w_data_i[1];
         end
      end

      always_ff @ (posedge clk_i) begin
        if (!reset_i & w_v_i[0] & w_v_i[1])
          assert(w_addr_i[0] != w_addr_i[1]) else $error("Two regfile write ports tried to write to the same address.");
      end

      
    end
  end


endmodule

`BSG_ABSTRACT_MODULE(regfile_synth)
