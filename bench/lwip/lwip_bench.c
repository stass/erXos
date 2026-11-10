/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * lwip_bench: lwIP's side of the network fast path's benchmarks, a TCP client
 * on the raw API over a tap device ($TAPDEV), the baseline that erx_net's
 * numbers are compared with.  The peer is a server in a jail on the tap's
 * bridge; lwIP is 10.77.0.101.  Usage:
 *
 *	lwip_bench send PEER PORT MIB
 *	lwip_bench recv PEER PORT MIB
 *	lwip_bench rr PEER PORT BYTES CONNECTIONS SECONDS
 *
 * send writes MIB mebibytes to the peer and shuts down its end; recv reads
 * until the peer shuts down.  rr opens CONNECTIONS connections, each of which
 * sends BYTES bytes and waits for the peer to echo as many, over and over for
 * SECONDS seconds.  Each run prints one line,
 *
 *	RESULT key=value key=value ...
 *
 * the format of erx_net_bench, whose keys tools/erx bench net-freebsd reads, and
 * one line of the process's own CPU time and context switches over the run,
 *
 *	WINDOW cpu_ms=N voluntary=N involuntary=N
 *
 * read from getrusage just before the connection starts and just after the
 * run ends.  The exit status is 0 only if the run completed.
 */

#include <sys/resource.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lwip/etharp.h"
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h"
#include "netif/ethernet.h"
#include "netif/tapif.h"

#define LWB_SETTLE_MS	1000
#define LWB_MAX_CONNS	16
/* Latencies kept for the percentiles; a run that fills the table fails. */
#define LWB_MAX_SAMPLES	(1U << 22)
#define LWB_ZEROS_BYTES	32768

enum lwb_mode {
	LWB_SEND,
	LWB_RECV,
	LWB_RR
};

/* One request-reply connection and the transaction it has in flight. */
struct lwb_conn {
	struct tcp_pcb	*pcb;
	uint64_t	started_ns;
	size_t		echoed;
};

static struct netif	lwb_netif;
static struct tcp_pcb	*lwb_pcb;
static enum lwb_mode	lwb_mode;
static uint64_t		lwb_total_bytes;
static uint64_t		lwb_done_bytes;
static uint64_t		lwb_start_ns;
static uint64_t		lwb_end_ns;
static bool		lwb_shut_sent;
static bool		lwb_finished;
static bool		lwb_failed;
static char		lwb_zeros[LWB_ZEROS_BYTES];

static struct lwb_conn	lwb_conns[LWB_MAX_CONNS];
static unsigned		lwb_nconns;
static unsigned		lwb_open_conns;
static size_t		lwb_rr_bytes;
static uint64_t		lwb_rr_deadline_ns;
static uint32_t		*lwb_latency_us;
static uint32_t		lwb_samples;

u32_t			sys_now(void);
sys_prot_t		sys_arch_protect(void);
void			sys_arch_unprotect(sys_prot_t previous);

static uint64_t		lwb_now_ns(void);
static err_t		lwb_bulk_connected(void *arg, struct tcp_pcb *pcb, err_t error);
static void		lwb_bulk_fill(struct tcp_pcb *pcb);
static err_t		lwb_bulk_received(void *arg, struct tcp_pcb *pcb, struct pbuf *data, err_t error);
static err_t		lwb_bulk_sent(void *arg, struct tcp_pcb *pcb, u16_t len);
static int		lwb_compare_u32(const void *a, const void *b);
static void		lwb_error(void *arg, err_t error);
static void		lwb_print_rr(void);
static void		lwb_print_window(const struct rusage *before);
static err_t		lwb_rr_connected(void *arg, struct tcp_pcb *pcb, err_t error);
static void		lwb_rr_error(void *arg, err_t error);
static err_t		lwb_rr_received(void *arg, struct tcp_pcb *pcb, struct pbuf *data, err_t error);
static void		lwb_rr_start(struct lwb_conn *conn);
static bool		lwb_run(void);
static void		lwb_settle(const ip4_addr_t *peer);
static unsigned long	lwb_parse(const char *text, unsigned long max);
static bool		lwb_parse_mode(const char *name, enum lwb_mode *mode);

/* lwIP's porting hooks: one thread, so protection is a no-op. */
u32_t
sys_now(void)
{
	return (u32_t)(lwb_now_ns() / 1000000);
}

sys_prot_t
sys_arch_protect(void)
{
	return 0;
}

void
sys_arch_unprotect(sys_prot_t previous)
{
	(void)previous;
}

static uint64_t
lwb_now_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint64_t)now.tv_sec * 1000000000U + (uint64_t)now.tv_nsec;
}

static bool
lwb_parse_mode(const char *name, enum lwb_mode *mode)
{
	if (strcmp(name, "send") == 0)
		*mode = LWB_SEND;
	else if (strcmp(name, "recv") == 0)
		*mode = LWB_RECV;
	else if (strcmp(name, "rr") == 0)
		*mode = LWB_RR;
	else
		return false;
	return true;
}

static unsigned long
lwb_parse(const char *text, unsigned long max)
{
	char *end;
	unsigned long value;

	value = strtoul(text, &end, 10);
	if (*text == '\0' || *end != '\0' || value == 0 || value > max) {
		fprintf(stderr, "lwip_bench: bad number '%s' (1 to %lu)\n", text, max);
		exit(2);
	}
	return value;
}

static void
lwb_error(void *arg, err_t error)
{
	(void)arg;
	fprintf(stderr, "lwip_bench: tcp error %d\n", (int)error);
	lwb_failed = true;
	lwb_pcb = NULL;
}

/* Bulk: write the zeros while the send buffer has room, then shut down. */
static void
lwb_bulk_fill(struct tcp_pcb *pcb)
{
	uint64_t left;
	u16_t room, n;

	while (lwb_done_bytes < lwb_total_bytes) {
		left = lwb_total_bytes - lwb_done_bytes;
		n = left > sizeof(lwb_zeros) ? (u16_t)sizeof(lwb_zeros) : (u16_t)left;
		room = tcp_sndbuf(pcb);
		if (room == 0)
			break;
		if (n > room)
			n = room;
		/* ROM data: lwIP references the zeros and copies nothing. */
		if (tcp_write(pcb, lwb_zeros, n, TCP_WRITE_FLAG_MORE) != ERR_OK)
			break;
		lwb_done_bytes += n;
	}
	tcp_output(pcb);
	if (lwb_done_bytes == lwb_total_bytes && !lwb_shut_sent) {
		tcp_shutdown(pcb, 0, 1);
		lwb_shut_sent = true;
	}
}

static err_t
lwb_bulk_sent(void *arg, struct tcp_pcb *pcb, u16_t len)
{
	(void)arg;
	(void)len;
	if (lwb_mode == LWB_SEND)
		lwb_bulk_fill(pcb);
	return ERR_OK;
}

/* The peer's end of stream ends a receive run and, after our FIN, a send run. */
static err_t
lwb_bulk_received(void *arg, struct tcp_pcb *pcb, struct pbuf *data, err_t error)
{
	(void)arg;
	(void)error;
	if (data == NULL) {
		lwb_end_ns = lwb_now_ns();
		lwb_finished = true;
		return ERR_OK;
	}
	tcp_recved(pcb, data->tot_len);
	lwb_done_bytes += data->tot_len;
	pbuf_free(data);
	return ERR_OK;
}

static err_t
lwb_bulk_connected(void *arg, struct tcp_pcb *pcb, err_t error)
{
	(void)arg;
	(void)error;
	if (lwb_mode == LWB_SEND)
		lwb_bulk_fill(pcb);
	return ERR_OK;
}

/* Request-reply: one request on the wire per connection at a time. */
static void
lwb_rr_start(struct lwb_conn *conn)
{
	conn->echoed = 0;
	conn->started_ns = lwb_now_ns();
	if (tcp_write(conn->pcb, lwb_zeros, (u16_t)lwb_rr_bytes, TCP_WRITE_FLAG_COPY) != ERR_OK ||
	    tcp_output(conn->pcb) != ERR_OK)
		lwb_failed = true;
}

static err_t
lwb_rr_connected(void *arg, struct tcp_pcb *pcb, err_t error)
{
	(void)pcb;
	(void)error;
	lwb_rr_start(arg);
	return ERR_OK;
}

static void
lwb_rr_error(void *arg, err_t error)
{
	struct lwb_conn *conn = arg;

	fprintf(stderr, "lwip_bench: tcp error %d on connection %ld\n",
	    (int)error, (long)(conn - lwb_conns));
	conn->pcb = NULL;
	lwb_failed = true;
}

static err_t
lwb_rr_received(void *arg, struct tcp_pcb *pcb, struct pbuf *data, err_t error)
{
	struct lwb_conn *conn = arg;
	uint64_t now;

	(void)error;
	if (data == NULL) {
		/* The peer closed before the run ended. */
		lwb_failed = true;
		return ERR_OK;
	}
	tcp_recved(pcb, data->tot_len);
	conn->echoed += data->tot_len;
	pbuf_free(data);
	if (conn->echoed < lwb_rr_bytes)
		return ERR_OK;
	if (lwb_samples == LWB_MAX_SAMPLES) {
		fprintf(stderr, "lwip_bench: latency table full\n");
		lwb_failed = true;
		return ERR_OK;
	}
	now = lwb_now_ns();
	lwb_latency_us[lwb_samples++] = (uint32_t)((now - conn->started_ns) / 1000);
	if (now >= lwb_rr_deadline_ns) {
		/* The peer's close of its side is not a failure now: stop listening. */
		tcp_arg(pcb, NULL);
		tcp_recv(pcb, NULL);
		tcp_err(pcb, NULL);
		tcp_close(pcb);
		conn->pcb = NULL;
		if (--lwb_open_conns == 0) {
			lwb_end_ns = now;
			lwb_finished = true;
		}
		return ERR_OK;
	}
	lwb_rr_start(conn);
	return ERR_OK;
}

static int
lwb_compare_u32(const void *a, const void *b)
{
	uint32_t x = *(const uint32_t *)a;
	uint32_t y = *(const uint32_t *)b;

	return x < y ? -1 : x > y;
}

/*
 * Prints the CPU time and context switches this process used since before, if
 * getrusage reports them, and nothing where it does not.
 */
static void
lwb_print_window(const struct rusage *before)
{
	struct rusage after;
	long long cpu_ms;

	if (getrusage(RUSAGE_SELF, &after) != 0)
		return;
	cpu_ms = ((long long)after.ru_utime.tv_sec - before->ru_utime.tv_sec +
	    (long long)after.ru_stime.tv_sec - before->ru_stime.tv_sec) * 1000 +
	    ((long long)after.ru_utime.tv_usec - before->ru_utime.tv_usec +
	    (long long)after.ru_stime.tv_usec - before->ru_stime.tv_usec) / 1000;
	printf("WINDOW cpu_ms=%lld voluntary=%ld involuntary=%ld\n", cpu_ms,
	    after.ru_nvcsw - before->ru_nvcsw, after.ru_nivcsw - before->ru_nivcsw);
}

static void
lwb_print_rr(void)
{
	double secs = (double)(lwb_end_ns - lwb_start_ns) / 1e9;

	qsort(lwb_latency_us, lwb_samples, sizeof(lwb_latency_us[0]), lwb_compare_u32);
	printf("RESULT mode=rr stack=lwip bytes=%zu conns=%u secs=%.3f txns=%u tps=%.0f "
	    "p50_us=%u p99_us=%u\n", lwb_rr_bytes, lwb_nconns, secs, lwb_samples,
	    lwb_samples / secs, lwb_latency_us[lwb_samples / 2],
	    lwb_latency_us[(uint64_t)lwb_samples * 99 / 100]);
}

/* Lets ARP resolve the peer before the clock starts, as erx_net's drivers do. */
static void
lwb_settle(const ip4_addr_t *peer)
{
	uint64_t begin = lwb_now_ns();

	etharp_request(&lwb_netif, peer);
	while (lwb_now_ns() - begin < (uint64_t)LWB_SETTLE_MS * 1000000) {
		tapif_select(&lwb_netif);
		sys_check_timeouts();
	}
}

static bool
lwb_run(void)
{
	while (!lwb_failed && !lwb_finished) {
		tapif_select(&lwb_netif);
		sys_check_timeouts();
		if (lwb_mode == LWB_SEND && lwb_pcb == NULL)
			break;
	}
	return !lwb_failed && lwb_finished;
}

int
main(int argc, char **argv)
{
	ip4_addr_t ip, mask, gw, peer;
	u16_t port;
	struct rusage before;
	unsigned i;
	bool have_before;

	if (argc < 2 || !lwb_parse_mode(argv[1], &lwb_mode) ||
	    argc != (lwb_mode == LWB_RR ? 7 : 5) || !ipaddr_aton(argv[2], &peer)) {
		fprintf(stderr, "usage: lwip_bench send|recv PEER PORT MIB | "
		    "rr PEER PORT BYTES CONNECTIONS SECONDS\n");
		return 2;
	}
	port = (u16_t)lwb_parse(argv[3], 65535);
	if (lwb_mode == LWB_RR) {
		lwb_rr_bytes = lwb_parse(argv[4], LWB_ZEROS_BYTES);
		lwb_nconns = (unsigned)lwb_parse(argv[5], LWB_MAX_CONNS);
		lwb_rr_deadline_ns = lwb_parse(argv[6], 3600) * 1000000000U;
		lwb_latency_us = calloc(LWB_MAX_SAMPLES, sizeof(*lwb_latency_us));
		if (lwb_latency_us == NULL)
			return 1;
	} else
		lwb_total_bytes = lwb_parse(argv[4], 1U << 20) << 20;

	IP4_ADDR(&ip, 10, 77, 0, 101);
	IP4_ADDR(&mask, 255, 255, 255, 0);
	IP4_ADDR(&gw, 10, 77, 0, 1);
	setvbuf(stdout, NULL, _IONBF, 0);
	lwip_init();
	netif_add(&lwb_netif, &ip, &mask, &gw, NULL, tapif_init, ethernet_input);
	netif_set_default(&lwb_netif);
	netif_set_up(&lwb_netif);
	lwb_settle(&peer);

	have_before = getrusage(RUSAGE_SELF, &before) == 0;
	lwb_start_ns = lwb_now_ns();
	if (lwb_mode == LWB_RR) {
		lwb_rr_deadline_ns += lwb_start_ns;
		for (i = 0; i < lwb_nconns; i++) {
			lwb_conns[i].pcb = tcp_new();
			if (lwb_conns[i].pcb == NULL)
				return 1;
			tcp_nagle_disable(lwb_conns[i].pcb);
			tcp_arg(lwb_conns[i].pcb, &lwb_conns[i]);
			tcp_err(lwb_conns[i].pcb, lwb_rr_error);
			tcp_recv(lwb_conns[i].pcb, lwb_rr_received);
			if (tcp_connect(lwb_conns[i].pcb, &peer, port, lwb_rr_connected) != ERR_OK)
				return 3;
			lwb_open_conns++;
		}
	} else {
		lwb_pcb = tcp_new();
		if (lwb_pcb == NULL)
			return 1;
		tcp_err(lwb_pcb, lwb_error);
		tcp_recv(lwb_pcb, lwb_bulk_received);
		tcp_sent(lwb_pcb, lwb_bulk_sent);
		if (tcp_connect(lwb_pcb, &peer, port, lwb_bulk_connected) != ERR_OK)
			return 3;
	}

	if (!lwb_run()) {
		fprintf(stderr, "lwip_bench: failed after %llu bytes\n", (unsigned long long)lwb_done_bytes);
		return 1;
	}
	if (lwb_mode == LWB_RECV && lwb_done_bytes != lwb_total_bytes) {
		fprintf(stderr, "lwip_bench: short transfer, %llu of %llu bytes\n",
		    (unsigned long long)lwb_done_bytes, (unsigned long long)lwb_total_bytes);
		return 1;
	}
	if (have_before)
		lwb_print_window(&before);
	if (lwb_mode == LWB_RR)
		lwb_print_rr();
	else {
		double secs = (double)(lwb_end_ns - lwb_start_ns) / 1e9;

		printf("RESULT mode=%s stack=lwip bytes=%llu secs=%.3f mbit=%.0f\n", argv[1],
		    (unsigned long long)lwb_done_bytes, secs, (double)lwb_done_bytes * 8 / secs / 1e6);
	}
	return 0;
}
