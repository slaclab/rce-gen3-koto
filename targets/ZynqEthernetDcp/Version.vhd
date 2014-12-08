LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

package Version is

constant FPGA_VERSION_C : std_logic_vector(31 downto 0) := x"00000001"; -- MAKE_VERSION

constant BUILD_STAMP_C : string := "ZynqEthernetDcp: Built Mon Dec  8 09:11:22 PST 2014 by ruckman";

end Version;

-------------------------------------------------------------------------------
-- Revision History:
--
-- 12/05/2014 (0x00000001): Initial Build
--
-------------------------------------------------------------------------------

