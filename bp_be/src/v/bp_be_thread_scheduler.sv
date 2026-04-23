/**
 * bp_be_thread_scheduler.sv
 *
 * Current-thread register for software-directed context switching
 *
 * Description:
 *   Holds the currently active hardware thread ID. A write to the CTXT CSR
 *   updates this register; otherwise it simply holds its value.
 *
 *   Despite the historical name, this block does not perform automatic
 *   round-robin scheduling.
 *
 * Author: Black Parrot Multithreading Implementation
 * Date: February 2026
 */

`include "bp_common_defines.svh"

module bp_be_thread_scheduler
 import bp_common_pkg::*;
 #(parameter num_threads_p = 1
   , parameter thread_id_width_p = `BSG_SAFE_CLOG2(num_threads_p)
   )
  (input                                    clk_i
   , input                                  reset_i
   , input                                  csr_write_ctxt_v_i
   , input [thread_id_width_p-1:0]          csr_write_ctxt_data_i
   , output logic [thread_id_width_p-1:0]   thread_id_o
   );

  // Current thread register - stores which thread is currently active.
  logic [thread_id_width_p-1:0] current_thread_r;

  // Sequential logic: update on CTXT CSR write, hold otherwise.
  always @(posedge clk_i) begin
    if (reset_i) begin
      // On reset, start with thread 0.
      current_thread_r <= '0;
    end else if (csr_write_ctxt_v_i) begin
      // CSR write to CTXT (0x081) jumps to the requested thread.
      current_thread_r <= csr_write_ctxt_data_i;
    end
    // else: hold current thread
  end

  // Combinational output: expose the active thread ID.
  assign thread_id_o = current_thread_r;

endmodule

`BSG_ABSTRACT_MODULE(bp_be_thread_scheduler)
