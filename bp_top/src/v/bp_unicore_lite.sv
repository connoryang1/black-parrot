
`include "bp_common_defines.svh"
`include "bp_top_defines.svh"
`include "bp_fe_defines.svh"
`include "bp_be_defines.svh"

module bp_unicore_lite
 import bsg_wormhole_router_pkg::*;
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 import bp_fe_pkg::*;
 import bp_me_pkg::*;
 import bsg_noc_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   , parameter bit cache_miss_trace_p = 1'b0
   // These dimensions count retained 64-byte payload lines, never L1 ways,
   // replay addresses or outstanding request slots. Legacy elaboration is 0.
`ifdef BP_RETAINED_BUFFER
   , parameter bit retained_buffer_p = `BP_RETAINED_BUFFER
`else
   , parameter bit retained_buffer_p = 1'b0
`endif
`ifdef BP_RETAINED_I_LINES
   , parameter int unsigned retained_i_lines_p = `BP_RETAINED_I_LINES
`else
   , parameter int unsigned retained_i_lines_p = 64
`endif
`ifdef BP_RETAINED_D_LINES
   , parameter int unsigned retained_d_lines_p = `BP_RETAINED_D_LINES
`else
   , parameter int unsigned retained_d_lines_p = 64
`endif
`ifdef BP_REPLAY_INSTALL
   // Address replay installs whole lines into the L1 I-cache instead of the
   // small advisory buffer (only without the retained store).
   , parameter bit replay_install_p = `BP_REPLAY_INSTALL
`else
   , parameter bit replay_install_p = 1'b0
`endif
`ifdef BP_ICACHE_PF_ELS
   , parameter int unsigned icache_pf_els_p = `BP_ICACHE_PF_ELS
`else
   , parameter int unsigned icache_pf_els_p = 4
`endif
`ifdef BP_DREPLAY_ENTRIES
   // Per-task D replay footprint length (lines per slot).
   , parameter int unsigned dreplay_entries_p = `BP_DREPLAY_ENTRIES
`else
   , parameter int unsigned dreplay_entries_p = 32
`endif
`ifdef BP_RETAINED_SETS
   , parameter int unsigned retained_sets_p = `BP_RETAINED_SETS
`else
   , parameter int unsigned retained_sets_p = 64
`endif
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_bedrock_if_widths(paddr_width_p, lce_id_width_p, cce_id_width_p, did_width_p, lce_assoc_p)

   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p)
   )
  (input                                               clk_i
   , input                                             reset_i

   , input [cfg_bus_width_lp-1:0]                      cfg_bus_i

   // Outgoing BP Stream Mem Buses from I$ and D$
   , output logic [1:0][mem_fwd_header_width_lp-1:0]   mem_fwd_header_o
   , output logic [1:0][bedrock_fill_width_p-1:0]      mem_fwd_data_o
   , output logic [1:0]                                mem_fwd_v_o
   , input [1:0]                                       mem_fwd_ready_and_i

   , input [1:0][mem_rev_header_width_lp-1:0]          mem_rev_header_i
   , input [1:0][bedrock_fill_width_p-1:0]             mem_rev_data_i
   , input [1:0]                                       mem_rev_v_i
   , output logic [1:0]                                mem_rev_ready_and_o

   , input                                             debug_irq_i
   , input                                             timer_irq_i
   , input                                             software_irq_i
   , input                                             m_external_irq_i
   , input                                             s_external_irq_i
   );

  `declare_bp_cfg_bus_s(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p);
  `declare_bp_fe_icache_engine_if(paddr_width_p, icache_tag_width_p, icache_sets_p, icache_assoc_p, icache_data_width_p, icache_block_width_p, icache_fill_width_p, icache_req_id_width_p);
  `declare_bp_be_dcache_engine_if(paddr_width_p, dcache_tag_width_p, dcache_sets_p, dcache_assoc_p, dcache_data_width_p, dcache_block_width_p, dcache_fill_width_p, dcache_req_id_width_p);
  `declare_bp_bedrock_if(paddr_width_p, lce_id_width_p, cce_id_width_p, did_width_p, lce_assoc_p);
  `bp_cast_i(bp_cfg_bus_s, cfg_bus);

  bp_fe_icache_req_s icache_req_lo;
  logic icache_req_v_lo, icache_req_yumi_li, icache_req_lock_li, icache_req_metadata_v_lo;
  // While either cache has ordinary misses outstanding, cap the replay reads
  // in flight so the replay burst does not queue ahead of those misses at the
  // in-order memory port. A cap of 0 disables throttling.
`ifdef BP_REPLAY_DEMAND_CAP
  localparam int replay_demand_cap_lp = `BP_REPLAY_DEMAND_CAP;
`else
  localparam int replay_demand_cap_lp = 0;
`endif
  logic icache_demand_active_lo, dcache_demand_active_lo;
  logic [7:0] icache_replay_inflight_lo, dcache_replay_inflight_lo;
  wire [8:0] replay_inflight_total = icache_replay_inflight_lo + dcache_replay_inflight_lo;
  wire replay_issue_throttle = (replay_demand_cap_lp != 0)
    & (icache_demand_active_lo | dcache_demand_active_lo)
    & (replay_inflight_total >= 9'(replay_demand_cap_lp));
  bp_fe_icache_req_metadata_s icache_req_metadata_lo;
  logic [icache_req_id_width_p-1:0] icache_req_id_li;
  logic icache_req_critical_li, icache_req_last_li;
  logic icache_req_credits_full_li, icache_req_credits_empty_li;
  logic icache_replay_v_lo, icache_replay_direct_ready_lo;
  logic [paddr_width_p-1:0] icache_replay_paddr_lo;
  logic icache_replay_lane_v_lo, icache_replay_lane_ready_li;
  logic [paddr_width_p-1:0] icache_replay_lane_paddr_lo;
  logic icache_replay_query_v_lo, icache_replay_query_hit_li;
  logic [paddr_width_p-1:0] icache_replay_query_paddr_lo;
  logic [dword_width_gp-1:0] icache_prefix_status_lo;
  logic icache_prefix_entry_v_lo, icache_prefix_count_v_lo;
  logic icache_prefix_trigger_v_lo, icache_prefix_clear_v_lo;
  logic icache_prefix_trigger_range_v_lo;
  logic [7:0] icache_prefix_entry_index_lo;
  logic [7:0] icache_prefix_trigger_start_lo;
  logic [8:0] icache_prefix_count_lo;
  logic [8:0] icache_prefix_trigger_count_lo;
  logic [paddr_width_p-1:0] icache_prefix_entry_paddr_lo;

  bp_fe_icache_tag_mem_pkt_s icache_tag_mem_pkt_li;
  logic icache_tag_mem_pkt_v_li, icache_tag_mem_pkt_yumi_lo;
  bp_fe_icache_tag_info_s icache_tag_mem_lo;
  logic [icache_assoc_p*($bits(bp_fe_icache_tag_info_s)+1)-1:0] icache_tag_row_lo;
  logic [icache_block_width_p-1:0] icache_fill_line_lo;
  bp_fe_icache_data_mem_pkt_s icache_data_mem_pkt_li;
  logic icache_data_mem_pkt_v_li, icache_data_mem_pkt_yumi_lo;
  logic [icache_block_width_p-1:0] icache_data_mem_lo;
  bp_fe_icache_stat_mem_pkt_s icache_stat_mem_pkt_li;
  logic icache_stat_mem_pkt_v_li, icache_stat_mem_pkt_yumi_lo;
  bp_fe_icache_stat_info_s icache_stat_mem_lo;

  bp_be_dcache_req_s dcache_req_lo;
  logic dcache_req_v_lo, dcache_req_yumi_li, dcache_req_lock_li, dcache_req_metadata_v_lo;
  bp_be_dcache_req_metadata_s dcache_req_metadata_lo;
  logic physical_preview_v_lo;
  logic [paddr_width_p-1:0] physical_preview_paddr_lo;
  logic dcache_replay_entry_v_lo, dcache_replay_config_v_lo;
  logic dcache_replay_trigger_v_lo;
  logic [dword_width_gp-1:0] dcache_replay_payload_lo;
  logic [dword_width_gp-1:0] dcache_replay_status_lo;
  logic dcache_replay_v_lo, dcache_replay_yumi_li;
  logic dcache_replay_accepted_li;
  logic dcache_replay_follow_trigger_lo;
  logic [paddr_width_p-1:0] dcache_replay_paddr_lo;
  logic dcache_replay_core_yumi_lo, dcache_replay_core_accepted_lo;
  logic [`BSG_WIDTH(dcache_prefetch_els_p+1)-1:0]
    dcache_prefetch_outstanding_count_lo, dcache_prefetch_complete_count_lo;
  logic [2:0] dcache_prefetch_outstanding_status_lo;
  logic dcache_prefetch_complete_status_lo;
  always_comb begin
    dcache_prefetch_outstanding_status_lo
      = (dcache_prefetch_outstanding_count_lo > 7)
        ? 3'd7 : 3'(dcache_prefetch_outstanding_count_lo);
    dcache_prefetch_complete_status_lo
      = |dcache_prefetch_complete_count_lo;
  end
  logic [paddr_width_p-1:0] dcache_preview_paddr_li;
  logic dcache_preview_v_li;
  logic physical_preview_uncached_lo, physical_preview_nonidem_lo;
  logic physical_preview_dram_lo;
  logic physical_preview_idle_lo;
  bp_pma
   #(.bp_params_p(bp_params_p))
   physical_preview_pma
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)
     ,.ptag_i(dcache_preview_paddr_li[page_offset_width_gp+:ptag_width_p])
     ,.uncached_mode_i(1'b0)
     ,.nonspec_mode_i(1'b0)
     ,.uncached_o(physical_preview_uncached_lo)
     ,.nonidem_o(physical_preview_nonidem_lo)
     ,.dram_o(physical_preview_dram_lo)
     );
  // Only cached, idempotent DRAM may be read speculatively. The request is
  // best effort and never backpressures architectural retirement.
  wire physical_preview_allowed_lo = dcache_preview_v_li
    & physical_preview_dram_lo & ~physical_preview_uncached_lo
    & ~physical_preview_nonidem_lo;
  assign dcache_preview_paddr_li = physical_preview_v_lo
                                   ? physical_preview_paddr_lo
                                   : dcache_replay_paddr_lo;
  assign dcache_preview_v_li = physical_preview_v_lo | dcache_replay_v_lo;
  wire dcache_replay_allowed_lo = dcache_replay_v_lo
    & ~physical_preview_v_lo & (dcache_replay_paddr_lo != '0)
    & physical_preview_allowed_lo;
  assign dcache_replay_accepted_li = dcache_replay_core_accepted_lo;
  assign dcache_replay_yumi_li = dcache_replay_v_lo
    & (dcache_replay_core_yumi_lo
       | (~physical_preview_v_lo
          & ((dcache_replay_paddr_lo == '0) | ~physical_preview_allowed_lo)));
  logic [dcache_req_id_width_p-1:0] dcache_req_id_li;
  logic dcache_req_critical_li, dcache_req_last_li;
  logic dcache_req_credits_full_li, dcache_req_credits_empty_li;

  bp_be_dcache_tag_mem_pkt_s dcache_tag_mem_pkt_li;
  logic dcache_tag_mem_pkt_v_li, dcache_tag_mem_pkt_yumi_lo;
  bp_be_dcache_tag_info_s dcache_tag_mem_lo;
  logic [dcache_assoc_p*($bits(bp_be_dcache_tag_info_s)+1)-1:0] dcache_tag_row_lo;
  logic [dcache_block_width_p-1:0] dcache_fill_line_lo;
  bp_be_dcache_data_mem_pkt_s dcache_data_mem_pkt_li;
  logic dcache_data_mem_pkt_v_li, dcache_data_mem_pkt_yumi_lo;
  logic [dcache_block_width_p-1:0] dcache_data_mem_lo;
  bp_be_dcache_stat_mem_pkt_s dcache_stat_mem_pkt_li;
  logic dcache_stat_mem_pkt_v_li, dcache_stat_mem_pkt_yumi_lo;
  bp_be_dcache_stat_info_s dcache_stat_mem_lo;

  wire posedge_clk = clk_i;
  wire negedge_clk = ~clk_i;


  // Global S/M CSR 0x5c2: I enable, D enable, D demand-copy, I demand-copy.
  // A command that changes a lane enable clears both stores (see below). Keep
  // the clear pulse registered for a full cycle:
  // I UCE runs at the positive edge, D UCE at the negative edge. Accepted
  // operations still drain; enable/clear never abandons transport ownership.
  logic retained_control_cmd_v;
  logic [3:0] retained_control_cmd, retained_control_r;
  logic retained_control_clear_r;
  logic [63:0] retained_status;
  logic dcache_retained_mutation_v, dcache_retained_maintenance_v;
  logic [paddr_width_p-1:0] dcache_retained_mutation_paddr;
  logic icache_retained_capture_cancel;
  logic [1:0] retained_lookup_v, retained_lookup_ready;
  logic [1:0][paddr_width_p-1:0] retained_lookup_addr;
  logic [1:0] retained_resp_v, retained_resp_ready, retained_resp_hit;
  logic [1:0][511:0] retained_resp_data;
  logic [1:0] retained_insert_v, retained_insert_ready;
  logic [1:0][paddr_width_p-1:0] retained_insert_addr;
  logic [1:0][511:0] retained_insert_data;
  logic [1:0] retained_insert_replace, retained_insert_cancel;
  logic [1:0] retained_insert_done, retained_insert_published;
  logic [1:0] retained_clear, retained_backend_busy, retained_uce_idle;
  logic [1:0] retained_maintenance, retained_epoch_wrap, retained_wrap_seen_r;

  wire [1:0] retained_control_enable_next =
    {retained_control_cmd[1] & (retained_d_lines_p != 0),
     retained_control_cmd[0] & (retained_i_lines_p != 0)};
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      retained_control_r <= '0;
      retained_control_clear_r <= 1'b0;
      retained_wrap_seen_r <= '0;
    end else begin
      // Clear only when a lane's lookup enable changes. A command that keeps
      // both enables and toggles only demand capture preserves the retained
      // payload, so software can capture one task's fills and keep them while
      // another task runs with capture off. Correctness never depends on this
      // clear: every D mutation still invalidates its retained set, and cache
      // maintenance (including fence.i) still clears the affected lanes.
      retained_control_clear_r <= retained_buffer_p & retained_control_cmd_v
        & (retained_control_enable_next != retained_control_r[1:0]);
      if (retained_buffer_p & retained_control_cmd_v) begin
        retained_control_r[0] <= retained_control_cmd[0] & (retained_i_lines_p != 0);
        retained_control_r[1] <= retained_control_cmd[1] & (retained_d_lines_p != 0);
        retained_control_r[2] <= retained_control_cmd[2] & retained_control_cmd[1]
                                & (retained_d_lines_p != 0);
        retained_control_r[3] <= retained_control_cmd[3] & retained_control_cmd[0]
                                & (retained_i_lines_p != 0);
        retained_wrap_seen_r <= retained_epoch_wrap;
      end else
        retained_wrap_seen_r <= retained_wrap_seen_r | retained_epoch_wrap;
    end
  end
  assign retained_clear[0] = retained_control_clear_r | retained_maintenance[0];
  assign retained_clear[1] = retained_control_clear_r | retained_maintenance[1]
                             | dcache_retained_maintenance_v;
  always_comb begin
    retained_status = '0;
    if (retained_buffer_p) begin
      retained_status[63] = 1'b1;
      retained_status[3:0] = retained_control_r;
      retained_status[9:8] = ~retained_uce_idle | retained_backend_busy
                            | {2{retained_control_clear_r}};
      retained_status[11:10] = retained_wrap_seen_r;
      retained_status[31:16] = 16'(retained_i_lines_p);
      retained_status[47:32] = 16'(retained_d_lines_p);
      retained_status[55:48] = 8'($clog2(retained_sets_p));
      retained_status[56] = 1'b1; // full 64-byte payload
      retained_status[57] = 1'b1; // conservative same-set mutation invalidation
    end
  end
  if (retained_buffer_p) begin : retained_store
    bp_retained_line_store
     #(.paddr_width_p(paddr_width_p), .sets_p(retained_sets_p)
       ,.i_lines_p(retained_i_lines_p), .d_lines_p(retained_d_lines_p))
     storage
      (.clk_i({negedge_clk, posedge_clk}), .reset_i({2{reset_i}})
       ,.clear_i(retained_clear)
       ,.invalidate_v_i({dcache_retained_mutation_v, 1'b0})
       ,.invalidate_addr_i({dcache_retained_mutation_paddr, {paddr_width_p{1'b0}}})
       ,.lookup_v_i(retained_lookup_v), .lookup_ready_o(retained_lookup_ready)
       ,.lookup_addr_i(retained_lookup_addr)
       ,.resp_v_o(retained_resp_v), .resp_ready_i(retained_resp_ready)
       ,.resp_hit_o(retained_resp_hit), .resp_data_o(retained_resp_data)
       ,.insert_v_i(retained_insert_v), .insert_ready_o(retained_insert_ready)
       ,.insert_addr_i(retained_insert_addr), .insert_data_i(retained_insert_data)
       ,.insert_replace_i(retained_insert_replace), .insert_cancel_i(retained_insert_cancel)
       ,.insert_done_o(retained_insert_done), .insert_published_o(retained_insert_published)
       ,.busy_o(retained_backend_busy), .epoch_wrap_o(retained_epoch_wrap));
    initial begin
      assert (icache_block_width_p == 512 && dcache_block_width_p == 512)
        else $error("retained payload requires full 64-byte I/D cache lines");
      assert (retained_i_lines_p <= 65535 && retained_d_lines_p <= 65535)
        else $error("retained geometry exceeds CSR representation");
    end
  end else begin : no_retained_store
    assign retained_lookup_ready = '0;
    assign retained_resp_v = '0;
    assign retained_resp_hit = '0;
    assign retained_resp_data = '0;
    assign retained_insert_ready = '0;
    assign retained_insert_done = '0;
    assign retained_insert_published = '0;
    assign retained_backend_busy = '0;
    assign retained_epoch_wrap = '0;
  end

  wire [did_width_p-1:0] did_li = cfg_bus_cast_i.did;
  wire [1:0][lce_id_width_p-1:0] lce_id_li = {cfg_bus_cast_i.dcache_id, cfg_bus_cast_i.icache_id};
  bp_core_minimal
   #(.bp_params_p(bp_params_p)
     ,.cache_miss_trace_p(cache_miss_trace_p)
     ,.retained_buffer_p(retained_buffer_p)
     ,.icache_replay_buffer_p(~retained_buffer_p)
     ,.icache_replay_buffer_els_p(32)
     )
   core_minimal
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)
     ,.retained_control_status_i(retained_status)
     ,.retained_control_cmd_v_o(retained_control_cmd_v)
     ,.retained_control_o(retained_control_cmd)
     ,.dcache_retained_mutation_v_o(dcache_retained_mutation_v)
     ,.dcache_retained_mutation_paddr_o(dcache_retained_mutation_paddr)
     ,.dcache_retained_maintenance_v_o(dcache_retained_maintenance_v)
     // The optional per-word I$ adapter is not used by this architecture.
     // Both sides restore complete L1 lines through their ordinary UCEs.
     ,.icache_retention_lookup_enable_i(1'b0)
     ,.icache_retained_lookup_v_o()
     ,.icache_retained_lookup_ready_i(1'b0)
     ,.icache_retained_lookup_paddr_o()
     ,.icache_retained_resp_v_i(1'b0)
     ,.icache_retained_resp_ready_o()
     ,.icache_retained_resp_hit_i(1'b0)
     ,.icache_retained_resp_data_i('0)
     ,.icache_retained_insert_v_o()
     ,.icache_retained_insert_ready_i(1'b0)
     ,.icache_retained_insert_paddr_o()
     ,.icache_retained_insert_data_o()
     ,.icache_retained_insert_replace_o()
     ,.icache_retained_insert_cancel_o()
     ,.icache_retained_insert_done_i(1'b0)
     ,.icache_retained_insert_published_i(1'b0)
     ,.icache_retained_clear_o()
     ,.icache_retained_drop_o()
     ,.icache_retained_capture_cancel_o(icache_retained_capture_cancel)
     ,.icache_retained_idle_o()
     ,.cfg_bus_i(cfg_bus_cast_i)
     ,.physical_preview_v_o(physical_preview_v_lo)
     ,.physical_preview_paddr_o(physical_preview_paddr_lo)
     ,.physical_preview_idle_i(physical_preview_idle_lo)
     ,.dcache_replay_status_i(dcache_replay_status_lo)
     ,.dcache_replay_entry_v_o(dcache_replay_entry_v_lo)
     ,.dcache_replay_config_v_o(dcache_replay_config_v_lo)
     ,.dcache_replay_trigger_v_o(dcache_replay_trigger_v_lo)
     ,.dcache_replay_payload_o(dcache_replay_payload_lo)
     ,.dcache_replay_v_i(dcache_replay_allowed_lo)
     ,.dcache_replay_paddr_i(dcache_replay_paddr_lo)
     ,.dcache_replay_yumi_o(dcache_replay_core_yumi_lo)
     ,.dcache_replay_accepted_o(dcache_replay_core_accepted_lo)

     ,.icache_req_o(icache_req_lo)
     ,.icache_req_v_o(icache_req_v_lo)
     ,.icache_req_yumi_i(icache_req_yumi_li)
     ,.icache_req_lock_i(icache_req_lock_li)
     ,.icache_req_metadata_o(icache_req_metadata_lo)
     ,.icache_req_metadata_v_o(icache_req_metadata_v_lo)
     ,.icache_req_id_i(icache_req_id_li)
     ,.icache_req_critical_i(icache_req_critical_li)
     ,.icache_req_last_i(icache_req_last_li)
     ,.icache_req_credits_full_i(icache_req_credits_full_li)
     ,.icache_req_credits_empty_i(icache_req_credits_empty_li)

     ,.icache_tag_mem_pkt_i(icache_tag_mem_pkt_li)
     ,.icache_tag_mem_pkt_v_i(icache_tag_mem_pkt_v_li)
     ,.icache_tag_mem_pkt_yumi_o(icache_tag_mem_pkt_yumi_lo)
     ,.icache_tag_mem_o(icache_tag_mem_lo)
     ,.icache_tag_row_o(icache_tag_row_lo)
     ,.icache_fill_line_i(icache_fill_line_lo)

     ,.icache_data_mem_pkt_i(icache_data_mem_pkt_li)
     ,.icache_data_mem_pkt_v_i(icache_data_mem_pkt_v_li)
     ,.icache_data_mem_pkt_yumi_o(icache_data_mem_pkt_yumi_lo)
     ,.icache_data_mem_o(icache_data_mem_lo)

     ,.icache_stat_mem_pkt_v_i(icache_stat_mem_pkt_v_li)
     ,.icache_stat_mem_pkt_i(icache_stat_mem_pkt_li)
     ,.icache_stat_mem_pkt_yumi_o(icache_stat_mem_pkt_yumi_lo)
     ,.icache_stat_mem_o(icache_stat_mem_lo)

     ,.dcache_req_o(dcache_req_lo)
     ,.dcache_req_v_o(dcache_req_v_lo)
     ,.dcache_req_yumi_i(dcache_req_yumi_li)
     ,.dcache_req_lock_i(dcache_req_lock_li)
     ,.dcache_req_metadata_o(dcache_req_metadata_lo)
     ,.dcache_req_metadata_v_o(dcache_req_metadata_v_lo)
     ,.dcache_req_id_i(dcache_req_id_li)
     ,.dcache_req_critical_i(dcache_req_critical_li)
     ,.dcache_req_last_i(dcache_req_last_li)
     ,.dcache_req_credits_full_i(dcache_req_credits_full_li)
     ,.dcache_req_credits_empty_i(dcache_req_credits_empty_li)

     ,.dcache_tag_mem_pkt_i(dcache_tag_mem_pkt_li)
     ,.dcache_tag_mem_pkt_v_i(dcache_tag_mem_pkt_v_li)
     ,.dcache_tag_mem_pkt_yumi_o(dcache_tag_mem_pkt_yumi_lo)
     ,.dcache_tag_mem_o(dcache_tag_mem_lo)
     ,.dcache_tag_row_o(dcache_tag_row_lo)
     ,.dcache_fill_line_i(dcache_fill_line_lo)

     ,.dcache_data_mem_pkt_i(dcache_data_mem_pkt_li)
     ,.dcache_data_mem_pkt_v_i(dcache_data_mem_pkt_v_li)
     ,.dcache_data_mem_pkt_yumi_o(dcache_data_mem_pkt_yumi_lo)
     ,.dcache_data_mem_o(dcache_data_mem_lo)

     ,.dcache_stat_mem_pkt_v_i(dcache_stat_mem_pkt_v_li)
     ,.dcache_stat_mem_pkt_i(dcache_stat_mem_pkt_li)
     ,.dcache_stat_mem_pkt_yumi_o(dcache_stat_mem_pkt_yumi_lo)
     ,.dcache_stat_mem_o(dcache_stat_mem_lo)

     ,.debug_irq_i(debug_irq_i)
     ,.timer_irq_i(timer_irq_i)
     ,.software_irq_i(software_irq_i)
     ,.m_external_irq_i(m_external_irq_i)
     ,.s_external_irq_i(s_external_irq_i)
     ,.icache_replay_query_v_i(icache_replay_query_v_lo)
     ,.icache_replay_query_paddr_i(icache_replay_query_paddr_lo)
     ,.icache_replay_query_hit_o(icache_replay_query_hit_li)
     ,.icache_replay_ready_i(icache_replay_direct_ready_lo)
     ,.icache_replay_v_o(icache_replay_v_lo)
     ,.icache_replay_paddr_o(icache_replay_paddr_lo)
     ,.icache_prefix_status_i(icache_prefix_status_lo)
     ,.icache_prefix_entry_v_o(icache_prefix_entry_v_lo)
     ,.icache_prefix_entry_index_o(icache_prefix_entry_index_lo)
     ,.icache_prefix_entry_paddr_o(icache_prefix_entry_paddr_lo)
     ,.icache_prefix_count_v_o(icache_prefix_count_v_lo)
     ,.icache_prefix_count_o(icache_prefix_count_lo)
     ,.icache_prefix_trigger_v_o(icache_prefix_trigger_v_lo)
     ,.icache_prefix_trigger_range_v_o(icache_prefix_trigger_range_v_lo)
     ,.icache_prefix_trigger_start_o(icache_prefix_trigger_start_lo)
     ,.icache_prefix_trigger_count_o(icache_prefix_trigger_count_lo)
     ,.icache_prefix_clear_v_o(icache_prefix_clear_v_lo)
     );

  bp_icache_replay_ctrl
   #(.paddr_width_p(paddr_width_p))
   icache_replay_ctrl
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)
     ,.direct_v_i(icache_replay_v_lo)
     ,.direct_paddr_i(icache_replay_paddr_lo)
     ,.direct_ready_o(icache_replay_direct_ready_lo)
     ,.entry_write_v_i(icache_prefix_entry_v_lo)
     ,.entry_write_index_i(icache_prefix_entry_index_lo)
     ,.entry_write_paddr_i(icache_prefix_entry_paddr_lo)
     ,.count_write_v_i(icache_prefix_count_v_lo)
     ,.count_i(icache_prefix_count_lo)
     ,.clear_counters_i(icache_prefix_clear_v_lo)
     ,.trigger_v_i(icache_prefix_trigger_v_lo
                   | dcache_replay_follow_trigger_lo)
     ,.trigger_range_v_i(icache_prefix_trigger_v_lo
                         & ~dcache_replay_follow_trigger_lo
                         & icache_prefix_trigger_range_v_lo)
     ,.trigger_start_i(icache_prefix_trigger_start_lo)
     ,.trigger_count_i(icache_prefix_trigger_count_lo)
     ,.resident_query_v_o(icache_replay_query_v_lo)
     ,.resident_query_paddr_o(icache_replay_query_paddr_lo)
     ,.resident_i(icache_replay_query_hit_li)
     ,.replay_v_o(icache_replay_lane_v_lo)
     ,.replay_paddr_o(icache_replay_lane_paddr_lo)
     ,.replay_ready_i(icache_replay_lane_ready_li)
     ,.status_o(icache_prefix_status_lo)
     );

  bp_uce
   #(.bp_params_p(bp_params_p)
     ,.retained_buffer_p(retained_buffer_p)
     ,.assoc_p(icache_assoc_p)
     ,.sets_p(icache_sets_p)
     ,.block_width_p(icache_block_width_p)
     ,.fill_width_p(icache_fill_width_p)
     ,.data_width_p(icache_data_width_p)
     ,.tag_width_p(icache_tag_width_p)
     ,.id_width_p(icache_req_id_width_p)
     ,.writeback_p(icache_features_p[e_cfg_writeback])
     ,.prefetch_p(1'b1)
     ,.prefetch_els_p(icache_pf_els_p)
     ,.prefetch_full_line_p(1'b1)
     ,.prefetch_demand_priority_p(1'b1)
     ,.prefetch_critical_forward_p(1'b0)
`ifdef BP_REPLAY_ICACHE_NODRAIN
     ,.install_drain_p(1'b0)
`endif
     ,.prefetch_side_buffer_p(~retained_buffer_p & ~replay_install_p)
     )
   icache_uce
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)

     ,.did_i(did_li)
     ,.lce_id_i(lce_id_li[0])
     ,.retained_enable_i(retained_control_r[0])
     ,.retained_demand_capture_i(retained_control_r[3])
     ,.retained_capture_cancel_i(icache_retained_capture_cancel)
     ,.retained_clear_i(retained_clear[0])
     ,.retained_maintenance_o(retained_maintenance[0])
     ,.retained_mutation_v_i(1'b0)
     ,.retained_mutation_paddr_i('0)
     ,.retained_idle_o(retained_uce_idle[0])
     ,.retained_lookup_v_o(retained_lookup_v[0])
     ,.retained_lookup_ready_i(retained_lookup_ready[0])
     ,.retained_lookup_addr_o(retained_lookup_addr[0])
     ,.retained_resp_v_i(retained_resp_v[0])
     ,.retained_resp_ready_o(retained_resp_ready[0])
     ,.retained_resp_hit_i(retained_resp_hit[0])
     ,.retained_resp_data_i(retained_resp_data[0])
     ,.retained_insert_v_o(retained_insert_v[0])
     ,.retained_insert_ready_i(retained_insert_ready[0])
     ,.retained_insert_addr_o(retained_insert_addr[0])
     ,.retained_insert_data_o(retained_insert_data[0])
     ,.retained_insert_replace_o(retained_insert_replace[0])
     ,.retained_insert_cancel_o(retained_insert_cancel[0])
     ,.retained_insert_done_i(retained_insert_done[0])
     ,.retained_insert_published_i(retained_insert_published[0])
     ,.retained_backend_busy_i(retained_backend_busy[0])

     ,.cache_req_i(icache_req_lo)
     ,.cache_req_v_i(icache_req_v_lo)
     ,.cache_req_yumi_o(icache_req_yumi_li)
     ,.cache_req_lock_o(icache_req_lock_li)
     ,.demand_active_o(icache_demand_active_lo)
     ,.replay_inflight_o(icache_replay_inflight_lo)
     ,.replay_issue_throttle_i(replay_issue_throttle)
     ,.cache_req_metadata_i(icache_req_metadata_lo)
     ,.cache_req_metadata_v_i(icache_req_metadata_v_lo)
     ,.preview_paddr_i('0)
     ,.preview_v_i(1'b0)
     ,.preview_cancel_i(1'b0)
     ,.preview_ready_o()
     ,.preview_idle_o()
     ,.cache_req_id_o(icache_req_id_li)
     ,.cache_req_critical_o(icache_req_critical_li)
     ,.cache_req_last_o(icache_req_last_li)
     ,.cache_req_credits_full_o(icache_req_credits_full_li)
     ,.cache_req_credits_empty_o(icache_req_credits_empty_li)

     ,.detached_prefetch_addr_i(icache_replay_lane_paddr_lo)
     ,.detached_prefetch_v_i(icache_replay_lane_v_lo)
     ,.detached_prefetch_ready_and_o(icache_replay_lane_ready_li)
     ,.prefetch_outstanding_o()
     ,.prefetch_complete_o()

     ,.tag_mem_pkt_o(icache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_o(icache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_i(icache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_i(icache_tag_mem_lo)
     ,.tag_row_i(icache_tag_row_lo)
     ,.install_line_o(icache_fill_line_lo)

     ,.data_mem_pkt_o(icache_data_mem_pkt_li)
     ,.data_mem_pkt_v_o(icache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_i(icache_data_mem_pkt_yumi_lo)
     ,.data_mem_i(icache_data_mem_lo)

     ,.stat_mem_pkt_o(icache_stat_mem_pkt_li)
     ,.stat_mem_pkt_v_o(icache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_yumi_i(icache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_i(icache_stat_mem_lo)

     ,.mem_fwd_header_o(mem_fwd_header_o[0])
     ,.mem_fwd_data_o(mem_fwd_data_o[0])
     ,.mem_fwd_v_o(mem_fwd_v_o[0])
     ,.mem_fwd_ready_and_i(mem_fwd_ready_and_i[0])

     ,.mem_rev_header_i(mem_rev_header_i[0])
     ,.mem_rev_data_i(mem_rev_data_i[0])
     ,.mem_rev_v_i(mem_rev_v_i[0])
     ,.mem_rev_ready_and_o(mem_rev_ready_and_o[0])
     );

  bp_bedrock_mem_fwd_header_s [1:1] _mem_fwd_header_o;
  logic [1:1][bedrock_fill_width_p-1:0] _mem_fwd_data_o;
  logic [1:1] _mem_fwd_v_o, _mem_fwd_ready_and_i;
  bp_bedrock_mem_rev_header_s [1:1] _mem_rev_header_i;
  logic [1:1][bedrock_fill_width_p-1:0] _mem_rev_data_i;
  logic [1:1] _mem_rev_v_i, _mem_rev_ready_and_o;

  // Wide D replay tables take index bits 52:48 above the original 44:40
  // field and count bits 36:32 above 7:2; both are zero for <=32 entries.
  localparam dreplay_index_w_lp = $clog2(dreplay_entries_p);
  localparam dreplay_count_w_lp = $clog2(dreplay_entries_p+1);
  wire [9:0] dreplay_index_wide = {dcache_replay_payload_lo[52:48], dcache_replay_payload_lo[44:40]};
  wire [10:0] dreplay_count_wide = {dcache_replay_payload_lo[36:32], dcache_replay_payload_lo[7:2]};
  bp_dcache_replay_ctrl
   #(.paddr_width_p(paddr_width_p), .entries_per_slot_p(dreplay_entries_p))
   dcache_replay_ctrl
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)
     ,.entry_write_v_i(dcache_replay_entry_v_lo)
     ,.entry_write_slot_i(dcache_replay_payload_lo[46:45])
     ,.entry_write_index_i(dreplay_index_wide[0+:dreplay_index_w_lp])
     ,.entry_write_paddr_i(dcache_replay_payload_lo[0+:paddr_width_p])
     ,.config_write_v_i(dcache_replay_config_v_lo)
     ,.config_write_slot_i(dcache_replay_payload_lo[1:0])
     ,.config_write_count_i(dreplay_count_wide[0+:dreplay_count_w_lp])
     ,.config_write_delay_i(dcache_replay_payload_lo[23:8])
     ,.config_write_gap_i(dcache_replay_payload_lo[31:24])
     ,.trigger_v_i(dcache_replay_trigger_v_lo)
     ,.trigger_slot_i(dcache_replay_payload_lo[1:0])
     ,.trigger_follow_i(dcache_replay_payload_lo[2])
     ,.replay_v_o(dcache_replay_v_lo)
     ,.replay_paddr_o(dcache_replay_paddr_lo)
     ,.replay_yumi_i(dcache_replay_yumi_li)
     ,.replay_accepted_i(dcache_replay_accepted_li)
     ,.downstream_outstanding_i(dcache_prefetch_outstanding_status_lo)
     ,.downstream_complete_i(dcache_prefetch_complete_status_lo)
     ,.follow_ready_i(~icache_prefix_status_lo[1])
     ,.follow_active_i(icache_prefix_status_lo[1])
     ,.follow_configured_i(|icache_prefix_status_lo[12:4])
     ,.follow_trigger_o(dcache_replay_follow_trigger_lo)
     ,.clear_counters_i(dcache_replay_config_v_lo
                        & dcache_replay_payload_lo[dword_width_gp-1])
     ,.status_o(dcache_replay_status_lo)
     );

  bp_uce
   #(.bp_params_p(bp_params_p)
     ,.retained_buffer_p(retained_buffer_p)
     ,.assoc_p(dcache_assoc_p)
     ,.sets_p(dcache_sets_p)
     ,.block_width_p(dcache_block_width_p)
     ,.fill_width_p(dcache_fill_width_p)
     ,.data_width_p(dcache_data_width_p)
     ,.tag_width_p(dcache_tag_width_p)
     ,.id_width_p(dcache_req_id_width_p)
     ,.writeback_p(dcache_features_p[e_cfg_writeback])
     ,.prefetch_els_p(dcache_prefetch_els_p)
     ,.prefetch_full_line_p(retained_buffer_p ? 1'b1 : dcache_prefetch_full_line_p)
     ,.prefetch_critical_forward_p(~retained_buffer_p)
     ,.prefetch_ignore_credits_p(1'b1)
     )
   dcache_uce
    (.clk_i(negedge_clk)
     ,.reset_i(reset_i)

     ,.did_i(did_li)
     ,.lce_id_i(lce_id_li[1])
     ,.retained_enable_i(retained_control_r[1])
     ,.retained_demand_capture_i(retained_control_r[2])
     ,.retained_capture_cancel_i(1'b0)
     ,.retained_clear_i(retained_clear[1])
     ,.retained_maintenance_o(retained_maintenance[1])
     ,.retained_mutation_v_i(dcache_retained_mutation_v)
     ,.retained_mutation_paddr_i(dcache_retained_mutation_paddr)
     ,.retained_idle_o(retained_uce_idle[1])
     ,.retained_lookup_v_o(retained_lookup_v[1])
     ,.retained_lookup_ready_i(retained_lookup_ready[1])
     ,.retained_lookup_addr_o(retained_lookup_addr[1])
     ,.retained_resp_v_i(retained_resp_v[1])
     ,.retained_resp_ready_o(retained_resp_ready[1])
     ,.retained_resp_hit_i(retained_resp_hit[1])
     ,.retained_resp_data_i(retained_resp_data[1])
     ,.retained_insert_v_o(retained_insert_v[1])
     ,.retained_insert_ready_i(retained_insert_ready[1])
     ,.retained_insert_addr_o(retained_insert_addr[1])
     ,.retained_insert_data_o(retained_insert_data[1])
     ,.retained_insert_replace_o(retained_insert_replace[1])
     ,.retained_insert_cancel_o(retained_insert_cancel[1])
     ,.retained_insert_done_i(retained_insert_done[1])
     ,.retained_insert_published_i(retained_insert_published[1])
     ,.retained_backend_busy_i(retained_backend_busy[1])

     ,.cache_req_i(dcache_req_lo)
     ,.cache_req_v_i(dcache_req_v_lo)
     ,.cache_req_yumi_o(dcache_req_yumi_li)
     ,.cache_req_lock_o(dcache_req_lock_li)
     ,.demand_active_o(dcache_demand_active_lo)
     ,.replay_inflight_o(dcache_replay_inflight_lo)
     ,.replay_issue_throttle_i(replay_issue_throttle)
     ,.cache_req_metadata_i(dcache_req_metadata_lo)
     ,.cache_req_metadata_v_i(dcache_req_metadata_v_lo)
     ,.preview_paddr_i(physical_preview_paddr_lo)
     ,.preview_v_i(physical_preview_v_lo & physical_preview_allowed_lo
                   & (physical_preview_paddr_lo != '0))
     ,.preview_cancel_i(physical_preview_v_lo & (physical_preview_paddr_lo == '0))
     ,.preview_ready_o()
     ,.preview_idle_o(physical_preview_idle_lo)
     ,.cache_req_id_o(dcache_req_id_li)
     ,.cache_req_critical_o(dcache_req_critical_li)
     ,.cache_req_last_o(dcache_req_last_li)
     ,.cache_req_credits_full_o(dcache_req_credits_full_li)
     ,.cache_req_credits_empty_o(dcache_req_credits_empty_li)

     ,.detached_prefetch_addr_i('0)
     ,.detached_prefetch_v_i(1'b0)
     ,.detached_prefetch_ready_and_o()
     ,.prefetch_outstanding_o(dcache_prefetch_outstanding_count_lo)
     ,.prefetch_complete_o(dcache_prefetch_complete_count_lo)

     ,.tag_mem_pkt_o(dcache_tag_mem_pkt_li)
     ,.tag_mem_pkt_v_o(dcache_tag_mem_pkt_v_li)
     ,.tag_mem_pkt_yumi_i(dcache_tag_mem_pkt_yumi_lo)
     ,.tag_mem_i(dcache_tag_mem_lo)
     ,.tag_row_i(dcache_tag_row_lo)
     ,.install_line_o(dcache_fill_line_lo)

     ,.data_mem_pkt_o(dcache_data_mem_pkt_li)
     ,.data_mem_pkt_v_o(dcache_data_mem_pkt_v_li)
     ,.data_mem_pkt_yumi_i(dcache_data_mem_pkt_yumi_lo)
     ,.data_mem_i(dcache_data_mem_lo)

     ,.stat_mem_pkt_o(dcache_stat_mem_pkt_li)
     ,.stat_mem_pkt_v_o(dcache_stat_mem_pkt_v_li)
     ,.stat_mem_pkt_yumi_i(dcache_stat_mem_pkt_yumi_lo)
     ,.stat_mem_i(dcache_stat_mem_lo)

     ,.mem_fwd_header_o(_mem_fwd_header_o[1])
     ,.mem_fwd_data_o(_mem_fwd_data_o[1])
     ,.mem_fwd_v_o(_mem_fwd_v_o[1])
     ,.mem_fwd_ready_and_i(_mem_fwd_ready_and_i[1])

     ,.mem_rev_header_i(_mem_rev_header_i[1])
     ,.mem_rev_data_i(_mem_rev_data_i[1])
     ,.mem_rev_v_i(_mem_rev_v_i[1])
     ,.mem_rev_ready_and_o(_mem_rev_ready_and_o[1])
     );

  bsg_fifo_1r1w_edge
   #(.width_p($bits(bp_bedrock_mem_fwd_header_s)+bedrock_fill_width_p))
   mem_fwd
    (.clk_i(negedge_clk)
     ,.reset_i(reset_i)

     ,.data_i({_mem_fwd_header_o[1], _mem_fwd_data_o[1]})
     ,.v_i(_mem_fwd_v_o[1])
     ,.ready_and_o(_mem_fwd_ready_and_i[1])

     ,.data_o({mem_fwd_header_o[1], mem_fwd_data_o[1]})
     ,.v_o(mem_fwd_v_o[1])
     ,.ready_and_i(mem_fwd_ready_and_i[1])
     );

  bsg_fifo_1r1w_edge
   #(.width_p($bits(bp_bedrock_mem_rev_header_s)+bedrock_fill_width_p))
   mem_rev
    (.clk_i(posedge_clk)
     ,.reset_i(reset_i)

     ,.data_i({mem_rev_header_i[1], mem_rev_data_i[1]})
     ,.v_i(mem_rev_v_i[1])
     ,.ready_and_o(mem_rev_ready_and_o[1])

     ,.data_o({_mem_rev_header_i[1], _mem_rev_data_i[1]})
     ,.v_o(_mem_rev_v_i[1])
     ,.ready_and_i(_mem_rev_ready_and_o[1])
     );

endmodule
