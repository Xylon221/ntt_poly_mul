// Diagnostic 2: Monitor pre-twist and first butterfly
`timescale 1ns / 1ps

module tb_diag2;

    reg clk, rst_n, start;
    wire done, busy;
    reg [11:0] host_addr;
    reg [13:0] host_wdata;
    reg host_we;
    wire [13:0] host_rdata;

    ntt_top u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .busy(busy),
        .host_addr(host_addr), .host_wdata(host_wdata),
        .host_we(host_we), .host_rdata(host_rdata)
    );

    always #5 clk = ~clk;
    integer i;

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Load small test pattern: only first 4 elements
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= (i + 1);   // A[i] = i+1: 1, 2, 3, 4
            host_we    <= 1;
        end
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= 1;          // B[i] = 1
            host_we    <= 1;
        end

        @(posedge clk);
        host_we <= 0;

        // Verify load
        @(posedge clk);
        host_addr <= 0;
        @(posedge clk); #1;
        $display("mem[0] = %0d (expected 1)", host_rdata);
        host_addr <= 1;
        @(posedge clk); #1;
        $display("mem[1] = %0d (expected 2)", host_rdata);

        // Start computation
        @(posedge clk);
        start <= 1;
        $display("[%0t] Start pulsed", $time);
        @(posedge clk);
        start <= 0;

        // Monitor first pre-twist cycles
        repeat(5) begin
            @(posedge clk);
            $display("[%0t] phase=%0d cnt=%0d twist_acc=%0d mem_rdata_a=%0d",
                     $time, u_dut.phase, u_dut.cnt, u_dut.twist_acc,
                     u_dut.mem_rdata_a);
        end

        $finish;
    end

    initial begin
        $dumpfile("diag2_wave.vcd");
        $dumpvars(0, tb_diag2);
    end

endmodule
