/*
 * gwmon - gateway monitor daemon for the AESD Pi 5 LoRaWAN gateway, version 2 (issues #6, #7).
 *
 * gwmon does four things, all from one ppoll() loop in the main thread:
 *   - A TCP status server (port 9000). Each connection gets one status line and is closed:
 *       gwmon 2.0.0 uptime=1234s daemon_uptime=1200s watchdog=active wd_timeout=10s \
 *           wd_interval=2s wd_feeds=600 wd_last_feed_age=1s station=running station_pid=301 \
 *           station_uptime=1190s station_restarts=0 station_fails=0 uplinks=12 \
 *           last_uplink_age=37s temp=31.5C
 *   - It owns the hardware watchdog. /dev/watchdog is opened once and fed from the main loop on a
 *     timer. If gwmon dies or its main loop hangs, the feeds stop and the board resets.
 *   - It supervises LoRa Basics Station (-s program, version 2). gwmon starts the program as a
 *     child, sees it exit through SIGCHLD and starts it again after a backoff delay. After 5
 *     starts in a row that end early, gwmon gives up and stops feeding the watchdog, so the
 *     board resets.
 *   - It reports gateway health (version 2): uplinks counted from Station's log file (-l) and the
 *     concentrator board temperature read from the WM1302's STTS751 sensor (-T).
 *
 * The design follows the course's aesdsocket: -d daemon mode (fork after the socket is bound),
 * signal handlers that only set a flag or do nothing, syslog, and a thread per client kept in a
 * list and joined by the main thread.
 *
 * Watchdog API used (Documentation/watchdog/watchdog-api.rst in the kernel tree):
 *   - open() starts the watchdog. From then on it must be pinged before the timeout.
 *   - A ping is a write of any byte to the device (same effect as ioctl WDIOC_KEEPALIVE).
 *   - ioctl WDIOC_SETTIMEOUT sets the timeout in seconds and writes back the value really used.
 *   - "Magic close": writing the character 'V' just before close() stops the watchdog. A close
 *     without it (a crash, kill -9) leaves the watchdog running, the kernel pings it one last
 *     time and logs "watchdog0: watchdog left running", and the board resets when the timeout
 *     runs out. With CONFIG_WATCHDOG_NOWAYOUT=y (or the driver's nowayout=1 parameter) even the
 *     magic close does not stop it.
 *
 * The Pi 5's watchdog, read from the kernel source this image pins (raspberrypi/linux 21b41014,
 * 6.12.61) and confirmed on the board on 2026-11-12 (docs/issue6-gwmon.md):
 *   - Driver bcm2835-wdt (CONFIG_BCM2835_WDT=y in bcm2712_defconfig), a child of the
 *     "brcm,bcm2712-pm" node. Identity string "Broadcom BCM2835 Watchdog timer", options
 *     WDIOF_SETTIMEOUT | WDIOF_MAGICCLOSE | WDIOF_KEEPALIVEPING (0x8180).
 *   - Default timeout 15 s, minimum 1 s. The hardware counter holds at most 15.999 s
 *     (max_hw_heartbeat_ms); the watchdog core accepts longer timeouts and pings the hardware
 *     itself in between. gwmon asks for 10 s and the driver reports 10 s back.
 *   - CONFIG_WATCHDOG_NOWAYOUT is not set (sysfs nowayout is 0), so the magic close works.
 *   - Measured: the Pi resets 10.0 to 10.5 s after kill -9 of gwmon and boots again by itself.
 *
 * Supervision rules (docs/issue7-gwmon-v2.md has the measurements):
 *   - The child runs in its own process group, with the default signal dispositions and an
 *     empty signal mask. PR_SET_PDEATHSIG sends it SIGTERM if gwmon dies, so no Station outlives
 *     its supervisor.
 *   - Nothing in the supervision blocks the main loop: fork() and exec, waitpid(WNOHANG), and a
 *     one-shot timerfd for the backoff delay. The watchdog feed stays in the same loop.
 *   - A start "fails" when the child ends less than stable_s seconds (-S, default 30) after it
 *     was started. The delay before the next start is 1 s after a run that lasted longer, and
 *     2, 4, 8, 16 s after the 1st to 4th failed start in a row. The 5th failed start in a row
 *     (-r) ends the supervision: state "failed", no more watchdog feeds.
 *   - Exit status 78 (EX_CONFIG in sysexits.h) means "nothing to run": the wrapper script uses
 *     it when no CUPS or LNS address is provisioned. gwmon then does not restart the child and
 *     keeps feeding the watchdog, so a gateway without credentials does not reboot in a loop.
 *
 * Shutdown rules:
 *   - SIGINT or SIGTERM: magic close first, then Station is stopped (SIGTERM to its process
 *     group, SIGKILL after 5 s), then the rest of the cleanup. The Pi keeps running.
 *   - Anything else that ends the process (SIGKILL, a crash, SIGHUP, a fatal error in the main
 *     loop) leaves the watchdog armed on purpose: the Pi resets wd_timeout seconds later.
 *
 * This file was partially generated using Claude Code using the chat sessions at:
 * Link to chat session (issue #6): https://claude.ai/code/cshk_01CSAPnx7BhY3Nsk5bW261b3NkPKAXvdTJyxZN6b8vcSPT
 * Link to chat session (issue #7): TODO(issue-7-session-link)
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <linux/watchdog.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define GWMON_VERSION "2.0.0"

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
#ifndef GWMON_DEFAULT_MAX_FAILS
#define GWMON_DEFAULT_MAX_FAILS 5  /* issue #7: give up after 5 tries */
#endif
#ifndef GWMON_DEFAULT_STABLE_S
#define GWMON_DEFAULT_STABLE_S 30  /* a run at least this long is not a failed start */
#endif

#define LISTEN_BACKLOG 8
#define MAX_CLIENTS 8          /* concurrent client threads; further connections are closed */
#define CLIENT_SEND_TIMEOUT_S 2
#define CLIENT_DRAIN_MS 500    /* how long to wait for the client to close its side */
#define STATUS_LINE_MAX 512

#define BACKOFF_BASE_S 1       /* restart delay after a run of stable_s or more */
#define BACKOFF_MAX_S 60       /* upper limit of the doubling delay (reached only with -r above 6) */
#define STOP_WAIT_MS 5000      /* SIGTERM to SIGKILL when gwmon stops Station */
#define EXIT_NOT_CONFIGURED 78 /* EX_CONFIG: the child has nothing to run and must not be restarted */

/* Station writes this, at log level VERBOSE, for each frame it has passed on to the LNS. */
#define UPLINK_MARK "[S2E:VERB] RX "
#define TAIL_LINE_MAX 512                /* the mark is in the first 40 characters of a line */
#define TAIL_MAX_BYTES (1024 * 1024)     /* most log data read in one pass of the main loop */

/*
 * The WM1302's temperature sensor, an ST STTS751 on the Pi's I2C bus 1 (the address list is
 * I2C_PORT_TEMP_SENSOR in the HAL's loragw_stts751.h; the board answers at 0x39). The HAL inside
 * Station reads the same sensor for its RSSI temperature compensation. Register numbers are from
 * the HAL and from the kernel's drivers/hwmon/stts751.c.
 */
#define STTS751_ADDR 0x39
#define STTS751_REG_TEMP_H 0x00          /* integer part, two's complement */
#define STTS751_REG_TEMP_L 0x02          /* fraction in the top 4 bits, 1/16 degree each */
#define STTS751_REG_MANUFACTURER 0xFE
#define STTS751_MANUFACTURER_ST 0x53

struct config {
	bool daemonize;
	int port;
	const char *wd_path;       /* "none" turns the watchdog off */
	int wd_timeout_s;
	int wd_interval_s;
	const char *station_cmd;   /* -s: the program to supervise; NULL = no supervision */
	const char *log_path;      /* -l: Station's log file, read for uplinks; NULL = off */
	const char *temp_path;     /* -T: I2C bus device of the STTS751; NULL = off */
	int max_fails;             /* -r: failed starts in a row before gwmon gives up */
	int stable_s;              /* -S: a run this long is not a failed start */
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

enum st_state {
	ST_OFF,                    /* no -s option, or stopped at shutdown */
	ST_RUNNING,                /* the child is running */
	ST_BACKOFF,                /* the child has ended; the restart timer is running */
	ST_FAILED,                 /* max_fails starts in a row failed: no restarts, no feeds */
	ST_UNCONFIGURED,           /* the child said it has nothing to run (exit status 78) */
};

struct supervisor {
	enum st_state state;
	pid_t pid;                 /* the running child, or 0 */
	struct timespec started;   /* CLOCK_MONOTONIC, when the last child was started */
	unsigned long starts;
	unsigned long restarts;    /* starts after the first one */
	int fails;                 /* starts in a row that ended before stable_s */
};

struct health {
	bool log_seen;             /* Station's log file has been opened at least once */
	unsigned long uplinks;
	bool have_uplink;
	struct timespec last_uplink; /* CLOCK_MONOTONIC, when gwmon read the line */
	bool temp_valid;           /* the last temperature read worked */
	double temp_c;
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
	.max_fails = GWMON_DEFAULT_MAX_FAILS,
	.stable_s = GWMON_DEFAULT_STABLE_S,
};

/*
 * g_wd, g_sup and g_health are written by the main thread only and read by the client threads.
 * Every write, and every read outside the main thread, is under g_lock.
 */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct watchdog g_wd = { .fd = -1, .state = WD_DISABLED };
static struct supervisor g_sup = { .state = ST_OFF };
static struct health g_health;

/* Used by the main thread only. */
static int g_restart_fd = -1;  /* one-shot timerfd: the backoff delay before a restart */
static struct {
	int fd;                    /* Station's log file, or -1 */
	ino_t ino;                 /* its inode, to notice that Station has rotated the log */
	char line[TAIL_LINE_MAX];  /* the line being put together */
	size_t len;
} g_tail = { .fd = -1 };
static struct {
	int fd;                    /* the I2C bus device, or -1 */
	bool fake;                 /* a regular file with a number in it: host test mode */
	bool failed;               /* the last read failed (for logging the change only) */
} g_temp = { .fd = -1 };

static struct timespec g_start; /* CLOCK_MONOTONIC at start; set before any thread exists */

/* The client list is used by the main thread only. */
static SLIST_HEAD(client_list, client) g_clients = SLIST_HEAD_INITIALIZER(g_clients);
static int g_nclients;

static volatile sig_atomic_t g_signal; /* the signal that asked gwmon to stop, or 0 */

static void on_signal(int signo)
{
	g_signal = signo;
}

/* SIGCHLD only has to end the ppoll() wait: the main loop then asks waitpid() what happened. */
static void on_sigchld(int signo)
{
	(void)signo;
}

static long long seconds_between(const struct timespec *from, const struct timespec *to)
{
	return (long long)to->tv_sec - (long long)from->tv_sec - (to->tv_nsec < from->tv_nsec ? 1 : 0);
}

/* ---------------------------------------------------------------- watchdog */

static void wd_set_state(enum wd_state state, int fd, int timeout_s)
{
	pthread_mutex_lock(&g_lock);
	g_wd.state = state;
	g_wd.fd = fd;
	g_wd.timeout_s = timeout_s;
	g_wd.feed_failed = false;
	pthread_mutex_unlock(&g_lock);
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
	/* Issue #7: once the supervisor has given up on Station, the watchdog is left to expire. */
	if (g_sup.state == ST_FAILED)
		return;

	failed = write(g_wd.fd, &ping, 1) != 1;
	if (failed)
		err = errno;

	pthread_mutex_lock(&g_lock);
	was_failed = g_wd.feed_failed;
	g_wd.feed_failed = failed;
	if (!failed) {
		g_wd.feeds++;
		clock_gettime(CLOCK_MONOTONIC, &g_wd.last_feed);
	}
	pthread_mutex_unlock(&g_lock);

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
	 * for a watchdog. O_CLOEXEC: Station must not inherit the watchdog.
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

	pthread_mutex_lock(&g_lock);
	g_wd.fd = -1;
	g_wd.state = WD_DISABLED;
	pthread_mutex_unlock(&g_lock);
}

/* ------------------------------------------------------ Station supervision */

/*
 * In the forked child: become a process group of its own and run the program. gwmon has
 * threads, so only async-signal-safe calls are allowed between fork() and exec.
 */
static void sup_child(pid_t parent)
{
	sigset_t none;

	setpgid(0, 0);
	/* SIGTERM for this process when gwmon dies. The setting is kept across exec. */
	prctl(PR_SET_PDEATHSIG, SIGTERM);
	if (getppid() != parent)
		_exit(EXIT_FAILURE); /* gwmon died before the prctl() call */

	/* exec resets handlers to the default but keeps "ignored" and the signal mask. */
	signal(SIGPIPE, SIG_DFL);
	sigemptyset(&none);
	sigprocmask(SIG_SETMASK, &none, NULL);

	execl(g_cfg.station_cmd, g_cfg.station_cmd, (char *)NULL);
	_exit(127); /* the shell's status for "cannot run the command" */
}

static int backoff_delay_s(int fails)
{
	int delay = BACKOFF_BASE_S;

	for (int i = 0; i < fails && delay < BACKOFF_MAX_S; i++)
		delay *= 2;
	return delay < BACKOFF_MAX_S ? delay : BACKOFF_MAX_S;
}

static void sup_start(void);

/*
 * The child with this pid is gone (or could not be forked). Decide what happens next: nothing
 * (not configured), a restart after the backoff delay, or giving up.
 */
static void sup_ended(pid_t pid, const char *how, bool not_configured)
{
	struct itimerspec delay = { 0 };
	struct timespec now;
	enum st_state state;
	long long ran;
	int fails;

	clock_gettime(CLOCK_MONOTONIC, &now);
	ran = seconds_between(&g_sup.started, &now);
	syslog(LOG_WARNING, "station (pid %d) %s after %lld s", (int)pid, how, ran);

	if (not_configured) {
		state = ST_UNCONFIGURED;
		fails = 0;
	} else {
		fails = ran >= g_cfg.stable_s ? 0 : g_sup.fails + 1;
		state = fails >= g_cfg.max_fails ? ST_FAILED : ST_BACKOFF;
	}

	pthread_mutex_lock(&g_lock);
	g_sup.pid = 0;
	g_sup.fails = fails;
	g_sup.state = state;
	pthread_mutex_unlock(&g_lock);

	switch (state) {
	case ST_UNCONFIGURED:
		syslog(LOG_NOTICE, "station has nothing to run (exit status %d): not restarting it, "
		       "the watchdog is still fed", EXIT_NOT_CONFIGURED);
		break;
	case ST_FAILED:
		if (g_wd.fd >= 0)
			syslog(LOG_CRIT, "station failed %d starts in a row: giving up. The watchdog is "
			       "no longer fed and resets the board within %d s", fails, g_wd.timeout_s);
		else
			syslog(LOG_CRIT, "station failed %d starts in a row: giving up. No watchdog is "
			       "open, so nothing resets the board", fails);
		break;
	default:
		delay.it_value.tv_sec = backoff_delay_s(fails);
		if (fails > 0)
			syslog(LOG_NOTICE, "restarting station in %d s (failed start %d of %d)",
			       (int)delay.it_value.tv_sec, fails, g_cfg.max_fails);
		else
			syslog(LOG_NOTICE, "restarting station in %d s", (int)delay.it_value.tv_sec);
		if (timerfd_settime(g_restart_fd, 0, &delay, NULL) != 0) {
			syslog(LOG_ERR, "cannot set the restart timer: %s, restarting now", strerror(errno));
			sup_start();
		}
		break;
	}
}

/* Start the supervised program. Returns at once; the exit is picked up by sup_reap(). */
static void sup_start(void)
{
	pid_t parent = getpid();
	unsigned long restarts;
	pid_t pid;
	int err;

	pid = fork();
	if (pid == 0)
		sup_child(parent); /* does not return */
	err = errno;

	pthread_mutex_lock(&g_lock);
	if (g_sup.starts++ > 0)
		g_sup.restarts++;
	restarts = g_sup.restarts;
	clock_gettime(CLOCK_MONOTONIC, &g_sup.started);
	g_sup.pid = pid > 0 ? pid : 0;
	g_sup.state = ST_RUNNING;
	pthread_mutex_unlock(&g_lock);

	if (pid < 0) {
		syslog(LOG_ERR, "cannot fork for %s: %s", g_cfg.station_cmd, strerror(err));
		sup_ended(0, "could not be started", false);
		return;
	}
	/* Also set here, so the group exists whichever of the two processes runs first. */
	setpgid(pid, pid);

	if (restarts > 0)
		syslog(LOG_NOTICE, "station restart %lu: started %s, pid %d", restarts,
		       g_cfg.station_cmd, (int)pid);
	else
		syslog(LOG_INFO, "station started: %s, pid %d", g_cfg.station_cmd, (int)pid);
}

/* Ask, without waiting, whether the child has ended. Called on every pass of the main loop. */
static void sup_reap(void)
{
	pid_t pid = g_sup.pid;
	char how[64];
	int wstatus;
	pid_t rc;

	if (pid <= 0)
		return;
	rc = waitpid(pid, &wstatus, WNOHANG);
	if (rc == 0 || (rc < 0 && errno == EINTR))
		return;

	if (rc < 0) {
		snprintf(how, sizeof(how), "is gone (waitpid: %s)", strerror(errno));
		sup_ended(pid, how, false);
	} else if (WIFEXITED(wstatus)) {
		snprintf(how, sizeof(how), "exited with status %d", WEXITSTATUS(wstatus));
		sup_ended(pid, how, WEXITSTATUS(wstatus) == EXIT_NOT_CONFIGURED);
	} else if (WIFSIGNALED(wstatus)) {
		snprintf(how, sizeof(how), "was killed by signal %d", WTERMSIG(wstatus));
		sup_ended(pid, how, false);
	}
}

/*
 * Stop the child at shutdown: SIGTERM to its process group, SIGKILL if it is still there after
 * STOP_WAIT_MS. The watchdog is already closed when this runs, so the wait cannot reset the board.
 */
static void sup_stop(void)
{
	const struct timespec step = { .tv_nsec = 50 * 1000 * 1000 };
	pid_t pid = g_sup.pid;
	bool killed = false;
	int wstatus;

	if (pid > 0) {
		if (kill(-pid, SIGTERM) != 0)
			kill(pid, SIGTERM);
		for (int waited = 0; waitpid(pid, &wstatus, WNOHANG) == 0; waited += 50) {
			if (waited >= STOP_WAIT_MS) {
				killed = true;
				kill(-pid, SIGKILL);
				kill(pid, SIGKILL);
				waitpid(pid, &wstatus, 0);
				break;
			}
			nanosleep(&step, NULL);
		}
		syslog(LOG_INFO, "station (pid %d) stopped%s", (int)pid,
		       killed ? " with SIGKILL: it did not end on SIGTERM" : "");
	}

	pthread_mutex_lock(&g_lock);
	g_sup.pid = 0;
	g_sup.state = ST_OFF;
	pthread_mutex_unlock(&g_lock);
}

/* ---------------------------------------------------- uplinks from the log */

/* One complete line of Station's log is in g_tail.line. */
static void tail_line(void)
{
	if (strstr(g_tail.line, UPLINK_MARK) == NULL)
		return;
	pthread_mutex_lock(&g_lock);
	g_health.uplinks++;
	g_health.have_uplink = true;
	clock_gettime(CLOCK_MONOTONIC, &g_health.last_uplink);
	pthread_mutex_unlock(&g_lock);
}

/* Cut the data into lines. A line longer than the buffer is tested on its beginning only. */
static void tail_bytes(const char *data, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		if (data[i] == '\n') {
			g_tail.line[g_tail.len] = '\0';
			tail_line();
			g_tail.len = 0;
		} else if (g_tail.len < sizeof(g_tail.line) - 1) {
			g_tail.line[g_tail.len++] = data[i];
		}
	}
}

/*
 * Open Station's log. at_end skips what is already in the file: lines from before gwmon started
 * are not counted. Returns false when there is no log file (yet).
 */
static bool tail_open(bool at_end)
{
	struct stat st;
	int fd = open(g_cfg.log_path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);

	if (fd < 0)
		return false;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || (at_end && lseek(fd, 0, SEEK_END) < 0)) {
		close(fd);
		return false;
	}
	g_tail.fd = fd;
	g_tail.ino = st.st_ino;
	g_tail.len = 0;

	pthread_mutex_lock(&g_lock);
	g_health.log_seen = true;
	pthread_mutex_unlock(&g_lock);
	return true;
}

/*
 * Read what Station has added to its log since the last call. Station rotates the log by
 * renaming it and creating a new file, so at the end of the open file the path is checked: if
 * it names another file now, that one is read from its beginning.
 */
static void tail_poll(void)
{
	size_t budget = TAIL_MAX_BYTES;
	bool switched = false;
	char buf[4096];
	struct stat st;

	if (g_cfg.log_path == NULL)
		return;
	if (g_tail.fd < 0 && !tail_open(false))
		return;

	while (budget > 0) {
		ssize_t n = read(g_tail.fd, buf, budget < sizeof(buf) ? budget : sizeof(buf));

		if (n > 0) {
			tail_bytes(buf, (size_t)n);
			budget -= (size_t)n;
			continue;
		}
		if (n < 0 && errno == EINTR)
			continue;
		if (n == 0 && stat(g_cfg.log_path, &st) == 0 && st.st_ino == g_tail.ino &&
		    st.st_size >= lseek(g_tail.fd, 0, SEEK_CUR))
			return; /* the same file, and nothing new in it */

		/* A read error, or the path is another file now (or is gone, or was cut short). */
		close(g_tail.fd);
		g_tail.fd = -1;
		if (switched || !tail_open(false))
			return;
		switched = true;
	}
}

/* ------------------------------------------------------------- temperature */

/* Read one register in one combined transfer (write the register number, then read a byte). */
static int stts751_read_reg(int fd, uint8_t reg, uint8_t *value)
{
	struct i2c_msg msgs[2] = {
		{ .addr = STTS751_ADDR, .flags = 0, .len = 1, .buf = &reg },
		{ .addr = STTS751_ADDR, .flags = I2C_M_RD, .len = 1, .buf = value },
	};
	struct i2c_rdwr_ioctl_data xfer = { .msgs = msgs, .nmsgs = 2 };

	return ioctl(fd, I2C_RDWR, &xfer) == 2 ? 0 : -1;
}

/*
 * The temperature is two registers. The integer part is read before and after the fraction and
 * the value is used when both reads agree, so the two parts are from the same conversion
 * whatever the sensor does between the reads.
 */
static bool stts751_read(int fd, double *celsius)
{
	uint8_t high, low, high2;

	for (int attempt = 0; attempt < 3; attempt++) {
		if (stts751_read_reg(fd, STTS751_REG_TEMP_H, &high) != 0 ||
		    stts751_read_reg(fd, STTS751_REG_TEMP_L, &low) != 0 ||
		    stts751_read_reg(fd, STTS751_REG_TEMP_H, &high2) != 0)
			return false;
		if (high == high2) {
			*celsius = ((int8_t)high * 256 + low) / 256.0;
			return true;
		}
	}
	return false;
}

/* Host test mode: the "sensor" is a text file with the temperature in it. */
static bool temp_read_file(int fd, double *celsius)
{
	char text[32], *end;
	ssize_t n = pread(fd, text, sizeof(text) - 1, 0);

	if (n <= 0)
		return false;
	text[n] = '\0';
	errno = 0;
	*celsius = strtod(text, &end);
	return errno == 0 && end != text;
}

static void temp_poll(void)
{
	double celsius = 0;
	bool ok;

	if (g_temp.fd < 0)
		return;
	ok = g_temp.fake ? temp_read_file(g_temp.fd, &celsius) : stts751_read(g_temp.fd, &celsius);

	pthread_mutex_lock(&g_lock);
	g_health.temp_valid = ok;
	if (ok)
		g_health.temp_c = celsius;
	pthread_mutex_unlock(&g_lock);

	/* Log the change only. */
	if (!ok && !g_temp.failed)
		syslog(LOG_WARNING, "temperature read from %s failed", g_cfg.temp_path);
	else if (ok && g_temp.failed)
		syslog(LOG_NOTICE, "temperature read works again");
	g_temp.failed = !ok;
}

/*
 * Open the I2C bus for the temperature sensor. gwmon only reads. It never writes a register, so
 * the configuration the HAL gives the sensor when Station starts is left alone, and each read
 * is one combined transfer, as the HAL's reads are, so the two users cannot mix up their steps.
 */
static void temp_open(void)
{
	struct stat st;
	uint8_t id = 0;
	int fd;

	if (g_cfg.temp_path == NULL)
		return;
	fd = open(g_cfg.temp_path, O_RDWR | O_CLOEXEC);
	if (fd < 0 || fstat(fd, &st) != 0) {
		syslog(LOG_WARNING, "cannot open %s for the temperature sensor: %s", g_cfg.temp_path,
		       strerror(errno));
		if (fd >= 0)
			close(fd);
		return;
	}
	if (!S_ISCHR(st.st_mode)) {
		syslog(LOG_WARNING, "%s is not a character device: test mode, the temperature is the "
		       "number in that file", g_cfg.temp_path);
		g_temp.fake = true;
	} else if (stts751_read_reg(fd, STTS751_REG_MANUFACTURER, &id) != 0 ||
		   id != STTS751_MANUFACTURER_ST) {
		syslog(LOG_WARNING, "no STTS751 temperature sensor at 0x%02x on %s", STTS751_ADDR,
		       g_cfg.temp_path);
		close(fd);
		return;
	}
	g_temp.fd = fd;
	temp_poll();
}

/* ------------------------------------------------------------------ status */

static const char *wd_state_name(const struct watchdog *wd, const struct supervisor *sup)
{
	if (wd->fd >= 0 && sup->state == ST_FAILED)
		return "starving"; /* open, but no longer fed: the supervisor has given up */
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

static const char *st_state_name(enum st_state state)
{
	switch (state) {
	case ST_RUNNING:
		return "running";
	case ST_BACKOFF:
		return "backoff";
	case ST_FAILED:
		return "failed";
	case ST_UNCONFIGURED:
		return "unconfigured";
	case ST_OFF:
	default:
		return "off";
	}
}

/* Add formatted text to the status line. Text that does not fit is cut off. */
__attribute__((format(printf, 4, 5)))
static void status_add(char *buf, size_t size, size_t *len, const char *fmt, ...)
{
	va_list ap;
	int n;

	if (*len >= size - 1)
		return;
	va_start(ap, fmt);
	n = vsnprintf(buf + *len, size - *len, fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	*len = (size_t)n < size - *len ? *len + (size_t)n : size - 1;
}

/*
 * Write the status line, newline included, into buf. Returns its length. The version 1 fields
 * come first and are unchanged. The Station, uplink and temperature fields follow, each group
 * only when its option (-s, -l, -T) was given.
 */
static size_t format_status(char *buf, size_t size)
{
	struct timespec now, boot;
	struct supervisor sup;
	struct watchdog wd;
	struct health health;
	size_t len = 0;

	clock_gettime(CLOCK_MONOTONIC, &now);
	clock_gettime(CLOCK_BOOTTIME, &boot); /* time since boot, including suspend */

	pthread_mutex_lock(&g_lock);
	wd = g_wd;
	sup = g_sup;
	health = g_health;
	pthread_mutex_unlock(&g_lock);

	status_add(buf, size - 1, &len, "gwmon %s uptime=%llds daemon_uptime=%llds watchdog=%s",
		   GWMON_VERSION, (long long)boot.tv_sec, seconds_between(&g_start, &now),
		   wd_state_name(&wd, &sup));
	if (wd.fd >= 0)
		status_add(buf, size - 1, &len,
			   " wd_timeout=%ds wd_interval=%ds wd_feeds=%lu wd_last_feed_age=%llds",
			   wd.timeout_s, g_cfg.wd_interval_s, wd.feeds,
			   seconds_between(&wd.last_feed, &now));

	if (g_cfg.station_cmd != NULL) {
		long long run_s = sup.state == ST_RUNNING ? seconds_between(&sup.started, &now) : 0;
		/*
		 * The supervisor resets its count of failed starts when a run of stable_s or more
		 * ends. The status shows 0 as soon as the current run has reached stable_s, so a
		 * Station that has recovered is not reported with an old count.
		 */
		int fails = (sup.state == ST_RUNNING && run_s >= g_cfg.stable_s) ? 0 : sup.fails;

		status_add(buf, size - 1, &len,
			   " station=%s station_pid=%d station_uptime=%llds station_restarts=%lu"
			   " station_fails=%d",
			   st_state_name(sup.state), (int)sup.pid, run_s, sup.restarts, fails);
	}

	if (g_cfg.log_path != NULL) {
		if (health.log_seen)
			status_add(buf, size - 1, &len, " uplinks=%lu", health.uplinks);
		else
			status_add(buf, size - 1, &len, " uplinks=unavailable");
		if (health.have_uplink)
			status_add(buf, size - 1, &len, " last_uplink_age=%llds",
				   seconds_between(&health.last_uplink, &now));
		else
			status_add(buf, size - 1, &len, " last_uplink_age=never");
	}

	if (g_cfg.temp_path != NULL) {
		if (health.temp_valid)
			status_add(buf, size - 1, &len, " temp=%.1fC", health.temp_c);
		else
			status_add(buf, size - 1, &len, " temp=unavailable");
	}

	/* status_add() was given one byte less than the buffer, so the newline always fits. */
	buf[len++] = '\n';
	buf[len] = '\0';
	return len;
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
		"gwmon %s - gateway monitor: TCP status server, hardware watchdog, Station supervisor\n"
		"Usage: %s [-d] [-p port] [-w device] [-t seconds] [-i seconds]\n"
		"       [-s program] [-r count] [-S seconds] [-l logfile] [-T i2c-device]\n"
		"  -d          run as a daemon\n"
		"  -p port     TCP status port (default %d)\n"
		"  -w device   watchdog device (default %s); \"none\" turns the watchdog off\n"
		"  -t seconds  watchdog timeout (default %d)\n"
		"  -i seconds  watchdog feed interval, below the timeout (default %d)\n"
		"  -s program  start this program (Basics Station) and restart it when it exits;\n"
		"              exit status %d means \"nothing to run, do not restart\"\n"
		"  -r count    failed starts in a row before gwmon gives up and stops feeding the\n"
		"              watchdog (default %d)\n"
		"  -S seconds  a run shorter than this is a failed start (default %d)\n"
		"  -l logfile  count uplinks from this Station log file\n"
		"  -T device   I2C bus of the WM1302's STTS751 temperature sensor, e.g. /dev/i2c-1\n"
		"  -v          print the version\n",
		GWMON_VERSION, prog, GWMON_DEFAULT_PORT, GWMON_DEFAULT_WATCHDOG, GWMON_DEFAULT_TIMEOUT_S,
		GWMON_DEFAULT_INTERVAL_S, EXIT_NOT_CONFIGURED, GWMON_DEFAULT_MAX_FAILS,
		GWMON_DEFAULT_STABLE_S);
}

static bool parse_args(int argc, char **argv)
{
	int opt;

	while ((opt = getopt(argc, argv, "dp:w:t:i:s:r:S:l:T:vh")) != -1) {
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
		case 's':
			g_cfg.station_cmd = optarg;
			break;
		case 'r':
			if (!parse_int(optarg, 1, 100, &g_cfg.max_fails))
				return false;
			break;
		case 'S':
			if (!parse_int(optarg, 1, 86400, &g_cfg.stable_s))
				return false;
			break;
		case 'l':
			g_cfg.log_path = optarg;
			break;
		case 'T':
			g_cfg.temp_path = optarg;
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
	struct sigaction sa_chld = { .sa_handler = on_sigchld, .sa_flags = SA_NOCLDSTOP };
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
	 * SIGINT, SIGTERM and SIGCHLD stay blocked except while the main thread waits in ppoll(),
	 * so a signal cannot be missed between the loop test and the wait. Threads inherit the
	 * blocked mask, so the main thread is the only one that takes these signals.
	 */
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGINT);
	sigaddset(&blocked, SIGTERM);
	sigaddset(&blocked, SIGCHLD);
	sigprocmask(SIG_BLOCK, &blocked, &wait_mask);
	sigdelset(&wait_mask, SIGINT);
	sigdelset(&wait_mask, SIGTERM);
	sigdelset(&wait_mask, SIGCHLD);
	sigemptyset(&sa.sa_mask);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigemptyset(&sa_chld.sa_mask);
	sigaction(SIGCHLD, &sa_chld, NULL);
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
	g_restart_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	period.it_value.tv_sec = g_cfg.wd_interval_s;
	period.it_interval.tv_sec = g_cfg.wd_interval_s;
	if (timer_fd < 0 || g_restart_fd < 0 || timerfd_settime(timer_fd, 0, &period, NULL) != 0) {
		syslog(LOG_ERR, "cannot start the timers: %s", strerror(errno));
		if (timer_fd >= 0)
			close(timer_fd);
		if (g_restart_fd >= 0)
			close(g_restart_fd);
		close(listen_fd);
		closelog();
		return EXIT_FAILURE;
	}

	/* The watchdog is opened in the daemon itself: from here on gwmon must keep feeding. */
	wd_open();
	syslog(LOG_INFO, "gwmon %s started, status on TCP port %d", GWMON_VERSION, g_cfg.port);

	temp_open();
	if (g_cfg.log_path != NULL)
		tail_open(true); /* whatever an earlier Station wrote is not counted */
	if (g_cfg.station_cmd != NULL)
		sup_start();

	/*
	 * The watchdog is fed from this loop, not from a thread of its own, so the feeds stop if the
	 * loop that serves the status port and supervises Station stops. Nothing in the loop waits
	 * for Station: its exit arrives as SIGCHLD, which ends ppoll(), and sup_reap() does not block.
	 */
	while (g_signal == 0) {
		struct pollfd fds[3] = {
			{ .fd = listen_fd, .events = POLLIN },
			{ .fd = timer_fd, .events = POLLIN },
			{ .fd = g_restart_fd, .events = POLLIN },
		};
		uint64_t expirations;

		sup_reap();

		if (ppoll(fds, 3, NULL, &wait_mask) < 0) {
			if (errno == EINTR)
				continue;
			syslog(LOG_CRIT, "ppoll: %s", strerror(errno));
			status = EXIT_FAILURE;
			break;
		}
		if ((fds[1].revents & POLLIN) && read(timer_fd, &expirations, sizeof(expirations)) > 0) {
			wd_feed();
			tail_poll();
			temp_poll();
		}
		if ((fds[2].revents & POLLIN) && read(g_restart_fd, &expirations, sizeof(expirations)) > 0 &&
		    g_sup.state == ST_BACKOFF)
			sup_start();
		if (fds[0].revents & POLLIN)
			accept_client(listen_fd);
		reap_clients(false);
	}

	if (g_signal != 0) {
		syslog(LOG_INFO, "Caught signal %d, exiting", (int)g_signal);
		wd_close(); /* first, so nothing later in the shutdown can run into the timeout */
		sup_stop();
	} else {
		/*
		 * A fatal error is treated like a crash: no magic close, the watchdog resets the board.
		 * Station gets SIGTERM from the kernel when this process ends (PR_SET_PDEATHSIG).
		 */
		syslog(LOG_CRIT, "main loop failed, leaving the watchdog armed");
	}

	close(listen_fd);
	reap_clients(true);
	close(timer_fd);
	close(g_restart_fd);
	if (g_tail.fd >= 0)
		close(g_tail.fd);
	if (g_temp.fd >= 0)
		close(g_temp.fd);
	closelog();
	return status;
}
