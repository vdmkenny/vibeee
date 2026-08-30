/* The layout proof between lwIP's C and netd's Zig mirror.
 *
 * `lwip.zig` hand-mirrors the few structs and constants the glue touches,
 * with comptime assertions pinning its side of every number. This file pins
 * the C side of the same numbers against the vendored headers, so a header
 * change and a mirror change each fail the build on their own. It contains
 * no code: static assertions only.
 */
#include <stddef.h>

#include "lwip/dhcp.h"
#include "lwip/err.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/prot/dhcp.h"

#define CHECK(name, expr) _Static_assert((expr), name)

/* struct netif, for the fields the glue reads and writes. */
CHECK("netif size", sizeof(struct netif) == 60);
CHECK("netif ip_addr", offsetof(struct netif, ip_addr) == 4);
CHECK("netif netmask", offsetof(struct netif, netmask) == 8);
CHECK("netif gw", offsetof(struct netif, gw) == 12);
CHECK("netif input", offsetof(struct netif, input) == 16);
CHECK("netif output", offsetof(struct netif, output) == 20);
CHECK("netif linkoutput", offsetof(struct netif, linkoutput) == 24);
CHECK("netif status_callback", offsetof(struct netif, status_callback) == 28);
CHECK("netif link_callback", offsetof(struct netif, link_callback) == 32);
CHECK("netif state", offsetof(struct netif, state) == 36);
CHECK("netif client_data", offsetof(struct netif, client_data) == 40);
CHECK("netif mtu", offsetof(struct netif, mtu) == 44);
CHECK("netif hwaddr", offsetof(struct netif, hwaddr) == 46);
CHECK("netif hwaddr_len", offsetof(struct netif, hwaddr_len) == 52);
CHECK("netif flags", offsetof(struct netif, flags) == 53);
CHECK("netif name", offsetof(struct netif, name) == 54);
CHECK("netif num", offsetof(struct netif, num) == 56);
CHECK("one dhcp client slot", LWIP_NETIF_CLIENT_DATA_INDEX_DHCP == 0);
CHECK("client slots", LWIP_NETIF_CLIENT_DATA_INDEX_MAX == 1);

/* netif flags the glue sets. */
CHECK("flag up", NETIF_FLAG_UP == 0x01);
CHECK("flag broadcast", NETIF_FLAG_BROADCAST == 0x02);
CHECK("flag link up", NETIF_FLAG_LINK_UP == 0x04);
CHECK("flag etharp", NETIF_FLAG_ETHARP == 0x08);

/* struct pbuf, for payload walks and takes. */
CHECK("pbuf size", sizeof(struct pbuf) == 16);
CHECK("pbuf next", offsetof(struct pbuf, next) == 0);
CHECK("pbuf payload", offsetof(struct pbuf, payload) == 4);
CHECK("pbuf tot_len", offsetof(struct pbuf, tot_len) == 8);
CHECK("pbuf len", offsetof(struct pbuf, len) == 10);
CHECK("pbuf ref", offsetof(struct pbuf, ref) == 14);

/* The allocation layers and types the glue names. */
CHECK("layer raw", PBUF_RAW == 0);
CHECK("layer link", PBUF_LINK == 14);
CHECK("layer ip", PBUF_IP == 34);
CHECK("layer transport", PBUF_TRANSPORT == 54);
CHECK("type pool", PBUF_POOL == 0x0182);
CHECK("type ram", PBUF_RAM == 0x0280);
CHECK("type ref", PBUF_REF == 0x0041);

/* err_t values crossing the boundary. */
CHECK("err ok", ERR_OK == 0);
CHECK("err mem", ERR_MEM == -1);
CHECK("err inprogress", ERR_INPROGRESS == -5);

/* struct dhcp, for the lease view `net` reports. */
CHECK("dhcp state", offsetof(struct dhcp, state) == 5);
CHECK("dhcp lease_used", offsetof(struct dhcp, lease_used) == 18);
CHECK("dhcp server", offsetof(struct dhcp, server_ip_addr) == 24);
CHECK("dhcp offered addr", offsetof(struct dhcp, offered_ip_addr) == 28);
CHECK("dhcp t0 lease", offsetof(struct dhcp, offered_t0_lease) == 40);
CHECK("dhcp bound", DHCP_STATE_BOUND == 10);
CHECK("dhcp coarse timer", DHCP_COARSE_TIMER_SECS == 60);
