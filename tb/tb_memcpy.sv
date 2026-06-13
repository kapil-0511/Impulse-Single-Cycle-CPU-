`timescale 1ns/1ps
`include "defines.v"
// tb_memcpy.sv — memcpy test with APB program loader
//
// Boot flow:
//   1. rst_n=0, prst_n=1  — CPU in reset, APB active
//   2. Write instructions via APB
//   3. rst_n=1            — CPU starts from PC=0
//
// Program (word 32..45, byte 0x080..0x0B4):
//   MOVI R0,#256  MOVI R1,#512  MOVI R2,#10
//   loop: LDR R3,[R0] STR R3,[R1] ADDI R0,+4 ADDI R1,+4 DEC R2 BNE loop
//
// Source: DMEM word 64..73 (0x100..0x124) = {10,20..100}
// Dest  : DMEM word 128..137 (0x200..0x224)

module tb_memcpy;

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

    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction

    // ---- Program loader via APB ----
    // Branch offsets:
    //   B AL  word 0  → word 32 : imm25 = 32
    //   BNE   word 40 → word 35 : imm25 = 35-40 = -5 → 25'h1FFFFFB

    task automatic load_program();
        $display("[APB] Loading program...");

        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        apb_write(32'h080, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd256)); // MOVI R0, #256
        apb_write(32'h084, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd512)); // MOVI R1, #512
        apb_write(32'h088, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd10 )); // MOVI R2, #10
        // copy_loop (word 35)
        apb_write(32'h08C, enc_load (4'd3, 4'd0, 16'd0));          // LDR  R3, [R0]
        apb_write(32'h090, enc_store(4'd3, 4'd1, 16'd0));          // STR  R3, [R1]
        apb_write(32'h094, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd4));   // ADDI R0, R0, #4
        apb_write(32'h098, enc_i(`FI_ADDI, 4'd1, 4'd1, 16'd4));   // ADDI R1, R1, #4
        apb_write(32'h09C, enc_u(`FU_DEC,  4'd2));                 // DEC  R2
        apb_write(32'h0A0, enc_b(`COND_NE, 25'h1FFFFFB));          // BNE  -5 → word 35
        apb_write(32'h0A4, enc_b(`COND_AL, 25'd0));                // B AL #0 (end)

        $display("[APB] Program load complete");
    endtask

    task automatic load_source_data();
        for (int i = 0; i < 10; i++)
            dut.u_dmem.mem[64 + i] = (i + 1) * 10;
        $display("[TB]  Source data loaded: mem[0x100..0x124] = 10..100");
    endtask

    task automatic verify_copy();
        int pass = 0, fail = 0;
        logic [31:0] src_val, dst_val;
        $display("------------------------------------------------------");
        $display(" idx | src addr | dst addr | src val | dst val | result");
        $display("------------------------------------------------------");
        for (int i = 0; i < 10; i++) begin
            src_val = dut.u_dmem.mem[64  + i];
            dst_val = dut.u_dmem.mem[128 + i];
            if (src_val === dst_val) begin
                $display("  [%0d]  0x%03h      0x%03h      %4d      %4d     PASS",
                         i, (64+i)*4, (128+i)*4, src_val, dst_val);
                pass++;
            end else begin
                $display("  [%0d]  0x%03h      0x%03h      %4d      %4d     FAIL ***",
                         i, (64+i)*4, (128+i)*4, src_val, dst_val);
                fail++;
            end
        end
        $display("------------------------------------------------------");
        if (fail == 0)
            $display("*** ALL 10 ELEMENTS COPIED CORRECTLY ***");
        else
            $display("!!! %0d ELEMENTS MISMATCH !!!", fail);
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
        load_source_data();

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(500) @(posedge clk);
                $display("TIMEOUT: 500 cycles elapsed");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("");
                        $display("=== MEMCPY TEST COMPLETE ===");
                        $display("PC stopped at    : 0x%08h", dut.pc);
                        $display("Cycles (CPU only): %0d  (expected ~63)", cycle_count);
                        $display("R0 (src end)     : 0x%08h  (expected 0x128)", dut.u_rf.r0);
                        $display("R1 (dst end)     : 0x%08h  (expected 0x228)", dut.u_rf.r1);
                        $display("R2 (counter)     : %0d          (expected 0)",  dut.u_rf.r2);
                        $display("");
                        verify_copy();
                        $finish;
                    end
                    prev_pc = dut.pc;
                end
            end
        join
    end

    always_ff @(posedge clk)
        if (rst_n) cycle_count++;

    initial begin
        $dumpfile("tb_memcpy.vcd");
        $dumpvars(0, tb_memcpy);
    end

endmodule
