/*
 * bp_me_l2_dirty_filter.sv
 *
 * Tracks which lines may be dirty in one L2 slice, so a replay prefetch that
 * reads DRAM directly (bypassing the blocking L2) is used only when DRAM holds
 * the current data. Every entry is keyed by the L2's own internal line address
 * (after bp_me_dram_hash_encode), so a filter set mirrors exactly one L2 set
 * in one bank.
 *
 * Invariant: a line that is dirty in the L2, or has a write queued anywhere in
 * the slice, is reported dirty. The converse need not hold (false positives
 * only send a replay through the L2, which is always correct).
 *
 *   write message fully accepted at the slice input : entry pending += 1
 *   write/AMO acknowledgement leaves the slice        : pending -= 1, dirty = 1
 *   L2 DMA write-back or refill of the line           : dirty = 0 if pending == 0
 *
 * A refill implies the line was absent, so any older dirty copy was already
 * written back. A set that cannot allocate an entry becomes sticky (every line
 * in it reported dirty) for the rest of the run; with ways_p above the L2
 * associativity plus queued writes this should not occur, and simulation
 * reports it.
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_me_l2_dirty_filter
 import bp_common_pkg::*;
 import bp_me_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   `declare_bp_bedrock_if_widths(paddr_width_p, lce_id_width_p, cce_id_width_p, did_width_p, lce_assoc_p)
   , parameter num_query_p = 1
   , parameter ways_p = l2_assoc_p + 4
   , parameter pending_width_p = 4

   , localparam lg_l2_banks_lp = `BSG_SAFE_CLOG2(l2_banks_p)
   , localparam lg_l2_sets_lp = `BSG_SAFE_CLOG2(l2_sets_p)
   , localparam l2_block_offset_width_lp = `BSG_SAFE_CLOG2(l2_block_width_p/8)
   , localparam line_width_lp = daddr_width_p - l2_block_offset_width_lp
   )
  (input                                              clk_i
   , input                                            reset_i

   // Slice input (fwd) and output (rev) handshakes
   , input [mem_fwd_header_width_lp-1:0]              fwd_header_i
   , input                                            fwd_accept_i
   , input [mem_rev_header_width_lp-1:0]              rev_header_i
   , input                                            rev_accept_i

   // Per-bank L2 DMA command handshakes, internal (hashed) addresses
   , input [l2_banks_p-1:0][daddr_width_p-1:0]        dma_addr_i
   , input [l2_banks_p-1:0]                           dma_write_i
   , input [l2_banks_p-1:0]                           dma_accept_i

   // Physical-address queries: may the line be dirty in this slice?
   , input [num_query_p-1:0][paddr_width_p-1:0]       query_paddr_i
   , output logic [num_query_p-1:0]                   query_dirty_o
   );

  `declare_bp_bedrock_if(paddr_width_p, lce_id_width_p, cce_id_width_p, did_width_p, lce_assoc_p);
  `bp_cast_i(bp_bedrock_mem_fwd_header_s, fwd_header);
  `bp_cast_i(bp_bedrock_mem_rev_header_s, rev_header);

  typedef struct packed
  {
    logic                         v;
    logic                         dirty;
    logic [pending_width_p-1:0]   pending;
    logic [line_width_lp-1:0]     line;
  } entry_s;

  entry_s entry_r [l2_banks_p][l2_sets_p][ways_p];
  logic sticky_r [l2_banks_p][l2_sets_p];

  // Last beat of each multi-beat message, so a message counts once.
  logic fwd_last_lo, rev_last_lo;
  bp_me_stream_pump_control
   #(.bp_params_p(bp_params_p)
     ,.stream_mask_p(mem_fwd_stream_mask_gp)
     ,.data_width_p(bedrock_fill_width_p)
     ,.payload_width_p(mem_fwd_payload_width_lp)
     ,.widest_beat_size_p(e_size_1B)
     )
   fwd_pump
    (.clk_i(clk_i), .reset_i(reset_i)
     ,.header_i(fwd_header_i), .ack_i(fwd_accept_i)
     ,.addr_o(), .first_o(), .critical_o(), .last_o(fwd_last_lo)
     );
  bp_me_stream_pump_control
   #(.bp_params_p(bp_params_p)
     ,.stream_mask_p(mem_rev_stream_mask_gp)
     ,.data_width_p(bedrock_fill_width_p)
     ,.payload_width_p(mem_rev_payload_width_lp)
     ,.widest_beat_size_p(e_size_1B)
     )
   rev_pump
    (.clk_i(clk_i), .reset_i(reset_i)
     ,.header_i(rev_header_i), .ack_i(rev_accept_i)
     ,.addr_o(), .first_o(), .critical_o(), .last_o(rev_last_lo)
     );

  wire fwd_is_write = fwd_header_cast_i.msg_type inside {e_bedrock_mem_wr, e_bedrock_mem_amo};
  wire rev_is_write = rev_header_cast_i.msg_type inside {e_bedrock_mem_wr, e_bedrock_mem_amo};

  // Hash physical addresses into the L2's internal address space.
  localparam num_hash_lp = 2 + num_query_p;
  logic [num_hash_lp-1:0][paddr_width_p-1:0] hash_paddr_li;
  logic [num_hash_lp-1:0][daddr_width_p-1:0] hash_daddr_lo;
  logic [num_hash_lp-1:0][lg_l2_banks_lp-1:0] hash_bank_lo;
  logic [num_hash_lp-1:0] hash_dram_lo;
  assign hash_paddr_li[0] = fwd_header_cast_i.addr;
  assign hash_paddr_li[1] = rev_header_cast_i.addr;
  for (genvar q = 0; q < num_query_p; q++)
    assign hash_paddr_li[2+q] = query_paddr_i[q];
  for (genvar h = 0; h < num_hash_lp; h++)
    begin : hash
      bp_me_dram_hash_encode
       #(.bp_params_p(bp_params_p))
       encode
        (.paddr_i(hash_paddr_li[h])
         ,.data_i('0)
         ,.dram_o(hash_dram_lo[h])
         ,.daddr_o(hash_daddr_lo[h])
         ,.slice_o()
         ,.bank_o(hash_bank_lo[h])
         ,.data_o()
         );
    end

  function automatic logic [lg_l2_sets_lp-1:0] set_of(input logic [line_width_lp-1:0] line);
    return lg_l2_sets_lp'(line);
  endfunction

  // Queries: a hit on a valid entry that is dirty or has a pending write, or a
  // sticky set, reports dirty.
  for (genvar q = 0; q < num_query_p; q++)
    begin : query
      wire [line_width_lp-1:0] qline = hash_daddr_lo[2+q][daddr_width_p-1:l2_block_offset_width_lp];
      wire [lg_l2_banks_lp-1:0] qbank = (l2_banks_p > 1) ? hash_bank_lo[2+q] : '0;
      always_comb
        begin
          query_dirty_o[q] = sticky_r[qbank][set_of(qline)];
          for (int w = 0; w < ways_p; w++)
            begin
              entry_s e;
              e = entry_r[qbank][set_of(qline)][w];
              if (e.v & (e.line == qline) & (e.dirty | (e.pending != '0)))
                query_dirty_o[q] = 1'b1;
            end
        end
    end

  wire [line_width_lp-1:0] fwd_line = hash_daddr_lo[0][daddr_width_p-1:l2_block_offset_width_lp];
  wire [line_width_lp-1:0] rev_line = hash_daddr_lo[1][daddr_width_p-1:l2_block_offset_width_lp];
  wire [lg_l2_banks_lp-1:0] fwd_bank = (l2_banks_p > 1) ? hash_bank_lo[0] : '0;
  wire [lg_l2_banks_lp-1:0] rev_bank = (l2_banks_p > 1) ? hash_bank_lo[1] : '0;
  wire fwd_write_v = fwd_accept_i & fwd_last_lo & fwd_is_write & hash_dram_lo[0];
  wire rev_ack_v   = rev_accept_i & rev_last_lo & rev_is_write & hash_dram_lo[1];

  // Updates apply in a fixed order within a cycle; each touches one set.
  // verilator lint_off BLKSEQ
  always_ff @(posedge clk_i)
    if (reset_i)
      begin
        for (int b = 0; b < l2_banks_p; b++)
          for (int s = 0; s < l2_sets_p; s++)
            begin
              sticky_r[b][s] = 1'b0;
              for (int w = 0; w < ways_p; w++)
                entry_r[b][s][w] = '0;
            end
      end
    else
      begin
        // L2 DMA: write-back or refill of a line with no queued write cleans it.
        for (int b = 0; b < l2_banks_p; b++)
          if (dma_accept_i[b])
            begin
              logic [line_width_lp-1:0] dline;
              dline = dma_addr_i[b][daddr_width_p-1:l2_block_offset_width_lp];
              for (int w = 0; w < ways_p; w++)
                if (entry_r[b][set_of(dline)][w].v & (entry_r[b][set_of(dline)][w].line == dline)
                    & (entry_r[b][set_of(dline)][w].pending == '0))
                  entry_r[b][set_of(dline)][w] = '0;
            end

        // Acknowledged write: one fewer queued, and the L2 copy is now dirty.
        if (rev_ack_v)
          for (int w = 0; w < ways_p; w++)
            if (entry_r[rev_bank][set_of(rev_line)][w].v
                & (entry_r[rev_bank][set_of(rev_line)][w].line == rev_line))
              begin
                if (entry_r[rev_bank][set_of(rev_line)][w].pending != '0)
                  entry_r[rev_bank][set_of(rev_line)][w].pending
                    = entry_r[rev_bank][set_of(rev_line)][w].pending - 1'b1;
                entry_r[rev_bank][set_of(rev_line)][w].dirty = 1'b1;
              end

        // Accepted write message: allocate or bump the line's entry.
        if (fwd_write_v)
          begin
            logic found, placed;
            found = 1'b0; placed = 1'b0;
            for (int w = 0; w < ways_p; w++)
              if (!found & entry_r[fwd_bank][set_of(fwd_line)][w].v
                  & (entry_r[fwd_bank][set_of(fwd_line)][w].line == fwd_line))
                begin
                  found = 1'b1;
                  if (~&entry_r[fwd_bank][set_of(fwd_line)][w].pending)
                    entry_r[fwd_bank][set_of(fwd_line)][w].pending
                      = entry_r[fwd_bank][set_of(fwd_line)][w].pending + 1'b1;
                  else
                    sticky_r[fwd_bank][set_of(fwd_line)] = 1'b1;
                end
            if (!found)
              for (int w = 0; w < ways_p; w++)
                if (!placed & ~entry_r[fwd_bank][set_of(fwd_line)][w].v)
                  begin
                    placed = 1'b1;
                    entry_r[fwd_bank][set_of(fwd_line)][w] =
                      '{v: 1'b1, dirty: 1'b0, pending: pending_width_p'(1), line: fwd_line};
                  end
            if (!found & !placed)
              sticky_r[fwd_bank][set_of(fwd_line)] = 1'b1;
          end
      end
  // verilator lint_on BLKSEQ

  // synopsys translate_off
  always_ff @(negedge clk_i)
    if (~reset_i & fwd_write_v)
      begin
        if (sticky_r[fwd_bank][set_of(fwd_line)])
          $display("L2DIRTY sticky bank=%0d set=%0d t=%0t", fwd_bank, set_of(fwd_line), $time);
      end
  // synopsys translate_on

endmodule
