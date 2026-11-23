// Production-only inactive CSR snapshot encoding. Generic raw store is unchanged.
// Accepted data must be the actual CSR producer expansion; arbitrary raw images
// are deliberately not admitted. Qualification/owners/priority remain outside.
`include "bp_common_defines.svh"
`include "bp_be_defines.svh"

module bp_be_csr_snapshot_store_canonical
 import bp_common_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_params_e bp_params_p = e_bp_default_cfg
   `declare_bp_proc_params(bp_params_p)
   , parameter int contexts_p = 4
   , parameter int width_p = 26*dword_width_gp + rv64_priv_width_gp
   , parameter int addr_width_p = (contexts_p>1)?$clog2(contexts_p):1
   )
  (input logic clk_i, reset_i, write_v_i
   , input logic [addr_width_p-1:0] write_addr_i, read_addr_i
   , input logic [width_p-1:0] write_data_i
   , output logic [contexts_p-1:0] valid_o
   , output logic read_valid_o
   , output logic [width_p-1:0] read_data_o
   );
  `declare_csr_structs(vaddr_width_p, paddr_width_p);
  typedef struct packed {
    logic [dword_width_gp-1:0] dcsr;
    logic [dword_width_gp-1:0] dpc;
    logic [dword_width_gp-1:0] dscratch0;
    logic [dword_width_gp-1:0] dscratch1;
    logic [dword_width_gp-1:0] mstatus;
    logic [dword_width_gp-1:0] medeleg;
    logic [dword_width_gp-1:0] mideleg;
    logic [dword_width_gp-1:0] mie;
    logic [dword_width_gp-1:0] mtvec;
    logic [dword_width_gp-1:0] mcounteren;
    logic [dword_width_gp-1:0] mscratch;
    logic [dword_width_gp-1:0] mepc;
    logic [dword_width_gp-1:0] mcause;
    logic [dword_width_gp-1:0] mtval;
    logic [dword_width_gp-1:0] mip;
    logic [dword_width_gp-1:0] mcycle;
    logic [dword_width_gp-1:0] minstret;
    logic [dword_width_gp-1:0] mcountinhibit;
    logic [dword_width_gp-1:0] stvec;
    logic [dword_width_gp-1:0] scounteren;
    logic [dword_width_gp-1:0] sscratch;
    logic [dword_width_gp-1:0] sepc;
    logic [dword_width_gp-1:0] scause;
    logic [dword_width_gp-1:0] stval;
    logic [dword_width_gp-1:0] satp;
    logic [dword_width_gp-1:0] fcsr;
    logic [rv64_priv_width_gp-1:0] priv_mode;
  } expanded_context_s;
  typedef struct packed {
    bp_dcsr_s dcsr;
    bp_dpc_s dpc;
    bp_dscratch0_s dscratch0;
    bp_dscratch1_s dscratch1;
    bp_mstatus_s mstatus;
    bp_medeleg_s medeleg;
    bp_mideleg_s mideleg;
    bp_mie_s mie;
    bp_mtvec_s mtvec;
    bp_mcounteren_s mcounteren;
    bp_mscratch_s mscratch;
    bp_mepc_s mepc;
    bp_mcause_s mcause;
    bp_mtval_s mtval;
    bp_mip_s mip;
    bp_mcycle_s mcycle;
    bp_minstret_s minstret;
    bp_mcountinhibit_s mcountinhibit;
    bp_stvec_s stvec;
    bp_scounteren_s scounteren;
    bp_sscratch_s sscratch;
    bp_sepc_s sepc;
    bp_scause_s scause;
    bp_stval_s stval;
    bp_satp_s satp;
    bp_fcsr_s fcsr;
    logic [rv64_priv_width_gp-1:0] priv_mode;
  } encoded_context_s;
  localparam int encoded_width_lp = $bits(encoded_context_s);

  function automatic encoded_context_s encode(input expanded_context_s value);
    encoded_context_s result;
    rv64_dcsr_s dcsr_rv;
    rv64_dpc_s dpc_rv;
    rv64_dscratch0_s dscratch0_rv;
    rv64_dscratch1_s dscratch1_rv;
    rv64_mstatus_s mstatus_rv;
    rv64_medeleg_s medeleg_rv;
    rv64_mideleg_s mideleg_rv;
    rv64_mie_s mie_rv;
    rv64_mtvec_s mtvec_rv;
    rv64_mcounteren_s mcounteren_rv;
    rv64_mscratch_s mscratch_rv;
    rv64_mepc_s mepc_rv;
    rv64_mcause_s mcause_rv;
    rv64_mtval_s mtval_rv;
    rv64_mip_s mip_rv;
    rv64_mcycle_s mcycle_rv;
    rv64_minstret_s minstret_rv;
    rv64_mcountinhibit_s mcountinhibit_rv;
    rv64_stvec_s stvec_rv;
    rv64_scounteren_s scounteren_rv;
    rv64_sscratch_s sscratch_rv;
    rv64_sepc_s sepc_rv;
    rv64_scause_s scause_rv;
    rv64_stval_s stval_rv;
    rv64_satp_s satp_rv;
    rv64_fcsr_s fcsr_rv;
    dcsr_rv = value.dcsr;
    result.dcsr = `compress_dcsr_s(dcsr_rv, vaddr_width_p, paddr_width_p);
    dpc_rv = value.dpc;
    result.dpc = `compress_dpc_s(dpc_rv, vaddr_width_p, paddr_width_p);
    dscratch0_rv = value.dscratch0;
    result.dscratch0 = `compress_dscratch0_s(dscratch0_rv, vaddr_width_p, paddr_width_p);
    dscratch1_rv = value.dscratch1;
    result.dscratch1 = `compress_dscratch1_s(dscratch1_rv, vaddr_width_p, paddr_width_p);
    mstatus_rv = value.mstatus;
    result.mstatus = `compress_mstatus_s(mstatus_rv, vaddr_width_p, paddr_width_p);
    medeleg_rv = value.medeleg;
    result.medeleg = `compress_medeleg_s(medeleg_rv, vaddr_width_p, paddr_width_p);
    mideleg_rv = value.mideleg;
    result.mideleg = `compress_mideleg_s(mideleg_rv, vaddr_width_p, paddr_width_p);
    mie_rv = value.mie;
    result.mie = `compress_mie_s(mie_rv, vaddr_width_p, paddr_width_p);
    mtvec_rv = value.mtvec;
    result.mtvec = `compress_mtvec_s(mtvec_rv, vaddr_width_p, paddr_width_p);
    mcounteren_rv = value.mcounteren;
    result.mcounteren = `compress_mcounteren_s(mcounteren_rv, vaddr_width_p, paddr_width_p);
    mscratch_rv = value.mscratch;
    result.mscratch = `compress_mscratch_s(mscratch_rv, vaddr_width_p, paddr_width_p);
    mepc_rv = value.mepc;
    result.mepc = `compress_mepc_s(mepc_rv, vaddr_width_p, paddr_width_p);
    mcause_rv = value.mcause;
    result.mcause = `compress_mcause_s(mcause_rv, vaddr_width_p, paddr_width_p);
    mtval_rv = value.mtval;
    result.mtval = `compress_mtval_s(mtval_rv, vaddr_width_p, paddr_width_p);
    mip_rv = value.mip;
    result.mip = `compress_mip_s(mip_rv, vaddr_width_p, paddr_width_p);
    mcycle_rv = value.mcycle;
    result.mcycle = `compress_mcycle_s(mcycle_rv, vaddr_width_p, paddr_width_p);
    minstret_rv = value.minstret;
    result.minstret = `compress_minstret_s(minstret_rv, vaddr_width_p, paddr_width_p);
    mcountinhibit_rv = value.mcountinhibit;
    result.mcountinhibit = `compress_mcountinhibit_s(mcountinhibit_rv, vaddr_width_p, paddr_width_p);
    stvec_rv = value.stvec;
    result.stvec = `compress_stvec_s(stvec_rv, vaddr_width_p, paddr_width_p);
    scounteren_rv = value.scounteren;
    result.scounteren = `compress_scounteren_s(scounteren_rv, vaddr_width_p, paddr_width_p);
    sscratch_rv = value.sscratch;
    result.sscratch = `compress_sscratch_s(sscratch_rv, vaddr_width_p, paddr_width_p);
    sepc_rv = value.sepc;
    result.sepc = `compress_sepc_s(sepc_rv, vaddr_width_p, paddr_width_p);
    scause_rv = value.scause;
    result.scause = `compress_scause_s(scause_rv, vaddr_width_p, paddr_width_p);
    stval_rv = value.stval;
    result.stval = `compress_stval_s(stval_rv, vaddr_width_p, paddr_width_p);
    satp_rv = value.satp;
    result.satp = `compress_satp_s(satp_rv, vaddr_width_p, paddr_width_p);
    fcsr_rv = value.fcsr;
    result.fcsr = `compress_fcsr_s(fcsr_rv, vaddr_width_p, paddr_width_p);
    result.priv_mode = value.priv_mode;
    return result;
  endfunction

  function automatic expanded_context_s decode(input encoded_context_s value);
    expanded_context_s result;
    rv64_dcsr_s dcsr_rv;
    rv64_dpc_s dpc_rv;
    rv64_dscratch0_s dscratch0_rv;
    rv64_dscratch1_s dscratch1_rv;
    rv64_mstatus_s mstatus_rv;
    rv64_medeleg_s medeleg_rv;
    rv64_mideleg_s mideleg_rv;
    rv64_mie_s mie_rv;
    rv64_mtvec_s mtvec_rv;
    rv64_mcounteren_s mcounteren_rv;
    rv64_mscratch_s mscratch_rv;
    rv64_mepc_s mepc_rv;
    rv64_mcause_s mcause_rv;
    rv64_mtval_s mtval_rv;
    rv64_mip_s mip_rv;
    rv64_mcycle_s mcycle_rv;
    rv64_minstret_s minstret_rv;
    rv64_mcountinhibit_s mcountinhibit_rv;
    rv64_stvec_s stvec_rv;
    rv64_scounteren_s scounteren_rv;
    rv64_sscratch_s sscratch_rv;
    rv64_sepc_s sepc_rv;
    rv64_scause_s scause_rv;
    rv64_stval_s stval_rv;
    rv64_satp_s satp_rv;
    rv64_fcsr_s fcsr_rv;
    dcsr_rv = `decompress_dcsr_s(value.dcsr);
    result.dcsr = dword_width_gp'(dcsr_rv);
    dpc_rv = `decompress_dpc_s(value.dpc);
    result.dpc = dword_width_gp'(dpc_rv);
    dscratch0_rv = `decompress_dscratch0_s(value.dscratch0);
    result.dscratch0 = dword_width_gp'(dscratch0_rv);
    dscratch1_rv = `decompress_dscratch1_s(value.dscratch1);
    result.dscratch1 = dword_width_gp'(dscratch1_rv);
    mstatus_rv = `decompress_mstatus_s(value.mstatus);
    result.mstatus = dword_width_gp'(mstatus_rv);
    medeleg_rv = `decompress_medeleg_s(value.medeleg);
    result.medeleg = dword_width_gp'(medeleg_rv);
    mideleg_rv = `decompress_mideleg_s(value.mideleg);
    result.mideleg = dword_width_gp'(mideleg_rv);
    mie_rv = `decompress_mie_s(value.mie);
    result.mie = dword_width_gp'(mie_rv);
    mtvec_rv = `decompress_mtvec_s(value.mtvec);
    result.mtvec = dword_width_gp'(mtvec_rv);
    mcounteren_rv = `decompress_mcounteren_s(value.mcounteren);
    result.mcounteren = dword_width_gp'(mcounteren_rv);
    mscratch_rv = `decompress_mscratch_s(value.mscratch);
    result.mscratch = dword_width_gp'(mscratch_rv);
    mepc_rv = `decompress_mepc_s(value.mepc);
    result.mepc = dword_width_gp'(mepc_rv);
    mcause_rv = `decompress_mcause_s(value.mcause);
    result.mcause = dword_width_gp'(mcause_rv);
    mtval_rv = `decompress_mtval_s(value.mtval);
    result.mtval = dword_width_gp'(mtval_rv);
    mip_rv = `decompress_mip_s(value.mip);
    result.mip = dword_width_gp'(mip_rv);
    mcycle_rv = `decompress_mcycle_s(value.mcycle);
    result.mcycle = dword_width_gp'(mcycle_rv);
    minstret_rv = `decompress_minstret_s(value.minstret);
    result.minstret = dword_width_gp'(minstret_rv);
    mcountinhibit_rv = `decompress_mcountinhibit_s(value.mcountinhibit);
    result.mcountinhibit = dword_width_gp'(mcountinhibit_rv);
    stvec_rv = `decompress_stvec_s(value.stvec);
    result.stvec = dword_width_gp'(stvec_rv);
    scounteren_rv = `decompress_scounteren_s(value.scounteren);
    result.scounteren = dword_width_gp'(scounteren_rv);
    sscratch_rv = `decompress_sscratch_s(value.sscratch);
    result.sscratch = dword_width_gp'(sscratch_rv);
    sepc_rv = `decompress_sepc_s(value.sepc);
    result.sepc = dword_width_gp'(sepc_rv);
    scause_rv = `decompress_scause_s(value.scause);
    result.scause = dword_width_gp'(scause_rv);
    stval_rv = `decompress_stval_s(value.stval);
    result.stval = dword_width_gp'(stval_rv);
    satp_rv = `decompress_satp_s(value.satp);
    result.satp = dword_width_gp'(satp_rv);
    fcsr_rv = `decompress_fcsr_s(value.fcsr);
    result.fcsr = dword_width_gp'(fcsr_rv);
    result.priv_mode = value.priv_mode;
    return result;
  endfunction

  encoded_context_s encoded_write, encoded_read;
  expanded_context_s reconstructed_write;
  assign encoded_write = encode(expanded_context_s'(write_data_i));
  assign reconstructed_write = decode(encoded_write);
  bp_be_csr_snapshot_store_production
   #(.contexts_p(contexts_p), .width_p(encoded_width_lp), .addr_width_p(addr_width_p))
   encoded_store
    (.clk_i(clk_i), .reset_i(reset_i), .write_v_i(write_v_i)
     ,.write_addr_i(write_addr_i), .read_addr_i(read_addr_i)
     ,.write_data_i(encoded_write), .valid_o(valid_o)
     ,.read_valid_o(read_valid_o), .read_data_o(encoded_read));
  // Retain the old out-of-range zero. In-range invalid data remains
  // unqualified, with no valid-bit zero mask added to the payload path.
  always_comb begin
    read_data_o = '0;
    if (int'(read_addr_i)<contexts_p) read_data_o = decode(encoded_read);
  end

  // synthesis translate_off
  initial begin
    assert (width_p == $bits(expanded_context_s))
      else $fatal(1,"CSR_CANONICAL_BAD_EXPANDED_WIDTH");
    assert (encoded_width_lp < width_p)
      else $fatal(1,"CSR_CANONICAL_NO_ENCODING");
    $display("CSR_CANONICAL_WIDTH expanded=%0d encoded=%0d contexts=%0d",width_p,encoded_width_lp,contexts_p);
  end
  // This full-width independent snapshot is verification-only. Compare at
  // the consumer edge before any concurrent write NBA, matching old RAM.
  logic [width_p-1:0] accepted_raw_r [0:contexts_p-1];
  always_ff @(posedge clk_i) begin
    if (!reset_i && write_v_i && int'(write_addr_i)<contexts_p) begin
      assert (reconstructed_write === write_data_i)
        else $fatal(1,"CSR_CANONICAL_NONCANONICAL_WRITE");
      accepted_raw_r[write_addr_i] <= write_data_i;
    end
    if (!reset_i && read_valid_o) begin
      assert (read_data_o === accepted_raw_r[read_addr_i])
        else $fatal(1,"CSR_CANONICAL_RECONSTRUCTION_MISMATCH");
    end
  end
  // synthesis translate_on
endmodule
