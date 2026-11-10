`default_nettype none
module staghorn_core #(
    parameter logic [31:0] RESET_ADDR = 32'h8000_0000
) (
    input wire clk,
    input wire rst_n, // active low!

    output logic instr_req,
    output logic [31:0] instr_req_addr,

    input wire instr_req_granted,
    input wire instr_rsp_valid,
    input wire [31:0] instr_rsp,

    output logic data_req,
    output logic [31:0] data_req_addr,

    output logic data_req_w,
    output logic [3:0] data_req_mask,
    output logic [31:0] data_req_wdata,

    input wire data_req_granted,
    input wire data_rsp_valid,
    input wire [31:0] data_rsp
);

logic [31:0] registers [1:31];
logic [31:0] pc;
logic [31:0] instr_raw;

// Decode
wire [6:0] opcode = instr_raw[6:0];
wire [2:0] funct3 = instr_raw[14:12];
wire [6:0] funct7 = instr_raw[31:25];

wire [4:0] rd = instr_raw[11:7];
wire [4:0] rs1 = instr_raw[19:15];
wire [4:0] rs2 = instr_raw[24:20];

wire [31:0] imm_i = {{20{instr_raw[31]}}, instr_raw[31:20]};
wire [31:0] imm_s = {{20{instr_raw[31]}}, instr_raw[31:25], instr_raw[11:7]};
wire [31:0] imm_b = {{19{instr_raw[31]}}, instr_raw[31], instr_raw[7], instr_raw[30:25], instr_raw[11:8], 1'b0};
wire [31:0] imm_u = {instr_raw[31:12], 12'b0};
wire [31:0] imm_j = {{11{instr_raw[31]}}, instr_raw[31], instr_raw[19:12], instr_raw[20], instr_raw[30:21], 1'b0};

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

    pc_sel_t pc_sel; // where the pc goes after the instruction

    logic branch;
    logic branch_cond_inv;
} instr_t;
instr_t instr;

always_comb begin
    instr = '0;

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
            instr.alu_alt = instr_raw[30] && funct3 == 3'b101;
            instr.imm = imm_i;
            instr.rd_sel = RD_ALU;

            instr.illegal = ((funct3 == 3'b001 || funct3 == 3'b101) && (instr_raw[31:25] & ~7'h20) != 0) || (funct3 == 3'b001 && instr_raw[30]);
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
                2'b00: instr.alu_op = ALU_XOR; // rs1 ^ rs2 == 0 -> rs1 == rs2 (eq/ne)
                2'b10: instr.alu_op = ALU_SLT; // lt/ge signed
                2'b11: instr.alu_op = ALU_SLTU; // lt/ge unsigned
                default: instr.illegal = 1;
            endcase

            instr.branch_cond_inv = funct3[0] ^ ~funct3[2]; // inv on beq, bge, bgeu
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
            instr.illegal = (funct3 != 3'b000) || (instr_raw[31:21] != 0) || (rs1 != 0) || (rd != 0);
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
wire [31:0] rs1_data =  rs1 == 0 ? 32'b0 : registers[rs1];
wire [31:0] rs2_data =  rs2 == 0 ? 32'b0 : registers[rs2];

logic [31:0] alu_a;
always_comb case (instr.alu_a)
    SRC_A_RS1: alu_a = rs1_data;
    SRC_A_PC: alu_a = pc;
    default: alu_a = 32'b0;
endcase

logic [31:0] alu_b;
always_comb case (instr.alu_b)
    SRC_B_IMM: alu_b = instr.imm;
    default: alu_b = rs2_data;
endcase

logic [31:0] alu_result;
// todo: switch away from naive version and share adders?, compare with yosys
always_comb case (instr.alu_op)
    ALU_ADD_SUB: alu_result = instr.alu_alt ? alu_a - alu_b : alu_a + alu_b;
    ALU_SLL: alu_result = alu_a << alu_b[4:0];
    ALU_SLT: alu_result = {31'b0, $signed(alu_a) < $signed(alu_b)};
    ALU_SLTU: alu_result = {31'b0, alu_a < alu_b};
    ALU_XOR: alu_result = alu_a ^ alu_b;
    ALU_SRL_SRA: begin
        if (instr.alu_alt) begin
            alu_result = $signed(alu_a) >>> alu_b[4:0];
        end else begin
             alu_a >> alu_b[4:0];
        end
    end
    ALU_OR: alu_result = alu_a | alu_b;
    ALU_AND: alu_result = alu_a & alu_b;
    default: alu_result = 32'bx;
endcase

wire branch_taken = instr.branch & (|alu_result ^ instr.branch_cond_inv);

wire [31:0] pc_default_next = pc + 32'd4;
logic [31:0] pc_next;
always_comb case (instr.pc_sel)
    PC_BRANCH: pc_next = branch_taken ? pc + instr.imm : pc_default_next;
    PC_ALU: pc_next = {alu_result[31:1], 1'b0};
    default: pc_next = pc_default_next;
endcase

// Memory
wire [31:0] mem_addr = alu_result; // rs1 + imm
wire [1:0] mem_offset = mem_addr[1:0];
wire mem_access = instr.mem_r | instr.mem_w;

// TODO: support misaligned memory
logic mem_misaligned;
always_comb case (instr.mem_width)
    MEM_H: mem_misaligned = mem_access & mem_offset[0];
    MEM_W: mem_misaligned = mem_access & (mem_offset != 2'b00);
    default: mem_misaligned = 0;
endcase

logic [3:0] mem_mask;
always_comb begin
    mem_mask = 4'b0000;
    if (instr.mem_w) case (instr.mem_width)
        MEM_B: mem_mask = 4'b0001 << mem_offset;
        MEM_H: mem_mask = 4'b0011 << mem_offset;
        default: mem_mask = 4'b1111;
    endcase
end

logic [31:0] mem_write_data;
always_comb case (instr.mem_width)
    MEM_B: mem_write_data = {4{rs2_data[7:0]}};
    MEM_H: mem_write_data = {2{rs2_data[15:0]}};
    default: mem_write_data = rs2_data;
endcase

wire [31:0] load_shifted = data_rsp >> {mem_offset, 3'b000}; // offset * 8

logic [31:0] load_value;
always_comb case (instr.mem_width)
    MEM_B: load_value = {{24{~instr.mem_unsigned & load_shifted[7]}}, load_shifted[7:0]};
    MEM_H: load_value = {{16{~instr.mem_unsigned & load_shifted[15]}}, load_shifted[15:0]};
    default: load_value = load_shifted;
endcase

wire rd_wants_write = instr.rd_sel != RD_NONE;
logic [31:0] rd_value;
always_comb case (instr.rd_sel)
    RD_ALU: rd_value = alu_result;
    RD_MEM: rd_value = load_value;
    RD_PC4: rd_value = pc_default_next;
    default: rd_value = 32'd0;
endcase

// Clocked logic
typedef enum logic [1:0] {FETCH, EXECUTE, MEMORY, HALT} core_state_t;
core_state_t core_state;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        core_state <= FETCH;

        instr_req <= 1;
        instr_req_addr <= RESET_ADDR;

        data_req <= 0;
        data_req_addr <= 0;
        data_req_w <= 0;
        data_req_mask <= 0;
        data_req_wdata <= 0;

        pc <= RESET_ADDR;
        instr_raw <= 0;
    end
    else begin
        if (instr_req && instr_req_granted) begin
            instr_req <= 0;
        end

        if (data_req && data_req_granted) begin
            data_req <= 0;
        end

        if (core_state == HALT) begin
        end else if (core_state == FETCH && instr_rsp_valid) begin
            instr_raw <= instr_rsp;
            core_state <= EXECUTE;
        end else if (core_state == EXECUTE && (instr.illegal || mem_misaligned)) begin
           core_state <= HALT;
        end
        end else if (core_state == EXECUTE && mem_access) begin
            data_req <= 1;
            data_req_addr <= mem_addr;
            data_req_w <= instr.mem_w;
            data_req_mask <= mem_mask;
            data_req_wdata <= mem_write_data;
            core_state <= MEMORY;
        end else if (
            (core_state == MEMORY && data_rsp_valid) ||
            (core_state == EXECUTE && !mem_access)
        ) begin
            if (rd_wants_write && rd != 0) begin
                registers[rd] <= rd_value;
            end

            instr_req <= 1;
            pc <= pc_next;
            instr_req_addr <= pc_next;
            core_state <= FETCH;
        end
    end
end

endmodule
