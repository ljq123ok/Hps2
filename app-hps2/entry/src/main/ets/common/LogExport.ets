/*
 * Hps2 — 诊断日志导出
 *
 * 【为什么需要】项目一直没有反馈通道：用户遇到问题只能"描述现象"，
 * 而日志里其实有明确原因（BOOT_ERROR= / JIT_SELFCHECK= / 各类错误码）。
 * 结果就是"别人说启动不了"这类无法定位的反馈。
 *
 * 做法：把应用私有目录下的日志与设备信息汇总成一个文本文件，
 * 存到用户可见的目录（Download），用户可直接发送给我们。
 *
 * 【隐私边界】只导出诊断所需内容：
 *   - 核心日志 emulog.txt（模拟器自身的运行日志）
 *   - 设备型号、系统版本、JIT 自检结果、启动阶段
 * **不包含**：BIOS 文件内容、游戏镜像内容、任何文件路径中的用户目录名
 * 之外的隐私信息（路径会带上，便于定位，但不含文件内容）。
 */
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import util from '@ohos.util';

const DOMAIN = 0x3202;
const TAG = 'HPS2_CORE';

export class LogExport {
  /**
   * 生成诊断报告文本（不落盘，供调用方决定去处）。
   *
   * @param dataRoot 应用私有目录（含 emulog.txt）
   * @param extra 额外要记录的键值（如当前启动阶段、错误文字）
   */
  static build(dataRoot: string, extra: Array<string>): string {
    const lines: Array<string> = [];
    lines.push('===== Hps2 诊断报告 =====');
    lines.push('生成时间(UTC ms): ' + Date.now().toString());

    // --- 设备信息 ---
    lines.push('');
    lines.push('--- 设备信息 ---');
    lines.push('设备型号: ' + deviceInfo.marketName + ' (' + deviceInfo.productModel + ')');
    lines.push('系统版本: ' + deviceInfo.osFullName);
    lines.push('显示版本: ' + deviceInfo.displayVersion);
    lines.push('SDK API: ' + deviceInfo.sdkApiVersion.toString());
    lines.push('ABI: ' + deviceInfo.abiList);
    for (const e of extra) {
      lines.push(e);
    }

    // --- 核心日志 ---
    lines.push('');
    lines.push('--- 核心日志 (emulog.txt) ---');
    const logPath = dataRoot + '/emulog.txt';
    try {
      if (!fs.accessSync(logPath)) {
        lines.push('(日志文件不存在)');
      } else {
        const stat = fs.statSync(logPath);
        // 只取尾部：日志可能很大，而最近的失败原因总在结尾
        const MAX = 512 * 1024;
        const readSize = stat.size > MAX ? MAX : stat.size;
        const offset = stat.size - readSize;

        const file = fs.openSync(logPath, fs.OpenMode.READ_ONLY);
        try {
          const buf = new ArrayBuffer(readSize);
          // 从尾部读，避免把整个大文件读进内存
          fs.readSync(file.fd, buf, { offset: offset, length: readSize });
          const decoder = util.TextDecoder.create('utf-8');
          const text = decoder.decodeToString(new Uint8Array(buf));
          lines.push(text);
          if (offset > 0) {
            lines.push('');
            lines.push(`(仅显示最后 ${Math.round(readSize / 1024)} KB，完整日志共 ${Math.round(stat.size / 1024)} KB)`);
          }
        } finally {
          fs.closeSync(file);
        }
      }
    } catch (e) {
      lines.push('(读取日志失败: ' + JSON.stringify(e) + ')');
    }

    lines.push('');
    lines.push('===== 报告结束 =====');
    return lines.join('\n');
  }

  /**
   * 把报告写入用户可见目录。
   *
   * 目录选择：应用私有目录不可被其它应用读取，
   * 故写入 Download（设备上通常为 /storage/Users/currentUser/Download）。
   * 返回写入的完整路径，便于在 UI 上告诉用户去哪找。
   */
  static saveToDownload(ctx: common.UIAbilityContext, content: string): string {
    // 注意：应用对公共目录的写入受沙箱限制，此路径在多数 HarmonyOS
    // 设备上对应用可写（Download 属应用可访问的公共目录）。
    const dir = '/storage/Users/currentUser/Download';
    const name = 'hps2_diagnostic_' + Date.now().toString() + '.txt';
    const full = dir + '/' + name;

    try {
      const file = fs.openSync(full,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'diagnostic saved: %{public}s', full);
      return full;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save diagnostic failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }
}
