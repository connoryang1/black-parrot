/**
 * bp_be_csr_wrapper_mt.sv
 *
 * Multi-thread CSR Wrapper
 *
 * Instantiates one bp_be_csr per thread (num_threads_p copies).
 * Presents the same external interface as a single bp_be_csr so it can be
 * used as a drop-in replacement in bp_be_pipe_sys.
 *
 * Gating rules:
 *   retire_pkt, fflags_acc, frf_w_v → retire_thread_id_i's bank
 *   csr_r_v → csr_thread_id_i's reservation bank
 *   IRQ signals (debug/timer/software/external) → all threads (keeps mip current)
 *
 * CSR reads and reservation translation use csr_thread_id_i. Save data uses
 * csr_context_save_physical_thread_id_i; other outputs use the active bank.
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_csr_wrapper_mt
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p, fetch_ptr_p, issue_ptr_p)
   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p)
   , localparam csr_context_csrs_lp = 26
   , localparam csr_context_width_lp = csr_context_csrs_lp*dword_width_gp + rv64_priv_width_gp
   )
  (input                                     clk_i
   , input                                   reset_i

   , input [cfg_bus_width_lp-1:0]            cfg_bus_i

   // CSR check interface
   , input                                   csr_r_v_i
   , input [rv64_csr_addr_width_gp-1:0]      csr_r_addr_i
   , output logic [dword_width_gp-1:0]       csr_r_data_o
   , output logic                            csr_r_illegal_o

   // Misc interface
   , input [retire_pkt_width_lp-1:0]         retire_pkt_i
   , input                                   retire_ctxtsw_v_i
   , input rv64_fflags_s                     fflags_acc_i
   , input                                   frf_w_v_i

   // Interrupts — broadcast to all threads so mip stays current
   , input                                   debug_irq_i
   , input                                   timer_irq_i
   , input                                   software_irq_i
   , input                                   m_external_irq_i
   , input                                   s_external_irq_i
   , output logic                            irq_pending_o
   , output logic                            irq_waiting_o

   // The final commit packet
   , output logic [commit_pkt_width_lp-1:0]  commit_pkt_o

   // Slow signals
   , output logic [decode_info_width_lp-1:0] decode_info_o
   , output logic [trans_info_width_lp-1:0]  trans_info_o
   , output logic [trans_info_width_lp-1:0]  reservation_trans_info_o
   , output rv64_frm_e                       frm_dyn_o

   // Current thread selects the active per-thread CSR instance.
   , input [thread_id_width_p-1:0]           current_physical_thread_id_i
   // Software-visible virtual context ID returned by CSR 0x800.
   , input [context_id_width_p-1:0]          current_virtual_context_id_i
   , input                                   legacy_context_user_enable_i
   // CSR reads belong to the instruction in the reservation station.
   , input [thread_id_width_p-1:0]           csr_thread_id_i
   // Retire thread owns the instruction currently committing in the backend.
   , input [thread_id_width_p-1:0]           retire_thread_id_i
   // Source operand of the CSR instruction currently in the reservation
   // station. Protected-call outcome readback compares it with the live token.
   , input [dword_width_gp-1:0]              rpc_call_token_i

   // Save/restore the active physical CSR bank for nonresident virtual contexts.
   , input                                   csr_context_restore_v_i
   , input                                   csr_context_apc_write_v_i
   , input                                   csr_context_restore_reset_i
   , input [thread_id_width_p-1:0]           csr_context_restore_physical_thread_id_i
   , input [csr_context_width_lp-1:0]        csr_context_restore_data_i
   , input [vaddr_width_p-1:0]               csr_context_restore_npc_i
   , input                                   rpc_context_prepare_v_i
   , input [thread_id_width_p-1:0]           rpc_context_prepare_physical_thread_id_i
   , input [dword_width_gp-1:0]              rpc_context_prepare_satp_i
   , input [vaddr_width_p-1:0]               rpc_context_prepare_entry_i
   , input [thread_id_width_p-1:0]           csr_context_save_physical_thread_id_i
   , output logic [csr_context_width_lp-1:0] csr_context_save_data_o

   // Bootstrap: write target NPC for a virtual context (CSR 0x801)
   , output logic                            ctx_npc_write_v_o
   , output logic                            ctx_npc_write_rebind_o
   , output logic                            ctx_npc_write_rpc_entry_o
   , output logic [context_id_width_p-1:0]   ctx_npc_write_virtual_context_id_o
   , output logic [vaddr_width_p-1:0]        ctx_npc_write_npc_o

   // CSR 0x802 remote register write into a virtual context
   , output logic                            ctx_rpush_v_o
   , output logic                            ctx_rpush_fp_v_o
   , output logic [context_id_width_p-1:0]   ctx_rpush_virtual_context_id_o
   , output logic [reg_addr_width_gp-1:0]    ctx_rpush_reg_o
   , output logic [dpath_width_gp-1:0]       ctx_rpush_data_o

   // Context-cache L1 D$ service CSR path.
   , input                                   ctx_l1_ready_i
   , input                                   ctx_l1_resp_v_i
   , input [dword_width_gp-1:0]              ctx_l1_resp_data_i
   , output logic                            ctx_l1_cmd_v_o
   , output logic                            ctx_l1_cmd_w_o
   , output logic [paddr_width_p-1:0]        ctx_l1_cmd_paddr_o
   , output logic [dword_width_gp-1:0]       ctx_l1_cmd_data_o

   , input [dword_width_gp-1:0]              miss_trace_status_i
   , input [dword_width_gp-1:0]              miss_trace_data_i
   , output logic                            miss_trace_ctrl_v_o
   , output logic                            miss_trace_arm_o
   , output logic                            miss_trace_clear_o
   , output logic                            miss_trace_read_v_o
   , output logic                            miss_trace_read_source_o
   , output logic [7:0]                      miss_trace_read_index_o

   , input                                   icache_replay_ready_i
   , output logic                            icache_replay_v_o
   , output logic [paddr_width_p-1:0]        icache_replay_paddr_o
   , input [dword_width_gp-1:0]              icache_prefix_status_i
   , output logic                            icache_prefix_entry_v_o
   , output logic [7:0]                      icache_prefix_entry_index_o
   , output logic [paddr_width_p-1:0]        icache_prefix_entry_paddr_o
   , output logic                            icache_prefix_count_v_o
   , output logic [8:0]                      icache_prefix_count_o
   , output logic                            icache_prefix_trigger_v_o
   , output logic                            icache_prefix_clear_v_o

   // Core-wide protected-RPC descriptor. Only M-mode CSR 0x7c3/0x7c4
   // accesses mutate this state; publication is atomic at COMMIT.
   , input                                   rpc_active_i
   , input                                   rpc_fault_recovery_i
   , input                                   rpc_prepare_ready_i
   , output logic                            rpc_prepare_v_o
   , output logic [1:0]                      rpc_prepare_component_o
   , output logic [context_id_width_p-1:0]   rpc_prepare_server_context_o
   , output logic [dword_width_gp-1:0]       rpc_prepare_server_satp_o
   , output logic [dword_width_gp-1:0]       rpc_prepare_server_entry_o
   , output logic                            rpc_descriptor_valid_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_token_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_caller_satp_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_server_satp_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_server_entry_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_server_sp_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_server_gp_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_server_tp_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_caller_badge_o
   , output logic [dword_width_gp-1:0]       rpc_descriptor_config_o
   );

  `declare_bp_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p, fetch_ptr_p, issue_ptr_p);
  `bp_cast_i(bp_be_retire_pkt_s, retire_pkt);

  // Per-thread output arrays
  logic [num_threads_p-1:0][dword_width_gp-1:0]       csr_r_data_co;
  logic [num_threads_p-1:0]                            csr_r_illegal_co;
  logic [num_threads_p-1:0][commit_pkt_width_lp-1:0]  commit_pkt_co;
  logic [num_threads_p-1:0][decode_info_width_lp-1:0] decode_info_co;
  logic [num_threads_p-1:0][trans_info_width_lp-1:0]  trans_info_co;
  rv64_frm_e [num_threads_p-1:0]                      frm_dyn_co;
  logic [num_threads_p-1:0]                            irq_pending_co;
  logic [num_threads_p-1:0]                            irq_waiting_co;
  logic [num_threads_p-1:0]                            ctx_npc_write_v_co;
  logic [num_threads_p-1:0]                            ctx_npc_write_rebind_co;
  logic [num_threads_p-1:0]                            ctx_npc_write_rpc_entry_co;
  logic [num_threads_p-1:0][context_id_width_p-1:0]   ctx_npc_write_virtual_context_id_co;
  logic [num_threads_p-1:0][vaddr_width_p-1:0]        ctx_npc_write_npc_co;
  logic [num_threads_p-1:0]                            ctx_rpush_v_co;
  logic [num_threads_p-1:0]                            ctx_rpush_fp_v_co;
  logic [num_threads_p-1:0][context_id_width_p-1:0]   ctx_rpush_virtual_context_id_co;
  logic [num_threads_p-1:0][reg_addr_width_gp-1:0]    ctx_rpush_reg_co;
  logic [num_threads_p-1:0][dpath_width_gp-1:0]       ctx_rpush_data_co;
  logic [num_threads_p-1:0]                            ctx_l1_cmd_v_co;
  logic [num_threads_p-1:0]                            ctx_l1_cmd_w_co;
  logic [num_threads_p-1:0][paddr_width_p-1:0]         ctx_l1_cmd_paddr_co;
  logic [num_threads_p-1:0][dword_width_gp-1:0]        ctx_l1_cmd_data_co;
  logic [num_threads_p-1:0]                            miss_trace_ctrl_v_co;
  logic [num_threads_p-1:0]                            miss_trace_arm_co;
  logic [num_threads_p-1:0]                            miss_trace_clear_co;
  logic [num_threads_p-1:0]                            miss_trace_read_v_co;
  logic [num_threads_p-1:0]                            miss_trace_read_source_co;
  logic [num_threads_p-1:0][7:0]                       miss_trace_read_index_co;
  logic [num_threads_p-1:0]                            icache_replay_v_co;
  logic [num_threads_p-1:0][paddr_width_p-1:0]         icache_replay_paddr_co;
  logic [num_threads_p-1:0]                            icache_prefix_entry_v_co;
  logic [num_threads_p-1:0][7:0]                       icache_prefix_entry_index_co;
  logic [num_threads_p-1:0][paddr_width_p-1:0]         icache_prefix_entry_paddr_co;
  logic [num_threads_p-1:0]                            icache_prefix_count_v_co;
  logic [num_threads_p-1:0][8:0]                       icache_prefix_count_co;
  logic [num_threads_p-1:0]                            icache_prefix_trigger_v_co;
  logic [num_threads_p-1:0]                            icache_prefix_clear_v_co;
  logic [num_threads_p-1:0][csr_context_width_lp-1:0] csr_context_save_data_co;
  logic [num_threads_p-1:0]                            retire_ctxtsw_v_gated;
  logic [num_threads_p-1:0]                            rpc_fault_unwind_co;

  // A core-wide physical timebase for short-latency measurements.  Unlike
  // mcycle, this counter is intentionally absent from the virtual-context
  // save/restore image and therefore never rolls back on a context switch.
  logic [dword_width_gp-1:0] global_cycle_r;
  always_ff @(posedge clk_i)
    if (reset_i)
      global_cycle_r <= '0;
    else
      global_cycle_r <= global_cycle_r + 1'b1;

  // Version-1 descriptor controller. CSR 0x7c3 holds the staging operand;
  // writing CSR 0x7c4 executes one command. A complete nine-field staging
  // image is copied to the live slot in a single edge, so a caller can never
  // observe a partially installed descriptor.
  localparam logic [7:0] rpc_control_stage_lp = 8'd0;
  localparam logic [7:0] rpc_control_commit_lp = 8'd1;
  localparam logic [7:0] rpc_control_revoke_lp = 8'd2;
  localparam logic [7:0] rpc_control_read_status_lp = 8'd3;
  localparam logic [7:0] rpc_control_prepare_lp = 8'd4;
  localparam logic [dword_width_gp-1:0] rpc_status_ok_lp = 64'd0;
  localparam logic [dword_width_gp-1:0] rpc_status_stale_lp = 64'd1;
  localparam logic [dword_width_gp-1:0] rpc_status_busy_lp = 64'd2;
  localparam logic [dword_width_gp-1:0] rpc_status_unsupported_lp = 64'd3;
  localparam logic [dword_width_gp-1:0] rpc_status_invalid_lp = 64'd4;
  localparam logic [dword_width_gp-1:0] rpc_status_faulted_lp = 64'd5;

  logic [dword_width_gp-1:0] rpc_m_data_r, rpc_control_status_r;
  logic [8:0][dword_width_gp-1:0] rpc_staged_field_r;
  logic [8:0] rpc_staged_valid_r;
  logic [8:0][dword_width_gp-1:0] rpc_live_field_r;
  logic rpc_descriptor_valid_r;
  logic rpc_descriptor_faulted_r;
  logic [2:0] rpc_prepared_component_r;
  bp_be_decode_info_s rpc_retire_decode_info;
  assign rpc_retire_decode_info = decode_info_co[retire_thread_id_i];

  wire rpc_machine_csr_write_v = retire_pkt_cast_i.instret
                                 & retire_pkt_cast_i.special.csrw
                                 & rpc_retire_decode_info.m_mode;
  wire [11:0] rpc_csr_addr = retire_pkt_cast_i.instr.t.itype.imm12;
  wire [dword_width_gp-1:0] rpc_csr_data =
    retire_pkt_cast_i.data[0 +: dword_width_gp];
  wire rpc_data_write_v = rpc_machine_csr_write_v & (rpc_csr_addr == 12'h7c3);
  wire rpc_control_write_v = rpc_machine_csr_write_v & (rpc_csr_addr == 12'h7c4);
  wire [7:0] rpc_control_command = rpc_csr_data[63:56];
  wire [7:0] rpc_control_field = rpc_csr_data[55:48];
  wire [31:0] rpc_control_slot = rpc_csr_data[31:0];
  wire rpc_control_reserved_zero = (rpc_csr_data[47:32] == '0);
  wire rpc_control_slot_supported = (rpc_control_slot == 32'd0);

  wire [dword_width_gp-1:0] rpc_staged_config = rpc_staged_field_r[8];
  wire rpc_staged_user_addresses_valid =
    (rpc_staged_field_r[3] != '0)
    & ~rpc_staged_field_r[3][0]
    & (rpc_staged_field_r[3][63:38] == '0)
    & (rpc_staged_field_r[4] != '0)
    & (rpc_staged_field_r[4][3:0] == '0)
    & (rpc_staged_field_r[4][63:38] == '0)
    & (rpc_staged_field_r[5][63:38] == '0)
    & (rpc_staged_field_r[6][63:38] == '0);
  wire rpc_staged_config_valid =
    // Bit 48 opts a version-2 descriptor into synchronous-fault completion.
    // Version 1 writes zero, and every higher bit remains reserved.
    (rpc_staged_config[63:49] == '0)
    & (rpc_staged_config[7:0] <= 8'd4)
    & (rpc_staged_config[15:8] <= 8'd4)
    & (rpc_staged_config[31:16] == 16'd0)
    & (rpc_staged_config[47:32] == 16'd1);
  wire rpc_staged_descriptor_valid = &rpc_staged_valid_r
    & (rpc_staged_field_r[0] != '0)
    & (rpc_staged_field_r[1][63:60] == 4'd8)
    & (rpc_staged_field_r[2][63:60] == 4'd8)
    & (rpc_staged_field_r[1] != rpc_staged_field_r[2])
    & rpc_staged_user_addresses_valid
    & rpc_staged_config_valid;
  wire rpc_prepare_component_valid = (rpc_control_field <= 8'd2);
  wire rpc_prepare_accept = rpc_control_write_v
    & rpc_control_reserved_zero
    & rpc_control_slot_supported
    & (rpc_control_command == rpc_control_prepare_lp)
    & rpc_prepare_component_valid
    & rpc_staged_descriptor_valid
    & ~rpc_descriptor_valid_r
    & ~rpc_active_i
    & rpc_prepare_ready_i;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      rpc_m_data_r <= '0;
      rpc_control_status_r <= rpc_status_unsupported_lp;
      rpc_staged_field_r <= '0;
      rpc_staged_valid_r <= '0;
      rpc_live_field_r <= '0;
      rpc_descriptor_valid_r <= 1'b0;
      rpc_descriptor_faulted_r <= 1'b0;
      rpc_prepared_component_r <= '0;
    end else begin
      if (rpc_data_write_v)
        rpc_m_data_r <= rpc_csr_data;

      if (rpc_control_write_v) begin
        if (!rpc_control_reserved_zero || !rpc_control_slot_supported) begin
          rpc_control_status_r <= rpc_control_slot_supported
                                  ? rpc_status_invalid_lp
                                  : rpc_status_unsupported_lp;
        end else begin
          unique case (rpc_control_command)
            rpc_control_stage_lp: begin
              // Any mutation invalidates preparation derived from the old
              // staged image. The installer must prepare all three pieces
              // after the final field has been staged.
              rpc_prepared_component_r <= '0;
              if (rpc_control_field <= 8'd8) begin
                rpc_staged_field_r[rpc_control_field[3:0]] <= rpc_m_data_r;
                rpc_staged_valid_r[rpc_control_field[3:0]] <= 1'b1;
                rpc_control_status_r <= rpc_status_ok_lp;
              end else begin
                rpc_control_status_r <= rpc_status_invalid_lp;
              end
            end
            rpc_control_commit_lp: begin
              rpc_staged_valid_r <= '0;
              rpc_prepared_component_r <= '0;
              if (rpc_active_i) begin
                rpc_control_status_r <= rpc_status_busy_lp;
              end else if (rpc_descriptor_valid_r) begin
                rpc_control_status_r <= rpc_status_busy_lp;
              end else if (!rpc_staged_descriptor_valid
                           || !(&rpc_prepared_component_r)) begin
                rpc_control_status_r <= rpc_status_invalid_lp;
              end else begin
                rpc_live_field_r <= rpc_staged_field_r;
                rpc_descriptor_valid_r <= 1'b1;
                rpc_descriptor_faulted_r <= 1'b0;
                rpc_control_status_r <= rpc_status_ok_lp;
              end
            end
            rpc_control_revoke_lp: begin
              if (!rpc_descriptor_valid_r
                  || (rpc_m_data_r != rpc_live_field_r[0])) begin
                rpc_control_status_r <= rpc_status_stale_lp;
              end else if (rpc_active_i) begin
                rpc_control_status_r <= rpc_status_busy_lp;
              end else begin
                rpc_descriptor_valid_r <= 1'b0;
                rpc_descriptor_faulted_r <= 1'b0;
                rpc_control_status_r <= rpc_status_ok_lp;
              end
            end
            rpc_control_read_status_lp: begin
              if (!rpc_descriptor_valid_r
                  || (rpc_m_data_r != rpc_live_field_r[0]))
                rpc_control_status_r <= rpc_status_stale_lp;
              else if (rpc_descriptor_faulted_r)
                rpc_control_status_r <= rpc_status_faulted_lp;
              else if (rpc_active_i)
                rpc_control_status_r <= rpc_status_busy_lp;
              else
                rpc_control_status_r <= rpc_status_ok_lp;
            end
            rpc_control_prepare_lp: begin
              if (!rpc_staged_descriptor_valid
                  || !rpc_prepare_component_valid) begin
                rpc_control_status_r <= rpc_status_invalid_lp;
              end else if (rpc_descriptor_valid_r || rpc_active_i
                           || !rpc_prepare_ready_i) begin
                rpc_control_status_r <= rpc_status_busy_lp;
              end else begin
                rpc_prepared_component_r[rpc_control_field[1:0]] <= 1'b1;
                rpc_control_status_r <= rpc_status_ok_lp;
              end
            end
            default: rpc_control_status_r <= rpc_status_unsupported_lp;
          endcase
        end
      end

      if (|rpc_fault_unwind_co)
        rpc_descriptor_faulted_r <= 1'b1;
    end
  end

  assign rpc_prepare_v_o = rpc_prepare_accept;
  assign rpc_prepare_component_o = rpc_control_field[1:0];
  assign rpc_prepare_server_context_o =
    context_id_width_p'(rpc_staged_config[47:32]);
  assign rpc_prepare_server_satp_o = rpc_staged_field_r[2];
  assign rpc_prepare_server_entry_o = rpc_staged_field_r[3];
  assign rpc_descriptor_valid_o = rpc_descriptor_valid_r
                                  & ~rpc_descriptor_faulted_r;
  assign rpc_descriptor_token_o = rpc_live_field_r[0];
  assign rpc_descriptor_caller_satp_o = rpc_live_field_r[1];
  assign rpc_descriptor_server_satp_o = rpc_live_field_r[2];
  assign rpc_descriptor_server_entry_o = rpc_live_field_r[3];
  assign rpc_descriptor_server_sp_o = rpc_live_field_r[4];
  assign rpc_descriptor_server_gp_o = rpc_live_field_r[5];
  assign rpc_descriptor_server_tp_o = rpc_live_field_r[6];
  assign rpc_descriptor_caller_badge_o = rpc_live_field_r[7];
  assign rpc_descriptor_config_o = rpc_live_field_r[8];

  // Per-thread gated inputs
  logic [num_threads_p-1:0]                          csr_r_v_gated;
  logic [num_threads_p-1:0]                          frf_w_v_gated;
  logic [num_threads_p-1:0][retire_pkt_width_lp-1:0] retire_pkt_gated;
  rv64_fflags_s [num_threads_p-1:0]                  fflags_acc_gated;

  for (genvar i = 0; i < num_threads_p; i++) begin : gen_gate
    wire csr_active = (csr_thread_id_i == thread_id_width_p'(i));
    wire retire_active = (retire_thread_id_i == thread_id_width_p'(i));
    assign csr_r_v_gated[i]     = csr_r_v_i & csr_active;
    assign frf_w_v_gated[i]     = frf_w_v_i & retire_active;
    assign retire_pkt_gated[i]  = retire_active ? retire_pkt_i : '0;
    assign retire_ctxtsw_v_gated[i] = retire_ctxtsw_v_i & retire_active;
    assign fflags_acc_gated[i]  = retire_active ? fflags_acc_i : rv64_fflags_s'('0);
  end

  for (genvar i = 0; i < num_threads_p; i++) begin : gen_csr
    bp_be_csr
     #(.bp_params_p(bp_params_p))
     csr_inst
      (.clk_i(clk_i)
       ,.reset_i(reset_i)
       ,.cfg_bus_i(cfg_bus_i)
       ,.global_cycle_i(global_cycle_r)

       ,.csr_r_v_i(csr_r_v_gated[i])
       ,.csr_r_addr_i(csr_r_addr_i)
       ,.csr_r_data_o(csr_r_data_co[i])
       ,.csr_r_illegal_o(csr_r_illegal_co[i])

       ,.retire_pkt_i(retire_pkt_gated[i])
       ,.retire_ctxtsw_v_i(retire_ctxtsw_v_gated[i])
       ,.fflags_acc_i(fflags_acc_gated[i])
       ,.frf_w_v_i(frf_w_v_gated[i])

       ,.debug_irq_i(debug_irq_i)
       ,.timer_irq_i(timer_irq_i)
       ,.software_irq_i(software_irq_i)
       ,.m_external_irq_i(m_external_irq_i)
       ,.s_external_irq_i(s_external_irq_i)
       ,.irq_pending_o(irq_pending_co[i])
       ,.irq_waiting_o(irq_waiting_co[i])

       ,.commit_pkt_o(commit_pkt_co[i])
       ,.decode_info_o(decode_info_co[i])
       ,.trans_info_o(trans_info_co[i])
       ,.frm_dyn_o(frm_dyn_co[i])

       ,.current_physical_thread_id_i(current_physical_thread_id_i)
       ,.current_virtual_context_id_i(current_virtual_context_id_i)
       ,.legacy_context_user_enable_i(legacy_context_user_enable_i)
       ,.csr_context_restore_v_i(csr_context_restore_v_i
                                 & (csr_context_restore_physical_thread_id_i == thread_id_width_p'(i)))
       ,.csr_context_apc_write_v_i(csr_context_apc_write_v_i
                                   & (csr_context_restore_physical_thread_id_i == thread_id_width_p'(i)))
       ,.csr_context_restore_reset_i(csr_context_restore_reset_i)
       ,.csr_context_restore_data_i(csr_context_restore_data_i)
       ,.csr_context_restore_npc_i(csr_context_restore_npc_i)
       ,.rpc_context_prepare_i(rpc_context_prepare_v_i
                               & (rpc_context_prepare_physical_thread_id_i
                                  == thread_id_width_p'(i)))
       ,.rpc_context_prepare_satp_i(rpc_context_prepare_satp_i)
       ,.rpc_context_prepare_entry_i(rpc_context_prepare_entry_i)
       ,.rpc_fault_recovery_i(rpc_fault_recovery_i)
       ,.rpc_fault_unwind_o(rpc_fault_unwind_co[i])
       ,.csr_context_save_data_o(csr_context_save_data_co[i])
       ,.ctx_npc_write_v_o(ctx_npc_write_v_co[i])
       ,.ctx_npc_write_rebind_o(ctx_npc_write_rebind_co[i])
       ,.ctx_npc_write_rpc_entry_o(ctx_npc_write_rpc_entry_co[i])
       ,.ctx_npc_write_virtual_context_id_o(ctx_npc_write_virtual_context_id_co[i])
       ,.ctx_npc_write_npc_o(ctx_npc_write_npc_co[i])

       ,.ctx_rpush_v_o(ctx_rpush_v_co[i])
       ,.ctx_rpush_fp_v_o(ctx_rpush_fp_v_co[i])
       ,.ctx_rpush_virtual_context_id_o(ctx_rpush_virtual_context_id_co[i])
       ,.ctx_rpush_reg_o(ctx_rpush_reg_co[i])
       ,.ctx_rpush_data_o(ctx_rpush_data_co[i])
       ,.ctx_l1_ready_i(ctx_l1_ready_i)
       ,.ctx_l1_resp_v_i(ctx_l1_resp_v_i & (current_physical_thread_id_i == thread_id_width_p'(i)))
       ,.ctx_l1_resp_data_i(ctx_l1_resp_data_i)
       ,.ctx_l1_cmd_v_o(ctx_l1_cmd_v_co[i])
       ,.ctx_l1_cmd_w_o(ctx_l1_cmd_w_co[i])
       ,.ctx_l1_cmd_paddr_o(ctx_l1_cmd_paddr_co[i])
       ,.ctx_l1_cmd_data_o(ctx_l1_cmd_data_co[i])
       ,.miss_trace_status_i(miss_trace_status_i)
       ,.miss_trace_data_i(miss_trace_data_i)
       ,.miss_trace_ctrl_v_o(miss_trace_ctrl_v_co[i])
       ,.miss_trace_arm_o(miss_trace_arm_co[i])
       ,.miss_trace_clear_o(miss_trace_clear_co[i])
       ,.miss_trace_read_v_o(miss_trace_read_v_co[i])
       ,.miss_trace_read_source_o(miss_trace_read_source_co[i])
       ,.miss_trace_read_index_o(miss_trace_read_index_co[i])
       ,.icache_replay_ready_i(icache_replay_ready_i)
       ,.icache_replay_v_o(icache_replay_v_co[i])
       ,.icache_replay_paddr_o(icache_replay_paddr_co[i])
       ,.icache_prefix_status_i(icache_prefix_status_i)
       ,.icache_prefix_entry_v_o(icache_prefix_entry_v_co[i])
       ,.icache_prefix_entry_index_o(icache_prefix_entry_index_co[i])
       ,.icache_prefix_entry_paddr_o(icache_prefix_entry_paddr_co[i])
       ,.icache_prefix_count_v_o(icache_prefix_count_v_co[i])
       ,.icache_prefix_count_o(icache_prefix_count_co[i])
       ,.icache_prefix_trigger_v_o(icache_prefix_trigger_v_co[i])
       ,.icache_prefix_clear_v_o(icache_prefix_clear_v_co[i])
       ,.rpc_m_data_i(rpc_m_data_r)
       ,.rpc_m_control_status_i(rpc_control_status_r)
       ,.rpc_call_token_i(rpc_call_token_i)
       ,.rpc_descriptor_valid_i(rpc_descriptor_valid_r
                                 & ~rpc_descriptor_faulted_r)
       ,.rpc_descriptor_token_i(rpc_live_field_r[0])
       );
  end

  // Select each output using its architectural owner.
  assign csr_r_data_o          = csr_r_data_co[csr_thread_id_i];
  assign csr_r_illegal_o       = csr_r_illegal_co[csr_thread_id_i];
  assign commit_pkt_o          = commit_pkt_co[current_physical_thread_id_i];
  assign decode_info_o         = decode_info_co[current_physical_thread_id_i];
  assign trans_info_o          = trans_info_co[current_physical_thread_id_i];
  assign reservation_trans_info_o = trans_info_co[csr_thread_id_i];
  assign frm_dyn_o             = frm_dyn_co[current_physical_thread_id_i];
  assign irq_pending_o         = irq_pending_co[current_physical_thread_id_i];
  assign irq_waiting_o         = irq_waiting_co[current_physical_thread_id_i];
  assign ctx_npc_write_v_o     = ctx_npc_write_v_co[current_physical_thread_id_i];
  assign ctx_npc_write_rebind_o = ctx_npc_write_rebind_co[current_physical_thread_id_i];
  assign ctx_npc_write_rpc_entry_o = ctx_npc_write_rpc_entry_co[current_physical_thread_id_i];
  assign ctx_npc_write_virtual_context_id_o   = ctx_npc_write_virtual_context_id_co[current_physical_thread_id_i];
  assign ctx_npc_write_npc_o   = ctx_npc_write_npc_co[current_physical_thread_id_i];
  assign ctx_rpush_v_o         = ctx_rpush_v_co[current_physical_thread_id_i];
  assign ctx_rpush_fp_v_o      = ctx_rpush_fp_v_co[current_physical_thread_id_i];
  assign ctx_rpush_virtual_context_id_o       = ctx_rpush_virtual_context_id_co[current_physical_thread_id_i];
  assign ctx_rpush_reg_o       = ctx_rpush_reg_co[current_physical_thread_id_i];
  assign ctx_rpush_data_o      = ctx_rpush_data_co[current_physical_thread_id_i];
  assign ctx_l1_cmd_v_o        = ctx_l1_cmd_v_co[current_physical_thread_id_i];
  assign ctx_l1_cmd_w_o        = ctx_l1_cmd_w_co[current_physical_thread_id_i];
  assign ctx_l1_cmd_paddr_o    = ctx_l1_cmd_paddr_co[current_physical_thread_id_i];
  assign ctx_l1_cmd_data_o     = ctx_l1_cmd_data_co[current_physical_thread_id_i];
  assign miss_trace_ctrl_v_o   = miss_trace_ctrl_v_co[retire_thread_id_i];
  assign miss_trace_arm_o      = miss_trace_arm_co[retire_thread_id_i];
  assign miss_trace_clear_o    = miss_trace_clear_co[retire_thread_id_i];
  assign miss_trace_read_v_o   = miss_trace_read_v_co[retire_thread_id_i];
  assign miss_trace_read_source_o = miss_trace_read_source_co[retire_thread_id_i];
  assign miss_trace_read_index_o = miss_trace_read_index_co[retire_thread_id_i];
  assign icache_replay_v_o = icache_replay_v_co[retire_thread_id_i];
  assign icache_replay_paddr_o = icache_replay_paddr_co[retire_thread_id_i];
  assign icache_prefix_entry_v_o = icache_prefix_entry_v_co[retire_thread_id_i];
  assign icache_prefix_entry_index_o = icache_prefix_entry_index_co[retire_thread_id_i];
  assign icache_prefix_entry_paddr_o = icache_prefix_entry_paddr_co[retire_thread_id_i];
  assign icache_prefix_count_v_o = icache_prefix_count_v_co[retire_thread_id_i];
  assign icache_prefix_count_o = icache_prefix_count_co[retire_thread_id_i];
  assign icache_prefix_trigger_v_o = icache_prefix_trigger_v_co[retire_thread_id_i];
  assign icache_prefix_clear_v_o = icache_prefix_clear_v_co[retire_thread_id_i];
  assign csr_context_save_data_o = csr_context_save_data_co[csr_context_save_physical_thread_id_i];

endmodule

`BSG_ABSTRACT_MODULE(bp_be_csr_wrapper_mt)
