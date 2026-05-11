// Diagnostic 4: Check memory before and after each phase
`timescale 1ns / 1ps

module tb_diag4;
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

    task read_mem;
        input [11:0] addr;
        begin
            host_addr <= addr;
            host_we <= 0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Load A
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= tv_a[i];
            host_we    <= 1;
        end
        // Load B
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= tv_b[i];
            host_we    <= 1;
        end
        @(posedge clk);
        host_we <= 0;
        
        // Verify load
        @(posedge clk); read_mem(0);
        $display("After load: A[0]=%0d (exp %0d)", host_rdata, tv_a[0]);
        read_mem(1);
        $display("After load: A[1]=%0d (exp %0d)", host_rdata, tv_a[1]);
        read_mem(1024);
        $display("After load: B[0]=%0d (exp %0d)", host_rdata, tv_b[0]);

        // Start
        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        // Wait for pre-twist A to finish (phase 1 -> phase 2)
        wait(u_dut.phase == 2);
        repeat(2) @(posedge clk);
        read_mem(0);
        $display("After pre-twist A: A[0]=%0d (exp %0d)", host_rdata, 1);
        read_mem(1);
        $display("After pre-twist A: A[1]=%0d (exp %0d)", host_rdata, (2 * 7) % 12289);

        // Wait for pre-twist B to finish (phase 2 -> phase 3)
        wait(u_dut.phase == 3);
        repeat(2) @(posedge clk);
        read_mem(1024);
        $display("After pre-twist B: B[0]=%0d (exp %0d)", host_rdata, 1024);
        read_mem(1025);
        $display("After pre-twist B: B[1]=%0d (exp %0d)", host_rdata, (1023 * 7) % 12289);

        // Wait for NTT A to finish (phase 3 -> phase 4)
        wait(u_dut.phase == 4);
        repeat(2) @(posedge clk);
        read_mem(0);
        $display("After NTT A: A[0]=%0d", host_rdata);

        // Wait for pointwise (phase 5 or 6)
        wait(u_dut.phase == 5 || u_dut.phase == 6);
        repeat(2) @(posedge clk);
        $display("Entering pointwise: phase=%0d", u_dut.phase);

        // Wait for inverse NTT (phase 7)
        wait(u_dut.phase == 7);
        repeat(2) @(posedge clk);
        read_mem(2048);
        $display("After pointwise, before INTT: C[0]=%0d", host_rdata);

        // Wait for post-twist (phase 8)
        wait(u_dut.phase == 8);
        repeat(2) @(posedge clk);
        read_mem(2048);
        $display("After INTT, before post-twist: C[0]=%0d", host_rdata);

        // Wait for done (phase 9)
        wait(u_dut.phase == 9);
        repeat(2) @(posedge clk);
        read_mem(2048);
        $display("After post-twist: C[0]=%0d (exp %0d)", host_rdata, tv_exp[0]);

        wait(done);
        $display("Done signal asserted");
        read_mem(2048);
        $display("Final C[0]=%0d (exp %0d)", host_rdata, tv_exp[0]);
        
        if (host_rdata === tv_exp[0])
            $display("PASS!");
        else
            $display("FAIL");

        $finish;
    end

    initial begin
        $dumpfile("diag4_wave.vcd");
        $dumpvars(0, tb_diag4);
    end
endmodule
