# 上游改动归档（upstream/ARMSX2）

`upstream/` 在根 `.gitignore` 中被忽略（它是外部源码树，体积大）。
但我们对上游做了**必要修改**，若不归档，**换环境重新克隆就会丢失**。

## 目录说明

| 路径 | 内容 |
|---|---|
| `upstream/0001-hps2-upstream-modifications.patch` | 对上游已有文件的修改（`git diff` 格式） |
| `new-files/` | 我们**新增**到上游源码树的文件（补丁无法表达） |

## 应用方式

```bash
cd upstream/ARMSX2

# 1) 应用对已有文件的修改
git apply ../../patches/upstream/0001-hps2-upstream-modifications.patch

# 2) 恢复新增文件
cp -r ../../patches/new-files/* .
```

## 当前归档的改动

### 修改已有文件（6 个，共 73 行新增）

| 文件 | 改动 |
|---|---|
| `pcsx2/GS/Renderers/OpenGL/GLContextEGLOHOS.cpp` | `ResizeSurface` 重建 EGLSurface —— **修旋转后黑屏**（+57 行）|
| `pcsx2/CMakeLists.txt` | 注册 OHAudioStream.cpp 等（+4 行）|
| `pcsx2/Config.h` | OHOS 平台默认音频后端 = OHAudio（+2 行）|
| `pcsx2/Host/AudioStreamTypes.h` | OHAudio 后端枚举（+1 行）|
| `pcsx2/Host/AudioStream.cpp` | OHAudio 分支接入（+5 行）|
| `pcsx2/Host/AudioStream.h` | OHAudio 创建接口声明（+4 行）|

### 新增文件

| 文件 | 说明 |
|---|---|
| `pcsx2/Host/OHAudioStream.cpp` | **HarmonyOS OHAudio 音频后端**（11.8 KB）。含本次爆音修复：按系统实际回调帧数自适应抬高 `buffer_ms` |

## 注意

- 上游 `git status` 还会显示 **563 个被删除的图片**（`platforms/ios` 400 个、
  `platforms/android` 161 个）—— 那是清理仓库体积时移除的移动端资源，
  **与功能无关，不影响构建**，故未纳入补丁。
- 补丁基于当前上游版本生成。若上游更新，重新 `git apply` 可能需要手工解决冲突。

## 维护约定

**每次修改 `upstream/` 下的文件后，必须重新生成本归档**：

```bash
cd upstream/ARMSX2
git diff -- '*.cpp' '*.h' '*.txt' > ../../patches/upstream/0001-hps2-upstream-modifications.patch
# 若有新增文件，同步到 patches/new-files/ 对应路径
```
