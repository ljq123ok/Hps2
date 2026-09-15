# BIOS 加载设计：用户提供 + 文件管理器选择

**决策（用户明确要求）**：BIOS **不内置、不打包、不分发**。
用户自行准备 BIOS，App 通过系统文件管理器让用户选择后加载。

**理由**：BIOS 是索尼的版权作品，随 App 分发构成侵权。
这也符合任务书的要求（"应用不得内置或分发 BIOS、商业游戏镜像"）。

---

## 1. 技术可行性（已核实 API，非推测）

### 1.1 文件选择

`@ohos.file.picker` 提供 `DocumentViewPicker`：

```typescript
class DocumentViewPicker {
  constructor(context: Context);
  select(option?: DocumentSelectOptions): Promise<Array<string>>;  // 返回 URI 数组
}

class DocumentSelectOptions {
  defaultFilePathUri?: string;
  fileSuffixFilters?: Array<string>;   // 可限定 *.bin 等
}
```

### 1.2 把选中的文件读入应用沙箱

picker 返回的是 **URI**（如 `file://docs/storage/...`），
而 PCSX2 核心需要**真实文件系统路径**。已核实：

```typescript
declare function copyFileSync(src: string | number, dest: string | number, mode?: number): void;
```

`copyFileSync` 接受 URI 作为 src、沙箱路径作为 dest —— 正好满足需求。

### 1.3 为何要复制而不是直接传 URI

- 核心（PCSX2）通过 `std::ifstream` / `mmap` 打开文件，需要 POSIX 路径
- 外部 URI 的授权是**临时**的，App 重启后即失效，
  而模拟器需要长期稳定访问 BIOS
- 复制到沙箱后，App 对 BIOS 拥有完全控制权，路径稳定
