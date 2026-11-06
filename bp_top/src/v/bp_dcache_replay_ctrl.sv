module bp_dcache_replay_ctrl
 #(parameter paddr_width_p = 40
   , parameter slots_p = 4
   , parameter entries_per_slot_p = 32
   , parameter command_queue_els_p = 2
   , localparam slot_width_lp = $clog2(slots_p)
   , localparam entry_width_lp = $clog2(entries_per_slot_p)
   , localparam count_width_lp = $clog2(entries_per_slot_p+1)
   , localparam command_ptr_width_lp = $clog2(command_queue_els_p)
   , localparam command_count_width_lp = $clog2(command_queue_els_p+1)
   )
  (input                                      clk_i
   , input                                    reset_i

   // S-mode configuration is performed outside the scheduler wakeup path.
   , input                                    entry_write_v_i
   , input [slot_width_lp-1:0]                entry_write_slot_i
   , input [entry_width_lp-1:0]               entry_write_index_i
   , input [paddr_width_p-1:0]                entry_write_paddr_i
   , input                                    config_write_v_i
   , input [slot_width_lp-1:0]                config_write_slot_i
   , input [count_width_lp-1:0]               config_write_count_i
   , input [15:0]                             config_write_delay_i
   , input [7:0]                              config_write_gap_i

   // A wakeup emits one stable software-assigned footprint slot.  The optional
   // follow bit requests one instruction-prefix trigger after every admitted
   // data response has drained from D-UCE.
   , input                                    trigger_v_i
   , input [slot_width_lp-1:0]                trigger_slot_i
   , input                                    trigger_follow_i

   // The top level consumes an entry either by admitting it to D-UCE or by
   // filtering an invalid/PMA-rejected address. Backpressure holds the entry.
   , output logic                             replay_v_o
   , output logic [paddr_width_p-1:0]         replay_paddr_o
   , input                                    replay_yumi_i
   , input                                    replay_accepted_i

   // D-UCE state is sampled into the otherwise reserved status bits.  This
   // separates command admission from downstream response/retirement state.
   , input [2:0]                              downstream_outstanding_i
   , input                                    downstream_complete_i

   // Hold the sequenced trigger until the shared instruction-prefix
   // controller can accept it rather than treating a busy controller as a
   // best-effort drop.
   , input                                    follow_ready_i
   , output logic                             follow_trigger_o

   , input                                    clear_counters_i
   , output logic [63:0]                      status_o
   );

  localparam table_els_lp = slots_p*entries_per_slot_p;
  localparam table_addr_width_lp = $clog2(table_els_lp);

  logic [paddr_width_p-1:0] footprint_mem [0:table_els_lp-1];
  logic [slots_p-1:0][count_width_lp-1:0] count_r;
  logic [slots_p-1:0][15:0] delay_config_r;
  logic [slots_p-1:0][7:0] gap_config_r;

  logic [command_queue_els_p-1:0][slot_width_lp-1:0] command_queue_r;
  logic [command_queue_els_p-1:0] command_follow_queue_r;
  logic [command_ptr_width_lp-1:0] command_head_r, command_tail_r;
  logic [command_count_width_lp-1:0] command_count_r;

  logic busy_r, read_pending_r, entry_valid_r;
  logic active_follow_r, follow_pending_r, follow_armed_r;
  logic [slot_width_lp-1:0] active_slot_r;
  logic [count_width_lp-1:0] fetch_index_r;
  logic [table_addr_width_lp-1:0] read_addr_r;
  logic [paddr_width_p-1:0] entry_paddr_r;
  logic [15:0] delay_r;
  logic [7:0] gap_r;

  logic [15:0] accepted_entry_count_r, filtered_entry_count_r;
  logic [7:0] accepted_trigger_count_r, dropped_trigger_count_r;
  logic drain_age_valid_r;
  logic [11:0] drain_age_r;

  wire trigger_accept = trigger_v_i
    & (command_count_r < command_queue_els_p);
  wire trigger_drop = trigger_v_i & ~trigger_accept;
  wire command_start = ~busy_r & ~follow_pending_r
    & (command_count_r != '0);
  wire start_read = busy_r & (delay_r == '0) & (gap_r == '0)
    & ~entry_valid_r & ~read_pending_r
    & (fetch_index_r < count_r[active_slot_r]);
  wire replay_yumi = entry_valid_r & replay_yumi_i;
  // D-UCE allocation becomes observable after the replay admission edge.
  // Require one full controller cycle before judging the downstream state so
  // a just-admitted final entry cannot create a premature combinational pulse.
  wire follow_ready = follow_pending_r & follow_armed_r
    & (downstream_outstanding_i == '0) & ~downstream_complete_i
    & follow_ready_i;
  wire replay_live = busy_r | entry_valid_r | (command_count_r != '0)
    | follow_pending_r | (downstream_outstanding_i != '0)
    | downstream_complete_i;

  // This deliberately coarse age is observable without changing the Linux
  // kernel or benchmark ABI.  It distinguishes replay still in flight from a
  // recent or comfortably early drain while consuming only the two status
  // bits that software did not use.
  wire [1:0] drain_age_bucket = ~drain_age_valid_r | (drain_age_r == '0)
    ? 2'b00
    : (drain_age_r < 12'd512)
      ? 2'b01
      : (drain_age_r < 12'd2048)
        ? 2'b10
        : 2'b11;

  assign replay_v_o = entry_valid_r;
  assign replay_paddr_o = entry_paddr_r;
  assign follow_trigger_o = follow_ready;

  // bits  0      replay active
  //       2:1    queued commands
  //       3      entry held under backpressure
  //       9:4    next entry index
  //      25:10   entries admitted below L1
  //      41:26   entries filtered before the lower detached-prefetch path
  //      49:42   accepted triggers
  //      57:50   dropped triggers
  //      59:58   cycles since the most recent replay fully drained:
  //                0 = no completed drain or replay still live
  //                1 = 1..511 cycles
  //                2 = 512..2047 cycles
  //                3 = 2048 or more cycles
  //      62:60   allocated D-UCE prefetch slots, saturated at seven
  //      63      at least one completed reply awaiting retirement
  assign status_o = {downstream_complete_i, downstream_outstanding_i
                     ,drain_age_bucket, dropped_trigger_count_r
                     ,accepted_trigger_count_r, filtered_entry_count_r
                     ,accepted_entry_count_r, fetch_index_r[5:0]
                     ,entry_valid_r, command_count_r[1:0], busy_r};

  always_ff @(posedge clk_i) begin
    if (entry_write_v_i & ~busy_r)
      footprint_mem[{entry_write_slot_i, entry_write_index_i}]
        <= entry_write_paddr_i;

    if (reset_i) begin
      count_r <= '0;
      delay_config_r <= '0;
      gap_config_r <= '0;
      command_head_r <= '0;
      command_tail_r <= '0;
      command_count_r <= '0;
      command_follow_queue_r <= '0;
      busy_r <= 1'b0;
      active_follow_r <= 1'b0;
      follow_pending_r <= 1'b0;
      follow_armed_r <= 1'b0;
      read_pending_r <= 1'b0;
      entry_valid_r <= 1'b0;
      active_slot_r <= '0;
      fetch_index_r <= '0;
      read_addr_r <= '0;
      entry_paddr_r <= '0;
      delay_r <= '0;
      gap_r <= '0;
      accepted_entry_count_r <= '0;
      filtered_entry_count_r <= '0;
      accepted_trigger_count_r <= '0;
      dropped_trigger_count_r <= '0;
      drain_age_valid_r <= 1'b0;
      drain_age_r <= '0;
    end else begin
      if (config_write_v_i & ~busy_r) begin
        count_r[config_write_slot_i] <= config_write_count_i;
        delay_config_r[config_write_slot_i] <= config_write_delay_i;
        gap_config_r[config_write_slot_i] <= config_write_gap_i;
      end

      if (clear_counters_i) begin
        accepted_entry_count_r <= '0;
        filtered_entry_count_r <= '0;
        accepted_trigger_count_r <= '0;
        dropped_trigger_count_r <= '0;
        drain_age_valid_r <= 1'b0;
        drain_age_r <= '0;
      end else if (trigger_accept) begin
        drain_age_valid_r <= 1'b1;
        drain_age_r <= '0;
      end else if (drain_age_valid_r) begin
        if (replay_live)
          drain_age_r <= '0;
        else if (~&drain_age_r)
          drain_age_r <= drain_age_r + 1'b1;
      end

      if (trigger_accept) begin
        command_queue_r[command_tail_r] <= trigger_slot_i;
        command_follow_queue_r[command_tail_r] <= trigger_follow_i;
        command_tail_r <= command_tail_r + 1'b1;
        if (~clear_counters_i & ~&accepted_trigger_count_r)
          accepted_trigger_count_r <= accepted_trigger_count_r + 1'b1;
      end else if (trigger_drop & ~clear_counters_i & ~&dropped_trigger_count_r)
        dropped_trigger_count_r <= dropped_trigger_count_r + 1'b1;

      if (command_start) begin
        active_slot_r <= command_queue_r[command_head_r];
        active_follow_r <= command_follow_queue_r[command_head_r];
        command_head_r <= command_head_r + 1'b1;
        fetch_index_r <= '0;
        read_pending_r <= 1'b0;
        entry_valid_r <= 1'b0;
        delay_r <= delay_config_r[command_queue_r[command_head_r]];
        gap_r <= '0;
        busy_r <= (count_r[command_queue_r[command_head_r]] != '0);
        if ((count_r[command_queue_r[command_head_r]] == '0)
            & command_follow_queue_r[command_head_r]) begin
          follow_pending_r <= 1'b1;
          follow_armed_r <= 1'b0;
        end
      end

      if (follow_pending_r & ~follow_armed_r)
        follow_armed_r <= 1'b1;

      if (follow_ready) begin
        follow_pending_r <= 1'b0;
        follow_armed_r <= 1'b0;
      end

      case ({trigger_accept, command_start})
        2'b10: command_count_r <= command_count_r + 1'b1;
        2'b01: command_count_r <= command_count_r - 1'b1;
        default: command_count_r <= command_count_r;
      endcase

      if (busy_r && (delay_r != '0))
        delay_r <= delay_r - 1'b1;
      else if (busy_r && (gap_r != '0))
        gap_r <= gap_r - 1'b1;

      if (start_read) begin
        read_addr_r <= {active_slot_r, fetch_index_r[entry_width_lp-1:0]};
        fetch_index_r <= fetch_index_r + 1'b1;
        read_pending_r <= 1'b1;
      end

      if (read_pending_r) begin
        entry_paddr_r <= footprint_mem[read_addr_r];
        entry_valid_r <= 1'b1;
        read_pending_r <= 1'b0;
      end

      if (replay_yumi) begin
        entry_valid_r <= 1'b0;
        gap_r <= gap_config_r[active_slot_r];
        if (replay_accepted_i) begin
          if (~clear_counters_i & ~&accepted_entry_count_r)
            accepted_entry_count_r <= accepted_entry_count_r + 1'b1;
        end else if (~clear_counters_i & ~&filtered_entry_count_r)
          filtered_entry_count_r <= filtered_entry_count_r + 1'b1;
        if ((fetch_index_r >= count_r[active_slot_r]) & ~read_pending_r) begin
          busy_r <= 1'b0;
          if (active_follow_r) begin
            follow_pending_r <= 1'b1;
            follow_armed_r <= 1'b0;
          end
        end
      end
    end
  end

  initial begin
    assert (slots_p == 4)
      else $error("data replay CSR encoding requires four footprint slots");
    assert (entries_per_slot_p == 32)
      else $error("data replay CSR encoding requires 32 entries per slot");
    assert (command_queue_els_p == 2)
      else $error("data replay status encoding requires a two-command queue");
    assert (paddr_width_p <= 40)
      else $error("data replay entry does not fit the proposed CSR payload");
  end

endmodule

