/**
 * bp_be_csr_wrapper_mt.sv
 *
 * Multi-Thread CSR Wrapper for Black Parrot
 *
 * Description:
 *   Wraps CSR access logic to support per-thread context switching via
 *   the CTXT CSR (0x081).
 *
 *   The CTXT CSR holds the current thread ID. Writing to it triggers
 *   a context switch: the next instruction will execute as a different
 *   thread with different state.
 *
 *   Standard CSRs are read/written from the context storage based on
 *   current_thread_id. Context-switching CSRs like CTXT are global.
 *
 * CSR Map (Threading Extension):
 *   0x081 - CTXT: Current context ID register (read/write)
 *           [31:0] = thread_id
 *
 *   Writes to CTXT CSR in retire stage atomically switch context.
 *   PC is handled by context storage (doesn't use normal CSR file).
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_csr_wrapper_mt
 import bp_common_pkg::*;
 #(parameter num_threads_p = 1
   , parameter dword_width_p = 64
   )
  (input                                     clk_i
   , input                                   reset_i

   // Current thread ID
   , output logic [$clog2(num_threads_p):0] current_thread_id_o
   , input  logic [$clog2(num_threads_p):0] next_thread_id_i

   // CSR interface (from decode/execute)
   , input                                   csr_addr_v_i
   , input  [11:0]                           csr_addr_i
   , input  [dword_width_p-1:0]              csr_wdata_i
   , output logic [dword_width_p-1:0]        csr_rdata_o
   , input                                   csr_w_v_i

   // To context storage
   , output logic [$clog2(num_threads_p):0] csr_ctxt_w_thread_id_o
   , output logic [$clog2(num_threads_p):0] csr_ctxt_w_thread_id_next_o

   // Context switching (retire stage)
   , input                                   ctxtsw_v_i
   , input  [11:0]                           ctxtsw_csr_addr_i
   , input  [dword_width_p-1:0]              ctxtsw_csr_data_i
   );

  localparam thread_id_width_lp = $clog2(num_threads_p) + 1;

  // Internal thread ID register (holds current context)
  logic [thread_id_width_lp-1:0]              thread_id_r;

  // Assign output
  assign current_thread_id_o = thread_id_r;

  // For context storage integration
  assign csr_ctxt_w_thread_id_o = thread_id_r;
  assign csr_ctxt_w_thread_id_next_o = next_thread_id_i;

  // Handle CTXT CSR (0x081) context switching
  always @(posedge clk_i) begin
    if (reset_i) begin
      thread_id_r <= '0;
    end else if (ctxtsw_v_i && ctxtsw_csr_addr_i == 12'h081) begin
      // Context switch: write new thread ID
      thread_id_r <= ctxtsw_csr_data_i[thread_id_width_lp-1:0];
    end
  end

  // CSR read logic
  always_comb begin
    csr_rdata_o = '0;

    if (csr_addr_v_i) begin
      case (csr_addr_i)
        12'h081: begin
          // CTXT CSR - return current thread ID
          csr_rdata_o = {(dword_width_p - thread_id_width_lp)'(0), thread_id_r};
        end
        default: begin
          // Standard CSRs would be handled by main CSR file
          // This wrapper just intercepts CTXT CSR
          csr_rdata_o = '0;
        end
      endcase
    end
  end

endmodule

`BSG_ABSTRACT_MODULE(bp_be_csr_wrapper_mt)
