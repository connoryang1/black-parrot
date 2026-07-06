/**
 *
 *  Name:
 *    bp_be_top.v
 *
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_top
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_core_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p)
   `declare_bp_be_if_widths(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p, fetch_ptr_p, issue_ptr_p)
   `declare_bp_be_dcache_engine_if_widths(paddr_width_p, dcache_tag_width_p, dcache_sets_p, dcache_assoc_p, dword_width_gp, dcache_block_width_p, dcache_fill_width_p, dcache_req_id_width_p)

   // Default parameters
   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p)
   , localparam csr_context_csrs_lp = 26
   , localparam csr_context_width_lp = csr_context_csrs_lp*dword_width_gp + rv64_priv_width_gp
  )
  (input                                             clk_i
   , input                                           reset_i

   // Processor configuration
   , input [cfg_bus_width_lp-1:0]                    cfg_bus_i

   // FE queue interface
   , input [fe_queue_width_lp-1:0]                   fe_queue_i
   , input                                           fe_queue_v_i
   , output logic                                    fe_queue_ready_and_o

   // FE cmd interface
   , output logic [fe_cmd_width_lp-1:0]              fe_cmd_o
   , output logic                                    fe_cmd_v_o
   , input                                           fe_cmd_yumi_i
   , input                                           fe_ctxtsw_ready_i
   , output logic                                    fe_ctxtsw_v_o
   , input                                           fe_ctxtsw_yumi_i
   , output logic [vaddr_width_p-1:0]                fe_ctxtsw_npc_o
   , output logic [thread_id_width_p-1:0]            fe_ctxtsw_thread_id_o
   , output logic [rv64_priv_width_gp-1:0]           fe_ctxtsw_priv_o
   , output logic                                    fe_ctxtsw_translation_en_o
   , output logic [asid_width_p-1:0]                 fe_ctxtsw_asid_o

   // D$-LCE Interface
   // signals to LCE
   , output logic [dcache_req_width_lp-1:0]          cache_req_o
   , output logic                                    cache_req_v_o
   , input                                           cache_req_yumi_i
   , input                                           cache_req_lock_i
   , output logic [dcache_req_metadata_width_lp-1:0] cache_req_metadata_o
   , output logic                                    cache_req_metadata_v_o
   , input [dcache_req_id_width_p-1:0]               cache_req_id_i
   , input                                           cache_req_critical_i
   , input                                           cache_req_last_i
   , input                                           cache_req_credits_full_i
   , input                                           cache_req_credits_empty_i

   // tag_mem
   , input                                           tag_mem_pkt_v_i
   , input [dcache_tag_mem_pkt_width_lp-1:0]         tag_mem_pkt_i
   , output logic [dcache_tag_info_width_lp-1:0]     tag_mem_o
   , output logic                                    tag_mem_pkt_yumi_o

   // data_mem
   , input                                           data_mem_pkt_v_i
   , input [dcache_data_mem_pkt_width_lp-1:0]        data_mem_pkt_i
   , output logic [dcache_block_width_p-1:0]         data_mem_o
   , output logic                                    data_mem_pkt_yumi_o

   // stat_mem
   , input                                           stat_mem_pkt_v_i
   , input [dcache_stat_mem_pkt_width_lp-1:0]        stat_mem_pkt_i
   , output logic [dcache_stat_info_width_lp-1:0]    stat_mem_o
   , output logic                                    stat_mem_pkt_yumi_o

   , input                                           debug_irq_i
   , input                                           timer_irq_i
   , input                                           software_irq_i
   , input                                           m_external_irq_i
   , input                                           s_external_irq_i
   );

  // Declare parameterized structures
  `declare_bp_common_if(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p);
  `declare_bp_core_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_be_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p, fetch_ptr_p, issue_ptr_p);
  `bp_cast_i(bp_cfg_bus_s, cfg_bus);

  // Top-level interface connections
  bp_be_dispatch_pkt_s dispatch_pkt;
  bp_be_branch_pkt_s   br_pkt;

  logic ordered_v, hazard_v, ispec_v;
  logic irq_pending_lo, irq_waiting_lo;

  bp_be_commit_pkt_s commit_pkt;
  bp_be_wb_pkt_s iwb_pkt, fwb_pkt;
  bp_be_decode_info_s decode_info_lo;
  bp_be_trans_info_s trans_info_lo;

  // Multi-threaded context storage signals
  logic [vaddr_width_p-1:0] context_npc_lo;
  logic [1:0] context_priv_mode_lo;
  logic context_translation_en_lo;
  logic [asid_width_p-1:0] context_asid_lo;
  logic [vaddr_width_p-1:0] ctxtsw_target_npc_lo;
  logic [1:0] ctxtsw_target_priv_mode_lo;
  logic ctxtsw_target_translation_en_lo;
  logic [asid_width_p-1:0] ctxtsw_target_asid_lo;
  logic pending_ctxtsw_v_r;
  logic pending_ctxtsw_sent_r;
  logic ctxtsw_launch_pending_r;
  enum logic [2:0] {
    e_ctxtsw_idle
    ,e_ctxtsw_prepared
    ,e_ctxtsw_launched
    ,e_ctxtsw_finalized
    ,e_ctxtsw_canceled
  } spec_ctxtsw_state_r;
  enum logic [3:0] {
    e_context_cache_idle
    ,e_context_cache_wait_ctxtsw_commit
    ,e_context_cache_wait_drain
    ,e_context_cache_save_restore_regs
    ,e_context_cache_save_restore_regs_tail
    ,e_context_cache_save_restore_fp_regs
    ,e_context_cache_save_restore_fp_regs_tail
    ,e_context_cache_save_npc
    ,e_context_cache_restore_npc
    ,e_context_cache_install_slot
    ,e_context_cache_launch_fe
    ,e_context_cache_done
  } context_cache_state_r;
  logic [thread_id_width_p-1:0] pending_ctxtsw_prev_thread_id_r;
  logic [context_id_width_p-1:0] pending_ctxtsw_context_id_r;
  logic [thread_id_width_p-1:0] pending_ctxtsw_thread_id_r;
  logic [vaddr_width_p-1:0] pending_ctxtsw_resume_npc_r;
  logic [vaddr_width_p-1:0] pending_ctxtsw_npc_r;
  logic [1:0] pending_ctxtsw_priv_mode_r;
  logic pending_ctxtsw_translation_en_r;
  logic [asid_width_p-1:0] pending_ctxtsw_asid_r;
  logic ctxtsw_launch_lo;
  logic [num_contexts_p-1:0] logical_context_resident_v_r;
  logic [num_contexts_p-1:0][thread_id_width_p-1:0] logical_context_slot_r;
  logic [num_threads_p-1:0][context_id_width_p-1:0] resident_thread_context_id_r;
  logic [context_id_width_p-1:0] current_context_id_r;
  logic [thread_id_width_p-1:0] current_thread_id_lo;
  logic fast_ctxtsw_v_lo;
  logic [thread_id_width_p-1:0] fast_ctxtsw_old_thread_id_lo;
  logic [context_id_width_p-1:0] fast_ctxtsw_context_id_lo;
  logic [thread_id_width_p-1:0] fast_ctxtsw_thread_id_lo;
  logic [vaddr_width_p-1:0] fast_ctxtsw_resume_npc_lo;
  logic [vaddr_width_p-1:0] fast_ctxtsw_target_npc_lo;
  logic [1:0] fast_ctxtsw_target_priv_mode_lo;
  logic fast_ctxtsw_target_translation_en_lo;
  logic [asid_width_p-1:0] fast_ctxtsw_target_asid_lo;
  logic context_cache_miss_pending_r;
  logic [context_id_width_p-1:0] context_cache_target_context_id_r;
  logic [context_id_width_p-1:0] context_cache_victim_context_id_r;
  logic [thread_id_width_p-1:0] context_cache_victim_thread_id_r;
  logic [vaddr_width_p-1:0] context_cache_resume_npc_r;
  logic [15:0] context_cache_state_cycles_r;
  logic [dword_width_gp-1:0] context_cache_miss_count_r;
  logic context_cache_int_restore_phase_r;
  logic context_cache_fp_restore_phase_r;
  logic [num_threads_p-1:0][vaddr_width_p-1:0] context_npc_r;
  logic [num_threads_p-1:0][1:0] context_priv_mode_r;
  logic [num_threads_p-1:0] context_translation_en_r;
  logic [num_threads_p-1:0][asid_width_p-1:0] context_asid_r;
  logic [num_contexts_p-1:0][vaddr_width_p-1:0] logical_context_npc_r;
  logic [num_contexts_p-1:0][1:0] logical_context_priv_mode_r;
  logic [num_contexts_p-1:0] logical_context_translation_en_r;
  logic [num_contexts_p-1:0][asid_width_p-1:0] logical_context_asid_r;
  logic [num_contexts_p-1:0] logical_context_csr_valid_r;
  logic [num_contexts_p-1:0][csr_context_width_lp-1:0] logical_context_csr_state_r;
  logic [num_threads_p-1:0][(2**reg_addr_width_gp)-1:0] resident_thread_fp_dirty_r;
  logic [num_contexts_p-1:0][(2**reg_addr_width_gp)-1:0] logical_context_fp_dirty_r;
  logic [num_threads_p-1:0][(2**reg_addr_width_gp)-1:0] resident_thread_int_dirty_r;
  logic [num_contexts_p-1:0][(2**reg_addr_width_gp)-1:0] logical_context_int_dirty_r;
  logic [(2**reg_addr_width_gp)-1:0] context_cache_int_save_mask_r, context_cache_int_restore_mask_r;
  logic [(2**reg_addr_width_gp)-1:0] context_cache_fp_save_mask_r, context_cache_fp_restore_mask_r;
  logic [thread_id_width_p-1:0] retire_thread_id_lo;

  logic [wb_pkt_width_lp-1:0] late_wb_pkt;
  logic late_wb_v_lo, late_wb_force_lo, late_wb_yumi_li;

  bp_be_issue_pkt_s issue_pkt;
  logic [vaddr_width_p-1:0] expected_npc_lo;
  logic npc_mismatch_lo, poison_isd_lo, clear_iss_lo, suppress_iss_lo, resume_lo;

  logic cmd_full_n_lo, cmd_full_r_lo, cmd_empty_n_lo, cmd_empty_r_lo;
  logic mem_ordered_lo, mem_busy_lo, idiv_busy_lo, fdiv_busy_lo;
  logic ctxtsw_target_resident_v_li;
  logic [thread_id_width_p-1:0] ctxtsw_target_thread_id_li;
  logic fast_ctxtsw_resident_v_li;
  logic context_cache_miss_v_li;
  logic [context_id_width_p-1:0] context_cache_miss_context_id_li;
  logic [vaddr_width_p-1:0] context_cache_miss_resume_npc_li;
  logic context_cache_commit_v_li;
  logic context_cache_launch_v_li;
  logic context_cache_active_li;
  logic context_cache_scheduler_drain_ready_lo;
  logic context_cache_calculator_drain_ready_lo;
  logic context_cache_drain_safe_li;
  logic [1:0] context_cache_scan_r_v_li;
  logic [1:0] context_cache_scan_w_v_li;
  logic [thread_id_width_p-1:0] context_cache_scan_thread_id_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_scan_r_addr_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_scan_w_addr_li;
  logic [1:0][dpath_width_gp-1:0] context_cache_scan_w_data_li;
  logic [1:0][dpath_width_gp-1:0] context_cache_scan_r_data_lo;
  logic [1:0] context_cache_fp_scan_r_v_li;
  logic [1:0] context_cache_fp_scan_w_v_li;
  logic [thread_id_width_p-1:0] context_cache_fp_scan_thread_id_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_fp_scan_r_addr_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_fp_scan_w_addr_li;
  logic [1:0][dpath_width_gp-1:0] context_cache_fp_scan_w_data_li;
  logic [1:0][dpath_width_gp-1:0] context_cache_fp_scan_r_data_lo;
  logic [1:0] context_cache_scan_save_v_r;
  logic [1:0] context_cache_fp_scan_save_v_r;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_scan_save_idx_r;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_fp_scan_save_idx_r;
  logic [num_contexts_p-1:0][(2**reg_addr_width_gp)-1:0][dpath_width_gp-1:0] context_cache_int_shadow_r;
  logic [num_contexts_p-1:0][(2**reg_addr_width_gp)-1:0][dpath_width_gp-1:0] context_cache_fp_shadow_r;
  logic ctx_npc_write_resident_v_li;
  logic [thread_id_width_p-1:0] ctx_npc_write_thread_id_li;
  logic ctx_rpush_resident_v_li;
  logic [thread_id_width_p-1:0] ctx_rpush_thread_id_li;
  logic scheduler_rpush_v_li;
  logic scheduler_rpush_fp_v_li;
  logic [(2**reg_addr_width_gp)-1:0] context_cache_victim_fp_dirty_li, context_cache_target_fp_dirty_li;
  logic context_cache_fp_copy_v_li;
  logic [1:0] context_cache_int_save_pick_v_li, context_cache_int_restore_pick_v_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_int_save_pick_addr_li, context_cache_int_restore_pick_addr_li;
  logic [1:0] context_cache_fp_save_pick_v_li, context_cache_fp_restore_pick_v_li;
  logic [1:0][reg_addr_width_gp-1:0] context_cache_fp_save_pick_addr_li, context_cache_fp_restore_pick_addr_li;
  logic [(2**reg_addr_width_gp)-1:0] context_cache_int_save_mask_n_li, context_cache_int_restore_mask_n_li;
  logic [(2**reg_addr_width_gp)-1:0] context_cache_fp_save_mask_n_li, context_cache_fp_restore_mask_n_li;
  logic context_cache_int_save_done_n_li, context_cache_int_restore_done_n_li;
  logic context_cache_fp_save_done_n_li, context_cache_fp_restore_done_n_li;
  logic [csr_context_width_lp-1:0] csr_context_save_data_lo;
  wire [thread_id_width_p-1:0] csr_context_save_thread_id_li =
    context_cache_commit_v_li
    ? context_cache_victim_thread_id_r
    : pending_ctxtsw_sent_r ? pending_ctxtsw_prev_thread_id_r : current_thread_id_lo;
  wire csr_context_restore_v_li = context_cache_state_r == e_context_cache_launch_fe;
  wire csr_context_restore_reset_li =
    ~logical_context_csr_valid_r[context_cache_target_context_id_r];
  wire [csr_context_width_lp-1:0] csr_context_restore_data_li =
    logical_context_csr_state_r[context_cache_target_context_id_r];
  localparam int reg_count_lp = 2**reg_addr_width_gp;
  wire ctxtsw_token_create_v_li = fast_ctxtsw_v_lo
                                  & fast_ctxtsw_resident_v_li
                                  & ~cfg_bus_cast_i.freeze
                                  & ~commit_pkt.resume;
  wire ctxtsw_token_finalize_v_li = commit_pkt.ctxtsw;
  wire ctxtsw_token_cancel_v_li = cfg_bus_cast_i.freeze | commit_pkt.resume | (commit_pkt.npc_w_v & ~commit_pkt.ctxtsw);
  wire ctxtsw_token_clear_v_li = ctxtsw_token_cancel_v_li | ctxtsw_token_finalize_v_li;
  wire ctxtsw_capture_v_li = ctxtsw_token_create_v_li;
  wire fast_ctxtsw_launch_v_li = ctxtsw_token_create_v_li
                                  & fe_ctxtsw_ready_i
                                  & ~pending_ctxtsw_v_r;
  assign context_cache_commit_v_li = commit_pkt.ctxtsw & context_cache_miss_pending_r;
  assign context_cache_launch_v_li = context_cache_state_r == e_context_cache_launch_fe;
  assign context_cache_active_li = context_cache_state_r != e_context_cache_idle;
  assign context_cache_drain_safe_li = context_cache_calculator_drain_ready_lo
                                       & ~dispatch_pkt.v
                                       & ~late_wb_v_lo
                                       & ~(iwb_pkt.ird_w_v | fwb_pkt.frd_w_v)
                                       & ~mem_busy_lo
                                       & mem_ordered_lo
                                       & ~idiv_busy_lo
                                       & ~fdiv_busy_lo;
  always_comb begin
    int save_cnt;
    int restore_cnt;

    context_cache_int_save_pick_v_li = '0;
    context_cache_int_save_pick_addr_li = '0;
    context_cache_int_restore_pick_v_li = '0;
    context_cache_int_restore_pick_addr_li = '0;
    save_cnt = 0;
    restore_cnt = 0;
    for (int i = 0; i < reg_count_lp; i++) begin
      if (context_cache_int_save_mask_r[i] && (save_cnt < 2)) begin
        context_cache_int_save_pick_v_li[save_cnt] = 1'b1;
        context_cache_int_save_pick_addr_li[save_cnt] = reg_addr_width_gp'(i);
        save_cnt++;
      end
      if (context_cache_int_restore_mask_r[i] && (restore_cnt < 2)) begin
        context_cache_int_restore_pick_v_li[restore_cnt] = 1'b1;
        context_cache_int_restore_pick_addr_li[restore_cnt] = reg_addr_width_gp'(i);
        restore_cnt++;
      end
    end
  end

  always_comb begin
    int save_cnt;
    int restore_cnt;

    context_cache_fp_save_pick_v_li = '0;
    context_cache_fp_save_pick_addr_li = '0;
    context_cache_fp_restore_pick_v_li = '0;
    context_cache_fp_restore_pick_addr_li = '0;
    save_cnt = 0;
    restore_cnt = 0;
    for (int i = 0; i < reg_count_lp; i++) begin
      if (context_cache_fp_save_mask_r[i] && (save_cnt < 2)) begin
        context_cache_fp_save_pick_v_li[save_cnt] = 1'b1;
        context_cache_fp_save_pick_addr_li[save_cnt] = reg_addr_width_gp'(i);
        save_cnt++;
      end
      if (context_cache_fp_restore_mask_r[i] && (restore_cnt < 2)) begin
        context_cache_fp_restore_pick_v_li[restore_cnt] = 1'b1;
        context_cache_fp_restore_pick_addr_li[restore_cnt] = reg_addr_width_gp'(i);
        restore_cnt++;
      end
    end
  end

  always_comb begin
    context_cache_int_save_mask_n_li = context_cache_int_save_mask_r;
    context_cache_int_restore_mask_n_li = context_cache_int_restore_mask_r;
    for (int i = 0; i < 2; i++) begin
      if (context_cache_int_save_pick_v_li[i])
        context_cache_int_save_mask_n_li[context_cache_int_save_pick_addr_li[i]] = 1'b0;
      if (context_cache_int_restore_pick_v_li[i])
        context_cache_int_restore_mask_n_li[context_cache_int_restore_pick_addr_li[i]] = 1'b0;
    end
  end

  always_comb begin
    context_cache_fp_save_mask_n_li = context_cache_fp_save_mask_r;
    context_cache_fp_restore_mask_n_li = context_cache_fp_restore_mask_r;
    for (int i = 0; i < 2; i++) begin
      if (context_cache_fp_save_pick_v_li[i])
        context_cache_fp_save_mask_n_li[context_cache_fp_save_pick_addr_li[i]] = 1'b0;
      if (context_cache_fp_restore_pick_v_li[i])
        context_cache_fp_restore_mask_n_li[context_cache_fp_restore_pick_addr_li[i]] = 1'b0;
    end
  end

  assign context_cache_int_save_done_n_li = ~(|context_cache_int_save_mask_n_li);
  assign context_cache_int_restore_done_n_li = ~(|context_cache_int_restore_mask_n_li);
  assign context_cache_fp_save_done_n_li = ~(|context_cache_fp_save_mask_n_li);
  assign context_cache_fp_restore_done_n_li = ~(|context_cache_fp_restore_mask_n_li);

  assign context_cache_scan_r_v_li = context_cache_int_save_pick_v_li
                                     & {2{context_cache_state_r == e_context_cache_save_restore_regs}}
                                     & {2{~context_cache_int_restore_phase_r}};
  assign context_cache_scan_w_v_li = context_cache_int_restore_pick_v_li
                                     & {2{context_cache_state_r == e_context_cache_save_restore_regs}}
                                     & {2{context_cache_int_restore_phase_r}};
  assign context_cache_scan_thread_id_li = context_cache_victim_thread_id_r;
  assign context_cache_scan_r_addr_li = context_cache_int_save_pick_addr_li;
  assign context_cache_scan_w_addr_li = context_cache_int_restore_pick_addr_li;
  assign context_cache_scan_w_data_li[0] =
    logical_context_int_dirty_r[context_cache_target_context_id_r][context_cache_scan_w_addr_li[0]]
    ? context_cache_int_shadow_r[context_cache_target_context_id_r][context_cache_scan_w_addr_li[0]]
    : '0;
  assign context_cache_scan_w_data_li[1] =
    logical_context_int_dirty_r[context_cache_target_context_id_r][context_cache_scan_w_addr_li[1]]
    ? context_cache_int_shadow_r[context_cache_target_context_id_r][context_cache_scan_w_addr_li[1]]
    : '0;
  assign context_cache_fp_scan_r_v_li = context_cache_fp_save_pick_v_li
                                        & {2{context_cache_state_r == e_context_cache_save_restore_fp_regs}}
                                        & {2{~context_cache_fp_restore_phase_r}};
  assign context_cache_fp_scan_w_v_li = context_cache_fp_restore_pick_v_li
                                        & {2{context_cache_state_r == e_context_cache_save_restore_fp_regs}}
                                        & {2{context_cache_fp_restore_phase_r}};
  assign context_cache_fp_scan_thread_id_li = context_cache_victim_thread_id_r;
  assign context_cache_fp_scan_r_addr_li = context_cache_fp_save_pick_addr_li;
  assign context_cache_fp_scan_w_addr_li = context_cache_fp_restore_pick_addr_li;
  assign context_cache_fp_scan_w_data_li[0] =
    logical_context_fp_dirty_r[context_cache_target_context_id_r][context_cache_fp_scan_w_addr_li[0]]
    ? context_cache_fp_shadow_r[context_cache_target_context_id_r][context_cache_fp_scan_w_addr_li[0]]
    : '0;
  assign context_cache_fp_scan_w_data_li[1] =
    logical_context_fp_dirty_r[context_cache_target_context_id_r][context_cache_fp_scan_w_addr_li[1]]
    ? context_cache_fp_shadow_r[context_cache_target_context_id_r][context_cache_fp_scan_w_addr_li[1]]
    : '0;
  assign retire_thread_id_lo = pending_ctxtsw_sent_r ? pending_ctxtsw_prev_thread_id_r : current_thread_id_lo;
  wire [thread_id_width_p-1:0] scheduler_current_thread_id_li =
    (commit_pkt.ctxtsw & pending_ctxtsw_sent_r) ? pending_ctxtsw_thread_id_r : current_thread_id_lo;

  always_comb begin
    ctx_npc_write_resident_v_li = 1'b0;
    ctx_npc_write_thread_id_li = '0;
    if (ctx_npc_write_v_lo && (ctx_npc_write_tid_lo < num_contexts_p)) begin
      ctx_npc_write_resident_v_li = logical_context_resident_v_r[ctx_npc_write_tid_lo];
      ctx_npc_write_thread_id_li = logical_context_slot_r[ctx_npc_write_tid_lo];
    end
  end

  always_comb begin
    ctx_rpush_resident_v_li = 1'b0;
    ctx_rpush_thread_id_li = '0;
    if ((ctx_rpush_v_lo | ctx_rpush_fp_v_lo) && (ctx_rpush_tid_lo < num_contexts_p)) begin
      ctx_rpush_resident_v_li = logical_context_resident_v_r[ctx_rpush_tid_lo];
      ctx_rpush_thread_id_li = logical_context_slot_r[ctx_rpush_tid_lo];
    end
  end

  assign scheduler_rpush_v_li = ctx_rpush_v_lo & ctx_rpush_resident_v_li;
  assign scheduler_rpush_fp_v_li = ctx_rpush_fp_v_lo & ctx_rpush_resident_v_li;

  assign fe_ctxtsw_v_o = context_cache_launch_v_li | fast_ctxtsw_launch_v_li | ctxtsw_launch_lo;
  assign fe_ctxtsw_npc_o = context_cache_launch_v_li
                            ? logical_context_npc_r[context_cache_target_context_id_r]
                            : fast_ctxtsw_launch_v_li ? fast_ctxtsw_target_npc_lo : pending_ctxtsw_npc_r;
  assign fe_ctxtsw_thread_id_o = context_cache_launch_v_li
                                  ? context_cache_victim_thread_id_r
                                  : fast_ctxtsw_launch_v_li ? fast_ctxtsw_thread_id_lo : pending_ctxtsw_thread_id_r;
  assign fe_ctxtsw_priv_o = context_cache_launch_v_li
                             ? logical_context_priv_mode_r[context_cache_target_context_id_r]
                             : fast_ctxtsw_launch_v_li ? fast_ctxtsw_target_priv_mode_lo : pending_ctxtsw_priv_mode_r;
  assign fe_ctxtsw_translation_en_o = context_cache_launch_v_li
                                      ? logical_context_translation_en_r[context_cache_target_context_id_r]
                                      : fast_ctxtsw_launch_v_li
                                      ? fast_ctxtsw_target_translation_en_lo
                                      : pending_ctxtsw_translation_en_r;
  assign fe_ctxtsw_asid_o = context_cache_launch_v_li
                             ? logical_context_asid_r[context_cache_target_context_id_r]
                             : fast_ctxtsw_launch_v_li ? fast_ctxtsw_target_asid_lo : pending_ctxtsw_asid_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      for (int i = 0; i < num_contexts_p; i++) begin
        logical_context_resident_v_r[i] <= (i < num_threads_p);
        logical_context_slot_r[i] <= thread_id_width_p'(i);
      end
      for (int i = 0; i < num_threads_p; i++)
        resident_thread_context_id_r[i] <= context_id_width_p'(i);
    end else if (context_cache_state_r == e_context_cache_launch_fe) begin
      logical_context_resident_v_r[context_cache_victim_context_id_r] <= 1'b0;
      logical_context_resident_v_r[context_cache_target_context_id_r] <= 1'b1;
      logical_context_slot_r[context_cache_target_context_id_r] <= context_cache_victim_thread_id_r;
      resident_thread_context_id_r[context_cache_victim_thread_id_r] <= context_cache_target_context_id_r;
    end
  end

  // Bootstrap: write a target NPC for a logical context (CSR 0x082)
  logic ctx_npc_write_v_lo;
  logic [context_id_width_p-1:0] ctx_npc_write_tid_lo;
  logic [vaddr_width_p-1:0] ctx_npc_write_npc_lo;

  // CSR 0x083 remote register write into a logical context
  logic ctx_rpush_v_lo;
  logic ctx_rpush_fp_v_lo;
  logic [context_id_width_p-1:0] ctx_rpush_tid_lo;
  logic [reg_addr_width_gp-1:0] ctx_rpush_reg_lo;
  logic [dpath_width_gp-1:0] ctx_rpush_data_lo;

  // Active hardware thread ID selected by CTXT CSR writes.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      current_thread_id_lo <= '0;
      current_context_id_r <= '0;
    end
    else if (context_cache_state_r == e_context_cache_launch_fe) begin
      current_thread_id_lo <= context_cache_victim_thread_id_r;
      current_context_id_r <= context_cache_target_context_id_r;
    end
    else if (commit_pkt.npc_w_v & ~commit_pkt.ctxtsw & pending_ctxtsw_v_r)
      current_thread_id_lo <= pending_ctxtsw_prev_thread_id_r;
    else if (commit_pkt.ctxtsw & pending_ctxtsw_v_r) begin
      current_thread_id_lo <= pending_ctxtsw_thread_id_r;
      current_context_id_r <= pending_ctxtsw_context_id_r;
    end
  end

  // Stage a prepared ctxtsw target bundle when ctxtsw is first classified in the BE.
  // This is not yet consumed by the FE restart path, but it gives the first-class
  // ctxtsw flow an explicit latched handoff state to build on.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      pending_ctxtsw_v_r <= 1'b0;
      pending_ctxtsw_sent_r <= 1'b0;
      ctxtsw_launch_pending_r <= 1'b0;
      spec_ctxtsw_state_r <= e_ctxtsw_idle;
      pending_ctxtsw_prev_thread_id_r <= '0;
      pending_ctxtsw_context_id_r <= '0;
      pending_ctxtsw_thread_id_r <= '0;
      pending_ctxtsw_resume_npc_r <= '0;
      pending_ctxtsw_npc_r <= '0;
      pending_ctxtsw_priv_mode_r <= 2'b11;
      pending_ctxtsw_translation_en_r <= 1'b0;
      pending_ctxtsw_asid_r <= '0;
    end else begin
      if (ctxtsw_token_clear_v_li) begin
        pending_ctxtsw_v_r <= 1'b0;
        pending_ctxtsw_sent_r <= 1'b0;
        ctxtsw_launch_pending_r <= 1'b0;
        spec_ctxtsw_state_r <= ctxtsw_token_finalize_v_li ? e_ctxtsw_finalized : e_ctxtsw_canceled;
      end

      if (ctxtsw_capture_v_li) begin
        pending_ctxtsw_v_r <= 1'b1;
        pending_ctxtsw_sent_r <= 1'b0;
        ctxtsw_launch_pending_r <= 1'b1;
        spec_ctxtsw_state_r <= e_ctxtsw_prepared;
        pending_ctxtsw_prev_thread_id_r <= fast_ctxtsw_old_thread_id_lo;
        pending_ctxtsw_context_id_r <= fast_ctxtsw_context_id_lo;
        pending_ctxtsw_thread_id_r <= fast_ctxtsw_thread_id_lo;
        pending_ctxtsw_resume_npc_r <= fast_ctxtsw_resume_npc_lo;
        pending_ctxtsw_npc_r <= fast_ctxtsw_target_npc_lo;
        pending_ctxtsw_priv_mode_r <= fast_ctxtsw_target_priv_mode_lo;
        pending_ctxtsw_translation_en_r <= fast_ctxtsw_target_translation_en_lo;
        pending_ctxtsw_asid_r <= fast_ctxtsw_target_asid_lo;
      end

      if (ctxtsw_launch_lo)
        spec_ctxtsw_state_r <= e_ctxtsw_launched;

      if (fe_ctxtsw_yumi_i && !context_cache_launch_v_li) begin
        pending_ctxtsw_sent_r <= 1'b1;
        ctxtsw_launch_pending_r <= 1'b0;
        spec_ctxtsw_state_r <= e_ctxtsw_launched;
      end
    end
  end

  // Per-thread context storage for resume state.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      for (int i = 0; i < num_threads_p; i++) begin
        context_npc_r[i] <= '0;
        context_priv_mode_r[i] <= 2'b11;
        context_translation_en_r[i] <= 1'b0;
        context_asid_r[i] <= '0;
      end
      for (int i = 0; i < num_contexts_p; i++) begin
        logical_context_npc_r[i] <= '0;
        logical_context_priv_mode_r[i] <= 2'b11;
        logical_context_translation_en_r[i] <= 1'b0;
        logical_context_asid_r[i] <= '0;
        logical_context_csr_valid_r[i] <= 1'b0;
        logical_context_csr_state_r[i] <= '0;
      end
    end else begin
      if (commit_pkt.ctxtsw) begin
        logic [thread_id_width_p-1:0] save_thread_id_li;
        logic [context_id_width_p-1:0] save_context_id_li;
        logic [vaddr_width_p-1:0] save_resume_npc_li;
        save_thread_id_li = context_cache_commit_v_li
                            ? context_cache_victim_thread_id_r
                            : pending_ctxtsw_prev_thread_id_r;
        save_context_id_li = context_cache_commit_v_li
                             ? context_cache_victim_context_id_r
                             : current_context_id_r;
        save_resume_npc_li = context_cache_commit_v_li
                             ? context_cache_resume_npc_r
                             : pending_ctxtsw_resume_npc_r;

        if (save_thread_id_li < num_threads_p) begin
          context_npc_r[save_thread_id_li] <= save_resume_npc_li;
          context_priv_mode_r[save_thread_id_li] <= commit_pkt.priv_n;
          context_translation_en_r[save_thread_id_li] <= commit_pkt.translation_en_n;
          context_asid_r[save_thread_id_li] <= trans_info_lo.asid;
        end

        if (save_context_id_li < num_contexts_p) begin
          logical_context_npc_r[save_context_id_li] <= save_resume_npc_li;
          logical_context_priv_mode_r[save_context_id_li] <= commit_pkt.priv_n;
          logical_context_translation_en_r[save_context_id_li] <= commit_pkt.translation_en_n;
          logical_context_asid_r[save_context_id_li] <= trans_info_lo.asid;
          logical_context_csr_state_r[save_context_id_li] <= csr_context_save_data_lo;
          logical_context_csr_valid_r[save_context_id_li] <= 1'b1;
        end
      end

      if (ctx_npc_write_v_lo && (ctx_npc_write_tid_lo < num_contexts_p)) begin
        logical_context_npc_r[ctx_npc_write_tid_lo] <= ctx_npc_write_npc_lo;
        logical_context_priv_mode_r[ctx_npc_write_tid_lo] <= commit_pkt.priv_n;
        logical_context_translation_en_r[ctx_npc_write_tid_lo] <= commit_pkt.translation_en_n;
        logical_context_asid_r[ctx_npc_write_tid_lo] <= trans_info_lo.asid;

        if (ctx_npc_write_resident_v_li && (ctx_npc_write_thread_id_li < num_threads_p)) begin
          context_npc_r[ctx_npc_write_thread_id_li] <= ctx_npc_write_npc_lo;
          context_priv_mode_r[ctx_npc_write_thread_id_li] <= commit_pkt.priv_n;
          context_translation_en_r[ctx_npc_write_thread_id_li] <= commit_pkt.translation_en_n;
          context_asid_r[ctx_npc_write_thread_id_li] <= trans_info_lo.asid;
        end
      end

      if (context_cache_state_r == e_context_cache_launch_fe) begin
        context_npc_r[context_cache_victim_thread_id_r]
          <= logical_context_npc_r[context_cache_target_context_id_r];
        context_priv_mode_r[context_cache_victim_thread_id_r]
          <= logical_context_priv_mode_r[context_cache_target_context_id_r];
        context_translation_en_r[context_cache_victim_thread_id_r]
          <= logical_context_translation_en_r[context_cache_target_context_id_r];
        context_asid_r[context_cache_victim_thread_id_r]
          <= logical_context_asid_r[context_cache_target_context_id_r];
      end
    end
  end

  wire [thread_id_width_p-1:0] context_read_thread_id_li =
    commit_pkt.ctxtsw
    ? (context_cache_commit_v_li ? current_thread_id_lo : pending_ctxtsw_thread_id_r)
    : current_thread_id_lo;
  wire [thread_id_width_p-1:0] context_write_thread_id_li =
    ctx_npc_write_resident_v_li ? ctx_npc_write_thread_id_li
    : commit_pkt.ctxtsw ? pending_ctxtsw_prev_thread_id_r
    : current_thread_id_lo;
  wire context_fwd_v = (commit_pkt.ctxtsw | ctx_npc_write_resident_v_li)
                       && (context_write_thread_id_li == context_read_thread_id_li)
                       && (context_write_thread_id_li < num_threads_p)
                       && (context_read_thread_id_li < num_threads_p);
  wire [context_id_width_p-1:0] ctxtsw_target_context_id_li = dispatch_pkt.ctxtsw_target_tid;
  wire [thread_id_width_p-1:0] fast_ctxtsw_target_thread_id_li = fast_ctxtsw_thread_id_lo;
  wire ctxtsw_target_fwd_v =
    ctx_npc_write_v_lo
    && (ctx_npc_write_tid_lo == ctxtsw_target_context_id_li)
    && (ctx_npc_write_tid_lo < num_contexts_p)
    && ctxtsw_target_resident_v_li
    && (ctxtsw_target_thread_id_li < num_threads_p);
  wire fast_ctxtsw_target_fwd_v =
    ctx_npc_write_v_lo
    && (ctx_npc_write_tid_lo == fast_ctxtsw_context_id_lo)
    && (ctx_npc_write_tid_lo < num_contexts_p)
    && fast_ctxtsw_resident_v_li
    && (fast_ctxtsw_target_thread_id_li < num_threads_p);

  always_comb begin
    ctxtsw_target_resident_v_li = 1'b0;
    ctxtsw_target_thread_id_li = '0;
    if (ctxtsw_target_context_id_li < num_contexts_p) begin
      ctxtsw_target_resident_v_li = logical_context_resident_v_r[ctxtsw_target_context_id_li];
      ctxtsw_target_thread_id_li = logical_context_slot_r[ctxtsw_target_context_id_li];
    end
  end

  always_comb begin
    fast_ctxtsw_resident_v_li = 1'b0;
    fast_ctxtsw_thread_id_lo = '0;
    if (fast_ctxtsw_context_id_lo < num_contexts_p) begin
      fast_ctxtsw_resident_v_li = logical_context_resident_v_r[fast_ctxtsw_context_id_lo];
      fast_ctxtsw_thread_id_lo = logical_context_slot_r[fast_ctxtsw_context_id_lo];
    end
  end

  assign context_cache_victim_fp_dirty_li = resident_thread_fp_dirty_r[context_cache_victim_thread_id_r];
  assign context_cache_target_fp_dirty_li = logical_context_fp_dirty_r[context_cache_target_context_id_r];
  assign context_cache_fp_copy_v_li = (|context_cache_victim_fp_dirty_li)
                                      | (|context_cache_target_fp_dirty_li);

  always_comb begin
    context_cache_miss_v_li = 1'b0;
    context_cache_miss_context_id_li = '0;
    context_cache_miss_resume_npc_li = '0;

    if (fast_ctxtsw_v_lo && !fast_ctxtsw_resident_v_li) begin
      context_cache_miss_v_li = 1'b1;
      context_cache_miss_context_id_li = fast_ctxtsw_context_id_lo;
      context_cache_miss_resume_npc_li = fast_ctxtsw_resume_npc_lo;
    end else if (dispatch_pkt.ctxtsw_v && !ctxtsw_target_resident_v_li) begin
      context_cache_miss_v_li = 1'b1;
      context_cache_miss_context_id_li = ctxtsw_target_context_id_li;
      context_cache_miss_resume_npc_li = dispatch_pkt.pc + (dispatch_pkt.size << 1'b1);
    end
  end

  // Passive context-cache FSM skeleton. The first active implementation will
  // replace the unsupported nonresident fatal with this FSM's save/restore path.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      context_cache_state_r <= e_context_cache_idle;
      context_cache_miss_pending_r <= 1'b0;
      context_cache_target_context_id_r <= '0;
      context_cache_victim_context_id_r <= '0;
      context_cache_victim_thread_id_r <= '0;
      context_cache_resume_npc_r <= '0;
      context_cache_state_cycles_r <= '0;
      context_cache_miss_count_r <= '0;
      context_cache_int_restore_phase_r <= 1'b0;
      context_cache_fp_restore_phase_r <= 1'b0;
      context_cache_scan_save_v_r <= '0;
      context_cache_fp_scan_save_v_r <= '0;
      context_cache_scan_save_idx_r <= '0;
      context_cache_fp_scan_save_idx_r <= '0;
      context_cache_int_save_mask_r <= '0;
      context_cache_int_restore_mask_r <= '0;
      context_cache_fp_save_mask_r <= '0;
      context_cache_fp_restore_mask_r <= '0;
      resident_thread_fp_dirty_r <= '0;
      logical_context_fp_dirty_r <= '0;
      resident_thread_int_dirty_r <= '0;
      logical_context_int_dirty_r <= '0;
      for (int i = 0; i < num_contexts_p; i++)
        for (int j = 0; j < 2**reg_addr_width_gp; j++) begin
          context_cache_int_shadow_r[i][j] <= '0;
          context_cache_fp_shadow_r[i][j] <= '0;
        end
    end else begin
      context_cache_state_cycles_r <= (context_cache_state_r == e_context_cache_idle)
                                      ? '0
                                      : context_cache_state_cycles_r + 16'd1;
      context_cache_scan_save_v_r <= context_cache_scan_r_v_li;
      context_cache_fp_scan_save_v_r <= context_cache_fp_scan_r_v_li;
      context_cache_scan_save_idx_r[0] <= context_cache_scan_r_addr_li[0];
      context_cache_scan_save_idx_r[1] <= context_cache_scan_r_addr_li[1];
      context_cache_fp_scan_save_idx_r[0] <= context_cache_fp_scan_r_addr_li[0];
      context_cache_fp_scan_save_idx_r[1] <= context_cache_fp_scan_r_addr_li[1];
      if (context_cache_scan_save_v_r[0])
        context_cache_int_shadow_r[context_cache_victim_context_id_r][context_cache_scan_save_idx_r[0]]
          <= context_cache_scan_r_data_lo[0];
      if (context_cache_scan_save_v_r[1])
        context_cache_int_shadow_r[context_cache_victim_context_id_r][context_cache_scan_save_idx_r[1]]
          <= context_cache_scan_r_data_lo[1];
      if (context_cache_fp_scan_save_v_r[0])
        context_cache_fp_shadow_r[context_cache_victim_context_id_r][context_cache_fp_scan_save_idx_r[0]]
          <= context_cache_fp_scan_r_data_lo[0];
      if (context_cache_fp_scan_save_v_r[1])
        context_cache_fp_shadow_r[context_cache_victim_context_id_r][context_cache_fp_scan_save_idx_r[1]]
          <= context_cache_fp_scan_r_data_lo[1];
      if (ctx_rpush_v_lo && !ctx_rpush_resident_v_li && (ctx_rpush_tid_lo < num_contexts_p)) begin
        context_cache_int_shadow_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= ctx_rpush_data_lo;
        if (ctx_rpush_reg_lo != '0)
          logical_context_int_dirty_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= 1'b1;
      end
      if (ctx_rpush_v_lo && ctx_rpush_resident_v_li && (ctx_rpush_tid_lo < num_contexts_p)) begin
        if (ctx_rpush_reg_lo != '0) begin
          logical_context_int_dirty_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= 1'b1;
          resident_thread_int_dirty_r[ctx_rpush_thread_id_li][ctx_rpush_reg_lo] <= 1'b1;
        end
      end
      if (ctx_rpush_fp_v_lo && !ctx_rpush_resident_v_li && (ctx_rpush_tid_lo < num_contexts_p)) begin
        context_cache_fp_shadow_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= ctx_rpush_data_lo;
        logical_context_fp_dirty_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= 1'b1;
      end
      if (ctx_rpush_fp_v_lo && ctx_rpush_resident_v_li && (ctx_rpush_tid_lo < num_contexts_p)) begin
        logical_context_fp_dirty_r[ctx_rpush_tid_lo][ctx_rpush_reg_lo] <= 1'b1;
        resident_thread_fp_dirty_r[ctx_rpush_thread_id_li][ctx_rpush_reg_lo] <= 1'b1;
      end
      if (fwb_pkt.frd_w_v && (fwb_pkt.thread_id < num_threads_p)) begin
        resident_thread_fp_dirty_r[fwb_pkt.thread_id][fwb_pkt.rd_addr] <= 1'b1;
        if (resident_thread_context_id_r[fwb_pkt.thread_id] < num_contexts_p)
          logical_context_fp_dirty_r[resident_thread_context_id_r[fwb_pkt.thread_id]][fwb_pkt.rd_addr] <= 1'b1;
      end
      if (iwb_pkt.ird_w_v && (iwb_pkt.thread_id < num_threads_p) && (iwb_pkt.rd_addr != '0)) begin
        resident_thread_int_dirty_r[iwb_pkt.thread_id][iwb_pkt.rd_addr] <= 1'b1;
        if (resident_thread_context_id_r[iwb_pkt.thread_id] < num_contexts_p)
          logical_context_int_dirty_r[resident_thread_context_id_r[iwb_pkt.thread_id]][iwb_pkt.rd_addr] <= 1'b1;
      end
      if (context_cache_state_r == e_context_cache_launch_fe) begin
        resident_thread_fp_dirty_r[context_cache_victim_thread_id_r]
          <= logical_context_fp_dirty_r[context_cache_target_context_id_r];
        resident_thread_int_dirty_r[context_cache_victim_thread_id_r]
          <= logical_context_int_dirty_r[context_cache_target_context_id_r];
      end

      unique case (context_cache_state_r)
        e_context_cache_idle: begin
          context_cache_int_restore_phase_r <= 1'b0;
          context_cache_fp_restore_phase_r <= 1'b0;
          context_cache_int_save_mask_r <= '0;
          context_cache_int_restore_mask_r <= '0;
          context_cache_fp_save_mask_r <= '0;
          context_cache_fp_restore_mask_r <= '0;
          if (context_cache_miss_v_li) begin
            context_cache_state_r <= e_context_cache_wait_ctxtsw_commit;
            context_cache_miss_pending_r <= 1'b1;
            context_cache_target_context_id_r <= context_cache_miss_context_id_li;
            context_cache_victim_context_id_r <= current_context_id_r;
            context_cache_victim_thread_id_r <= current_thread_id_lo;
            context_cache_resume_npc_r <= context_cache_miss_resume_npc_li;
            context_cache_miss_count_r <= context_cache_miss_count_r + dword_width_gp'(1);
          end
        end

        e_context_cache_wait_ctxtsw_commit:
          context_cache_state_r <= commit_pkt.ctxtsw
                                   ? e_context_cache_wait_drain
                                   : context_cache_state_r;

        e_context_cache_wait_drain: begin
          context_cache_int_restore_phase_r <= 1'b0;
          context_cache_fp_restore_phase_r <= 1'b0;
          context_cache_int_save_mask_r <= resident_thread_int_dirty_r[context_cache_victim_thread_id_r];
          context_cache_int_restore_mask_r <= resident_thread_int_dirty_r[context_cache_victim_thread_id_r]
                                              | logical_context_int_dirty_r[context_cache_target_context_id_r];
          context_cache_fp_save_mask_r <= resident_thread_fp_dirty_r[context_cache_victim_thread_id_r];
          context_cache_fp_restore_mask_r <= resident_thread_fp_dirty_r[context_cache_victim_thread_id_r]
                                             | logical_context_fp_dirty_r[context_cache_target_context_id_r];
          context_cache_state_r <= context_cache_drain_safe_li
                                   ? ((!context_cache_fp_copy_v_li)
                                      && !((|resident_thread_int_dirty_r[context_cache_victim_thread_id_r])
                                           || (|logical_context_int_dirty_r[context_cache_target_context_id_r])
                                           || (|resident_thread_fp_dirty_r[context_cache_victim_thread_id_r])
                                           || (|logical_context_fp_dirty_r[context_cache_target_context_id_r]))
                                      ? e_context_cache_launch_fe
                                      : e_context_cache_save_restore_regs)
                                   : context_cache_state_r;
        end

        e_context_cache_save_restore_regs: begin
          if (!context_cache_int_restore_phase_r) begin
            context_cache_int_save_mask_r <= context_cache_int_save_mask_n_li;
            if (context_cache_int_save_done_n_li)
              context_cache_int_restore_phase_r <= 1'b1;
            context_cache_state_r <= context_cache_int_save_done_n_li
                                     ? (context_cache_int_restore_done_n_li
                                        ? ((|context_cache_fp_save_mask_r | |context_cache_fp_restore_mask_r)
                                           ? e_context_cache_save_restore_fp_regs
                                           : e_context_cache_save_restore_regs_tail)
                                        : context_cache_state_r)
                                     : context_cache_state_r;
          end else begin
            context_cache_int_restore_mask_r <= context_cache_int_restore_mask_n_li;
            context_cache_state_r <= context_cache_int_restore_done_n_li
                                     ? ((|context_cache_fp_save_mask_r | |context_cache_fp_restore_mask_r)
                                        ? e_context_cache_save_restore_fp_regs
                                        : e_context_cache_save_restore_regs_tail)
                                     : context_cache_state_r;
          end
        end

        e_context_cache_save_restore_fp_regs: begin
          if (!context_cache_fp_restore_phase_r) begin
            context_cache_fp_save_mask_r <= context_cache_fp_save_mask_n_li;
            if (context_cache_fp_save_done_n_li)
              context_cache_fp_restore_phase_r <= 1'b1;
            context_cache_state_r <= context_cache_fp_save_done_n_li
                                     ? (context_cache_fp_restore_done_n_li
                                        ? e_context_cache_save_restore_fp_regs_tail
                                        : context_cache_state_r)
                                     : context_cache_state_r;
          end else begin
            context_cache_fp_restore_mask_r <= context_cache_fp_restore_mask_n_li;
            context_cache_state_r <= context_cache_fp_restore_done_n_li
                                     ? e_context_cache_save_restore_fp_regs_tail
                                     : context_cache_state_r;
          end
        end

        e_context_cache_save_restore_regs_tail:
          context_cache_state_r <= e_context_cache_launch_fe;

        e_context_cache_save_restore_fp_regs_tail:
          context_cache_state_r <= e_context_cache_save_restore_regs_tail;

        e_context_cache_save_npc: begin
          context_cache_state_r <= e_context_cache_launch_fe;
        end

        e_context_cache_restore_npc:
          context_cache_state_r <= e_context_cache_launch_fe;

        e_context_cache_install_slot:
          context_cache_state_r <= e_context_cache_launch_fe;

        e_context_cache_launch_fe:
          context_cache_state_r <= fe_ctxtsw_yumi_i
                                   ? e_context_cache_done
                                   : context_cache_state_r;

        e_context_cache_done: begin
          context_cache_state_r <= e_context_cache_idle;
          context_cache_miss_pending_r <= 1'b0;
        end

        default:
          context_cache_state_r <= e_context_cache_idle;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!reset_i
        && context_cache_miss_v_li
        && context_cache_active_li
        && (context_cache_miss_context_id_li != context_cache_target_context_id_r))
      $fatal(1, "Nested nonresident context switch target %0d is not supported", context_cache_miss_context_id_li);
  end
`endif

  always_comb begin
    if (context_cache_commit_v_li) begin
      context_npc_lo = logical_context_npc_r[context_cache_target_context_id_r];
      context_priv_mode_lo = logical_context_priv_mode_r[context_cache_target_context_id_r];
      context_translation_en_lo = logical_context_translation_en_r[context_cache_target_context_id_r];
      context_asid_lo = logical_context_asid_r[context_cache_target_context_id_r];
    end else if (context_fwd_v) begin
      context_npc_lo = ctx_npc_write_v_lo ? ctx_npc_write_npc_lo : commit_pkt.npc;
      context_priv_mode_lo = commit_pkt.priv_n;
      context_translation_en_lo = commit_pkt.translation_en_n;
      context_asid_lo = trans_info_lo.asid;
    end else if (context_read_thread_id_li < num_threads_p) begin
      context_npc_lo = context_npc_r[context_read_thread_id_li];
      context_priv_mode_lo = context_priv_mode_r[context_read_thread_id_li];
      context_translation_en_lo = context_translation_en_r[context_read_thread_id_li];
      context_asid_lo = context_asid_r[context_read_thread_id_li];
    end else begin
      context_npc_lo = '0;
      context_priv_mode_lo = 2'b11;
      context_translation_en_lo = 1'b0;
      context_asid_lo = '0;
    end
  end

  always_comb begin
    if (ctxtsw_target_fwd_v) begin
      ctxtsw_target_npc_lo = ctx_npc_write_npc_lo;
      ctxtsw_target_priv_mode_lo = commit_pkt.priv_n;
      ctxtsw_target_translation_en_lo = commit_pkt.translation_en_n;
      ctxtsw_target_asid_lo = trans_info_lo.asid;
    end else if (ctxtsw_target_resident_v_li && (ctxtsw_target_thread_id_li < num_threads_p)) begin
      ctxtsw_target_npc_lo = context_npc_r[ctxtsw_target_thread_id_li];
      ctxtsw_target_priv_mode_lo = context_priv_mode_r[ctxtsw_target_thread_id_li];
      ctxtsw_target_translation_en_lo = context_translation_en_r[ctxtsw_target_thread_id_li];
      ctxtsw_target_asid_lo = context_asid_r[ctxtsw_target_thread_id_li];
    end else begin
      ctxtsw_target_npc_lo = '0;
      ctxtsw_target_priv_mode_lo = 2'b11;
      ctxtsw_target_translation_en_lo = 1'b0;
      ctxtsw_target_asid_lo = '0;
    end
  end

  always_comb begin
    if (fast_ctxtsw_target_fwd_v) begin
      fast_ctxtsw_target_npc_lo = ctx_npc_write_npc_lo;
      fast_ctxtsw_target_priv_mode_lo = commit_pkt.priv_n;
      fast_ctxtsw_target_translation_en_lo = commit_pkt.translation_en_n;
      fast_ctxtsw_target_asid_lo = trans_info_lo.asid;
    end else if (fast_ctxtsw_resident_v_li && (fast_ctxtsw_target_thread_id_li < num_threads_p)) begin
      fast_ctxtsw_target_npc_lo = context_npc_r[fast_ctxtsw_target_thread_id_li];
      fast_ctxtsw_target_priv_mode_lo = context_priv_mode_r[fast_ctxtsw_target_thread_id_li];
      fast_ctxtsw_target_translation_en_lo = context_translation_en_r[fast_ctxtsw_target_thread_id_li];
      fast_ctxtsw_target_asid_lo = context_asid_r[fast_ctxtsw_target_thread_id_li];
    end else begin
      fast_ctxtsw_target_npc_lo = '0;
      fast_ctxtsw_target_priv_mode_lo = 2'b11;
      fast_ctxtsw_target_translation_en_lo = 1'b0;
      fast_ctxtsw_target_asid_lo = '0;
    end
  end

  bp_be_director
   #(.bp_params_p(bp_params_p))
   director
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.cfg_bus_i(cfg_bus_i)
     ,.context_npc_i(context_npc_lo)
     ,.current_thread_id_i(current_thread_id_lo)
     ,.context_asid_i(context_asid_lo)
     ,.context_priv_i(context_priv_mode_lo)
     ,.context_translation_en_i(context_translation_en_lo)
     ,.dispatch_ctxtsw_v_i(dispatch_pkt.ctxtsw_v)
     ,.dispatch_ctxtsw_target_npc_i(ctxtsw_target_npc_lo)
     ,.dispatch_ctxtsw_target_thread_id_i(ctxtsw_target_thread_id_li)
     ,.dispatch_ctxtsw_target_asid_i(ctxtsw_target_asid_lo)
     ,.dispatch_ctxtsw_target_priv_i(ctxtsw_target_priv_mode_lo)
     ,.dispatch_ctxtsw_target_translation_en_i(ctxtsw_target_translation_en_lo)
     ,.pending_ctxtsw_v_i(pending_ctxtsw_v_r)
     ,.pending_ctxtsw_sent_i(pending_ctxtsw_sent_r | context_cache_miss_pending_r)
     ,.ctxtsw_launch_pending_i(ctxtsw_launch_pending_r)
     ,.ctxtsw_target_npc_i(pending_ctxtsw_npc_r)
     ,.ctxtsw_target_thread_id_i(pending_ctxtsw_thread_id_r)
     ,.ctxtsw_target_asid_i(pending_ctxtsw_asid_r)
     ,.ctxtsw_target_priv_i(pending_ctxtsw_priv_mode_r)
     ,.ctxtsw_target_translation_en_i(pending_ctxtsw_translation_en_r)
     ,.fe_ctxtsw_ready_i(fe_ctxtsw_ready_i)
     ,.ctxtsw_launch_o(ctxtsw_launch_lo)

     ,.issue_pkt_i(issue_pkt)
     ,.expected_npc_o(expected_npc_lo)

     ,.fe_cmd_o(fe_cmd_o)
     ,.fe_cmd_v_o(fe_cmd_v_o)
     ,.fe_cmd_yumi_i(fe_cmd_yumi_i)

     ,.resume_o(resume_lo)
     ,.poison_isd_o(poison_isd_lo)
     ,.clear_iss_o(clear_iss_lo)
     ,.suppress_iss_o(suppress_iss_lo)
     ,.irq_waiting_i(irq_waiting_lo)
     ,.mem_busy_i(mem_busy_lo)
     ,.cmd_full_n_o(cmd_full_n_lo)
     ,.cmd_full_r_o(cmd_full_r_lo)

     ,.br_pkt_i(br_pkt)
     ,.commit_pkt_i(commit_pkt)
     );

  bp_be_detector
   #(.bp_params_p(bp_params_p))
   detector
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.issue_pkt_i(issue_pkt)
     ,.cmd_full_i(cmd_full_r_lo)
     ,.credits_full_i(cache_req_credits_full_i)
     ,.credits_empty_i(cache_req_credits_empty_i)
     ,.mem_busy_i(mem_busy_lo)
     ,.mem_ordered_i(mem_ordered_lo)
     ,.fdiv_busy_i(fdiv_busy_lo)
     ,.idiv_busy_i(idiv_busy_lo)
     ,.current_thread_id_i(scheduler_current_thread_id_li)
     ,.retire_thread_id_i(retire_thread_id_lo)
     ,.ispec_v_o(ispec_v)
     ,.hazard_v_o(hazard_v)
     ,.ordered_v_o(ordered_v)
     ,.dispatch_pkt_i(dispatch_pkt)
     ,.commit_pkt_i(commit_pkt)

     ,.late_wb_pkt_i(late_wb_pkt)
     ,.late_wb_yumi_i(late_wb_yumi_li)
     );

  bp_be_scheduler
   #(.bp_params_p(bp_params_p))
   scheduler
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.poison_isd_i(poison_isd_lo)
     ,.resume_i(resume_lo)
     ,.decode_info_i(decode_info_lo)
     ,.trans_info_i(trans_info_lo)
     ,.issue_pkt_o(issue_pkt)
     ,.suppress_iss_i(suppress_iss_lo | context_cache_active_li)
     ,.clear_iss_i(clear_iss_lo)
     ,.expected_npc_i(expected_npc_lo)
     ,.hazard_v_i(hazard_v)
     ,.ispec_v_i(ispec_v)
     ,.irq_pending_i(irq_pending_lo)
     ,.ordered_v_i(ordered_v)
     ,.pending_ctxtsw_sent_i(pending_ctxtsw_sent_r | context_cache_active_li)

     ,.fe_queue_i(fe_queue_i)
     ,.fe_queue_v_i(fe_queue_v_i)
     ,.fe_queue_ready_and_o(fe_queue_ready_and_o)

     ,.dispatch_pkt_o(dispatch_pkt)
     ,.commit_pkt_i(commit_pkt)
     ,.iwb_pkt_i(iwb_pkt)
     ,.fwb_pkt_i(fwb_pkt)

     ,.late_wb_pkt_i(late_wb_pkt)
     ,.late_wb_v_i(late_wb_v_lo)
     ,.late_wb_force_i(late_wb_force_lo)
     ,.late_wb_yumi_o(late_wb_yumi_li)

     ,.current_thread_id_i(scheduler_current_thread_id_li)
     ,.current_context_id_i(current_context_id_r)
     ,.retire_thread_id_i(retire_thread_id_lo)

     ,.rpush_w_v_i(scheduler_rpush_v_li)
     ,.rpush_fp_w_v_i(scheduler_rpush_fp_v_li)
     ,.rpush_tid_i(ctx_rpush_thread_id_li)
     ,.rpush_reg_i(ctx_rpush_reg_lo)
     ,.rpush_data_i(ctx_rpush_data_lo)
     ,.context_cache_scan_r_v_i(context_cache_scan_r_v_li)
     ,.context_cache_scan_w_v_i(context_cache_scan_w_v_li)
     ,.context_cache_scan_thread_id_i(context_cache_scan_thread_id_li)
     ,.context_cache_scan_r_addr_i(context_cache_scan_r_addr_li)
     ,.context_cache_scan_w_addr_i(context_cache_scan_w_addr_li)
     ,.context_cache_scan_w_data_i(context_cache_scan_w_data_li)
     ,.context_cache_scan_r_data_o(context_cache_scan_r_data_lo)
     ,.context_cache_fp_scan_r_v_i(context_cache_fp_scan_r_v_li)
     ,.context_cache_fp_scan_w_v_i(context_cache_fp_scan_w_v_li)
     ,.context_cache_fp_scan_thread_id_i(context_cache_fp_scan_thread_id_li)
     ,.context_cache_fp_scan_r_addr_i(context_cache_fp_scan_r_addr_li)
     ,.context_cache_fp_scan_w_addr_i(context_cache_fp_scan_w_addr_li)
     ,.context_cache_fp_scan_w_data_i(context_cache_fp_scan_w_data_li)
     ,.context_cache_fp_scan_r_data_o(context_cache_fp_scan_r_data_lo)
     ,.context_cache_drain_ready_o(context_cache_scheduler_drain_ready_lo)
     );

  bp_be_calculator_top
   #(.bp_params_p(bp_params_p))
   calculator
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.cfg_bus_i(cfg_bus_i)

     ,.decode_info_o(decode_info_lo)
     ,.trans_info_o(trans_info_lo)
     ,.mem_busy_o(mem_busy_lo)
     ,.mem_ordered_o(mem_ordered_lo)
     ,.idiv_busy_o(idiv_busy_lo)
     ,.fdiv_busy_o(fdiv_busy_lo)

     ,.dispatch_pkt_i(dispatch_pkt)
     ,.br_pkt_o(br_pkt)
     ,.commit_pkt_o(commit_pkt)
     ,.iwb_pkt_o(iwb_pkt)
     ,.fwb_pkt_o(fwb_pkt)

     ,.late_wb_pkt_o(late_wb_pkt)
     ,.late_wb_v_o(late_wb_v_lo)
     ,.late_wb_force_o(late_wb_force_lo)
     ,.late_wb_yumi_i(late_wb_yumi_li)

     ,.cache_req_o(cache_req_o)
     ,.cache_req_metadata_o(cache_req_metadata_o)
     ,.cache_req_v_o(cache_req_v_o)
     ,.cache_req_yumi_i(cache_req_yumi_i)
     ,.cache_req_lock_i(cache_req_lock_i)
     ,.cache_req_metadata_v_o(cache_req_metadata_v_o)
     ,.cache_req_id_i(cache_req_id_i)
     ,.cache_req_critical_i(cache_req_critical_i)
     ,.cache_req_last_i(cache_req_last_i)
     ,.cache_req_credits_full_i(cache_req_credits_full_i)
     ,.cache_req_credits_empty_i(cache_req_credits_empty_i)

     ,.tag_mem_pkt_v_i(tag_mem_pkt_v_i)
     ,.tag_mem_pkt_i(tag_mem_pkt_i)
     ,.tag_mem_o(tag_mem_o)
     ,.tag_mem_pkt_yumi_o(tag_mem_pkt_yumi_o)

     ,.data_mem_pkt_v_i(data_mem_pkt_v_i)
     ,.data_mem_pkt_i(data_mem_pkt_i)
     ,.data_mem_o(data_mem_o)
     ,.data_mem_pkt_yumi_o(data_mem_pkt_yumi_o)

     ,.stat_mem_pkt_v_i(stat_mem_pkt_v_i)
     ,.stat_mem_pkt_i(stat_mem_pkt_i)
     ,.stat_mem_o(stat_mem_o)
     ,.stat_mem_pkt_yumi_o(stat_mem_pkt_yumi_o)

     ,.debug_irq_i(debug_irq_i)
     ,.timer_irq_i(timer_irq_i)
     ,.software_irq_i(software_irq_i)
     ,.m_external_irq_i(m_external_irq_i)
     ,.s_external_irq_i(s_external_irq_i)
     ,.irq_pending_o(irq_pending_lo)
     ,.irq_waiting_o(irq_waiting_lo)
     ,.cmd_full_n_i(cmd_full_n_lo)
     // Context switching
     ,.current_thread_id_i(current_thread_id_lo)
     ,.current_context_id_i(current_context_id_r)
     ,.retire_thread_id_i(retire_thread_id_lo)
     ,.csr_context_restore_v_i(csr_context_restore_v_li)
     ,.csr_context_restore_reset_i(csr_context_restore_reset_li)
     ,.csr_context_restore_thread_id_i(context_cache_victim_thread_id_r)
     ,.csr_context_restore_data_i(csr_context_restore_data_li)
     ,.csr_context_save_thread_id_i(csr_context_save_thread_id_li)
     ,.csr_context_save_data_o(csr_context_save_data_lo)
     ,.ctx_npc_write_v_o(ctx_npc_write_v_lo)
     ,.ctx_npc_write_tid_o(ctx_npc_write_tid_lo)
     ,.ctx_npc_write_npc_o(ctx_npc_write_npc_lo)
     ,.ctx_rpush_v_o(ctx_rpush_v_lo)
     ,.ctx_rpush_fp_v_o(ctx_rpush_fp_v_lo)
     ,.ctx_rpush_tid_o(ctx_rpush_tid_lo)
     ,.ctx_rpush_reg_o(ctx_rpush_reg_lo)
     ,.ctx_rpush_data_o(ctx_rpush_data_lo)
     ,.fast_ctxtsw_v_o(fast_ctxtsw_v_lo)
     ,.fast_ctxtsw_old_thread_id_o(fast_ctxtsw_old_thread_id_lo)
     ,.fast_ctxtsw_thread_id_o(fast_ctxtsw_context_id_lo)
     ,.fast_ctxtsw_resume_npc_o(fast_ctxtsw_resume_npc_lo)
     ,.context_cache_drain_ready_o(context_cache_calculator_drain_ready_lo)
     );

endmodule
