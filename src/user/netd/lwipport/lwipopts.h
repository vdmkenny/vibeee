/* lwIP, configured for netd: one thread, one event loop, raw API only.
 *
 * Every decision here is design/08-network.md section 3.2. The stack runs in
 * NO_SYS mode with no OS emulation; timers ride sys_check_timeouts driven
 * from the serve loop's own wait deadline, so nothing polls. */
#ifndef VIBEEE_LWIPOPTS_H
#define VIBEEE_LWIPOPTS_H

/* One thread, no OS layer, callback API only. */
#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0
#define LWIP_NETCONN 0
#define LWIP_SOCKET 0

/* Protocols: IPv4 with ARP, ICMP, UDP, TCP, raw for the ping op; DHCP and
 * DNS as clients. IPv6 is a later decision the structures do not preclude. */
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_ARP 1
#define LWIP_ICMP 1
#define LWIP_RAW 1
#define LWIP_UDP 1
#define LWIP_TCP 1
/* The stack's own loopback: 127.0.0.1 exists with no hardware under it,
 * and everything queued for ourselves is delivered by netif_poll_all in
 * the event loop, never by a thread. */
#define LWIP_HAVE_LOOPIF 1
#define LWIP_NETIF_LOOPBACK 1
#define LWIP_LOOPBACK_MAX_PBUFS 8

#define LWIP_DHCP 1
#define LWIP_DNS 1
#define LWIP_IGMP 0
#define LWIP_AUTOIP 0
/* No address-conflict probe before accepting a lease: it costs seconds per
 * acquisition and its failure mode (declining the lease) is worse on this
 * machine than the collision it guards against. */
#define LWIP_DHCP_DOES_ACD_CHECK 0
#define LWIP_ACD 0
/* An interface that fails DHCP stays addressless and says so: a 169.254
 * address on a home LAN is a lie of convenience. */

/* The netif: hardware ones and the loopback, no hostname, and both change
 * callbacks on, because address and link changes are what policy and
 * narration hang from. */
#define LWIP_SINGLE_NETIF 0
#define LWIP_NETIF_HOSTNAME 0
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define LWIP_NETIF_API 0
#define LWIP_NUM_NETIF_CLIENT_DATA 0

/* Memory: static pools, no libc heap. Sixty-four kilobytes of heap for TCP
 * segments and DHCP/DNS state, forty-eight pool buffers for frames. This is
 * a 512 MB machine serving a 100 Mbit port; exhaustion drops packets and
 * never blocks the loop. */
#define MEM_LIBC_MALLOC 0
#define MEMP_MEM_MALLOC 0
#define MEM_ALIGNMENT 4
#define MEM_SIZE (64 * 1024)
#define PBUF_POOL_SIZE 48
#define PBUF_POOL_BUFSIZE 1536
#define MEMP_NUM_PBUF 16
#define MEMP_NUM_RAW_PCB 4
#define MEMP_NUM_UDP_PCB 8
#define MEMP_NUM_TCP_PCB 16
#define MEMP_NUM_TCP_PCB_LISTEN 4
/* At least TCP_SND_QUEUELEN, which the send buffer derives at four segments
 * of headroom per buffered byte range; lwIP's own sanity check holds this. */
#define MEMP_NUM_TCP_SEG 48

/* TCP sized for LAN bulk on a 630 MHz core: MSS 1460, 16 KB windows,
 * NewReno as shipped. Window scaling and SACK wait for a workload that
 * needs them. */
#define TCP_MSS 1460
#define TCP_WND (16 * 1024)
#define TCP_SND_BUF (16 * 1024)

/* Every checksum in software: no controller here offloads any. */
#define LWIP_CHECKSUM_CTRL_PER_NETIF 0

/* DNS: a stub for the resolve op, two servers, small cache. */
#define DNS_TABLE_SIZE 4
#define DNS_MAX_NAME_LENGTH 64

/* No forwarding between netifs; fragments reassembled within defaults. */
#define IP_FORWARD 0

/* Statistics wait for a debug surface worth their bytes. */
#define LWIP_STATS 0

#endif
