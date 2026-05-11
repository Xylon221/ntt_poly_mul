// NTT 多项式乘法自检测试平台
// 从 hex 文件加载测试向量，运行计算，逐一比对结果

`timescale 1ns / 1ps

module tb_ntt_top;

    reg        clk;
    reg        rst_n;
    reg        start;
    wire       done;
    wire       busy;

    reg  [11:0] host_addr;
    reg  [13:0] host_wdata;
    reg         host_we;
    wire [13:0] host_rdata;

    ntt_top u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .done       (done),
        .busy       (busy),
        .host_addr  (host_addr),
        .host_wdata (host_wdata),
        .host_we    (host_we),
        .host_rdata (host_rdata)
    );

    localparam N = 1024;
    localparam Q = 14'd12289;

    // 测试数据数组
    reg [13:0] tv_a    [0:N-1];
    reg [13:0] tv_b    [0:N-1];
    reg [13:0] tv_exp  [0:N-1];

    // 加载测试向量
    initial begin
        $readmemh("tv_a.hex", tv_a);
        $readmemh("tv_b.hex", tv_b);
        $readmemh("tv_exp.hex", tv_exp);
    end

    // 时钟: 100 MHz (周期 10ns)
    always #5 clk = ~clk;

    integer i, errors;
    reg [13:0] result;
    reg [31:0] cycle_cnt;

    initial begin
        clk       = 0;
        rst_n     = 0;
        start     = 0;
        host_addr = 0;
        host_wdata = 0;
        host_we   = 0;
        errors    = 0;
        cycle_cnt = 0;

        $display("=== NTT 多项式乘法 自检测试 ===");
        $display("Q=%0d, N=%0d", Q, N);

        // 复位
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // ----- 加载 A 到内存 (地址 0x000..0x3FF) -----
        $display("[%0t] 加载多项式 A...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= tv_a[i];
            host_we    <= 1;
        end

        // ----- 加载 B 到内存 (地址 0x400..0x7FF) -----
        $display("[%0t] 加载多项式 B...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= tv_b[i];
            host_we    <= 1;
        end

        @(posedge clk);
        host_we <= 0;

        // ----- 启动计算 -----
        $display("[%0t] 启动 NTT 计算...", $time);
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // ----- 等待完成 -----
        wait (done);
        $display("[%0t] 计算完成! 计算周期: %0d", $time, cycle_cnt);

        // ----- 验证结果 (C 区域: 0x800..0xBFF) -----
        $display("[%0t] 正在验证结果...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr <= {2'b10, i[9:0]};
        end
        @(posedge clk);

        for (i = 0; i < N; i = i + 1) begin
            host_addr <= {2'b10, i[9:0]};
            #1;
            result = host_rdata;
            if (result !== tv_exp[i]) begin
                if (errors < 20) begin
                    $display("错误: C[%0d] = %0d, 期望 %0d", i, result, tv_exp[i]);
                end
                errors = errors + 1;
            end
        end

        // ----- 报告 -----
        if (errors == 0) begin
            $display("=== 全部 %0d 项测试通过 ===", N);
        end else begin
            $display("=== 测试失败: %0d 项错误 ===", errors);
        end
        $display("总周期数: %0d", cycle_cnt);
        $finish;
    end

    // 周期计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_cnt <= 0;
        else if (!done)
            cycle_cnt <= cycle_cnt + 1;
    end

    // 超时保护
    initial begin
        #10000000;
        $display("超时: 仿真未完成");
        $finish;
    end

    // 波形输出
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_ntt_top);
    end

endmodule
