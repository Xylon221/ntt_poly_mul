`timescale 1ns / 1ps
// NTT Polynomial Multiplication Top Module
//
// Weighted NTT approach for negacyclic convolution c(x) = a(x)*b(x) mod (x^1024+1)
//
// Algorithm:
//   1. Pre-twist:  A[i] *= psi^i,  B[i] *= psi^i
//   2. Forward NTT on A and B (using root omega = 49 = psi^2)
//   3. Pointwise multiply: C[i] = A[i] * B[i] mod Q
//   4. Inverse NTT on C (using root omega^(-1))
//   5. Post-twist + scale: result[i] = C[i] * psi^(-i) * N^(-1)
//
// Memory layout (3072 entries):
//   0x000-0x3FF: polynomial A workspace
//   0x400-0x7FF: polynomial B workspace
//   0x800-0xBFF: polynomial C workspace

module ntt_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire        done,
    output wire        busy,

    input  wire [11:0] host_addr,
    input  wire [13:0] host_wdata,
    input  wire        host_we,
    output wire [13:0] host_rdata
);
    localparam Q     = 14'd12289;
    localparam N     = 11'd1024;
    localparam MU    = 15'd21843;
    localparam PSI   = 14'd7;
    localparam PSI_INV = 14'd8778;     // 7^(-1) mod 12289 = 8778
    localparam N_INV = 14'd12277;

    reg [13:0] mem [0:3071];

    // ---- Phase FSM ----
    localparam PH_IDLE     = 4'd0;
    localparam PH_TWIST_A  = 4'd1;     // Pre-twist A
    localparam PH_TWIST_B  = 4'd2;     // Pre-twist B
    localparam PH_NTT_A    = 4'd3;     // Forward NTT on A
    localparam PH_NTT_B    = 4'd4;     // Forward NTT on B
    localparam PH_PW_READ  = 4'd5;     // Pointwise: read A,B
    localparam PH_PW_WRITE = 4'd6;     // Pointwise: write C
    localparam PH_INTT_C   = 4'd7;     // Inverse NTT on C
    localparam PH_POST     = 4'd8;     // Post-twist + scale
    localparam PH_DONE     = 4'd9;

    reg [3:0]  phase;
    reg        ntt_start;
    reg [1:0]  ntt_base;
    reg        ntt_mode_reg;
    wire       ntt_done;

    reg [9:0]  cnt;
    reg [13:0] twist_acc;        // running product for psi^j / psi^(-j)

    // Pointwise multiply
    reg [9:0]  pw_cnt;
    reg [27:0] pw_prod;

    // Barrett reduction helper (uses wide intermediate to avoid truncation)
    function [13:0] barrett;
        input [27:0] prod;
        reg [42:0] wide;
        reg [27:0] r1;
        begin
            wide    = prod * MU;
            r1      = prod - wide[41:28] * Q;
            barrett = (r1 >= Q) ? (r1[13:0] - Q) : r1[13:0];
        end
    endfunction

    // ---- Memory arbitration ----
    wire host_active = (phase == PH_IDLE || phase == PH_DONE);
    wire core_active = (phase == PH_NTT_A || phase == PH_NTT_B || phase == PH_INTT_C);
    wire twist_active = (phase == PH_TWIST_A || phase == PH_TWIST_B || phase == PH_POST);
    wire pw_read = (phase == PH_PW_READ);
    wire pw_write = (phase == PH_PW_WRITE);

    // Twist target region
    wire [1:0] twist_base = (phase == PH_TWIST_A) ? 2'b00 :
                             (phase == PH_TWIST_B) ? 2'b01 : 2'b10;

    // Port A address/data
    wire [11:0] mem_addr_a = core_active ? core_addr_a :
                             host_active ? host_addr :
                             twist_active ? {twist_base, cnt} :
                             pw_read  ? {2'b00, pw_cnt} :
                             pw_write ? {2'b10, pw_cnt} : 12'd0;
    wire        mem_we_a   = core_active ? core_we_a :
                             host_active ? host_we :
                             twist_active ? 1'b1 :
                             pw_write ? 1'b1 : 1'b0;
    wire [13:0] mem_data_a = core_active ? core_wdata_a :
                             host_active ? host_wdata :
                             twist_active ? twist_result :
                             pw_write ? pw_result : 14'd0;
    wire        mem_we_a_gated = mem_we_a && !(twist_active && (mem_data_a === 14'dx));

    // Port B address/data (read B during twist for twist_result, pointwise read)
    wire [11:0] mem_addr_b = core_active ? core_addr_b :
                             host_active ? host_addr :
                             pw_read  ? {2'b01, pw_cnt} : 12'd0;
    wire        mem_we_b   = core_active ? core_we_b :
                             host_active ? host_we : 1'b0;
    wire [13:0] mem_wdata_b = core_active ? core_wdata_b :
                              host_active ? host_wdata : 14'd0;

    // ---- Twist: mem[a] * twist_acc mod Q ----
    wire [27:0] tw_prod   = mem_rdata_a * twist_acc;
    wire [42:0] tw_wide   = tw_prod * MU;
    wire [13:0] tw_t      = tw_wide[41:28];
    wire [27:0] tw_r1     = tw_prod - tw_t * Q;
    wire [13:0] twist_result = (tw_r1 >= Q) ? (tw_r1[13:0] - Q) : tw_r1[13:0];

    // ---- Pointwise result ----
    wire [27:0] pw_prod_w = pw_prod;
    wire [42:0] pw_wide   = pw_prod_w * MU;
    wire [13:0] pw_t      = pw_wide[41:28];
    wire [27:0] pw_r1     = pw_prod_w - pw_t * Q;
    wire [13:0] pw_result = (pw_r1 >= Q) ? (pw_r1[13:0] - Q) : pw_r1[13:0];

    // ---- Memory writes ----
    always @(posedge clk) begin
        if (mem_we_a && !(mem_we_b && mem_addr_a == mem_addr_b)) begin
            mem[mem_addr_a] <= mem_data_a;
        end
        if (mem_we_b && !(mem_we_a && mem_addr_a == mem_addr_b)) begin
            mem[mem_addr_b] <= mem_wdata_b;
        end
        if (mem_we_a && mem_we_b && mem_addr_a == mem_addr_b) begin
            mem[mem_addr_a] <= mem_data_a;
        end
    end

    // Async reads
    wire [13:0] mem_rdata_a, mem_rdata_b;
    assign mem_rdata_a = mem[mem_addr_a];
    assign mem_rdata_b = mem[mem_addr_b];
    assign host_rdata  = host_active ? mem[host_addr] : 14'd0;

    // ---- NTT Core ----
    wire [11:0] core_addr_a, core_addr_b;
    wire        core_we_a, core_we_b;
    wire [13:0] core_wdata_a, core_wdata_b;
    wire [13:0] core_mem_rdata_a, core_mem_rdata_b;
    assign core_mem_rdata_a = mem[core_addr_a];
    assign core_mem_rdata_b = mem[core_addr_b];

    ntt_core u_ntt_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (ntt_start),
        .mode         (ntt_mode_reg),
        .base_sel     (ntt_base),
        .done         (ntt_done),
        .mem_addr_a   (core_addr_a),
        .mem_we_a     (core_we_a),
        .mem_wdata_a  (core_wdata_a),
        .mem_rdata_a  (core_mem_rdata_a),
        .mem_addr_b   (core_addr_b),
        .mem_we_b     (core_we_b),
        .mem_wdata_b  (core_wdata_b),
        .mem_rdata_b  (core_mem_rdata_b),
        .twiddle_addr (twiddle_addr),
        .twiddle_data (twiddle_data),
        .bf_valid     (bf_valid),
        .bf_mode      (bf_mode),
        .bf_a         (bf_a),
        .bf_b         (bf_b),
        .bf_w         (bf_w),
        .bf_res_a     (bf_res_a),
        .bf_res_b     (bf_res_b),
        .bf_valid_out (bf_valid_out)
    );

    wire [11:0] twiddle_addr;
    wire [13:0] twiddle_data;
    wire        bf_valid, bf_mode;
    wire [13:0] bf_a, bf_b, bf_w;
    wire [13:0] bf_res_a, bf_res_b;
    wire        bf_valid_out;

    twiddle_rom u_twiddle_rom (
        .clk  (clk),
        .addr (twiddle_addr),
        .data (twiddle_data)
    );

    butterfly u_butterfly (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (bf_valid),
        .mode      (bf_mode),
        .a         (bf_a),
        .b         (bf_b),
        .w         (bf_w),
        .res_a     (bf_res_a),
        .res_b     (bf_res_b),
        .valid_out (bf_valid_out)
    );

    // ---- Phase Controller ----
    reg [3:0] prev_phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase        <= PH_IDLE;
            prev_phase   <= PH_IDLE;
            ntt_start    <= 1'b0;
            ntt_base     <= 2'b00;
            ntt_mode_reg <= 1'b0;
            cnt          <= 10'd0;
            twist_acc    <= 14'd0;
            pw_cnt       <= 10'd0;
            pw_prod      <= 28'd0;
        end else begin
            prev_phase <= phase;
            ntt_start <= 1'b0;

            case (phase)
                PH_IDLE: begin
                    if (start) begin
                        cnt       <= 10'd0;
                        twist_acc <= 14'd1;     // psi^0 = 1
                        phase     <= PH_TWIST_A;
                    end
                end

                // Pre-twist A: A[i] *= psi^i
                PH_TWIST_A: begin
                    // mem_rdata_a = A[cnt], twist_acc = psi^cnt
                    // Written back via port A
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
                        // twist_acc = psi^(cnt+1) = twist_acc * PSI
                        twist_acc <= barrett(twist_acc * PSI);
                    end else begin
                        cnt       <= 10'd0;
                        twist_acc <= 14'd1;
                        phase     <= PH_TWIST_B;
                    end
                end

                // Pre-twist B: B[i] *= psi^i
                PH_TWIST_B: begin
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
                        twist_acc <= barrett(twist_acc * PSI);
                    end else begin
                        ntt_base     <= 2'b00;  // A region
                        ntt_mode_reg <= 1'b0;   // forward
                        ntt_start    <= 1'b1;
                        phase        <= PH_NTT_A;
                    end
                end

                // Forward NTT on A
                PH_NTT_A: begin
                    if (ntt_done) begin
                        ntt_base     <= 2'b01;   // B region
                        ntt_mode_reg <= 1'b0;    // forward
                        ntt_start    <= 1'b1;
                        phase        <= PH_NTT_B;
                    end
                end

                // Forward NTT on B
                PH_NTT_B: begin
                    if (ntt_done) begin
                        pw_cnt  <= 10'd0;
                        pw_prod <= 28'd0;
                        phase   <= PH_PW_READ;
                    end
                end

                // Pointwise: read A[i], B[i] and compute product
                PH_PW_READ: begin
                    pw_prod <= mem_rdata_a * mem_rdata_b;
                    phase   <= PH_PW_WRITE;
                end

                // Pointwise: write C[i] = pw_result, advance to next element
                PH_PW_WRITE: begin
                    if (pw_cnt + 1 < N) begin
                        pw_cnt  <= pw_cnt + 1;
                        phase   <= PH_PW_READ;
                    end else begin
                        ntt_base     <= 2'b10;   // C region
                        ntt_mode_reg <= 1'b1;    // inverse
                        ntt_start    <= 1'b1;
                        phase        <= PH_INTT_C;
                    end
                end

                // Inverse NTT on C
                PH_INTT_C: begin
                    if (ntt_done) begin
                        cnt       <= 10'd0;
                        twist_acc <= N_INV;      // start with N_INV * psi^0
                        phase     <= PH_POST;
                    end
                end

                // Post-twist + scale: C[i] *= psi^(-i) * N^(-1)
                PH_POST: begin
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
                        // twist_acc = psi^(-(cnt+1)) * N_INV
                        twist_acc <= barrett(twist_acc * PSI_INV);
                    end else begin
                        phase <= PH_DONE;
                    end
                end

                PH_DONE: begin
                    phase <= PH_IDLE;
                end

                default: phase <= PH_IDLE;
            endcase
        end
    end

    assign done = (phase == PH_DONE);
    assign busy = (phase != PH_IDLE && phase != PH_DONE);

endmodule
