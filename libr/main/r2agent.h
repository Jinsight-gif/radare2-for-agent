#ifndef R2AGENT_H
#define R2AGENT_H

#include <r_core.h>

typedef struct r2_agent_options_t {
	const char *socket_path;
	const char *log_path;
	bool foreground;
	int timeout;
} R2AgentOptions;

R_API int r2agent_start(RCore *core, R2AgentOptions *opts);
R_API int r2agent_send(const char *cmd, const char *socket_path, bool json, int timeout, char **out);
R_API const char *r2agent_default_socket_path(void);
R_API const char *r2agent_default_log_path(void);

#endif
