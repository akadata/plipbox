/*
 * plip_rx.c: handle incoming plip packets
 *
 * Written by
 *  Christian Vogelgsang <chris@vogelgsang.org>
 *
 * This file is part of plipbox.
 * See README for copyright notice.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
 *  02111-1307  USA.
 *
 */

#include "global.h"
   
#include "net/net.h"
#include "net/eth.h"
#include "net/ip.h"
#include "net/arp_cache.h"
#include "net/arp.h"
#include "net/icmp.h"

#include "plip_state.h"
#include "pkt_buf.h"
#include "enc28j60.h"
#include "eth_tx.h"
#include "plip.h"
#include "plip_tx.h"
#include "ping.h"
#include "uart.h"
#include "uartutil.h"
#include "param.h"
#include "debug.h"

static u08 offset;

static u08 begin_rx(plip_packet_t *pkt)
{
  // start writing packet after (potential) ETH header
  offset = ETH_HDR_SIZE;
  
  // start writing after ETH header
  enc28j60_packet_tx_begin_range(ETH_HDR_SIZE);
  
  return PLIP_STATUS_OK;
}

static u08 transfer_rx(u08 *data)
{
  // clone packet to our packet buffer
  if(offset < PKT_BUF_SIZE) {
    pkt_buf[offset] = *data;
    offset ++;
  }
  
  // always copy to TX buffer of enc28j60
  enc28j60_packet_tx_byte(*data);
  
  return PLIP_STATUS_OK;
}

static u08 end_rx(plip_packet_t *pkt)
{
  // end range in enc28j60 buffer
  enc28j60_packet_tx_end_range();

  return PLIP_STATUS_OK;
}

void plip_rx_init(void)
{
  plip_recv_init(begin_rx, transfer_rx, end_rx);
}

static void uart_send_prefix(void)
{
  uart_send_pstring(PSTR("plip(rx): "));
}

//#define DEBUG

static void handle_ip_pkt(plip_packet_t *pkt, u08 eth_online)
{
  if(eth_online) {
    // simply send packet to ethernet
    eth_tx_send(ETH_TYPE_IPV4, pkt->size, ETH_HDR_SIZE, pkt->dst_addr);
  } else {
    // no ethernet online -> we have to drop packet
    uart_send_prefix();
    uart_send_pstring(PSTR("IP: DROP!"));
    uart_send_crlf();
  }
}

static void handle_arp_pkt(plip_packet_t *pkt, u08 eth_online)
{
  u08 *arp_buf = pkt_buf + ETH_HDR_SIZE;
  u16 arp_size = pkt->size;
  
  // make sure its an IPv4 ARP packet
  if(!arp_is_ipv4(arp_buf, arp_size)) {
    uart_send_prefix();
    uart_send_pstring(PSTR("ARP: type?"));
    return;
  }

#ifdef DEBUG
  debug_dump_arp_pkt(arp_buf, uart_send_prefix);
#endif

  // ARP request should now be something like this:
  // src_mac = Amiga MAC
  // src_ip = Amiga IP
  const u08 *pkt_src_mac = pkt->src_addr;
  const u08 *arp_src_mac = arp_get_src_mac(arp_buf);
  
  // pkt src and arp src must be the same
  if(!net_compare_mac(pkt_src_mac, arp_src_mac)) {
    uart_send_prefix();
    uart_send_pstring(PSTR("ARP: pkt!=src mac!"));
    uart_send_crlf();
    return;
  }
    
  // send ARP packet to ethernet
  if(eth_online) {
    eth_tx_send(ETH_TYPE_ARP, arp_size, ETH_HDR_SIZE, pkt->dst_addr);
  } else {
    // no ethernet online -> we have to drop packet
    uart_send_prefix();
    uart_send_pstring(PSTR("ARP: DROP!"));
    uart_send_crlf();
  }
}

static u08 update_my_mac(plip_packet_t *pkt)
{
  // update mac if its not a broadcast or zero mac
  if(!net_compare_bcast_mac(pkt->src_addr) && !net_compare_zero_mac(pkt->src_addr)) {
    net_copy_mac(pkt->src_addr, net_get_mac());
   
    uart_send_prefix();
    uart_send_pstring(PSTR("UPDATE: mac="));
    net_dump_mac(net_get_mac());
    uart_send_crlf();
    return 1;
  } else {
    return 0;
  }
}

static u08 has_mac;

void plip_rx_reset_config(void)
{
  has_mac = 0;
}
  
u08 plip_rx_is_configured(void)
{
  return has_mac;
}

void plip_rx_worker(u08 plip_state, u08 eth_online)
{
  // operate only in WAIT_CONFIG or ONLINE 
  if((plip_state != PLIP_STATE_WAIT_CONFIG) && (plip_state != PLIP_STATE_ONLINE)) {
    return;
  }
  
  // do we have a PLIP packet waiting?
  if(plip_can_recv() == PLIP_STATUS_OK) {
    // receive PLIP packet and store it in eth chip tx buffer
    // also keep a copy in our local pkt_buf (up to max size)
    u08 status = plip_recv(&pkt);
    if(status == PLIP_STATUS_OK) {
#ifdef DEBUG
      debug_dump_plip_pkt(&pkt, uart_send_prefix);
#endif

      // update mac?
      if(!has_mac) {
        if(update_my_mac(&pkt)) {
          has_mac = 1;
        }
      }

      // got a valid packet from plip -> check type
      u16 type = pkt.type;
      // handle IP packet
      if(type == ETH_TYPE_IPV4) {
        handle_ip_pkt(&pkt, eth_online);
      }
      // handle ARP packet
      else if(type == ETH_TYPE_ARP) {
        handle_arp_pkt(&pkt, eth_online);
      }
      // unknown packet type
      else {
        uart_send_prefix();
        uart_send_pstring(PSTR("type? "));
        uart_send_hex_word_crlf(type);
      }
    } else {
      // report receiption error
      uart_send_prefix();
      uart_send_pstring(PSTR("recv? "));
      uart_send_hex_byte_crlf(status);
    }
  }
}