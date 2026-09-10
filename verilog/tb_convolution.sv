
`timescale 1ns / 1ps

module tb_convolution();
    parameter debug32          = 32;
    parameter input_channel  = 3;
    parameter input_width    = 8;
    parameter output_channel = 16;
    parameter stride         = 1;
    parameter padding        = 1;
    
    parameter BIT_WIDTH      = 8;
    parameter kernel_size    = 3; 
    parameter output_width   = (input_width-kernel_size + 2*padding)/stride + 1;
    parameter ADDR_WIDTH     = 20;
    parameter IFMAP_DEPTH    = input_width*input_width*input_channel; 
    parameter WEIGHT_DEPTH   = kernel_size*kernel_size*input_channel*output_channel + output_channel; // (+ bias)
    parameter OFMAP_DEPTH    = output_width*output_width*output_channel;
    
    parameter half_clock     = 5; // 100MHz

    // from convolver 
    wire       [31:0]       dout;
    wire                           eoc;

    reg [ADDR_WIDTH-1:0] i_addra, w_addra, o_addra; //test 용
    wire img_ready, fil_ready, output_valid, output_last;
    
    // to convolver 
    reg                            clk;
    reg                            rst;
    wire        [BIT_WIDTH-1:0]         din;
    wire        [31:0]         win;

    // internal memory 
    reg signed [BIT_WIDTH-1:0]         din_memory      [0:IFMAP_DEPTH-1]; 
    reg signed [31:0]         win_memory      [0:WEIGHT_DEPTH-1];
    reg signed [31:0]       dout_memory     [0:OFMAP_DEPTH-1];
    reg signed [31:0]       ref_out         [0:OFMAP_DEPTH-1];
    
    reg start;
    reg [debug32-1:0] img_width_reg;
    reg [debug32-1:0] input_channel_reg;
    reg [debug32-1:0] output_channel_reg;
    reg [debug32-1:0] stride_reg;
    reg [debug32-1:0] padding_reg;

    integer counter;
    integer idx;
    integer sum, ifmap_val, weight_val;
    integer input_row, input_col;
    integer oc, ic, i, j, m, n; // 각 루프를 위한 인덱스
    
    initial begin
        clk     = 0;
        counter = 0;
        i_addra = 0;
        w_addra = 0;
        o_addra = 0;
        
        img_width_reg = input_width;
        input_channel_reg = input_channel;
        output_channel_reg = output_channel;
        stride_reg = stride;
        padding_reg = padding;
        
        rst = 0;
        #(4*half_clock)
        rst = 1;
        #(4*half_clock)
        start = 1;
        #(2*half_clock)
        start = 0;
    end

    always #(half_clock)  clk = ~clk;
    always @ (posedge clk) begin
        counter = counter + 1;
    end
   
    initial begin
        #(100*100*100*100*half_clock*2)
        $display("#############################################################################");
        $display("Failed");
        $display("#############################################################################");
        $finish;
    end
    
    
    always @ (posedge eoc) begin
        if(rst === 1'b1) begin
            for (idx = 0; idx < OFMAP_DEPTH; idx = idx+1) begin
                if (dout_memory[idx] === 8'dx) begin
                    $display("#############################################################################");
                    $display("Write failure");
                    $display("#############################################################################");
                    $finish;
                end
    
                if (dout_memory[idx] !== ref_out[idx]) begin
                    $display("#############################################################################");
                    $display("Wrong data");
                    $display("#############################################################################");
                    $finish;
                end
                 if (dout_memory[idx] == ref_out[idx]) begin
                     $display("#############################################################################");
                     $display("[%0d] Correct! Calculated : %0d, Golden : %0d", idx, dout_memory[idx], ref_out[idx]);
                 end
            end
            $display("#############################################################################");
            $display("The convolution module works well! ^_^");
            $display("The total cycle is %d", counter);
            $display("#############################################################################");
            $finish;
        end
    end
    
    
    //input, weight memory
    initial begin
        for (idx = 0; idx < IFMAP_DEPTH; idx = idx+1) begin
            din_memory[idx] = $urandom_range(127, -128);
        end
        for (idx = 0; idx < WEIGHT_DEPTH; idx = idx+1) begin
            win_memory[idx] = $urandom_range(127, -128);
        end
        for (idx = 0; idx < OFMAP_DEPTH; idx = idx+1) begin
            dout_memory[idx] = 0;
        end
        
        // ref_out
        // oc: Output Channel (Filter) 루프
        for (oc = 0; oc < output_channel; oc = oc + 1) begin
            // i, j: Output Feature Map의 세로, 가로 루프
            for (i = 0; i < output_width; i = i + 1) begin
                for (j = 0; j < output_width; j = j + 1) begin
                    
                    sum = 0; // 각 출력 픽셀마다 sum 초기화
    
                    // ic: Input Channel 루프 (모든 입력 채널에 대해 연산 후 합산)
                    for (ic = 0; ic < input_channel; ic = ic + 1) begin
                        // m, n: Filter Kernel의 세로, 가로 루프
                        for (m = 0; m < kernel_size; m = m + 1) begin
                            for (n = 0; n < kernel_size; n = n + 1) begin
                                
                                // 1. 입력 이미지 값 (ifmap_val) 가져오기
                                // 입력 규격: 입력채널 x 행 x 렬 (IC x H x W)
                                input_row = i * stride + m - padding;
                                input_col = j * stride + n - padding;
    
                                if (input_row >= 0 && input_row < input_width && input_col >= 0 && input_col < input_width) begin
                                    ifmap_val = din_memory[ic*input_width*input_width + input_row*input_width + input_col];
                                end
                                else begin
                                    ifmap_val = 0; // Zero Padding
                                end
                                
                                // 2. 필터 가중치 값 (weight_val) 가져오기
                                // 필터 규격: 입력채널 x 개수 x 행 x 렬 (IC x OC x K x K)
                                weight_val = win_memory[ic*output_channel*kernel_size*kernel_size + oc*kernel_size*kernel_size + m*kernel_size + n];
                                
                                // MAC 연산
                                sum = sum + (ifmap_val * weight_val);
                            end
                        end
                    end // End of Input Channel loop
                    
                    // 3. 최종 계산된 sum 값을 ref_output 메모리에 저장
                    // 출력 규격: 행 x 렬 x 출력채널 (H x W x OC)
                    // 인덱스: (출력행 * OW * OC) + (출력열 * OC) + 출력채널
                    sum = sum + win_memory[input_channel * output_channel * kernel_size * kernel_size + oc];
                    ref_out[i*output_width*output_channel + j*output_channel + oc] = sum;
                    
                end
            end
        end // End of Output Channel loop
    end
    
    // read input feature map data 
    always @ (posedge clk) begin
        if(1 && img_ready) i_addra <= i_addra+1;
    end
    assign din=din_memory[i_addra];
    
    // read weight data 
    always @ (posedge clk) begin
        if(1 && fil_ready) w_addra <= w_addra+1;
    end
    assign win=win_memory[w_addra];
    
    //write to output memory
    always @ (posedge clk) begin
        if(output_valid && 1) begin
            dout_memory[o_addra] <= dout;
            o_addra <= o_addra + 1;
        end
    end
    
    convolution u_convolution (
        .clk                 (clk),
        .resetn              (rst),
        
        .start               (start),
        .eoc                 (eoc),
        .IMAGE_WIDTH         (img_width_reg),
        .INPUT_CHANNEL       (input_channel_reg),
        .OUTPUT_CHANNEL      (output_channel_reg),
        .STRIDE              (stride_reg),
        .PADDING             (padding_reg),
        
        .IMAGE_RAM_DIN       (din),
        .IMAGE_VALID         (1'b1),
        .IMAGE_LAST          (), //X
        .IMAGE_READY         (img_ready),
        
        .FILTER_RAM_DIN      (win),
        .FILTER_VALID        (1'b1),
        .FILTER_LAST         (), //X
        .FILTER_READY        (fil_ready),
        
        .FEATURE_RAM_DOUT    (dout),
        .OUTPUT_VALID        (output_valid),
        .OUTPUT_LAST         (output_last),
        .OUTPUT_READY        (1'b1)
    );  

endmodule
