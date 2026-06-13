`timescale 1ns/1ps
`include "defines.v"
// cpu_top.v — Single-cycle CPU
//
// Non-branch: [31:29]=fmt [28:24]=funct [23:20]=Rd [19:16]=Rs1
//             [15:12]=Rs2 / [15:0]=imm16
// Branch:     [31:29]=100 [28:25]=COND  [24:0]=imm25
module cpu_top (
    input  clk,
    input  pclk,
    input  rst_n,    // CPU reset  — freezes datapath, clears all CPU state
    input  prst_n,   // APB reset  — blocks APB transactions only, no memory clear
    input  irq,
    input  fiq,
    input  [31:0] paddr,
    input         psel,
    input         penable,
    input         pwrite,
    input  [31:0] pwdata,
    output [31:0] prdata,
    output        pready,
    output        pslverr
);

    // ----------------------------------------------------------------
    // Architectural state
    // ----------------------------------------------------------------
    reg [31:0] pc;
    reg [31:0] sp;
    reg [5:0]  sr;          // [5:F][4:I][3:V][2:C][1:N][0:Z]
    reg [1:0]  cpu_mode;
    reg [31:0] lr_irq,  lr_fiq;
    reg [5:0]  spsr_irq, spsr_fiq;
    // ----------------------------------------------------------------
    // IF — Instruction Fetch
    // ----------------------------------------------------------------
    wire [31:0] inst;
    wire [31:0] pc_plus4 = pc + 32'd4;

    inst_mem u_imem (
        .pclk     (pclk),
        .prst_n   (prst_n),
        .cpu_addr (pc),
        .cpu_inst (inst),
        .paddr    (paddr),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .pwdata   (pwdata),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr)
    );

    // ----------------------------------------------------------------
    // ID — Instruction Decode
    // All formats
    // ----------------------------------------------------------------
    wire [2:0]  fmt      = inst[`FMT_MSB:`FMT_LSB];       // [31:29] format
    wire [4:0]  funct    = inst[`FT_MSB:`FT_LSB];          // [28:24] function
    wire [3:0]  rd_addr  = inst[`RD_MSB:`RD_LSB];          // [23:20]
    wire [3:0]  rs1_addr = inst[`RS1_MSB:`RS1_LSB];        // [19:16]
    wire [3:0]  rs2_addr = inst[`RS2_MSB:`RS2_LSB];        // [15:12]
    wire [15:0] imm16    = inst[`IMM16_MSB:`IMM16_LSB];    // [15:0]

    // Branch format fields — only valid when fmt==FMT_BRANCH
    wire [3:0]  br_cond  = inst[`BR_COND_MSB:`BR_COND_LSB];   // [28:25]
    wire [24:0] br_imm25 = inst[`BR_IMM25_MSB:`BR_IMM25_LSB]; // [24:0]

    // BL format field — only valid when fmt==FMT_JUMP, funct==FJ_BL
    wire [19:0] bl_imm20 = inst[`BL_IMM20_MSB:`BL_IMM20_LSB]; // [19:0]

    // ---- Control unit ----
    wire        use_imm, use_rd_src, reg_write, mem_read, mem_write;
    wire [1:0]  wb_sel;
    wire        branch, bl_op, bx_op, push_op, pop_op;
    wire        reti_op, cmp_tst_op;
    wire [3:0]  alu_op;

    control u_ctrl (
        .fmt       (fmt),
        .funct     (funct),
        .use_imm   (use_imm),
        .use_rd_src(use_rd_src),
        .reg_write (reg_write),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .wb_sel    (wb_sel),
        .branch    (branch),
        .bl_op     (bl_op),
        .bx_op     (bx_op),
        .push_op   (push_op),
        .pop_op    (pop_op),
        .reti_op   (reti_op),
        .cmp_tst_op(cmp_tst_op),
        .alu_op    (alu_op)
    );

    // ---- Condition check — only for FMT_BRANCH ----
    wire cond_pass;
    cond_check u_cond (
        .cond (br_cond),
        .Z    (sr[`SR_Z]),
        .N    (sr[`SR_N]),
        .C    (sr[`SR_C]),
        .V    (sr[`SR_V]),
        .pass (cond_pass)
    );

    // ---- Immediate sign extension ----
    wire [31:0] imm32 = {{16{imm16[15]}}, imm16};   // sign-extend 16 → 32

    // ---- Register file ----
    // Port A: Rs1 normally; Rd for unary/BX (use_rd_src)
    // Port B: Rs2 normally; Rd field for FMT_STORE (store data register)
    wire [3:0]  rfa_addr = use_rd_src ? rd_addr : rs1_addr;
    wire [31:0] rfa_data, rfb_data;
    wire        rf_we;
    wire [3:0]  rf_wr_addr;
    wire [31:0] rf_wr_data;

    reg_file u_rf (
        .clk       (clk),
        .rst_n     (rst_n),
        .wr_addr   (rf_wr_addr),
        .wr_data   (rf_wr_data),
        .wr_en     (rf_we),
        .rd_addr_a (rfa_addr),
        .rd_data_a (rfa_data),
        .rd_addr_b ((fmt == `FMT_STORE) ? rd_addr : rs2_addr),
        .rd_data_b (rfb_data)
    );

    // ----------------------------------------------------------------
    // EX — Execute
    // ----------------------------------------------------------------
    wire [31:0] alu_a = rfa_data;
    wire [31:0] alu_b = use_imm ? imm32 : rfb_data;

    wire [31:0] alu_result;
    wire        alu_Z_out, alu_N_out, alu_C_out, alu_V_out, alu_flags_we;

    alu u_alu (
        .alu_op   (alu_op),
        .a        (alu_a),
        .b        (alu_b),
        .result   (alu_result),
        .alu_Z    (alu_Z_out),
        .alu_N    (alu_N_out),
        .alu_C    (alu_C_out),
        .alu_V    (alu_V_out),
        .flags_we (alu_flags_we)
    );

    // Branch targets
    // Branch: pc + sign_extend(imm25)*4 = pc + {{5{imm25[24]}}, imm25, 2'b00}
    wire [31:0] branch_target = pc + {{5{br_imm25[24]}}, br_imm25, 2'b00};
    // BL: pc + sign_extend(imm20)*4
    wire [31:0] bl_target     = pc + {{10{bl_imm20[19]}}, bl_imm20, 2'b00};

    // Interrupts
    wire fiq_taken = fiq & sr[`SR_F] & (cpu_mode == `MODE_SYS);
    wire irq_taken = irq & sr[`SR_I] & (cpu_mode == `MODE_SYS);
    wire [31:0] reti_pc = (cpu_mode == `MODE_FIQ) ? lr_fiq : lr_irq;

    // Next PC — cond_pass ONLY gates FMT_BRANCH
    // All other instructions execute unconditionally (A64 style)
    wire [31:0] next_pc =
        fiq_taken              ? `FIQ_VEC      :
        irq_taken              ? `IRQ_VEC      :
        reti_op                ? reti_pc       :
        bx_op                  ? rfa_data      :
        bl_op                  ? bl_target     :
        (branch & cond_pass)   ? branch_target :
        pc_plus4;

    // ----------------------------------------------------------------
    // MEM — Memory Access
    // ----------------------------------------------------------------
    wire [31:0] mem_addr   = push_op ? (sp - 32'd4) :
                             pop_op  ? sp            :
                             alu_result;

    // FMT_STORE: rfb_data = value of Rs (rd field via port B mux above)
    // PUSH:      rfa_data = value of Rd (via use_rd_src)
    wire        dmem_we    = mem_write;
    wire [31:0] dmem_wdata = (fmt == `FMT_STORE) ? rfb_data : rfa_data;
    wire [31:0] mem_rdata;

    data_mem u_dmem (
        .clk   (clk),
        .addr  (mem_addr),
        .wdata (dmem_wdata),
        .we    (dmem_we),
        .rdata (mem_rdata)
    );

    // ----------------------------------------------------------------
    // WB — Write Back
    // ----------------------------------------------------------------
    wire [3:0]  wb_rd_addr = bl_op ? 4'd14 : rd_addr;

    wire [31:0] wb_data = (wb_sel == `WB_MEM) ? mem_rdata :
                          (wb_sel == `WB_PC4) ? pc_plus4  :
                          alu_result;

    wire do_reg_write = reg_write & ~cmp_tst_op;
    assign rf_we      = do_reg_write;
    assign rf_wr_addr = wb_rd_addr;
    assign rf_wr_data = wb_data;

    wire [31:0] sp_next  = push_op ? (sp - 32'd4) : (sp + 32'd4);
    wire        sp_we    = (push_op | pop_op);

    // Flags update: any instruction that sets flags_we, except FMT_BRANCH
    wire update_flags = alu_flags_we & (fmt != `FMT_BRANCH);

    // ----------------------------------------------------------------
    // Sequential state — advances on every clock when out of reset
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc        <= 32'd0;
            sp        <= `SP_INIT;
            sr        <= 6'b11_0000;
            cpu_mode  <= `MODE_SYS;
            lr_irq    <= 32'd0;
            lr_fiq    <= 32'd0;
            spsr_irq  <= 6'd0;
            spsr_fiq  <= 6'd0;
        end else begin
            pc <= next_pc;

            if (sp_we)        sp        <= sp_next;
            if (update_flags) sr[3:0]   <= {alu_V_out, alu_C_out,
                                             alu_N_out, alu_Z_out};

            if (fiq_taken) begin
                lr_fiq    <= pc_plus4; spsr_fiq  <= sr;
                sr[`SR_F] <= 1'b0;    sr[`SR_I] <= 1'b0;
                cpu_mode  <= `MODE_FIQ;
            end else if (irq_taken) begin
                lr_irq    <= pc_plus4; spsr_irq  <= sr;
                sr[`SR_I] <= 1'b0;    cpu_mode  <= `MODE_IRQ;
            end

            if (reti_op) begin
                case (cpu_mode)
                    `MODE_FIQ: begin sr <= spsr_fiq; cpu_mode <= `MODE_SYS; end
                    `MODE_IRQ: begin sr <= spsr_irq; cpu_mode <= `MODE_SYS; end
                    default: ;
                endcase
            end
        end
    end

endmodule
