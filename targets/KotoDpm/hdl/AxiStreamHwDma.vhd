-------------------------------------------------------------------------------
-- Title      : SSI Stream DMA Controller
-- Project    : General Purpose Core
-------------------------------------------------------------------------------
-- File       : AxiStreamDma.vhd
-- Author     : Ryan Herbst, rherbst@slac.stanford.edu
-- Created    : 2014-04-25
-- Last update: 2015-12-18
-- Platform   :
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Generic AXI Stream DMA block for frame at a time transfers.
-------------------------------------------------------------------------------
-- Copyright (c) 2014 by Ryan Herbst. All rights reserved.
-------------------------------------------------------------------------------
-- Modification history:
-- 04/25/2014: created.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;
use work.AxiPkg.all;
use work.AxiDmaPkg.all;

entity AxiStreamHwDma is
   generic (
      TPD_G             : time                 := 1 ns;
      FREE_ADDR_WIDTH_G : integer              := 9;
      AXIL_BASE_ADDR_G  : slv(31 downto 0)     := x"00000000";
      AXI_READY_EN_G    : boolean              := false;
      AXIS_READY_EN_G   : boolean              := false;
      AXIS_CONFIG_G     : AxiStreamConfigType  := AXI_STREAM_CONFIG_INIT_C;
      AXI_CONFIG_G      : AxiConfigType        := AXI_CONFIG_INIT_C;
      AXI_BURST_G       : slv(1 downto 0)      := "01";
      AXI_CACHE_G       : slv(3 downto 0)      := "1111"
   );
   port (

      -- Clock/Reset
      axiClk          : in  sl;   -- connected to sysClk200 (axiDmaClk) as in RceG3DmaAxis
      axiRst          : in  sl;

      obReady         : in  sl;

      -- Register Access & Interrupt
      axilClk         : in  sl;  -- connected sysClk125:  needed for axi Lite signals
      axilRst         : in  sl;
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType;

      -- SSI
      sAxisMaster     : in  AxiStreamMasterType;
      sAxisSlave      : out AxiStreamSlaveType;
      mAxisMaster     : out AxiStreamMasterType;
      mAxisSlave      : in  AxiStreamSlaveType;
      mAxisCtrl       : in  AxiStreamCtrlType;

      -- AXI Interface
      axiReadMaster   : out AxiReadMasterType;
      axiReadSlave    : in  AxiReadSlaveType;
      axiWriteMaster  : out AxiWriteMasterType;
      axiWriteSlave   : in  AxiWriteSlaveType;
      axiWriteCtrl    : in  AxiCtrlType
   );
end AxiStreamHwDma;

architecture structure of AxiStreamHwDma is

   constant countWidth : integer := 10;

   type StateType is (S_IDLE_C, S_WAIT_C, S_FIFO_0_C, S_FIFO_1_C);

   type RegType is record
      maxRxSize     : slv(23 downto 0);
      buffAddr      : slv(31 downto 0);
      fifoLoad      : sl;
      rxEnable      : sl;
      txEnable      : sl;
      fifoClear     : sl;
      axiReadSlave  : AxiLiteReadSlaveType;
      axiWriteSlave : AxiLiteWriteSlaveType;
   end record RegType;

   constant REG_INIT_C : RegType := (
      maxRxSize     => x"000400",
      buffAddr      => x"3F000000",
      fifoLoad      => '0',
      rxEnable      => '0',
      txEnable      => '0',
      fifoClear     => '1',
      axiReadSlave  => AXI_LITE_READ_SLAVE_INIT_C,
      axiWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C
      );

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   type IbType is record
      state         : StateType;
      ibReq         : AxiWriteDmaReqType;
      pendListWrite : sl;
      pendListDin   : slv(31 downto 0);
      freeLoadRead  : sl;
      freeListRead  : sl;
   end record IbType;

   constant IB_INIT_C : IbType := (
      state         => S_IDLE_C,
      ibReq         => AXI_WRITE_DMA_REQ_INIT_C,
      pendListWrite => '0',
      pendListDin   => (others=>'0'),
      freeLoadRead  => '0',
      freeListRead  => '0'
      );

   signal ib   : IbType := IB_INIT_C;
   signal ibin : IbType;

   type ObType is record
      state         : StateType;
      obReq         : AxiReadDmaReqType;
      freeListWrite : sl;
      freeListDin   : slv(31 downto 0);
      freeListCount : slv(countWidth-1 downto 0);
      pendListRead  : sl;
   end record ObType;

   constant OB_INIT_C : ObType := (
      state         => S_IDLE_C,
      obReq         => AXI_READ_DMA_REQ_INIT_C,
      freeListWrite => '0',
      freeListDin   => (others=>'0'),
      freeListCount => (others=>'0'),
      pendListRead  => '0'
      );

   signal ob   : ObType := OB_INIT_C;
   signal obin : ObType;

   signal fifoReset     : sl;
   signal maxSize       : slv(23 downto 0);

   signal freeLoadEmpty : sl;
   signal freeLoadRd    : sl;
   signal freeLoadDout  : slv(31 downto 0);

   signal freeListRd    : sl;
   signal freeListDout  : slv(31 downto 0);
   signal freeListFull  : sl;
   signal freeListEmpty : sl;

   signal pendListRd    : sl;
   signal pendListDout  : slv(31 downto 0);
   signal pendListFull  : sl;
   signal pendListEmpty : sl;

   signal obAck              : AxiReadDmaAckType;
   signal obReq              : AxiReadDmaReqType;
   signal ibAck              : AxiWriteDmaAckType;
   signal ibReq              : AxiWriteDmaReqType;

begin

  U_FreeLoad : entity work.FifoAsync
    generic map (
      TPD_G            => TPD_G,
      FWFT_EN_G        => true,
      DATA_WIDTH_G     => 32,
      ADDR_WIDTH_G     => 10 )
    port map (
      rst        => fifoReset,
      wr_clk     => axilClk,
      wr_en      => r.fifoLoad,
      din        => r.buffAddr,
      rd_clk     => axiClk,
      rd_en      => freeLoadRd,
      dout       => freeLoadDout,
      empty      => freeLoadEmpty );

  U_FreeList : entity work.FifoSync
    generic map (
      TPD_G            => TPD_G,
      FWFT_EN_G        => true,
      DATA_WIDTH_G     => 32,
      ADDR_WIDTH_G     => 10,
--      FULL_THRES_G     =>  3,
--      EMPTY_THRES_G    =>  3 )
      FULL_THRES_G     =>  1,   -- same as pushFifo setting in "AxiLiteFifoPushPushPop"  (unused)
      EMPTY_THRES_G    =>  1 )  -- same as pushFifo setting in "AxiLiteFifoPushPushPop"  (unused)
    port map (
      rst        => fifoReset,
      clk        => axiClk,
      wr_en      => ob.freeListWrite,
      rd_en      => freeListRd,
      din        => ob.freeListDin,
      dout       => freeListDout,
      prog_full  => freeListFull,  -- unused
--      prog_empty => freeListEmpty );
      empty => freeListEmpty );  -- used in place of PushFifoValid[0]

  U_PendList : entity work.FifoSync
    generic map (
      TPD_G            => TPD_G,
      FWFT_EN_G        => true,
      DATA_WIDTH_G     => 32,
      ADDR_WIDTH_G     => 10,
--      FULL_THRES_G     =>  2,
--      EMPTY_THRES_G    =>  2 )
      FULL_THRES_G     =>  (2**10) - 10,   -- same as popFifo setting in "AxiLiteFifoPushPushPop"
      EMPTY_THRES_G    =>  1 )             -- same as popFifo setting in "AxiLiteFifoPushPushPop"  (unused)
    port map (
      rst        => fifoReset,
      clk        => axiClk,
      wr_en      => ib.pendListWrite,
      rd_en      => pendListRd,
      din        => ib.pendListDin,
      dout       => pendListDout,
      prog_full  => pendListFull,  -- used in place of popFifoPFull[0]
--      prog_empty => pendListEmpty );
      empty => pendListEmpty );   -- used in place of PushFifoValid[1]

   -------------------------------------
   -- Local Register Space
   -------------------------------------

   -- Sync
   process (axilClk) is
   begin
      if (rising_edge(axilClk)) then
         r <= rin after TPD_G;
      end if;
   end process;

   -- Async
   process (r, axiRst, axilReadMaster, axilWriteMaster, ib, freeListEmpty, freeListFull, pendListEmpty, pendListFull  ) is
      variable v         : RegType;
      variable axiStatus : AxiLiteStatusType;
   begin
      v := r;
      v.fifoClear := '0';
      v.fifoLoad  := '0';

      axiSlaveWaitTxn(axilWriteMaster, axilReadMaster, v.axiWriteSlave, v.axiReadSlave, axiStatus);

      -- Write
      if (axiStatus.writeEnable = '1') then  -- from AxiLitePkg/axiSlaveWaitWriteTxn
                                             --  writeEnable = 1 if (WM)awvalid=1 && (WM)avalid=1 && (WS)bvalid=0 (which requires (WM)bready=1!)

        case axilWriteMaster.awaddr(4 downto 2) is
--            when "000" =>
--               v.fifoClear := '1';
--               v.maxRxSize := axilWriteMaster.wdata(23 downto 0);
--            when "001" =>
--               v.buffAddr  := axilWriteMaster.wdata;
--               v.fifoLoad  := '1';
--  MT  after implementing RCE_HP driver
            when "000" =>      -- driver write to 0x404
                v.rxEnable := axilWriteMaster.wdata(0);
            when "001" =>      -- driver write to 0x404
                v.fifoClear := axilWriteMaster.wdata(0);
            when "010" =>      -- driver write to 0x408
                v.maxRxSize := axilWriteMaster.wdata(23 downto 0);
            when "011" =>      -- driver write to 0x40C
                v.buffAddr  := axilWriteMaster.wdata;
                v.fifoLoad  := '1';
            when others =>
                null;
        end case;

         axiSlaveWriteResponse(v.axiWriteSlave);
      end if;

      -- Read
      if (axiStatus.readEnable = '1') then  -- from AxiLitePkg/axiSlaveReadTxn
                                            --  readEnable = 1 if (RM)arvalid=1 && (RS)rvalid=0 (which requires (RM)rready=1!)

         v.axiReadSlave.rdata := (others=>'0');

         case axilReadMaster.araddr(4 downto 2) is
--            when "000" =>
--               v.fifoClear := '1';
--               v.maxRxSize := axilWriteMaster.wdata(23 downto 0);
--            when "001" =>
--               v.buffAddr  := axilWriteMaster.wdata;
--               v.fifoLoad  := '1';
--  MT  after implementing RCE_HP driver
            when "000" =>      -- driver write to 0x404
                v.axiReadSlave.rdata(0) := r.rxEnable;
                v.axiReadSlave.rdata(4) := r.fifoLoad;
            when "001" =>      -- driver write to 0x404
                v.axiReadSlave.rdata(0) := r.fifoClear;
            when "010" =>      -- driver write to 0x408
                v.axiReadSlave.rdata(23 downto 0) := r.maxRxSize;
            when "011" =>      -- driver write to 0x40C
                v.axiReadSlave.rdata := r.buffAddr;
            when others =>
               null;
         end case;

         -- Send Axi Response
         axiSlaveReadResponse(v.axiReadSlave);

      end if;

      -- Reset
      if (axiRst = '1') then
         v := REG_INIT_C;
      end if;

      -- Next register assignment
      rin <= v;

      -- Outputs
      axilReadSlave     <= r.axiReadSlave;
      axilWriteSlave    <= r.axiWriteSlave;

   end process;

  U_SyncClear : entity work.SynchronizerOneShot
     generic map ( TPD_G => TPD_G)
     port map ( clk     => axiClk,
                dataIn  => r.fifoClear,
                dataOut => fifoReset );

  U_SyncSize : entity work.SynchronizerVector
     generic map ( TPD_G     => TPD_G,
                   WIDTH_G   => 24 )
     port map ( clk      => axiClk,
                dataIn   => r.maxRxSize,
                dataOut  => maxSize );

   -------------------------------------
   -- Inbound Controller
   -------------------------------------
   U_IbDma : entity work.AxiStreamDmaWrite
      generic map (
         TPD_G            => TPD_G,
         AXI_READY_EN_G   => AXI_READY_EN_G,
         AXIS_CONFIG_G    => AXIS_CONFIG_G,
         AXI_CONFIG_G     => AXI_CONFIG_G,
         AXI_BURST_G      => AXI_BURST_G,
         AXI_CACHE_G      => AXI_CACHE_G
      ) port map (
         axiClk          => axiClk,
         axiRst          => axiRst,
         dmaReq          => ibReq,
         dmaAck          => ibAck,
         axisMaster      => sAxisMaster,
         axisSlave       => sAxisSlave,
         axiWriteMaster  => axiWriteMaster,
         axiWriteSlave   => axiWriteSlave,
         axiWriteCtrl    => axiWriteCtrl
      );

   -- Sync
   process (axiClk) is
   begin
      if (rising_edge(axiClk)) then
         ib <= ibin after TPD_G;
      end if;
   end process;

   -- Async
   process (ib, r, axiRst, fifoReset, ibAck, freeListEmpty, freeListDout, pendListFull, maxSize, freeLoadEmpty, freeLoadDout) is
      variable v : IbType;
   begin
      v := ib;

      v.freeLoadRead  := '0';
      v.freeListRead  := '0';
      v.pendListWrite := '0';

      case ib.state is

         when S_IDLE_C =>
            v.ibReq.maxSize := x"00" & maxSize;

            if pendListFull = '0' then
              if freeLoadEmpty='0' then
                v.ibReq.request := '1';
                v.ibReq.address := freeLoadDout;
                v.freeLoadRead  := '1';
                v.state         := S_WAIT_C;
              elsif freeListEmpty='0' then
                v.ibReq.request := '1';
                v.ibReq.address := freeListDout;
                v.freeListRead  := '1';
                v.state         := S_WAIT_C;
              end if;
            end if;

         when S_WAIT_C =>
-- MT            v.pendListDin := "1" & ib.ibReq.address(30 downto 0);
            v.pendListDin := ib.ibReq.address;

            if ibAck.done = '1' then
               v.pendListWrite := '1';
               v.state         := S_FIFO_0_C;
            end if;

         when S_FIFO_0_C =>
            v.pendListDin(31 downto 24) := x"E0";
            v.pendListDin(23 downto  0) := ibAck.size(23 downto 0);
            v.pendListWrite             := '1';
            v.state                     := S_FIFO_1_C;

         when S_FIFO_1_C =>
            v.pendListDin(31 downto 26) := x"F" & "00";
            v.pendListDin(25)           := ibAck.overflow;
            v.pendListDin(24)           := ibAck.writeError;
            v.pendListDin(23 downto 16) := ibAck.lastUser;
            v.pendListDin(15 downto  8) := ibAck.firstUser;
            v.pendListDin(7  downto  0) := ibAck.dest;
            v.pendListWrite             := '1';
            v.ibReq.request             := '0';
            v.state                     := S_IDLE_C;

         when others => null;

      end case;

      -- Reset
--      if axiRst = '1' or fifoReset = '1' then
            if axiRst = '1' or r.rxEnable = '0' then
         v := IB_INIT_C;
      end if;

      -- Next register assignment
      ibin <= v;

      -- Outputs
      ibReq                   <= ib.ibReq;
      freeListRd              <= v.freeListRead;
      freeLoadRd              <= v.freeLoadRead;

   end process;


   -------------------------------------
   -- Outbound Controller
   -------------------------------------
   U_ObDma : entity work.AxiStreamDmaRead
      generic map (
         TPD_G            => TPD_G,
         AXIS_READY_EN_G  => AXIS_READY_EN_G,
         AXIS_CONFIG_G    => AXIS_CONFIG_G,
         AXI_CONFIG_G     => AXI_CONFIG_G,
         AXI_BURST_G      => AXI_BURST_G,
         AXI_CACHE_G      => AXI_CACHE_G
      ) port map (
         axiClk          => axiClk,
         axiRst          => axiRst,
         dmaReq          => obReq,
         dmaAck          => obAck,
         axisMaster      => mAxisMaster,
         axisSlave       => mAxisSlave,
         axisCtrl        => mAxisCtrl,
         axiReadMaster   => axiReadMaster,
         axiReadSlave    => axiReadSlave
      );

   -- Sync
   process (axiClk) is
   begin
      if (rising_edge(axiClk)) then
         ob <= obin after TPD_G;
      end if;
   end process;

   -- Async
   process (ob, r, axiRst, fifoReset, obAck, pendListEmpty, pendListDout, obReady ) is
      variable v : ObType;
   begin
      v := ob;

      v.pendListRead  := '0';
      v.freeListWrite := '0';

      case ob.state is

         when S_IDLE_C =>
            v.obReq.address := pendListDout;

            if pendListEmpty = '0' then
               v.pendListRead  := '1';
               v.state         := S_FIFO_0_C;
            end if;

         when S_FIFO_0_C =>
            v.obReq.size := x"00" & pendListDout(23 downto 0);

            if pendListEmpty = '0' then
               v.pendListRead  := '1';
               v.state         := S_FIFO_1_C;
            end if;

         when S_FIFO_1_C =>
            v.obReq.lastUser  := pendListDout(23 downto 16);
            v.obReq.firstUser := pendListDout(15 downto  8);
            v.obReq.dest      := pendListDout(7  downto  0);
            v.obReq.id        := (others=>'0');

            if pendListEmpty = '0' and obReady = '1' then
               v.pendListRead  := '1';
               v.obReq.request := '1';
               v.state         := S_WAIT_C;
            end if;

         when S_WAIT_C =>
            if obAck.done = '1' then
               v.obReq.request := '0';
-- MT               v.freeListDin   := "1" & ob.obReq.address(30 downto 0);
               v.freeListDin   := ob.obReq.address;
               v.freeListWrite := '1';
               v.state         := S_IDLE_C;
            end if;

      end case;

      -- Reset
--      if axiRst = '1' then
      if axiRst = '1' or r.rxEnable = '0' then
         v := OB_INIT_C;
      end if;

      -- Next register assignment
      obin <= v;

      -- Outputs
      obReq                 <= ob.obReq;
      pendListRd            <= v.pendListRead;

   end process;

end structure;
