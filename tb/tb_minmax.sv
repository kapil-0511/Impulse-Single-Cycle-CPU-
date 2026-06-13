`timescale 1ns/1ps
`include "defines.v"
// tb_minmax.sv — Find smallest and largest element in an array (N=25)
//
// Register allocation:
//   R0 — array base pointer (byte address, advances by 4)
//   R1 — loop counter (N-1=24 down to 0)
//   R2 — current element A[i]
//   R3 — running minimum
//   R4 — running maximum
//   R5 — result base address
//
// Memory layout (DMEM):
//   Array  : words  64..88  (byte 0x100) — 25 elements
//   Result : word  200      (byte 0x320) — min
//            word  201      (byte 0x324) — max
//
// Word map:
//   Word  0 = 0x000  B AL +32
//   Word  6 = 0x018  RETI
//   Word  7 = 0x01C  RETI
//   Word 32 = 0x080  MOVI R0, #256    array base
//   Word 33 = 0x084  MOVI R1, #24     loop counter = N-1
//   Word 34 = 0x088  LDR  R3,[R0, 0]  min = A[0]
//   Word 35 = 0x08C  LDR  R4,[R0, 0]  max = A[0]
//   Word 36 = 0x090  ADDI R0,R0,#4    advance to A[1]
//   Word 37 = 0x094  LDR  R2,[R0, 0]  ← LOOP TOP
//   Word 38 = 0x098  CMP  R2, R3
//   Word 39 = 0x09C  BGE  +2          if R2>=min skip
//   Word 40 = 0x0A0  MOV  R3, R2      update min
//   Word 41 = 0x0A4  CMP  R2, R4      ← skip_min
//   Word 42 = 0x0A8  BLE  +2          if R2<=max skip
//   Word 43 = 0x0AC  MOV  R4, R2      update max
//   Word 44 = 0x0B0  ADDI R0,R0,#4    ← skip_max
//   Word 45 = 0x0B4  DEC  R1
//   Word 46 = 0x0B8  BNE  -9          back to word 37
//   Word 47 = 0x0BC  MOVI R5, #800    result base
//   Word 48 = 0x0C0  STR  R3,[R5, 0]  store min
//   Word 49 = 0x0C4  STR  R4,[R5, 4]  store max
//   Word 50 = 0x0C8  B AL #0          halt

module tb_minmax;

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
        apb_write(addr, enc_i(`FI_MOVI, 4'd0, 4'd0, 16'd256));   addr += 4; // MOVI R0,#256
        apb_write(addr, enc_i(`FI_MOVI, 4'd1, 4'd0, 16'd24));    addr += 4; // MOVI R1,#24
        apb_write(addr, enc_load(4'd3, 4'd0, 16'd0));             addr += 4; // LDR  R3,[R0,0]
        apb_write(addr, enc_load(4'd4, 4'd0, 16'd0));             addr += 4; // LDR  R4,[R0,0]
        apb_write(addr, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd4));     addr += 4; // ADDI R0,R0,#4

        // loop top (word 37)
        apb_write(addr, enc_load(4'd2, 4'd0, 16'd0));             addr += 4; // LDR  R2,[R0,0]
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd2, 4'd3));       addr += 4; // CMP  R2,R3
        apb_write(addr, enc_b(`COND_GE, 25'd2));                  addr += 4; // BGE  +2
        apb_write(addr, enc_r(`FR_MOV, 4'd3, 4'd2, 4'd0));       addr += 4; // MOV  R3,R2

        // skip_min (word 41)
        apb_write(addr, enc_r(`FR_CMP, 4'd0, 4'd2, 4'd4));       addr += 4; // CMP  R2,R4
        apb_write(addr, enc_b(`COND_LE, 25'd2));                  addr += 4; // BLE  +2
        apb_write(addr, enc_r(`FR_MOV, 4'd4, 4'd2, 4'd0));       addr += 4; // MOV  R4,R2

        // skip_max (word 44)
        apb_write(addr, enc_i(`FI_ADDI, 4'd0, 4'd0, 16'd4));     addr += 4; // ADDI R0,R0,#4
        apb_write(addr, enc_u(`FU_DEC, 4'd1));                    addr += 4; // DEC  R1
        apb_write(addr, enc_b(`COND_NE, 25'h1FFFFF7));            addr += 4; // BNE  -9

        // store results (word 47)
        apb_write(addr, enc_i(`FI_MOVI, 4'd5, 4'd0, 16'd800));   addr += 4; // MOVI R5,#800
        apb_write(addr, enc_store(4'd3, 4'd5, 16'd0));            addr += 4; // STR  R3,[R5,0]
        apb_write(addr, enc_store(4'd4, 4'd5, 16'd4));            addr += 4; // STR  R4,[R5,4]
        apb_write(addr, enc_b(`COND_AL, 25'd0));

        $display("[APB] Program load complete");
    endtask

    // ---- Array loader ----
    // 25 elements, range 18-951
    // min = 18 (index 7), max = 951 (index 3)
    task automatic load_array();
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
        $display("[TB]  Array[0..24] loaded into DMEM[64..88]");
    endtask

    // ---- Checker ----
    task automatic verify();
        logic [31:0] min_val, max_val;
        min_val = dut.u_dmem.mem[200];
        max_val = dut.u_dmem.mem[201];
        $display("[MEM] Source : DMEM words  64..88  (byte 0x100..0x15F)");
        $display("[MEM] Result : DMEM word  200      (byte 0x320) = min");
        $display("[MEM]          DMEM word  201      (byte 0x324) = max");
        $display("-------------------------------------------");
        $display("  DMEM[0x320] min : %0d  (expected 18)",  min_val);
        $display("  DMEM[0x324] max : %0d  (expected 951)", max_val);
        $display("-------------------------------------------");
        if (min_val === 32'd18 && max_val === 32'd951)
            $display("*** PASS — min=18, max=951 ***");
        else
            $display("!!! FAIL — got min=%0d max=%0d", min_val, max_val);
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
        load_array();

        @(negedge clk);
        rst_n = 1'b1;
        $display("[TB]  rst_n=1 — CPU starting");

        fork
            begin
                repeat(600) @(posedge clk);
                $display("TIMEOUT: 600 cycles");
                $finish;
            end
            begin
                forever @(posedge clk) begin
                    if (rst_n && (dut.pc === prev_pc)) begin
                        @(posedge clk);
                        $display("=== MIN/MAX COMPLETE ===");
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
        $dumpfile("tb_minmax.vcd");
        $dumpvars(0, tb_minmax);
    end

endmodule
