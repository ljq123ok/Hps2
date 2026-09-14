/*
 * HarmonyOS 内核 mmap/mprotect 语义探针（命令行版）
 *
 * 目的：在不依赖 HAP 签名的前提下，直接在真机内核上测量
 *       匿名可执行内存的真实策略。这是阶段 1 探针的"内核侧对照"。
 *
 * ⚠️ 重要限制：本程序通过 hdc shell 运行，处于 **shell 域**，
 *    不是应用域（normal_hap / debug_hap）。因此：
 *      - 若结果为"拒绝" => 强证据表明应用侧更不可能成功；
 *      - 若结果为"允许" => 不能证明应用侧也允许（应用域通常更严）。
 *    最终结论仍须由签名后的 HAP 探针给出。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>

typedef int (*fn_int)(void);

static uint32_t movz_w0(unsigned imm){ return 0x52800000u | ((uint32_t)(imm & 0xFFFF) << 5); }
#define RET 0xD65F03C0u

static void flush(void *p, size_t n){
    __builtin___clear_cache((char*)p, (char*)p + n);
    __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
}

/* 测试 1：RW -> 写入 -> RX -> 执行 */
static int t_rw_then_rx(void){
    size_t pg = 4096;
    void *p = mmap(NULL, pg, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED){ printf("  mmap(RW) 失败 errno=%d (%s)\n", errno, strerror(errno)); return -1; }
    ((uint32_t*)p)[0] = movz_w0(123);
    ((uint32_t*)p)[1] = RET;
    if (mprotect(p, pg, PROT_READ|PROT_EXEC) != 0){
        printf("  mprotect(RX) 失败 errno=%d (%s)\n", errno, strerror(errno));
        munmap(p, pg); return -1;
    }
    flush(p, pg);
    fn_int f = (fn_int)p;
    int v = f();
    printf("  mprotect(RW->RX) 成功, 执行返回 %d (期望 123) %s\n", v, v==123?"PASS":"FAIL");
    munmap(p, pg);
    return v==123 ? 0 : -2;
}

/* 测试 2：直接申请 RWX */
static int t_rwx(void){
    size_t pg = 4096;
    errno = 0;
    void *p = mmap(NULL, pg, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED){
        printf("  mmap(RWX) 被拒绝 errno=%d (%s)  => 内核强制 W^X\n", errno, strerror(errno));
        return -1;
    }
    ((uint32_t*)p)[0] = movz_w0(7);
    ((uint32_t*)p)[1] = RET;
    flush(p, pg);
    int v = ((fn_int)p)();
    printf("  mmap(RWX) 被允许, 执行返回 %d  => 内核未强制 W^X\n", v);
    munmap(p, pg);
    return 0;
}

/* 测试 3：mprotect 把已有 RX 页改回可写（JIT 代码修补场景） */
static int t_repatch(void){
    size_t pg = 4096;
    void *p = mmap(NULL, pg, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED){ printf("  mmap 失败 errno=%d\n", errno); return -1; }
    ((uint32_t*)p)[0]=movz_w0(1); ((uint32_t*)p)[1]=RET;
    if (mprotect(p, pg, PROT_READ|PROT_EXEC)!=0){ printf("  首次 RX 失败 errno=%d\n", errno); munmap(p,pg); return -1; }
    flush(p,pg);
    int a = ((fn_int)p)();
    /* 改回写，重写指令，再改回执行 —— JIT 原位修补 */
    if (mprotect(p, pg, PROT_READ|PROT_WRITE)!=0){
        printf("  RX->RW 失败 errno=%d (%s)  => 不允许代码页回写\n", errno, strerror(errno));
        munmap(p,pg); return -1;
    }
    ((uint32_t*)p)[0]=movz_w0(2);
    if (mprotect(p, pg, PROT_READ|PROT_EXEC)!=0){ printf("  二次 RX 失败 errno=%d\n", errno); munmap(p,pg); return -1; }
    flush(p,pg);
    int b = ((fn_int)p)();
    printf("  代码修补: %d -> %d (期望 1 -> 2) %s\n", a, b, (a==1&&b==2)?"PASS":"FAIL");
    munmap(p,pg);
    return (a==1&&b==2)?0:-2;
}

static void t_pageinfo(void){
    long pg = sysconf(_SC_PAGESIZE);
    printf("  页大小=%ld 指针位宽=%zu\n", pg, sizeof(void*)*8);
}

int main(void){
    printf("=== HarmonyOS 内核 mmap/mprotect 探针 ===\n");
    printf("[环境]\n"); t_pageinfo();
    printf("[1] RW->RX 分步映射 + 执行\n"); t_rw_then_rx();
    printf("[2] 直接 RWX 映射\n");            t_rwx();
    printf("[3] 代码页修补 (RX->RW->RX)\n"); t_repatch();
    printf("=== 结束 ===\n");
    return 0;
}
