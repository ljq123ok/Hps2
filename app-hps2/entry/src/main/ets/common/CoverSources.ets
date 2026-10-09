/*
 * Hps2 — 封面库源配置
 *
 * 【为什么需要这个模块】封面下载要联网，而"哪个源可用"高度依赖用户所处
 * 网络环境。实测（2026-10-09，Mac 与手机双侧）：
 *   - gh-proxy.com（国内可达的 GitHub 代理）：3/3 成功，约 2.7s  ← 最快
 *   - raw.githubusercontent.com（GitHub 官方）：2/3 成功，偶发超时
 *   - cdn.jsdelivr.net（国内 CDN）：2/3 成功，较慢
 * 手机侧对三者都能完成 TLS 握手。
 *
 * 因此不能写死单一源，否则用户在另一种网络下就是"点了没反应"。
 * 本模块提供：内置源列表 + 用户自选 + 自定义源（可增删）。
 *
 * 【URL 模板】沿用上游 GameList::DownloadCovers 的占位符约定：
 *   ${serial}    游戏序列号，如 SCPS-15062（封面库普遍按此命名）
 *   ${title}     游戏正式标题（来自 GameDB）
 *   ${filetitle} 镜像文件名（去扩展名）
 * 模板必须含其中至少一个，否则无法定位封面。
 *
 * 【命名规则提醒】上游按 "serial → 文件标题 → 标题" 的顺序在
 * covers/ 目录里找图（见 GetCoverImagePathForEntry）。所以按 serial
 * 下载最通用 —— 这也是默认模板用 ${serial} 的原因。
 */
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

/** 一个封面库源 */
export interface CoverSource {
  /** 稳定标识，用于持久化用户选择；自定义源需唯一 */
  id: string;
  /** 界面上显示的名字 */
  name: string;
  /** URL 模板，含 ${serial} / ${title} / ${filetitle} 占位符 */
  urlTemplate: string;
  /** true = 内置源（不可删除，但可编辑 URL 作为"高级覆盖"） */
  builtin: boolean;
  /** 备注（显示在界面上，说明该源的适用网络） */
  note: string;
}

/**
 * 内置源。
 *
 * 顺序即默认优先级：把国内可达的放前面，让默认体验最好。
 * 用户可单独启用/禁用，也可调整顺序（见 CoverSourceStore）。
 */
export const BUILTIN_COVER_SOURCES: Array<CoverSource> = [
  {
    id: 'ghproxy',
    name: '国内加速（gh-proxy）',
    urlTemplate: 'https://gh-proxy.com/https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/${serial}.jpg',
    builtin: true,
    note: '国内直连最快的 GitHub 加速，实测约 2.7s',
  },
  {
    id: 'github-raw',
    name: 'GitHub 官方',
    urlTemplate: 'https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/${serial}.jpg',
    builtin: true,
    note: '官方源；国内可能不稳定或超时',
  },
  {
    id: 'jsdelivr',
    name: 'jsDelivr CDN',
    urlTemplate: 'https://cdn.jsdelivr.net/gh/xlenore/ps2-covers@main/covers/default/${serial}.jpg',
    builtin: true,
    note: '国内可达的 CDN，速度较慢，作为备用',
  },
];

/** 占位符 —— 校验自定义模板时用 */
export const COVER_PLACEHOLDERS: Array<string> = ['${serial}', '${title}', '${filetitle}'];

/** 模板是否合法：必须含至少一个占位符，且是 http(s) */
export function isValidCoverTemplate(tpl: string): boolean {
  if (!tpl || tpl.length === 0) {
    return false;
  }
  if (!tpl.startsWith('http://') && !tpl.startsWith('https://')) {
    return false;
  }
  for (const p of COVER_PLACEHOLDERS) {
    if (tpl.indexOf(p) >= 0) {
      return true;
    }
  }
  return false;
}

/** 模板里用到的占位符（生成 URL 时决定要替换哪些）*/
export function templatePlaceholders(tpl: string): Array<string> {
  const out: Array<string> = [];
  for (const p of COVER_PLACEHOLDERS) {
    if (tpl.indexOf(p) >= 0) {
      out.push(p);
    }
  }
  return out;
}

/** 把模板实例化成实际 URL。占位符缺失的值用空串替换（保持长度不变）*/
export function buildCoverUrl(tpl: string, serial: string, title: string, fileTitle: string): string {
  let url = tpl;
  if (serial && serial.length > 0) {
    url = url.replace(/\$\{serial\}/g, encodeURIComponent(serial));
  }
  if (title && title.length > 0) {
    url = url.replace(/\$\{title\}/g, encodeURIComponent(title));
  }
  if (fileTitle && fileTitle.length > 0) {
    url = url.replace(/\$\{filetitle\}/g, encodeURIComponent(fileTitle));
  }
  return url;
}

/** 持久化结构 */
interface CoverSourceFile {
  version: number;
  /** 当前选中的源 id；空 = 未选择（用第一个启用的）*/
  selectedId: string;
  /** 用户自定义源 */
  custom: Array<CoverSource>;
  /** 被用户禁用的内置源 id */
  disabled: Array<string>;
}

const COVER_SOURCE_VERSION: number = 1;

/**
 * 封面源存储。
 *
 * 容错原则（与项目其它设置一致）：文件缺失/损坏一律退回内置默认，
 * 绝不让坏配置导致"封面功能整个不可用"。
 */
export class CoverSourceStore {
  private selectedId: string = '';
  private custom: Array<CoverSource> = [];
  private disabled: Array<string> = [];

  /** 全部可用源（内置在前，自定义在后），已剔除被禁用的 */
  all(): Array<CoverSource> {
    const out: Array<CoverSource> = [];
    for (const s of BUILTIN_COVER_SOURCES) {
      if (this.disabled.indexOf(s.id) < 0) {
        out.push(s);
      }
    }
    for (const s of this.custom) {
      out.push(s);
    }
    return out;
  }

  /** 当前选中的源；未选中或已失效时退回第一个可用源 */
  current(): CoverSource | null {
    const list = this.all();
    if (list.length === 0) {
      return null;
    }
    for (const s of list) {
      if (s.id === this.selectedId) {
        return s;
      }
    }
    return list[0];
  }

  getSelectedId(): string {
    return this.selectedId;
  }

  select(id: string): void {
    this.selectedId = id;
  }

  /** 新增自定义源。返回错误说明；成功时返回空串 */
  addCustom(name: string, urlTemplate: string): string {
    const trimmedName = name.trim();
    const trimmedUrl = urlTemplate.trim();
    if (trimmedName.length === 0) {
      return '请填写源名称';
    }
    if (!isValidCoverTemplate(trimmedUrl)) {
      return 'URL 模板无效：需以 http(s):// 开头，且含 ${serial} / ${title} / ${filetitle} 之一';
    }
    // id 用时间戳保证唯一，避免依赖随机数
    const id = 'custom-' + Date.now().toString();
    this.custom.push({
      id: id,
      name: trimmedName,
      urlTemplate: trimmedUrl,
      builtin: false,
      note: '自定义源',
    });
    // 新增后默认切到它 —— 用户刚加完通常就想试试
    this.selectedId = id;
    return '';
  }

  removeCustom(id: string): boolean {
    for (let i = 0; i < this.custom.length; i++) {
      if (this.custom[i].id === id) {
        this.custom.splice(i, 1);
        if (this.selectedId === id) {
          this.selectedId = '';
        }
        return true;
      }
    }
    return false;
  }

  /** 启用/禁用内置源。禁用当前选中的源时自动回退 */
  setBuiltinEnabled(id: string, enabled: boolean): void {
    const idx = this.disabled.indexOf(id);
    if (enabled && idx >= 0) {
      this.disabled.splice(idx, 1);
    } else if (!enabled && idx < 0) {
      this.disabled.push(id);
    }
  }

  isBuiltinEnabled(id: string): boolean {
    return this.disabled.indexOf(id) < 0;
  }

  customSources(): Array<CoverSource> {
    return this.custom;
  }

  private filePath(root: string): string {
    return root + '/cover-sources.json';
  }

  save(root: string): void {
    try {
      const data: CoverSourceFile = {
        version: COVER_SOURCE_VERSION,
        selectedId: this.selectedId,
        custom: this.custom,
        disabled: this.disabled,
      };
      const file = fs.openSync(this.filePath(root),
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(data));
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'saved cover sources (custom=%{public}d)', this.custom.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save cover sources failed');
    }
  }

  load(root: string): void {
    try {
      const path = this.filePath(root);
      if (!fs.accessSync(path)) {
        return;
      }
      const raw = fs.readTextSync(path);
      if (!raw || raw.length === 0) {
        return;
      }
      const data = JSON.parse(raw) as CoverSourceFile;
      if (data.version !== COVER_SOURCE_VERSION) {
        hilog.warn(DOMAIN, TAG, 'cover sources version mismatch -> defaults');
        return;
      }
      this.selectedId = data.selectedId || '';
      this.disabled = data.disabled || [];
      // 只接受结构完整的自定义源，坏条目直接丢弃
      const list: Array<CoverSource> = [];
      const src = data.custom || [];
      for (let i = 0; i < src.length; i++) {
        const s = src[i];
        if (s && s.id && s.name && isValidCoverTemplate(s.urlTemplate)) {
          list.push({
            id: s.id,
            name: s.name,
            urlTemplate: s.urlTemplate,
            builtin: false,
            note: '自定义源',
          });
        }
      }
      this.custom = list;
      hilog.info(DOMAIN, TAG, 'restored cover sources (custom=%{public}d)', this.custom.length);
    } catch (e) {
      // 坏文件：保持内置默认，不阻断
      hilog.error(DOMAIN, TAG, 'load cover sources failed, using defaults');
      this.selectedId = '';
      this.custom = [];
      this.disabled = [];
    }
  }
}

/** 跨组件共享的单例（与 SharedPadLayout 同一套做法）*/
export class SharedCoverSources {
  static store: CoverSourceStore = new CoverSourceStore();
}
