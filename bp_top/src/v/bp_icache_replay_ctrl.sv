module bp_icache_replay_ctrl
 #(parameter paddr_width_p = 40
   , parameter els_p = 256
   , localparam index_width_lp = $clog2(els_p)
   , localparam count_width_lp = $clog2(els_p+1)
   )
  (input                                clk_i
   , input                              reset_i

   // The original one-line M-mode test ingress remains available and has
   // priority over background prefix traffic.
   , input                              direct_v_i
   , input [paddr_width_p-1:0]          direct_paddr_i
   , output logic                       direct_ready_o

   // M-mode configuration plane.
   , input                              entry_write_v_i
   , input [index_width_lp-1:0]         entry_write_index_i
   , input [paddr_width_p-1:0]          entry_write_paddr_i
   , input                              count_write_v_i
   , input [count_width_lp-1:0]         count_i
   , input                              clear_counters_i

   // S/M-mode launch plane.
   , input                              trigger_v_i

   // Completed advisory-buffer residency query. A prefix entry spends one
   // cycle here before it may enter the UCE, so already-complete lines do not
   // get withdrawn and refetched on every context-switch trigger.
   , output logic                       resident_query_v_o
   , output logic [paddr_width_p-1:0]   resident_query_paddr_o
   , input                              resident_i

   // Detached UCE replay lane.
   , output logic                       replay_v_o
   , output logic [paddr_width_p-1:0]   replay_paddr_o
   , input                              replay_ready_i

   , output logic [63:0]                status_o
   );

  logic [paddr_width_p-1:0] prefix_mem [0:els_p-1];
  logic [count_width_lp-1:0] count_r, fetch_index_r;
  logic [index_width_lp-1:0] read_index_r;
  logic [paddr_width_p-1:0] entry_paddr_r;
  logic busy_r, read_pending_r, entry_valid_r, resident_query_pending_r;
  logic [15:0] accepted_count_r;
  logic [7:0] trigger_count_r, dropped_trigger_count_r;
  logic [8:0] resident_drop_count_r;

  wire prefix_accept = entry_valid_r & ~resident_query_pending_r
    & replay_ready_i & ~direct_v_i;
  wire start_read = busy_r & ~entry_valid_r & ~read_pending_r
                    & (fetch_index_r < count_r);

  assign direct_ready_o = replay_ready_i;
  assign resident_query_v_o = entry_valid_r & resident_query_pending_r;
  assign resident_query_paddr_o = entry_paddr_r;
  assign replay_v_o = direct_v_i
    | (entry_valid_r & ~resident_query_pending_r);
  assign replay_paddr_o = direct_v_i ? direct_paddr_i : entry_paddr_r;

  // bits  0     detached lane ready
  //       1     prefix replay active
  //       2     one table entry waiting for query/admission
  //       3     synchronous table read pending
  //      12:4   configured entry count
  //      21:13  next table index
  //      37:22  accepted prefix entries
  //      45:38  accepted triggers
  //      53:46  triggers dropped while busy/unconfigured
  //      54     completed-buffer query pending
  //      63:55  prefix entries dropped as already resident
  assign status_o = {resident_drop_count_r, resident_query_pending_r
                     ,dropped_trigger_count_r, trigger_count_r
                     ,accepted_count_r, fetch_index_r, count_r
                     ,read_pending_r, entry_valid_r, busy_r, replay_ready_i};

  always_ff @(posedge clk_i) begin
    if (entry_write_v_i & ~busy_r)
      prefix_mem[entry_write_index_i] <= entry_write_paddr_i;

    if (reset_i) begin
      count_r <= '0;
      fetch_index_r <= '0;
      read_index_r <= '0;
      entry_paddr_r <= '0;
      busy_r <= 1'b0;
      read_pending_r <= 1'b0;
      entry_valid_r <= 1'b0;
      resident_query_pending_r <= 1'b0;
      accepted_count_r <= '0;
      trigger_count_r <= '0;
      dropped_trigger_count_r <= '0;
      resident_drop_count_r <= '0;
    end else begin
      if (count_write_v_i & ~busy_r)
        count_r <= count_i;

      if (clear_counters_i) begin
        accepted_count_r <= '0;
        trigger_count_r <= '0;
        dropped_trigger_count_r <= '0;
        resident_drop_count_r <= '0;
      end

      if (trigger_v_i) begin
        if (~busy_r & (count_r != '0)) begin
          busy_r <= 1'b1;
          fetch_index_r <= '0;
          read_pending_r <= 1'b0;
          entry_valid_r <= 1'b0;
          resident_query_pending_r <= 1'b0;
          if (~clear_counters_i & ~&trigger_count_r)
            trigger_count_r <= trigger_count_r + 1'b1;
        end else if (~clear_counters_i & ~&dropped_trigger_count_r)
          dropped_trigger_count_r <= dropped_trigger_count_r + 1'b1;
      end

      if (start_read) begin
        read_index_r <= fetch_index_r[index_width_lp-1:0];
        fetch_index_r <= fetch_index_r + 1'b1;
        read_pending_r <= 1'b1;
      end

      if (read_pending_r) begin
        entry_paddr_r <= prefix_mem[read_index_r];
        entry_valid_r <= 1'b1;
        resident_query_pending_r <= 1'b1;
        read_pending_r <= 1'b0;
      end

      if (entry_valid_r & resident_query_pending_r) begin
        resident_query_pending_r <= 1'b0;
        if (resident_i) begin
          entry_valid_r <= 1'b0;
          if (~clear_counters_i & ~&resident_drop_count_r)
            resident_drop_count_r <= resident_drop_count_r + 1'b1;
          if ((fetch_index_r >= count_r) & ~read_pending_r)
            busy_r <= 1'b0;
        end
      end

      if (prefix_accept) begin
        entry_valid_r <= 1'b0;
        if (~clear_counters_i & ~&accepted_count_r)
          accepted_count_r <= accepted_count_r + 1'b1;
        if ((fetch_index_r >= count_r) & ~read_pending_r)
          busy_r <= 1'b0;
      end
    end
  end

  initial begin
    assert (els_p == 256)
      else $error("shared I-cache replay CSR encoding requires 256 entries");
    assert (paddr_width_p <= 56)
      else $error("shared I-cache replay entry does not fit one CSR payload");
  end

endmodule
