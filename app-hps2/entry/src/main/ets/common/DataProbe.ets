/*
 * Hps2 — 阶段 0 数据外置探针（ArkTS 侧）
 *
 * ============================================================================
 * 【这个文件是临时的】阶段 3 落地后应整体移除。
 * 目的：在真机上回答"应用能否把数据根放在公共 Download 目录"，
 * 并输出结构化日志供判读（DATA_PROBE <项>=PASS|FAIL）。
 *
 * ============================================================================
 * 【为什么 ArkTS 与 Native 要分别测】
 * 二者走的是**两条不同的通路**：
 *   ArkTS 的 fs  -> OpenHarmony 文件管理框架（可能经 hmdfs/fuse、可能
 *                   依赖 URI 授权或权限位）
 *   Native 的 open(2) -> 原始系统调用（PCSX2 核心实际使用的方式）
 * ArkTS 能访问**不代表** native 能。而模拟器核心全部走 native POSIX，
 * 所以第 4 项才是真正的闸门。这决定了本探针必须**两者都测**。
 *
 * ============================================================================
 * 【为什么不能用 hdc 脚本替代】
 * shell 的 uid=2000 且 SELinux 上下文为 u:r:sh:s0，与应用 u:r:app:s0
 * 是两套策略。实测 hdc shell 对 /storage/media 报 Permission denied，
 * 但这**不能**推断应用也失败。必须由应用进程自己实测。
 *
 * ============================================================================
 * 【安全性】探针只写 <公共目录>/Hps2Probe/ 这一个自建子目录，
 * 不接触 games/、memcards/ 等真实数据目录，也不删除非自建文件。
 */
import fs from '@ohos.file.fs';
import Environment from '@ohos.file.environment';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import hps2core from 'libhps2core.so';

const DOMAIN = 0x3202;
const TAG = 'HPS2_DATAPROBE';

/** 探针专用子目录名（避免与阶段 3 的正式布局 Hps2/ 混用） */
const PROBE_DIR_NAME = 'Hps2Probe';
/** 冷启动持久化标记文件名 */
const MARKER_NAME = 'dataprobe-marker.json';

/**
 * 候选公共根目录。
 *
 * 【为什么要有候选列表】第一轮实测已确认：
 *   Environment.getUserDownloadDir() -> throw 801 (The device doesn't support this api)
 * 即该 API 在目标真机上**不可用**（syscap
 * SystemCapability.FileManagement.File.Environment.FolderObtain 未提供），
 * 而它又**不需要权限**（API 12 起文档块无 @permission），所以问题不在权限。
 *
 * 因此不能只依赖那一个 API：必须落回**真实路径**逐个实测。
 * 这些路径由 hdc 枚举确认存在（在 uid=2000 的 shell 视角下可 stat）。
 * 最终以 native POSIX 实测结果为准 —— 路径"看得见"不等于"应用能读写"。
 *
 * 注意 userId：真机为 100，但不应写死，运行时从沙箱路径推导。
 */
function candidatePublicRoots(userId: string): string[] {
  return [
    `/storage/media/${userId}/local/files/Docs/Download`,
    `/storage/media/${userId}/local/files/Docs/Documents`,
    `/storage/media/${userId}/local/files/Docs`,
    `/storage/media/${userId}/local/files`,
  ];
}

/** 阶段 3 计划中的正式子目录名（探针会尝试创建以验证多级目录能力） */
const PLANNED_SUBDIRS: string[] = [
  'bios', 'games', 'memcards', 'sstates', 'cheats',
  'patches', 'gamesettings', 'inputprofiles', 'textures', 'snaps', 'inis'
];

/** 一条探测结果，便于统一记录 */
interface ProbeResult {
  name: string;
  pass: boolean;
  detail: string;
}

/** 探针汇总 */
interface ProbeReport {
  results: ProbeResult[];
  publicRoot: string;
  probeDir: string;
}

/**
 * 把结果按统一格式打到 hilog，便于 `hilog | grep DATA_PROBE` 抓取判读。
 */
function logResult(r: ProbeResult): void {
  hilog.info(DOMAIN, TAG, 'DATA_PROBE %{public}s=%{public}s detail=%{public}s',
    r.name, r.pass ? 'PASS' : 'FAIL', r.detail);
}

/**
 * 阶段 0 探针主体。
 *
 * @param sandboxRoot 当前沙箱数据根（getContext().filesDir），仅用于对照
 * @returns 探测报告
 */
export function runDataProbe(sandboxRoot: string): ProbeReport {
  const results: ProbeResult[] = [];
  let publicRoot = '';
  let probeDir = '';

  hilog.info(DOMAIN, TAG, 'DATA_PROBE begin sandbox=%{public}s', sandboxRoot);

  // ------------------------------------------------------------------------
  // 第 1 项：解析公共根目录
  //
  // 【第一轮实测的结论】Environment.getUserDownloadDir() 在真机上直接
  //   throw 801 "The device doesn't support this api"
  // 即该 API 依赖的 syscap（...File.Environment.FolderObtain）本机未提供。
  // 注意这**不是权限问题**：该 API 自 API 12 起文档块已无 @permission。
  //
  // 【因此改为多候选实测】API 不可用不代表目录不可达。回退到真实路径
  // 逐个尝试，并**以 native POSIX 是否真的能读写为准**。
  // 这一步不因单个候选失败而中止 —— 否则会像上一轮那样，
  // 让真正的闸门（第 4 项）根本跑不到。
  // ------------------------------------------------------------------------
  try {
    const viaApi = Environment.getUserDownloadDir();
    if (viaApi.length > 0) {
      publicRoot = viaApi;
      results.push({
        name: 'resolve_public_dir',
        pass: true,
        detail: `via getUserDownloadDir -> ${viaApi}`
      });
    } else {
      results.push({
        name: 'resolve_public_dir',
        pass: false,
        detail: 'getUserDownloadDir returned empty; falling back to candidates'
      });
    }
  } catch (err) {
    const be = err as BusinessError;
    results.push({
      name: 'resolve_public_dir',
      pass: false,
      detail: `getUserDownloadDir throw code=${be.code} msg=${be.message}; falling back to candidates`
    });
  }

  // userId 取真机实测值；每个候选都会经 ArkTS + native 双重实测，
  // 错的候选会自然 FAIL，不会造成误判。
  const userId = '100';

  if (publicRoot.length === 0) {
    const candidates = candidatePublicRoots(userId);
    for (const c of candidates) {
      // 只读诊断：候选是否存在、是否目录、能否枚举。
      let statInfo = '';
      try {
        statInfo = hps2core.statDataPath(c);
      } catch (e) {
        statInfo = 'statDataPath threw';
      }
      // ArkTS 交叉验证（与 native 结果对照；二者通路不同）。
      let arkOk = false;
      try {
        arkOk = fs.accessSync(c);
      } catch (e) {
        arkOk = false;
      }
      hilog.info(DOMAIN, TAG,
        'DATA_PROBE candidate path=%{public}s arkts_access=%{public}d native=%{public}s',
        c, arkOk ? 1 : 0, statInfo);

      if (arkOk && publicRoot.length === 0) {
        publicRoot = c;
      }
    }
    results.push({
      name: 'candidate_public_roots',
      pass: publicRoot.length > 0,
      detail: publicRoot.length > 0
        ? `first ArkTS-accessible candidate -> ${publicRoot}`
        : 'no candidate accessible via ArkTS'
    });
  }

  // 【关键修正】即便 ArkTS 全都访问不了，也**必须**继续跑到第 4 项：
  // native 与 ArkTS 走不同通路，ArkTS 失败不代表 native 失败。
  // 上一轮在此处提前 return，导致真正的闸门根本没被测到 —— 这是设计缺陷。
  if (publicRoot.length === 0) {
    publicRoot = candidatePublicRoots(userId)[0];
    results.push({
      name: 'fallback_for_native_test',
      pass: false,
      detail: `ArkTS could not access any candidate; still testing native POSIX on ${publicRoot}`
    });
  }

  probeDir = publicRoot + '/' + PROBE_DIR_NAME;

  // 枚举应用**实际可见**的顶层目录与关键挂载点。
  // 这决定"公共存储到底以什么路径暴露给应用"（或根本未暴露）。
  for (const probe of ['/', '/storage', '/data', '/storage/media', '/mnt', '/sdcard']) {
    try {
      const lst: string = hps2core.listDataDir(probe);
      hilog.info(DOMAIN, TAG, 'DATA_PROBE visible dir=%{public}s -> %{public}s', probe, lst);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'DATA_PROBE listDataDir(%{public}s) threw', probe);
    }
  }

  // 逐级祖先诊断：确定应用视角下访问**断在哪一层**。
  // 这是解释 FAIL 根因的关键 —— errno=2(ENOENT) 可能是"挂载点对应用
  // 不可见"，也可能是"某级祖先被拒绝进入"，二者对方案含义完全不同。
  try {
    const chain: string = hps2core.probePathChain(publicRoot);
    hilog.info(DOMAIN, TAG, 'DATA_PROBE path_chain=%{public}s', chain);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'DATA_PROBE probePathChain threw');
  }

  // 用 native 的 stat 看它在 POSIX 层是什么样（属主/权限位/可枚举性）。
  // 这一条常能解释"为什么 ArkTS 能而 native 不能"。
  try {
    // 显式标注返回类型：ArkTS 严格模式禁止从 napi 模块推断出 any
    // （与 Index.ets 中 `const raw: string = hps2core.getStatus()` 同理）。
    const st: string = hps2core.statDataPath(publicRoot);
    hilog.info(DOMAIN, TAG, 'DATA_PROBE native_stat_public=%{public}s', st);
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'DATA_PROBE native statDataPath threw: %{public}s',
      JSON.stringify(err as BusinessError));
  }

  // ------------------------------------------------------------------------
  // 第 2 项：应用能否自行创建目录（含多级）并枚举
  //
  // 为什么重要：阶段 3 要求"全新安装时自动创建目录并正常启动"。
  // 若只能读用户预建的目录，则必须改为"引导用户手动创建"的设计。
  // ------------------------------------------------------------------------
  let mkdirOk = false;
  try {
    if (!fs.accessSync(probeDir)) {
      fs.mkdirSync(probeDir);
    }
    mkdirOk = fs.accessSync(probeDir);
    results.push({
      name: 'mkdir',
      pass: mkdirOk,
      detail: mkdirOk ? probeDir : 'accessSync false after mkdir'
    });
  } catch (e) {
    const err = e as BusinessError;
    results.push({
      name: 'mkdir',
      pass: false,
      detail: `code=${err.code} msg=${err.message}`
    });
  }

  // 多级子目录：阶段 3 的正式布局需要（bios/ games/ memcards/ ...）
  if (mkdirOk) {
    let madeCount = 0;
    const failed: string[] = [];
    for (const sub of PLANNED_SUBDIRS) {
      const p = probeDir + '/' + sub;
      try {
        if (!fs.accessSync(p)) {
          fs.mkdirSync(p);
        }
        if (fs.accessSync(p)) {
          madeCount++;
        } else {
          failed.push(sub);
        }
      } catch (e) {
        failed.push(sub);
      }
    }
    const pass = madeCount === PLANNED_SUBDIRS.length;
    results.push({
      name: 'mkdir_subdirs',
      pass,
      detail: pass ? `${madeCount}/${PLANNED_SUBDIRS.length}`
                   : `${madeCount}/${PLANNED_SUBDIRS.length} failed=[${failed.join(',')}]`
    });
  }

  // ------------------------------------------------------------------------
  // 第 3 项：枚举内容（用户手动放入的文件能否被发现）
  //
  // 同时验证两件事：
  //   a) 能列出目录内容（而非只能逐个文件授权）
  //   b) 用户通过系统文件管理器放入的文件能被看见
  //   c) 冷启动后仍能看见（由标记文件 + 第二次启动的日志共同证明）
  // ------------------------------------------------------------------------
  if (mkdirOk) {
    try {
      const names: string[] = fs.listFileSync(probeDir);
      // 过滤掉 .part 之类的临时文件不必要 —— 探针目录本就干净。
      const imageLike: string[] = [];
      for (const n of names) {
        const low = n.toLowerCase();
        if (low.endsWith('.iso') || low.endsWith('.bin') || low.endsWith('.chd') ||
            low.endsWith('.elf') || low.endsWith('.txt') || low.endsWith('.json')) {
          imageLike.push(n);
        }
      }
      results.push({
        name: 'enumerate',
        pass: true,
        detail: `entries=${names.length} candidates=${imageLike.length} [${imageLike.join('|')}]`
      });
    } catch (e) {
      const err = e as BusinessError;
      results.push({
        name: 'enumerate',
        pass: false,
        detail: `code=${err.code} msg=${err.message}`
      });
    }
  }

  // ------------------------------------------------------------------------
  // 冷启动持久化标记：写一个 JSON，内含本次启动的时间戳与写入序号。
  // 第二次启动时能看到 **上一次** 的写入 => 目录内容确实跨进程存活。
  // 若卸载重装后仍能看到 => 该目录不随应用卸载而清除（第 5 项的核心）。
  // ------------------------------------------------------------------------
  if (mkdirOk) {
    const marker = probeDir + '/' + MARKER_NAME;
    try {
      let previous = '';
      if (fs.accessSync(marker)) {
        previous = fs.readTextSync(marker);
      }
      const now = new Date().toISOString();
      const body = `{"lastLaunch":"${now}","sandbox":"${sandboxRoot}","previous":${JSON.stringify(previous)}}`;
      const f = fs.openSync(marker, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, body);
      fs.closeSync(f);

      // 回读确认写入真的落盘
      const back = fs.readTextSync(marker);
      const seenPrevious = previous.length > 0;
      results.push({
        name: 'persist_marker',
        pass: back.length > 0,
        detail: seenPrevious
          ? `cold_start_seen_previous=true prevLen=${previous.length}`
          : 'cold_start_seen_previous=false (first run)'
      });
    } catch (e) {
      const err = e as BusinessError;
      results.push({
        name: 'persist_marker',
        pass: false,
        detail: `code=${err.code} msg=${err.message}`
      });
    }
  }

  // ------------------------------------------------------------------------
  // 第 4 项：Native POSIX 读写（真正的闸门）
  //
  // 交给 native 用裸 open/write/fsync/lseek/read/rename/unlink 实测。
  // 若此步 FAIL 而上面 ArkTS 全 PASS，则结论是"核心无法使用外部目录"，
  // 数据外置对模拟器无效 —— 这是本探针最重要的判据。
  // ------------------------------------------------------------------------
  try {
    // 传 publicRoot 而非 probeDir：native 的 RunNativeProbe 会自行追加
    // 自己的子目录名（Hps2Probe）。上一轮误传 probeDir 导致路径被拼成
    // .../Hps2Probe/Hps2Probe —— 修掉。
    const nativeJson: string = hps2core.runDataProbe(publicRoot);
    const ok = nativeJson.indexOf('"ok":true') >= 0;
    results.push({
      name: 'native_rw_seek',
      pass: ok,
      detail: ok ? 'all posix ops ok' : nativeJson
    });
  } catch (e) {
    const err = e as BusinessError;
    results.push({
      name: 'native_rw_seek',
      pass: false,
      detail: `throw code=${err.code} msg=${err.message}`
    });
  }

  // 汇总
  let passCount = 0;
  for (const r of results) {
    logResult(r);
    if (r.pass) {
      passCount++;
    }
  }
  hilog.info(DOMAIN, TAG, 'DATA_PROBE summary pass=%{public}d total=%{public}d root=%{public}s',
    passCount, results.length, publicRoot);

  return { results, publicRoot, probeDir };
}
