/**
 * bp_be_context_mem.sv
 *
 * Private backing store for nonresident architectural integer contexts.
 *
 * This is intentionally outside of the coherent Dcache path.  Context state
 * is architectural core-private state: a future capacity-limited version may
 * spill whole lines to memory, but resident context save/restore must not
 * depend on ordinary load/store arbitration or cache refill latency.
 *
 * The first interface is deliberately small and pipeline-friendly:
 * - two 64-bit register writes per cycle, for eviction scans and rpush;
 * - one synchronous 8-register (512-bit for RV64) line read per cycle.
 *
 * The registered response address allows callers to issue consecutive line
 * reads and associate each response without relying on a combinational RAM.
 */

module bp_be_context_mem
 #(parameter int context_count_p = 1
   , parameter int context_id_width_p = 1
   , parameter int reg_count_p = 32
   , parameter int reg_addr_width_p = 5
   , parameter int data_width_p = 64
   , parameter int regs_per_line_p = 8
   , parameter int line_count_p = (reg_count_p + regs_per_line_p - 1) / regs_per_line_p
   , parameter int line_index_width_p = (line_count_p > 1) ? $clog2(line_count_p) : 1
   )
  (input clk_i
   , input reset_i

   , input [1:0] w_v_i
   , input [1:0][context_id_width_p-1:0] w_context_id_i
   , input [1:0][reg_addr_width_p-1:0] w_reg_addr_i
   , input [1:0][data_width_p-1:0] w_data_i

   , input r_v_i
   , input [context_id_width_p-1:0] r_context_id_i
   , input [line_index_width_p-1:0] r_line_index_i
   , output logic r_v_o
   , output logic [context_id_width_p-1:0] r_context_id_o
   , output logic [line_index_width_p-1:0] r_line_index_o
   , output logic [regs_per_line_p*data_width_p-1:0] r_data_o
   );

  localparam int bank_els_lp = context_count_p*line_count_p;
  localparam int bank_addr_width_lp = $clog2(bank_els_lp);
  localparam int lane_index_width_lp = $clog2(regs_per_line_p);
  logic [regs_per_line_p-1:0][data_width_p-1:0] bank_r_data_lo;
  logic [context_count_p-1:0][reg_count_p-1:0] valid_r;

  // The pipeline register file gives CSR remote writes priority over ordinary
  // writeback. Mirror that exact ordering into the write-through image so each
  // lane remains a simple one-write, one-read synchronous RAM.
  wire scalar_w_v = |w_v_i;
  wire scalar_w_port = w_v_i[1];
  wire [context_id_width_p-1:0] scalar_w_context_id = w_context_id_i[scalar_w_port];
  wire [reg_addr_width_p-1:0] scalar_w_reg_addr = w_reg_addr_i[scalar_w_port];
  wire [data_width_p-1:0] scalar_w_data = w_data_i[scalar_w_port];
  wire [line_index_width_p-1:0] scalar_w_line_index =
    scalar_w_reg_addr[reg_addr_width_p-1:lane_index_width_lp];

  for (genvar lane = 0; lane < regs_per_line_p; lane++) begin : lane
    wire lane_w_v = scalar_w_v
                    & (scalar_w_reg_addr[0+:lane_index_width_lp]
                       == lane_index_width_lp'(lane));
    bsg_mem_1r1w_sync
     #(.width_p(data_width_p), .els_p(bank_els_lp), .ram_style_p("block"))
     lane_mem
      (.clk_i(clk_i)
       ,.reset_i(reset_i)
       ,.w_v_i(lane_w_v)
       ,.w_addr_i({scalar_w_context_id, scalar_w_line_index})
       ,.w_data_i(scalar_w_data)
       ,.r_v_i(r_v_i)
       ,.r_addr_i({r_context_id_i, r_line_index_i})
       ,.r_data_o(bank_r_data_lo[lane])
       );
  end

  always_comb begin
    r_data_o = '0;
    for (int lane = 0; lane < regs_per_line_p; lane++) begin
      automatic int reg_idx = lane + regs_per_line_p*int'(r_line_index_o);
      if ((reg_idx < reg_count_p) && valid_r[r_context_id_o][reg_idx])
        r_data_o[data_width_p*lane +: data_width_p] = bank_r_data_lo[lane];
    end
  end

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      r_v_o <= 1'b0;
      r_context_id_o <= '0;
      r_line_index_o <= '0;
      valid_r <= '0;
    end else begin
      r_v_o <= r_v_i;
      if (r_v_i) begin
        r_context_id_o <= r_context_id_i;
        r_line_index_o <= r_line_index_i;
      end

      if (scalar_w_v)
        valid_r[scalar_w_context_id][scalar_w_reg_addr] <= 1'b1;
    end
  end

endmodule
