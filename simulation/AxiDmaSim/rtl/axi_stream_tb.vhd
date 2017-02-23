------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;
use work.AxiPkg.all;
use work.AxiDmaPkg.all;
use work.RceG3Pkg.all;

entity axi_stream_tb is end axi_stream_tb;

-- Define architecture
architecture axi_stream_tb of axi_stream_tb is

   constant CHAN_COUNT_C : integer := 3;

   signal axiClk          : sl;
   signal axiRst          : sl;
   signal axilReadMaster  : AxiLiteReadMasterType;
   signal axilReadSlave   : AxiLiteReadSlaveType;
   signal axilWriteMaster : AxiLiteWriteMasterType;
   signal axilWriteSlave  : AxiLiteWriteSlaveType;
   signal interrupt       : sl;
   signal online          : slv(CHAN_COUNT_C-1 downto 0);
   signal acknowledge     : slv(CHAN_COUNT_C-1 downto 0);
   signal sAxisMaster     : AxiStreamMasterArray(CHAN_COUNT_C-1 downto 0);
   signal sAxisSlave      : AxiStreamSlaveArray(CHAN_COUNT_C-1 downto 0);
   signal mAxisMaster     : AxiStreamMasterArray(CHAN_COUNT_C-1 downto 0);
   signal mAxisSlave      : AxiStreamSlaveArray(CHAN_COUNT_C-1 downto 0);
   signal mAxisCtrl       : AxiStreamCtrlArray(CHAN_COUNT_C-1 downto 0);
   signal axiReadMaster   : AxiReadMasterArray(CHAN_COUNT_C downto 0);
   signal axiReadSlave    : AxiReadSlaveArray(CHAN_COUNT_C downto 0);
   signal axiWriteMaster  : AxiWriteMasterArray(CHAN_COUNT_C downto 0);
   signal axiWriteSlave   : AxiWriteSlaveArray(CHAN_COUNT_C downto 0);
   signal axiWriteCtrl    : AxiCtrlArray(CHAN_COUNT_C downto 0);

--   type RegType is record
--      axilReadMaster  : AxiLiteReadMasterType;
--      axilWriteMaster : AxiLiteWriteMasterType;
--      count           : slv(15 downto 0);
--   end record RegType;
--
--   constant REG_INIT_C : RegType := (
--      axilReadMaster  <= AXI_LITE_READ_MASTER_INIT_C,
--      axilWriteMaster <= AXI_LITE_WRITE_MASTER_INIT_C,
--      count           <= (others=>'0')
--   );
--
--   signal r   : RegType := REG_INIT_C;
--   signal rin : RegType;

begin

   process begin
      axiClk <= '1';
      wait for 5 ns;
      axiClk <= '0';
      wait for 5 ns;
   end process;

   process begin
      axiRst <= '1';
      wait for (100 ns);
      axiRst <= '0';
      wait;
   end process;

   U_AxiStreamDmaV2: entity work.AxiStreamDmaV2 
      generic map (
         TPD_G              => 1 ns,
         DESC_AWIDTH_G      => 11,
         AXIL_BASE_ADDR_G   => x"00060000",
         AXI_ERROR_RESP_G   => AXI_RESP_OK_C,
         AXI_READY_EN_G     => true,
         AXIS_READY_EN_G    => true,
         AXIS_CONFIG_G      => RCEG3_AXIS_DMA_CONFIG_C,
         AXI_DESC_CONFIG_G  => AXI_ACP_INIT_C,
         AXI_DMA_CONFIG_G   => AXI_HP_INIT_C,
         CHAN_COUNT_G       => CHAN_COUNT_C,
         RD_PIPE_STAGES_G   => 1,
         RD_PEND_THRESH_G   => 1000)
      port map (
         axiClk           => axiClk,
         axiRst           => axiRst,
         axilReadMaster   => axilReadMaster,
         axilReadSlave    => axilReadSlave,
         axilWriteMaster  => axilWriteMaster,
         axilWriteSlave   => axilWriteSlave,
         interrupt        => interrupt,
         online           => online,
         acknowledge      => acknowledge,
         sAxisMaster      => sAxisMaster,
         sAxisSlave       => sAxisSlave,
         mAxisMaster      => mAxisMaster,
         mAxisSlave       => mAxisSlave,
         mAxisCtrl        => mAxisCtrl,
         axiReadMaster    => axiReadMaster,
         axiReadSlave     => axiReadSlave,
         axiWriteMaster   => axiWriteMaster,
         axiWriteSlave    => axiWriteSlave,
         axiWriteCtrl     => axiWriteCtrl);

   U_AxiGen: for i in 0 to CHAN_COUNT_C generate
      U_ReadTest: entity work.AxiReadEmulate
         generic map (
            TPD_G        => 1 ns,
            LATENCY_G    => 31,
            AXI_CONFIG_G => AXI_HP_INIT_C,
            SIM_DEBUG_G  => true)
         port map (
            axiClk        => axiClk,
            axiRst        => axiRst,
            axiReadMaster => axiReadMaster(i),
            axiReadSlave  => axiReadSlave(i));

      U_WriteTest: entity work.AxiWriteEmulate
         generic map (
            TPD_G        => 1 ns,
            LATENCY_G    => 31,
            AXI_CONFIG_G => AXI_HP_INIT_C,
            SIM_DEBUG_G  => true)
         port map (
            axiClk         => axiClk,
            axiRst         => axiRst,
            axiWriteMaster => axiWriteMaster(i),
            axiWriteSlave  => axiWriteSlave(i));
   end generate;

   process begin

      axilWriteMaster  <= AXI_LITE_WRITE_MASTER_INIT_C;

      wait for 5 US;

      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060028", x"00001000", true); -- Max Size

      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060020", x"00000000", true); -- Fifo reset
      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060000", x"00000001", true); -- Enable

      for i in 0 to 8 loop
         axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060048", toSlv(i,32), true); -- write FIFO
         axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00064000" + (toSlv(i,8) & "00"), toSlv(1024+i*8,32), true); -- addr table
      end loop;

      for i in 9 to 16 loop
         axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00064000" + (toSlv(i,8) & "00"), toSlv(1024+i*8,32), true); -- addr table
      end loop;

      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060004", x"00000001", true); -- Int Enable

      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060044", x"40000080", true); -- Read High
      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060040", x"00000030", true); -- Read Low

      --axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060044", x"00800080", true); -- Read High
      --axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"00060040", x"00008040", true); -- Read Low

      wait for 1 US;

      axiLiteBusSimWrite ( axiClk, axilWriteMaster, axilWriteSlave, x"0006004C", x"00030002", true); -- In ack/enable

      wait;
   end process;

   axilReadMaster   <= AXI_LITE_READ_MASTER_INIT_C;
   sAxisMaster      <= mAxisMaster;
   mAxisSlave       <= sAxisSlave;
   mAxisCtrl        <= (others=>AXI_STREAM_CTRL_INIT_C);
   axiWriteCtrl     <= (others=>AXI_CTRL_INIT_C);

end axi_stream_tb;
