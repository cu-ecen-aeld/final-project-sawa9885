/*
 * gwmon - gateway monitor daemon for the AESD Pi 5 LoRaWAN gateway, version 1 (issue #6).
 *
 * Version 1 does two things:
 *   - A TCP status server (port 9000). Each connection gets one status line and is closed:
 *       gwmon 1.0.0 uptime=1234s daemon_uptime=1200s watchdog=active wd_timeout=10s \
 *           wd_interval=2s wd_feeds=600 wd_last_feed_age=1s
 *   - It owns the hardware watchdog. /dev/watchdog is opened once and fed from the main loop on a
 *     timer. If gwmon dies or its main loop hangs, the feeds stop and the board resets.
 *
 * The design follows the course's aesdsocket: -d daemon mode (fork after the socket is bound),
 * SIGINT and SIGTERM handlers that only set a flag, syslog, and a thread per client kept in a
 * list and joined by the main thread.
 *
 * Watchdog API used (Documentation/watchdog/watchdog-api.rst in the kernel tree):
 *   - open() starts the watchdog. From then on it must be pinged before the timeout.
 *   - A ping is a write of any byte to the device (same effect as ioctl WDIOC_KEEPALIVE).
 *   - ioctl WDIOC_SETTIMEOUT sets the timeout in seconds and writes back the value really used.
 *   - "Magic close": writing the character 'V' just before close() stops the watchdog. A close
 *     without it (a crash, kill -9) leaves the watchdog running, the kernel logs
 *     "watchdog0: watchdog did not stop!", and the board resets when the timeout runs out.
 *     With CONFIG_WATCHDOG_NOWAYOUT=y (or the driver's nowayout=1 parameter) even the magic
 *     close does not stop it.
 *
 * What the Pi 5 is expected to have, read from the kernel source this image pins (raspberrypi/linux
 * 21b41014, 6.12.61) and NOT YET CONFIRMED ON THE BOARD:
 *   - Driver bcm2835-wdt (CONFIG_BCM2835_WDT=y in bcm2712_defconfig), a child of the
 *     "brcm,bcm2712-pm" node. Identity string "Broadcom BCM2835 Watchdog timer", options
 *     WDIOF_SETTIMEOUT | WDIOF_MAGICCLOSE | WDIOF_KEEPALIVEPING.
 *   - Default timeout 15 s, minimum 1 s. The hardware counter holds at most 15.999 s
 *     (max_hw_heartbeat_ms); the watchdog core accepts longer timeouts and pings the hardware
 *     itself in between. gwmon asks for 10 s, so the hardware limit is not involved.
 *   - CONFIG_WATCHDOG_NOWAYOUT is not set in bcm2712_defconfig, so the magic close should work.
 *   To confirm on the board: /sys/class/watchdog/watchdog0/{identity,timeout,nowayout,state},
 *   the "watchdog ..." line gwmon writes to syslog at start, the time from kill -9 to the reset,
 *   and that a watchdog reset really reboots the Pi 5 rather than halting it.
 *
 * Shutdown rules:
 *   - SIGINT or SIGTERM: magic close first, then the rest of the cleanup. The Pi keeps running.
 *   - Anything else that ends the process (SIGKILL, a crash, SIGHUP, a fatal error in the main
 *     loop) leaves the watchdog armed on purpose: the Pi resets wd_timeout seconds later.
 *
 * This file was partially generated using Claude Code using the chat session at:
 * Link to chat session (issue #6): TODO(issue-6-session-link)
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/watchdog.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define GWMON_VERSION "1.0.0"

/* Build-time defaults. Each one can be changed with -D at build time or an option at run time. */
#ifndef GWMON_DEFAULT_PORT
#define GWMON_DEFAULT_PORT 9000
#endif
#ifndef GWMON_DEFAULT_WATCHDOG
#define GWMON_DEFAULT_WATCHDOG "/dev/watchdog"
#endif
#ifndef GWMON_DEFAULT_TIMEOUT_S
#define GWMON_DEFAULT_TIMEOUT_S 10 /* issue #6: reset within 15 s of kill -9 */
#endif
#ifndef GWMON_DEFAULT_INTERVAL_S
#define GWMON_DEFAULT_INTERVAL_S 2
#endif

#define LISTEN_BACKLOG 8
#define MAX_CLIENTS 8          /* concurrent client threads; further connections are closed */
#define CLIENT_SEND_TIMEOUT_S 2
#define CLIENT_DRAIN_MS 500    /* how long to wait for the client to close its side */
#define STATUS_LINE_MAX 256

struct config {
	bool daemonize;
	int port;
	const char *wd_path;       /* "none" turns the watchdog off */
	int wd_timeout_s;
	int wd_interval_s;
};

enum wd_state {
	WD_DISABLED,               /* -w none, or closed with the magic close */
	WD_UNAVAILABLE,            /* the device could not be opened */
	WD_ACTIVE,                 /* a watchdog device is open and fed */
	WD_FAKE,                   /* the path is not a character device: host test mode */
};

struct watchdog {
	int fd;
	enum wd_state state;
	bool feed_failed;          /* the last feed did not succeed */
	int timeout_s;             /* as reported by the driver; 0 = unknown */
	unsigned long feeds;
	struct timespec last_feed; /* CLOCK_MONOTONIC */
};

struct client {
	pthread_t thread;
	int fd;
	atomic_bool done;          /* set by the thread when it has finished */
	SLIST_ENTRY(client) link;
};

static struct config g_cfg = {
	.daemonize = false,
	.port = GWMON_DEFAULT_PORT,
	.wd_path = GWMON_DEFAULT_WATCHDOG,
	.wd_timeout_s = GWMON_DEFAULT_TIMEOUT_S,
	.wd_interval_s = GWMON_DEFAULT_INTERVAL_S,
};

/* g_wd is written by the main thread and read by the client threads, under g_wd_lock. */
static pthread_mutex_t g_wd_lock = PTHREAD_MUTEX_INITIALIZER;
static struct watchdog g_wd = { .fd = -1, .state = WD_DISABLED };

static struct timespec g_start; /* CLOCK_MONOTONIC at start; set before any thread exists */

/* The client list is used by the main thread only. */
static SLIST_HEAD(client_list, client) g_clients = SLIST_HEAD_INITIALIZER(g_clients);
static int g_nclients;

static volatile sig_atomic_t g_signal; /* the signal that asked gwmon to stop, or 0 */

static void on_signal(int signo)
{
	g_signal = signo;
}

/* ---------------------------------------------------------------- watchdog */

static void wd_set_state(enum wd_state state, int fd, int timeout_s)
{
	pthread_mutex_lock(&g_wd_lock);
	g_wd.state = state;
	g_wd.fd = fd;
	g_wd.timeout_s = timeout_s;
	g_wd.feed_failed = false;
	pthread_mutex_unlock(&g_wd_lock);
}

/*
 * Ping the watchdog. The byte must not be 'V': that would arm the magic close, and any other
 * byte disarms it again.
 */
static void wd_feed(void)
{
	static const char ping = '\0';
	bool failed, was_failed;
	int err = 0;

	if (g_wd.fd < 0)
		return;

	failed = write(g_wd.fd, &ping, 1) != 1;
	if (failed)
		err = errno;

	pthread_mutex_lock(&g_wd_lock);
	was_failed = g_wd.feed_failed;
	g_wd.feed_failed = failed;
	if (!failed) {
		g_wd.feeds++;
		clock_gettime(CLOCK_MONOTONIC, &g_wd.last_feed);
	}
	pthread_mutex_unlock(&g_wd_lock);

	/* Log the change only, not every failed feed. */
	if (failed && !was_failed)
		syslog(LOG_ERR, "watchdog feed failed: %s", strerror(err));
	else if (!failed && was_failed)
		syslog(LOG_NOTICE, "watchdog feed works again");
}

/* Open the watchdog, which starts it, set the timeout and feed it once. */
static void wd_open(void)
{
	struct watchdog_info info;
	struct stat st;
	int timeout = g_cfg.wd_timeout_s;
	int fd;

	if (strcmp(g_cfg.wd_path, "none") == 0) {
		syslog(LOG_WARNING, "watchdog disabled (-w none)");
		return;
	}

	/*
	 * No O_CREAT: if the driver is missing, a regular file must not appear in /dev and pass
	 * for a watchdog.
	 */
	fd = open(g_cfg.wd_path, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		syslog(LOG_ERR, "cannot open watchdog %s: %s", g_cfg.wd_path, strerror(errno));
		wd_set_state(WD_UNAVAILABLE, -1, 0);
		return;
	}

	if (fstat(fd, &st) != 0 || !S_ISCHR(st.st_mode)) {
		/* Host tests pass a regular file here. Feeds and the magic close land in the file. */
		syslog(LOG_WARNING, "%s is not a character device: test mode, nothing resets this machine",
		       g_cfg.wd_path);
		wd_set_state(WD_FAKE, fd, timeout);
		wd_feed();
		return;
	}

	if (ioctl(fd, WDIOC_GETSUPPORT, &info) == 0)
		syslog(LOG_INFO, "watchdog %s: \"%.32s\", options 0x%x%s", g_cfg.wd_path,
		       (const char *)info.identity, (unsigned int)info.options,
		       (info.options & WDIOF_MAGICCLOSE) ? " (magic close)" : " (no magic close)");
	else
		syslog(LOG_WARNING, "WDIOC_GETSUPPORT failed: %s", strerror(errno));

	/* SETTIMEOUT writes the timeout the driver really uses back into the argument. */
	if (ioctl(fd, WDIOC_SETTIMEOUT, &timeout) != 0) {
		syslog(LOG_WARNING, "cannot set the watchdog timeout to %d s: %s", g_cfg.wd_timeout_s,
		       strerror(errno));
		if (ioctl(fd, WDIOC_GETTIMEOUT, &timeout) != 0)
			timeout = 0;
	}
	if (timeout > 0 && g_cfg.wd_interval_s >= timeout)
		syslog(LOG_WARNING, "feed interval %d s is not below the watchdog timeout %d s",
		       g_cfg.wd_interval_s, timeout);

	wd_set_state(WD_ACTIVE, fd, timeout);
	wd_feed();
	syslog(LOG_INFO, "watchdog armed: timeout %d s, fed every %d s", timeout, g_cfg.wd_interval_s);
}

/* Stop the watchdog with the magic close. Only the clean shutdown path calls this. */
static void wd_close(void)
{
	static const char magic = 'V';
	int fd = g_wd.fd;

	if (fd < 0)
		return;

	if (write(fd, &magic, 1) != 1)
		syslog(LOG_ERR, "magic close write failed: %s (the watchdog may still be running)",
		       strerror(errno));
	if (close(fd) != 0)
		syslog(LOG_ERR, "closing the watchdog failed: %s", strerror(errno));
	else
		syslog(LOG_INFO, "watchdog closed with the magic close after %lu feeds", g_wd.feeds);

	pthread_mutex_lock(&g_wd_lock);
	g_wd.fd = -1;
	g_wd.state = WD_DISABLED;
	pthread_mutex_unlock(&g_wd_lock);
}

/* ------------------------------------------------------------------ status */

static long long seconds_between(const struct timespec *from, const struct timespec *to)
{
	return (long long)to->tv_sec - (long long)from->tv_sec - (to->tv_nsec < from->tv_nsec ? 1 : 0);
}

static const char *wd_state_name(const struct watchdog *wd)
{
	if (wd->feed_failed)
		return "error";
	switch (wd->state) {
	case WD_ACTIVE:
		return "active";
	case WD_FAKE:
		return "fake";
	case WD_UNAVAILABLE:
		return "unavailable";
	case WD_DISABLED:
	default:
		return "disabled";
	}
}

/* Write the status line, newline included, into buf. Returns its length. */
static size_t format_status(char *buf, size_t size)
{
	struct timespec now, boot;
	struct watchdog wd;
	char wd_part[128] = "";
	int n;

	clock_gettime(CLOCK_MONOTONIC, &now);
	clock_gettime(CLOCK_BOOTTIME, &boot); /* time since boot, including suspend */

	pthread_mutex_lock(&g_wd_lock);
	wd = g_wd;
	pthread_mutex_unlock(&g_wd_lock);

	if (wd.fd >= 0)
		snprintf(wd_part, sizeof(wd_part),
			 " wd_timeout=%ds wd_interval=%ds wd_feeds=%lu wd_last_feed_age=%llds",
			 wd.timeout_s, g_cfg.wd_interval_s, wd.feeds,
			 seconds_between(&wd.last_feed, &now));

	n = snprintf(buf, size, "gwmon %s uptime=%llds daemon_uptime=%llds watchdog=%s%s\n",
		     GWMON_VERSION, (long long)boot.tv_sec, seconds_between(&g_start, &now),
		     wd_state_name(&wd), wd_part);
	if (n < 0)
		return 0;
	if ((size_t)n >= size) { /* cannot happen with these field widths; keep the newline anyway */
		buf[size - 2] = '\n';
		return size - 1;
	}
	return (size_t)n;
}

/* ----------------------------------------------------------------- clients */

static void *client_thread(void *arg)
{
	struct client *c = arg;
	char line[STATUS_LINE_MAX];
	char scratch[64];
	struct timeval tv = { .tv_sec = CLIENT_SEND_TIMEOUT_S };
	struct pollfd pfd = { .fd = c->fd, .events = POLLIN };
	size_t len, sent = 0;

	setsockopt(c->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	len = format_status(line, sizeof(line));
	while (sent < len) {
		ssize_t n = send(c->fd, line + sent, len - sent, MSG_NOSIGNAL);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		sent += (size_t)n;
	}

	/*
	 * Send FIN and give the client a short time to close its side. Closing a socket that still
	 * has unread input (for example "echo status | nc ...") sends a reset, which can cost the
	 * client the status line. One poll() and one read bound the wait: a client cannot hold
	 * the thread.
	 */
	shutdown(c->fd, SHUT_WR);
	if (poll(&pfd, 1, CLIENT_DRAIN_MS) > 0)
		(void)recv(c->fd, scratch, sizeof(scratch), MSG_DONTWAIT);

	close(c->fd);
	atomic_store(&c->done, true);
	return NULL;
}

/* Join the threads that have finished, or all of them when wait_all is set. */
static void reap_clients(bool wait_all)
{
	struct client *c = SLIST_FIRST(&g_clients);

	while (c != NULL) {
		struct client *next = SLIST_NEXT(c, link);

		if (wait_all || atomic_load(&c->done)) {
			pthread_join(c->thread, NULL);
			SLIST_REMOVE(&g_clients, c, client, link);
			free(c);
			g_nclients--;
		}
		c = next;
	}
}

static void accept_client(int listen_fd)
{
	struct sockaddr_storage addr;
	socklen_t addr_len = sizeof(addr);
	char host[NI_MAXHOST] = "?";
	struct client *c;
	int fd, rc;

	fd = accept4(listen_fd, (struct sockaddr *)&addr, &addr_len, SOCK_CLOEXEC);
	if (fd < 0) {
		if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED)
			syslog(LOG_ERR, "accept: %s", strerror(errno));
		return;
	}
	getnameinfo((struct sockaddr *)&addr, addr_len, host, sizeof(host), NULL, 0, NI_NUMERICHOST);

	if (g_nclients >= MAX_CLIENTS) {
		syslog(LOG_WARNING, "%d clients already, closing connection from %s", g_nclients, host);
		close(fd);
		return;
	}

	c = calloc(1, sizeof(*c));
	if (c == NULL) {
		syslog(LOG_ERR, "out of memory, closing connection from %s", host);
		close(fd);
		return;
	}
	c->fd = fd;
	atomic_init(&c->done, false);

	rc = pthread_create(&c->thread, NULL, client_thread, c);
	if (rc != 0) {
		syslog(LOG_ERR, "pthread_create: %s", strerror(rc));
		close(fd);
		free(c);
		return;
	}
	SLIST_INSERT_HEAD(&g_clients, c, link);
	g_nclients++;
	syslog(LOG_INFO, "Accepted connection from %s", host);
}

/* ------------------------------------------------------------------- setup */

/* Returns a non-blocking listening socket on the port, or -1. */
static int open_listen_socket(int port)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM, .ai_flags = AI_PASSIVE };
	struct addrinfo *res = NULL;
	char service[16];
	int fd, rc, one = 1;

	snprintf(service, sizeof(service), "%d", port);
	rc = getaddrinfo(NULL, service, &hints, &res);
	if (rc != 0) {
		syslog(LOG_ERR, "getaddrinfo: %s", gai_strerror(rc));
		return -1;
	}

	fd = socket(res->ai_family, res->ai_socktype | SOCK_CLOEXEC | SOCK_NONBLOCK, res->ai_protocol);
	if (fd < 0) {
		syslog(LOG_ERR, "socket: %s", strerror(errno));
	} else if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) != 0 ||
		   bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, LISTEN_BACKLOG) != 0) {
		syslog(LOG_ERR, "cannot listen on port %d: %s", port, strerror(errno));
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);
	return fd;
}

/*
 * Become a daemon, as aesdsocket does: the caller has already bound the socket, so a start
 * failure is reported by the exit status of the foreground process. Returns 0 in the daemon.
 */
static int daemonize(void)
{
	pid_t pid = fork();
	int fd;

	if (pid < 0)
		return -1;
	if (pid > 0)
		_exit(EXIT_SUCCESS); /* parent: the child carries on */

	if (setsid() < 0 || chdir("/") != 0)
		return -1;
	fd = open("/dev/null", O_RDWR);
	if (fd < 0)
		return -1;
	if (dup2(fd, STDIN_FILENO) < 0 || dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0)
		return -1;
	if (fd > STDERR_FILENO)
		close(fd);
	return 0;
}

static bool parse_int(const char *text, int min, int max, int *out)
{
	char *end;
	long value;

	errno = 0;
	value = strtol(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || value < min || value > max)
		return false;
	*out = (int)value;
	return true;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"gwmon %s - gateway monitor: TCP status server and hardware watchdog\n"
		"Usage: %s [-d] [-p port] [-w device] [-t seconds] [-i seconds]\n"
		"  -d          run as a daemon\n"
		"  -p port     TCP status port (default %d)\n"
		"  -w device   watchdog device (default %s); \"none\" turns the watchdog off\n"
		"  -t seconds  watchdog timeout (default %d)\n"
		"  -i seconds  watchdog feed interval, below the timeout (default %d)\n"
		"  -v          print the version\n",
		GWMON_VERSION, prog, GWMON_DEFAULT_PORT, GWMON_DEFAULT_WATCHDOG, GWMON_DEFAULT_TIMEOUT_S,
		GWMON_DEFAULT_INTERVAL_S);
}

static bool parse_args(int argc, char **argv)
{
	int opt;

	while ((opt = getopt(argc, argv, "dp:w:t:i:vh")) != -1) {
		switch (opt) {
		case 'd':
			g_cfg.daemonize = true;
			break;
		case 'p':
			if (!parse_int(optarg, 1, 65535, &g_cfg.port))
				return false;
			break;
		case 'w':
			g_cfg.wd_path = optarg;
			break;
		case 't':
			if (!parse_int(optarg, 1, 3600, &g_cfg.wd_timeout_s))
				return false;
			break;
		case 'i':
			if (!parse_int(optarg, 1, 3600, &g_cfg.wd_interval_s))
				return false;
			break;
		case 'v':
			printf("gwmon %s\n", GWMON_VERSION);
			exit(EXIT_SUCCESS);
		default:
			return false;
		}
	}
	if (optind != argc)
		return false;
	if (g_cfg.wd_interval_s >= g_cfg.wd_timeout_s) {
		fprintf(stderr, "the feed interval (%d s) must be below the timeout (%d s)\n",
			g_cfg.wd_interval_s, g_cfg.wd_timeout_s);
		return false;
	}
	return true;
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
	struct sigaction sa = { .sa_handler = on_signal }; /* no SA_RESTART: ppoll must return */
	struct itimerspec period = { 0 };
	sigset_t blocked, wait_mask;
	int listen_fd, timer_fd;
	int status = EXIT_SUCCESS;

	if (!parse_args(argc, argv)) {
		usage(argv[0]);
		return EXIT_FAILURE;
	}

	openlog("gwmon", LOG_PID | (g_cfg.daemonize ? 0 : LOG_PERROR), LOG_DAEMON);

	/*
	 * SIGINT and SIGTERM stay blocked except while the main thread waits in ppoll(), so the
	 * flag cannot be set between the loop test and the wait. Threads inherit the blocked mask,
	 * so the main thread is the only one that takes these signals.
	 */
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGINT);
	sigaddset(&blocked, SIGTERM);
	sigprocmask(SIG_BLOCK, &blocked, &wait_mask);
	sigdelset(&wait_mask, SIGINT);
	sigdelset(&wait_mask, SIGTERM);
	sigemptyset(&sa.sa_mask);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	listen_fd = open_listen_socket(g_cfg.port);
	if (listen_fd < 0) {
		closelog();
		return EXIT_FAILURE;
	}

	if (g_cfg.daemonize && daemonize() != 0) {
		syslog(LOG_ERR, "cannot become a daemon: %s", strerror(errno));
		close(listen_fd);
		closelog();
		return EXIT_FAILURE;
	}

	clock_gettime(CLOCK_MONOTONIC, &g_start);

	timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	period.it_value.tv_sec = g_cfg.wd_interval_s;
	period.it_interval.tv_sec = g_cfg.wd_interval_s;
	if (timer_fd < 0 || timerfd_settime(timer_fd, 0, &period, NULL) != 0) {
		syslog(LOG_ERR, "cannot start the feed timer: %s", strerror(errno));
		if (timer_fd >= 0)
			close(timer_fd);
		close(listen_fd);
		closelog();
		return EXIT_FAILURE;
	}

	/* The watchdog is opened last and in the daemon itself: from here on gwmon must keep feeding. */
	wd_open();
	syslog(LOG_INFO, "gwmon %s started, status on TCP port %d", GWMON_VERSION, g_cfg.port);

	/*
	 * The watchdog is fed from this loop, not from a thread of its own, so the feeds stop if the
	 * loop that serves the status port stops.
	 */
	while (g_signal == 0) {
		struct pollfd fds[2] = {
			{ .fd = listen_fd, .events = POLLIN },
			{ .fd = timer_fd, .events = POLLIN },
		};
		uint64_t expirations;

		if (ppoll(fds, 2, NULL, &wait_mask) < 0) {
			if (errno == EINTR)
				continue;
			syslog(LOG_CRIT, "ppoll: %s", strerror(errno));
			status = EXIT_FAILURE;
			break;
		}
		if ((fds[1].revents & POLLIN) && read(timer_fd, &expirations, sizeof(expirations)) > 0)
			wd_feed();
		if (fds[0].revents & POLLIN)
			accept_client(listen_fd);
		reap_clients(false);
	}

	if (g_signal != 0) {
		syslog(LOG_INFO, "Caught signal %d, exiting", (int)g_signal);
		wd_close(); /* first, so nothing later in the shutdown can run into the timeout */
	} else {
		/* A fatal error is treated like a crash: no magic close, the watchdog resets the board. */
		syslog(LOG_CRIT, "main loop failed, leaving the watchdog armed");
	}

	close(listen_fd);
	reap_clients(true);
	close(timer_fd);
	closelog();
	return status;
}
