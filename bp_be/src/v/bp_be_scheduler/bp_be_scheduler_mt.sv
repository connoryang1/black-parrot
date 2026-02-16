/**
 * bp_be_scheduler_mt.sv
 *
 * Multi-threaded Hardware Scheduler for Black Parrot
 *
 * Phase 0: Hybrid SW/HW Scheduling
 * - Hardware round-robin to schedule runnable threads
 * - Software can override via CSR (scheduler control)
 * - Supports thread enable/disable, blocking (mwait), and priorities
 *
 * This module is instantiated in bp_be_top and provides:
 * - active_tid_o: Current thread ID to execute
 * - scheduler_override_i: Software override from CSR (Phase 0+ feature)
 * - thread_status_i: Per-thread enable/block status
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_scheduler_mt
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   )
  (input                                  clk_i
   , input                                reset_i

   ///////////////////////////////////////////////////////////////////////////
   // Hardware Scheduler Control
   ///////////////////////////////////////////////////////////////////////////
   // From CSR: thread enable/disable, block status
   , input [num_threads_gp-1:0]           thread_enabled_i      // 1 = runnable
   , input [num_threads_gp-1:0]           thread_blocked_i      // 1 = blocked (e.g., on mwait)
   , input [7:0]                          thread_priority_i [num_threads_gp-1:0] // 0-255, higher = faster

   // From CSR: software scheduling override
   , input [7:0]                          scheduler_mode_i      // 0=hw rr, 1=sw override, etc
   , input [thread_id_width_p-1:0]        scheduler_override_tid_i  // Force this thread

   ///////////////////////////////////////////////////////////////////////////
   // Dispatch Interface
   ///////////////////////////////////////////////////////////////////////////
   // Instruction issue request from current thread
   , input bp_be_issue_pkt_s              issue_pkt_i
   , input                                issue_valid_i

   // Output to pipeline
   , output logic [thread_id_width_p-1:0] active_tid_o          // Which thread to fetch/decode
   , output logic [thread_id_width_p-1:0] next_tid_o            // Next thread (for prefetch)

   ///////////////////////////////////////////////////////////////////////////
   // Scheduler State
   ///////////////////////////////////////////////////////////////////////////
   , output logic [thread_id_width_p-1:0] scheduler_state_tid_o // Debug: current scheduler state
   );

  ///////////////////////////////////////////////////////////////////////////
  // Round-Robin Scheduler State Machine
  ///////////////////////////////////////////////////////////////////////////

  logic [thread_id_width_p-1:0] current_tid_r, current_tid_n;
  logic [thread_id_width_p-1:0] next_tid_n;
  logic [7:0] instr_count_r;                      // Instructions issued from current thread
  localparam int MAX_INSTR_PER_THREAD = 8;        // Switch thread every N instructions

  ///////////////////////////////////////////////////////////////////////////
  // Helper Functions
  ///////////////////////////////////////////////////////////////////////////

  // Find next runnable thread (hardware round-robin)
  function logic [thread_id_width_p-1:0] find_next_runnable_tid(
    logic [thread_id_width_p-1:0] current_tid
  );
    logic [thread_id_width_p-1:0] tid;
    logic found;

    tid = current_tid;
    found = 1'b0;

    // Try up to num_threads_gp iterations to find a runnable thread
    for (int i = 0; i < num_threads_gp; i++) begin
      tid = (tid + 1) % num_threads_gp;
      if (thread_enabled_i[tid] && !thread_blocked_i[tid]) begin
        found = 1'b1;
        break;
      end
    end

    // If no runnable thread found, default to 0 (will stall pipeline if disabled)
    return tid;
  endfunction

  // Find next highest-priority runnable thread (for priority scheduling)
  function logic [thread_id_width_p-1:0] find_next_priority_tid(
    logic [thread_id_width_p-1:0] current_tid
  );
    logic [thread_id_width_p-1:0] best_tid;
    logic [7:0] best_priority;

    best_tid = current_tid;
    best_priority = thread_priority_i[current_tid];

    // Search for higher-priority runnable thread
    for (int i = 0; i < num_threads_gp; i++) begin
      if (thread_enabled_i[i] && !thread_blocked_i[i]) begin
        if (thread_priority_i[i] > best_priority) begin
          best_tid = i;
          best_priority = thread_priority_i[i];
        end
      end
    end

    return best_tid;
  endfunction

  ///////////////////////////////////////////////////////////////////////////
  // Scheduler Logic (Combinational)
  ///////////////////////////////////////////////////////////////////////////

  always_comb begin
    // Default: continue with current thread
    next_tid_n = current_tid_r;
    instr_count_r = 0;  // TODO: This should be a registered counter

    // Determine next active thread based on scheduler mode
    if (scheduler_mode_i == 8'h01) begin
      // Software override mode: use CSR-specified thread
      next_tid_n = scheduler_override_tid_i;
    end else if (scheduler_mode_i == 8'h02) begin
      // Priority-based scheduling
      next_tid_n = find_next_priority_tid(current_tid_r);
    end else begin
      // Hardware round-robin (mode 0x00)
      // Switch threads if:
      // 1. Current thread is not runnable, OR
      // 2. We've issued enough instructions from this thread
      if (!thread_enabled_i[current_tid_r] || thread_blocked_i[current_tid_r]) begin
        // Current thread not runnable - immediately find next
        next_tid_n = find_next_runnable_tid(current_tid_r);
      end else if (instr_count_r >= MAX_INSTR_PER_THREAD && issue_valid_i) begin
        // Max instructions reached - rotate to next runnable thread
        next_tid_n = find_next_runnable_tid(current_tid_r);
      end
    end
  end

  ///////////////////////////////////////////////////////////////////////////
  // Scheduler State Update (Sequential)
  ///////////////////////////////////////////////////////////////////////////

  always @(posedge clk_i) begin
    if (reset_i) begin
      current_tid_r <= '0;
    end else begin
      // Update current thread
      current_tid_r <= next_tid_n;

      // Update instruction counter (only increments for current thread's instructions)
      if (issue_valid_i && next_tid_n == current_tid_r) begin
        instr_count_r <= instr_count_r + 1;
      end else begin
        // Reset counter when switching threads
        instr_count_r <= '0;
      end
    end
  end

  ///////////////////////////////////////////////////////////////////////////
  // Output Assignments
  ///////////////////////////////////////////////////////////////////////////

  assign active_tid_o = current_tid_r;
  assign next_tid_o = next_tid_n;
  assign scheduler_state_tid_o = current_tid_r;

  ///////////////////////////////////////////////////////////////////////////
  // Assertions (optional, can be disabled)
  ///////////////////////////////////////////////////////////////////////////

  // Check that scheduler produces valid thread IDs
  `ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (!reset_i) begin
      assert(current_tid_r < num_threads_gp)
        else $error("Scheduler produced invalid thread ID: %d", current_tid_r);
      assert(next_tid_n < num_threads_gp)
        else $error("Scheduler next TID out of range: %d", next_tid_n);
    end
  end
  `endif

endmodule
