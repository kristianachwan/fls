// FLS - watches app memory on macOS and kills an app that uses too much.
//
// Build: clang -O2 -o FLS fls.c
// Usage: ./FLS --help
//
// An "app" is every process inside one .app bundle (Chrome and all its helpers),
// or every process running one executable (all `node` processes).
//
// Each check applies the first rule that matches:
//   1. One process over --limit: kill only that process.
//   2. One app over --limit: kill the whole app.
//   3. All apps together over --total: kill the biggest app.
//
// Memory is phys_footprint, the number in Activity Monitor's Memory column. It
// includes compressed and swapped pages, which `ps` RSS leaves out, so a leak
// that macOS has compressed still counts in full.

#include <getopt.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define MAX_PROCS 16384
#define GB (1024.0 * 1024.0 * 1024.0)
#define TERM_GRACE_SECONDS 5
#define DRY_RUN_LOG_SECONDS 60
#define LIST_ROWS 15

// loginwindow, Dock, Finder and friends. Killing loginwindow logs the user out.
#define PROTECTED_PREFIX "/System/Library/CoreServices/"

typedef struct {
    char *key;
    uint64_t bytes;
    int procs;
} App;

typedef struct {
    pid_t pid;
    int app;
    uint64_t bytes;
} Proc;

extern char **environ;

static App apps[MAX_PROCS];
static Proc procs[MAX_PROCS];
static int app_count, proc_count;
static uint64_t total_bytes;

static void log_line(const char *format, ...) {
    char message[1024], stamp[32];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof message, format, args);
    va_end(args);

    time_t now = time(NULL);
    strftime(stamp, sizeof stamp, "%F %T", localtime(&now));
    printf("%s %s\n", stamp, message);
    fflush(stdout);

    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/Library/Logs/FLS.log", home);
    FILE *file = fopen(path, "a");
    if (!file) return;
    fprintf(file, "%s %s\n", stamp, message);
    fclose(file);
}

static void notify(const char *message) {
    // The message goes in as an argument, so a quote in an app name can't break the script.
    char *argv[] = {"osascript", "-e", "on run argv",
                    "-e", "display notification (item 1 of argv) with title \"FLS\"",
                    "-e", "end run", (char *)message, NULL};
    pid_t pid;
    posix_spawn(&pid, "/usr/bin/osascript", NULL, NULL, argv, environ);
}

// Writes the process's app identity into key: its outermost .app bundle, else its executable path.
static bool app_key(pid_t pid, char key[PROC_PIDPATHINFO_MAXSIZE]) {
    if (proc_pidpath(pid, key, PROC_PIDPATHINFO_MAXSIZE) <= 0) return false;
    char *bundle = strstr(key, ".app/");
    if (bundle) bundle[4] = '\0';
    return true;
}

static const char *app_name(const App *app) {
    const char *slash = strrchr(app->key, '/');
    return slash ? slash + 1 : app->key;
}

static int find_or_add_app(const char *key) {
    for (int i = 0; i < app_count; i++) {
        if (strcmp(apps[i].key, key) == 0) return i;
    }
    apps[app_count] = (App){.key = strdup(key)};
    return app_count++;
}

static void scan(const char *only) {
    static pid_t pids[MAX_PROCS];

    for (int i = 0; i < app_count; i++) free(apps[i].key);
    app_count = proc_count = 0;
    total_bytes = 0;

    int pid_count = proc_listallpids(pids, sizeof pids);
    for (int i = 0; i < pid_count; i++) {
        struct rusage_info_v0 usage;
        char key[PROC_PIDPATHINFO_MAXSIZE];

        if (pids[i] == getpid()) continue;
        // This fails for other users' processes (root daemons), so FLS only sees your own.
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V0, (rusage_info_t *)&usage) != 0) continue;
        if (!app_key(pids[i], key)) continue;
        if (only && !strstr(key, only)) continue;

        int app = find_or_add_app(key);
        apps[app].bytes += usage.ri_phys_footprint;
        apps[app].procs++;
        total_bytes += usage.ri_phys_footprint;
        procs[proc_count++] = (Proc){.pid = pids[i], .app = app, .bytes = usage.ri_phys_footprint};
    }
}

static bool is_protected(int app) {
    return strncmp(apps[app].key, PROTECTED_PREFIX, strlen(PROTECTED_PREFIX)) == 0;
}

static int biggest_killable_app(void) {
    int biggest = -1;
    for (int i = 0; i < app_count; i++) {
        if (is_protected(i)) continue;
        if (biggest < 0 || apps[i].bytes > apps[biggest].bytes) biggest = i;
    }
    return biggest;
}

static int biggest_killable_proc(void) {
    int biggest = -1;
    for (int i = 0; i < proc_count; i++) {
        if (is_protected(procs[i].app)) continue;
        if (biggest < 0 || procs[i].bytes > procs[biggest].bytes) biggest = i;
    }
    return biggest;
}

static void proc_label(int proc, char *label, size_t size) {
    char name[64] = "";
    proc_name(procs[proc].pid, name, sizeof name);
    snprintf(label, size, "%s, pid %d", name[0] ? name : app_name(&apps[procs[proc].app]), procs[proc].pid);
}

// True if procs[proc] is being stopped: every process of the app, or just the one pid if set.
static bool is_selected(int proc, int app, pid_t pid) {
    return procs[proc].app == app && (!pid || procs[proc].pid == pid);
}

static void stop(int app, pid_t pid, const char *target, const char *why) {
    char message[512];
    snprintf(message, sizeof message, "Killed %s: %s", target, why);
    log_line("%s", message);
    notify(message);

    for (int i = 0; i < proc_count; i++) {
        if (is_selected(i, app, pid)) kill(procs[i].pid, SIGTERM);
    }
    sleep(TERM_GRACE_SECONDS);

    int forced = 0;
    for (int i = 0; i < proc_count; i++) {
        char key[PROC_PIDPATHINFO_MAXSIZE];
        // Compare the path too, in case the pid was reused during the wait.
        if (is_selected(i, app, pid) && app_key(procs[i].pid, key) &&
            strcmp(key, apps[app].key) == 0 && kill(procs[i].pid, SIGKILL) == 0) {
            forced++;
        }
    }
    if (forced) {
        log_line("Force-killed %d process%s of %s that ignored SIGTERM", forced, forced == 1 ? "" : "es",
                 app_name(&apps[app]));
    }
}

static int by_bytes_descending(const void *a, const void *b) {
    uint64_t left = ((const App *)a)->bytes, right = ((const App *)b)->bytes;
    return left < right ? 1 : left > right ? -1 : 0;
}

static void print_list(void) {
    // Sorting reorders apps, so read the biggest process first while its app index is still valid.
    int biggest = biggest_killable_proc();
    char label[128] = "";
    if (biggest >= 0) proc_label(biggest, label, sizeof label);

    qsort(apps, app_count, sizeof apps[0], by_bytes_descending);
    printf("%9s %6s  %s\n", "MEMORY", "PROCS", "APP");
    for (int i = 0; i < app_count && i < LIST_ROWS; i++) {
        printf("%6.2f GB %6d  %s\n", apps[i].bytes / GB, apps[i].procs, app_name(&apps[i]));
    }
    if (biggest >= 0) printf("%6.2f GB %6d  biggest process: %s\n", procs[biggest].bytes / GB, 1, label);
    printf("%6.2f GB %6d  total, %d apps\n", total_bytes / GB, proc_count, app_count);
}

static void print_help(void) {
    puts("FLS - kills an app when it uses too much memory.\n"
         "\n"
         "  ./FLS            Watch memory and kill any process or app over 80 GB\n"
         "  ./FLS --list     Show the biggest apps right now, then exit\n"
         "\n"
         "  --limit GB       Kill a process, or a whole app, above this much memory (default 80)\n"
         "  --total GB       Also kill the biggest app when all apps together pass this (default off)\n"
         "  --interval S     Seconds between checks (default 5)\n"
         "  --dry-run        Log what would be killed, but kill nothing\n"
         "  --only TEXT      Only look at apps whose path contains TEXT\n"
         "\n"
         "Kills are logged to ~/Library/Logs/FLS.log and shown as a notification.\n"
         "./install.sh [options] runs FLS now and at every login. ./uninstall.sh removes that.");
}

static double parse_gb(const char *flag, const char *value) {
    double gb = strtod(value, NULL);
    if (gb < 1) {
        fprintf(stderr, "%s must be at least 1 GB, got \"%s\"\n", flag, value);
        exit(2);
    }
    return gb;
}

int main(int argc, char **argv) {
    static const struct option options[] = {
        {"limit", required_argument, NULL, 'l'},
        {"total", required_argument, NULL, 't'},
        {"interval", required_argument, NULL, 'i'},
        {"dry-run", no_argument, NULL, 'd'},
        {"only", required_argument, NULL, 'o'},
        {"list", no_argument, NULL, 's'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0},
    };
    double limit_gb = 80, total_gb = 0;
    int interval = 5;
    bool dry_run = false, list = false;
    const char *only = NULL;

    int option;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        switch (option) {
            case 'l': limit_gb = parse_gb("--limit", optarg); break;
            case 't': total_gb = parse_gb("--total", optarg); break;
            case 'i':
                interval = atoi(optarg);
                if (interval < 1) {
                    fprintf(stderr, "--interval must be at least 1 second, got \"%s\"\n", optarg);
                    return 2;
                }
                break;
            case 'd': dry_run = true; break;
            case 'o': only = optarg; break;
            case 's': list = true; break;
            case 'h': print_help(); return 0;
            default: print_help(); return 2;
        }
    }
    if (optind < argc) {
        fprintf(stderr, "Unexpected argument \"%s\"\n", argv[optind]);
        return 2;
    }

    if (list) {
        scan(only);
        print_list();
        return 0;
    }

    signal(SIGCHLD, SIG_IGN);  // osascript children get reaped automatically
    log_line("Started: process and app limit %g GB, total limit %s%s, checking every %d s", limit_gb,
             total_gb ? "on" : "off", dry_run ? ", dry run" : "", interval);

    time_t last_dry_run_log = 0;
    for (;;) {
        scan(only);
        int proc = biggest_killable_proc();
        int app = biggest_killable_app();
        pid_t pid = 0;
        char target[256] = "", why[128] = "";

        // The biggest is always the first over a limit, so checking it alone is enough.
        // Try the narrowest kill first: one leaking Chrome tab shouldn't take down all of Chrome.
        if (proc >= 0 && procs[proc].bytes > limit_gb * GB) {
            char label[128];
            proc_label(proc, label, sizeof label);
            app = procs[proc].app;
            pid = procs[proc].pid;
            snprintf(target, sizeof target, "%s (%.1f GB)", label, procs[proc].bytes / GB);
            snprintf(why, sizeof why, "over the %g GB process limit", limit_gb);
        } else if (app >= 0 && apps[app].bytes > limit_gb * GB) {
            snprintf(why, sizeof why, "over the %g GB app limit", limit_gb);
        } else if (app >= 0 && total_gb && total_bytes > total_gb * GB) {
            snprintf(why, sizeof why, "all apps together used %.1f GB, over the %g GB total limit",
                     total_bytes / GB, total_gb);
        }
        if (why[0] && !pid) {
            snprintf(target, sizeof target, "%s (%.1f GB, %d process%s)", app_name(&apps[app]),
                     apps[app].bytes / GB, apps[app].procs, apps[app].procs == 1 ? "" : "es");
        }

        if (why[0] && !dry_run) {
            stop(app, pid, target, why);
        } else if (why[0] && time(NULL) - last_dry_run_log >= DRY_RUN_LOG_SECONDS) {
            log_line("Would kill %s: %s", target, why);
            last_dry_run_log = time(NULL);
        }
        sleep(interval);
    }
}
