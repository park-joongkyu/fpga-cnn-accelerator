
module MAC9
#(
    parameter WIDTH = 3,
    parameter BIT_WIDTH = 8
)(
    input wire clk,
    input wire resetn,
    input wire [1:0] load_mode,
    input wire mac_en,
    input wire signed [BIT_WIDTH*WIDTH*WIDTH-1:0] filter_in,
    input wire signed [BIT_WIDTH-1:0] image_col_in [0:WIDTH-1],
    output reg signed [31:0] mac_result,
    output reg mac_valid_pre
);

    localparam LOAD_NONE=2'd0,
               LOAD_FILTER=2'd1,
               LOAD_IMAGE_COL=2'd2;
    
    reg signed [BIT_WIDTH*WIDTH*WIDTH-1:0] filter_reg; // 필터 프리 로드 저장소
    wire signed [BIT_WIDTH-1:0] filter [0:WIDTH-1][0:WIDTH-1];
    reg signed [BIT_WIDTH-1:0] image_reg [0:WIDTH-1][0:WIDTH-1]; // 시프트 윈도우 3x3 

    reg signed [2*BIT_WIDTH-1:0] products [0:WIDTH-1][0:WIDTH-1];
    reg signed [2*BIT_WIDTH-1+WIDTH:0] partial_sums [0:WIDTH-1];
    reg mac_en_delayed;
    
    ////// Comb Logic //////
    genvar r,c;
    generate
        for(r=0; r<WIDTH; r=r+1) begin
            for(c=0; c<WIDTH; c=c+1) begin
                assign filter[r][c]=filter_reg[BIT_WIDTH*(r*WIDTH+c) +: BIT_WIDTH]; 
            end
        end    
    endgenerate
        
    ////// Seq Logic //////
    //// LOAD ////
    integer i,j;
    always @(posedge clk) begin 
        if(!resetn) begin
            for (i=0; i<WIDTH; i=i+1) begin
                for (j=0; j<WIDTH; j=j+1) begin
                    image_reg[i][j] <= 0;
                end
            end
            for (i=0; i<WIDTH*WIDTH; i=i+1) begin
                filter_reg[i] <= 0;
            end
        end
        
        else if(load_mode==LOAD_FILTER) begin
            filter_reg <= filter_in; //메인 외부버퍼에 저장되어 있으므로 한번에 서브 로딩 
        end
        
        else if(load_mode==LOAD_IMAGE_COL) begin
            for(i=0; i<WIDTH; i=i+1) begin
                for (j=0; j<WIDTH-1; j=j+1) begin
                    image_reg[i][j] <= image_reg[i][j+1]; // 시프트 방식으로 3x1씩 들어오는 이미지 데이터 3x3까지 모으기
                end
                image_reg[i][WIDTH-1] <= image_col_in[i];
            end
        end
    end

    //// MAC ////
    always @(posedge clk) begin
        if(!resetn) begin
            for (i=0; i<WIDTH; i=i+1) begin
                for (j=0; j<WIDTH; j=j+1) begin
                    products[i][j] <= 0;
                end
                partial_sums[i] <= 0;
            end
            mac_en_delayed <= 0;
            mac_result <= 0;
            mac_valid_pre <= 0;
        end
        
        else begin // 곱셈과 덧셈 분리한 파이프라인 + 덧셈은 2stage 애더 트리로 또 분리
            //STAGE 0 : MULT
            for (i=0; i<WIDTH; i=i+1) begin
                for (j=0; j<WIDTH; j=j+1) begin
                    products[i][j] <= image_reg[i][j] * filter[i][j];
                end
            end

            //STAGE 1 : 3 PARTIAL SUM
            for (i=0; i<WIDTH; i=i+1) begin
                partial_sums[i] <= products[i][0] + products[i][1] + products[i][2];
            end

            //STAGE 2 : TOTAL SUM
            mac_result <= partial_sums[0] + partial_sums[1] + partial_sums[2];

        mac_en_delayed <= mac_en;
        mac_valid_pre <= mac_en_delayed;
        end
    end
    
endmodule