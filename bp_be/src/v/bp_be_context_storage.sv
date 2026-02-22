/**
 * bp_be_context_storage.sv
 *
 * Per-Thread Context Storage for Black Parrot
 *
 * Description:
 *   Stores per-thread architectural state that must be preserved across
 *   context switches:
 *   - NPC (next PC) - address of next instruction to execute
 *   - PRIV_MODE - current privilege mode (machine/supervisor/user)
 *   - TRANSLATION_EN - MMU enabled flag
 *   - ASID - address space ID (for TLB tagging)
 *
 * Each thread has its own copy of these registers, indexed by thread_id.
 * On context switch (write to CTXT CSR), hardware atomically switches which
 * thread's state is visible to the rest of the pipeline.
 *
 * Architecture:
 *   - Array of flip-flops, one per thread
 *   - Synchronous writes on retire (when instruction commits)
 *   - Combinational reads based on current_thread_id
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_context_storage
 import bp_common_pkg::*;
 #(parameter num_threads_p = 1
   , parameter vaddr_width_p = 64
   , parameter asid_width_p = 16
   )
  (input                                        clk_i
   , input                                      reset_i

   // Current thread ID (read-side)
   , input [$clog2(num_threads_p):0]            current_thread_id_i

   // Read interface (combinational)
   , output logic [vaddr_width_p-1:0]           npc_o
   , output logic [1:0]                         priv_mode_o  // RISC-V privilege mode (M=3, S=1, U=0)
   , output logic                               translation_en_o
   , output logic [asid_width_p-1:0]            asid_o

   // Write interface (synchronous on commit)
   , input                                      commit_v_i
   , input [$clog2(num_threads_p):0]            commit_thread_id_i
   , input [vaddr_width_p-1:0]                  npc_i
   , input [1:0]                                priv_mode_i
   , input                                      translation_en_i
   , input [asid_width_p-1:0]                   asid_i
   );

  localparam thread_id_width_lp = $clog2(num_threads_p) + 1;

  // Per-thread storage arrays
  logic [num_threads_p-1:0][vaddr_width_p-1:0]      npc_storage;
  logic [num_threads_p-1:0][1:0]                    priv_mode_storage;
  logic [num_threads_p-1:0]                         translation_en_storage;
  logic [num_threads_p-1:0][asid_width_p-1:0]       asid_storage;

  // Write logic: synchronous update on commit
  always @(posedge clk_i) begin
    if (reset_i) begin
      // Reset all threads to machine mode, no translation, ASID 0
      for (int i = 0; i < num_threads_p; i++) begin
        npc_storage[i] <= '0;
        priv_mode_storage[i] <= 2'b11;  // PRIV_MODE_M = 3 = 2'b11
        translation_en_storage[i] <= 1'b0;
        asid_storage[i] <= '0;
      end
    end else if (commit_v_i && commit_thread_id_i < num_threads_p) begin
      // Update the state for the committing thread
      // $display("[CTXST @%0t] WRITE: tid=%0d npc=0x%08x (old npc=0x%08x)",
      //          $time, commit_thread_id_i, npc_i, npc_storage[commit_thread_id_i]);
      npc_storage[commit_thread_id_i] <= npc_i;
      priv_mode_storage[commit_thread_id_i] <= priv_mode_i;
      translation_en_storage[commit_thread_id_i] <= translation_en_i;
      asid_storage[commit_thread_id_i] <= asid_i;
    end
  end

  // Debug: trace every time commit_v fires or npc_o changes
  // always @(posedge clk_i) begin
  //   if (!reset_i && commit_v_i)
  //     $display("[CTXST @%0t] commit_v=1 tid=%0d npc_in=0x%08x cur_tid=%0d fwd=%0b npc_out=0x%08x",
  //              $time, commit_thread_id_i, npc_i, current_thread_id_i, fwd_v, npc_o);
  // end

  // Write-forwarding: if writing and reading the same slot simultaneously,
  // return the incoming write value rather than the stale registered value.
  wire fwd_v = commit_v_i && (commit_thread_id_i == current_thread_id_i)
                           && (commit_thread_id_i < num_threads_p)
                           && (current_thread_id_i < num_threads_p);

  // Read logic: combinational mux based on current thread ID
  always_comb begin
    if (fwd_v) begin
      npc_o = npc_i;
      priv_mode_o = priv_mode_i;
      translation_en_o = translation_en_i;
      asid_o = asid_i;
    end else if (current_thread_id_i < num_threads_p) begin
      npc_o = npc_storage[current_thread_id_i];
      priv_mode_o = priv_mode_storage[current_thread_id_i];
      translation_en_o = translation_en_storage[current_thread_id_i];
      asid_o = asid_storage[current_thread_id_i];
    end else begin
      // Invalid thread ID - return defaults
      npc_o = '0;
      priv_mode_o = 2'b11;  // PRIV_MODE_M
      translation_en_o = 1'b0;
      asid_o = '0;
    end
  end

endmodule

`BSG_ABSTRACT_MODULE(bp_be_context_storage)
