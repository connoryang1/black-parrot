// Experimental single-write inactive CSR store. Integration is not performed.
// The bb575 producer proves save and seed mutually exclusive; both use one
// common save-data wire. Preserve the qualification/owner logic outside RAM.
module bp_be_csr_snapshot_store_production
 #(parameter int contexts_p=4, width_p=1666
   , parameter int addr_width_p=(contexts_p>1)?$clog2(contexts_p):1)
  (input logic clk_i, reset_i, write_v_i
   ,input logic [addr_width_p-1:0] write_addr_i,read_addr_i
   ,input logic [width_p-1:0] write_data_i
   ,output logic [contexts_p-1:0] valid_o
   ,output logic read_valid_o
   ,output logic [width_p-1:0] read_data_o);
  (* ram_style="distributed" *) logic [width_p-1:0] mem [0:contexts_p-1];
  logic [contexts_p-1:0] valid_r;
  always_ff @(posedge clk_i)
    if (!reset_i && write_v_i && int'(write_addr_i)<contexts_p)
      mem[write_addr_i]<=write_data_i;
  always_ff @(posedge clk_i) begin
    if (reset_i)valid_r<='0;
    else if (write_v_i && int'(write_addr_i)<contexts_p)valid_r[write_addr_i]<=1'b1;
  end
  assign valid_o=valid_r;
  always_comb begin
    read_valid_o=1'b0;read_data_o='0;
    if (int'(read_addr_i)<contexts_p)begin
      read_valid_o=valid_r[read_addr_i];
      read_data_o=mem[read_addr_i]; // undefined while invalid; consumed only when valid
    end
  end
endmodule
