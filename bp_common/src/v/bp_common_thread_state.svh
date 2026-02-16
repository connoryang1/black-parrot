`ifndef BP_COMMON_THREAD_STATE_SVH
`define BP_COMMON_THREAD_STATE_SVH

///////////////////////////////////////////////////////////////////////////////
// Thread Context Structure
//
// Each hardware thread needs to preserve its state when switching execution.
// This structure defines the minimum state that must be saved per thread.
//
// Total size: 544 bits = 68 bytes per thread
//
// Storage strategy options:
//   - Distributed flip-flops (15KB for 224 threads, zero latency)
//   - SRAM banks (smaller, 2+ cycle latency)
//   - Hybrid (hot FF + cold SRAM)
///////////////////////////////////////////////////////////////////////////////

typedef struct packed {
    ///////////////////////////////////////////////////////////////////
    // PROGRAM COUNTER & PREDICTION STATE (128 bits)
    ///////////////////////////////////////////////////////////////////
    logic [63:0] pc;                        // Program counter (instruction fetch address)
    logic [63:0] npc;                       // Next PC (prediction for next instruction)

    ///////////////////////////////////////////////////////////////////
    // BRANCH PREDICTION STATE (20 bits)
    ///////////////////////////////////////////////////////////////////
    logic [15:0] global_history;            // Global branch history (for Gselect BHT hash)
    logic [3:0]  ras_ptr;                   // Return Address Stack pointer (0-15 depth)

    ///////////////////////////////////////////////////////////////////
    // PRIVILEGE & EXCEPTION STATE (8 bits)
    ///////////////////////////////////////////////////////////////////
    logic [1:0]  priv_mode;                 // Privilege mode: User(0), Supervisor(1), Machine(3)
    logic [2:0]  _reserved_priv;            // Reserved for future use

    ///////////////////////////////////////////////////////////////////
    // MACHINE STATE REGISTERS (64 bits each = 192 bits)
    ///////////////////////////////////////////////////////////////////
    logic [63:0] mstatus;                   // Machine status (interrupt enable, privilege, etc)
    logic [63:0] mtvec;                     // Machine trap vector (exception handler address)
    logic [63:0] mepc;                      // Machine exception PC (where exception occurred)

    ///////////////////////////////////////////////////////////////////
    // VIRTUAL MEMORY STATE (96 bits)
    ///////////////////////////////////////////////////////////////////
    logic [63:0] satp;                      // Supervisor address translation & protection (paging config)
    logic [31:0] asid;                      // Address Space ID (for TLB, thread-local)

    ///////////////////////////////////////////////////////////////////
    // THREAD DESCRIPTOR (64 bits)
    ///////////////////////////////////////////////////////////////////
    logic [15:0] vtid;                      // Virtual thread ID (OS-facing, may map to different ptid)
    logic [15:0] ptid;                      // Physical thread ID (hardware-facing, maps to register file)
    logic [15:0] permissions;               // Access control bits (who can start/stop this thread)
    logic [7:0]  priority;                  // Thread priority (for scheduler, 0=low, 255=high)
    logic        thread_valid;              // Is this thread valid (allocated)?
    logic        thread_runnable;           // Can this thread be scheduled?
    logic        thread_blocked;            // Is this thread blocked (e.g., on mwait)?
    logic        _reserved_desc;            // Reserved

    ///////////////////////////////////////////////////////////////////
    // THREAD-LOCAL STORAGE (64 bits)
    ///////////////////////////////////////////////////////////////////
    logic [63:0] tls_base;                  // Base address of thread-local storage area

} bp_thread_ctx_s;

///////////////////////////////////////////////////////////////////////////////
// Parameter calculations
///////////////////////////////////////////////////////////////////////////////

localparam int BP_THREAD_CTX_WIDTH_GP = $bits(bp_thread_ctx_s);  // Width in bits
localparam int BP_THREAD_CTX_BYTES_GP = (BP_THREAD_CTX_WIDTH_GP + 7) / 8;  // Width in bytes

///////////////////////////////////////////////////////////////////////////////
// CSR addresses for thread management (custom RV64 extensions)
// Using 0xC00-0xCFF range (machine-mode custom CSRs)
///////////////////////////////////////////////////////////////////////////////

typedef enum logic [11:0] {
    // Thread Identity
    CSR_PTID              = 12'hC00,  // Physical Thread ID (read-only)
    CSR_VTID              = 12'hC01,  // Virtual Thread ID (read-write)

    // Thread Status
    CSR_THREAD_STAT       = 12'hC02,  // Thread status flags (runnable, blocked, etc)
    CSR_THREAD_PRIORITY   = 12'hC03,  // Thread priority for scheduling

    // Exception Handling
    CSR_EXCEPTION_PTR     = 12'hC04,  // Exception descriptor pointer (memory address)

    // Thread Descriptor Table
    CSR_TDT_PTR           = 12'hC05,  // Thread Descriptor Table base address

    // Monitor/mwait
    CSR_MONITOR_ADDR      = 12'hC06,  // Address to monitor for modifications

    // Thread Information
    CSR_THREAD_LOCAL      = 12'hC07,  // Thread-local storage base address
    CSR_NUM_THREADS       = 12'hC08,  // Number of available threads (read-only)
    CSR_MAX_THREADS       = 12'hC09,  // Maximum threads per core (read-only)

    // Performance counters (thread-specific)
    CSR_THREAD_CYCLES     = 12'hC0A,  // Cycles executed by this thread
    CSR_THREAD_INSTR      = 12'hC0B   // Instructions executed by this thread

} bp_thread_csr_addr_e;

`endif
