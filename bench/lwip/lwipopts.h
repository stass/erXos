/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * lwIP's options for the benchmark client: the raw API on one thread
 * (NO_SYS), IPv4 and TCP over Ethernet.  The windows are the largest that
 * need no window scaling, 65535 bytes of receive window and of send buffer,
 * the configuration whose throughput the network fast path's targets cite.
 */

#ifndef LWIPOPTS_H
#define LWIPOPTS_H

#define NO_SYS			1
#define LWIP_SOCKET		0
#define LWIP_NETCONN		0
#define LWIP_IPV4		1
#define LWIP_IPV6		0
#define LWIP_DHCP		0
#define LWIP_AUTOIP		0
#define LWIP_IGMP		0
#define LWIP_STATS		0
#define LWIP_DNS		0
#define LWIP_TCP		1
#define LWIP_UDP		1
#define LWIP_ICMP		1
#define LWIP_ARP		1
#define LWIP_ETHERNET		1
#define LWIP_NETIF_STATUS_CALLBACK	0
#define MEM_ALIGNMENT		8
#define MEM_SIZE		(8 * 1024 * 1024)
#define MEMP_NUM_PBUF		4096
#define PBUF_POOL_SIZE		4096
#define PBUF_POOL_BUFSIZE	1536
#define MEMP_NUM_TCP_SEG	1024
#define MEMP_NUM_TCP_PCB	32
#define TCP_MSS			1460
#define TCP_WND			65535
#define TCP_SND_BUF		65535
#define TCP_SND_QUEUELEN	((8 * (TCP_SND_BUF) + (TCP_MSS - 1)) / (TCP_MSS))

#endif
