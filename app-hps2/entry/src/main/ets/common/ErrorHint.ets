/*
 * Hps2 — 启动失败的原因分类与处置建议
 *
 * 【为什么需要】用户反馈"我的 BIOS 都能启动，别人不行"。但失败原因其实
 * 分好几类（JIT 失效 / BIOS 无效 / 内存不足 / 其它），处置方式完全不同：
 *    JIT 失效  -> 重启设备
 *    BIOS 无效 -> 换一个 BIOS 文件
 *    内存不足  -> 关掉后台应用再试
 * 若只显示一句原始错误，用户无从判断 —— 这正是"别人不行"难以定位的原因。
 *
 * 分类依据是 native 侧实际会产出的错误串（已逐条核对 napi_init.cpp 的
 * 所有 SetError 调用），不是臆测的文本匹配。
 */

/** 失败类别 */
export enum FailKind {
  None = 0,
  Jit = 1,        // JIT 不可用或运行中失效
  Bios = 2,       // BIOS 相关
  Memory = 3,     // 内存/资源不足
  Surface = 4,    // 渲染表面问题
  Other = 5,
}

export class ErrorHint {
  /**
   * 按原始错误串判定类别。
   *
   * 匹配规则全部来自 native 实际产出的文本（见 napi_init.cpp 的 SetError），
   * 不做宽泛猜测 —— 宁可归入 Other，也不要误判给用户错误的处置建议。
   */
  static classify(raw: string): FailKind {
    if (!raw || raw.length === 0)
      return FailKind.None;

    // --- JIT 类 ---
    // "JIT 不可用（阶段 ...）"、"JIT 未生效：核心已静默退回解释器..."、
    // "JIT 能力在运行中失效，已停止模拟：..."、"JIT 不可用，已拒绝启动。"
    if (raw.includes('JIT'))
      return FailKind.Jit;

    // --- 内存类 ---
    // "CPUThreadInitialize failed"（实测多由 code memory 分配失败引起）、
    // "Failed to allocate ..."、"Failed to allocate VM memory"
    if (raw.includes('CPUThreadInitialize') ||
        raw.includes('allocate') ||
        raw.includes('Failed to allocate') ||
        raw.includes('内存'))
      return FailKind.Memory;

    // --- BIOS 类 ---
    // "VMManager::Initialize failed"（BIOS 无效时核心在此失败）、
    // 以及文本里直接提到 BIOS 的情况
    if (raw.includes('BIOS') || raw.includes('bios') ||
        raw.includes('VMManager::Initialize'))
      return FailKind.Bios;

    // --- 渲染表面类 ---
    if (raw.includes('setSurface') || raw.includes('OHNativeWindow') ||
        raw.includes('render window'))
      return FailKind.Surface;

    return FailKind.Other;
  }

  /** 类别显示名（给用户看的短标签） */
  static kindLabel(k: FailKind): string {
    switch (k) {
      case FailKind.Jit: return 'JIT（动态编译）';
      case FailKind.Bios: return 'BIOS 或核心启动';
      case FailKind.Memory: return '内存不足';
      case FailKind.Surface: return '渲染表面';
      case FailKind.Other: return '其它';
      default: return '';
    }
  }

  /** 针对该类别的可操作建议 */
  static advice(k: FailKind): string {
    switch (k) {
      case FailKind.Jit:
        return '重启手机后重试。JIT 可用性会随运行状态变化，重启是目前唯一'
             + '经实测有效的恢复方式。若重启后仍失败，请用「复制日志」把日志发给我们。';
      case FailKind.Bios:
        return '请换一个 PS2 BIOS 文件试试。注意：其它机种（PS1/PSP）的 .bin '
             + '文件也叫 .bin，但无法用于 PS2。PS2 BIOS 常见规格为 4MB / 2MB / 8MB。';
      case FailKind.Memory:
        return '设备可用内存不足。PS2 模拟需要数百 MB 连续内存用于 JIT 代码缓存。'
             + '请关闭其它应用后重试。';
      case FailKind.Surface:
        return '渲染表面创建失败。可尝试返回首页再重新启动；若持续出现请反馈日志。';
      default:
        return '请用「复制日志」把详细信息发给我们，便于定位。';
    }
  }

  /** 是否属于"重试也没用、必须换文件"的情况（决定 UI 是否强调换文件） */
  static needsDifferentFile(k: FailKind): boolean {
    return k === FailKind.Bios;
  }
}
