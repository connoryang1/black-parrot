/*
 * Read-only prefetch transaction table.
 *
 * The table is deliberately independent of the coherence FSM.  It owns only
 * metadata for detached L1 fills; the caller performs allocation arbitration,
 * memory issue, and data/tag writes.  Responses may return out of order.
 */
module bp_prefetch_mshr_table
  #(parameter addr_width_p = 56
    , parameter id_width_p = 2
    , parameter context_width_p = 2
    , parameter way_width_p = 3
    , parameter els_p = 2
    , parameter beats_p = 4
    , parameter line_offset_width_p = 6
    )
  (input clk_i
   , input reset_i

   , output logic alloc_ready_o
   , input alloc_v_i
   , input [addr_width_p-1:0] alloc_addr_i
   , input [context_width_p-1:0] alloc_context_i
   , input [way_width_p-1:0] alloc_way_i
   , output logic [id_width_p-1:0] alloc_id_o
   , output logic alloc_yumi_o
   , output logic alloc_duplicate_o

   , input issue_v_i
   , input [id_width_p-1:0] issue_id_i
   , output logic issue_ready_o
   , input response_v_i
   , input [id_width_p-1:0] response_id_i
   , input [$clog2(beats_p)-1:0] response_beat_i
   , output logic response_ready_o
   , input response_last_i

   , input demand_v_i
   , input [addr_width_p-1:0] demand_addr_i
   , output logic demand_join_o
   , output logic [id_width_p-1:0] demand_id_o
   , input demand_mark_v_i
   , input [id_width_p-1:0] demand_mark_id_i
   , output logic [els_p-1:0] demand_wait_o

   , output logic [els_p-1:0] valid_o
   , output logic [els_p-1:0] issued_o
   , output logic [els_p-1:0][addr_width_p-1:0] addr_o
   , output logic [els_p-1:0][context_width_p-1:0] context_o
   , output logic [els_p-1:0][way_width_p-1:0] way_o
   , output logic [els_p-1:0][beats_p-1:0] fill_mask_o
   , output logic [$clog2(els_p+1)-1:0] occupancy_o
   , output logic [$clog2(els_p+1)-1:0] max_occupancy_o
   );

  localparam slot_width_lp = (els_p > 1) ? $clog2(els_p) : 1;

  logic [els_p-1:0] issued_r;
  logic [els_p-1:0][addr_width_p-1:0] addr_r;
  logic [els_p-1:0][context_width_p-1:0] context_r;
  logic [els_p-1:0][way_width_p-1:0] way_r;
  logic [els_p-1:0][beats_p-1:0] fill_mask_r;
  logic [els_p-1:0] demand_wait_r;
  logic [$clog2(els_p+1)-1:0] max_occupancy_r;
  wire issue_id_valid = (issue_id_i < els_p);
  wire response_id_valid = (response_id_i < els_p);
  wire [slot_width_lp-1:0] issue_slot = issue_id_i[slot_width_lp-1:0];
  wire [slot_width_lp-1:0] response_slot = response_id_i[slot_width_lp-1:0];
  wire [slot_width_lp-1:0] alloc_slot = alloc_id_o[slot_width_lp-1:0];

  always_comb begin
    alloc_ready_o = 1'b0;
    alloc_id_o = '0;
    alloc_duplicate_o = 1'b0;
    for (int i = els_p-1; i >= 0; i--) begin
      if (!valid_o[i]) begin
        alloc_ready_o = 1'b1;
        alloc_id_o = id_width_p'(i);
      end
      if (valid_o[i]
          && (addr_r[i][addr_width_p-1:line_offset_width_p]
              == alloc_addr_i[addr_width_p-1:line_offset_width_p])) begin
        alloc_duplicate_o = alloc_v_i;
        alloc_id_o = id_width_p'(i);
      end
    end

    issue_ready_o = issue_v_i && issue_id_valid && valid_o[issue_slot] && !issued_r[issue_slot];
    response_ready_o = response_v_i && response_id_valid && valid_o[response_slot] && issued_r[response_slot];
    demand_join_o = 1'b0;
    demand_id_o = '0;
    for (int i = els_p-1; i >= 0; i--)
      if (valid_o[i]
          && (addr_r[i][addr_width_p-1:line_offset_width_p]
              == demand_addr_i[addr_width_p-1:line_offset_width_p])) begin
        demand_join_o = demand_v_i;
        demand_id_o = id_width_p'(i);
      end
    alloc_yumi_o = alloc_v_i && (alloc_ready_o || alloc_duplicate_o);
  end

  assign issued_o = issued_r;
  assign addr_o = addr_r;
  assign context_o = context_r;
  assign way_o = way_r;
  assign fill_mask_o = fill_mask_r;
  assign occupancy_o = $countones(valid_o);
  assign max_occupancy_o = max_occupancy_r;
  assign demand_wait_o = demand_wait_r;

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      valid_o <= '0;
      issued_r <= '0;
      addr_r <= '0;
      context_r <= '0;
      way_r <= '0;
      fill_mask_r <= '0;
      max_occupancy_r <= '0;
      demand_wait_r <= '0;
    end else begin
      if (alloc_v_i && alloc_ready_o && !alloc_duplicate_o) begin
        valid_o[alloc_slot] <= 1'b1;
        issued_r[alloc_slot] <= 1'b0;
        addr_r[alloc_slot] <= alloc_addr_i;
        context_r[alloc_slot] <= alloc_context_i;
        way_r[alloc_slot] <= alloc_way_i;
        fill_mask_r[alloc_slot] <= '0;
        demand_wait_r[alloc_slot] <= 1'b0;
      end
      if (issue_ready_o)
        issued_r[issue_slot] <= 1'b1;
      if (response_ready_o && response_last_i) begin
        valid_o[response_slot] <= 1'b0;
        issued_r[response_slot] <= 1'b0;
        demand_wait_r[response_slot] <= 1'b0;
      end
      if (response_ready_o)
        fill_mask_r[response_slot][response_beat_i] <= 1'b1;
      if (demand_mark_v_i && (demand_mark_id_i < els_p))
        demand_wait_r[demand_mark_id_i[slot_width_lp-1:0]] <= 1'b1;
      if ($countones(valid_o) > max_occupancy_r)
        max_occupancy_r <= $countones(valid_o);
    end
  end

  initial begin
    assert (els_p > 0) else $error("prefetch table must have at least one entry");
    assert (els_p <= (1 << id_width_p))
      else $error("prefetch table ID width cannot represent every entry");
  end
endmodule
