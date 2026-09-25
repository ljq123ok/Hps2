// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// OpenHarmony native audio output. SDL3 currently has no OHOS audio driver in
// this tree and its fallback driver is intentionally silent, so the emulator
// must use libohaudio directly on OHOS.

#include "Host/AudioStream.h"

#include "common/Error.h"
#include "common/Console.h"

#include <ohaudio/native_audiostreambuilder.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>

namespace
{
class OHAudioStream final : public AudioStream
{
public:
	OHAudioStream(u32 sample_rate, const AudioStreamParameters& parameters)
		: AudioStream(sample_rate, parameters)
	{
	}

	~OHAudioStream() override
	{
		if (m_builder)
		{
			OH_AudioStreamBuilder_Destroy(m_builder);
			m_builder = nullptr;
		}
		if (m_renderer)
		{
			OH_AudioRenderer_Stop(m_renderer);
			OH_AudioRenderer_Release(m_renderer);
			m_renderer = nullptr;
		}
	}

	bool Initialize(bool stretch_enabled, Error* error)
	{
		OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&m_builder, AUDIOSTREAM_TYPE_RENDERER);
		if (result != AUDIOSTREAM_SUCCESS)
			return Fail(error, "OH_AudioStreamBuilder_Create", result);

		if (!Check(OH_AudioStreamBuilder_SetSamplingRate(m_builder, static_cast<int32_t>(m_sample_rate)),
			"OH_AudioStreamBuilder_SetSamplingRate", error) ||
			!Check(OH_AudioStreamBuilder_SetChannelCount(m_builder, 2),
				"OH_AudioStreamBuilder_SetChannelCount", error) ||
			// S16LE is supported since API 10.  F32LE was added later, and a
			// negotiated integer format must never receive float samples.
			!Check(OH_AudioStreamBuilder_SetSampleFormat(m_builder, AUDIOSTREAM_SAMPLE_S16LE),
				"OH_AudioStreamBuilder_SetSampleFormat", error) ||
			!Check(OH_AudioStreamBuilder_SetEncodingType(m_builder, AUDIOSTREAM_ENCODING_TYPE_RAW),
				"OH_AudioStreamBuilder_SetEncodingType", error) ||
			!Check(OH_AudioStreamBuilder_SetRendererInfo(m_builder, AUDIOSTREAM_USAGE_GAME),
				"OH_AudioStreamBuilder_SetRendererInfo", error) ||
			!Check(OH_AudioStreamBuilder_SetLatencyMode(m_builder,
				m_parameters.minimal_output_latency ? AUDIOSTREAM_LATENCY_MODE_FAST : AUDIOSTREAM_LATENCY_MODE_NORMAL),
				"OH_AudioStreamBuilder_SetLatencyMode", error) ||
			!Check(OH_AudioStreamBuilder_SetRendererWriteDataCallback(m_builder, &WriteCallback, this),
				"OH_AudioStreamBuilder_SetRendererWriteDataCallback", error))
		{
			return false;
		}

		result = OH_AudioStreamBuilder_GenerateRenderer(m_builder, &m_renderer);
		OH_AudioStreamBuilder_Destroy(m_builder);
		m_builder = nullptr;
		if (result != AUDIOSTREAM_SUCCESS || !m_renderer)
			return Fail(error, "OH_AudioStreamBuilder_GenerateRenderer", result);

		// The renderer may negotiate a device format different from the request.
		// A mismatch here changes the audio clock and produces gradual A/V drift,
		// so make it visible in the device log instead of silently accepting it.
		int32_t actual_rate = 0;
		int32_t actual_channels = 0;
		OH_AudioStream_SampleFormat actual_format = AUDIOSTREAM_SAMPLE_S16LE;
		int32_t callback_frames = 0;
		const OH_AudioStream_Result rate_result = OH_AudioRenderer_GetSamplingRate(m_renderer, &actual_rate);
		const OH_AudioStream_Result channels_result = OH_AudioRenderer_GetChannelCount(m_renderer, &actual_channels);
		const OH_AudioStream_Result format_result = OH_AudioRenderer_GetSampleFormat(m_renderer, &actual_format);
		const OH_AudioStream_Result frame_result = OH_AudioRenderer_GetFrameSizeInCallback(m_renderer, &callback_frames);
		if (rate_result == AUDIOSTREAM_SUCCESS && channels_result == AUDIOSTREAM_SUCCESS &&
			format_result == AUDIOSTREAM_SUCCESS)
		{
			m_sample_format = actual_format;
			INFO_LOG("OpenHarmony audio negotiated format: {} Hz, {} channels, sample format {}, callback frames {} "
				"(requested {} Hz, 2 channels, S16LE)",
				actual_rate, actual_channels, static_cast<int>(actual_format),
				frame_result == AUDIOSTREAM_SUCCESS ? callback_frames : 0, m_sample_rate);
			if (actual_rate != static_cast<int32_t>(m_sample_rate) || actual_channels != 2)
				WARNING_LOG("OpenHarmony audio format mismatch may cause A/V drift");
		}
		else
		{
			WARNING_LOG("OpenHarmony audio could not query negotiated format: rate={}, channels={}, format={}, frames={}",
				static_cast<int>(rate_result), static_cast<int>(channels_result),
				static_cast<int>(format_result), static_cast<int>(frame_result));
		}

		// Allocate this before the real-time callback starts.  Integer output
		// formats are converted from the core's float samples without allocating
		// on the audio thread.
		m_callback_buffer_frames = std::max<u32>(callback_frames > 0 ? static_cast<u32>(callback_frames) : 1024u, 1024u);
		m_callback_float_buffer = std::make_unique<float[]>(m_callback_buffer_frames * 2);

		// ------------------------------------------------------------------
		// 【爆音修复】核心环形缓冲的水位必须 >= 单次回调的请求量。
		//
		// 核心的目标水位由 buffer_ms 决定（AudioStream.cpp:420）：
		//     m_target_buffer_size = rate * buffer_ms / 1000
		// 而 ReadFrames 在 available < requested 时会**掺入静音**
		// （silence_frames = frames_to_read - available_frames），
		// 并置 m_filling —— 下一次回调整段返回静音。
		// 声音与静音交替 = 听感上的**爆音 / 咔哒**。
		//
		// 真机实测（HarmonyOS API 26 测试设备）：
		//     buffer = 50 (ms) -> 目标水位 2400 帧
		//     callback frames = 4458 帧 (= 92.9 ms)
		//     即单次请求是目标水位的 **1.86 倍**
		// 于是每次回调都欠载 -> 持续掺静音 -> 爆音。
		//
		// 修法：在**得知实际回调帧数之后**（此处），按需抬高 buffer_ms，
		// 使目标水位覆盖单次回调，并留出安全余量。
		// 注意必须在本函数内、BaseInitialize() 之前调整 ——
		// 因为环形缓冲正是在 BaseInitialize -> AllocateBuffer() 中按
		// m_parameters.buffer_ms 分配的，之后再改无效。
		// ------------------------------------------------------------------
		if (callback_frames > 0)
		{
			const u32 requested_frames = static_cast<u32>(callback_frames);
			// 用 m_sample_rate：核心环形缓冲就是按它分配的（见 AllocateBuffer），
			// 必须与之一致，否则算出的水位对不上。
			const u32 rate = static_cast<u32>(m_sample_rate);
			const u32 current_target =
				(static_cast<u32>(m_parameters.buffer_ms) * rate) / 1000u;
			if (requested_frames > current_target)
			{
				// 目标水位 = 单次回调量 + 50% 余量，向上取整到毫秒
				const u32 safe_frames = requested_frames + requested_frames / 2;
				const u32 needed_ms =
					(safe_frames * 1000u + rate - 1u) / rate;
				INFO_LOG("OpenHarmony audio: callback requests {} frames but buffer_ms {} only "
					"covers {} frames; raising buffer_ms to {} to avoid underrun (crackling)",
					requested_frames, m_parameters.buffer_ms, current_target, needed_ms);
				m_parameters.buffer_ms = static_cast<u16>(needed_ms);
			}
		}

		// The core's AudioStream ring buffer must be ready before the system
		// callback can start pulling frames.
		BaseInitialize(&StereoSampleReaderImpl, stretch_enabled);
		result = OH_AudioRenderer_SetVolume(m_renderer, 1.0f);
		if (result != AUDIOSTREAM_SUCCESS)
			return Fail(error, "OH_AudioRenderer_SetVolume", result);

		// SPU2 calls SetPaused() immediately after CreateStream(). Delay the
		// renderer start until that point so the native callback cannot consume
		// silence before the VM has established its running state.
		m_running = false;
		INFO_LOG("OpenHarmony audio stream prepared: {} Hz, stereo format {}", m_sample_rate,
			static_cast<int>(m_sample_format));
		return true;
	}

	void SetPaused(bool paused) override
	{
		if (!m_renderer || paused == !m_running)
		{
			AudioStream::SetPaused(paused);
			return;
		}

		const OH_AudioStream_Result result = paused ? OH_AudioRenderer_Pause(m_renderer)
			: OH_AudioRenderer_Start(m_renderer);
		if (result == AUDIOSTREAM_SUCCESS)
			m_running = !paused;
		else
			WARNING_LOG("OpenHarmony audio {} failed: {}", paused ? "pause" : "resume", static_cast<int>(result));

		AudioStream::SetPaused(paused);
	}

private:
	static OH_AudioData_Callback_Result WriteCallback(OH_AudioRenderer*, void* user_data,
		void* audio_data, int32_t audio_data_size)
	{
		auto* self = static_cast<OHAudioStream*>(user_data);
		if (!self || !audio_data || audio_data_size <= 0)
			return AUDIO_DATA_CALLBACK_RESULT_INVALID;

		const u32 bytes_per_sample = BytesPerSample(self->m_sample_format);
		if (bytes_per_sample == 0 || (audio_data_size % static_cast<int32_t>(bytes_per_sample * 2)) != 0)
			return AUDIO_DATA_CALLBACK_RESULT_INVALID;

		const u32 frames = static_cast<u32>(audio_data_size) / (bytes_per_sample * 2);
		if (self->m_sample_format == AUDIOSTREAM_SAMPLE_F32LE)
		{
			self->ReadFrames(static_cast<float*>(audio_data), frames);
		}
		else
		{
			if (!self->m_callback_float_buffer || frames > self->m_callback_buffer_frames)
				return AUDIO_DATA_CALLBACK_RESULT_INVALID;

			self->ReadFrames(self->m_callback_float_buffer.get(), frames);
			self->ConvertSamples(audio_data, self->m_callback_float_buffer.get(), frames);
		}
		return AUDIO_DATA_CALLBACK_RESULT_VALID;
	}

	static u32 BytesPerSample(OH_AudioStream_SampleFormat format)
	{
		switch (format)
		{
			case AUDIOSTREAM_SAMPLE_U8: return 1;
			case AUDIOSTREAM_SAMPLE_S16LE: return 2;
			case AUDIOSTREAM_SAMPLE_S24LE: return 3;
			case AUDIOSTREAM_SAMPLE_S32LE:
			case AUDIOSTREAM_SAMPLE_F32LE: return 4;
			default: return 0;
		}
	}

	static int32_t ClampS32(float value)
	{
		return static_cast<int32_t>(std::lrintf(std::clamp(value, -1.0f, 1.0f) * 2147483647.0f));
	}

	void ConvertSamples(void* output, const float* input, u32 frames)
	{
		const u32 samples = frames * 2;
		switch (m_sample_format)
		{
			case AUDIOSTREAM_SAMPLE_U8:
			{
				auto* dst = static_cast<uint8_t*>(output);
				for (u32 i = 0; i < samples; i++)
					dst[i] = static_cast<uint8_t>(std::clamp(128 + std::lrintf(std::clamp(input[i], -1.0f, 1.0f) * 127.0f), 0l, 255l));
				break;
			}
			case AUDIOSTREAM_SAMPLE_S16LE:
			{
				auto* dst = static_cast<int16_t*>(output);
				for (u32 i = 0; i < samples; i++)
					dst[i] = static_cast<int16_t>(std::lrintf(std::clamp(input[i], -1.0f, 1.0f) * 32767.0f));
				break;
			}
			case AUDIOSTREAM_SAMPLE_S24LE:
			{
				auto* dst = static_cast<uint8_t*>(output);
				for (u32 i = 0; i < samples; i++)
				{
					const int32_t value = ClampS32(input[i]) >> 8;
					dst[i * 3 + 0] = static_cast<uint8_t>(value & 0xff);
					dst[i * 3 + 1] = static_cast<uint8_t>((value >> 8) & 0xff);
					dst[i * 3 + 2] = static_cast<uint8_t>((value >> 16) & 0xff);
				}
				break;
			}
			case AUDIOSTREAM_SAMPLE_S32LE:
			{
				auto* dst = static_cast<int32_t*>(output);
				for (u32 i = 0; i < samples; i++)
					dst[i] = ClampS32(input[i]);
				break;
			}
			default:
				break;
		}
	}

	bool Check(OH_AudioStream_Result result, const char* operation, Error* error)
	{
		if (result == AUDIOSTREAM_SUCCESS)
			return true;
		return Fail(error, operation, result);
	}

	bool Fail(Error* error, const char* operation, OH_AudioStream_Result result)
	{
		Error::SetStringFmt(error, "{} failed (result={})", operation, static_cast<int>(result));
		ERROR_LOG("OpenHarmony audio: {} failed (result={})", operation, static_cast<int>(result));
		return false;
	}

	OH_AudioStreamBuilder* m_builder = nullptr;
	OH_AudioRenderer* m_renderer = nullptr;
	OH_AudioStream_SampleFormat m_sample_format = AUDIOSTREAM_SAMPLE_S16LE;
	std::unique_ptr<float[]> m_callback_float_buffer;
	u32 m_callback_buffer_frames = 0;
	bool m_running = false;
};
} // namespace

std::unique_ptr<AudioStream> AudioStream::CreateOHAudioStream(u32 sample_rate,
	const AudioStreamParameters& parameters, bool stretch_enabled, Error* error)
{
	std::unique_ptr<OHAudioStream> stream = std::make_unique<OHAudioStream>(sample_rate, parameters);
	if (!stream->Initialize(stretch_enabled, error))
		return nullptr;
	return stream;
}
