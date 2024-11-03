package DataStreamerVN;

import BlueAXI::*;
import DReg::*;
import FIFO::*;
import Vector::*;
import GetPut::*;

interface DataStreamerVN;
    (* prefix = "M_AXIS_AIE_X" *) interface AXI4_Stream_Wr_Fab#(AXIS_AIE_DATA_WIDTH, 0) m_axis_aie_x;
    (* prefix = "M_AXIS_AIE_Y" *) interface AXI4_Stream_Wr_Fab#(AXIS_AIE_DATA_WIDTH, 0) m_axis_aie_y;
    (* prefix = "S_AXIS_AIE" *) interface AXI4_Stream_Rd_Fab#(AXIS_AIE_DATA_WIDTH, 0) s_axis_aie;
    (* prefix = "M_AXIS_DMA" *) interface AXI4_Stream_Wr_Fab#(AXIS_DMA_DATA_WIDTH, 0) m_axis_dma;
    (* prefix = "S_AXIS_DMA" *) interface AXI4_Stream_Rd_Fab#(AXIS_DMA_DATA_WIDTH, 0) s_axis_dma;
    (* prefix = "S_AXI_LITE" *) interface AXI4_Lite_Slave_Rd_Fab#(AXI_SLAVE_ADDR_WIDTH, AXI_SLAVE_DATA_WIDTH) s_lite_rd;
    (* prefix = "S_AXI_LITE" *) interface AXI4_Lite_Slave_Wr_Fab#(AXI_SLAVE_ADDR_WIDTH, AXI_SLAVE_DATA_WIDTH) s_lite_wr;
    (* always_ready *) method Bool interrupt();
endinterface

typedef 512 AXIS_DMA_DATA_WIDTH;
typedef 128 AXIS_AIE_DATA_WIDTH;
typedef 12 AXI_SLAVE_ADDR_WIDTH;
typedef 64 AXI_SLAVE_DATA_WIDTH;
typedef TDiv#(AXIS_DMA_DATA_WIDTH, AXIS_AIE_DATA_WIDTH) AIE_BEATS_PER_DMA_BEAT;
typedef TDiv#(AIE_BEATS_PER_DMA_BEAT, 2) AIE_BEATS_PER_DMA_BEAT_HALF;
typedef TDiv#(AXIS_DMA_DATA_WIDTH, 32) WORDS_PER_DMA_BEAT;
typedef TDiv#(AXIS_AIE_DATA_WIDTH, 32) WORDS_PER_AIE_BEAT;
typedef 16 FIFO_SIZE;

typedef enum {IDLE, RUNNING} State deriving (Bits, Eq, FShow);

(* default_clock_osc = "aclk", default_reset = "aresetn" *)
module mkDataStreamerVN(DataStreamerVN);
    let m_axis_aie_x_inst <- mkAXI4_Stream_Wr(2);
    let m_axis_aie_y_inst <- mkAXI4_Stream_Wr(2);
    let s_axis_aie_inst <- mkAXI4_Stream_Rd(2);
    let m_axis_dma_inst <- mkAXI4_Stream_Wr(2);
    let s_axis_dma_inst <- mkAXI4_Stream_Rd(2);
    Reg#(Bool) start <- mkDReg(False);
    Reg#(Bit#(AXI_SLAVE_DATA_WIDTH)) result <- mkReg(0);
    Reg#(Bit#(AXI_SLAVE_DATA_WIDTH)) samples <- mkReg(0);
    List#(RegisterOperator#(axiAddrWidth, AXI_SLAVE_DATA_WIDTH)) operators = Nil;
    operators = registerHandler('h00, start, operators);
    operators = registerHandlerRO('h10, result, operators);
    operators = registerHandler('h20, samples, operators);
    let s_lite_inst <- mkGenericAxi4LiteSlave(operators, 1, 1);
    Reg#(Bool) interruptDReg <- mkDReg(False);

    Reg#(State) state <- mkReg(IDLE);
    Reg#(UInt#(32)) outstandingResultBeats <- mkReg(0);
    rule initModule if (state == IDLE && start);
        state <= RUNNING;
        result <= 0;
        outstandingResultBeats <= truncate(unpack(samples >> valueOf(TLog#(WORDS_PER_DMA_BEAT))));
    endrule

    rule cycleCount if (state == RUNNING);
        result <= result + 1;
    endrule

    FIFO#(Bit#(AXIS_DMA_DATA_WIDTH)) dmaInFifo <- mkSizedFIFO(valueOf(FIFO_SIZE));
    rule receiveDMABeat;
        let p <- s_axis_dma_inst.pkg.get();
        dmaInFifo.enq(p.data());
    endrule

    Reg#(UInt#(AIE_BEATS_PER_DMA_BEAT_HALF)) deqBeat <- mkReg(0);
    FIFO#(Bit#(TMul#(AXIS_AIE_DATA_WIDTH, 2))) aieOutFifo <- mkFIFO;
    rule splitData;
        Vector#(AIE_BEATS_PER_DMA_BEAT_HALF, Bit#(TMul#(AXIS_AIE_DATA_WIDTH, 2))) v = unpack(dmaInFifo.first());
        aieOutFifo.enq(v[deqBeat]);

        if (deqBeat == fromInteger(valueOf(AIE_BEATS_PER_DMA_BEAT_HALF) - 1)) begin
            dmaInFifo.deq();
            deqBeat <= 0;
        end
        else begin
            deqBeat <= deqBeat + 1;
        end
    endrule

    rule sendAIEBeats;
        Vector#(TMul#(WORDS_PER_AIE_BEAT, 2), Bit#(32)) v = unpack(aieOutFifo.first());
        aieOutFifo.deq();

        // Split floats to 'x' and 'y' streams
        Vector#(WORDS_PER_AIE_BEAT, Bit#(32)) dv0 = newVector;
        Vector#(WORDS_PER_AIE_BEAT, Bit#(32)) dv1 = newVector;
        for (Integer i = 0; i < valueOf(WORDS_PER_AIE_BEAT); i = i + 1) begin
            dv0[i] = v[i * 2];
            dv1[i] = v[i * 2 + 1];
        end

        let p0 = AXI4_Stream_Pkg {
            data: pack(dv0),
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: False
        };
        let p1 = AXI4_Stream_Pkg {
            data: pack(dv1),
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: False
        };
        m_axis_aie_x_inst.pkg.put(p0);
        m_axis_aie_y_inst.pkg.put(p1);
    endrule

    FIFO#(Bit#(AXIS_AIE_DATA_WIDTH)) aieInFifo <- mkFIFO;
    rule receiveAIEBeat;
        let p <- s_axis_aie_inst.pkg.get();
        aieInFifo.enq(p.data());
    endrule

    Reg#(UInt#(TLog#(AIE_BEATS_PER_DMA_BEAT))) enqBeat <- mkReg(0);
    Reg#(Vector#(AIE_BEATS_PER_DMA_BEAT, Bit#(AXIS_AIE_DATA_WIDTH))) outAccReg <- mkReg(unpack(0));
    FIFO#(Bit#(AXIS_DMA_DATA_WIDTH)) dmaOutFifo <- mkSizedFIFO(valueOf(FIFO_SIZE));
    rule accumulateResults;
        let v = outAccReg;
        v[enqBeat] = aieInFifo.first();
        aieInFifo.deq();

        outAccReg <= v;
        if (enqBeat == fromInteger(valueOf(AIE_BEATS_PER_DMA_BEAT) - 1)) begin
            dmaOutFifo.enq(pack(v));
            enqBeat <= 0;
        end
        else begin
            enqBeat <= enqBeat + 1;
        end
    endrule

    rule sendDMABeat if (state == RUNNING && outstandingResultBeats != 0);
        let d = dmaOutFifo.first();
        dmaOutFifo.deq();
        let p = AXI4_Stream_Pkg {
            data: d,
            user: 0,
            keep: unpack(-1),
            dest: 0,
            last: (outstandingResultBeats == 1)
        };
        m_axis_dma_inst.pkg.put(p);
        outstandingResultBeats <= outstandingResultBeats - 1;
    endrule

    rule raiseInterrupt if (state == RUNNING && outstandingResultBeats == 0);
        interruptDReg <= True;
        state <= IDLE;
    endrule

    interface m_axis_aie_x = m_axis_aie_x_inst.fab;
    interface m_axis_aie_y = m_axis_aie_y_inst.fab;
    interface s_axis_aie = s_axis_aie_inst.fab;
    interface m_axis_dma = m_axis_dma_inst.fab;
    interface s_axis_dma = s_axis_dma_inst.fab;
    interface s_lite_rd = s_lite_inst.s_rd;
    interface s_lite_wr = s_lite_inst.s_wr;
    method Bool interrupt = interruptDReg;

endmodule

endpackage
