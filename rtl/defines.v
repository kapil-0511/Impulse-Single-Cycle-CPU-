// defines.v — Custom CPU ISA
//
// Non-branch: [31:29]=fmt  [28:24]=funct  [23:20]=Rd  [19:16]=Rs1
//             [15:12]=Rs2  [15:0]=imm16
// Branch:     [31:29]=100  [28:25]=COND   [24:0]=imm25

// ---- Instruction formats [31:29] ----
`define FMT_R      3'b000   // Register-Register : Rd = Rs1 op Rs2
`define FMT_I      3'b001   // Register-Immediate: Rd = Rs1 op imm16
`define FMT_LOAD   3'b010   // Load              : Rd = mem[Rb + off16]
`define FMT_STORE  3'b011   // Store             : mem[Rb + off16] = Rs
`define FMT_BRANCH 3'b100   // Branch            : if(COND) PC+=imm25*4
`define FMT_UNARY  3'b101   // Unary in-place    : Rd op= 1
`define FMT_JUMP   3'b110   // Jump              : BL / BX
`define FMT_CTRL   3'b111   // Control           : NOP / RETI

// ---- Funct codes — R-type [28:24] ----
`define FR_ADD   5'd0    // ADD  Rd, Rs1, Rs2
`define FR_SUB   5'd1    // SUB  Rd, Rs1, Rs2
`define FR_MUL   5'd2    // MUL  Rd, Rs1, Rs2
`define FR_AND   5'd3    // AND  Rd, Rs1, Rs2
`define FR_OR    5'd4    // OR   Rd, Rs1, Rs2
`define FR_XOR   5'd5    // XOR  Rd, Rs1, Rs2
`define FR_NOT   5'd6    // NOT  Rd, Rs1
`define FR_CMP   5'd7    // CMP  Rs1, Rs2       (flags only, no Rd write)
`define FR_TST   5'd8    // TST  Rs1, Rs2       (flags only, no Rd write)
`define FR_LSL   5'd9    // LSL  Rd, Rs1, Rs2
`define FR_LSR   5'd10   // LSR  Rd, Rs1, Rs2
`define FR_ASR   5'd11   // ASR  Rd, Rs1, Rs2
`define FR_MOV   5'd12   // MOV  Rd, Rs1

// ---- Funct codes — I-type [28:24] ----
`define FI_ADDI  5'd0    // ADDI Rd, Rs1, #imm16
`define FI_SUBI  5'd1    // SUBI Rd, Rs1, #imm16
`define FI_MOVI  5'd2    // MOVI Rd, #imm16
`define FI_LSLI  5'd3    // LSLI Rd, Rs1, #imm16
`define FI_LSRI  5'd4    // LSRI Rd, Rs1, #imm16
`define FI_ASRI  5'd5    // ASRI Rd, Rs1, #imm16

// ---- Funct codes — Load [28:24] ----
`define FL_LDR   5'd0    // LDR  Rd, [Rb, #offset16]

// ---- Funct codes — Store [28:24] ----
`define FS_STR   5'd0    // STR  Rs, [Rb, #offset16]

// ---- Funct codes — Unary [28:24] ----
`define FU_INC   5'd0    // INC  Rd
`define FU_DEC   5'd1    // DEC  Rd
`define FU_PUSH  5'd2    // PUSH Rd
`define FU_POP   5'd3    // POP  Rd

// ---- Funct codes — Jump [28:24] ----
`define FJ_BL    5'd0    // BL   #off20   (R14=PC+4, PC=PC+off20*4)
`define FJ_BX    5'd1    // BX   Rd       (PC=Rd)

// ---- Funct codes — Control [28:24] ----
`define FC_NOP   5'd0    // NOP
`define FC_RETI  5'd1    // RETI

// ---- Condition codes (branch inst [28:25] only) ----
`define COND_NV  4'h0   // Never
`define COND_EQ  4'h1   // Equal              Z=1
`define COND_NE  4'h2   // Not Equal          Z=0
`define COND_GT  4'h3   // Greater Than       Z=0 & N=V
`define COND_LT  4'h4   // Less Than          N!=V
`define COND_GE  4'h5   // Greater or Equal   N=V
`define COND_LE  4'h6   // Less or Equal      Z=1 | N!=V
`define COND_CS  4'h7   // Carry Set          C=1
`define COND_CC  4'h8   // Carry Clear        C=0
`define COND_AL  4'hE   // Always

// ---- ALU operation codes (internal datapath — not ISA encoding) ----
`define ALU_ADD    4'd0    // a + b
`define ALU_SUB    4'd1    // a - b
`define ALU_MUL    4'd2    // a * b
`define ALU_AND    4'd3    // a & b
`define ALU_OR     4'd4    // a | b
`define ALU_XOR    4'd5    // a ^ b
`define ALU_NOT    4'd6    // ~a
`define ALU_LSL    4'd7    // a << b[4:0]
`define ALU_LSR    4'd8    // a >> b[4:0]
`define ALU_ASR    4'd9    // $signed(a) >>> b[4:0]
`define ALU_MOV    4'd10   // a        (pass A — for MOV)
`define ALU_MOVB   4'd11   // b        (pass B — for MOVI)
`define ALU_INC    4'd12   // a + 1
`define ALU_DEC    4'd13   // a - 1

// ---- Instruction field positions ----
`define FMT_MSB    31
`define FMT_LSB    29
`define FT_MSB     28
`define FT_LSB     24
`define RD_MSB     23
`define RD_LSB     20
`define RS1_MSB    19
`define RS1_LSB    16
`define RS2_MSB    15
`define RS2_LSB    12
`define IMM16_MSB  15
`define IMM16_LSB   0
// Branch format
`define BR_COND_MSB  28
`define BR_COND_LSB  25
`define BR_IMM25_MSB 24
`define BR_IMM25_LSB  0
// BL format
`define BL_IMM20_MSB 19
`define BL_IMM20_LSB  0

// ---- Write-back selector ----
`define WB_ALU   2'b00
`define WB_MEM   2'b01
`define WB_PC4   2'b10

// ---- CPU mode ----
`define MODE_SYS 2'b00
`define MODE_IRQ 2'b01
`define MODE_FIQ 2'b10

// ---- Status register bits ----
`define SR_Z 0   // Zero
`define SR_N 1   // Negative
`define SR_C 2   // Carry
`define SR_V 3   // Overflow
`define SR_I 4   // IRQ enable
`define SR_F 5   // FIQ enable

// ---- Interrupt vectors ----
`define IRQ_VEC  32'h00000018
`define FIQ_VEC  32'h0000001C

// ---- Memory sizes ----
`define IMEM_DEPTH 1024
`define DMEM_DEPTH 1024
`define SP_INIT    32'h00000FFC
