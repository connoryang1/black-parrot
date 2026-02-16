/**
 * bp_be_regfile_mt.sv
 *
 * Multi-threaded Register File for Black Parrot
 *
 * Description:
 *   Thread-indexed register file supporting simultaneous read/write operations
 *   across multiple hardware threads without context switching.
 *
 * Architecture:
 *   - Each hardware thread has its own register file (32 x 64-bit registers)
 *   - Address format: {thread_id[thread_id_width_gp-1:0], reg_addr[reg_addr_width_gp-1:0]}
 *   - Supports multiple simultaneous reads from different threads
 *   - Single write port shared across all threads (can be extended if needed)
 *   - Forwarding logic handles read-after-write hazards within same thread
 *
 * Advantages over traditional register renaming:
 *   - No complex dependency tracking across threads
 *   - Zero latency context switching (thread's state is ready immediately)
 *   - Simpler hardware compared to out-of-order execution + renaming
 *   - Scales linearly with number of threads
 *
 * Parameters:
 *   num_threads_p      - Number of threads (default: 1)
 *   data_width_p       - Data width in bits (default: 64 for RV64)
 *   read_ports_p       - Number of simultaneous reads (default: 2)
 *   zero_x0_p          - If 1, x0 register always reads as 0 (RISC-V spec)
 */

`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_regfile_mt
 import bp_common_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    `declare_bp_proc_params(bp_params_p)

   , parameter `BSG_INV_PARAM(data_width_p)
   , parameter `BSG_INV_PARAM(read_ports_p)
   , parameter `BSG_INV_PARAM(zero_x0_p)
   )
  (input                                            clk_i
   , input                                          reset_i

   // Read bus - each read can be from a different thread
   , input [read_ports_p-1:0]                       rs_r_v_i
   , input [read_ports_p-1:0][num_threads_gp:0]    rs_thread_id_i  // Thread ID for each read
   , input [read_ports_p-1:0][reg_addr_width_gp-1:0] rs_addr_i
   , output [read_ports_p-1:0][data_width_p-1:0]    rs_data_o

   // Write bus - writes to a specific thread's register
   , input                                          rd_w_v_i
   , input [num_threads_gp:0]                       rd_thread_id_i  // Thread ID for write
   , input [reg_addr_width_gp-1:0]                  rd_addr_i
   , input [data_width_p-1:0]                       rd_data_i
   );

  // Derived parameters
  localparam rf_els_lp = 2**reg_addr_width_gp;       // 32 registers per thread
  localparam total_rf_els_lp = 2**(reg_addr_width_gp + $clog2(num_threads_gp)); // Total storage

  // Compose thread-indexed addresses
  logic [read_ports_p-1:0][reg_addr_width_gp+$clog2(num_threads_gp)-1:0] rs_addr_indexed;
  logic [reg_addr_width_gp+$clog2(num_threads_gp)-1:0] rd_addr_indexed;

  // Construct indexed addresses: {thread_id, reg_addr}
  for (genvar i = 0; i < read_ports_p; i++)
    begin : read_addr_construct
      assign rs_addr_indexed[i] = {rs_thread_id_i[i], rs_addr_i[i]};
    end
  assign rd_addr_indexed = {rd_thread_id_i, rd_addr_i};

  // Register file storage
  logic [read_ports_p-1:0] rs_v_li;
  logic [read_ports_p-1:0][reg_addr_width_gp+$clog2(num_threads_gp)-1:0] rs_addr_li;
  logic [read_ports_p-1:0][data_width_p-1:0] rs_data_lo;

  // Select appropriate memory based on read ports
  if (read_ports_p == 2)
    begin : twoport
      bsg_mem_2r1w_sync
       #(.width_p(data_width_p), .els_p(total_rf_els_lp))
       regfile_mem
        (.clk_i(clk_i)
         ,.reset_i(reset_i)

         ,.w_v_i(rd_w_v_i)
         ,.w_addr_i(rd_addr_indexed)
         ,.w_data_i(rd_data_i)

         ,.r0_v_i(rs_v_li[0])
         ,.r0_addr_i(rs_addr_li[0])
         ,.r0_data_o(rs_data_lo[0])

         ,.r1_v_i(rs_v_li[1])
         ,.r1_addr_i(rs_addr_li[1])
         ,.r1_data_o(rs_data_lo[1])
         );
    end
  else if (read_ports_p == 3)
    begin : threeport
      bsg_mem_3r1w_sync
       #(.width_p(data_width_p), .els_p(total_rf_els_lp))
       regfile_mem
        (.clk_i(clk_i)
         ,.reset_i(reset_i)

         ,.w_v_i(rd_w_v_i)
         ,.w_addr_i(rd_addr_indexed)
         ,.w_data_i(rd_data_i)

         ,.r0_v_i(rs_v_li[0])
         ,.r0_addr_i(rs_addr_li[0])
         ,.r0_data_o(rs_data_lo[0])

         ,.r1_v_i(rs_v_li[1])
         ,.r1_addr_i(rs_addr_li[1])
         ,.r1_data_o(rs_data_lo[1])

         ,.r2_v_i(rs_v_li[2])
         ,.r2_addr_i(rs_addr_li[2])
         ,.r2_data_o(rs_data_lo[2])
         );
    end
  else
    begin : error
      $error("Error: unsupported number of read ports");
    end

  // Save the written data for forwarding
  logic [data_width_p-1:0] rd_data_r;
  logic [num_threads_gp:0] rd_thread_id_r;
  logic [reg_addr_width_gp-1:0] rd_addr_r;
  bsg_dff
   #(.width_p(data_width_p + num_threads_gp + 1 + reg_addr_width_gp))
   rd_reg
    (.clk_i(clk_i)
     ,.data_i({rd_data_i, rd_thread_id_i, rd_addr_i})
     ,.data_o({rd_data_r, rd_thread_id_r, rd_addr_r})
     );

  // Forwarding and bypass logic for each read port
  for (genvar i = 0; i < read_ports_p; i++)
    begin : bypass
      logic zero_rs_r, fwd_rs_r, rs_r_v_r;
      logic [data_width_p-1:0] fwd_data_lo;

      // Check for reads from x0 (should always return 0)
      wire zero_rs = rs_r_v_i[i] & (rs_addr_i[i] == '0) & (zero_x0_p == 1);

      // Check for forwarding: write to same thread and same register
      wire same_thread = (rd_thread_id_i == rs_thread_id_i[i]);
      wire fwd_rs = rd_w_v_i & same_thread & rs_r_v_i[i] & (rd_addr_i == rs_addr_i[i]);

      bsg_dff
       #(.width_p(3))
       rs_r_v_reg
        (.clk_i(clk_i)
         ,.data_i({zero_rs, fwd_rs, rs_r_v_i[i]})
         ,.data_o({zero_rs_r, fwd_rs_r, rs_r_v_r})
         );

      assign fwd_data_lo = zero_rs_r ? '0 : fwd_rs_r ? rd_data_r : rs_data_lo[i];

      logic [reg_addr_width_gp-1:0] rs_addr_r;
      logic [num_threads_gp:0] rs_thread_id_r;
      bsg_dff_en
       #(.width_p(reg_addr_width_gp + num_threads_gp + 1))
       rs_addr_reg
        (.clk_i(clk_i)
         ,.en_i(rs_r_v_i[i])
         ,.data_i({rs_thread_id_i[i], rs_addr_i[i]})
         ,.data_o({rs_thread_id_r, rs_addr_r})
         );

      logic [data_width_p-1:0] rs_data_n, rs_data_r;
      // Check for replacement: write to same thread and same register (delayed)
      wire same_thread_r = (rd_thread_id_r == rs_thread_id_r);
      wire replace_rs = rd_w_v_i & same_thread_r & (rs_addr_r == rd_addr_i);
      assign rs_data_n = replace_rs ? rd_data_i : fwd_data_lo;

      bsg_dff_en
       #(.width_p(data_width_p))
       rs_data_reg
        (.clk_i(clk_i)
         ,.en_i(rs_r_v_r | replace_rs)
         ,.data_i(rs_data_n)
         ,.data_o(rs_data_r)
         );

      // Control signals
      assign rs_v_li[i] = rs_r_v_i[i] & ~fwd_rs;
      assign rs_addr_li[i] = rs_addr_indexed[i];

      // Output: forward if we had forwarding, else use saved register data
      assign rs_data_o[i] = rs_r_v_r ? fwd_data_lo : rs_data_r;
    end

endmodule

`BSG_ABSTRACT_MODULE(bp_be_regfile_mt)
