`timescale 1ns/1ps
`include "defines.v"
// tb_cpu.sv — General CPU test: arithmetic, branches, load/store, stack, subroutine
//
// Boot flow  (matches tb_memcpy):
//   1. rst_n=0, prst_n=1  — CPU held in reset, APB active
//   2. Write instructions via APB transactions
//   3. rst_n=1            — CPU starts from PC=0
//
// Program (word 32..59, byte 0x080..0x0EC):
//   MOVI R0,#10  MOVI R1,#3
//   ADD/SUB/MUL/AND/OR/XOR/NOT/LSL/LSR
//   CMP R2,R3 → BGT skips FAIL → MOVI R5,#0xBEF
//   STR R5,[R0]  LDR R6,[R0]  CMP R5,R6 (Z=1)
//   BNE +2 (not taken) → INC R2  DEC R2
//   PUSH R5  POP R15
//   BL sub_add2 → sub_add2: INC INC BX R14 → returns
//   B AL #0 (program end)

module tb_cpu;

    // ---- DUT signals ----
    logic        clk, pclk, rst_n, prst_n, irq, fiq;
    logic [31:0] paddr, pwdata, prdata;
    logic        psel, penable, pwrite, pready, pslverr;

    cpu_top dut (
        .clk     (clk),
        .pclk    (pclk),
        .rst_n   (rst_n),
        .prst_n  (prst_n),
        .irq     (irq),
        .fiq     (fiq),
        .paddr   (paddr),
        .psel    (psel),
        .penable (penable),
        .pwrite  (pwrite),
        .pwdata  (pwdata),
        .prdata  (prdata),
        .pready  (pready),
        .pslverr (pslverr)
    );

    initial clk  = 0; always #5  clk  = ~clk;
    initial pclk = 0; always #8  pclk = ~pclk;

    // ---- APB master task ----
    task automatic apb_write(input logic [31:0] addr, data);
        @(negedge pclk);
        paddr = addr; pwdata = data; pwrite = 1'b1; psel = 1'b1; penable = 1'b0;
        @(negedge pclk);
        penable = 1'b1;
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        @(negedge pclk);
        psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    endtask

    // ---- Encoding helpers ----
    function automatic logic [31:0] enc_r(input logic [4:0] funct, input logic [3:0] rd, rs1, rs2);
        return {`FMT_R, funct, rd, rs1, rs2, 12'd0};
    endfunction

    function automatic logic [31:0] enc_i(input logic [4:0] funct, input logic [3:0] rd, rs1, input logic [15:0] imm);
        return {`FMT_I, funct, rd, rs1, imm};
    endfunction

    function automatic logic [31:0] enc_load(input logic [3:0] rd, rb, input logic [15:0] off);
        return {`FMT_LOAD, `FL_LDR, rd, rb, off};
    endfunction

    function automatic logic [31:0] enc_store(input logic [3:0] rs, rb, input logic [15:0] off);
        return {`FMT_STORE, `FS_STR, rs, rb, off};
    endfunction

    function automatic logic [31:0] enc_b(input logic [3:0] cond, input logic [24:0] imm25);
        return {`FMT_BRANCH, cond, imm25};
    endfunction

    function automatic logic [31:0] enc_u(input logic [4:0] funct, input logic [3:0] rd);
        return {`FMT_UNARY, funct, rd, 20'd0};
    endfunction

    function automatic logic [31:0] enc_bl(input logic [19:0] imm20);
        return {`FMT_JUMP, `FJ_BL, 4'd0, imm20};
    endfunction

    function automatic logic [31:0] enc_bx(input logic [3:0] rd);
        return {`FMT_JUMP, `FJ_BX, rd, 20'd0};
    endfunction

    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction

    // ---- Program loader via APB ----
    // Word → byte address: addr = word_index * 4
    //   Word  0 = 0x000  (vector: B AL +32)
    //   Word  6 = 0x018  (IRQ handler: RETI)
    //   Word  7 = 0x01C  (FIQ handler: RETI)
    //   Word 32 = 0x080  (main)
    //   ...
    //   Word 59 = 0x0EC  (sub_add2: BX R14)

    task automatic load_program();
        int addr;
        $display("[APB] Loading program...");

        // Vector table
        apb_write(32'h000, enc_b(`COND_AL, 25'd32));  // B AL → word 32
        apb_write(32'h018, enc_ctrl(`FC_RETI));         // IRQ handler
        apb_write(32'h01C, enc_ctrl(`FC_RETI));         // FIQ handler

        // Main (word 32 = 0x080)
        addr = 32'h080;
        // Arithmetic
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd10));    addr += 4; // MOVI R0, #10
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd3));     addr += 4; // MOVI R1, #3
        apb_write(addr, enc_r(`FR_ADD,  4'd2, 4'd0, 4'd1));      addr += 4; // ADD  R2, R0, R1 → 13
        apb_write(addr, enc_r(`FR_SUB,  4'd3, 4'd0, 4'd1));      addr += 4; // SUB  R3, R0, R1 → 7
        apb_write(addr, enc_r(`FR_MUL,  4'd4, 4'd0, 4'd1));      addr += 4; // MUL  R4, R0, R1 → 30
        // Bitwise
        apb_write(addr, enc_r(`FR_AND,  4'd7,  4'd2, 4'd1));     addr += 4; // AND  R7,  R2, R1 → 1
        apb_write(addr, enc_r(`FR_OR,   4'd8,  4'd2, 4'd1));     addr += 4; // OR   R8,  R2, R1 → 15
        apb_write(addr, enc_r(`FR_XOR,  4'd9,  4'd2, 4'd1));     addr += 4; // XOR  R9,  R2, R1 → 14
        apb_write(addr, enc_r(`FR_NOT,  4'd10, 4'd2, 4'd0));     addr += 4; // NOT  R10, R2     → ~13
        apb_write(addr, enc_r(`FR_LSL,  4'd11, 4'd1, 4'd1));     addr += 4; // LSL  R11, R1, R1 → 24
        apb_write(addr, enc_r(`FR_LSR,  4'd12, 4'd4, 4'd1));     addr += 4; // LSR  R12, R4, R1 → 3
        // Branch test: 13 > 7 so BGT skips FAIL
        apb_write(addr, enc_r(`FR_CMP,  4'd0,  4'd2, 4'd3));     addr += 4; // CMP  R2, R3
        apb_write(addr, enc_b(`COND_GT, 25'd2));                  addr += 4; // BGT  +2 → skip FAIL
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd0));     addr += 4; // MOVI R5, #0     (FAIL)
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'h0BEF));  addr += 4; // MOVI R5, #0xBEF (PASS)
        // Load/store round-trip
        apb_write(addr, enc_store(4'd5, 4'd0, 16'd0));            addr += 4; // STR  R5, [R0]
        apb_write(addr, enc_load (4'd6, 4'd0, 16'd0));            addr += 4; // LDR  R6, [R0]
        apb_write(addr, enc_r(`FR_CMP,  4'd0,  4'd5, 4'd6));     addr += 4; // CMP  R5, R6 → Z=1
        // BNE not taken (Z=1)
        apb_write(addr, enc_b(`COND_NE, 25'd2));                  addr += 4; // BNE  +2  (not taken)
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 14
        apb_write(addr, enc_u(`FU_DEC,  4'd2));                   addr += 4; // DEC  R2 → 13
        // Stack
        apb_write(addr, enc_u(`FU_PUSH, 4'd5));                   addr += 4; // PUSH R5
        apb_write(addr, enc_u(`FU_POP,  4'd15));                  addr += 4; // POP  R15
        // Subroutine: BL sub_add2 (+2 words)
        apb_write(addr, enc_bl(20'd2));                            addr += 4; // BL   sub_add2
        apb_write(addr, enc_b(`COND_AL, 25'd0));                  addr += 4; // B AL #0 (end)
        // sub_add2
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 14
        apb_write(addr, enc_u(`FU_INC,  4'd2));                   addr += 4; // INC  R2 → 15
        apb_write(addr, enc_bx(4'd14));                                       // BX   R14 → return

        $display("[APB] Program load complete");
    endtask

    // ---- Simulation driver ----
    int          cycle_count;
    logic [31:0] prev_pc;

    initial begin
        irq = 0; fiq = 0;
        rst_n = 0; prst_n = 1;
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
        cycle_count = 0;
        prev_pc = 32'hFFFF_FFFF;

        repeat(2) @(posedge pclk); #1;

        load_program();

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(500) @(posedge clk);
                $display("TIMEOUT: simulation ran 500 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== SIMULATION COMPLETE ===");
                        $display("PC stopped at : 0x%08h", dut.pc);
                        $display("Cycles        : %0d", cycle_count);
                        $display("R0  = %0d (expected 10)",   dut.u_rf.r0);
                        $display("R1  = %0d (expected 3)",    dut.u_rf.r1);
                        $display("R2  = %0d (expected 15)",   dut.u_rf.r2);
                        $display("R3  = %0d (expected 7)",    dut.u_rf.r3);
                        $display("R4  = %0d (expected 30)",   dut.u_rf.r4);
                        $display("R5  = %0d (expected 3055)", dut.u_rf.r5);
                        $display("R6  = %0d (expected 3055)", dut.u_rf.r6);
                        $display("R7  = %0d (expected 1)",    dut.u_rf.r7);
                        $display("R8  = %0d (expected 15)",   dut.u_rf.r8);
                        $display("R9  = %0d (expected 14)",   dut.u_rf.r9);
                        $display("R11 = %0d (expected 24)",   dut.u_rf.r11);
                        $display("R12 = %0d (expected 3)",    dut.u_rf.r12);
                        $display("SP  = 0x%08h (expected 0x%08h)", dut.sp, `SP_INIT);
                        $display("SR  = 0b%06b", dut.sr);
                        if (dut.u_rf.r2 == 32'd15 &&
                            dut.u_rf.r5 == dut.u_rf.r6 &&
                            dut.sp == `SP_INIT)
                            $display("*** ALL CHECKS PASSED ***");
                        else
                            $display("!!! SOME CHECKS FAILED !!!");
                        $finish;
                    end
                    prev_pc = dut.pc;
                end
            end
        join
    end

    always_ff @(posedge clk)
        if (rst_n) cycle_count++;

    // IRQ pulse at cycle 100 in SYS mode
    initial begin
        repeat(100) @(posedge clk);
        if (dut.cpu_mode == `MODE_SYS) begin
            irq = 1;
            @(posedge clk);
            irq = 0;
            $display("[tb] IRQ pulsed at cycle ~100");
        end
    end

    initial begin
        $dumpfile("tb_cpu.vcd");
        $dumpvars(0, tb_cpu);
    end

endmodule
