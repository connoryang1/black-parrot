/**
 *
 * Name:
 *   bp_fe_icache.sv
 *
 * Description:
 *   L1 Instruction Cache. Features:
 *   - Virtually-indexed, physically-tagged
 *   - 1-8 way set-associative
 *   - 64-512 bit block size (minimum 64-bit data mem bank size)
 *   - Separate speculative and non-speculative fetch commands
 *
 *   An address is broken down as follows:
 *     physical address = [physical tag | virtual index | block offset]
 *
 *   There are 3 large SRAMs (must be hardened for good QoR):
 *   - Tag Mem: Physical tags and coherence state
 *   - Data Mem: Cache data blocks. 1 bank per way, with data
 *       interleaved between the banks as bank_id = word_offset + way_id
 *   - Stat Mem: Contains the LRU and information for the cache line
 *
 * See interface for usage notes
 *
 * Notes:
 *    Supports multi-cycle fill/eviction with the UCE in unicore configuration
 *    Uses fill_index in data_mem_pkt to generate a write_mask for the data banks
 *      bank_width = block_width / assoc >= dword_width
 *      fill_width = N*bank_width <= block_width
 */

`include "bp_common_defines.svh"
`include "bp_fe_defines.svh"

module bp_fe_icache
 import bp_common_pkg::*;
 import bp_fe_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)

   // Default to icache parameters, but can override if needed
   , parameter features_p    = icache_features_p
   , parameter misaligned_p  = features_p[e_cfg_misaligned]
   , parameter coherent_p    = features_p[e_cfg_coherent]
   , parameter sets_p        = icache_sets_p
   , parameter assoc_p       = icache_assoc_p
   , parameter block_width_p = icache_block_width_p
   , parameter fill_width_p  = icache_fill_width_p
   , parameter data_width_p  = icache_data_width_p
   , parameter tag_width_p   = icache_tag_width_p
   , parameter id_width_p    = icache_req_id_width_p
   , parameter bit replay_buffer_p = 1'b0
   , parameter replay_buffer_els_p = 16
   , parameter bit replay_buffer_bram_p = 1'b0

   `declare_bp_common_if_widths(vaddr_width_p, hio_width_p, core_id_width_p, cce_id_width_p, lce_id_width_p, did_width_p)
   `declare_bp_fe_icache_engine_if_widths(paddr_width_p, tag_width_p, sets_p, assoc_p, data_width_p, block_width_p, fill_width_p, id_width_p)
   , localparam icache_pkt_width_lp = `bp_fe_icache_pkt_width(vaddr_width_p)
   )
  (input                                              clk_i
   , input                                            reset_i

   // Cycle 0: "Decode"
   // New I$ packet comes in for a fetch, fence or fill request
   // v_i is raised when there is a new request
   // yumi_o is raised when that request is accepted
   // Normally, yumi_o waits for TL to be empty so as to not lose
   //   requests. However, when we're redirecting the I$ we may want
   //   to override the TL message right away. force_i says to accept
   //   regardless of v_tl_r status
   , input [icache_pkt_width_lp-1:0]                  icache_pkt_i
   , input                                            v_i
   , input                                            force_i
   , input                                            miss_abort_i
   , output                                           yumi_o
   , input                                            tl_flush_i

   // Cycle 1: "Tag Lookup"
   // TLB and PMA information comes in this cycle
   // tv_flush_i eliminates the request in this stage, used for redirections
   // We output tv_we as a signal to move parallel pipelines forward
   , input [ptag_width_p-1:0]                         ptag_i
   , input                                            ptag_v_i
   , input                                            ptag_uncached_i
   , input                                            ptag_nonidem_i
   , input                                            ptag_dram_i
   , input                                            tv_flush_i
   , output logic                                     tv_we_o

   // Cycle 2: "Tag Verify"
   // Data (or miss result) comes out of the cache
   // Cache engine requests cannot be cancelled once they come here, but tv_flush_i
   //   will prevent them from escaping the I$.
   // data_o is the outgoing data, with v_o being valid
   // yumi_i is dequeues the data
   , output logic [data_width_p-1:0]                  data_o
   , output logic                                     hit_v_o
   , output logic                                     miss_v_o
   , output logic                                     fence_v_o
   , input                                            yumi_i

   // Physical lookup for suppressing refreshes of completed advisory lines.
   // Partial entries are deliberately reported absent.
   , input                                            replay_query_v_i
   , input [paddr_width_p-1:0]                        replay_query_paddr_i
   , output logic                                     replay_query_hit_o

   // Experimental global retention policy, updated only at CSR retirement.
   , input                                            retention_cmd_v_i
   , input [1:0]                                      retention_mode_i
   , output logic [63:0]                              retention_status_o

   // Optional miss-only synchronous retained-store lane.  Lookup enable is
   // separate from demand admission: baseline-off bypasses its extra latency,
   // while advisory-only replay may look up lines with retention mode zero.
   , input                                            retention_lookup_enable_i
   , output                                           retained_lookup_v_o
   , input                                            retained_lookup_ready_i
   , output [paddr_width_p-1:0]                        retained_lookup_paddr_o
   , input                                            retained_resp_v_i
   , output                                           retained_resp_ready_o
   , input                                            retained_resp_hit_i
   , input [block_width_p-1:0]                        retained_resp_data_i
   , output                                           retained_insert_v_o
   , input                                            retained_insert_ready_i
   , output [paddr_width_p-1:0]                        retained_insert_paddr_o
   , output [block_width_p-1:0]                        retained_insert_data_o
   , output                                           retained_insert_replace_o
   , output                                           retained_insert_cancel_o
   , input                                            retained_insert_done_i
   , input                                            retained_insert_published_i
   , output                                           retained_clear_o
   , output                                           retained_drop_o
   , output                                           retained_idle_o

   // Cache Engine Interface
   // This is considered the "slow path", handling uncached requests
   //   and fill DMAs. It also handles coherence transactions for
   //   configurations which support that behavior
   , output logic [icache_req_width_lp-1:0]           cache_req_o
   , output logic                                     cache_req_v_o
   , input                                            cache_req_yumi_i
   , input                                            cache_req_lock_i
   , output logic [icache_req_metadata_width_lp-1:0]  cache_req_metadata_o
   , output logic                                     cache_req_metadata_v_o
   , input [id_width_p-1:0]                           cache_req_id_i
   , input                                            cache_req_critical_i
   , input                                            cache_req_last_i
   , input                                            cache_req_credits_full_i
   , input                                            cache_req_credits_empty_i

   , input                                            data_mem_pkt_v_i
   , input [icache_data_mem_pkt_width_lp-1:0]         data_mem_pkt_i
   , output logic                                     data_mem_pkt_yumi_o
   , output logic [block_width_p-1:0]                 data_mem_o

   , input                                            tag_mem_pkt_v_i
   , input [icache_tag_mem_pkt_width_lp-1:0]          tag_mem_pkt_i
   , output logic                                     tag_mem_pkt_yumi_o
   , output logic [icache_tag_info_width_lp-1:0]      tag_mem_o
   // Whole tag row of the last engine tag read (all ways), for one-cycle replay duplicate scans.
   , output logic [assoc_p*(icache_tag_info_width_lp+1)-1:0] tag_row_o

   , input                                            stat_mem_pkt_v_i
   , input [icache_stat_mem_pkt_width_lp-1:0]         stat_mem_pkt_i
   , output logic                                     stat_mem_pkt_yumi_o
   , output logic [icache_stat_info_width_lp-1:0]     stat_mem_o
   );

  `declare_bp_fe_icache_engine_if(paddr_width_p, tag_width_p, sets_p, assoc_p, data_width_p, block_width_p, fill_width_p, id_width_p);

  // Various localparameters
  localparam lg_assoc_lp            =`BSG_SAFE_CLOG2(assoc_p);
  localparam bank_width_lp          = block_width_p / assoc_p;
  localparam num_data_per_bank_lp   = bank_width_lp / data_width_p;
  localparam data_mem_mask_width_lp = (bank_width_lp >> 3);
  localparam byte_offset_width_lp   = `BSG_SAFE_CLOG2(bank_width_lp >> 3);
  localparam bindex_width_lp        = `BSG_SAFE_CLOG2(assoc_p);
  localparam sindex_width_lp        = `BSG_SAFE_CLOG2(sets_p);
  localparam block_offset_width_lp  = (assoc_p > 1)
    ? (bindex_width_lp+byte_offset_width_lp)
    : byte_offset_width_lp;
  localparam block_size_in_fill_lp  = block_width_p / fill_width_p;
  localparam fill_size_in_bank_lp   = fill_width_p / bank_width_lp;
  // The large backend owns all payload/tag capacity.  Constant-prune the
  // legacy asynchronous store rather than silently growing its CAM.
  localparam replay_buffer_els_lp = (replay_buffer_p & ~replay_buffer_bram_p)
    ? replay_buffer_els_p : 1;
  localparam replay_buffer_slot_width_lp = `BSG_SAFE_CLOG2(replay_buffer_els_lp);
  localparam replay_words_per_line_lp = block_width_p / data_width_p;
  localparam replay_words_per_fill_lp = fill_width_p / data_width_p;
  // The 32-entry FPGA configuration is organized as four hashed banks of
  // eight associative ways.  Fixed-capacity banking removes the 32-way tag
  // search from the fetch path while preserving one monolithic 32-entry data
  // index.  The selected XORs distribute every retained Linux prefix used by
  // this project within eight ways; other capacities keep the legacy flat
  // organization and replacement policy.
  localparam replay_buffer_banks_lp = 4;
  localparam replay_buffer_bank_width_lp = `BSG_SAFE_CLOG2(replay_buffer_banks_lp);
  localparam replay_buffer_bank_ways_lp = replay_buffer_els_lp / replay_buffer_banks_lp;
  localparam replay_buffer_bank_way_width_lp = `BSG_SAFE_CLOG2(replay_buffer_bank_ways_lp);
  localparam replay_buffer_banked_lp = replay_buffer_p & (replay_buffer_els_lp == 32);
  typedef logic [paddr_width_p-block_offset_width_lp-1:0] replay_line_addr_s;

  function automatic logic [replay_buffer_bank_width_lp-1:0]
    replay_buffer_bank(input replay_line_addr_s line_addr);
    replay_buffer_bank[0] = line_addr[0] ^ line_addr[13];
    replay_buffer_bank[1] = line_addr[3] ^ line_addr[6];
  endfunction

  // State machine declaration
  enum logic [1:0] {e_ready, e_miss, e_recover} state_n, state_r;
  wire is_ready    = (state_r == e_ready);
  wire is_miss     = (state_r == e_miss);
  wire is_recover  = (state_r == e_recover);

  // Feedback signals between stages
  logic tl_we, tv_we;
  logic v_tl_n, v_tl_r;
  logic v_tv_n, v_tv_r;

  // Keep the normal refill handshakes on their original ready/valid path.
  // Context-switch aborts are a separate path and must not alter ordinary
  // redirects or create a feedback path through the UCE SRAM ports.
  wire critical_recv = is_miss & cache_req_critical_i & ~miss_abort_i
    & (~stat_mem_pkt_v_i | stat_mem_pkt_yumi_o)
    & (~tag_mem_pkt_v_i | tag_mem_pkt_yumi_o)
    & (~data_mem_pkt_v_i | data_mem_pkt_yumi_o);
  wire complete_recv = is_miss & cache_req_last_i & ~miss_abort_i
    & (~stat_mem_pkt_v_i | stat_mem_pkt_yumi_o)
    & (~tag_mem_pkt_v_i | tag_mem_pkt_yumi_o)
    & (~data_mem_pkt_v_i | data_mem_pkt_yumi_o);

  // The UCE holds last and its refill packets until the SRAM handshakes
  // complete.  Use that held intent for the abort decision; feeding the
  // packet yummies back through complete_recv creates a combinational cycle
  // through SRAM arbitration and the UCE refill counters.
  wire abort_miss = is_miss & miss_abort_i & ~cache_req_last_i;
  logic abort_miss_r;
  wire abort_recv = abort_miss_r
    & (~stat_mem_pkt_v_i | stat_mem_pkt_yumi_o)
    & (~tag_mem_pkt_v_i | tag_mem_pkt_yumi_o)
    & (~data_mem_pkt_v_i | data_mem_pkt_yumi_o);
  wire abort_complete = abort_recv & cache_req_last_i;
  logic [paddr_width_p-1:0] abort_miss_paddr_r;
  logic [lg_assoc_lp-1:0] abort_miss_way_r;
  wire abort_inflight = abort_miss | abort_miss_r;

  // Snoop signals
  logic [block_width_p-1:0] snoop_data;
  logic [assoc_p-1:0] snoop_hit;
  logic [assoc_p-1:0] snoop_way;
  logic [assoc_p-1:0] snoop_bank_sel_one_hot;
  logic snoop_spec, snoop_uncached;
  bp_fe_icache_decode_s snoop_decode;

  /////////////////////////////////////////////////////////////////////////////
  // Decode stage
  /////////////////////////////////////////////////////////////////////////////
  `declare_bp_fe_icache_pkt_s(vaddr_width_p);
  `bp_cast_i(bp_fe_icache_pkt_s, icache_pkt);
  bp_fe_icache_decode_s decode_lo;

  wire [vaddr_width_p-1:0]   vaddr       = icache_pkt_cast_i.vaddr;
  wire [vtag_width_p-1:0]    vaddr_vtag  = vaddr[(vaddr_width_p-1)-:vtag_width_p];
  wire [sindex_width_lp-1:0] vaddr_index = vaddr[block_offset_width_lp+:sindex_width_lp];
  wire [bindex_width_lp-1:0] vaddr_bank  = vaddr[byte_offset_width_lp+:bindex_width_lp];

  wire spec = icache_pkt_cast_i.spec;

  assign decode_lo = '{fetch_op : icache_pkt_cast_i.op inside {e_icache_fetch}
                       ,inval_op: icache_pkt_cast_i.op inside {e_icache_inval}
                       };

  // A slow-path cache lock must drain an already-resident TL entry without
  // replacing it with a new frontend request.  The shared TL write enable is
  // still asserted for that drain, so gate the upstream acceptance separately;
  // otherwise ordinary fetches can interleave with installer tag/data SRAM
  // operations and pair a later PC with stale bank-zero instruction data.
  assign yumi_o = v_i & tl_we & ~cache_req_lock_i;

  ///////////////////////////
  // Tag Mem Storage
  ///////////////////////////
  `bp_cast_i(bp_fe_icache_tag_mem_pkt_s, tag_mem_pkt);
  logic                              tag_mem_v_li;
  logic                              tag_mem_w_li;
  logic [sindex_width_lp-1:0]        tag_mem_addr_li;
  bp_fe_icache_tag_info_s [assoc_p-1:0] tag_mem_w_mask_li;
  bp_fe_icache_tag_info_s [assoc_p-1:0] tag_mem_data_li;
  bp_fe_icache_tag_info_s [assoc_p-1:0] tag_mem_data_lo;

  bsg_mem_1rw_sync_mask_write_bit
   #(.width_p(assoc_p*($bits(bp_fe_icache_tag_info_s))), .els_p(sets_p), .latch_last_read_p(1))
   tag_mem
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.data_i(tag_mem_data_li)
     ,.addr_i(tag_mem_addr_li)
     ,.v_i(tag_mem_v_li)
     ,.w_mask_i(tag_mem_w_mask_li)
     ,.w_i(tag_mem_w_li)
     ,.data_o(tag_mem_data_lo)
     );

  ///////////////////////////
  // Data Mem Storage
  ///////////////////////////
  `bp_cast_i(bp_fe_icache_data_mem_pkt_s, data_mem_pkt);
  localparam data_mem_addr_width_lp = (assoc_p > 1) ? (sindex_width_lp+bindex_width_lp) : sindex_width_lp;
  logic [assoc_p-1:0]                             data_mem_v_li;
  logic [assoc_p-1:0]                             data_mem_w_li;
  logic [assoc_p-1:0][data_mem_addr_width_lp-1:0] data_mem_addr_li;
  logic [assoc_p-1:0][bank_width_lp-1:0]          data_mem_data_li;
  logic [assoc_p-1:0][bank_width_lp-1:0]          data_mem_data_lo;

  for (genvar bank = 0; bank < assoc_p; bank++)
    begin: data_mems
      bsg_mem_1rw_sync #(.width_p(bank_width_lp), .els_p(sets_p*assoc_p), .latch_last_read_p(1))
       data_mem
        (.clk_i(clk_i)
         ,.reset_i(reset_i)
         ,.data_i(data_mem_data_li[bank])
         ,.addr_i(data_mem_addr_li[bank])
         ,.v_i(data_mem_v_li[bank])
         ,.w_i(data_mem_w_li[bank])
         ,.data_o(data_mem_data_lo[bank])
         );
    end

  /////////////////////////////////////////////////////////////////////////////
  // TL Stage
  /////////////////////////////////////////////////////////////////////////////
  logic [vaddr_width_p-1:0] vaddr_tl_r;
  logic spec_tl_r;
  bp_fe_icache_decode_s decode_tl_r;

  wire tl_we_raw = v_tl_r ? (tv_we | force_i) : ~cache_req_lock_i;
  // Stop fetch progress only while draining a context-switch abort.  Do not
  // feed UCE SRAM-valid signals into this path: that creates a combinational
  // loop through TL, the SRAM arbiters, and the UCE refill counters.
  assign tl_we = tl_we_raw & ~abort_inflight;
  bsg_dff_reset_en
   #(.width_p(1))
   v_tl_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i | tl_flush_i)
     ,.en_i(tl_we)
     ,.data_i(yumi_o)
     ,.data_o(v_tl_r)
     );

  // Save stage information
  bsg_dff_reset_en
   #(.width_p(vaddr_width_p+1+$bits(bp_fe_icache_decode_s)))
   tl_stage_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(tl_we)
     ,.data_i({vaddr, spec, decode_lo})
     ,.data_o({vaddr_tl_r, spec_tl_r, decode_tl_r})
     );

  wire [paddr_width_p-1:0]         paddr_tl = {ptag_i, vaddr_tl_r[0+:page_offset_width_gp]};
  wire [vtag_width_p-1:0]     vaddr_vtag_tl = vaddr_tl_r[(vaddr_width_p-1)-:vtag_width_p];
  wire [sindex_width_lp-1:0] vaddr_index_tl = vaddr_tl_r[block_offset_width_lp+:sindex_width_lp];
  wire [bindex_width_lp-1:0]  vaddr_bank_tl = vaddr_tl_r[byte_offset_width_lp+:bindex_width_lp];

  // Concatenate unused bits from vaddr if any cache way size is not 4kb
  localparam ctag_vbits_lp = page_offset_width_gp - (block_offset_width_lp + sindex_width_lp);
  wire [`BSG_MAX(ctag_vbits_lp,1)-1:0] ctag_vbits = vaddr_tl_r[block_offset_width_lp+sindex_width_lp+:`BSG_MAX(ctag_vbits_lp,1)];
  // Causes segfault in Synopsys DC O-2018.06-SP4
  // wire [tag_width_p-1:0] ctag_li = {ptag_i, {ctag_vbits_lp!=0{ctag_vbits}}};
  wire [tag_width_p-1:0] ctag_li = tag_width_p'((ctag_vbits_lp!=0) ? {ptag_i, ctag_vbits} : ptag_i);
  wire [paddr_width_p-1:caddr_width_p] ptag_high_li = paddr_tl[paddr_width_p-1:caddr_width_p];

  logic [assoc_p-1:0] way_v_tl, hit_v_tl;
  for (genvar i = 0; i < assoc_p; i++) begin: tag_comp_tl
    wire tag_match_tl  = ptag_v_i & ~|ptag_high_li & (ctag_li == tag_mem_data_lo[i].tag);
    assign way_v_tl[i] = (tag_mem_data_lo[i].state != e_COH_I);
    assign hit_v_tl[i] = tag_match_tl & (tag_mem_data_lo[i].tag == ctag_li && way_v_tl[i]);
  end
  wire fetch_uncached_tl = (decode_tl_r.fetch_op &  ptag_uncached_i);
  wire fetch_cached_tl   = (decode_tl_r.fetch_op & ~ptag_uncached_i);
  wire spec_tl           = (decode_tl_r.fetch_op & !ptag_v_i)
                           || (decode_tl_r.fetch_op & spec_tl_r & ptag_nonidem_i);

  logic [assoc_p-1:0] bank_sel_one_hot_tl;
  bsg_decode
   #(.num_out_p(assoc_p))
   offset_decode
    (.i(vaddr_bank_tl)
     ,.o(bank_sel_one_hot_tl)
     );

  /////////////////////////////////////////////////////////////////////////////
  // TV Stage
  /////////////////////////////////////////////////////////////////////////////
  localparam snoop_offset_width_lp = `BSG_SAFE_CLOG2(fill_width_p/word_width_gp);
  logic [paddr_width_p-1:0]              paddr_tv_r;
  logic [assoc_p-1:0]                    bank_sel_one_hot_tv_r, way_v_tv_r, hit_v_tv_r;
  logic                                  spec_tv_r, uncached_tv_r;
  bp_fe_icache_decode_s                  decode_tv_r;
  logic                                  snoop_tv_r;
  logic [assoc_p-1:0][bank_width_lp-1:0] ld_data_tv_r;

  // Do not advance TL->TV while a detached replay install holds the cache:
  // new TL entries are refused then, so the move would leave IF1 empty, and
  // when the lock drops IF2 would be consumed in the same cycle its successor
  // is first accepted. pc_gen's past-incomplete-instruction check (ovr_linear)
  // compares against the registered IF1 prediction, so a block-aliased taken
  // prediction would then join a held instruction half to the target block.
  assign tv_we = v_tv_r ? yumi_i : (is_ready & ~cache_req_lock_i);
  bsg_dff_reset_en
   #(.width_p(1))
   v_tv_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i | tv_flush_i)
     ,.en_i(tv_we)
     ,.data_i(v_tl_r)
     ,.data_o(v_tv_r)
     );
  assign tv_we_o = tv_we;

  logic [assoc_p-1:0] bank_sel_one_hot_tv_n, way_v_tv_n, hit_v_tv_n;
  logic [block_width_p-1:0] ld_data_tv_n;
  logic spec_tv_n, uncached_tv_n;
  bp_fe_icache_decode_s decode_tv_n;
  bsg_mux
   #(.width_p(3*assoc_p+block_width_p+2+$bits(bp_fe_icache_decode_s)), .els_p(2))
   hit_mux
    (.data_i({{snoop_bank_sel_one_hot, snoop_way, snoop_hit, snoop_data
               ,snoop_spec, snoop_uncached, snoop_decode}
               ,{bank_sel_one_hot_tl, way_v_tl, hit_v_tl, data_mem_data_lo
               ,spec_tl, fetch_uncached_tl, decode_tl_r}
              })
     ,.sel_i(critical_recv)
     ,.data_o({bank_sel_one_hot_tv_n, way_v_tv_n, hit_v_tv_n, ld_data_tv_n
               ,spec_tv_n, uncached_tv_n, decode_tv_n})
     );

  wire snoop_tv_n = critical_recv;
  bsg_dff_reset_en
   #(.width_p(block_width_p+1+3*assoc_p+2+$bits(bp_fe_icache_decode_s)))
   tv_stage_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.en_i(tv_we | critical_recv)
     ,.data_i({ld_data_tv_n, snoop_tv_n, bank_sel_one_hot_tv_n, way_v_tv_n, hit_v_tv_n
               ,spec_tv_n, uncached_tv_n, decode_tv_n
               })
     ,.data_o({ld_data_tv_r, snoop_tv_r, bank_sel_one_hot_tv_r, way_v_tv_r, hit_v_tv_r
               ,spec_tv_r, uncached_tv_r, decode_tv_r
               })
     );

  wire [paddr_width_p-1:0] paddr_tv_n = critical_recv ? paddr_tv_r : paddr_tl;
  bsg_dff_en
   #(.width_p(paddr_width_p))
   paddr_reg
    (.clk_i(clk_i)
     ,.en_i(tv_we | critical_recv)
     ,.data_i(paddr_tv_n)
     ,.data_o(paddr_tv_r)
     );

  logic [lg_assoc_lp-1:0] invalid_way_tv;
  logic invalid_exist_tv;
  bsg_priority_encode
   #(.width_p(assoc_p), .lo_to_hi_p(1))
   pe_invalid
    (.i(~way_v_tv_r)
     ,.v_o(invalid_exist_tv)
     ,.addr_o(invalid_way_tv)
     );

  // If there is invalid way, then it take priority over LRU way.
  logic [lg_assoc_lp-1:0] lru_encode;
  wire [lg_assoc_lp-1:0] lru_way_li = invalid_exist_tv ? invalid_way_tv : lru_encode;

  logic [lg_assoc_lp-1:0] hit_index_tv;
  logic cache_hit_v_tv;
  bsg_encode_one_hot
   #(.width_p(assoc_p), .lo_to_hi_p(1))
   hit_index_encoder
    (.i(hit_v_tv_r)
     ,.addr_o(hit_index_tv)
     ,.v_o(cache_hit_v_tv)
     );

  logic [assoc_p-1:0] hit_way_one_hot_tv;
  bsg_decode
   #(.num_out_p(assoc_p))
   hit_way_decode
    (.i(hit_index_tv)
     ,.o(hit_way_one_hot_tv)
     );

  logic [assoc_p-1:0] ld_data_way_select_tv;
  bsg_adder_one_hot
   #(.width_p(assoc_p))
   select_adder
    (.a_i({assoc_p{cache_hit_v_tv}} & hit_way_one_hot_tv)
     ,.b_i(bank_sel_one_hot_tv_r)
     ,.o(ld_data_way_select_tv)
     );

  logic [bank_width_lp-1:0] ld_data_way_picked;
  bsg_mux_one_hot
   #(.width_p(bank_width_lp), .els_p(assoc_p))
   data_set_select_mux
    (.data_i(ld_data_tv_r)
     ,.sel_one_hot_i(ld_data_way_select_tv)
     ,.data_o(ld_data_way_picked)
     );

  // Completed detached replies live in this buffer until replacement or
  // fence.i. They are looked up only after the ordinary MMU has supplied a
  // valid physical executable address, and never alter the live cache SRAMs.
  logic [replay_buffer_els_lp-1:0] replay_buffer_alloc_r;
  logic [replay_buffer_els_lp-1:0][paddr_width_p-block_offset_width_lp-1:0]
    replay_buffer_addr_r;
  logic [replay_buffer_els_lp-1:0][block_size_in_fill_lp-1:0]
    replay_buffer_beat_v_r;
  logic [replay_buffer_slot_width_lp-1:0] replay_buffer_replace_r;
  logic [replay_words_per_line_lp-1:0][data_width_p-1:0]
    replay_buffer_word_data_lo;

  logic replay_buffer_hit_tv;
  logic legacy_replay_buffer_hit_tv;
  logic retained_wait, retained_hit, retained_demand_published;
  logic [block_width_p-1:0] retained_data;
  logic [replay_buffer_slot_width_lp-1:0] replay_buffer_hit_slot_tv;
  logic [data_width_p-1:0] replay_buffer_data_tv;
  wire [replay_buffer_bank_width_lp-1:0] replay_buffer_hit_bank_tv
    = replay_buffer_bank(paddr_tv_r[paddr_width_p-1:block_offset_width_lp]);
  always_comb begin
    legacy_replay_buffer_hit_tv = 1'b0;
    replay_buffer_hit_slot_tv = '0;
    if (replay_buffer_banked_lp) begin
      for (int way = replay_buffer_bank_ways_lp-1; way >= 0; way--) begin
        automatic logic [replay_buffer_slot_width_lp-1:0] slot
          = replay_buffer_slot_width_lp'
              (replay_buffer_hit_bank_tv*replay_buffer_bank_ways_lp + way);
        if (replay_buffer_alloc_r[slot]
            & (&replay_buffer_beat_v_r[slot])
            & (replay_buffer_addr_r[slot]
               == paddr_tv_r[paddr_width_p-1:block_offset_width_lp])) begin
          legacy_replay_buffer_hit_tv = 1'b1;
          replay_buffer_hit_slot_tv = slot;
        end
      end
    end else begin
      for (int i = replay_buffer_els_lp-1; i >= 0; i--)
        if (replay_buffer_p & ~replay_buffer_bram_p & replay_buffer_alloc_r[i]
            & (&replay_buffer_beat_v_r[i])
            & (replay_buffer_addr_r[i]
               == paddr_tv_r[paddr_width_p-1:block_offset_width_lp])) begin
          legacy_replay_buffer_hit_tv = 1'b1;
          replay_buffer_hit_slot_tv = replay_buffer_slot_width_lp'(i);
        end
    end
    legacy_replay_buffer_hit_tv &= v_tv_r & decode_tv_r.fetch_op & ~spec_tv_r
      & ~uncached_tv_r & ~cache_hit_v_tv;
  end
  wire [replay_buffer_bank_width_lp-1:0] replay_buffer_query_bank
    = replay_buffer_bank
        (replay_query_paddr_i[paddr_width_p-1:block_offset_width_lp]);
  always_comb begin
    replay_query_hit_o = 1'b0;
    if (replay_buffer_banked_lp) begin
      for (int way = 0; way < replay_buffer_bank_ways_lp; way++) begin
        automatic logic [replay_buffer_slot_width_lp-1:0] slot
          = replay_buffer_slot_width_lp'
              (replay_buffer_query_bank*replay_buffer_bank_ways_lp + way);
        replay_query_hit_o |= replay_query_v_i
          & replay_buffer_alloc_r[slot] & (&replay_buffer_beat_v_r[slot])
          & (replay_buffer_addr_r[slot]
             == replay_query_paddr_i[paddr_width_p-1:block_offset_width_lp]);
      end
    end else begin
      for (int i = 0; i < replay_buffer_els_lp; i++)
        replay_query_hit_o |= replay_buffer_p & ~replay_buffer_bram_p & replay_query_v_i
          & replay_buffer_alloc_r[i] & (&replay_buffer_beat_v_r[i])
          & (replay_buffer_addr_r[i]
             == replay_query_paddr_i[paddr_width_p-1:block_offset_width_lp]);
    end
  end
  assign replay_buffer_hit_tv = replay_buffer_bram_p ? retained_hit : legacy_replay_buffer_hit_tv;
  bsg_mux
   #(.width_p(data_width_p), .els_p(replay_words_per_line_lp))
   replay_buffer_word_mux
    (.data_i(replay_buffer_word_data_lo)
     ,.sel_i(paddr_tv_r[`BSG_SAFE_CLOG2(data_width_p/8)
                         +: `BSG_SAFE_CLOG2(replay_words_per_line_lp)])
     ,.data_o(replay_buffer_data_tv)
     );
  wire hit_v_tv = cache_hit_v_tv | replay_buffer_hit_tv;

  // TODO: Can retime manually for critical path?
  logic [data_width_p-1:0] cache_data_tv;
  wire [`BSG_SAFE_CLOG2(num_data_per_bank_lp)-1:0] ld_data_word_sel_tv =
    paddr_tv_r[2+:`BSG_SAFE_CLOG2(num_data_per_bank_lp)];
  bsg_mux
   #(.width_p(data_width_p), .els_p(num_data_per_bank_lp))
   data_select_mux
    (.data_i(ld_data_way_picked)
     ,.sel_i(ld_data_word_sel_tv)
     ,.data_o(cache_data_tv)
     );

  wire [data_width_p-1:0] retained_word = retained_data
    [paddr_tv_r[`BSG_SAFE_CLOG2(data_width_p/8)+:`BSG_SAFE_CLOG2(replay_words_per_line_lp)]
     *data_width_p+:data_width_p];
  assign data_o = replay_buffer_hit_tv
    ? (replay_buffer_bram_p ? retained_word : replay_buffer_data_tv) : cache_data_tv;
  // Detached replay installs write the tag/data SRAMs while the cache is
  // e_ready (demand fills only write in e_miss and then recover). A fetch in
  // TL/TV across such a write may hold a stale miss (refilling it would
  // duplicate the line in a second way) or SRAM output disturbed by the write
  // or reused through the same-index bypass. Report such a fetch as a miss
  // without a request so the FE refetches; the redirect flushes TL, so the
  // refetch re-reads the SRAMs.
  logic install_stale_fetch_tv;  // driven below the SRAM write decode

  // While a detached replay install holds the cache (cache_req_lock_i), new
  // TL entries are refused, so IF2 must not be consumed either: the frontend
  // assumes that whenever IF2 is consumed its successor already sits in IF1,
  // and both its scan overrides and its split-instruction realignment check
  // against IF1. Consuming IF2 with IF1 empty let a held instruction half be
  // joined to an unrelated later fetch. Freezing TV instead is safe: a fetch
  // held in TL/TV across the install is marked stale (install_stale_*) when it
  // may have observed the installer's SRAM traffic, and is then refetched.
  assign hit_v_o   = is_ready & v_tv_r & decode_tv_r.fetch_op & ~spec_tv_r &  hit_v_tv
    & ~install_stale_fetch_tv & ~cache_req_lock_i;
  assign miss_v_o  = is_ready & v_tv_r & decode_tv_r.fetch_op
    & ((spec_tv_r & ~hit_v_tv) | install_stale_fetch_tv) & ~cache_req_lock_i;
  assign fence_v_o = is_ready & v_tv_r & decode_tv_r.inval_op & snoop_tv_r & ~cache_req_lock_i;

  ///////////////////////////
  // Stat Mem Storage
  ///////////////////////////
  `bp_cast_i(bp_fe_icache_stat_mem_pkt_s, stat_mem_pkt);
  logic                       stat_mem_v_li;
  logic                       stat_mem_w_li;
  logic [sindex_width_lp-1:0] stat_mem_addr_li;
  bp_fe_icache_stat_info_s       stat_mem_data_li;
  bp_fe_icache_stat_info_s       stat_mem_mask_li;
  bp_fe_icache_stat_info_s       stat_mem_data_lo;

  bsg_mem_1rw_sync_mask_write_bit
   #(.width_p(assoc_p-1), .els_p(sets_p), .latch_last_read_p(1))
   stat_mem
    (.clk_i(clk_i)
     ,.reset_i(reset_i)
     ,.data_i(stat_mem_data_li.lru)
     ,.addr_i(stat_mem_addr_li)
     ,.v_i(stat_mem_v_li)
     ,.w_mask_i(stat_mem_mask_li.lru)
     ,.w_i(stat_mem_w_li)
     ,.data_o(stat_mem_data_lo.lru)
     );
  assign stat_mem_data_lo.dirty = '0;

  // Demand victim: steer the pseudo-LRU away from protected replay lines.
  logic [assoc_p-1:0] replay_protect_victim_mask, replay_protect_row;
  logic [`BSG_SAFE_MINUS(assoc_p, 2):0] replay_protect_lru_mask, replay_protect_lru_data;
  bsg_lru_pseudo_tree_backup
   #(.ways_p(assoc_p))
   replay_protect_backup
    (.disabled_ways_i(replay_protect_victim_mask)
     ,.modify_mask_o(replay_protect_lru_mask)
     ,.modify_data_o(replay_protect_lru_data)
     );
  bsg_lru_pseudo_tree_encode
   #(.ways_p(assoc_p))
   lru_encoder
    (.lru_i((stat_mem_data_lo.lru & ~replay_protect_lru_mask)
            | (replay_protect_lru_data & replay_protect_lru_mask))
     ,.way_id_o(lru_encode)
     );

  /////////////////////////////////////////////////////////////////////////////
  // Slow Path
  /////////////////////////////////////////////////////////////////////////////
  `bp_cast_o(bp_fe_icache_req_s, cache_req);
  `bp_cast_o(bp_fe_icache_req_metadata_s, cache_req_metadata);

  localparam block_req_size = bp_cache_req_size_e'(`BSG_SAFE_CLOG2(block_width_p/8));
  localparam uncached_req_size = bp_cache_req_size_e'(`BSG_SAFE_CLOG2(data_width_p/8));

  wire cached_req   = decode_tv_r.fetch_op & ~snoop_tv_r & ~hit_v_tv & ~uncached_tv_r & ~spec_tv_r;
  wire uncached_req = decode_tv_r.fetch_op & ~snoop_tv_r & ~hit_v_tv &  uncached_tv_r & ~spec_tv_r;
  wire inval_req    = decode_tv_r.inval_op & ~snoop_tv_r;

  assign cache_req_v_o = is_ready & v_tv_r & |{uncached_req, cached_req, inval_req}
    & ~(decode_tv_r.fetch_op & install_stale_fetch_tv)
    & ~tv_flush_i & ~retained_wait;
  assign cache_req_cast_o =
   '{addr     : paddr_tv_r
     ,size    : bp_cache_req_size_e'(cached_req ? block_req_size : uncached_req_size)
     ,msg_type: cached_req ? e_miss_load : uncached_req ? e_uc_load : e_cache_inval
     ,subop   : e_req_amoswap
     ,hit     : cache_hit_v_tv
     ,id      : '0
     ,data    : '0
     };

  // The cache pipeline is designed to always send metadata a cycle after the request
  wire cache_req_metadata_v = cache_req_yumi_i;
  bsg_dff_reset
   #(.width_p(1))
   cache_req_v_reg
    (.clk_i(clk_i)
     ,.reset_i(reset_i)

     ,.data_i(cache_req_metadata_v)
     ,.data_o(cache_req_metadata_v_o)
     );

  logic metadata_hit_r;
  logic [lg_assoc_lp-1:0] metadata_hit_index_r;
  bsg_dff
   #(.width_p(1+lg_assoc_lp))
   hit_reg
    (.clk_i(clk_i)
     ,.data_i({cache_hit_v_tv, hit_index_tv})
     ,.data_o({metadata_hit_r, metadata_hit_index_r})
     );

  wire [assoc_p-1:0] hit_or_repl_way = metadata_hit_r ? metadata_hit_index_r : lru_way_li;
  assign cache_req_metadata_cast_o.hit_or_repl_way = hit_or_repl_way;
  assign cache_req_metadata_cast_o.dirty = '0;

  /////////////////////////////////////////////////////////////////////////////
  // State machine
  //   e_ready   : Cache is ready to accept requests
  //   e_miss    : Cache is waiting for a cache request to be serviced
  //   e_recover : Reread the SRAMs to recover the updated TL state
  /////////////////////////////////////////////////////////////////////////////
  always_comb
    case (state_r)
      e_miss    : state_n = miss_abort_i ? e_ready : complete_recv ? e_recover : state_r;
      e_recover : state_n = e_ready;
      e_ready   : state_n = cache_req_yumi_i ? e_miss : state_r;
      default  : state_n = e_ready;
    endcase

  // synopsys sync_set_reset "reset_i"
  always_ff @(posedge clk_i)
    if (reset_i)
      state_r <= e_ready;
    else
      state_r <= state_n;

  always_ff @(posedge clk_i)
    if (reset_i)
      abort_miss_r <= 1'b0;
    else if (abort_complete)
      abort_miss_r <= 1'b0;
    else if (abort_miss)
      abort_miss_r <= 1'b1;

  always_ff @(posedge clk_i)
    if (cache_req_yumi_i)
      begin
        abort_miss_paddr_r <= paddr_tv_r;
        abort_miss_way_r <= hit_or_repl_way;
      end

  /////////////////////////////////////////////////////////////////////////////
  // SRAM Control
  /////////////////////////////////////////////////////////////////////////////

  wire do_recover = is_recover & ~yumi_o;

  ///////////////////////////
  // Tag Mem Control
  ///////////////////////////

  // Tag mem is bypassed if the index is the same on consecutive reads
  wire tag_mem_bypass = v_tl_r & decode_tl_r.fetch_op & (vaddr_index == vaddr_index_tl);
  wire tag_mem_fast_read = (do_recover || yumi_o & decode_lo.fetch_op & ~tag_mem_bypass)
    & ~abort_inflight;
  wire tag_mem_fast_write = abort_miss;
  wire tag_mem_slow_read = tag_mem_pkt_yumi_o & ~abort_miss_r & (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_read) ;
  wire tag_mem_slow_write = tag_mem_pkt_yumi_o & ~abort_miss_r & (tag_mem_pkt_cast_i.opcode != e_cache_tag_mem_read);
  assign tag_mem_v_li = tag_mem_fast_read | tag_mem_fast_write | tag_mem_slow_read | tag_mem_slow_write;
  assign tag_mem_w_li = tag_mem_fast_write | tag_mem_slow_write;
  assign tag_mem_addr_li = tag_mem_fast_write
    ? abort_miss_paddr_r[block_offset_width_lp+:sindex_width_lp]
    : tag_mem_fast_read
      ? do_recover ? vaddr_index_tl : vaddr_index
      : tag_mem_pkt_cast_i.index;
  assign tag_mem_pkt_yumi_o = tag_mem_pkt_v_i & ~|tag_mem_fast_read;

  logic [assoc_p-1:0] tag_mem_way_one_hot;
  bsg_decode
   #(.num_out_p(assoc_p))
   tag_mem_way_decode
    (.i(tag_mem_pkt_cast_i.way_id)
     ,.o(tag_mem_way_one_hot)
     );

  logic [assoc_p-1:0] abort_miss_way_one_hot;
  bsg_decode
   #(.num_out_p(assoc_p))
   abort_miss_way_decode
    (.i(abort_miss_way_r)
     ,.o(abort_miss_way_one_hot)
     );

  always_comb
    for (int i = 0; i < assoc_p; i++)
      if (tag_mem_fast_write)
        begin
          tag_mem_data_li[i]   = '{state: bp_coh_states_e'('0), tag: '0};
          tag_mem_w_mask_li[i] = '{state: {$bits(bp_coh_states_e){abort_miss_way_one_hot[i]}}, tag: '0};
        end
      else
        case (tag_mem_pkt_cast_i.opcode)
          e_cache_tag_mem_set_tag:
            begin
              tag_mem_data_li[i]   = '{state: tag_mem_pkt_cast_i.state, tag: tag_mem_pkt_cast_i.tag};
              tag_mem_w_mask_li[i] = '{state: {$bits(bp_coh_states_e){tag_mem_way_one_hot[i]}}
                                       ,tag : {tag_width_p{tag_mem_way_one_hot[i]}}
                                       };
            end
          e_cache_tag_mem_set_state:
            begin
              tag_mem_data_li[i]   = '{state: tag_mem_pkt_cast_i.state, tag: '0};
              tag_mem_w_mask_li[i] = '{state: {$bits(bp_coh_states_e){tag_mem_way_one_hot[i]}}, tag: '0};
            end
          e_cache_tag_mem_set_inval:
            begin
              tag_mem_data_li[i] = '{state: bp_coh_states_e'('0), tag: '0};
              tag_mem_w_mask_li[i] = '{state: bp_coh_states_e'('1), tag: '0};
            end
          default: // e_cache_tag_mem_set_clear
            begin
              tag_mem_data_li[i]   = '{state: bp_coh_states_e'('0), tag: '0};
              tag_mem_w_mask_li[i] = '{state: bp_coh_states_e'('1), tag: '1};
            end
        endcase

  logic [lg_assoc_lp-1:0] tag_mem_pkt_way_r;
  bsg_dff
   #(.width_p(lg_assoc_lp))
   tag_mem_pkt_way_reg
    (.clk_i(clk_i)
     ,.data_i(tag_mem_pkt_cast_i.way_id)
     ,.data_o(tag_mem_pkt_way_r)
     );

  assign tag_mem_o = tag_mem_data_lo[tag_mem_pkt_way_r];
  assign tag_row_o = {replay_protect_row, tag_mem_data_lo};

  ///////////////////////////
  // Data Mem Control
  ///////////////////////////
  wire replay_buffer_prefetch_input = replay_buffer_p & data_mem_pkt_v_i
    & (data_mem_pkt_cast_i.opcode == e_cache_data_mem_prefetch);
  wire replay_buffer_inval = cache_req_yumi_i & inval_req;
  logic [1:0] retention_mode_r;
  logic retention_published_r;
  logic [15:0] retention_side_hits_r;
  wire demand_capture_enabled = replay_buffer_p & (retention_mode_r != 0)
    & (~replay_buffer_bram_p | retention_lookup_enable_i);
  logic demand_capture_active_r, demand_capture_first_r;
  // Observe the ordinary SRAM handshake, never bypass or drive it. A write
  // can be held across frontend arbitration, so valid alone is insufficient.
  wire demand_capture_input = demand_capture_enabled
    & demand_capture_active_r & data_mem_pkt_yumi_o
    & (data_mem_pkt_cast_i.opcode == e_cache_data_mem_write)
    & ~retention_cmd_v_i & ~miss_abort_i & ~abort_inflight;
  wire replay_buffer_input = (replay_buffer_prefetch_input | demand_capture_input)
    & (~replay_buffer_bram_p | retention_lookup_enable_i);
  bp_fe_icache_data_mem_pkt_s replay_buffer_pkt_r;
  logic replay_buffer_pkt_v_r, replay_buffer_pkt_demand_r, replay_buffer_pkt_first_r;
  // Abort may arrive while the final accepted beat is in this register.
  // Suppress that pending demand publication as well as new capture beats.
  wire replay_buffer_pending_write = replay_buffer_pkt_v_r
    & (~replay_buffer_pkt_demand_r
       | (demand_capture_enabled & ~retention_cmd_v_i & ~miss_abort_i & ~abort_inflight));
  // First-completed admission pins complete entries in the selected bank.
  // Advisory replay keeps its historical replacement behavior in every mode.
  wire retention_pin = replay_buffer_pkt_demand_r & (retention_mode_r == 2);
  wire replay_buffer_write = ~replay_buffer_bram_p & replay_buffer_pending_write
    & (~retention_pin | replay_buffer_write_match | replay_buffer_write_free);

  always_ff @(posedge clk_i) begin
    if (reset_i | replay_buffer_inval | retention_cmd_v_i | miss_abort_i | abort_inflight
        | (replay_buffer_bram_p & ~retention_lookup_enable_i)) begin
      demand_capture_active_r <= 1'b0;
      demand_capture_first_r <= 1'b0;
    end else if (cache_req_yumi_i) begin
      demand_capture_active_r <= demand_capture_enabled & cached_req;
      demand_capture_first_r <= demand_capture_enabled & cached_req;
    end else if (demand_capture_input) begin
      demand_capture_first_r <= 1'b0;
      if (cache_req_last_i)
        demand_capture_active_r <= 1'b0;
    end
  end

  if (replay_buffer_bram_p & replay_buffer_p) begin : retained_bram
    logic adapter_idle;
    wire eligible = is_ready & v_tv_r & decode_tv_r.fetch_op
      & ~spec_tv_r & ~uncached_tv_r & ~cache_hit_v_tv & retention_lookup_enable_i;
    assign retained_clear_o = replay_buffer_inval;
    // Client-local lifecycle only. Backend busy/sweep and detached UCE
    // traffic are separate and must not be inferred drained from this bit.
    assign retained_idle_o = adapter_idle & ~replay_buffer_pkt_v_r & ~demand_capture_active_r;
    bp_fe_icache_retained_bram
     #(.paddr_width_p(paddr_width_p), .block_width_p(block_width_p), .fill_width_p(fill_width_p))
     adapter
      (.clk_i(clk_i), .reset_i(reset_i), .clear_i(replay_buffer_inval)
       ,.enable_i(retention_lookup_enable_i)
       ,.lookup_v_i(eligible), .lookup_paddr_i(paddr_tv_r)
       ,.cancel_i(tv_flush_i | miss_abort_i | retention_cmd_v_i)
       ,.consume_i((hit_v_o & yumi_i) | cache_req_yumi_i)
       ,.wait_o(retained_wait), .hit_o(retained_hit), .data_o(retained_data)
       ,.lookup_v_o(retained_lookup_v_o), .lookup_ready_i(retained_lookup_ready_i)
       ,.lookup_paddr_o(retained_lookup_paddr_o)
       ,.resp_v_i(retained_resp_v_i), .resp_ready_o(retained_resp_ready_o)
       ,.resp_hit_i(retained_resp_hit_i), .resp_data_i(retained_resp_data_i)
       ,.capture_v_i(replay_buffer_pending_write)
       ,.capture_demand_i(replay_buffer_pkt_demand_r)
       ,.capture_first_i(replay_buffer_pkt_first_r)
       ,.capture_paddr_i(replay_buffer_pkt_r.addr)
       ,.capture_beats_i(replay_buffer_pkt_r.fill_index)
       ,.capture_data_i(replay_buffer_pkt_r.data)
       ,.demand_cancel_i(retention_cmd_v_i | miss_abort_i | abort_inflight)
       ,.demand_pin_i(retention_mode_r == 2)
       ,.insert_v_o(retained_insert_v_o), .insert_ready_i(retained_insert_ready_i)
       ,.insert_paddr_o(retained_insert_paddr_o), .insert_data_o(retained_insert_data_o)
       ,.insert_replace_o(retained_insert_replace_o), .insert_cancel_o(retained_insert_cancel_o)
       ,.insert_done_i(retained_insert_done_i), .insert_published_i(retained_insert_published_i)
       ,.demand_published_o(retained_demand_published), .drop_o(retained_drop_o), .idle_o(adapter_idle)
       );
  end else begin : no_retained_bram
    assign retained_wait = 1'b0;
    assign retained_hit = 1'b0;
    assign retained_data = '0;
    assign retained_demand_published = 1'b0;
    assign retained_lookup_v_o = 1'b0;
    assign retained_lookup_paddr_o = '0;
    assign retained_resp_ready_o = 1'b1;
    assign retained_insert_v_o = 1'b0;
    assign retained_insert_paddr_o = '0;
    assign retained_insert_data_o = '0;
    assign retained_insert_replace_o = 1'b0;
    assign retained_insert_cancel_o = 1'b0;
    assign retained_clear_o = 1'b0;
    assign retained_drop_o = 1'b0;
    assign retained_idle_o = 1'b1;
  end

  // Register advisory packets before associative allocation. The UCE can
  // still deliver one beat every cycle: an older registered beat retires as
  // the next beat enters this stage. Besides isolating replay traffic from
  // the ordinary SRAM path, this prevents the selected-slot fanout from
  // extending the core-to-frontend control path through the UCE.
  always_ff @(posedge clk_i) begin
    if (reset_i | replay_buffer_inval)
      replay_buffer_pkt_v_r <= 1'b0;
    else begin
      replay_buffer_pkt_v_r <= replay_buffer_input;
      if (replay_buffer_input) begin
        replay_buffer_pkt_r <= data_mem_pkt_cast_i;
        replay_buffer_pkt_demand_r <= demand_capture_input;
        // Ordinary responses are critical-first and may start at any beat.
        // Beat zero can arrive midway through a wrapped demand packet; only
        // its first accepted beat starts the new publication epoch.
        replay_buffer_pkt_first_r <= demand_capture_input
          ? demand_capture_first_r : data_mem_pkt_cast_i.fill_index[0];
      end
    end
  end

  logic replay_buffer_write_match, replay_buffer_write_free;
  logic [replay_buffer_slot_width_lp-1:0] replay_buffer_write_slot;
  logic [replay_buffer_banks_lp-1:0][replay_buffer_bank_way_width_lp-1:0]
    replay_buffer_bank_replace_r;
  wire [replay_buffer_bank_width_lp-1:0] replay_buffer_write_bank
    = replay_buffer_bank
        (replay_buffer_pkt_r.addr[paddr_width_p-1:block_offset_width_lp]);
  always_comb begin
    replay_buffer_write_match = 1'b0;
    replay_buffer_write_free = 1'b0;
    if (replay_buffer_banked_lp) begin
      replay_buffer_write_slot = replay_buffer_slot_width_lp'
        (replay_buffer_write_bank*replay_buffer_bank_ways_lp
         + replay_buffer_bank_replace_r[replay_buffer_write_bank]);
      for (int way = replay_buffer_bank_ways_lp-1; way >= 0; way--) begin
        automatic logic [replay_buffer_slot_width_lp-1:0] slot
          = replay_buffer_slot_width_lp'
              (replay_buffer_write_bank*replay_buffer_bank_ways_lp + way);
        if (replay_buffer_alloc_r[slot]
            & (replay_buffer_addr_r[slot]
               == replay_buffer_pkt_r.addr[paddr_width_p-1:block_offset_width_lp])) begin
          replay_buffer_write_match = 1'b1;
          replay_buffer_write_slot = slot;
        end
        if ((!replay_buffer_alloc_r[slot]
             | (retention_pin & !(&replay_buffer_beat_v_r[slot])))
            & !replay_buffer_write_match) begin
          replay_buffer_write_free = 1'b1;
          replay_buffer_write_slot = slot;
        end
      end
    end else begin
      replay_buffer_write_slot = replay_buffer_replace_r;
      for (int i = replay_buffer_els_lp-1; i >= 0; i--) begin
        if (replay_buffer_alloc_r[i]
            & (replay_buffer_addr_r[i]
               == replay_buffer_pkt_r.addr[paddr_width_p-1:block_offset_width_lp])) begin
          replay_buffer_write_match = 1'b1;
          replay_buffer_write_slot = replay_buffer_slot_width_lp'(i);
        end
        if ((!replay_buffer_alloc_r[i]
             | (retention_pin & !(&replay_buffer_beat_v_r[i])))
            & !replay_buffer_write_match) begin
          replay_buffer_write_free = 1'b1;
          replay_buffer_write_slot = replay_buffer_slot_width_lp'(i);
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (reset_i | replay_buffer_inval) begin
      replay_buffer_alloc_r <= '0;
      replay_buffer_addr_r <= '0;
      replay_buffer_beat_v_r <= '0;
      replay_buffer_replace_r <= '0;
      replay_buffer_bank_replace_r <= '0;
    end else if (replay_buffer_write) begin
      replay_buffer_alloc_r[replay_buffer_write_slot] <= 1'b1;
      replay_buffer_addr_r[replay_buffer_write_slot]
        <= replay_buffer_pkt_r.addr[paddr_width_p-1:block_offset_width_lp];
      // Start a fresh publication epoch even when refreshing the same line.
      // A critical-first demand packet need not start with beat zero.
      // Until all beats of this epoch arrive the entry cannot hit.
      if (!replay_buffer_write_match | replay_buffer_pkt_first_r)
        replay_buffer_beat_v_r[replay_buffer_write_slot]
          <= replay_buffer_pkt_r.fill_index;
      else
        replay_buffer_beat_v_r[replay_buffer_write_slot]
          <= replay_buffer_beat_v_r[replay_buffer_write_slot]
             | replay_buffer_pkt_r.fill_index;
      if (!replay_buffer_write_match & !replay_buffer_write_free) begin
        if (replay_buffer_banked_lp) begin
          if (replay_buffer_bank_replace_r[replay_buffer_write_bank]
              == replay_buffer_bank_way_width_lp'(replay_buffer_bank_ways_lp-1))
            replay_buffer_bank_replace_r[replay_buffer_write_bank] <= '0;
          else
            replay_buffer_bank_replace_r[replay_buffer_write_bank]
              <= replay_buffer_bank_replace_r[replay_buffer_write_bank] + 1'b1;
        end else begin
          if (replay_buffer_replace_r
              == replay_buffer_slot_width_lp'(replay_buffer_els_lp-1))
            replay_buffer_replace_r <= '0;
          else
            replay_buffer_replace_r <= replay_buffer_replace_r + 1'b1;
        end
      end
    end
  end

  wire [block_size_in_fill_lp-1:0] retention_next_beats
    = (!replay_buffer_write_match | replay_buffer_pkt_first_r)
      ? replay_buffer_pkt_r.fill_index
      : (replay_buffer_beat_v_r[replay_buffer_write_slot]
         | replay_buffer_pkt_r.fill_index);
  // Count consumed side-only instructions, not cycles stalled at a hit.
  // Policy writes reset statistics but never invalidate retained contents;
  // software uses the ordinary fence.i path to begin a fresh admission epoch.
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      retention_mode_r <= '0;
      retention_published_r <= 1'b0;
      retention_side_hits_r <= '0;
    end else if (retention_cmd_v_i) begin
      retention_mode_r <= (replay_buffer_p & (retention_mode_i != 3))
        ? retention_mode_i : 2'b00;
      retention_published_r <= 1'b0;
      retention_side_hits_r <= '0;
    end else begin
      if ((replay_buffer_write & replay_buffer_pkt_demand_r & (&retention_next_beats))
          | retained_demand_published)
        retention_published_r <= 1'b1;
      if (replay_buffer_hit_tv & hit_v_o & yumi_i & !(&retention_side_hits_r))
        retention_side_hits_r <= retention_side_hits_r + 1'b1;
    end
  end
  always_comb begin
    retention_status_o = '0;
    retention_status_o[63] = replay_buffer_p;
    retention_status_o[1:0] = retention_mode_r;
    retention_status_o[2] = retention_published_r;
    retention_status_o[31:16] = retention_side_hits_r;
  end

  // Word-banked storage avoids reading and multiplexing all 512 bits of every
  // entry on each fetch. Each bank has one synchronous response write and one
  // asynchronous selected read, which maps compactly to distributed RAM.
  for (genvar word = 0; word < replay_words_per_line_lp; word++) begin
    localparam beat_lp = word / replay_words_per_fill_lp;
    localparam fill_word_lp = word % replay_words_per_fill_lp;
    (* ram_style = "distributed" *)
    logic [data_width_p-1:0] mem [replay_buffer_els_lp];
    always_ff @(posedge clk_i)
      if (replay_buffer_write & replay_buffer_pkt_r.fill_index[beat_lp])
        mem[replay_buffer_write_slot]
          <= replay_buffer_pkt_r.data[fill_word_lp*data_width_p+:data_width_p];
    assign replay_buffer_word_data_lo[word] = mem[replay_buffer_hit_slot_tv];
  end

  logic [assoc_p-1:0] vaddr_bank_dec;
  bsg_decode
   #(.num_out_p(assoc_p))
   bypass_bank_decode
    (.i(vaddr_bank)
     ,.o(vaddr_bank_dec)
     );

  // During a data mem bypass, only the necessary bank of data memory is read
  logic [assoc_p-1:0] data_mem_bypass_select;
  bsg_adder_one_hot
   #(.width_p(assoc_p))
   data_mem_bank_select_adder
    (.a_i(hit_v_tl)
     ,.b_i(vaddr_bank_dec)
     ,.o(data_mem_bypass_select)
     );

  wire [`BSG_SAFE_CLOG2(fill_width_p)-1:0] write_data_rot_li = data_mem_pkt_cast_i.way_id*bank_width_lp;
  // Expand the bank write mask to bank width
  logic [fill_width_p-1:0] data_mem_pkt_fill_data_li;
  bsg_rotate_left
   #(.width_p(fill_width_p))
   write_data_rotate
    (.data_i(data_mem_pkt_cast_i.data)
     ,.rot_i(write_data_rot_li)
     ,.o(data_mem_pkt_fill_data_li)
     );
  wire [assoc_p-1:0][bank_width_lp-1:0] data_mem_pkt_data_li = {block_size_in_fill_lp{data_mem_pkt_fill_data_li}};

  logic [block_size_in_fill_lp-1:0][fill_size_in_bank_lp-1:0] data_mem_pkt_fill_mask_expanded;
  bsg_expand_bitmask
   #(.in_width_p(block_size_in_fill_lp), .expand_p(fill_size_in_bank_lp))
   fill_mask_expand
    (.i(data_mem_pkt_cast_i.fill_index), .o(data_mem_pkt_fill_mask_expanded));

  logic [assoc_p-1:0] data_mem_write_bank_mask;
  wire [`BSG_SAFE_CLOG2(assoc_p)-1:0] write_mask_rot_li = data_mem_pkt_cast_i.way_id;
  bsg_rotate_left
   #(.width_p(assoc_p))
   write_mask_rotate
    (.data_i(data_mem_pkt_fill_mask_expanded)
     ,.rot_i(write_mask_rot_li)
     ,.o(data_mem_write_bank_mask)
     );

  wire data_mem_bypass = v_tl_r & decode_tl_r.fetch_op & (vaddr_index == vaddr_index_tl) && (vaddr_vtag == vaddr_vtag_tl);

  logic [assoc_p-1:0] data_mem_fast_read, data_mem_fast_write, data_mem_slow_read, data_mem_slow_write;
  for (genvar i = 0; i < assoc_p; i++)
    begin : data_mem_lines
      assign data_mem_slow_read[i] = data_mem_pkt_yumi_o & ~abort_miss_r & (data_mem_pkt_cast_i.opcode == e_cache_data_mem_read);
      assign data_mem_slow_write[i] = data_mem_pkt_yumi_o & ~abort_miss_r & (data_mem_pkt_cast_i.opcode == e_cache_data_mem_write) & data_mem_write_bank_mask[i];

      assign data_mem_fast_read[i] = (do_recover || yumi_o & decode_lo.fetch_op & (~data_mem_bypass | data_mem_bypass_select[i]))
        & ~abort_inflight;

      assign data_mem_v_li[i] = data_mem_fast_read[i] | data_mem_slow_read[i] | data_mem_slow_write[i];
      assign data_mem_w_li[i] = data_mem_slow_write[i];
      wire [bindex_width_lp-1:0] data_mem_pkt_offset = (bindex_width_lp'(i) - data_mem_pkt_cast_i.way_id);
      assign data_mem_addr_li[i] = data_mem_fast_read[i]
        ? do_recover ? {vaddr_index_tl, {(assoc_p>1){vaddr_bank_tl}}} : {vaddr_index, {(assoc_p > 1){vaddr_bank}}}
        : {data_mem_pkt_cast_i.index, {(assoc_p > 1){data_mem_pkt_offset}}};
      assign data_mem_data_li[i] = data_mem_pkt_data_li[i];
    end
  // See hit_v_o/miss_v_o: fetches that may have observed an install write.
  logic install_stale_tl_r, install_stale_tv_r;
  // The SRAMs latch their last read (latch_last_read_p), so a write to a
  // different set cannot disturb an in-flight fetch; only same-set writes
  // (stale tags/data, or a same-index bypass of them) need the refetch.
  wire install_tag_write = is_ready & tag_mem_slow_write;
  wire install_data_write = is_ready & (|data_mem_slow_write);
  wire [sindex_width_lp-1:0] paddr_index_tv = paddr_tv_r[block_offset_width_lp+:sindex_width_lp];
  wire install_write_tl = (install_tag_write & (tag_mem_pkt_cast_i.index == vaddr_index_tl))
    | (install_data_write & (data_mem_pkt_cast_i.index == vaddr_index_tl));
  wire install_write_tv = (install_tag_write & (tag_mem_pkt_cast_i.index == paddr_index_tv))
    | (install_data_write & (data_mem_pkt_cast_i.index == paddr_index_tv));
  // TL compares against the tag SRAM's latched output combinationally. The
  // installer's own tag reads (duplicate scan of other sets) replace that
  // output, so any such read invalidates a fetch waiting in TL whatever its
  // set: it could otherwise miss on a resident line (duplicate refill) or hit
  // another set's way (wrong instructions).
  wire install_tag_read = is_ready & tag_mem_slow_read;
  always_ff @(posedge clk_i)
    if (reset_i | tl_flush_i)
      install_stale_tl_r <= 1'b0;
    else
      install_stale_tl_r <= install_write_tl | install_tag_read
        | (tl_we ? (install_stale_tl_r & (tag_mem_bypass | data_mem_bypass)) : install_stale_tl_r);
  always_ff @(posedge clk_i)
    if (reset_i | tv_flush_i)
      install_stale_tv_r <= 1'b0;
    else if (critical_recv)
      install_stale_tv_r <= 1'b0;
    else
      // On a TL->TV move the incoming fetch carries the TL flag, including a
      // same-set write in this very cycle.
      install_stale_tv_r <= tv_we ? (install_stale_tl_r | install_write_tl)
                                  : (install_stale_tv_r | install_write_tv);
  assign install_stale_fetch_tv = install_stale_tv_r & ~snoop_tv_r;

  assign data_mem_pkt_yumi_o = replay_buffer_prefetch_input
    ? 1'b1
    : (data_mem_pkt_cast_i.opcode == e_cache_data_mem_uncached)
      ? data_mem_pkt_v_i
      : data_mem_pkt_v_i & ~|data_mem_fast_read;

  logic [lg_assoc_lp-1:0] data_mem_pkt_way_r;
  bsg_dff
   #(.width_p(lg_assoc_lp))
   data_mem_pkt_way_reg
    (.clk_i(clk_i)
     ,.data_i(data_mem_pkt_cast_i.way_id)
     ,.data_o(data_mem_pkt_way_r)
     );

  wire [`BSG_SAFE_CLOG2(block_width_p)-1:0] read_data_rot_li = data_mem_pkt_way_r*bank_width_lp;
  bsg_rotate_right
   #(.width_p(block_width_p))
   read_data_rotate
    (.data_i(data_mem_data_lo)
     ,.rot_i(read_data_rot_li)
     ,.o(data_mem_o)
     );

  ///////////////////////////
  // Stat Mem Control
  ///////////////////////////
  wire stat_mem_fast_read = ~uncached_tv_r & cache_req_yumi_i & ~abort_inflight;
  wire stat_mem_fast_write = ~uncached_tv_r & yumi_i & ~abort_inflight
    & ~replay_buffer_hit_tv;
  wire stat_mem_slow_write = stat_mem_pkt_yumi_o & ~abort_miss & ~abort_miss_r & (stat_mem_pkt_cast_i.opcode != e_cache_stat_mem_read);
  assign stat_mem_pkt_yumi_o = stat_mem_pkt_v_i & ~stat_mem_fast_write & ~stat_mem_fast_read;
  assign stat_mem_v_li = stat_mem_fast_read | stat_mem_fast_write | stat_mem_pkt_yumi_o;
  assign stat_mem_w_li = stat_mem_fast_write | (stat_mem_pkt_yumi_o & stat_mem_slow_write);
  assign stat_mem_addr_li = (stat_mem_fast_write | stat_mem_fast_read)
    ? paddr_tv_r[block_offset_width_lp+:sindex_width_lp]
    : stat_mem_pkt_cast_i.index;

  logic [`BSG_SAFE_MINUS(assoc_p, 2):0] lru_decode_data_lo, lru_decode_mask_lo;
  bsg_lru_pseudo_tree_decode
   #(.ways_p(assoc_p))
   lru_decode
    (.way_id_i(hit_index_tv)
     ,.data_o(lru_decode_data_lo)
     ,.mask_o(lru_decode_mask_lo)
     );

  assign stat_mem_data_li.lru = stat_mem_fast_write ? lru_decode_data_lo : '0;
  assign stat_mem_mask_li.lru = stat_mem_fast_write ? lru_decode_mask_lo : '1;

  assign stat_mem_o = stat_mem_data_lo;

  /////////////////////////////////////////////////////////////////////////////
  // Snoop Logic
  /////////////////////////////////////////////////////////////////////////////
  wire [assoc_p-1:0] pseudo_hit =
    (data_mem_pkt_v_i << data_mem_pkt_cast_i.way_id) | (tag_mem_pkt_v_i << tag_mem_pkt_cast_i.way_id);
  assign snoop_hit = pseudo_hit;
  assign snoop_way = pseudo_hit;
  assign snoop_data = data_mem_data_li;
  assign snoop_spec = spec_tv_r;
  assign snoop_uncached = uncached_tv_r;
  assign snoop_decode = decode_tv_r;
  assign snoop_bank_sel_one_hot = bank_sel_one_hot_tv_r;

  // synopsys translate_off
  always_ff @(negedge clk_i) if (!reset_i && demand_capture_enabled)
    assert (!coherent_p)
      else $error("Demand retention requires a noncoherent instruction cache");

  always_ff @(negedge clk_i) if (!reset_i && cache_req_lock_i)
    assert (!yumi_o)
      else $error("I-cache accepted a new frontend request while SRAM slow path was locked");

  if (`BSG_SAFE_CLOG2(block_width_p*sets_p/8) > page_offset_width_gp) begin
    $error("Cache way size must be at most 4kB");
  end

  if (!(`BSG_IS_POW2(assoc_p)))
    $error("Associativity must be power of two");
  // synopsys translate_on

`ifdef BP_REPLAY_STATS
  // Simulation-only replay survival statistics. A tag publication while the
  // cache is in its ready state is a replay install (ordinary refills publish
  // from the miss states). Count each such line's first use, and lines whose
  // way is rewritten or invalidated before any use.
  bit replay_unused_r [sets_p][assoc_p];
  longint unsigned rs_installs, rs_used, rs_evicted_unused, rs_demand_fills;
  initial begin
    rs_installs = 0; rs_used = 0; rs_evicted_unused = 0; rs_demand_fills = 0;
    for (int s = 0; s < sets_p; s++) for (int w = 0; w < assoc_p; w++) replay_unused_r[s][w] = 1'b0;
  end
  wire [assoc_p-1:0] rs_hit_vec = (is_ready & v_tv_r & decode_tv_r.fetch_op) ? hit_v_tv_r : '0;
  wire [sindex_width_lp-1:0] rs_hit_idx = paddr_tv_r[block_offset_width_lp+:sindex_width_lp];
  always_ff @(posedge clk_i)
    if (~reset_i) begin
      if (|rs_hit_vec)
        for (int w = 0; w < assoc_p; w++)
          if (rs_hit_vec[w] && replay_unused_r[rs_hit_idx][w]) begin
            replay_unused_r[rs_hit_idx][w] <= 1'b0; rs_used <= rs_used + 1;
          end
      if (tag_mem_slow_write) begin
        if (replay_unused_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id])
          rs_evicted_unused <= rs_evicted_unused + 1;
        replay_unused_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id]
          <= is_ready & (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_tag);
        if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_tag) begin
          if (is_ready) rs_installs <= rs_installs + 1;
          else rs_demand_fills <= rs_demand_fills + 1;
        end
      end
    end
  // Report cumulative totals periodically: the run ends through a testbench
  // abort that skips final blocks.
  longint unsigned rs_cycles = 0;
  longint unsigned rs_multihit = 0;
  always_ff @(posedge clk_i)
    if (~reset_i & v_tv_r & decode_tv_r.fetch_op & ~$onehot0(hit_v_tv_r)) begin
      if (rs_multihit == 0)
        $display("REPLAYSTATS icache first multihit t=%0t paddr=%h hit=%b", $time, paddr_tv_r, hit_v_tv_r);
      rs_multihit <= rs_multihit + 1;
    end
  always_ff @(posedge clk_i) begin
    rs_cycles <= rs_cycles + 1;
    if ((rs_cycles & 64'h3ffff) == 0) begin
      automatic longint unsigned left = 0;
      for (int s = 0; s < sets_p; s++) for (int w = 0; w < assoc_p; w++) left += replay_unused_r[s][w];
      $display("REPLAYSTATS icache cyc=%0d installs=%0d used=%0d evicted_unused=%0d unused_now=%0d demand_fills=%0d multihit=%0d",
               rs_cycles, rs_installs, rs_used, rs_evicted_unused, left, rs_demand_fills, rs_multihit);
    end
  end
`ifdef BP_REPLAY_EVLOG
  // Simulation-only event log for switch-window attribution (analyzed by
  // research/.../tools/evlog_attr.py). Same free-running cycle count as the
  // REPLAYSTATS report and the CSR marker log. R=replay install, F=demand
  // fill, U=first use of a replayed line, X=replayed line overwritten or
  // invalidated unused (op/ready identify the writer).
  logic [$bits(tag_mem_pkt_cast_i.tag)-1:0] ev_tag_r [sets_p][assoc_p];
  always_ff @(posedge clk_i)
    if (~reset_i) begin
      if (|rs_hit_vec)
        for (int w = 0; w < assoc_p; w++)
          if (rs_hit_vec[w] && replay_unused_r[rs_hit_idx][w])
            $display("EV %s %0d U %0d %0d %h", "I", rs_cycles, rs_hit_idx, w, ev_tag_r[rs_hit_idx][w]);
      if (tag_mem_slow_write) begin
        if (replay_unused_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id])
          $display("EV %s %0d X %0d %0d %h op=%0d ready=%0d", "I", rs_cycles, tag_mem_pkt_cast_i.index,
                   tag_mem_pkt_cast_i.way_id, ev_tag_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id],
                   tag_mem_pkt_cast_i.opcode, is_ready);
        if (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_tag) begin
          ev_tag_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id] <= tag_mem_pkt_cast_i.tag;
          $display("EV %s %0d %s %0d %0d %h", "I", rs_cycles, is_ready ? "R" : "F",
                   tag_mem_pkt_cast_i.index, tag_mem_pkt_cast_i.way_id, tag_mem_pkt_cast_i.tag);
        end
      end
    end
`endif
`endif

  /////////////////////////////////////////////////////////////////////////////
  // Replay protect-until-first-use (BP_REPLAY_PROTECT). A replayed line is
  // installed for a program that has not run yet, so recency-based
  // replacement sees it as old and evicts it before that program arrives.
  // One bit per way marks replay installs (a tag publication while the cache
  // is not serving its own miss) until their first hit or until the way is
  // rewritten. Demand and replay victim selection skip protected ways unless
  // every way of the set is protected. All bits clear when a new replay burst
  // starts (an install after BP_REPLAY_PROTECT_GAP quiet cycles), so stale
  // predictions cannot pin ways. Replacement choice only; never correctness.
  /////////////////////////////////////////////////////////////////////////////
`ifdef BP_REPLAY_PROTECT
`ifndef BP_REPLAY_PROTECT_GAP
`define BP_REPLAY_PROTECT_GAP 4096
`endif
  logic [assoc_p-1:0] replay_protect_r [sets_p];
  logic [sindex_width_lp-1:0] replay_protect_stat_idx_r, replay_protect_tag_idx_r;
  logic [15:0] replay_protect_quiet_r;
  wire [assoc_p-1:0] replay_protect_hit_vec = (is_ready & v_tv_r & decode_tv_r.fetch_op) ? hit_v_tv_r : '0;
  wire [sindex_width_lp-1:0] replay_protect_hit_idx = paddr_tv_r[block_offset_width_lp+:sindex_width_lp];
  wire replay_protect_install = tag_mem_slow_write & is_ready
    & (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_set_tag);
  wire replay_protect_new_burst = replay_protect_install
    & (replay_protect_quiet_r >= 16'(`BP_REPLAY_PROTECT_GAP));
  always_ff @(posedge clk_i)
    if (reset_i) begin
      for (int s = 0; s < sets_p; s++) replay_protect_r[s] <= '0;
      replay_protect_quiet_r <= '1;
      replay_protect_stat_idx_r <= '0;
      replay_protect_tag_idx_r <= '0;
    end else begin
      if (stat_mem_v_li & ~stat_mem_w_li) replay_protect_stat_idx_r <= stat_mem_addr_li;
      if (tag_mem_pkt_yumi_o & (tag_mem_pkt_cast_i.opcode == e_cache_tag_mem_read))
        replay_protect_tag_idx_r <= tag_mem_pkt_cast_i.index;
      replay_protect_quiet_r <= replay_protect_install ? '0
        : (&replay_protect_quiet_r ? replay_protect_quiet_r : replay_protect_quiet_r + 1'b1);
      if (replay_protect_new_burst)
        for (int s = 0; s < sets_p; s++) replay_protect_r[s] <= '0;
      if (|replay_protect_hit_vec)
        replay_protect_r[replay_protect_hit_idx] <= replay_protect_r[replay_protect_hit_idx] & ~replay_protect_hit_vec;
      if (tag_mem_slow_write) begin
        if (tag_mem_pkt_cast_i.opcode inside {e_cache_tag_mem_set_clear, e_cache_tag_mem_set_inval})
          replay_protect_r[tag_mem_pkt_cast_i.index] <= '0;
        else
          replay_protect_r[tag_mem_pkt_cast_i.index][tag_mem_pkt_cast_i.way_id] <= replay_protect_install;
      end
    end
  wire [assoc_p-1:0] replay_protect_stat_vec = replay_protect_r[replay_protect_stat_idx_r];
  assign replay_protect_victim_mask = &replay_protect_stat_vec ? '0 : replay_protect_stat_vec;
  assign replay_protect_row = replay_protect_r[replay_protect_tag_idx_r];
`else
  assign replay_protect_victim_mask = '0;
  assign replay_protect_row = '0;
`endif

endmodule
