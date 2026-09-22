/*
 * Hps2 — 即时存档（savestate）
 *
 * 复用上游 PCSX2 的存档槽机制（VMManager 已提供，无需自行实现序列化）：
 *   VMManager::SaveStateToSlot(slot, zip_on_thread, error_callback)
 *   VMManager::LoadStateFromSlot(slot, backup, error)
 *   VMManager::HasSaveStateInSlot(serial, crc, slot)
 *
 * 【与"记忆卡存档"的区别】这是**即时存档**（整机状态快照，含内存、
 * 寄存器、显存等），可随时存/读，与游戏内的记忆卡存档互不影响。
 *
 * 【线程】上游的 Hotkeys 用法（Hotkeys.cpp:113-118）表明可直接调用，
 * 其中 zip_on_thread=true 让压缩在后台线程进行，避免卡住主流程。
 */
#pragma once

#include <functional>
#include <string>

namespace Hps2VmSync
{
	/// VM 线程此刻是否阻塞在 VMManager::Execute() 内。
	/// 定义在 napi_init.cpp（只有那里知道主循环状态）。
	/// 读档/存档前用它判断是否已达安全点。
	bool IsInExecute();

	/// 把任务投递到 VM 线程执行并等待完成（等效上游 Host::RunOnCPUThread）。
	/// 读档/存档必须经此调用：它们要重建重编译器状态与 TLB 映射，
	/// 这些只允许在 VM 线程上下文里发生。
	/// 返回 false 表示 VM 未运行或超时。
	bool RunOnVmThread(std::function<void()> fn, int timeout_ms);
}

namespace Hps2SaveState
{
	/** 存档槽数量。上游常用 1..10，这里取 8 个便于 UI 排布。 */
	constexpr int kSlotCount = 8;

	/** 一次操作的结果 */
	struct Result
	{
		bool ok = false;
		std::string message;   // 面向用户的说明
	};

	/** 存档到指定槽（1-based）。zip_on_thread=true 时压缩在后台，不阻塞。 */
	Result Save(int slot);

	/** 从指定槽读取（1-based）。 */
	Result Load(int slot);

	/** 该槽是否已有存档。 */
	bool HasSave(int slot);

	/** 返回各槽状态（JSON 数组），供 UI 展示。 */
	std::string ListSlotsJson();
}
