/*
 * Hps2 — 手机目录扫描（「扫描手机目录添加游戏」）
 *
 * 【存在的理由】
 *   此前只能通过系统文件选择器**逐个**挑镜像，用户把游戏放进手机目录后
 *   应用完全发现不了 —— 「重新扫描」只重扫应用私有 games/ 目录，
 *   用户的体感就是"扫不出来"。
 *
 * 【能扫哪里 —— 这是 HarmonyOS 的安全模型，不是本模块的取舍】
 *   系统只对普通应用开放这两个公开目录（均为 user_grant + normal 级）：
 *     - Download
 *     - Documents
 *   Desktop 需要 system_basic（普通应用拿不到）；此外**没有全盘 API**。
 *   本模块据此只扫上述两个根，绝不假装能扫全盘。
 *
 * 【权限语义】
 *   两个权限都是 user_grant：首次调用 requestPermissionsFromUser 会弹窗，
 *   用户拒绝则返回空结果并把原因带回 UI（不静默失败）。
 *   权限是**目录级**的：拿到后 fs 可直接按真实路径读写该目录树，
 *   无需再走 picker 授权 —— 这正是"原地读取"能成立的前提。
 */
import fs from '@ohos.file.fs';
import environment from '@ohos.file.environment';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import type { PermissionRequestResult } from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

/** 视为游戏镜像的扩展名（与 native listGames 保持一致） */
const GAME_EXTS: Array<string> = [
  '.iso', '.chd', '.bin', '.img', '.cso', '.gz', '.elf'
];

/** 扫描结果的一项 */
export interface ScannedGame {
  /** 真实文件路径（可直接交给 native 打开 —— 原地读取的关键） */
  path: string;
  /** 文件名 */
  name: string;
  /** 字节数 */
  size: number;
  /** 所在根目录的显示名（Download / Documents），用于分组 */
  rootLabel: string;
}

/** 扫描结果整体（含失败原因，便于 UI 如实告知） */
export interface ScanResult {
  games: Array<ScannedGame>;
  /** 被拒绝或不可用的目录说明；空串 = 一切正常 */
  message: string;
  /** 至少有一个目录可用 */
  ok: boolean;
}

/** 单个扫描根 */
interface ScanRoot {
  label: string;
  path: string;
  permission: string;
}

/**
 * 判断是否游戏镜像。
 *
 * 【为什么先小写】用户下载下来的扩展名大小写混杂（.ISO / .Iso 都见过），
 * 不统一小写会漏掉相当一部分。
 */
function isGameFile(lower: string): boolean {
  for (let i = 0; i < GAME_EXTS.length; i++) {
    const e = GAME_EXTS[i];
    if (lower.length > e.length && lower.endsWith(e)) {
      return true;
    }
  }
  return false;
}

export class ScanDirs {
  /**
   * 申请两个目录权限。
   *
   * 返回**实际被授予**的权限名集合。调用方据它决定能扫哪些根，
   * 而不是假设"申请了就一定有"。
   */
  static async requestPermissions(ctx: common.UIAbilityContext): Promise<Set<string>> {
    const granted: Set<string> = new Set<string>();
    const perms: Array<Permissions> = [
      'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
      'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
    ];
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      // bundleName 必须与签名 profile 一致，从系统读取避免硬编码漂移
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const res: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(ctx, perms);
      const codes: Array<number> = res.authResults;
      const names: Array<string> = res.permissions;
      for (let i = 0; i < names.length; i++) {
        if (i < codes.length && codes[i] === 0) {
          granted.add(names[i]);
        }
      }
      hilog.info(DOMAIN, TAG, 'scan dirs permissions granted=%{public}d/%{public}d',
        granted.size, perms.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'requestPermissionsFromUser failed');
    }
    return granted;
  }

  /**
   * 扫描 Download + Documents 下的游戏镜像（递归）。
   *
   * 【为什么递归】用户习惯建子目录归档（实测：游戏放在 Documents/ps2/ 下）。
   * 非递归扫描会漏掉绝大多数文件。
   *
   * 【为什么不用 native 扫】ArkTS 的 fs.listFile 原生支持 recursion，
   * 权限也在 ArkTS 侧申请，少一层跨语言传递，失败原因也更容易带回 UI。
   * native 侧只负责"按给定真实路径打开镜像"。
   */
  static async scan(ctx: common.UIAbilityContext): Promise<ScanResult> {
    const granted = await ScanDirs.requestPermissions(ctx);
    const games: Array<ScannedGame> = [];
    const denied: Array<string> = [];

    // 逐个根解析；某个根不可用不影响另一个
    const roots: Array<ScanRoot> = [];
    try {
      if (granted.has('ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY')) {
        roots.push({
          label: 'Download',
          path: environment.getUserDownloadDir(),
          permission: 'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
        });
      } else {
        denied.push('Download');
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getUserDownloadDir failed');
      denied.push('Download');
    }
    try {
      if (granted.has('ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY')) {
        roots.push({
          label: 'Documents',
          path: environment.getUserDocumentDir(),
          permission: 'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
        });
      } else {
        denied.push('Documents');
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getUserDocumentDir failed');
      denied.push('Documents');
    }

    for (let i = 0; i < roots.length; i++) {
      const root = roots[i];
      try {
        // 递归列目录：recursion=true 时返回相对路径
        const entries = await fs.listFile(root.path, { recursion: true });
        for (let j = 0; j < entries.length; j++) {
          const rel = entries[j];
          const lower = rel.toLowerCase();
          if (!isGameFile(lower)) {
            continue;
          }
          const full = root.path + '/' + rel;
          let size = 0;
          try {
            size = fs.statSync(full).size;
          } catch (e) {
            // 单个文件 stat 失败（被删/无权限）不应中断整轮扫描
            hilog.warn(DOMAIN, TAG, 'stat scanned file failed, size=0');
          }
          games.push({
            path: full,
            name: rel,
            size: size,
            rootLabel: root.label,
          });
        }
        hilog.info(DOMAIN, TAG, 'scanned root %{public}s entries=%{public}d',
          root.label, entries.length);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'listFile failed for a scan root');
        denied.push(root.label + '（读取失败）');
      }
    }

    // 去重：同一文件可能同时出现在两个根（极少见，但用户可能建软链/重复放置）
    const seen: Set<string> = new Set<string>();
    const unique: Array<ScannedGame> = [];
    for (let i = 0; i < games.length; i++) {
      const g = games[i];
      if (seen.has(g.path)) {
        continue;
      }
      seen.add(g.path);
      unique.push(g);
    }
    // 大的排前面：PS2 镜像越大越可能是本体，帮用户先看到重点
    unique.sort((a: ScannedGame, b: ScannedGame) => b.size - a.size);

    let message = '';
    if (denied.length > 0) {
      message = '未授权或不可用：' + denied.join('、') +
        '。可在 系统设置 → 应用 → Hps2 → 权限 中开启。';
    }
    return {
      games: unique,
      message: message,
      ok: roots.length > 0,
    };
  }
}
