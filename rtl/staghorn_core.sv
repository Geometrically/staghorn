`default_nettype none
module staghorn_core #(
    parameter logic [31:0] RESET_ADDR = 32'h8000_0000
) (
    input wire clk,
    input wire rst_n, // active low!

    // Instruction port
    output logic instr_addr_valid,
    output logic [31:0] instr_addr,
    input wire instr_ready,
    input wire [31:0] instr_data,

    // Data port (r/w)
    output logic data_addr_valid,
    output logic [31:0] data_addr,
    // 0 = load, 1 = write (w/ mask)
    output logic [3:0] data_mask,
    // high if read/write succeeded
    input wire data_ready,
    output logic [31:0] data_write_data,
    input wire [31:0] data_read_data
);

logic [31:0] registers [1:31];
logic [31:0] pc;

// TODO: move to dedicated write port?
task automatic write_reg(
    input logic [4:0] addr,
    input logic [31:0] value
);
    if (addr != 5'd0)
        registers[addr] <= value;
endtask

always_ff @(posedge clk) begin
    if (!rst_n) begin
        instr_addr_valid <= 1;
        instr_addr <= RESET_ADDR;

        data_addr_valid <= 0;
        data_addr <= 0;
        data_mask <= 0;
        data_write_data <= 0;

        pc <= RESET_ADDR;
    end
    else begin
        if (!instr_ready) begin
            // fetch
            instr_addr_valid <= 1;
            instr_addr <= pc;
        end else begin
            // execute
            instr_addr_valid <= 0;
        end
    end
end

// Decode
wire [6:0] opcode = instr_data[6:0];
wire [2:0] funct3 = instr_data[14:12];
wire [6:0] funct7 = instr_data[31:25];

wire [4:0] rd = instr_data[11:7];
wire [4:0] rs1 = instr_data[19:15];
wire [4:0] rs2 = instr_data[24:20];

wire [31:0] rs1_data = rs1 == 0 ? 32'b0 : registers[rs1];
wire [31:0] rs2_data = rs2 == 0 ? 32'b0 : registers[rs2];

wire [31:0] imm_i = {{20{instr_data[31]}}, instr_data[31:20]};
wire [31:0] imm_s = {{20{instr_data[31]}}, instr_data[31:25], instr_data[11:7]};
wire [31:0] imm_b = {{19{instr_data[31]}}, instr_data[31], instr_data[7], instr_data[30:25], instr_data[11:8], 1'b0};
wire [31:0] imm_u = {instr_data[31:12], 12'b0};
wire [31:0] imm_j = {{11{instr_data[31]}}, instr_data[31], instr_data[19:12], instr_data[20], instr_data[30:21], 1'b0};

typedef enum logic [2:0] {
    ALU_ADD_SUB = 3'b000,
    ALU_SLL = 3'b001,
    ALU_SLT = 3'b010,
    ALU_SLTU = 3'b011,
    ALU_XOR = 3'b100,
    ALU_SRL_SRA = 3'b101,
    ALU_OR = 3'b110,
    ALU_AND = 3'b111
} alu_op_t;

typedef enum logic [1:0] {SRC_A_RS1, SRC_A_PC, SRC_A_ZERO} alu_src_a_t;
typedef enum logic {SRC_B_RS2, SRC_B_IMM} alu_src_b_t;

typedef enum logic [1:0] {
    MEM_B = 2'b00,
    MEM_H = 2'b01,
    MEM_W = 2'b10
} mem_width_t;

typedef enum logic [1:0] { RD_NONE, RD_ALU, RD_MEM, RD_PC4 } rd_sel_t;

typedef enum logic [1:0] { PC_PLUS4, PC_BRANCH, PC_ALU } pc_sel_t;

typedef struct packed {
    logic illegal;

    alu_op_t alu_op;
    logic alu_alt; // use ALU alt instruction (ex: sub)
    alu_src_a_t alu_a;
    alu_src_b_t alu_b;
    logic [31:0] imm;

    logic mem_r;
    logic mem_w;
    mem_width_t mem_width;
    logic mem_unsigned;

    rd_sel_t rd_sel; // what is set into rd
    logic [4:0] rd;

    pc_sel_t pc_sel; // where the pc goes after the instruction

    logic branch;
    logic branch_cond_inv;
} instr_t;
instr_t instr;

always_comb begin
    instr = '0;
    instr.rd = rd;

    // TODO: find way to decode illegal instructions better
    case (opcode)
        7'h33: begin // arithmetic, register-to-register (R)
            instr.alu_op = alu_op_t'(funct3);

            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_RS2;
            instr.alu_alt = funct7[5];
            instr.rd_sel = RD_ALU;

            instr.illegal = (funct7 & ~7'h20) != 0 || (funct7[5] && funct3 != 3'b000 && funct3 != 3'b101);
        end
        7'h13: begin // arithmetic, register-to-immediate (I)
            instr.alu_op = alu_op_t'(funct3);

            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_IMM;
            instr.alu_alt = instr_data[30] && funct3 == 3'b101;
            instr.imm = imm_i;
            instr.rd_sel = RD_ALU;

            instr.illegal = ((funct3 == 3'b001 || funct3 == 3'b101) && (instr_data[31:25] & ~7'h20) != 0) || (funct3 == 3'b001 && instr_data[30]);
        end
        7'h03: begin // load
            instr.mem_r = 1;
            instr.mem_width = mem_width_t'(funct3[1:0]);
            instr.mem_unsigned = funct3[2];

            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_IMM; // add offset
            instr.imm = imm_i;

            instr.rd_sel = RD_MEM;
            instr.illegal = (funct3[1:0] == 2'b11) || (funct3 == 3'b110); // unsupported variants
        end
        7'h23: begin // store
            instr.mem_w = 1;
            instr.mem_width = mem_width_t'(funct3[1:0]);

            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_IMM; // add offset
            instr.imm = imm_s;

            instr.rd_sel = RD_NONE;
            instr.illegal = funct3[2] || (funct3[1:0] == 2'b11);
        end
        7'h63: begin // branch (b)
            instr.branch = 1;
            instr.pc_sel = PC_BRANCH;

            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_RS2;
            instr.imm = imm_b;
            instr.rd_sel = RD_NONE;

            case (funct3[2:1])
                2'b00: instr.alu_op = ALU_XOR; // rs1 ^ rs2 == 0 -> rs1 == rs2 (eq/beq)
                2'b10: instr.alu_op = ALU_SLT; // lt/ge signed
                2'b11: instr.alu_op = ALU_SLTU; // lt/ge unsigned
                default: instr.illegal = 1;
            endcase

            instr.branch_cond_inv = funct3[0];
        end
        7'h37: begin // load upper immediate (u)
            instr.alu_a = SRC_A_ZERO;
            instr.alu_b = SRC_B_IMM;
            instr.imm = imm_u;
            instr.rd_sel = RD_ALU;
        end
        7'h17: begin // add upper immediate to PC (u)
            instr.alu_a = SRC_A_PC;
            instr.alu_b = SRC_B_IMM;
            instr.rd_sel = RD_ALU;
            instr.imm = imm_u;
        end
        7'h6F: begin // jump and link (j)
            instr.alu_a = SRC_A_PC;
            instr.alu_b = SRC_B_IMM;
            instr.imm = imm_j;
            instr.pc_sel = PC_ALU;
            instr.rd_sel = RD_PC4;
        end
        7'h67: begin // jump and link reg (i)
            instr.alu_a = SRC_A_RS1;
            instr.alu_b = SRC_B_IMM;
            instr.imm = imm_i;
            instr.pc_sel = PC_ALU;
            instr.rd_sel = RD_PC4;
            instr.illegal = (funct3 != 3'b000);
        end
        7'h0F: begin // fence
            instr.illegal = (funct3 > 3'b001);
            // case(func3)
            //     3'b000:
            //         // FENCE
            //     3'b001:
            //         // FENCE.I (ext)
            // endcase
        end
        7'h73: begin // system
            instr.illegal = (funct3 != 3'b000) || (instr_data[31:21] != 0) || (rs1 != 0) || (rd != 0);
            // case(func3)
            //     3'b000:
            //         // ECALL / EBREAK (funct 7 = 0100000)
            //     3'b001:
            //         // CSRRW
            //     3'b010:
            //         // CSRRS
            //     3'b011:
            //         // CSRRC
            //     3'b101:
            //         // CSRRWI
            //     3'b110:
            //         // CSRRSI
            //     3'b111:
            //         // CSRRCI
            // endcase
        end
        default:
            instr.illegal = 1;
    endcase
end

// Execute
logic [31:0] next_pc = pc + 4;
always_comb begin
end
endmodule
