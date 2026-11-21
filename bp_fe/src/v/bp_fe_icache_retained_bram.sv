// Miss-only adapter for the shared synchronous retained-line store.  The store
// owns physical tags and 64-byte payloads; this adapter owns fetch cancellation
// and assembles accepted UCE beats without backpressuring the ordinary refill.
module bp_fe_icache_retained_bram
 #(parameter paddr_width_p = 40
   , parameter block_width_p = 512
   , parameter fill_width_p = 128
   , localparam beats_lp = block_width_p/fill_width_p
   , localparam offset_lp = $clog2(block_width_p/8)
   )
  (input clk_i, reset_i, clear_i, enable_i
   , input lookup_v_i
   , input [paddr_width_p-1:0] lookup_paddr_i
   , input cancel_i, consume_i
   , output wait_o, hit_o
   , output [block_width_p-1:0] data_o
   , output lookup_v_o
   , input lookup_ready_i
   , output [paddr_width_p-1:0] lookup_paddr_o
   , input resp_v_i, resp_hit_i
   , input [block_width_p-1:0] resp_data_i
   , output resp_ready_o
   , input capture_v_i, capture_demand_i, capture_first_i
   , input [paddr_width_p-1:0] capture_paddr_i
   , input [beats_lp-1:0] capture_beats_i
   , input [fill_width_p-1:0] capture_data_i
   , input demand_cancel_i, demand_pin_i
   , output insert_v_o
   , input insert_ready_i
   , output [paddr_width_p-1:0] insert_paddr_o
   , output [block_width_p-1:0] insert_data_o
   , output insert_replace_o, insert_cancel_o
   , input insert_done_i, insert_published_i
   , output demand_published_o
   , output logic drop_o
   , output idle_o
   );

  logic query_active_r, query_poison_r, query_done_r, query_hit_r;
  logic [paddr_width_p-1:0] query_paddr_r;
  logic [block_width_p-1:0] query_data_r;
  wire query_cancel = cancel_i | clear_i | ~enable_i | ~lookup_v_i
    | (query_paddr_r != lookup_paddr_i);
  assign lookup_v_o = lookup_v_i & ~query_active_r & ~query_done_r
    & ~cancel_i & ~clear_i & enable_i;
  assign lookup_paddr_o = lookup_paddr_i;
  // Every accepted query owns exactly one response, including cancellation.
  // Never recycle that ownership on a redirect: an old reply could otherwise
  // become the instruction for the next fetch at the same physical address.
  assign resp_ready_o = 1'b1;
  assign wait_o = lookup_v_i & ~query_done_r & enable_i;
  assign hit_o = lookup_v_i & query_done_r & query_hit_r & ~cancel_i & ~clear_i & enable_i;
  assign data_o = query_data_r;
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      query_active_r <= 1'b0;
      query_poison_r <= 1'b0;
      query_done_r <= 1'b0;
      query_hit_r <= 1'b0;
      query_paddr_r <= '0;
      query_data_r <= '0;
    end else begin
      if (cancel_i | clear_i | ~enable_i | ~lookup_v_i | consume_i)
        query_done_r <= 1'b0;
      if (query_active_r & query_cancel)
        query_poison_r <= 1'b1;
      if (lookup_v_o & lookup_ready_i) begin
        query_active_r <= 1'b1;
        query_poison_r <= 1'b0;
        query_paddr_r <= lookup_paddr_i;
      end
      if (resp_v_i & query_active_r) begin
        query_active_r <= 1'b0;
        if (~query_poison_r & ~query_cancel) begin
          query_done_r <= 1'b1;
          query_hit_r <= resp_hit_i;
          query_data_r <= resp_data_i;
        end
      end
    end
  end

  logic partial_v_r, partial_demand_r;
  logic [paddr_width_p-1:offset_lp] partial_addr_r;
  logic [beats_lp-1:0] partial_beats_r, next_beats;
  logic [block_width_p-1:0] partial_data_r, next_data;
  wire fresh = ~partial_v_r | capture_first_i
    | (partial_addr_r != capture_paddr_i[paddr_width_p-1:offset_lp])
    | (partial_demand_r != capture_demand_i);
  always_comb begin
    next_beats = fresh ? '0 : partial_beats_r;
    next_data = fresh ? '0 : partial_data_r;
    for (int beat = 0; beat < beats_lp; beat++)
      if (capture_beats_i[beat]) begin
        next_beats[beat] = 1'b1;
        next_data[beat*fill_width_p+:fill_width_p] = capture_data_i;
      end
  end

  logic pending_v_r, pending_demand_r, pending_replace_r;
  logic [paddr_width_p-1:0] pending_addr_r;
  logic [block_width_p-1:0] pending_data_r;
  logic insert_active_r, insert_demand_r;
  wire capture_ok = capture_v_i & ~clear_i & enable_i
    & (~capture_demand_i | ~demand_cancel_i);
  assign insert_v_o = pending_v_r & ~insert_active_r & ~clear_i & enable_i
    & (~pending_demand_r | ~demand_cancel_i);
  assign insert_paddr_o = pending_addr_r;
  assign insert_data_o = pending_data_r;
  assign insert_replace_o = pending_replace_r;
  assign insert_cancel_o = clear_i | ~enable_i | (insert_active_r & insert_demand_r & demand_cancel_i);
  assign demand_published_o = insert_published_i & insert_active_r & insert_demand_r
    & ~clear_i & ~demand_cancel_i & enable_i;
  assign idle_o = ~(query_active_r | query_done_r | partial_v_r | pending_v_r | insert_active_r);
  wire insert_accept = insert_v_o & insert_ready_i;
  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      partial_v_r <= 1'b0;
      partial_demand_r <= 1'b0;
      partial_addr_r <= '0;
      partial_beats_r <= '0;
      partial_data_r <= '0;
      pending_v_r <= 1'b0;
      pending_demand_r <= 1'b0;
      pending_replace_r <= 1'b0;
      pending_addr_r <= '0;
      pending_data_r <= '0;
      insert_active_r <= 1'b0;
      insert_demand_r <= 1'b0;
      drop_o <= 1'b0;
    end else begin
      drop_o <= 1'b0;
      if (insert_done_i)
        insert_active_r <= 1'b0;
      if (insert_accept) begin
        pending_v_r <= 1'b0;
        insert_active_r <= 1'b1;
        insert_demand_r <= pending_demand_r;
      end
      if (clear_i | ~enable_i) begin
        partial_v_r <= 1'b0;
        pending_v_r <= 1'b0;
      end else begin
        if (demand_cancel_i) begin
          if (partial_demand_r) partial_v_r <= 1'b0;
          if (pending_demand_r) pending_v_r <= 1'b0;
        end
        if (capture_ok) begin
          partial_addr_r <= capture_paddr_i[paddr_width_p-1:offset_lp];
          partial_demand_r <= capture_demand_i;
          partial_data_r <= next_data;
          partial_beats_r <= next_beats;
          partial_v_r <= ~(&next_beats);
          if (&next_beats) begin
            // Optional capture cannot stall a required ordinary refill.  A
            // full staging queue drops the whole new line, never publishes
            // partial data and reports the loss to external statistics.
            if (~pending_v_r | insert_accept) begin
              pending_v_r <= 1'b1;
              pending_addr_r <= {capture_paddr_i[paddr_width_p-1:offset_lp], {offset_lp{1'b0}}};
              pending_data_r <= next_data;
              pending_demand_r <= capture_demand_i;
              pending_replace_r <= ~capture_demand_i | ~demand_pin_i;
            end else drop_o <= 1'b1;
          end
        end
      end
    end
  end
endmodule
