// Experimental inactive CSR image store. No integration or area claim.
// Independent save/reseed writers retain every write; reseed wins a collision.
// Each resetless RAM has one writer. Only validity and last-writer bits reset.
module bp_be_csr_snapshot_store
 #(parameter int contexts_p = 4
   , parameter int width_p = 1666
   , parameter int addr_width_p = (contexts_p > 1) ? $clog2(contexts_p) : 1
   )
  (input logic clk_i, reset_i
   , input logic save_v_i, seed_v_i
   , input logic [addr_width_p-1:0] save_addr_i, seed_addr_i, read_addr_i
   , input logic [width_p-1:0] save_data_i, seed_data_i
   , output logic [contexts_p-1:0] valid_o
   , output logic read_valid_o
   , output logic [width_p-1:0] read_data_o
   );
  (* ram_style = "distributed" *) logic [width_p-1:0] save_mem [0:contexts_p-1];
  (* ram_style = "distributed" *) logic [width_p-1:0] seed_mem [0:contexts_p-1];
  logic [contexts_p-1:0] valid_r, owner_r;
  // Separate canonical one-write processes; no payload initialization/reset.
  always_ff @(posedge clk_i)
    if (!reset_i && save_v_i && (int'(save_addr_i) < contexts_p))
      save_mem[save_addr_i] <= save_data_i;
  always_ff @(posedge clk_i)
    if (!reset_i && seed_v_i && (int'(seed_addr_i) < contexts_p))
      seed_mem[seed_addr_i] <= seed_data_i;
  always_ff @(posedge clk_i) begin
    if (reset_i) begin valid_r <= '0; owner_r <= '0; end
    else begin
      if (save_v_i && (int'(save_addr_i) < contexts_p)) begin
        valid_r[save_addr_i] <= 1'b1;
        owner_r[save_addr_i] <= 1'b0;
      end
      if (seed_v_i && (int'(seed_addr_i) < contexts_p)) begin
        valid_r[seed_addr_i] <= 1'b1;
        owner_r[seed_addr_i] <= 1'b1;
      end
    end
  end
  assign valid_o = valid_r;
  always_comb begin
    read_valid_o = 1'b0;
    read_data_o = '0;
    if (int'(read_addr_i) < contexts_p) begin
      read_valid_o = valid_r[read_addr_i];
      if (valid_r[read_addr_i])
        read_data_o = owner_r[read_addr_i] ? seed_mem[read_addr_i] : save_mem[read_addr_i];
    end
  end
endmodule
