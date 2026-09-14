/*
 * 宿主侧指令编码校验（仅验证 AArch64 编码与 JIT 生命周期逻辑，
 * 不代表 HarmonyOS 真机的能力结论）。
 *
 * 本机 macOS 为 arm64，与目标设备同架构，因此可直接执行同样的
 * movz w0,#imm ; ret 序列，用来证明「编码正确」这个前提：
 * 若在真机上失败，就能排除「指令编码写错」这一可能，把问题
 * 收敛到 HarmonyOS 的内存/权限策略上。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>

static uint32_t encode_movz_w0(uint16_t imm) {
    return 0x52800000u | ((uint32_t)imm << 5) | 0u;
}
static const uint32_t RET = 0xD65F03C0u;

typedef int (*fn_int)(void);

int main(void) {
    size_t page = 4096;
    printf("== AArch64 编码校验 ==\n");
    printf("movz w0,#123 => 0x%08X (期望 0x52800F60)\n", encode_movz_w0(123));
    printf("ret          => 0x%08X (期望 0xD65F03C0)\n", RET);

    /* 走与 HAP 中完全相同的 RW -> RX 流程 */
    void *p = mmap(NULL, page, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { printf("mmap 失败: %s\n", strerror(errno)); return 1; }

    uint32_t *code = (uint32_t *)p;
    code[0] = encode_movz_w0(123);
    code[1] = RET;

    if (mprotect(p, page, PROT_READ | PROT_EXEC) != 0) {
        printf("mprotect RX 失败: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    __builtin___clear_cache((char *)p, (char *)p + page);
    __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");

    fn_int f = (fn_int)p;
    int v = f();
    printf("执行生成代码返回: %d (期望 123) -> %s\n", v, v == 123 ? "PASS" : "FAIL");

    /* 重建校验 */
    for (int i = 0; i < 3; i++) {
        mprotect(p, page, PROT_READ | PROT_WRITE);
        code[0] = encode_movz_w0((uint16_t)(100 + i));
        mprotect(p, page, PROT_READ | PROT_EXEC);
        __builtin___clear_cache((char *)p, (char *)p + page);
        __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
        int r = f();
        printf("  重建 r%d => %d (期望 %d) %s\n", i, r, 100 + i, r == 100 + i ? "PASS" : "FAIL");
    }
    munmap(p, page);
    return v == 123 ? 0 : 1;
}
