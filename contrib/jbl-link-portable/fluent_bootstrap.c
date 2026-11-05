/* Local Fluent Bit 1.4.6 ARMv7 input plugin; no records or network output.
 * ABI reference: upstream v1.4.6 include/fluent-bit/flb_input.h.
 * Build with JBL_PROBE to write a /run marker and intentionally fail init.
 * Production calls only our /data bootstrap and leaves logging functional.
 */
extern int open(const char *, int, ...);
extern int close(int);
extern int write(int, const void *, unsigned int);
extern unsigned int getuid(void);
extern int system(const char *);

static int initialize(void *instance, void *config, void *context)
{
    (void)instance;
    (void)config;
    (void)context;
    if (getuid() != 0)
        return 0;
#ifdef JBL_PROBE
    static const char result[] = "JBL_FLUENT_PLUGIN_INITIALIZED\n";
    int fd = open("/run/jbl-fluent-probe/initialized", 1 | 64 | 128, 0600);
    if (fd >= 0) {
        write(fd, result, sizeof(result) - 1);
        close(fd);
    }
    return -1; /* The probe process must exit instead of becoming a daemon. */
#else
    system("/bin/sh /data/jbl-autostart/bootstrap.sh >>/run/jbl-autostart.log 2>&1");
    return 0; /* Failure of our bootstrap must not stop vendor logging. */
#endif
}

/* 32-bit upstream layout: flags, name/description/config, nine callbacks,
 * instance, and two intrusive-list pointers. Only init is implemented. */
struct input_registration {
    int flags;
    const char *name;
    const char *description;
    void *config_map;
    void *callbacks[9];
    void *instance;
    void *links[2];
};
_Static_assert(sizeof(struct input_registration) == 64, "Expected ARM32 ABI");

__attribute__((visibility("default")))
struct input_registration in_jbl_bootstrap_plugin = {
    .name = "jbl_bootstrap",
    .description = "Local JBL bootstrap without log records",
    .callbacks = {(void *)initialize}
};
