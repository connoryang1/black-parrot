/**
 *  bp_core_minimal.v
 *
 */

`include "bp_common_defines.svh"
`include "bp_fe_defines.svh"
`include "bp_be_defines.svh"
`include "bp_top_defines.svh"

module bp_core_minimal
 import bp_common_pkg::*;
 import bp_fe_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_fe_icache_engine_if_widths(paddr_width_p, icache_tag_width_p, icache_sets_p, icache_assoc_p, icache_data_width_p, icache_block_width_p, icache_fill_width_p, icache_req_id_width_p)
   `declare_bp_be_dcache_engine_if_widths(paddr_width_p, dcache_tag_width_p, dcache_sets_p, dcache_assoc_p, dcache_data_width_p, dcache_block_width_p, dcache_fill_width_p, dcache_req_id_width_p)
   , parameter bit cache_miss_trace_p = 1'b0
   , localparam cfg_bus_width_lp = `bp_cfg_bus_width(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p)
   )
  (input                                             clk_i
   , input                                           reset_i

   , input [cfg_bus_width_lp-1:0]                    cfg_bus_i

   , output logic [icache_req_width_lp-1:0]          icache_req_o
   , output logic                                    icache_req_v_o
   , input                                           icache_req_yumi_i
   , input                                           icache_req_lock_i
   , output logic [icache_req_metadata_width_lp-1:0] icache_req_metadata_o
   , output logic                                    icache_req_metadata_v_o
   , input [icache_req_id_width_p-1:0]               icache_req_id_i
   , input                                           icache_req_critical_i
   , input                                           icache_req_last_i
   , input                                           icache_req_credits_full_i
   , input                                           icache_req_credits_empty_i

   , input [icache_tag_mem_pkt_width_lp-1:0]         icache_tag_mem_pkt_i
   , input                                           icache_tag_mem_pkt_v_i
   , output logic                                    icache_tag_mem_pkt_yumi_o
   , output logic [icache_tag_info_width_lp-1:0]     icache_tag_mem_o

   , input [icache_data_mem_pkt_width_lp-1:0]        icache_data_mem_pkt_i
   , input                                           icache_data_mem_pkt_v_i
   , output logic                                    icache_data_mem_pkt_yumi_o
   , output logic [icache_block_width_p-1:0]         icache_data_mem_o

   , input [icache_stat_mem_pkt_width_lp-1:0]        icache_stat_mem_pkt_i
   , input                                           icache_stat_mem_pkt_v_i
   , output logic                                    icache_stat_mem_pkt_yumi_o
   , output logic [icache_stat_info_width_lp-1:0]    icache_stat_mem_o

   // D$ Engine Interface is clocked on the negedge of the clock. Must be attached to
   //   a negative-edge cache engine and synchronized before getting to the memory system
   , output logic [dcache_req_width_lp-1:0]          dcache_req_o
   , output logic                                    dcache_req_v_o
   , input                                           dcache_req_yumi_i
   , input                                           dcache_req_lock_i
   , output logic [dcache_req_metadata_width_lp-1:0] dcache_req_metadata_o
   , output logic                                    dcache_req_metadata_v_o
   , input [dcache_req_id_width_p-1:0]               dcache_req_id_i
   , input                                           dcache_req_critical_i
   , input                                           dcache_req_last_i
   , input                                           dcache_req_credits_full_i
   , input                                           dcache_req_credits_empty_i
   // {published, issued, admitted} physical preview events from the UCE.
   , input [2:0]                                     preview_events_i
   , input [paddr_width_p-1:0]                       preview_publish_addr_i
   , output logic                                    physical_preview_v_o
   , output logic [paddr_width_p-1:0]                physical_preview_paddr_o

   , input [dcache_tag_mem_pkt_width_lp-1:0]         dcache_tag_mem_pkt_i
   , input                                           dcache_tag_mem_pkt_v_i
   , output logic                                    dcache_tag_mem_pkt_yumi_o
   , output logic [dcache_tag_info_width_lp-1:0]     dcache_tag_mem_o

   , input [dcache_data_mem_pkt_width_lp-1:0]        dcache_data_mem_pkt_i
   , input                                           dcache_data_mem_pkt_v_i
   , output logic                                    dcache_data_mem_pkt_yumi_o
   , output logic [dcache_block_width_p-1:0]         dcache_data_mem_o

   , input [dcache_stat_mem_pkt_width_lp-1:0]        dcache_stat_mem_pkt_i
   , input                                           dcache_stat_mem_pkt_v_i
   , output logic                                    dcache_stat_mem_pkt_yumi_o
   , output logic [dcache_stat_info_width_lp-1:0]    dcache_stat_mem_o

   , input                                           debug_irq_i
   , input                                           timer_irq_i
   , input                                           software_irq_i
   , input                                           m_external_irq_i
   , input                                           s_external_irq_i
   );

  `declare_bp_core_if(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p);
  `declare_bp_fe_icache_engine_if(paddr_width_p, icache_tag_width_p, icache_sets_p, icache_assoc_p, icache_data_width_p, icache_block_width_p, icache_fill_width_p, icache_req_id_width_p);
  `declare_bp_be_dcache_engine_if(paddr_width_p, dcache_tag_width_p, dcache_sets_p, dcache_assoc_p, dcache_data_width_p, dcache_block_width_p, dcache_fill_width_p, dcache_req_id_width_p);
  `declare_bp_cfg_bus_s(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p);

  `bp_cast_i(bp_cfg_bus_s, cfg_bus);

  bp_fe_queue_s fe_queue_li, fe_queue_lo;
  logic fe_queue_v_li, fe_queue_ready_and_lo;
  bp_fe_cmd_s fe_cmd_lo;
  logic fe_cmd_v_lo, fe_cmd_yumi_li, fe_ctxtsw_ready_lo;
  logic fe_ctxtsw_v_lo, fe_ctxtsw_yumi_li, fe_ctxtsw_cancel_lo;
  logic [vaddr_width_p-1:0] fe_ctxtsw_npc_lo;
  logic [thread_id_width_p-1:0] fe_ctxtsw_thread_id_lo;
  logic [rv64_priv_width_gp-1:0] fe_ctxtsw_priv_lo;
  logic fe_ctxtsw_translation_en_lo;
  logic [asid_width_p-1:0] fe_ctxtsw_asid_lo;

  logic [dword_width_gp-1:0] miss_trace_status_li, miss_trace_data_li;
  logic miss_trace_ctrl_v_lo, miss_trace_arm_lo, miss_trace_preview_lo;
  logic physical_preview_v_lo;
  logic [paddr_width_p-1:0] physical_preview_paddr_lo;

  // Capture the retirement pulse on the core posedge so the negedge UCE
  // receives one stable advisory request in the following half-cycle.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      physical_preview_v_o <= 1'b0;
      physical_preview_paddr_o <= '0;
    end else begin
      physical_preview_v_o <= physical_preview_v_lo;
      physical_preview_paddr_o <= physical_preview_paddr_lo;
    end
  end
  logic miss_trace_clear_lo;
  logic miss_trace_read_v_lo, miss_trace_read_source_lo;
  logic [7:0] miss_trace_read_index_lo;
  logic [33:0] prefetch_remove_event_lo;
  logic [63:0] prefetch_remove_meta_lo;

  // This temporary measurement block records accepted physical demand misses,
  // after translation and before the I/D memory engines. Separate memories
  // preserve simultaneous I- and D-side events and map to one RAMB18 each.
  if (cache_miss_trace_p) begin : gen_cache_miss_trace
    bp_fe_icache_req_s icache_req_cast;
    bp_be_dcache_req_s dcache_req_cast;
    assign icache_req_cast = icache_req_o;
    assign dcache_req_cast = dcache_req_o;

    logic armed_r, preview_trace_r, preview_overflow_r;
    logic icache_overflow_r, dcache_overflow_r;
    logic [8:0] icache_count_r, dcache_count_r;
    logic [3:0] preview_count_r;
    logic [4:0] prefetch_remove_count_r;
    logic [7:0] preview_physical_count_r, preview_admit_count_r;
    logic [7:0] preview_issue_count_r, preview_publish_count_r;
    logic [31:0] cycle_r;
    (* ram_style = "block" *) logic [63:0] icache_trace_mem [0:255];
    (* ram_style = "block" *) logic [63:0] dcache_trace_mem [0:255];
    logic [63:0] icache_trace_data_r, dcache_trace_data_r;
    logic miss_trace_read_source_r;

    // Address-preview mode reuses the I history for D-side publications. The
    // Linux diagnostic reads no I misses in that mode, and separating these
    // writes preserves simultaneous publication and removal records.
    wire icache_miss_accept = armed_r & ~preview_trace_r & icache_req_v_o & icache_req_yumi_i
                              & (icache_req_cast.msg_type == e_miss_load);
    wire dcache_miss_accept = armed_r & dcache_req_v_o & dcache_req_yumi_i
                              & (dcache_req_cast.msg_type == e_miss_load);
    wire preview_physical = dcache_req_v_o & dcache_req_yumi_i
                            & (dcache_req_cast.msg_type == e_cache_prefetch);
    // Publication timing is independent of when software arms demand misses.
    wire preview_record = preview_trace_r & preview_events_i[2];
    wire prefetch_remove_record = preview_trace_r & prefetch_remove_event_lo[33];
    wire dcache_trace_demand_write = ~miss_trace_clear_lo & dcache_miss_accept
                                      & (dcache_count_r < (preview_trace_r ? 9'd232 : 9'd256));
    wire dcache_trace_remove_write = ~miss_trace_clear_lo & ~dcache_miss_accept
                                      & prefetch_remove_record
                                      & (prefetch_remove_count_r < 5'd16);
    wire dcache_trace_write = dcache_trace_demand_write | dcache_trace_remove_write;
    wire [7:0] dcache_trace_write_addr = dcache_trace_demand_write
                                          ? dcache_count_r[7:0]
                                          : (8'd232 + {4'b0, prefetch_remove_count_r[3:0]});
    wire [63:0] dcache_trace_write_data = dcache_trace_demand_write
                                            ? {cycle_r, dcache_req_cast.msg_type, dcache_req_cast.addr[33:6]}
                                            : {cycle_r, prefetch_remove_event_lo[31:0]};
    wire icache_trace_preview_write = ~miss_trace_clear_lo & preview_record
                                      & (preview_count_r < 4'd8);
    // Only a TV-stage consume has a PC. Replacement/store/L1 invalidations
    // need no I-side metadata write, so they may overlap publication safely.
    // Software reports zero metadata for those non-consume removal records.
    wire prefetch_consume_record = prefetch_remove_record
                                   & (prefetch_remove_event_lo[31:30] == 2'd0);
    wire icache_trace_remove_meta_write = ~miss_trace_clear_lo
                                           & prefetch_consume_record & ~preview_record
                                           & (prefetch_remove_count_r < 5'd16);
    wire icache_trace_write = (~miss_trace_clear_lo & icache_miss_accept
                               & (icache_count_r < 9'd256))
                              | icache_trace_preview_write | icache_trace_remove_meta_write;
    wire [7:0] icache_trace_write_addr = icache_trace_preview_write
                                          ? (8'd248 + {5'b0, preview_count_r[2:0]})
                                          : icache_trace_remove_meta_write
                                            ? (8'd232 + {4'b0, prefetch_remove_count_r[3:0]})
                                            : icache_count_r[7:0];
    // These sources are mutually exclusive. One-hot terms avoid a 64-bit
    // priority mux on the single BRAM write port in this slice-dense build.
    wire [63:0] icache_trace_write_data =
        ({64{icache_trace_preview_write}}
         & {cycle_r, 2'b11, preview_publish_addr_i[33:4]})
      | ({64{icache_trace_remove_meta_write}} & prefetch_remove_meta_lo)
      | ({64{icache_miss_accept}}
         & {cycle_r, icache_req_cast.msg_type, icache_req_cast.addr[33:6]});

    assign miss_trace_status_li =
      {prefetch_remove_count_r, preview_trace_r, preview_overflow_r, preview_count_r,
       preview_publish_count_r, preview_issue_count_r,
       preview_admit_count_r, preview_physical_count_r,
       armed_r, dcache_overflow_r, icache_overflow_r
       ,dcache_count_r, icache_count_r};
    assign miss_trace_data_li = miss_trace_read_source_r
                                ? dcache_trace_data_r
                                : icache_trace_data_r;

    always_ff @(posedge clk_i)
      if (reset_i) begin
        armed_r <= 1'b0;
        preview_trace_r <= 1'b0;
        preview_overflow_r <= 1'b0;
        preview_count_r <= '0;
        prefetch_remove_count_r <= '0;
        icache_overflow_r <= 1'b0;
        dcache_overflow_r <= 1'b0;
        icache_count_r <= '0;
        dcache_count_r <= '0;
        preview_physical_count_r <= '0;
        preview_admit_count_r <= '0;
        preview_issue_count_r <= '0;
        preview_publish_count_r <= '0;
        cycle_r <= '0;
        miss_trace_read_source_r <= 1'b0;
      end else begin
        cycle_r <= cycle_r + 1'b1;

        if (miss_trace_ctrl_v_lo) begin
          armed_r <= miss_trace_arm_lo;
          preview_trace_r <= miss_trace_preview_lo;
        end

        if (miss_trace_clear_lo) begin
          icache_overflow_r <= 1'b0;
          dcache_overflow_r <= 1'b0;
          icache_count_r <= '0;
          dcache_count_r <= '0;
          preview_overflow_r <= 1'b0;
          preview_count_r <= '0;
          prefetch_remove_count_r <= '0;
          preview_physical_count_r <= '0;
          preview_admit_count_r <= '0;
          preview_issue_count_r <= '0;
          preview_publish_count_r <= '0;
        end else begin
          if (preview_physical & ~(&preview_physical_count_r))
            preview_physical_count_r <= preview_physical_count_r + 1'b1;
          if (preview_events_i[0] & ~(&preview_admit_count_r))
            preview_admit_count_r <= preview_admit_count_r + 1'b1;
          if (preview_events_i[1] & ~(&preview_issue_count_r))
            preview_issue_count_r <= preview_issue_count_r + 1'b1;
          if (preview_events_i[2] & ~(&preview_publish_count_r))
            preview_publish_count_r <= preview_publish_count_r + 1'b1;
          if (icache_miss_accept) begin
            if (icache_count_r < 9'd256) begin
              icache_count_r <= icache_count_r + 1'b1;
            end else
              icache_overflow_r <= 1'b1;
          end

          // D-demand and removal still share one write port. Their collision
          // remains explicit, as does a D-cache TV/removal collision.
          if (prefetch_remove_record
              & (dcache_miss_accept | prefetch_remove_event_lo[32]))
            preview_overflow_r <= 1'b1;
          // A true consume still requires its PC and cannot share the I RAM
          // write port with a publication; reject that ambiguous transcript.
          if (prefetch_consume_record & preview_record)
            preview_overflow_r <= 1'b1;
          if (dcache_miss_accept) begin
            if (dcache_count_r < (preview_trace_r ? 9'd232 : 9'd256)) begin
              dcache_count_r <= dcache_count_r + 1'b1;
            end else
              dcache_overflow_r <= 1'b1;
          end
          if (prefetch_remove_record) begin
            if (prefetch_remove_count_r < 5'd16)
              prefetch_remove_count_r <= prefetch_remove_count_r + 1'b1;
            else
              preview_overflow_r <= 1'b1;
          end
          if (preview_record) begin
            if (preview_count_r < 4'd8) begin
              preview_count_r <= preview_count_r + 1'b1;
            end else
              preview_overflow_r <= 1'b1;
          end
        end

        // Each 256x64 history retains one physical write port for BRAM
        // inference; simultaneous I-publication and D-removal now both land.
        if (icache_trace_write)
          icache_trace_mem[icache_trace_write_addr] <= icache_trace_write_data;
        if (dcache_trace_write)
          dcache_trace_mem[dcache_trace_write_addr] <= dcache_trace_write_data;

        if (miss_trace_read_v_lo) begin
          // Keep the two registered read ports structurally independent so
          // Vivado can infer one simple dual-port block RAM per history.
          icache_trace_data_r <= icache_trace_mem[miss_trace_read_index_lo];
          dcache_trace_data_r <= dcache_trace_mem[miss_trace_read_index_lo];
          miss_trace_read_source_r <= miss_trace_read_source_lo;
        end
      end
  end else begin : gen_no_cache_miss_trace
    assign miss_trace_status_li = '0;
    assign miss_trace_data_li = '0;
  end

  bp_fe_top
   #(.bp_params_p(bp_params_p))
   fe
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.cfg_bus_i(cfg_bus_cast_i)

     ,.fe_queue_o(fe_queue_li)
     ,.fe_queue_v_o(fe_queue_v_li)
     ,.fe_queue_ready_and_i(fe_queue_ready_and_lo)

     ,.fe_cmd_i(fe_cmd_lo)
     ,.fe_cmd_v_i(fe_cmd_v_lo)
     ,.fe_cmd_yumi_o(fe_cmd_yumi_li)
     ,.ctxtsw_ready_o(fe_ctxtsw_ready_lo)
     ,.ctxtsw_v_i(fe_ctxtsw_v_lo)
     ,.ctxtsw_yumi_o(fe_ctxtsw_yumi_li)
     ,.ctxtsw_cancel_i(fe_ctxtsw_cancel_lo)
     ,.ctxtsw_npc_i(fe_ctxtsw_npc_lo)
     ,.ctxtsw_thread_id_i(fe_ctxtsw_thread_id_lo)
     ,.ctxtsw_priv_i(fe_ctxtsw_priv_lo)
     ,.ctxtsw_translation_en_i(fe_ctxtsw_translation_en_lo)
     ,.ctxtsw_asid_i(fe_ctxtsw_asid_lo)

     ,.cache_req_o(icache_req_o)
     ,.cache_req_v_o(icache_req_v_o)
     ,.cache_req_yumi_i(icache_req_yumi_i)
     ,.cache_req_lock_i(icache_req_lock_i)
     ,.cache_req_metadata_o(icache_req_metadata_o)
     ,.cache_req_metadata_v_o(icache_req_metadata_v_o)
     ,.cache_req_id_i(icache_req_id_i)
     ,.cache_req_critical_i(icache_req_critical_i)
     ,.cache_req_last_i(icache_req_last_i)
     ,.cache_req_credits_full_i(icache_req_credits_full_i)
     ,.cache_req_credits_empty_i(icache_req_credits_empty_i)

     ,.tag_mem_pkt_i(icache_tag_mem_pkt_i)
     ,.tag_mem_pkt_v_i(icache_tag_mem_pkt_v_i)
     ,.tag_mem_pkt_yumi_o(icache_tag_mem_pkt_yumi_o)
     ,.tag_mem_o(icache_tag_mem_o)

     ,.data_mem_pkt_i(icache_data_mem_pkt_i)
     ,.data_mem_pkt_v_i(icache_data_mem_pkt_v_i)
     ,.data_mem_pkt_yumi_o(icache_data_mem_pkt_yumi_o)
     ,.data_mem_o(icache_data_mem_o)

     ,.stat_mem_pkt_v_i(icache_stat_mem_pkt_v_i)
     ,.stat_mem_pkt_i(icache_stat_mem_pkt_i)
     ,.stat_mem_pkt_yumi_o(icache_stat_mem_pkt_yumi_o)
     ,.stat_mem_o(icache_stat_mem_o)
     );

  bp_be_top
   #(.bp_params_p(bp_params_p))
   be
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.cfg_bus_i(cfg_bus_cast_i)

     ,.fe_queue_i(fe_queue_li)
     ,.fe_queue_v_i(fe_queue_v_li)
     ,.fe_queue_ready_and_o(fe_queue_ready_and_lo)

     ,.fe_cmd_o(fe_cmd_lo)
     ,.fe_cmd_v_o(fe_cmd_v_lo)
     ,.fe_cmd_yumi_i(fe_cmd_yumi_li)
     ,.fe_ctxtsw_ready_i(fe_ctxtsw_ready_lo)
     ,.fe_ctxtsw_v_o(fe_ctxtsw_v_lo)
     ,.fe_ctxtsw_yumi_i(fe_ctxtsw_yumi_li)
     ,.fe_ctxtsw_cancel_o(fe_ctxtsw_cancel_lo)
     ,.fe_ctxtsw_npc_o(fe_ctxtsw_npc_lo)
     ,.fe_ctxtsw_thread_id_o(fe_ctxtsw_thread_id_lo)
     ,.fe_ctxtsw_priv_o(fe_ctxtsw_priv_lo)
     ,.fe_ctxtsw_translation_en_o(fe_ctxtsw_translation_en_lo)
     ,.fe_ctxtsw_asid_o(fe_ctxtsw_asid_lo)

     ,.cache_req_o(dcache_req_o)
     ,.cache_req_v_o(dcache_req_v_o)
     ,.cache_req_yumi_i(dcache_req_yumi_i)
     ,.cache_req_lock_i(dcache_req_lock_i)
     ,.cache_req_metadata_o(dcache_req_metadata_o)
     ,.cache_req_metadata_v_o(dcache_req_metadata_v_o)
     ,.cache_req_id_i(dcache_req_id_i)
     ,.cache_req_critical_i(dcache_req_critical_i)
     ,.cache_req_last_i(dcache_req_last_i)
     ,.cache_req_credits_full_i(dcache_req_credits_full_i)
     ,.cache_req_credits_empty_i(dcache_req_credits_empty_i)

     ,.data_mem_pkt_i(dcache_data_mem_pkt_i)
     ,.data_mem_pkt_v_i(dcache_data_mem_pkt_v_i)
     ,.data_mem_pkt_yumi_o(dcache_data_mem_pkt_yumi_o)
     ,.prefetch_remove_event_o(prefetch_remove_event_lo)
     ,.prefetch_remove_meta_o(prefetch_remove_meta_lo)
     ,.data_mem_o(dcache_data_mem_o)

     ,.tag_mem_pkt_i(dcache_tag_mem_pkt_i)
     ,.tag_mem_pkt_v_i(dcache_tag_mem_pkt_v_i)
     ,.tag_mem_pkt_yumi_o(dcache_tag_mem_pkt_yumi_o)
     ,.tag_mem_o(dcache_tag_mem_o)

     ,.stat_mem_pkt_v_i(dcache_stat_mem_pkt_v_i)
     ,.stat_mem_pkt_i(dcache_stat_mem_pkt_i)
     ,.stat_mem_pkt_yumi_o(dcache_stat_mem_pkt_yumi_o)
     ,.stat_mem_o(dcache_stat_mem_o)

     ,.debug_irq_i(debug_irq_i)
     ,.timer_irq_i(timer_irq_i)
     ,.software_irq_i(software_irq_i)
     ,.m_external_irq_i(m_external_irq_i)
     ,.s_external_irq_i(s_external_irq_i)
     ,.miss_trace_status_i(miss_trace_status_li)
     ,.miss_trace_data_i(miss_trace_data_li)
     ,.miss_trace_ctrl_v_o(miss_trace_ctrl_v_lo)
     ,.miss_trace_arm_o(miss_trace_arm_lo)
     ,.miss_trace_preview_o(miss_trace_preview_lo)
     ,.miss_trace_clear_o(miss_trace_clear_lo)
     ,.miss_trace_read_v_o(miss_trace_read_v_lo)
     ,.miss_trace_read_source_o(miss_trace_read_source_lo)
     ,.miss_trace_read_index_o(miss_trace_read_index_lo)
     ,.physical_preview_v_o(physical_preview_v_lo)
     ,.physical_preview_paddr_o(physical_preview_paddr_lo)
     );

endmodule
