`timescale 1ns / 1ps
// NTT 多项式乘法顶层模块
//
// 采用加权 NTT 实现负循环卷积: c(x) = a(x)*b(x) mod (x^1024+1)
//
// 算法流程:
//   1. 预旋乘: A[i] *= psi^i,  B[i] *= psi^i
//   2. 正向 NTT: A 和 B (使用根 omega = 49 = psi^2)
//   3. 逐点模乘: C[i] = A[i] * B[i] mod Q
//   4. 逆向 NTT: C (使用根 omega^(-1))
//   5. 后旋乘 + 缩放: result[i] = C[i] * psi^(-i) * N^(-1)
//
// 内存布局 (3072 项):
//   0x000-0x3FF: 多项式 A 工作区
//   0x400-0x7FF: 多项式 B 工作区
//   0x800-0xBFF: 多项式 C 工作区

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

    // ---- 相位 FSM ----
    localparam PH_IDLE     = 4'd0;
    localparam PH_TWIST_A  = 4'd1;     // 预旋乘 A
    localparam PH_TWIST_B  = 4'd2;     // 预旋乘 B
    localparam PH_NTT_A    = 4'd3;     // 正向 NTT on A
    localparam PH_NTT_B    = 4'd4;     // 正向 NTT on B
    localparam PH_PW_READ  = 4'd5;     // 逐点乘: 读取 A,B
    localparam PH_PW_WRITE = 4'd6;     // 逐点乘: 写入 C
    localparam PH_INTT_C   = 4'd7;     // 逆向 NTT on C
    localparam PH_POST     = 4'd8;     // 后旋乘 + 缩放
    localparam PH_DONE     = 4'd9;

    reg [3:0]  phase;
    reg        ntt_start;
    reg [1:0]  ntt_base;
    reg        ntt_mode_reg;
    wire       ntt_done;

    reg [9:0]  cnt;
    reg [13:0] twist_acc;        // psi^j / psi^(-j) 累乘值

    // 逐点乘法
    reg [9:0]  pw_cnt;
    reg [27:0] pw_prod;

    // Barrett 约简函数
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

    // ---- 存储器仲裁 ----
    wire host_active = (phase == PH_IDLE || phase == PH_DONE);
    wire core_active = (phase == PH_NTT_A || phase == PH_NTT_B || phase == PH_INTT_C);
    wire twist_active = (phase == PH_TWIST_A || phase == PH_TWIST_B || phase == PH_POST);
    wire pw_read = (phase == PH_PW_READ);
    wire pw_write = (phase == PH_PW_WRITE);

    // 旋乘目标区域选择
    wire [1:0] twist_base = (phase == PH_TWIST_A) ? 2'b00 :
                             (phase == PH_TWIST_B) ? 2'b01 : 2'b10;

    // 端口 A 地址/数据
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

    // 端口 B 地址/数据 (旋乘阶段读 B，逐点乘阶段读 B)
    wire [11:0] mem_addr_b = core_active ? core_addr_b :
                             host_active ? host_addr :
                             pw_read  ? {2'b01, pw_cnt} : 12'd0;
    wire        mem_we_b   = core_active ? core_we_b :
                             host_active ? host_we : 1'b0;
    wire [13:0] mem_wdata_b = core_active ? core_wdata_b :
                              host_active ? host_wdata : 14'd0;

    // ---- 旋乘: mem[a] * twist_acc mod Q ----
    wire [27:0] tw_prod   = mem_rdata_a * twist_acc;
    wire [42:0] tw_wide   = tw_prod * MU;
    wire [13:0] tw_t      = tw_wide[41:28];
    wire [27:0] tw_r1     = tw_prod - tw_t * Q;
    wire [13:0] twist_result = (tw_r1 >= Q) ? (tw_r1[13:0] - Q) : tw_r1[13:0];

    // ---- 逐点乘结果 ----
    wire [27:0] pw_prod_w = pw_prod;
    wire [42:0] pw_wide   = pw_prod_w * MU;
    wire [13:0] pw_t      = pw_wide[41:28];
    wire [27:0] pw_r1     = pw_prod_w - pw_t * Q;
    wire [13:0] pw_result = (pw_r1 >= Q) ? (pw_r1[13:0] - Q) : pw_r1[13:0];

    // ---- 存储器写入 ----
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

    // 异步读
    wire [13:0] mem_rdata_a, mem_rdata_b;
    assign mem_rdata_a = mem[mem_addr_a];
    assign mem_rdata_b = mem[mem_addr_b];
    assign host_rdata  = host_active ? mem[host_addr] : 14'd0;

    // ---- NTT 核心 ----
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

    // ---- 相位控制器 ----
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

                // 预旋乘 A: A[i] *= psi^i
                PH_TWIST_A: begin
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
                        twist_acc <= barrett(twist_acc * PSI);
                    end else begin
                        cnt       <= 10'd0;
                        twist_acc <= 14'd1;
                        phase     <= PH_TWIST_B;
                    end
                end

                // 预旋乘 B: B[i] *= psi^i
                PH_TWIST_B: begin
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
                        twist_acc <= barrett(twist_acc * PSI);
                    end else begin
                        ntt_base     <= 2'b00;  // A 区域
                        ntt_mode_reg <= 1'b0;   // 正向
                        ntt_start    <= 1'b1;
                        phase        <= PH_NTT_A;
                    end
                end

                // 正向 NTT on A
                PH_NTT_A: begin
                    if (ntt_done) begin
                        ntt_base     <= 2'b01;   // B 区域
                        ntt_mode_reg <= 1'b0;    // 正向
                        ntt_start    <= 1'b1;
                        phase        <= PH_NTT_B;
                    end
                end

                // 正向 NTT on B
                PH_NTT_B: begin
                    if (ntt_done) begin
                        pw_cnt  <= 10'd0;
                        pw_prod <= 28'd0;
                        phase   <= PH_PW_READ;
                    end
                end

                // 逐点乘: 读取 A[i], B[i] 并计算乘积
                PH_PW_READ: begin
                    pw_prod <= mem_rdata_a * mem_rdata_b;
                    phase   <= PH_PW_WRITE;
                end

                // 逐点乘: 写入 C[i] = pw_result, 前进到下一元素
                PH_PW_WRITE: begin
                    if (pw_cnt + 1 < N) begin
                        pw_cnt  <= pw_cnt + 1;
                        phase   <= PH_PW_READ;
                    end else begin
                        ntt_base     <= 2'b10;   // C 区域
                        ntt_mode_reg <= 1'b1;    // 逆向
                        ntt_start    <= 1'b1;
                        phase        <= PH_INTT_C;
                    end
                end

                // 逆向 NTT on C
                PH_INTT_C: begin
                    if (ntt_done) begin
                        cnt       <= 10'd0;
                        twist_acc <= N_INV;      // 初始值 N_INV * psi^0
                        phase     <= PH_POST;
                    end
                end

                // 后旋乘 + 缩放: C[i] *= psi^(-i) * N^(-1)
                PH_POST: begin
                    if (cnt + 1 < N) begin
                        cnt       <= cnt + 1;
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
