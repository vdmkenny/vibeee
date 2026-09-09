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
#define LWIP_NETIF_HOSTNAME 1
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define LWIP_NETIF_API 0
#define LWIP_NUM_NETIF_CLIENT_DATA 0

/* The timeout pool.
 *
 * Left alone this is exactly LWIP_NUM_SYS_TIMEOUT_INTERNAL, and lwIP spends
 * all of it: five cyclic timeouts registered by sys_timeouts_init (reassembly,
 * ARP, the two DHCP ones, DNS) and a sixth taken by tcp_timer_needed as soon
 * as any TCP pcb exists. The next sys_timeout -- the one the ping op arms --
 * then fails its allocation and, because this port's assert path exits, ends
 * the service rather than the ping. Four more than the internal count is the
 * difference between "no timers left" and "always room for one more". */
#define MEMP_NUM_SYS_TIMEOUT (LWIP_NUM_SYS_TIMEOUT_INTERNAL + 4)

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
/* Two connections' worth of queued segments, not one.
 *
 * TCP_SND_QUEUELEN derives from the send buffer ((4 * TCP_SND_BUF + MSS - 1)
 * / MSS), so at a 16 KB buffer a single pcb can hold 45 of the 48 segments
 * lwIP's own sanity check asks for -- one bulk upload starves every other
 * connection's retransmits and still passes the check, which only requires
 * the pool to cover one pcb. The pool is sized for the pcbs that actually
 * exist instead. */
#define MEMP_NUM_TCP_SEG 96

/* TCP sized for LAN bulk on a 630 MHz core: MSS 1460, NewReno as shipped.
 * Window scaling and SACK wait for a workload that needs them.
 *
 * Windows and buffers are eight segments rather than eleven: sixteen
 * connections advertising 16 KB each promise 256 KB of receive window
 * against 48 pool buffers holding 73 KB, and the send buffer is copied into
 * the same 64 KB heap everything else shares. A window this machine can
 * actually fill beats one it can only advertise. */
#define TCP_MSS 1460
#define TCP_WND (8 * TCP_MSS)
#define TCP_SND_BUF (8 * TCP_MSS)

/* Out-of-order segments are bounded. Both limits default to zero, meaning
 * unlimited, so a peer sending nothing but out-of-order data pins the whole
 * pool in a queue it will never drain. */
#define TCP_OOSEQ_MAX_PBUFS 8
#define TCP_OOSEQ_MAX_BYTES (4 * TCP_MSS)

/* The listen backlog the bridge asks for is real. Undefined, it is compiled
 * out of tcp_listen_with_backlog, and half-open connections then spend
 * MEMP_NUM_TCP_PCB directly -- a handful of SYNs evict working connections. */
#define TCP_LISTEN_BACKLOG 1

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
