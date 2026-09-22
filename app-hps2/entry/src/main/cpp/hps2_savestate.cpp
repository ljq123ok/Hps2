/*
 * Hps2 — 即时存档实现。设计说明见 hps2_savestate.h。
 */

#include "hps2_savestate.h"

#include <hilog/log.h>

#include "VMManager.h"
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

		// ------------------------------------------------------------------
		// 分步日志：读档曾导致 native 崩溃（cppcrash），但崩溃日志不可达
		// （shell 访问不到 /data/log）。故在每一步前打日志，
		// 复现后即可据"最后成功打印的那一步"确定崩溃位置。
		//
		// 注意：读档会恢复内存、寄存器与 GS 状态，任何一步都可能崩，
		// 因此逐步打点比只记录成功/失败更有诊断价值。
		// ------------------------------------------------------------------
		SLOGI("LOAD step1: about to call LoadStateFromSlot(%{public}d)", slot);

		Error error;
		const bool ok = VMManager::LoadStateFromSlot(slot, false, &error);

		SLOGI("LOAD step2: LoadStateFromSlot returned ok=%{public}d", ok ? 1 : 0);

		if (!ok)
		{
			r.message = "读档失败：" + error.GetDescription();
			SLOGE("LoadStateFromSlot(%{public}d) failed: %{public}s",
				slot, error.GetDescription().c_str());
			return r;
		}

		// 读档会替换整个 VM 状态。若这一步之后崩溃，说明问题出在
		// "恢复后的状态被使用"（例如 GS 重放、CPU 恢复执行）而非读取本身。
		SLOGI("LOAD step3: state restored, VM should continue");

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
