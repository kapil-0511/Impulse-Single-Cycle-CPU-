`timescale 1ns/1ps
`include "defines.v"
// tb_array_sum.sv — Element-wise array addition: C[i] = A[i] + B[i], i=0..24
//
// Memory layout (DMEM — backdoor loaded):
//   Array A : byte 0x100 (word  64) — 25 elements
//   Array B : byte 0x200 (word 128) — 25 elements
//   Array C : byte 0x300 (word 192) — 25 results
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R0, #256   base A
//   Word 33 = 0x084  MOVI R1, #512   base B
//   Word 34 = 0x088  MOVI R2, #768   base C
//   Word 35 = 0x08C  MOVI R3, #25    loop count
//   Word 36 = 0x090  LDR  R4,[R0,0]  ← loop top
//   Word 37 = 0x094  LDR  R5,[R1,0]
//   Word 38 = 0x098  ADD  R6, R4, R5
//   Word 39 = 0x09C  STR  R6,[R2,0]
//   Word 40 = 0x0A0  ADDI R0,R0,#4
//   Word 41 = 0x0A4  ADDI R1,R1,#4
//   Word 42 = 0x0A8  ADDI R2,R2,#4
//   Word 43 = 0x0AC  DEC  R3
//   Word 44 = 0x0B0  BNE  -8 → word 36
//   Word 45 = 0x0B4  B AL #0  halt

module tb_array_sum;

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

    function automatic logic [31:0] enc_ctrl(input logic [4:0] funct);
        return {`FMT_CTRL, funct, 24'd0};
    endfunction

    // ---- Program loader ----
    task automatic load_program();
        int addr;
        $display("[APB] Loading program...");

        apb_write(32'h000, enc_b(`COND_AL, 25'd32));
        apb_write(32'h018, enc_ctrl(`FC_RETI));
        apb_write(32'h01C, enc_ctrl(`FC_RETI));

        addr = 32'h080;
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd256)); addr += 4; // MOVI R0,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd512)); addr += 4; // MOVI R1,#512
        apb_write(addr, enc_i(`FI_MOVI, 4'd2, 4'd0, 16'd768)); addr += 4; // MOVI R2,#768
        apb_write(addr, enc_i(`FI_MOVI, 4'd3, 4'd0, 16'd25));  addr += 4; // MOVI R3,#25
        // loop top (word 36)
        apb_write(addr, enc_load(4'd4, 4'd0, 16'd0));                      addr += 4; // LDR R4,[R0]
        apb_write(addr, enc_load(4'd5, 4'd1, 16'd0));                      addr += 4; // LDR R5,[R1]
        apb_write(addr, enc_r(`FR_ADD, 4'd6, 4'd4, 4'd5));                addr += 4; // ADD R6,R4,R5
        apb_write(addr, enc_store(4'd6, 4'd2, 16'd0));                     addr += 4; // STR R6,[R2]
        apb_write(addr, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd4));             addr += 4; // ADDI R0,R0,#4
        apb_write(addr, enc_i(`FI_ADDI, 4'd1, 4'd1, 16'd4));             addr += 4; // ADDI R1,R1,#4
        apb_write(addr, enc_i(`FI_ADDI, 4'd2, 4'd2, 16'd4));             addr += 4; // ADDI R2,R2,#4
        apb_write(addr, enc_u(`FU_DEC, 4'd3));                             addr += 4; // DEC  R3
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF8));                    addr += 4; // BNE  -8
        apb_write(addr, enc_b(`COND_AL, 25'd0));                                       // halt

        $display("[APB] Program load complete");
    endtask

    // ---- Array loader ----
    // A: 25 diverse values in 15-1000
    // B: 25 diverse values in 15-1000
    task automatic load_arrays();
        // Array A (word 64..88)
        dut.u_dmem.mem[64]  = 32'd427; dut.u_dmem.mem[65]  = 32'd83;
        dut.u_dmem.mem[66]  = 32'd612; dut.u_dmem.mem[67]  = 32'd951;
        dut.u_dmem.mem[68]  = 32'd38;  dut.u_dmem.mem[69]  = 32'd776;
        dut.u_dmem.mem[70]  = 32'd245; dut.u_dmem.mem[71]  = 32'd18;
        dut.u_dmem.mem[72]  = 32'd534; dut.u_dmem.mem[73]  = 32'd889;
        dut.u_dmem.mem[74]  = 32'd162; dut.u_dmem.mem[75]  = 32'd723;
        dut.u_dmem.mem[76]  = 32'd57;  dut.u_dmem.mem[77]  = 32'd398;
        dut.u_dmem.mem[78]  = 32'd841; dut.u_dmem.mem[79]  = 32'd127;
        dut.u_dmem.mem[80]  = 32'd690; dut.u_dmem.mem[81]  = 32'd315;
        dut.u_dmem.mem[82]  = 32'd472; dut.u_dmem.mem[83]  = 32'd936;
        dut.u_dmem.mem[84]  = 32'd204; dut.u_dmem.mem[85]  = 32'd581;
        dut.u_dmem.mem[86]  = 32'd743; dut.u_dmem.mem[87]  = 32'd29;
        dut.u_dmem.mem[88]  = 32'd667;
        // Array B (word 128..152)
        dut.u_dmem.mem[128] = 32'd312; dut.u_dmem.mem[129] = 32'd758;
        dut.u_dmem.mem[130] = 32'd44;  dut.u_dmem.mem[131] = 32'd629;
        dut.u_dmem.mem[132] = 32'd891; dut.u_dmem.mem[133] = 32'd155;
        dut.u_dmem.mem[134] = 32'd483; dut.u_dmem.mem[135] = 32'd726;
        dut.u_dmem.mem[136] = 32'd367; dut.u_dmem.mem[137] = 32'd52;
        dut.u_dmem.mem[138] = 32'd814; dut.u_dmem.mem[139] = 32'd298;
        dut.u_dmem.mem[140] = 32'd641; dut.u_dmem.mem[141] = 32'd175;
        dut.u_dmem.mem[142] = 32'd523; dut.u_dmem.mem[143] = 32'd869;
        dut.u_dmem.mem[144] = 32'd431; dut.u_dmem.mem[145] = 32'd77;
        dut.u_dmem.mem[146] = 32'd918; dut.u_dmem.mem[147] = 32'd286;
        dut.u_dmem.mem[148] = 32'd643; dut.u_dmem.mem[149] = 32'd109;
        dut.u_dmem.mem[150] = 32'd854; dut.u_dmem.mem[151] = 32'd462;
        dut.u_dmem.mem[152] = 32'd733;
        $display("[TB]  A[0..24] and B[0..24] loaded");
    endtask

    // ---- Checker ----
    task automatic verify();
        int pass, fail;
        logic [31:0] a_val, b_val, c_val, expected;
        pass = 0; fail = 0;
        $display("[MEM] Source A : DMEM words  64..88  (byte 0x100..0x15F)");
        $display("[MEM] Source B : DMEM words 128..152 (byte 0x200..0x25F)");
        $display("[MEM] Result C : DMEM words 192..216 (byte 0x300..0x35F)");
        $display("----------------------------------------------------");
        $display("  i |    A |    B |  A+B | C[i] | result");
        $display("----------------------------------------------------");
        for (int i = 0; i < 25; i++) begin
            a_val    = dut.u_dmem.mem[64  + i];
            b_val    = dut.u_dmem.mem[128 + i];
            c_val    = dut.u_dmem.mem[192 + i];
            expected = a_val + b_val;
            if (c_val === expected) begin
                $display(" %2d | %4d | %4d | %4d | %4d | PASS",
                         i, a_val, b_val, expected, c_val);
                pass++;
            end else begin
                $display(" %2d | %4d | %4d | %4d | %4d | FAIL ***",
                         i, a_val, b_val, expected, c_val);
                fail++;
            end
        end
        $display("----------------------------------------------------");
        if (fail == 0) $display("*** ALL 25 ELEMENTS CORRECT ***");
        else           $display("!!! %0d ELEMENTS WRONG !!!", fail);
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
        load_arrays();

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(700) @(posedge clk);
                $display("TIMEOUT: 700 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== ARRAY SUM COMPLETE ===");
                        $display("PC stopped at : 0x%08h", dut.pc);
                        $display("Cycles        : %0d",    cycle_count);
                        verify();
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
        $dumpfile("tb_array_sum.vcd");
        $dumpvars(0, tb_array_sum);
    end

endmodule
