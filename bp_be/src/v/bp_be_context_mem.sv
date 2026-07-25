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

  logic [regs_per_line_p*data_width_p-1:0]
    mem [0:context_count_p-1][0:line_count_p-1];

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      r_v_o <= 1'b0;
      r_context_id_o <= '0;
      r_line_index_o <= '0;
      r_data_o <= '0;
      for (int context_idx = 0; context_idx < context_count_p; context_idx++)
        for (int line = 0; line < line_count_p; line++)
          mem[context_idx][line] <= '0;
    end else begin
      r_v_o <= r_v_i;
      if (r_v_i) begin
        r_context_id_o <= r_context_id_i;
        r_line_index_o <= r_line_index_i;
        r_data_o <= mem[r_context_id_i][r_line_index_i];
      end

      for (int write_port = 0; write_port < 2; write_port++)
        if (w_v_i[write_port])
          mem[w_context_id_i[write_port]][w_reg_addr_i[write_port] / regs_per_line_p]
            [data_width_p*(w_reg_addr_i[write_port] % regs_per_line_p) +: data_width_p]
              <= w_data_i[write_port];
    end
  end

endmodule
