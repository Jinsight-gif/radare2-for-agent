/* radare2 - LGPL - Copyright 2013-2025 - pancake */

#include "index.h"
#include "r2agent.h"
#include <r_main.h>
#include <r_core.h>
#include <r_socket.h>
#include <r_util/r_json.h>
#include <r_util/pj.h>

#if R2__UNIX__
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#endif


/* ------------------------------------------------------------------ */
/* v1 agent daemon: Unix socket server + client                       */
/* ------------------------------------------------------------------ */

#define R2_AGENT_DEFAULT_SOCKET "/tmp/r2-agent.sock"
#define R2_AGENT_DEFAULT_LOG "/tmp/r2-agent.log"
#define R2_AGENT_DEFAULT_TIMEOUT 30
#define R2_AGENT_MAX_REQUEST (64 * 1024 * 1024)

static FILE *r2agent_log_file = NULL;

R_API const char *r2agent_default_socket_path(void) {
	char *env = r_sys_getenv ("R2_AGENT_SOCK");
	if (R_STR_ISNOTEMPTY (env)) {
		static char buf[4096];
		r_str_ncpy (buf, env, sizeof (buf));
		free (env);
		return buf;
	}
	free (env);
	return R2_AGENT_DEFAULT_SOCKET;
}

R_API const char *r2agent_default_log_path(void) {
	return R2_AGENT_DEFAULT_LOG;
}

static void r2agent_log(const char *fmt, ...) {
	va_list ap;
	if (!r2agent_log_file) {
		return;
	}
	va_start (ap, fmt);
	vfprintf (r2agent_log_file, fmt, ap);
	va_end (ap);
	fflush (r2agent_log_file);
}

static char *r2agent_read_nul(RSocket *s) {
	size_t cap = 4096;
	size_t used = 0;
	char *buf = malloc (cap + 1);
	if (!buf) {
		return NULL;
	}
	while (used < R2_AGENT_MAX_REQUEST) {
		if (used == cap) {
			cap *= 2;
			if (cap > R2_AGENT_MAX_REQUEST) {
				cap = R2_AGENT_MAX_REQUEST;
			}
			char *nbuf = realloc (buf, cap + 1);
			if (!nbuf) {
				free (buf);
				return NULL;
			}
			buf = nbuf;
		}
		int n = r_socket_read (s, (ut8 *)buf + used, (int)(cap - used));
		if (n <= 0) {
			free (buf);
			return NULL;
		}
		used += (size_t)n;
		char *nul = memchr (buf + used - n, 0, (size_t)n);
		if (nul) {
			size_t len = (size_t)(nul - buf);
			char *out = malloc (len + 1);
			if (!out) {
				free (buf);
				return NULL;
			}
			memcpy (out, buf, len);
			out[len] = 0;
			free (buf);
			return out;
		}
	}
	free (buf);
	return NULL;
}

static bool r2agent_write_nul(RSocket *s, const char *buf) {
	size_t len = strlen (buf);
	size_t off = 0;
	while (off < len) {
		int chunk = (len - off > 1400)? 1400: (int)(len - off);
		int n = r_socket_write (s, buf + off, chunk);
		if (n <= 0) {
			return false;
		}
		off += (size_t)n;
	}
	char nul = 0;
	return r_socket_write (s, &nul, 1) == 1;
}

static bool r2agent_is_blacklisted(const char *cmd) {
	static const char *blacklist[] = {
		"V", "VV", "Vv", "Vi", "Vp", "Vk", "Vd", "Vb", "Vm", "Vs", "Vf", "Ve",
		"v", "vv", "ve", "vp", "vk", "vvi",
		NULL
	};
	if (!cmd) {
		return false;
	}
	while (IS_WHITESPACE (*cmd)) {
		cmd++;
	}
	int i;
	for (i = 0; blacklist[i]; i++) {
		const char *b = blacklist[i];
		size_t blen = strlen (b);
		if (!strncmp (cmd, b, blen)) {
			char c = cmd[blen];
			if (!c || IS_WHITESPACE (c) || c == ';' || c == '|' || c == '&' || c == '?' || c == '\n' || c == '\r') {
				return true;
			}
		}
	}
	return false;
}

static bool r2agent_parse_request(const char *req, char **cmd_out, bool *json_out, int *timeout_out) {
	RJson *root = r_json_parsedup (req);
	if (!root || root->type != R_JSON_OBJECT) {
		r_json_free (root);
		return false;
	}
	const RJson *jcmd = r_json_get (root, "cmd");
	if (!jcmd || jcmd->type != R_JSON_STRING) {
		r_json_free (root);
		return false;
	}
	*cmd_out = strdup (jcmd->str_value);
	*json_out = false;
	const RJson *jjson = r_json_get (root, "json");
	if (jjson && jjson->type == R_JSON_BOOLEAN) {
		*json_out = jjson->num.u_value? true: false;
	}
	*timeout_out = R2_AGENT_DEFAULT_TIMEOUT;
	const RJson *jtimeout = r_json_get (root, "timeout");
	if (jtimeout && jtimeout->type == R_JSON_INTEGER) {
		*timeout_out = (int)jtimeout->num.s_value;
	}
	r_json_free (root);
	return true;
}

static char *r2agent_json_response(bool ok, const char *output, bool truncated, bool timed_out, const char *error) {
	PJ *pj = pj_new ();
	pj_o (pj);
	pj_kb (pj, "ok", ok);
	pj_ks (pj, "output", output? output: "");
	pj_kb (pj, "truncated", truncated);
	pj_kb (pj, "timed_out", timed_out);
	if (error) {
		pj_ks (pj, "error", error);
	} else {
		pj_knull (pj, "error");
	}
	pj_end (pj);
	return pj_drain (pj);
}

static char *r2agent_mgmt_open(RCore *core, const char *arg) {
	while (IS_WHITESPACE (*arg)) {
		arg++;
	}
	if (!*arg) {
		return strdup ("error: missing path\n");
	}
	char *tmp = r_core_cmd_str (core, "o--");
	free (tmp);
	RIODesc *fd = r_core_file_open (core, arg, R_PERM_RX, 0);
	if (!fd) {
		return r_str_newf ("error: cannot open %s\n", arg);
	}
	r_core_bin_load (core, arg, UT64_MAX);
	tmp = r_core_cmd_str (core, "aaa");
	free (tmp);
	return r_str_newf ("opened %s\n", arg);
}

static char *r2agent_mgmt_close(RCore *core) {
	char *tmp = r_core_cmd_str (core, "o--");
	free (tmp);
	return strdup ("closed\n");
}

static char *r2agent_mgmt_status(RCore *core, const char *socket_path, bool json) {
	const char *file = (core->io && core->io->desc && core->io->desc->name)? core->io->desc->name: "none";
	bool analyzed = core->anal && core->anal->fcns && r_list_length (core->anal->fcns) > 0;
	if (json) {
		PJ *pj = pj_new ();
		pj_o (pj);
		pj_ki (pj, "pid", r_sys_getpid ());
		pj_ks (pj, "socket", socket_path);
		pj_ks (pj, "file", file);
		pj_kb (pj, "analyzed", analyzed);
		pj_end (pj);
		return pj_drain (pj);
	}
	return r_str_newf ("pid: %d\nsocket: %s\nfile: %s\nanalyzed: %s\n",
		r_sys_getpid (), socket_path, file, analyzed? "yes": "no");
}

static int r2agent_handle_client(RCore *core, RSocket *cli, R2AgentOptions *opts, bool *quit) {
	char *req = r2agent_read_nul (cli);
	if (!req) {
		return -1;
	}
	char *cmd = NULL;
	bool json = false;
	int timeout = R2_AGENT_DEFAULT_TIMEOUT;
	if (!r2agent_parse_request (req, &cmd, &json, &timeout)) {
		const char *err = "error: invalid request\n";
		r2agent_write_nul (cli, err);
		r2agent_log ("invalid request: %s\n", req);
		free (req);
		return 1;
	}
	free (req);
	r_str_trim (cmd);
	r2agent_log ("cmd: %s\n", cmd);
	char *out = NULL;
	bool ok = true;
	bool truncated = false;
	bool timed_out = false;
	const char *error = NULL;
	char *errbuf = NULL;

	if (r2agent_is_blacklisted (cmd)) {
		errbuf = r_str_newf ("error: command rejected: %s\n", cmd);
		error = errbuf;
		ok = false;
	} else if (!strcmp (cmd, "quit")) {
		*quit = true;
		out = strdup ("bye\n");
	} else if (!strcmp (cmd, "close")) {
		out = r2agent_mgmt_close (core);
	} else if (!strcmp (cmd, "status")) {
		const char *sock = (opts && opts->socket_path)? opts->socket_path: r2agent_default_socket_path ();
		out = r2agent_mgmt_status (core, sock, json);
	} else if (!strncmp (cmd, "open ", 5)) {
		out = r2agent_mgmt_open (core, cmd + 5);
		if (r_str_startswith (out, "error:")) {
			errbuf = out;
			error = errbuf;
			out = strdup ("");
			ok = false;
		}
	} else {
		r_cons_break_clear (core->cons);
		r_cons_break_timeout (core->cons, timeout);
		char *res = r_core_cmd_str (core, cmd);
		timed_out = r_cons_is_breaked (core->cons);
		r_cons_break_timeout (core->cons, 0);
		r_cons_break_clear (core->cons);
		if (res) {
			out = res;
		} else {
			out = strdup ("");
		}
		if (timed_out) {
			ok = false;
			errbuf = strdup ("error: command timed out\n");
			error = errbuf;
		}
	}
	if (!out) {
		out = strdup ("");
	}
	if (json) {
		char *resp = r2agent_json_response (ok, out, truncated, timed_out, error);
		r2agent_write_nul (cli, resp);
		free (resp);
	} else if (error) {
		r2agent_write_nul (cli, error);
	} else {
		r2agent_write_nul (cli, out);
	}
	if (error) {
		r2agent_log ("error: %s\n", error);
	}
	free (out);
	free (errbuf);
	free (cmd);
	return 0;
}

static bool r2agent_socket_in_use(const char *socket_path) {
	RSocket *probe = r_socket_new (false);
	if (!probe) {
		return false;
	}
	bool in_use = r_socket_connect_unix (probe, socket_path);
	r_socket_free (probe);
	return in_use;
}

R_API int r2agent_start(RCore *core, R2AgentOptions *opts) {
	const char *socket_path = (opts && opts->socket_path)? opts->socket_path: r2agent_default_socket_path ();
	const char *log_path = (opts && opts->log_path)? opts->log_path: r2agent_default_log_path ();
	bool foreground = opts? opts->foreground: false;
	RSocket *srv = NULL;

	if (r_file_exists (socket_path)) {
		if (r2agent_socket_in_use (socket_path)) {
			R_LOG_ERROR ("r2 agent daemon is already running on %s", socket_path);
			return 1;
		}
#if R2__UNIX__
		unlink (socket_path);
#endif
	}
#if R2__UNIX__
	if (!foreground) {
		srv = r_socket_new (false);
		if (!srv) {
			return 1;
		}
		srv->proto = R_SOCKET_PROTO_UNIX;
		if (!r_socket_listen (srv, socket_path, NULL)) {
			R_LOG_ERROR ("Cannot listen on %s", socket_path);
			r_socket_free (srv);
			return 1;
		}
		listen (srv->fd, 8);
		chmod (socket_path, 0600);
		pid_t pid = fork ();
		if (pid < 0) {
			R_LOG_ERROR ("Cannot fork daemon");
			r_socket_free (srv);
#if R2__UNIX__
			unlink (socket_path);
#endif
			return 1;
		}
		if (pid > 0) {
			printf ("%d\n", pid);
			return 0;
		}
		if (setsid () < 0) {
			R_LOG_ERROR ("Cannot setsid");
		}
	}
#endif
	r2agent_log_file = fopen (log_path, "a");
#if R2__UNIX__
	if (!foreground) {
		int lfd = open (log_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
		if (lfd >= 0) {
			dup2 (lfd, 1);
			dup2 (lfd, 2);
			if (lfd > 2) {
				close (lfd);
			}
		}
	}
#endif
	if (!r2agent_log_file) {
		r2agent_log_file = stderr;
	}
	r_config_set_b (core->config, "scr.interactive", false);
	r_config_set_b (core->config, "scr.prompt", false);
	r_config_set_i (core->config, "scr.color", 0);
	r_config_set_b (core->config, "scr.wheel", false);
	r_config_set (core->config, "scr.pager", "cat");
	if (r_config_get_b (core->config, "cfg.plugins")) {
		r_core_loadlibs (core, R_LIB_LOAD_ALL, NULL);
	}

	if (!srv) {
		srv = r_socket_new (false);
		if (!srv) {
			r2agent_log ("cannot allocate socket\n");
			return 1;
		}
		srv->proto = R_SOCKET_PROTO_UNIX;
		if (!r_socket_listen (srv, socket_path, NULL)) {
			R_LOG_ERROR ("Cannot listen on %s", socket_path);
			r_socket_free (srv);
			return 1;
		}
#if R2__UNIX__
		listen (srv->fd, 8);
		chmod (socket_path, 0600);
#else
		(void)socket_path;
#endif
	}
	r2agent_log ("daemon started on %s pid %d\n", socket_path, r_sys_getpid ());

	bool quit = false;
	while (!quit) {
		RSocket *cli = r_socket_accept (srv);
		if (!cli) {
			if (quit) {
				break;
			}
			continue;
		}
		r2agent_handle_client (core, cli, opts, &quit);
		r_socket_free (cli);
	}

	r_socket_free (srv);
#if R2__UNIX__
	unlink (socket_path);
#endif
	r2agent_log ("daemon stopped\n");
	if (r2agent_log_file && r2agent_log_file != stderr) {
		fclose (r2agent_log_file);
	}
	r2agent_log_file = NULL;
	return 0;
}

R_API int r2agent_send(const char *cmd, const char *socket_path, bool json, int timeout, char **out) {
	const char *sock = socket_path? socket_path: r2agent_default_socket_path ();
	if (timeout <= 0) {
		timeout = R2_AGENT_DEFAULT_TIMEOUT;
	}
	RSocket *s = r_socket_new (false);
	if (!s) {
		return 1;
	}
	if (!r_socket_connect_unix (s, sock)) {
		r_socket_free (s);
		if (out) {
			char *err = r_str_newf ("error: cannot connect to %s\n", sock);
			*out = json? r2agent_json_response (false, "", false, false, err): err;
			if (*out != err) {
				free (err);
			}
		}
		return 1;
	}
	PJ *pj = pj_new ();
	pj_o (pj);
	pj_ks (pj, "cmd", cmd? cmd: "");
	pj_kb (pj, "json", json);
	pj_kn (pj, "timeout", (ut64)timeout);
	pj_end (pj);
	char *req = pj_drain (pj);
	bool wok = r2agent_write_nul (s, req);
	free (req);
	if (!wok) {
		r_socket_free (s);
		return 1;
	}
	int ready = r_socket_ready (s, timeout, 0);
	if (ready <= 0) {
		r_socket_free (s);
		if (out) {
			const char *err = "error: timeout waiting for daemon\n";
			*out = json? r2agent_json_response (false, "", false, true, err): strdup (err);
		}
		return 1;
	}
	char *resp = r2agent_read_nul (s);
	r_socket_free (s);
	if (!resp) {
		if (out) {
			const char *err = "error: cannot read daemon response\n";
			*out = json? r2agent_json_response (false, "", false, false, err): strdup (err);
		}
		return 1;
	}
	if (out) {
		*out = resp;
		if (!json && r_str_startswith (resp, "error:")) {
			return 1;
		}
		if (json) {
			RJson *j = r_json_parsedup (resp);
			bool ok = true;
			if (j && j->type == R_JSON_OBJECT) {
				const RJson *jok = r_json_get (j, "ok");
				if (jok && jok->type == R_JSON_BOOLEAN) {
					ok = jok->num.u_value? true: false;
				}
			}
			r_json_free (j);
			if (!ok) {
				return 1;
			}
		}
	} else {
		free (resp);
	}
	return 0;
}

#if __APPLE__ && (__arm__ || __arm64__ || __aarch64__)
#define USE_IOS_JETSAM 1

#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
extern int memorystatus_control(uint32_t command, pid_t pid, uint32_t flags, void *buffer, size_t buffersize);

#else
#define USE_IOS_JETSAM 0
#endif

static int usage(bool v) {
	printf ("Usage: r2agent [-adhsLjv] [-p port]\n"
	"  -a        listen for everyone (localhost by default)\n"
	"  -d        run in daemon mode (background)\n"
	"  -h        show this help message\n"
	"  -s        run in sandbox mode\n"
	"  -u        enable http authorization access\n"
	"  -t        user:password authentication file\n"
	"  -p [port] specify listening port (defaults to 8080)\n"
	"  -L        list currently loaded r2 sessions and exit\n"
	"  -v        show r2 version information and exit\n"
	"  -j        output JSON when used with -v or -L\n");
	return !v;
}

static RList *auth_tokens_split(char *str) {
	RList *tokens = r_str_split_list (str, "\n", 0);
	RListIter *iter;
	RListIter *tmp;
	char *tok;
	r_list_foreach_safe (tokens, iter, tmp, tok) {
		if (R_STR_ISEMPTY (tok)) {
			r_list_delete (tokens, iter);
		}
	}
	if (r_list_empty (tokens)) {
		r_list_free (tokens);
		return NULL;
	}
	return tokens;
}

R_API int r_main_r2agent(int argc, const char **argv) {
	RSocket *s;
	RCons *cons = NULL;
	RSocketHTTPOptions so = { 0 };
	int c;
	bool dodaemon = false;
	bool dosandbox = false;
	bool listenlocal = true;
	const char *port = "8080";
	const char *httpauthfile = NULL;
	char *pfile = NULL;

	RGetopt opt;
	bool list_sessions = false;
	bool list_json = false;
	bool show_version = false;
	r_getopt_init (&opt, argc, argv, "adhup:t:svLj");
	while ((c = r_getopt_next (&opt)) != -1) {
		switch (c) {
		case 'a':
			listenlocal = false;
			break;
		case 's':
			dosandbox = true;
			break;
		case 'd':
			dodaemon = true;
			break;
		case 'h':
			return usage (true);
		case 'v':
			show_version = true;
			break;
		case 'u':
			so.httpauth = true;
			break;
		case 't':
			httpauthfile = opt.arg;
			break;
		case 'p':
			port = opt.arg;
			break;
		case 'L':
			list_sessions = true;
			break;
		case 'j':
			list_json = true;
			break;
		default:
			return usage (false);
		}
	}
	if (opt.ind != argc) {
		return usage (false);
	}

	if (show_version) {
		int mode = list_json? 'j': 0;
		return r_main_version_print ("r2agent", mode);
	}

	if (list_sessions) {
		RCore *core = r_core_new ();
		if (!core) {
			R_LOG_ERROR ("Unable to create RCore instance");
			return 1;
		}
		const char *cmd = list_json? "=lj": "=l";
		char *out = r_core_cmd_str (core, cmd);
		if (out) {
			printf ("%s\n", out);
			free (out);
		}
		r_core_free (core);
		return 0;
	}

	so.accept_timeout = 0;
	so.timeout = 3;

	if (so.httpauth) {
		if (!httpauthfile) {
			R_LOG_ERROR ("No authentication user list set");
			return usage (false);
		}

		size_t sz;
		pfile = r_file_slurp (httpauthfile, &sz);
		if (pfile) {
			so.authtokens = auth_tokens_split (pfile);
			if (!so.authtokens) {
				R_LOG_ERROR ("Empty list of HTTP users");
				free (pfile);
				return usage (false);
			}
		} else {
			R_LOG_ERROR ("Empty list of HTTP users");
			return usage (false);
		}
	}
#if USE_IOS_JETSAM
	memorystatus_control (MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, r_sys_getpid (), 256, NULL, 0);
#endif
	if (dodaemon) {
#if LIBC_HAVE_FORK
		int pid = r_sys_fork ();
		if (pid > 0) {
			printf ("%d\n", pid);
			return 0;
		}
#endif
	}

	s = r_socket_new (false);
	s->local = listenlocal;
	if (!r_socket_listen (s, port, NULL)) {
		R_LOG_ERROR ("Cannot listen on %d", s->port);
		r_socket_free (s);
		return 1;
	}

	R_LOG_INFO ("http://localhost:%d/", s->port);
	/* Create a pid file in tmpdir/r2/<pid>.pid so r2 (=l) can discover this server */
	char *pidfile = NULL;
	{
		char *tmpdir = r_file_tmpdir ();
		char *tmpdir_r2 = r_str_newf ("%s/r2", tmpdir);
		r_sys_mkdir (tmpdir_r2);
		int pid = r_sys_getpid ();
		char *fn = r_str_newf ("%s/%d.pid", tmpdir_r2, pid);
		char *suri = r_str_newf ("r2web://127.0.0.1:%d/cmd", s->port);
		if (r_file_dump (fn, (const ut8 *)suri, strlen (suri), false)) {
			pidfile = fn; /* keep ownership to remove on exit */
		} else {
			free (fn);
		}
		free (suri);
		free (tmpdir_r2);
		free (tmpdir);
	}

	if (dosandbox && !r_sandbox_enable (true)) {
		R_LOG_ERROR ("Cannot enable the sandbox");
		free (pfile);
		r_list_free (so.authtokens);
		r_socket_free (s);
		if (pidfile) {
			r_file_rm (pidfile);
			free (pidfile);
		}
		return 1;
	}

	cons = r_cons_new ();

	while (!r_cons_is_breaked (cons)) {
		char *res = NULL;
		RSocketHTTPRequest *rs = r_socket_http_accept (s, &so);
		if (!rs) {
			R_LOG_ERROR ("Failed to accept http client");
			continue;
		}
		if (!rs->auth) {
			r_socket_http_response (rs, 401, "", 0, NULL);
			r_socket_http_close (rs);
			r_socket_http_free (rs);
			continue;
		}
		if (!strcmp (rs->method, "GET")) {
			if (r_str_startswith (rs->path, "/proc/kill/")) {
				/* TODO: show page here? */
				int pid = atoi (rs->path + strlen ("/proc/kill/"));
				if (pid > 0) {
#if R2__WINDOWS__
					r_sandbox_kill (pid, 0);
#else
					r_sandbox_kill (pid, SIGKILL);
#endif
				}
			} else if (r_str_startswith (rs->path, "/file/open/")) {
				int session_port = 3000 + r_num_rand (1024);
				char *filename = rs->path + strlen ("/file/open/");
				char *escaped_filename = r_str_escape_sh (filename);
				char *authargs = NULL;
				if (so.httpauth) {
					char *ea = r_str_escape_sh (httpauthfile);
					authargs = r_str_newf ("-e http.auth=true -e \"http.authfile=%s\" ", ea);
					free (ea);
				}
				char *cmd = r_str_newf ("r2 -q %s%s-e http.port=%d -c=h \"%s\"",
					listenlocal? "": "-e http.bind=public ",
					r_str_get (authargs),
					session_port, escaped_filename);

				/* TODO: use r_sys api to get pid when running in bg */
				int pid = r_sys_cmdbg (cmd);
				free (cmd);
				free (authargs);
				free (escaped_filename);

				res = r_str_newf ("<html><body>"
						"<a href='/'>back</a><hr size=1/>"
						" - <a target='_blank' href='http://localhost:%d/'>open</a><br />"
						" - <a href='/proc/kill/%d'>kill</a><br />"
						"</body></html>",
					session_port, pid);
				R_LOG_DEBUG ("child pid %d", pid);
			}
		}
		r_socket_http_response (rs, 200, res? res: page_index, 0, NULL);
		r_socket_http_close (rs);
		r_socket_http_free (rs);
		R_FREE (res);
	}

	r_cons_free (cons);
	free (pfile);
	r_list_free (so.authtokens);
	r_socket_free (s);
	/* Remove pid file created at startup so sessions list stays clean */
	if (pidfile) {
		r_file_rm (pidfile);
		free (pidfile);
	}
	return 0;
}
