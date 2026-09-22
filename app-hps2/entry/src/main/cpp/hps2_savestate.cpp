/*
 * Hps2 — 即时存档实现。设计说明见 hps2_savestate.h。
 */

#include "hps2_savestate.h"

#include <hilog/log.h>

#include <chrono>
#include <thread>

#include "VMManager.h"
#include "R5900.h"
#include "common/Error.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_SAVE"

#define SLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define SLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2SaveState
{
	namespace
	{
		bool SlotValid(int slot)
		{
			return slot >= 1 && slot <= kSlotCount;
		}
	}

	Result Save(int slot)
	{
		Result r;
		if (!SlotValid(slot))
		{
			r.message = "无效的存档槽：" + std::to_string(slot);
			return r;
		}

		// VM 未运行时无法存档 —— 明确报出，而不是静默失败
		if (!VMManager::HasValidVM())
		{
			r.message = "尚未启动游戏，无法存档。";
			return r;
		}

		// 【线程一致性】与读档同理：存档要读取**一致的** VM 状态，
		// 而 VM 线程正在并发改写内存与寄存器。若不暂停，
		// 存下来的可能是"写了一半"的不一致状态。
		//
		// 上游 Hotkeys.cpp:115 直接调 SaveStateToSlot —— 因为上游的热键
		// 回调本身就在 CPU 线程上分发。我们的调用来自 JS 线程，
		// 故必须自己先暂停。
		const bool was_running = (VMManager::GetState() == VMState::Running);
		if (was_running)
		{
			VMManager::SetPaused(true);
			// 与读档同理：必须等 VM 真正退出 Execute()，
			// 否则保存到的是"写了一半"的不一致状态。
			constexpr int kMaxWaitMs = 3000;
			constexpr int kStepMs = 2;
			int waited = 0;
			while (Hps2VmSync::IsInExecute() && waited < kMaxWaitMs)
			{
				std::this_thread::sleep_for(std::chrono::milliseconds(kStepMs));
				waited += kStepMs;
			}
			SLOGI("SAVE: waited %{public}dms, still_in_execute=%{public}d",
				waited, Hps2VmSync::IsInExecute() ? 1 : 0);
		}

		// zip_on_thread=true：压缩放到后台线程，避免存档瞬间卡住画面
		// （上游 Hotkeys.cpp:115 亦如此调用）。
		VMManager::SaveStateToSlot(slot, true, [slot](const std::string& error) {
			if (!error.empty())
				SLOGE("save slot %{public}d failed: %{public}s", slot, error.c_str());
			else
				SLOGI("saved to slot %{public}d", slot);
		});

		// 注意：压缩在后台进行，此处返回"已开始"而非"已完成"。
		// 措辞需相应保守，避免用户以为立刻可用。
		if (was_running)
		{
			VMManager::SetPaused(false);
			SLOGI("SAVE: VM resumed");
		}

		r.ok = true;
		r.message = "已存档到槽 " + std::to_string(slot) + "（正在后台写入）";
		SLOGI("SaveStateToSlot(%{public}d) dispatched", slot);
		return r;
	}

	Result Load(int slot)
	{
		Result r;
		if (!SlotValid(slot))
		{
			r.message = "无效的存档槽：" + std::to_string(slot);
			return r;
		}

		if (!VMManager::HasValidVM())
		{
			r.message = "尚未启动游戏，无法读档。";
			return r;
		}

		// ==================================================================
		// 【根因修复】必须先把 VM 停下来，再读档。
		//
		// 上游 Hotkeys.cpp:99 的做法是把读档**投递到 CPU 线程**：
		//     Host::RunOnCPUThread([slot]() { LoadStateFromSlot(...); });
		// 而我们的 Host::RunOnCPUThread 是未实现的桩（hps2_host.cpp:305
		// pxFailRel("Not implemented")），且我们的 VM 跑在**独立线程**
		// 的长循环 VMManager::Execute() 里。
		//
		// 此前我们直接在 JS 线程调用 LoadStateFromSlot —— 于是与正在
		// 执行游戏代码的 VM 线程**并发覆写同一批状态**（内存、寄存器、
		// TLB、GS 状态），状态被撕裂。现象完全吻合：
		//     重编译器被 reset、PC 跳到错误地址、
		//     EE 读到 0x77（未初始化填充）并执行垃圾指令。
		//
		// 既然无法投递到 CPU 线程，就改用等效做法：
		//   1) 请求暂停（SetPaused(true) 会让 Cpu->Execute() 返回）
		//   2) 等待 VM 线程真正停下（轮询 GetState() 直到非 Running）
		//   3) 此时再读档 —— VM 已不在执行，状态覆写是安全的
		//   4) 读档后恢复运行
		// ==================================================================
		const bool was_running = (VMManager::GetState() == VMState::Running);
		SLOGI("LOAD step1: pausing VM (was_running=%{public}d)", was_running ? 1 : 0);

		if (was_running)
			VMManager::SetPaused(true);

		// ------------------------------------------------------------------
		// 【关键修正】等待 VM 线程真正退出 VMManager::Execute()。
		//
		// 原先的条件是 `while (GetState() == VMState::Running)` —— 那是
		// **形同虚设**：SetPaused(true) 会立刻把状态改成 Paused（因为就是
		// 我们自己设的），于是第一次检查就通过，实测耗时 0ms。
		// 结果读档仍在 VM 正在执行时进行 —— 状态依然被并发覆写。
		//
		// 现在改为等待 g_vm_in_execute（由 VM 线程在主循环里置位/清除），
		// 它真实反映"VM 线程是否阻塞在 Execute() 内"。
		// ------------------------------------------------------------------
		{
			constexpr int kMaxWaitMs = 3000;
			constexpr int kStepMs = 2;
			int waited = 0;
			while (Hps2VmSync::IsInExecute() && waited < kMaxWaitMs)
			{
				std::this_thread::sleep_for(std::chrono::milliseconds(kStepMs));
				waited += kStepMs;
			}
			const bool in_exec = Hps2VmSync::IsInExecute();
			SLOGI("LOAD step2: waited %{public}dms for Execute() to return; "
			      "still_in_execute=%{public}d state=%{public}d",
				waited, in_exec ? 1 : 0, static_cast<int>(VMManager::GetState()));
			if (in_exec)
			{
				// 超时仍未退出 —— 明确报出，不要假装安全。
				SLOGE("LOAD aborted: VM thread still in Execute() after %{public}dms; "
				      "refusing to load state (would corrupt it)",
					kMaxWaitMs);
				if (was_running)
					VMManager::SetPaused(false);
				r.message = "读档失败：模拟器线程未能在超时内暂停，已取消以避免损坏存档。";
				return r;
			}
		}

		SLOGI("LOAD step3: about to call LoadStateFromSlot(%{public}d)", slot);

		Error error;
		const bool ok = VMManager::LoadStateFromSlot(slot, false, &error);

		SLOGI("LOAD step4: LoadStateFromSlot returned ok=%{public}d", ok ? 1 : 0);

		// 直接读取 EE 的 PC，判断"状态是否真的恢复了"。
		// 真机日志显示恢复后 recExecute 打印 pc=0x00000001（非法值：
		// MIPS 指令必然 4 字节对齐，且 1 不在任何有效内存区）。
		// 在此处读值可区分两种情况：
		//   a) 读档刚结束 pc 就是错的 => 恢复流程本身有问题
		//   b) 读档后 pc 正确、后续被改 => 问题在恢复运行那一步
		SLOGI("LOAD check: after load, cpuRegs.pc=0x%{public}08X", cpuRegs.pc);

		// 读档完成后恢复运行（仅当读档前本来在运行）。
		// 这一步同样重要：若不恢复，用户会看到"读档后画面静止"。
		if (was_running && ok)
		{
			VMManager::SetPaused(false);
			SLOGI("LOAD step5: VM resumed");
		}

		if (!ok)
		{
			r.message = "读档失败：" + error.GetDescription();
			SLOGE("LoadStateFromSlot(%{public}d) failed: %{public}s",
				slot, error.GetDescription().c_str());
			return r;
		}

		r.ok = true;
		r.message = "已读取槽 " + std::to_string(slot);
		SLOGI("loaded from slot %{public}d", slot);
		return r;
	}

	bool HasSave(int slot)
	{
		if (!SlotValid(slot) || !VMManager::HasValidVM())
			return false;

		// 必须显式提供当前光盘的 serial 与 CRC。
		//
		// 我最初想用 VMManager::GetCurrentSaveStateFileName(slot)（它内部
		// 就是拿 s_disc_serial/s_disc_crc），但它是 **private** ——
		// 只在 VMManager.cpp:138 的类内声明，头文件里没有，外部无法调用。
		// 故改用公开的 GetDiscSerial()/GetDiscCRC() 自行组合。
		//
		// （不能传空 serial：GetSaveStateFileName 会据此推导文件名，
		//   空值得到的路径不指向真实存档。）
		const std::string serial = VMManager::GetDiscSerial();
		const u32 crc = VMManager::GetDiscCRC();
		if (serial.empty())
			return false;

		return VMManager::HasSaveStateInSlot(serial.c_str(), crc, slot);
	}

	std::string ListSlotsJson()
	{
		// 输出 [{slot, hasSave}, ...]
		std::string out = "[";
		for (int i = 1; i <= kSlotCount; ++i)
		{
			if (i > 1)
				out += ",";
			out += "{\"slot\":" + std::to_string(i)
				+ ",\"hasSave\":" + (HasSave(i) ? "true" : "false") + "}";
		}
		out += "]";
		return out;
	}
}
