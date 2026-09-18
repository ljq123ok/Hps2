export const startBios: (dataRoot: string, biosDir: string, gamePath: string) => number;
export const setSurface: (surfaceId: string, width: number, height: number) => number;
export const stop: () => number;
export const getStatus: () => string;

/**
 * JIT 能力自检结果。
 *
 * 产品决策：**不做降级** —— JIT 不可用时阻止启动，而不是退回解释器。
 * 因此 UI 必须在启动前展示该状态，并把 action 作为可操作建议给用户。
 */
export interface JitCheckResult {
  /** JIT 当前是否可用（唯一的启动判据） */
  available: boolean;
  /** 失败阶段编号：0=ok 1=mmap-rw 2=mprotect-rx 3=execute 4=revalidate */
  stage: number;
  /** 失败阶段名（稳定标识，便于日志检索与反馈） */
  stageName: string;
  /** 失败时的 errno（成功为 0）。实测故障模式为 22 (EINVAL) */
  errno: number;
  /** 面向用户的一句话说明 */
  message: string;
  /** 面向用户的可操作建议 */
  action: string;
}

/**
 * 执行一次完整的 JIT 自检（申请 → 写入 → 提交 → 执行 → 校验）。
 *
 * 供 UI 在启动前调用，使用户不必先点启动才发现不可用。
 * 返回 JSON 字符串，需 JSON.parse 后按 JitCheckResult 使用。
 */
export const checkJit: () => string;
