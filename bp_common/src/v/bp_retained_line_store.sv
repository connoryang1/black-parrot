/*
 * Partitioned full-64-byte retained payload, with one owning-clock RAM per
 * I/D partition. Ordinary L1 geometry is unchanged. This is an experimental
 * miss-only lookaside: synchronous tag-way scan followed by eight word reads,
 * never an asynchronous capacity-wide CAM or 512-bit payload mux.
 *
 * Slots are real full lines; a partial final way is supported. I and D may
 * have different capacities, including zero. Logical global addresses never
 * leave their partition. Reset/clear sweeps tag validity only, not payload RAM.
 *
 * Conservative coherence: every invalidation retires ALL retained lines in
 * that backend set by advancing a per-set epoch. Collateral invalidation and
 * an epoch-wrap tag sweep are real costs; configured slots do not guarantee
 * useful unique capacity. This can later be replaced by exact invalidation
 * without changing the client's address/handshake interface.
 *
 * Every accepted lookup produces exactly one response, even across clear or
 * invalidation (a forced miss). Response valid is held until ready. Coherence
 * may revoke a queued hit to a miss while stalled; consume hit/data ONLY at
 * the response handshake. Absent coherence, a held response is stable.
 * Every accepted atomic insert produces one done pulse, with published set
 * only after all eight payload writes and atomic tag publication. Cancel,
 * clear, matching-set invalidation, or a full nonreplacing set retire an
 * insert without publication. The client assembles complete, nonaborted
 * packets before insertion and may drop optional captures when not ready.
 */
module bp_retained_line_store
 #(parameter int unsigned paddr_width_p = 34
   , parameter int unsigned sets_p = 64
   , parameter int unsigned i_lines_p = 64
   , parameter int unsigned d_lines_p = 64
   , parameter int unsigned epoch_width_p = 8
   )
  (input logic [1:0] clk_i
   , input logic [1:0] reset_i
   , input logic [1:0] clear_i
   , input logic [1:0] invalidate_v_i
   , input logic [1:0][paddr_width_p-1:0] invalidate_addr_i

   , input logic [1:0] lookup_v_i
   , output logic [1:0] lookup_ready_o
   , input logic [1:0][paddr_width_p-1:0] lookup_addr_i
   , output logic [1:0] resp_v_o
   , input logic [1:0] resp_ready_i
   , output logic [1:0] resp_hit_o
   , output logic [1:0][511:0] resp_data_o

   , input logic [1:0] insert_v_i
   , output logic [1:0] insert_ready_o
   , input logic [1:0][paddr_width_p-1:0] insert_addr_i
   , input logic [1:0][511:0] insert_data_i
   , input logic [1:0] insert_replace_i
   , input logic [1:0] insert_cancel_i
   , output logic [1:0] insert_done_o
   , output logic [1:0] insert_published_o
   , output logic [1:0] busy_o
   , output logic [1:0] epoch_wrap_o
   );

  localparam int set_width_lp = (sets_p > 1) ? $clog2(sets_p) : 1;
  localparam int set_bits_lp = $clog2(sets_p);
  localparam int tag_width_lp = paddr_width_p - 6 - set_bits_lp;
  localparam int total_lines_lp = i_lines_p + d_lines_p;
  localparam int ram_lines_lp = (total_lines_lp > 0) ? total_lines_lp : 1;
  localparam int tag_addr_width_lp = (ram_lines_lp > 1) ? $clog2(ram_lines_lp) : 1;
  localparam int data_addr_width_lp = $clog2(ram_lines_lp * 8);
  typedef struct packed {
    logic valid;
    logic [epoch_width_p-1:0] epoch;
    logic [tag_width_lp-1:0] tag;
  } tag_info_s;
  localparam int tag_bits_lp = $bits(tag_info_s);

  logic [1:0] tag_v, tag_w, data_v, data_w;
  logic [1:0][tag_addr_width_lp-1:0] tag_addr;
  logic [1:0][data_addr_width_lp-1:0] data_addr;
  logic [1:0][tag_bits_lp-1:0] tag_wdata, tag_rdata;
  logic [1:0][63:0] data_wdata, data_rdata;

  for (genvar lane = 0; lane < 2; lane++) begin : lane_fsm
    localparam int lines_lp = (lane == 0) ? i_lines_p : d_lines_p;
    localparam int base_lp = (lane == 0) ? 0 : i_lines_p;
    localparam int local_addr_width_lp = (lines_lp > 1) ? $clog2(lines_lp) : 1;
    localparam int lane_ram_lines_lp = (lines_lp > 0) ? lines_lp : 1;
    localparam int lane_data_addr_width_lp = $clog2(lane_ram_lines_lp * 8);
    // Static lane ownership needs only one synchronous read/write port.
    // Preserve read-first behavior, enables and read latency; only physical
    // storage/indexing changes. Existing global-address assertions below still
    // bound every access. Disabled lanes never access their placeholder arrays.
    /* verilator tracing_off */
    (* ram_style = "block", ram_decomp = "area" *) logic [tag_bits_lp-1:0] tag_mem [lane_ram_lines_lp];
    (* ram_style = "block", ram_decomp = "area" *) logic [63:0] payload_mem [lane_ram_lines_lp * 8];
    /* verilator tracing_on */
    logic [tag_bits_lp-1:0] tag_q;
    logic [63:0] data_q;
    wire [local_addr_width_lp-1:0] local_tag_addr
      = local_addr_width_lp'(tag_addr[lane] - tag_addr_width_lp'(base_lp));
    wire [lane_data_addr_width_lp-1:0] local_data_addr
      = lane_data_addr_width_lp'(data_addr[lane] - data_addr_width_lp'(base_lp * 8));
    assign tag_rdata[lane] = tag_q;
    assign data_rdata[lane] = data_q;
    always @(posedge clk_i[lane]) begin
      if (tag_v[lane]) begin
        if (tag_w[lane]) tag_mem[local_tag_addr] <= tag_wdata[lane];
        tag_q <= tag_mem[local_tag_addr];
      end
      if (data_v[lane]) begin
        if (data_w[lane]) payload_mem[local_data_addr] <= data_wdata[lane];
        data_q <= payload_mem[local_data_addr];
      end
    end
    localparam int ways_lp = (lines_lp + sets_p - 1) / sets_p;
    localparam int way_width_lp = (ways_lp > 1) ? $clog2(ways_lp) : 1;
    typedef enum logic [3:0] {
      e_clear, e_idle, e_lookup_tag, e_lookup_compare, e_lookup_data,
      e_lookup_collect, e_insert_tag, e_insert_compare, e_insert_invalidate,
      e_insert_data
    } state_e;
    state_e state_r;
    // Separate writers are required: an unrelated invalidation and final
    // insertion publication may update epoch and RR on the same clock edge.
    (* ram_style = "distributed" *) logic [way_width_lp-1:0] rr_r [sets_p];
    logic [set_width_lp-1:0] set_r;
    logic [tag_width_lp-1:0] ptag_r;
    logic [epoch_width_p-1:0] insert_epoch_r;
    logic [local_addr_width_lp-1:0] slot_r, empty_slot_r, clear_slot_r;
    logic empty_found_r, replace_r;
    logic [511:0] insert_data_r;
    logic [2:0] word_r;
    logic resp_v_r, resp_hit_r;
    logic insert_done_r, insert_published_r, epoch_wrap_r;
    assign insert_done_o[lane] = insert_done_r;
    assign insert_published_o[lane] = insert_published_r;
    assign epoch_wrap_o[lane] = epoch_wrap_r;
    logic [511:0] resp_data_r;

    wire [epoch_width_p-1:0] line_epoch, inv_epoch;
    wire last_slot;
    wire [set_width_lp-1:0] inv_set = set_width_lp'(invalidate_addr_i[lane] >> 6)
                                                    & set_width_lp'(sets_p-1);
    wire set_kill = invalidate_v_i[lane] && (inv_set == set_r);
    wire wrap = (state_r != e_clear) && invalidate_v_i[lane]
                  && (&inv_epoch) && (lines_lp != 0);
    wire clear_now = clear_i[lane] || wrap;
    // The idle insert capture and active tag comparison never use their epoch
    // read simultaneously. Invalidation retains its independent async read.
    wire [set_width_lp-1:0] insert_set
      = set_width_lp'(insert_addr_i[lane] >> 6) & set_width_lp'(sets_p-1);
    wire [set_width_lp-1:0] epoch_read_set = (state_r == e_idle) ? insert_set : set_r;
    wire [set_width_lp-1:0] clear_set
      = set_width_lp'(clear_slot_r) & set_width_lp'(sets_p-1);
    wire publish_metadata = (state_r == e_insert_data) && (word_r == 3'd7)
                            && !clear_now && !set_kill && !insert_cancel_i[lane];

    // A full tag sweep already covers every metadata set when lines>=sets.
    // No memory reset, no new busy cycles: init writes share that existing
    // sweep, including held/restarted clears. I epochs retain their original
    // FF form so the production invalidate=0 connection trivially prunes them.
    // Small/disabled partitions retain all-set reset and unused-set wrap rules.
    if ((lane != 0) && (lines_lp >= sets_p)) begin : distributed_epochs
      wire epoch_write_v = !reset_i[lane]
        && ((state_r == e_clear) || (!clear_now && invalidate_v_i[lane]));
      wire [set_width_lp-1:0] epoch_write_addr
        = (state_r == e_clear) ? clear_set : inv_set;
      wire [epoch_width_p-1:0] epoch_write_data
        = (state_r == e_clear) ? '0 : (inv_epoch + 1'b1);
      // Canonical one-port write shape; the controller still owns every
      // reset/clear/wrap priority and both original asynchronous read indices.
      bp_retained_epoch_ram
       #(.sets_p(sets_p), .width_p(epoch_width_p)) epoch_ram
       (.clk_i(clk_i[lane]), .write_v_i(epoch_write_v)
        ,.write_addr_i(epoch_write_addr), .write_data_i(epoch_write_data)
        ,.read_addr_i(epoch_read_set), .invalidate_addr_i(inv_set)
        ,.read_data_o(line_epoch), .invalidate_data_o(inv_epoch));
    end else begin : flop_epochs
      (* ram_style = "distributed" *) logic [epoch_width_p-1:0] epochs_r [sets_p];
      assign line_epoch = epochs_r[epoch_read_set];
      assign inv_epoch = epochs_r[inv_set];
      always_ff @(posedge clk_i[lane]) begin
        if (reset_i[lane] || clear_now)
          for (int s = 0; s < sets_p; s++) epochs_r[s] <= '0;
        else if (invalidate_v_i[lane] && (state_r != e_clear))
          epochs_r[inv_set] <= epochs_r[inv_set] + 1'b1;
      end
    end
    if (lines_lp >= sets_p) begin : distributed_rr
      always_ff @(posedge clk_i[lane]) begin
        if (!reset_i[lane]) begin
          if (state_r == e_clear) rr_r[clear_set] <= '0;
          else if (publish_metadata) begin
            if (last_slot) rr_r[set_r] <= '0;
            else rr_r[set_r] <= way_width_lp'((int'(slot_r) >> set_bits_lp) + 1);
          end
        end
      end
    end else begin : flop_rr
      always_ff @(posedge clk_i[lane]) begin
        if (reset_i[lane] || clear_now)
          for (int s = 0; s < sets_p; s++) rr_r[s] <= '0;
        else if (publish_metadata) begin
          if (last_slot) rr_r[set_r] <= '0;
          else rr_r[set_r] <= way_width_lp'((int'(slot_r) >> set_bits_lp) + 1);
        end
      end
    end
`ifdef BP_RETAINED_METADATA_VERIFY
    // Verification-only initialization accounting: intentionally excluded from
    // implementation builds; RAM initial contents must never be assumed zero.
    logic [sets_p-1:0] metadata_initialized_r;
    always_ff @(posedge clk_i[lane]) begin
      if (reset_i[lane] || clear_now) metadata_initialized_r <= '0;
      else if (state_r == e_clear) metadata_initialized_r[clear_set] <= 1'b1;
      if (!reset_i[lane] && (lines_lp >= sets_p) && (state_r == e_idle))
        assert (&metadata_initialized_r) else $fatal(1,"retained metadata used before complete sweep");
    end
`endif
    wire lookup_active = (state_r == e_lookup_tag) || (state_r == e_lookup_compare)
                          || (state_r == e_lookup_data) || (state_r == e_lookup_collect);
    wire insert_active = (state_r == e_insert_tag) || (state_r == e_insert_compare)
                          || (state_r == e_insert_invalidate) || (state_r == e_insert_data);
    if (lines_lp == 0) begin : disabled_partition
      assign last_slot = 1'b1;
    end else begin : nonempty_partition
      assign last_slot = (int'(slot_r) + sets_p >= lines_lp);
    end
    tag_info_s read_tag;
    assign read_tag = tag_info_s'(tag_rdata[lane]);
    wire valid_tag = read_tag.valid && (read_tag.epoch == line_epoch);
    wire tag_match = valid_tag && (read_tag.tag == ptag_r);

    assign lookup_ready_o[lane] = (state_r == e_idle) && !resp_v_r && !clear_now && !reset_i[lane];
    assign insert_ready_o[lane] = lookup_ready_o[lane] && !lookup_v_i[lane]
                                 && !invalidate_v_i[lane] && !insert_cancel_i[lane];
    assign busy_o[lane] = (state_r != e_idle) || resp_v_r;
    assign resp_v_o[lane] = resp_v_r && !reset_i[lane];
    assign resp_hit_o[lane] = resp_hit_r && !clear_now && !set_kill && !reset_i[lane];
    assign resp_data_o[lane] = resp_data_r;

    always_comb begin
      tag_v[lane] = 1'b0; tag_w[lane] = 1'b0;
      tag_addr[lane] = tag_addr_width_lp'(base_lp + int'(slot_r)); tag_wdata[lane] = '0;
      data_v[lane] = 1'b0; data_w[lane] = 1'b0;
      data_addr[lane] = data_addr_width_lp'((base_lp + int'(slot_r)) * 8 + int'(word_r));
      data_wdata[lane] = insert_data_r[int'(word_r)*64+:64];
      if (!reset_i[lane]) begin
        if ((state_r == e_clear) && (lines_lp != 0)) begin
          tag_v[lane] = 1'b1; tag_w[lane] = 1'b1;
          tag_addr[lane] = tag_addr_width_lp'(base_lp + int'(clear_slot_r));
        end else if (!clear_now && !set_kill) begin
          case (state_r)
            e_lookup_tag, e_insert_tag: tag_v[lane] = 1'b1;
            e_lookup_data: data_v[lane] = 1'b1;
            e_lookup_collect: if (word_r != 3'd7) begin
              data_v[lane] = 1'b1;
              data_addr[lane] = data_addr_width_lp'((base_lp + int'(slot_r)) * 8 + int'(word_r) + 1);
            end
            e_insert_invalidate: if (!insert_cancel_i[lane]) begin
              tag_v[lane] = 1'b1; tag_w[lane] = 1'b1;
            end
            e_insert_data: if (!insert_cancel_i[lane]) begin
              data_v[lane] = 1'b1; data_w[lane] = 1'b1;
              if (word_r == 3'd7) begin
                tag_v[lane] = 1'b1; tag_w[lane] = 1'b1;
                tag_wdata[lane] = tag_info_s'{valid:1'b1, epoch:insert_epoch_r, tag:ptag_r};
              end
            end
            default: begin end
          endcase
        end
      end
    end

    always_ff @(posedge clk_i[lane]) begin
      if (reset_i[lane]) begin
        state_r <= (lines_lp == 0) ? e_idle : e_clear;
        clear_slot_r <= '0; resp_v_r <= 1'b0; resp_hit_r <= 1'b0;
        set_r <= '0; ptag_r <= '0; slot_r <= '0; empty_slot_r <= '0;
        insert_epoch_r <= '0; word_r <= '0; empty_found_r <= 1'b0; replace_r <= 1'b0;
        insert_done_r <= 1'b0; insert_published_r <= 1'b0; epoch_wrap_r <= 1'b0;
      end else begin
        insert_done_r <= 1'b0; insert_published_r <= 1'b0; epoch_wrap_r <= wrap;
        if (resp_v_r && resp_ready_i[lane]) resp_v_r <= 1'b0;
        if (clear_now) begin
          state_r <= (lines_lp == 0) ? e_idle : e_clear; clear_slot_r <= '0;
          if (lookup_active) begin resp_v_r <= 1'b1; resp_hit_r <= 1'b0; end
          else if (resp_v_r) resp_hit_r <= 1'b0;
          if (insert_active) insert_done_r <= 1'b1;
        end else if (lookup_active && set_kill) begin
          state_r <= e_idle; resp_v_r <= 1'b1; resp_hit_r <= 1'b0;
        end else if (insert_active && (set_kill || insert_cancel_i[lane])) begin
          state_r <= e_idle; insert_done_r <= 1'b1;
        end else begin
          if (resp_v_r && set_kill) resp_hit_r <= 1'b0;
          case (state_r)
            e_clear: begin
              if ((lines_lp == 0) || (int'(clear_slot_r) == lines_lp-1)) state_r <= e_idle;
              else clear_slot_r <= clear_slot_r + 1'b1;
            end
            e_idle: begin
              if (lookup_v_i[lane] && lookup_ready_o[lane]) begin
                set_r <= set_width_lp'(lookup_addr_i[lane] >> 6) & set_width_lp'(sets_p-1);
                ptag_r <= tag_width_lp'(lookup_addr_i[lane] >> (6+set_bits_lp));
                slot_r <= local_addr_width_lp'((lookup_addr_i[lane] >> 6) & paddr_width_p'(sets_p-1));
                if ((lines_lp == 0) || (int'((lookup_addr_i[lane] >> 6) & paddr_width_p'(sets_p-1)) >= lines_lp)) begin
                  resp_v_r <= 1'b1; resp_hit_r <= 1'b0;
                end else state_r <= e_lookup_tag;
              end else if (insert_v_i[lane] && insert_ready_o[lane]) begin
                set_r <= set_width_lp'(insert_addr_i[lane] >> 6) & set_width_lp'(sets_p-1);
                ptag_r <= tag_width_lp'(insert_addr_i[lane] >> (6+set_bits_lp));
                slot_r <= local_addr_width_lp'((insert_addr_i[lane] >> 6) & paddr_width_p'(sets_p-1));
                insert_epoch_r <= line_epoch;
                insert_data_r <= insert_data_i[lane]; replace_r <= insert_replace_i[lane]; empty_found_r <= 1'b0;
                if ((lines_lp == 0) || (int'((insert_addr_i[lane] >> 6) & paddr_width_p'(sets_p-1)) >= lines_lp))
                  insert_done_r <= 1'b1;
                else state_r <= e_insert_tag;
              end
            end
            e_lookup_tag: state_r <= e_lookup_compare;
            e_lookup_compare: begin
              if (tag_match) begin word_r <= '0; state_r <= e_lookup_data; end
              else if (last_slot) begin state_r <= e_idle; resp_v_r <= 1'b1; resp_hit_r <= 1'b0; end
              else begin slot_r <= slot_r + local_addr_width_lp'(sets_p); state_r <= e_lookup_tag; end
            end
            e_lookup_data: state_r <= e_lookup_collect;
            e_lookup_collect: begin
              resp_data_r[int'(word_r)*64+:64] <= data_rdata[lane];
              if (word_r == 3'd7) begin state_r <= e_idle; resp_v_r <= 1'b1; resp_hit_r <= 1'b1; end
              else word_r <= word_r + 1'b1;
            end
            e_insert_tag: state_r <= e_insert_compare;
            e_insert_compare: begin
              if (tag_match) state_r <= e_insert_invalidate;
              else if (last_slot) begin
                if (!valid_tag || empty_found_r || replace_r) begin
                  if (empty_found_r) slot_r <= empty_slot_r;
                  else if (valid_tag) slot_r <= local_addr_width_lp'(int'(rr_r[set_r]) * sets_p + int'(set_r));
                  state_r <= e_insert_invalidate;
                end else begin state_r <= e_idle; insert_done_r <= 1'b1; end
              end else begin
                if (!valid_tag && !empty_found_r) begin empty_found_r <= 1'b1; empty_slot_r <= slot_r; end
                slot_r <= slot_r + local_addr_width_lp'(sets_p); state_r <= e_insert_tag;
              end
            end
            e_insert_invalidate: begin word_r <= '0; state_r <= e_insert_data; end
            e_insert_data: begin
              if (word_r == 3'd7) begin
                state_r <= e_idle; insert_done_r <= 1'b1; insert_published_r <= 1'b1;
              end else word_r <= word_r + 1'b1;
            end
            default: state_r <= e_clear;
          endcase
        end
      end
    end

    // These assertions also cover non-power-of-two/partial final partitions.
    always @(posedge clk_i[lane]) if (!reset_i[lane]) begin
      if (tag_v[lane]) assert ((int'(tag_addr[lane]) >= base_lp) && (int'(tag_addr[lane]) < base_lp+lines_lp))
        else $fatal(1,"retained tag port escaped its lane partition");
      if (data_v[lane]) assert ((int'(data_addr[lane]) >= base_lp*8) && (int'(data_addr[lane]) < (base_lp+lines_lp)*8))
        else $fatal(1,"retained payload port escaped its lane partition");
      if (insert_v_i[lane] && insert_ready_o[lane]) assert (insert_addr_i[lane][5:0] == 0)
        else $fatal(1,"retained inserts require a complete aligned 64-byte line");
      assert (!insert_published_o[lane] || insert_done_o[lane]) else $fatal(1,"publication without insert terminal event");
    end
  end

  initial begin
    assert (sets_p != 0 && ((sets_p & (sets_p-1)) == 0)) else $fatal(1,"retained sets must be power of two");
    assert (paddr_width_p > 6+set_bits_lp && epoch_width_p > 0) else $fatal(1,"invalid retained address/epoch width");
  end
endmodule

/* verilator lint_off DECLFILENAME */
/* Canonical no-reset single-write/two-asynchronous-read epoch storage.
 * The owning controller supplies the existing clear sweep and invalidation
 * priority. No initialization, policy, latency or additional BRAM is implied.
 */
module bp_retained_epoch_ram
 #(parameter int unsigned sets_p = 256
   , parameter int unsigned width_p = 8
   , localparam int addr_width_lp = (sets_p > 1) ? $clog2(sets_p) : 1
   )
  (input logic clk_i
   , input logic write_v_i
   , input logic [addr_width_lp-1:0] write_addr_i
   , input logic [width_p-1:0] write_data_i
   , input logic [addr_width_lp-1:0] read_addr_i, invalidate_addr_i
   , output logic [width_p-1:0] read_data_o, invalidate_data_o
   );
  (* ram_style = "distributed" *) logic [width_p-1:0] mem [sets_p];
  assign read_data_o = mem[read_addr_i];
  assign invalidate_data_o = mem[invalidate_addr_i];
  always_ff @(posedge clk_i)
    if (write_v_i) mem[write_addr_i] <= write_data_i;
endmodule
/* verilator lint_on DECLFILENAME */
