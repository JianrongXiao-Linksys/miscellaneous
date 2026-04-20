#!/bin/ash
# Set your Wi-Fi interface ID here
WIFI_INTERFACE=1
WIFI_NAME=wifi1
ATH_NAME=ath10

# Enable debug counters
# PMAC0
athdiag --quiet --wifi $WIFI_INTERFACE --set --address 0x944500 --value 0x6FF

# Define all register addresses
REGISTERS="0xA8D164 0xA8D168 0xA8D16C 0xA8D170 0xA89288 0xA8D0C8 0xA8D0CC 0xA8D0D0 0x94454C 0x944550 0x944554 0x944558 0xA8A034 0xA8D184 0xA8D188 0xA8D18C 0x500438 0x50043C 0x500440 0x500444 0x500448 0x500450 0x500458 0x500460 0x500468 0x500470 0x5004C0 0x5004C8 0x500208 0x500358 0x5003A8"

# Register descriptions
get_register_description() {
   case "$1" in
       0xA8D164) echo "PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_END_CNT" ;;
       0xA8D168) echo "PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_PCU_START_CNT" ;;
       0xA8D16C) echo "PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_PPDU_END_CNT" ;;
       0xA8D170) echo "PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_PPDU_START_CNT" ;;
       0xA89288) echo "WCSS_PMAC0_PMCMN_R0_MCMN_MAC_IDLE " ;;
       0xA8D0C8) echo "PMAC0_RXPCU_R1_FSM_STATUS_0" ;;
       0xA8D0CC) echo "PMAC0_RXPCU_R1_FSM_STATUS_1" ;;
       0xA8D0D0) echo "PMAC0_RXPCU_R1_FSM_STATUS_2" ;;
       0x94454C) echo "WCSS_DMAC_RXDMA_MC_R1_DEBUG_PPDU_RCVD" ;;
       0x944550) echo "WCSS_DMAC_RXDMA_MC_R1_DEBUG_MPDU_RCVD" ;;
       0x944554) echo "WCSS_DMAC_RXDMA_MC_R1_DEBUG_DEST_RING_MPDU_RCVD_1" ;;
       0x944558) echo "WCSS_DMAC_RXDMA_MC_R1_DEBUG_DEST_RING_MPDU_RCVD_2" ;;
       0xA8A034) echo "WCSS_PMAC0_PMCMN_R1_TLV_READY " ;;
       0xA8D184) echo "PMAC0_RXPCU_R1_PKT_DEBUG_FILTER_IN_CNT" ;;
       0xA8D188) echo "PMAC0_RXPCU_R1_PKT_DEBUG_FILTER_OUT_CNT" ;;
       0xA8D18C) echo "PMAC0_RXPCU_R1_PKT_DEBUG_OVERFLOW_CNT" ;;
       0x500438) echo "WCSS_PHYA0_RXTD_RX11B_DET_CTRL0_L" ;;
	   0x50043C) echo "WCSS_PHYA0_RXTD_RX11B_DET_CTRL0_U" ;;
	   0x500440) echo "WCSS_PHYA0_RXTD_RX11B_DET_CTRL1_L" ;;
	   0x500444) echo "WCSS_PHYA0_RXTD_RX11B_DET_CTRL1_U" ;;
	   0x500448) echo "RX11B_PLL_FREQ_OFFSET_L" ;;
	   0x500450) echo "WCSS_PHYA0_RXTD_RXB_RX_RESET_L" ;;
	   0x500458) echo "WCSS_PHYA0_RXTD_RXB_RX_CONFIG_1_L" ;;
	   0x500460) echo "WCSS_PHYA0_RXTD_RXB_RX_CONFIG_2_L" ;;
	   0x500468) echo "WCSS_PHYA0_RXTD_RXB_RX_DISABLES_L" ;;
	   0x500470) echo "WCSS_PHYA0_RXTD_RXB_RX_DIVERSITY_MODE_L" ;;
	   0x5004C0) echo "WCSS_PHYA0_RXTD_FORCE_CLKEN_CCK_L" ;;
	   0x5004C8) echo "WCSS_PHYA0_RXTD_RXB_SPARE_01_L" ;;
	   0x500208) echo "WCSS_PHYA0_RXTD_NOTCH_CNTL_1_L" ;;
	   0x500358) echo "WCSS_PHYA0_RXTD_AGC_PWR_TARGET_3_L" ;;
	   0x5003A8) echo "PHYA_RXTD_TFEST_CONTROL_L" ;;
   esac
}

# Loop to collect data every 1 second
count=1
while [ $count -le 10 ]; do
   echo "========================================"
   timestamp=$(date)
   echo "Collection $count - Timestamp: $timestamp"
   echo "========================================"
   echo ""
   
   echo "--- MAC Register Reads ---"
   for addr in $REGISTERS; do
       desc=$(get_register_description "$addr")
       value=$(athdiag --wifi=$WIFI_INTERFACE --get --quiet --address=$addr)
       echo "[$addr] $desc = $value"
   done
   
   echo ""
   echo "--- WIFISTATS Output ---"
   i=1
   while [ $i -le 60 ]; do
       echo "WIFISTATS $i:"
       wifistats $WIFI_NAME $i
       i=$((i + 1))
   done
   
   echo ""
   echo "--- CFG80211 TXRX Stats ---"
   for stat_id in 258 259 260 261; do
       echo "cfg80211tool $ATH_NAME txrx_stats $stat_id:"
       cfg80211tool $ATH_NAME txrx_stats $stat_id
   done
   
   echo "----------------------------------------"
   echo ""
   
   count=$((count + 1))
   sleep 1
done

echo "Data collection complete!"