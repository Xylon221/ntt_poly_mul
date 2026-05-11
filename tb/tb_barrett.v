// Minimal Barrett reduction test
`timescale 1ns / 1ps

module tb_barrett;
    localparam Q  = 14'd12289;
    localparam MU = 15'd21839;

    reg [13:0] a, b;
    wire [27:0] prod = a * b;

    // Method 1: Context-determined width (as used in butterfly)
    wire [42:0] wide1 = prod * MU;
    wire [13:0] t1    = wide1[41:28];
    wire [27:0] r1_1  = prod - t1 * Q;
    wire [13:0] res1  = (r1_1 >= Q) ? (r1_1[13:0] - Q) : r1_1[13:0];

    // Method 2: Explicit extension
    wire [42:0] wide2 = { {15{1'b0}}, prod } * { {28{1'b0}}, MU };
    wire [13:0] t2    = wide2[41:28];
    wire [27:0] r1_2  = prod - t2 * Q;
    wire [13:0] res2  = (r1_2 >= Q) ? (r1_2[13:0] - Q) : r1_2[13:0];

    // Method 3: Direct mod (for reference)
    wire [27:0] ref = prod % Q;

    // Method 4: Verilog function (as in ntt_top)
    function [13:0] barrett;
        input [27:0] prod_in;
        reg [42:0] wide;
        reg [27:0] r1;
        begin
            wide = prod_in * MU;
            r1   = prod_in - wide[41:28] * Q;
            barrett = (r1 >= Q) ? (r1[13:0] - Q) : r1[13:0];
        end
    endfunction

    wire [13:0] res4 = barrett(prod);

    integer errors;
    initial begin
        errors = 0;
        // Test several (a,b) pairs
        // Simple: 2 * 3 = 6
        a = 2; b = 3; #10;
        if (res1 !== 6 || res2 !== 6 || ref !== 6 || res4 !== 6) begin
            $display("FAIL: 2*3: res1=%0d res2=%0d ref=%0d res4=%0d", res1, res2, ref, res4);
            errors = errors + 1;
        end

        // Medium: 100 * 200 = 20000 -> 20000-12289=7711
        a = 100; b = 200; #10;
        if (res1 !== 7711 || res2 !== 7711 || ref !== 7711 || res4 !== 7711) begin
            $display("FAIL: 100*200: res1=%0d res2=%0d ref=%0d res4=%0d", res1, res2, ref, res4);
            errors = errors + 1;
        end

        // Large: 12288 * 12288 -> ?
        a = 12288; b = 12288; #10;
        $display("12288*12288: res1=%0d res2=%0d ref=%0d res4=%0d prod=%0d MU=%0d wide1[41:28]=%0d",
                 res1, res2, ref, res4, prod, MU, wide1[41:28]);
        if (res1 !== ref || res2 !== ref || res4 !== ref) begin
            $display("FAIL: 12288*12288");
            errors = errors + 1;
        end

        // Mid: 5000 * 8000
        a = 5000; b = 8000; #10;
        $display("5000*8000: res1=%0d res2=%0d ref=%0d res4=%0d prod=%0d", res1, res2, ref, res4, prod);
        if (res1 !== ref || res2 !== ref || res4 !== ref) begin
            $display("FAIL: 5000*8000");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL BARRETT TESTS PASSED");
        else
            $display("%0d TESTS FAILED", errors);

        $finish;
    end

endmodule
