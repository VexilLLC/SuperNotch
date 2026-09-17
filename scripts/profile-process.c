// macOS process footprint and CPU sampler (percentage of one logical core).
// Build: clang -O2 scripts/profile-process.c -o /tmp/supernotch-profile
// Run: /tmp/supernotch-profile <pid> [seconds]
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s pid [seconds]\n", argv[0]);
        return 1;
    }
    int pid = atoi(argv[1]);
    int seconds = argc > 2 ? atoi(argv[2]) : 20;
    if (pid <= 0 || seconds < 1 || seconds > 3600) return 1;

    struct rusage_info_v4 before = {0}, current = {0};
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&before)) {
        perror("proc_pid_rusage");
        return 2;
    }
    uint64_t start = mach_absolute_time();
    uint64_t peak = before.ri_phys_footprint;
    double footprintSum = 0;
    for (int sample = 0; sample < seconds; sample++) {
        sleep(1);
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&current) ||
            current.ri_proc_start_abstime != before.ri_proc_start_abstime) {
            fprintf(stderr, "Target exited or changed during measurement\n");
            return 2;
        }
        if (current.ri_phys_footprint > peak) peak = current.ri_phys_footprint;
        footprintSum += current.ri_phys_footprint;
    }
    // Both CPU counters and elapsed time are in Mach ticks. Their ratio is
    // already a CPU fraction; convert elapsed time separately for wakeups/s.
    double elapsedTicks = (double)(mach_absolute_time() - start);
    double elapsedSeconds = elapsedTicks * timebase.numer / timebase.denom / 1e9;
    double cpuTicks = (double)(current.ri_user_time - before.ri_user_time) +
                     (double)(current.ri_system_time - before.ri_system_time);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    proc_pidpath(pid, path, sizeof(path));
    printf("%s\nCPU %.3f%%; mean footprint %.2f MiB; end %.2f MiB; "
           "sampled peak %.2f MiB; interrupt wakeups/s %.2f; duration %.2fs\n",
           path, 100 * cpuTicks / elapsedTicks, footprintSum / seconds / 1048576.,
           current.ri_phys_footprint / 1048576., peak / 1048576.,
           (current.ri_interrupt_wkups - before.ri_interrupt_wkups) / elapsedSeconds,
           elapsedSeconds);
    return 0;
}
