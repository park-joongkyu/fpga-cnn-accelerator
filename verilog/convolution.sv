
module convolution
#(
    parameter FILTER_WIDTH = 3, //상수
    parameter BIT_WIDTH = 8 //양자화 비트수 상수
)
(
    input wire clk,
    input wire resetn,
    
    // Control Signals (from AXI-Lite Wrapper)
    input wire         start, 
    output wire        eoc,  
    input wire [31:0] IMAGE_WIDTH, //인풋 파라미터
    input wire [31:0] INPUT_CHANNEL, //인풋 파라미터 
    input wire [31:0] OUTPUT_CHANNEL, //인풋 파라미터
	input wire [31:0] STRIDE, //인풋 파라미터
    input wire [31:0] PADDING, //인풋 파라미터
    
    // AXI-Stream Input Interface (from DMA)
    input wire signed [BIT_WIDTH-1:0] IMAGE_RAM_DIN, //s_axis_tdata
    input wire IMAGE_VALID, //s_axis_tvalid
    input wire IMAGE_LAST, //s_axis_tlast 사용 x
    output reg IMAGE_READY, //s_axis_tready

    input wire signed [31:0] FILTER_RAM_DIN, //외부로부터 이미지와 바이어스+필터를 받음
    input wire FILTER_VALID, 
    input wire FILTER_LAST, //사용 x
    output reg FILTER_READY,
    
    // AXI-Stream Output Interface (to DMA)
    output wire signed [31:0] FEATURE_RAM_DOUT, //m_axis_tdata,
    output reg OUTPUT_VALID, //m_axis_tvalid,
    output wire OUTPUT_LAST, //m_axis_tlast,
    input wire OUTPUT_READY //m_axis_tready,
);  
    localparam FILTER_LIMIT = 512, //상수
               IMAGE_WIDTH_LIMIT = 32, //상수
               PADDING_LIMIT = 2, //상수
               MAC_UNIT = 16, //상수
               FB_CNT_COL_WIDTH=$clog2(MAC_UNIT), //상수
               FB_CNT_ROW_WIDTH=$clog2(FILTER_LIMIT/MAC_UNIT), //상수
               IMAGE_CNT_WIDTH=$clog2(IMAGE_WIDTH_LIMIT); //상수
               
    localparam BEFORE_START=4'd0, //시작 전
               IDLE=4'd1,
               READ_BIAS=4'd2, //모든 필터의 bias를 먼저 따로 전부 로드
	           READ_FILTER=4'd3, //필터 한채널 프리 로드 
	           RUN_1=4'd4, //img cnt를 보고 ready를 켤지 말지 선택하는 상태
	           RUN_2=4'd5, //din buffer에 0 혹은 읽어온 img를 저장하고 시프트하는 상태
	           RUN_3=4'd6, //MAC unit이 동작하는 상태 
	           PRE_SEND_OUTPUT=4'd7, //출력 타이밍 용
	           SEND_OUTPUT=4'd8, //출력
	           EOC=4'd9;
	

    reg signed [BIT_WIDTH-1:0] shift_buffer [0:FILTER_WIDTH-2][0:IMAGE_WIDTH_LIMIT + 2*PADDING_LIMIT - 1]; //최소면적 이미지 버퍼 (패딩=2까지 지원)
    reg signed [BIT_WIDTH-1:0] DIN_buffer;
    
    wire signed [BIT_WIDTH-1:0] image_col_in [0:FILTER_WIDTH-1]; //MAC9와 연결된 배선은 고정되어 있음. (동적인덱싱 & 느린 mux 대신, 시프트 버퍼의 매번 고정된 위치의 3x1을 MAC9로 보내고 시프트 버퍼를 이동시키는 아이디어) 
    wire [MAC_UNIT-1:0] mac_valid_pre;
       
    reg signed [BIT_WIDTH-1:0] one_filter [0:FILTER_WIDTH*FILTER_WIDTH-1]; 
    wire signed [BIT_WIDTH*FILTER_WIDTH*FILTER_WIDTH-1:0] fb_din; //8비트 3x3 flatten little endian
    reg [FB_CNT_ROW_WIDTH-1:0] fb_addr;
    reg [MAC_UNIT-1:0] fb_wen;
    wire signed [BIT_WIDTH*FILTER_WIDTH*FILTER_WIDTH-1:0] fb_dout [0:MAC_UNIT-1];
    
    reg signed [31:0] bb_din; //32비트, aka. one_bias
    reg [FB_CNT_ROW_WIDTH-1:0] bb_addr;
    reg [MAC_UNIT-1:0] bb_wen;
    wire signed [31:0] bb_dout [0:MAC_UNIT-1]; //32비트
      
    reg [3:0] state;
    
    // 구현을 위한 각종 제어용 플래그
    reg [1:0] load_mode;
    reg mac_en, mac_en_delayed;
    
    wire signed [31:0] mac_result [0:MAC_UNIT-1];

    reg [FB_CNT_ROW_WIDTH:0] fb_row_cnt; //filter cnt
    reg [FB_CNT_COL_WIDTH-1:0] fb_col_cnt;
    reg [FILTER_WIDTH*FILTER_WIDTH-1:0] fb_data_cnt;
    
    reg [FB_CNT_ROW_WIDTH:0] bb_row_cnt; //bias cnt
    reg [FB_CNT_COL_WIDTH-1:0] bb_col_cnt;
      
    reg [IMAGE_CNT_WIDTH:0] img_row_cnt; //image cnt
    reg [IMAGE_CNT_WIDTH:0] img_col_cnt;
    
    reg [IMAGE_CNT_WIDTH:0] str_row_cnt; //stride cnt
    reg [IMAGE_CNT_WIDTH:0] str_col_cnt;

    reg [FB_CNT_ROW_WIDTH:0] output_row_cnt; //output cnt
    reg [FB_CNT_COL_WIDTH-1:0] output_col_cnt;
 
    reg signed [31:0] fifo_reg [0:MAC_UNIT-1]; //16개 x 32비트
    wire signed [31:0] fifo_dout [0:MAC_UNIT-1];
    wire [MAC_UNIT*32-1:0] fifo_reg_combined;
    wire [MAC_UNIT*32-1:0] fifo_dout_combined;
    
    reg fifo_wr_en;
    reg fifo_rd_en;
    wire fifo_empty;
    
    reg [9:0] used_filter; //512까지 표현 가능해야함
    reg [9:0] channel_cnt; //일단 해두고 더 늘림 
    reg save_pipe1;
    reg signed [BIT_WIDTH-1:0] new_img;
    
    
    assign eoc=(state==EOC);
    assign FEATURE_RAM_DOUT=fifo_reg[0]; 
    
    integer i,j,l,n;
    
    genvar k;
    generate
        for (k=0; k<MAC_UNIT; k=k+1) begin
            assign fifo_reg_combined[32*k +: 32] = fifo_reg[k];
            assign fifo_dout[k]=fifo_dout_combined[32*k +: 32];
        end
    endgenerate
    
    generate
        for (k=0; k<FILTER_WIDTH*FILTER_WIDTH; k=k+1) begin
            assign fb_din[BIT_WIDTH*k +: BIT_WIDTH] = one_filter[k];
        end
    endgenerate
    
    generate
        for(k=0; k<FILTER_WIDTH-1; k=k+1) begin 
            assign image_col_in[k] = shift_buffer[k][FILTER_WIDTH-1]; //image_col_in은 MAC9와 연결되는데, 이는 시프트 버퍼의 특정 위치에 고정
        end
    endgenerate
    assign image_col_in[FILTER_WIDTH-1] = DIN_buffer;
    
    always @(posedge clk) begin
        if(!resetn) mac_en_delayed <= 0;
        else mac_en_delayed <= mac_en; //연산 타이밍 맞추기 위함
    end
    
    
    //// FSM ////
    always @(posedge clk) begin
        if (!resetn) begin
            state <= 0;
            for(i=0; i<FILTER_WIDTH; i=i+1) begin
                for(j=0; j<IMAGE_WIDTH_LIMIT + 2*PADDING_LIMIT; j=j+1) begin
                    shift_buffer[i][j] <= 0;
                end
            end
            load_mode <= 0;
            mac_en <= 0;
            fb_row_cnt <= 0;
            fb_col_cnt <= 0;
            fb_data_cnt <= 0;
            bb_row_cnt <= 0;
            bb_col_cnt <= 0;
            img_row_cnt <= 0;
            img_col_cnt <= 0;
            IMAGE_READY <= 0;
            FILTER_READY <= 0;
            OUTPUT_VALID <= 0;
            fifo_wr_en <= 0;
            fifo_rd_en <= 0;
            fb_addr <= 0;
            fb_wen <= 0;
            bb_addr <= 0;
            bb_wen <= 0;
            save_pipe1 <= 0;
            used_filter <= 0;
            channel_cnt <= 0;
            str_row_cnt <= 0;
            str_col_cnt <= 0;
            output_row_cnt <= 0;
            output_col_cnt <= 0;
        end 
        else begin
            case (state)
                BEFORE_START: begin
                    channel_cnt <= 0;
                    if(start) state <= IDLE;
                end
                
                IDLE: begin
                    for(i=0; i<FILTER_WIDTH; i=i+1) begin
                        for(j=0; j<IMAGE_WIDTH_LIMIT + 2*PADDING_LIMIT; j=j+1) begin
                            shift_buffer[i][j] <= 0;
                        end
                    end
                    load_mode <= 0;
                    mac_en <= 0;
                    fb_row_cnt <= 0;
                    fb_col_cnt <= 0;
                    fb_data_cnt <= 0;
                    bb_row_cnt <= 0;
                    bb_col_cnt <= 0;
                    img_row_cnt <= 0;
                    img_col_cnt <= 0;
                    IMAGE_READY <= 0;
                    FILTER_READY <= 0;
                    OUTPUT_VALID <= 0;
                    fifo_wr_en <= 0;
                    fifo_rd_en <= 0;
                    fb_addr <= 0;
                    fb_wen <= 0;
                    bb_addr <= 0;
                    bb_wen <= 0;
                    save_pipe1 <= 0;
                    used_filter <= 0;
                    str_row_cnt <= 0;
                    str_col_cnt <= 0;
                    output_row_cnt <= 0;
                    output_col_cnt <= 0;
                    state <= READ_FILTER;
                end
                
                READ_FILTER: begin //필터 주소 하나씩 올려가며 읽어와서 필터 버퍼에 저장          
                    if(fb_row_cnt*MAC_UNIT + fb_col_cnt == OUTPUT_CHANNEL) begin //프리로드 종료 조건 -> 문제시 비트 배수판단법으로 변경
                        fb_addr <= 0; //bram 주소 초기화
                        fb_wen <= 0;
                        state <= RUN_1;
                    end
                    else begin
                        FILTER_READY <= 1;
                        
                        if(FILTER_VALID && FILTER_READY) begin //valid와 ready 둘다 1이면
                            //FILTER_READY <= 0 // 여기서는 ready를 내리지 말고 매 사이클 받도록 허용
                            one_filter[fb_data_cnt] <= FILTER_RAM_DIN; 
                            
                            // 구현 및 제어를 위한 카운터 
                            if(fb_data_cnt == FILTER_WIDTH*FILTER_WIDTH-1) begin
                                //마지막 데이터 가져옴과 동시에 ready 내려야함
                                if(fb_row_cnt*MAC_UNIT + fb_col_cnt == OUTPUT_CHANNEL-1) FILTER_READY <= 0; //종료조건 여기로 옮겨도 됨, 대신 다음 상태가면 wen 꺼야함
                                
                                fb_data_cnt <= 0;
                                //one_filter는 타이밍 맞게 준비될 예정
                                fb_addr <= fb_row_cnt; 
                                fb_wen[fb_col_cnt] <= 1; //하나씩 준비되는대로 최대 32행 16열에 차곡차곡 저장
                                
                                if(fb_col_cnt == MAC_UNIT-1) begin
                                    fb_col_cnt <= 0;
                                    if (fb_row_cnt == FILTER_LIMIT/MAC_UNIT) begin // FILTER_LIMIT/MAC_UNIT-1 까지만 허용 하면 가득찰때 종료조건 계산 오류 
                                        fb_row_cnt <= 0;
                                    end 
                                    else fb_row_cnt <= fb_row_cnt + 1;
                                end 
                                else fb_col_cnt <= fb_col_cnt + 1;
                            end        
                            else begin
                                fb_wen <= 0;
                                fb_data_cnt <= fb_data_cnt + 1;
                            end
                        end
                    end
                end
                
                RUN_1: begin //패딩인지, 이미지 읽어와야 할지 결정. 패딩을 위한 버퍼까지 다 준비해두고 인풋 패딩 변수에 따라 0을 넣을지 이미지를 넣을지 결정
                    load_mode <= 0;
                    if(img_row_cnt<PADDING || img_row_cnt>IMAGE_WIDTH-1+PADDING || img_col_cnt<PADDING || img_col_cnt>IMAGE_WIDTH-1+PADDING) begin //패딩이면
                        new_img <= 0; //제로 패딩
                        state <= RUN_2; //바로 넘어감
                    end
                    else IMAGE_READY <= 1; //이미지 읽어와야 한다면 ready 올리고 대기
                    
                    if(IMAGE_VALID && IMAGE_READY) begin //valid와 ready가 둘다 1인 엣지에
                        IMAGE_READY <= 0;
                        new_img <= IMAGE_RAM_DIN; //읽어온 이미지 픽셀  
                        state <= RUN_2;
                    end
                end
                
                RUN_2: begin //이미지 버퍼에 넣기
                    
                    // 메인 아이디어 : 가능한 최소 면적, DRAM 접근 최소화(데이터 재사용 최대화), path 딜레이 최소화(mux 없이 고정된 위치의 값만 MAC9와 연결) 
                    for(i=0; i<FILTER_WIDTH-1; i=i+1) begin
                        for(j=0; j<IMAGE_WIDTH_LIMIT + 2*PADDING_LIMIT - 1; j=j+1) begin
                            if(j==FILTER_WIDTH-2) begin
                                if(i==FILTER_WIDTH-2) shift_buffer[i][j] <= DIN_buffer;
                                else shift_buffer[i][j] <= shift_buffer[i+1][j+1];
                            end
                            else shift_buffer[i][j] <= shift_buffer[i][j+1];
                        end 
                        shift_buffer[i][IMAGE_WIDTH_LIMIT-1 + 2*PADDING_LIMIT] <= shift_buffer[i][0];
                        
                        //안전하게 모든 경우 직접 기술, 이미지 크기와 패딩에 따라 시프트 버퍼 배선의 mux가 결정됨 
                        for(n=0; n<=PADDING_LIMIT; n=n+1) begin
                            for(l=1; l<=IMAGE_WIDTH_LIMIT; l=l+1) begin
                                if(PADDING==n && IMAGE_WIDTH==l) shift_buffer[i][l-1+2*n] <= shift_buffer[i][0]; //모든 경우가 다 합성되고, 입력에 맞는 통로가 열리는 셈
                            end
                        end 
                    end
                    DIN_buffer <= new_img;                 
                        
                    load_mode <= 2; //이미지버퍼를 만드는 지금 타이밍에 load_mode를 같이 켜줘야 다음 사이클에 바로 유닛이 이미지 로드함 
                    
                    // 주소 올리기
                    if(img_col_cnt == IMAGE_WIDTH + 2*PADDING - 1) begin
                        img_col_cnt <= 0;
                        if (img_row_cnt == IMAGE_WIDTH + 2*PADDING - 1) begin
                            img_row_cnt <= 0;
                        end 
                        else img_row_cnt <= img_row_cnt + 1;
                    end 
                    else img_col_cnt <= img_col_cnt + 1;     
                    
                    if(img_row_cnt>=FILTER_WIDTH-1 && img_col_cnt>=FILTER_WIDTH-1) begin //지금 넣는 이미지가 2행 이상 2열 이상이면  
                        if(str_row_cnt==0 && str_col_cnt==0) begin //str이 0,0일때만 mac 찍으러 갈 것임. 카운터로 구현
                            fb_addr <= 0; //필터 bram의 처음 출력을 미리 뽑아 타이밍 맞춤
                            state <= RUN_3; //타당한 윈도우 완성되는 경우 
                        end
                        else begin
                            if(img_row_cnt==IMAGE_WIDTH + 2*PADDING - 1 && img_col_cnt==IMAGE_WIDTH + 2*PADDING - 1) begin //마지막 이미지 행렬셀인데 타당하지 않아 뒷 상태로 가지 못해 종료를 못하는 경우 방지
                                if(channel_cnt==INPUT_CHANNEL-1) begin
                                    state <= READ_BIAS;
                                end
                                else begin
                                    channel_cnt <= channel_cnt + 1; //마지막 입력 채널이 아니면 1 올리고 맨처음으로가서 다음 입력채널의 필터리드 
                                    state <= IDLE;
                                end
                            end    
                            else state <= RUN_1; //2행 2열 안이지만 stride 조건에 의해 타당하지 않은 경우면서 마지막 이미지 행렬셀은 아닌 경우
                        end
                        
                        // stride 카운터
                        if(img_col_cnt==IMAGE_WIDTH + 2*PADDING - 1) begin 
                            str_col_cnt <= 0;
                            if (img_row_cnt==IMAGE_WIDTH + 2*PADDING - 1) begin
                                str_row_cnt <= 0;
                            end 
                            else begin
                                if(str_row_cnt == STRIDE-1) str_row_cnt <= 0;
                                else str_row_cnt <= str_row_cnt + 1;
                            end
                        end 
                        else begin
                            if(str_col_cnt == STRIDE-1) str_col_cnt <= 0;
                            else str_col_cnt <= str_col_cnt + 1;     
                        end
                       
                    end
                    else state <= RUN_1; //2행 2열 밖이라 타당한 윈도우 완성 안되는 경우
                end
                
                RUN_3: begin // MAC unit 동작시키기
                     if(used_filter >= OUTPUT_CHANNEL) begin //현재 행렬셀의 모든 필터 다 처리함
                        load_mode <= 0;
                        fb_addr <= 0; //원래는 한타임 일찍 꺼줘야 맞는데 어차피 읽기만 하는거라 상관없음
                        mac_en <= 0;
                     end
                     else begin
                        used_filter <= used_filter + MAC_UNIT;
                        load_mode <= 1; //필터 각 유닛에 서브로드 
                        fb_addr <= fb_addr+1; //시작 타이밍 잘 맞췄으니 이제 하나씩 올리면 됨
                        mac_en <= 1; //mac 시작은 이거 한타임 이후에 하게 됨
                    end
                    
                    
                    save_pipe1 <= mac_valid_pre[0];

                    
                    if(mac_valid_pre[0]) begin //어차피 동일하니 0이 대표로
                        if(channel_cnt!=0) fifo_rd_en <= 1; //한타임 미리 켜줘서 타이밍 맞춤
                        else fifo_rd_en <= 0;
                    end      
                    else fifo_rd_en <= 0;
                     
                    if(save_pipe1) begin //이때부터 mac result가 valid함 
                        for(i=0; i<MAC_UNIT; i=i+1) begin
                            if(channel_cnt!=0) fifo_reg[i] <= mac_result[i] + fifo_dout[i]; //fifo 출력을 mac result와 합한 데이터 준비
                            else fifo_reg[i] <= mac_result[i];
                        end
                        fifo_wr_en <= 1; //다음 타이밍에 fifo에 저장되도록
                    end                    
                    else begin
                        if(fifo_wr_en) begin //save_pipe1이 0이고 fifo_wr_en이 1인 순간이 이번셀 마지막 mac결과 저장순간이므로 저장하면서 상태 전이 
                            used_filter <= 0; //초기화
                            if(img_row_cnt==0 && img_col_cnt==0) begin //마지막 이미지 행렬셀 이라면 카운터가 지금 0,0으로 가있게 됨
                                if(channel_cnt==INPUT_CHANNEL-1) begin
                                    state <= READ_BIAS; //그와중에 마지막 입력 채널이었다면 끝
                                end
                                else begin
                                    channel_cnt <= channel_cnt + 1; //마지막 입력 채널이 아니면 1 올리고 맨처음으로가서 다음 입력채널의 필터리드 
                                    state <= IDLE;
                                end
                            end
                            else state <= RUN_1; //계속 이번 입력 채널 이미지 셀 받으러 
                        end
                        
                        fifo_wr_en <= 0; //타이밍 맞춰 마지막 저장될때 꺼지게
                    end  
                end
                
                READ_BIAS: begin //필터 주소 하나씩 올려가며 읽어와서 필터 버퍼에 저장          
                    if(bb_row_cnt*MAC_UNIT + bb_col_cnt == OUTPUT_CHANNEL) begin //바이어스 리드 종료 조건 -> 문제시 비트 배수판단법으로 변경
                        bb_addr <= 0; //bias 더하기 위해 2사이클 전 미리 0으로
                        bb_wen <= 0;
                        state <= PRE_SEND_OUTPUT;
                    end
                    else begin
                        FILTER_READY <= 1;
                        
                        if(FILTER_VALID && FILTER_READY) begin //valid와 ready 둘다 1이면
                            //FILTER_READY <= 0 // 여기서는 ready를 내리지 말고 매 사이클 받도록 허용
                            bb_din <= FILTER_RAM_DIN; 

                            // 구현 및 제어를 위한 카운터 
                            //마지막 데이터 가져옴과 동시에 ready 내려야함
                            if(bb_row_cnt*MAC_UNIT + bb_col_cnt == OUTPUT_CHANNEL-1) FILTER_READY <= 0; //종료조건 여기로 옮겨도 됨, 대신 다음 상태가면 wen 꺼야함
                            
                            bb_addr <= bb_row_cnt; 
                            bb_wen <= 0; //default
                            bb_wen[bb_col_cnt] <= 1; //하나씩 준비되는대로 최대 32행 16열에 차곡차곡 저장
                            
                            if(bb_col_cnt == MAC_UNIT-1) begin
                                bb_col_cnt <= 0;
                                if (bb_row_cnt == FILTER_LIMIT/MAC_UNIT) begin // FILTER_LIMIT/MAC_UNIT-1 까지만 허용 하면 가득찰때 종료조건 계산 오류 
                                    bb_row_cnt <= 0;
                                end 
                                else bb_row_cnt <= bb_row_cnt + 1;
                            end 
                            else bb_col_cnt <= bb_col_cnt + 1;
                        end        

                    end
                end
                
                PRE_SEND_OUTPUT: begin //bram 타이밍 맞추기 위한 더미 state 
                    fifo_rd_en <= 1; //얘는 한타임 전에 올려줘야 맞음
                    state <= SEND_OUTPUT;
                end
                
                SEND_OUTPUT: begin //출력 스트리밍 
                    if(OUTPUT_VALID==0) begin //처음 혹은 한 행렬셀의 16개 데이터가 나간 후마다
                        for(i=0; i<MAC_UNIT; i=i+1) begin
                            fifo_reg[i] <= fifo_dout[i] + bb_dout[i]; //fifo에서 빼서 reg에 저장, 이때 대응되는 bias를 더해준다
                            bb_addr <= bb_addr + 1; //bb_addr은 데이터를 사용하기 '2사이클' 이전에 설정되어야 함. 지금 바꾸면 빨라봐야 2사이클후에 여기 다시오니 만족
                        end
                        fifo_rd_en <= 0; //한타임 전에 켜둔게 지금 인식되며 data를 캡쳐하므로 꺼준다.
                        OUTPUT_VALID <= 1; //가져가길 허용
                    end
                    else begin
                        if(OUTPUT_VALID && OUTPUT_READY) begin 
                            //밖에선 fifo_reg 맨 앞 32비트 가져감, 시프트
                            for(i=0; i<MAC_UNIT-1; i=i+1) begin
                                fifo_reg[i] <= fifo_reg[i+1]; 
                            end
                            fifo_reg[MAC_UNIT-1] <= 32'd0;
                            
                            //제어용 기본 카운터
                            if(output_col_cnt==MAC_UNIT-1) begin
                                output_col_cnt <= 0;
                                output_row_cnt <= output_row_cnt + 1;
                            end
                            else output_col_cnt <= output_col_cnt + 1;
                                        
                            if(output_row_cnt*MAC_UNIT + output_col_cnt==OUTPUT_CHANNEL-1) begin //이번 행렬셀의 마지막 피쳐맵의 셀을 가져가는 순간
                                output_row_cnt <= 0; //0으로
                                output_col_cnt <= 0; //0으로
                                OUTPUT_VALID <= 0;
                                if(fifo_empty) state <= EOC; //최종 종료
                                else begin
                                    bb_addr <= 0; //다시 옆 행렬셀 첫 한 단위 피쳐맵 세트로
                                    state <= PRE_SEND_OUTPUT;        
                                end
                            end
                            else begin
                                if(output_col_cnt==MAC_UNIT-1) begin //fifo 한 단위의 마지막을 가져가는 순간 
                                    output_col_cnt <= 0;
                                    OUTPUT_VALID <= 0; 
                                    if(fifo_empty) state <= EOC; //최종 종료. 이미 위에 있어서 없어도 되긴 할듯
                                    else fifo_rd_en <= 1;                    
                                end
                            end
                            
                        end
                    end
                end 
                EOC: begin
                    state <= BEFORE_START;
                end
            endcase
        end
    end
    
    assign OUTPUT_LAST=(output_row_cnt*MAC_UNIT + output_col_cnt==OUTPUT_CHANNEL-1) && fifo_empty;
    
    generate
        for(k=0; k<MAC_UNIT; k=k+1) begin
            MAC9 #(
                .WIDTH(FILTER_WIDTH),
                .BIT_WIDTH(BIT_WIDTH)
            ) U_MAC9(
                .clk(clk),
                .resetn(resetn),
                .load_mode(load_mode), //1이면 필터 로드, 2면 3x1 이미지 열 로드 
                .mac_en(mac_en_delayed),
                .filter_in(fb_dout[k]),
                .image_col_in(image_col_in),
                .mac_result(mac_result[k]),
                .mac_valid_pre(mac_valid_pre[k])
            );
        end
    endgenerate
    
    fifo_0 TEMP_FEATURE_MAP (
        .clk(clk),      // input wire clk
        .srst(!resetn),    // input wire srst
        .din(fifo_reg_combined),      // input wire [511 : 0] din
        .wr_en(fifo_wr_en),  // input wire wr_en
        .rd_en(fifo_rd_en),  // input wire rd_en
        .dout(fifo_dout_combined),    // output wire [511 : 0] dout
        .full(),    // output wire full
        .empty(fifo_empty)  // output wire empty
    );
    
    generate
        for(k=0; k<MAC_UNIT; k=k+1) begin
            bram_32x72 FILTER_BRAM ( //32행이고 한주소당 1필터=9숫자=72비트, 가 16=MAC_UNIT열 있음, 만약 MAC_UNIT 늘린다면 행이 줄을 것
                .clka(clk),    // input wire clka
                .wea(fb_wen[k]),      // input wire [0 : 0] wea
                .addra(fb_addr),  // input wire [4 : 0] addra
                .dina(fb_din),    // input wire [71 : 0] dina
                .douta(fb_dout[k])  // output wire [71 : 0] douta
            );
        end
    endgenerate
    
    generate
        for(k=0; k<MAC_UNIT; k=k+1) begin
            bram_32x32 BIAS_BRAM ( //32행이고 한주소당 1바이어스=1숫자=32비트, 가 16=MAC_UNIT열 있음, 만약 MAC_UNIT 늘린다면 행이 줄을 것
                .clka(clk),    // input wire clka
                .wea(bb_wen[k]),      // input wire [0 : 0] wea
                .addra(bb_addr),  // input wire [4 : 0] addra
                .dina(bb_din),    // input wire [31 : 0] dina
                .douta(bb_dout[k])  // output wire [31 : 0] douta
            );
        end
    endgenerate

endmodule