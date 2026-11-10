/*
 * Exercise RainerScript's replace() and wrap() through the real config loader: a fixed rsyslog.conf
 * defines a ruleset that feeds the message text to nested replace()/wrap() calls (the shape of a
 * configuration that exposes replacement to message input), and each fuzz input is one message
 * whose `set` statements are evaluated by the script engine, exactly as execSet() does.
 */
/* rsyslogd.c is included, not linked: its class-init sequence (rsyslogd_InitGlobalClasses) fills static
 * interface tables that the config loader reaches through queryLocalHostname(), so the daemon's own
 * startup code has to run in this translation unit. The build compiles it with -Dmain=rsyslogd_main. */
#include "../tools/rsyslogd.c"

static ruleset_t *fuzzRuleset;
static wti_t *fuzzWti;

/* The first character of the message is the needle, so any run of one repeated byte makes every
 * replace() expand; the replacement is the message itself. */
#define NEEDLE "substring($msg, 0, 1)"
static const char fuzzConfig[] =
    "global(maxMessageSize=\"8192\")\n"
    "ruleset(name=\"fuzz\") {\n"
    "    set $.r = replace(replace(replace($msg, " NEEDLE ", $msg), " NEEDLE ", $msg), " NEEDLE ", $msg);\n"
    "    set $.w = wrap(replace(replace($msg, " NEEDLE ", $msg), " NEEDLE ", $msg), " NEEDLE ", $msg);\n"
    "    set $.v = wrap($msg, $msg);\n"
    "}\n"
    "ruleset(name=\"sink\") {\n"
    "    action(type=\"omfile\" file=\"/dev/null\")\n"
    "}\n";

static void fuzzAbortOnError(const rsRetVal ret) {
    if (ret != RS_RET_OK) abort();
}

static void fuzzIgnoreExpectedError(const int severity __attribute__((unused)),
                                    const int error_number __attribute__((unused)),
                                    const uchar *message __attribute__((unused))) {}

static void fuzzCleanup(void) {
    fuzzAbortOnError(rsrtExit());
}

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerInitialize(int *argc __attribute__((unused)), char ***argv) {
    const char *slash;
    static char modulePath[PATH_MAX];
    const char *tmpdir = getenv("TMPDIR");
    char confPath[PATH_MAX];
    rsconf_t *conf = NULL;
    FILE *fp;
    int len, fd;

    slash = strrchr((*argv)[0], '/');
    if (slash == NULL) {
        len = snprintf(modulePath, sizeof(modulePath), "runtime/.libs");
    } else {
        len = snprintf(modulePath, sizeof(modulePath), "%.*s/../runtime/.libs", (int)(slash - (*argv)[0]), (*argv)[0]);
    }
    if (len < 0 || (size_t)len >= sizeof(modulePath) || setenv("RSYSLOG_MODDIR", modulePath, 1) != 0) abort();

    fuzzAbortOnError(rsyslogd_InitGlobalClasses());
    rsrtSetErrLogger(fuzzIgnoreExpectedError);

    len = snprintf(confPath, sizeof(confPath), "%s/fuzz_rainerscript.XXXXXX", tmpdir != NULL ? tmpdir : "/tmp");
    if (len < 0 || (size_t)len >= sizeof(confPath)) abort();
    fd = mkstemp(confPath);
    if (fd < 0) abort();
    fp = fdopen(fd, "w");
    if (fp == NULL || fputs(fuzzConfig, fp) == EOF || fclose(fp) != 0) abort();
    fuzzAbortOnError(rsconf.Load(&conf, (uchar *)confPath));
    unlink(confPath);

    /* rsconf.Activate() would start the queues and worker threads; the script engine only needs runConf. */
    runConf = conf;
    fuzzAbortOnError(rulesetGetRuleset(conf, &fuzzRuleset, (uchar *)"fuzz"));
    fuzzAbortOnError(wtiConstruct(&fuzzWti));
    if (atexit(fuzzCleanup) != 0) abort();
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, const size_t size) {
    smsg_t *msg = NULL;
    struct cnfstmt *stmt;

    /* Input modules cap a message at the maxMessageSize global (rsyslog docs, "maxMessageSize"). */
    if (size > (size_t)glblGetMaxLine(runConf)) return -1;

    fuzzAbortOnError(msgConstruct(&msg));
    MsgSetRawMsg(msg, (const char *)data, size);
    MsgSetMSGoffs(msg, 0);

    for (stmt = fuzzRuleset->root; stmt != NULL; stmt = stmt->next) {
        struct svar result;
        if (stmt->nodetype != S_SET) abort();
        cnfexprEval(stmt->d.s_set.expr, &result, msg, fuzzWti);
        varDelete(&result);
    }

    fuzzAbortOnError(msgDestruct(&msg));
    return 0;
}
