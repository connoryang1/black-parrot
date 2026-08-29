
`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_cmd_queue
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_core_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   , localparam ptr_width_lp = `BSG_SAFE_CLOG2(fe_cmd_fifo_els_p)
   )
  (input                                clk_i
   , input                              reset_i

   , input [fe_cmd_width_lp-1:0]        fe_cmd_i
   , input                              fe_cmd_v_i

   , output logic [fe_cmd_width_lp-1:0] fe_cmd_o
   , output logic                       fe_cmd_v_o
   , input                              fe_cmd_yumi_i

   , output logic                       empty_n_o
   , output logic                       empty_r_o
   , output logic                       full_n_o
   , output logic                       full_r_o
   );

  `declare_bp_core_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `bp_cast_i(bp_fe_cmd_s, fe_cmd);

  logic full_lo, empty_lo;

  // Context redirects and I-cache refill completions need zero-cycle FE
  // delivery.  Keep ordinary redirects queued so their payload is not exposed
  // combinationally across the BE/FE boundary.
  wire fast_cmd_v = (fe_cmd_cast_i.opcode == e_op_context_switch)
                    | (fe_cmd_cast_i.opcode == e_op_icache_fill_response);
  wire bypass_v = empty_lo & fe_cmd_v_i & fast_cmd_v;
  wire enq = fe_cmd_v_i & (~bypass_v | ~fe_cmd_yumi_i);
  wire deq = fe_cmd_yumi_i & ~empty_lo;

  logic [ptr_width_lp-1:0] wptr_r, rptr_n, rptr_r;
  bsg_fifo_tracker
   #(.els_p(fe_cmd_fifo_els_p))
   ft
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.enq_i(enq)
     ,.deq_i(deq)
     ,.wptr_r_o(wptr_r)
     ,.rptr_r_o(rptr_r)
     ,.rptr_n_o(rptr_n)
     ,.full_o(full_lo)
     ,.empty_o(empty_lo)
     );

  logic [fe_cmd_width_lp-1:0] fifo_cmd_lo;

  bsg_mem_1r1w
   #(.width_p($bits(bp_fe_cmd_s)), .els_p(fe_cmd_fifo_els_p))
   fifo_mem
    (.w_clk_i(clk_i)
     ,.w_reset_i(reset_i)
     ,.w_v_i(enq)
     ,.w_addr_i(wptr_r)
     ,.w_data_i(fe_cmd_i)
     ,.r_v_i(fe_cmd_v_o)
     ,.r_addr_i(rptr_r)
     ,.r_data_o(fifo_cmd_lo)
     );

  assign fe_cmd_o       = bypass_v ? fe_cmd_i : fifo_cmd_lo;
  assign fe_cmd_v_o     = bypass_v | ~empty_lo;

  wire almost_full = (rptr_r == wptr_r+1'b1);
  wire almost_empty = (rptr_r == wptr_r-1'b1);

  assign empty_r_o = empty_lo;
  assign empty_n_o = (empty_lo | (almost_empty & deq)) & ~enq;
  assign full_r_o  = full_lo;
  assign full_n_o  = (full_lo | (almost_full & enq)) & ~deq;

endmodule
