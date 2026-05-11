// Diagnostic 3: Full load, check pre-twist completion and NTT start
`timescale 1ns / 1ps

module tb_diag3;

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
    reg [13:0] tv_a [0:1023];
    reg [13:0] tv_b [0:1023];
    reg [13:0] tv_exp [0:1023];

    initial begin
        $readmemh("tv_a.hex", tv_a);
        $readmemh("tv_b.hex", tv_b);
        $readmemh("tv_exp.hex", tv_exp);
    end

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Load A
        $display("[%0t] Loading A...", $time);
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= tv_a[i];
            host_we    <= 1;
        end

        // Load B
        $display("[%0t] Loading B...", $time);
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= tv_b[i];
            host_we    <= 1;
        end

        @(posedge clk);
        host_we <= 0;

        // Verify some loads
        @(posedge clk);
        host_addr <= 0;
        @(posedge clk); #1;
        $display("mem[0] = %0d (expected %0d)", host_rdata, tv_a[0]);
        host_addr <= 1024;
        @(posedge clk); #1;
        $display("mem[1024] = %0d (expected %0d)", host_rdata, tv_b[0]);

        // Start computation
        $display("[%0t] Starting...", $time);
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Check phase transitions
        repeat(10) @(posedge clk);
        $display("[%0t] After 10 cycles: phase=%0d cnt=%0d", $time, u_dut.phase, u_dut.cnt);

        // Wait for pre-twist A to complete (~1024 cycles)
        repeat(1100) @(posedge clk);
        $display("[%0t] After ~1100 cycles: phase=%0d cnt=%0d", $time, u_dut.phase, u_dut.cnt);

        // Wait more for pre-twist B
        repeat(1100) @(posedge clk);
        $display("[%0t] After ~2200 cycles: phase=%0d cnt=%0d", $time, u_dut.phase, u_dut.cnt);

        // Read a pre-twisted value
        @(posedge clk);
        host_addr <= 0;
        @(posedge clk); #1;
        $display("After pre-twist A[0] = %0d", host_rdata);
        host_addr <= 1024;
        @(posedge clk); #1;
        $display("After pre-twist B[0] = %0d", host_rdata);

        // Wait for NTT to complete
        wait(done);
        $display("[%0t] Done!", $time);

        // Check result C[0]
        @(posedge clk);
        host_addr <= 2048;
        @(posedge clk); #1;
        $display("C[0] = %0d (expected %0d)", host_rdata, tv_exp[0]);

        if (host_rdata === tv_exp[0])
            $display("MATCH!");
        else
            $display("MISMATCH");

        $finish;
    end

    initial begin
        $dumpfile("diag3_wave.vcd");
        $dumpvars(0, tb_diag3);
    end

endmodule
