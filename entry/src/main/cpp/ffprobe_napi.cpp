#include <napi/native_api.h>
#include <string>
#include <cstdio>
#include <cstring>
#include <cstdint>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixfmt.h>
#include <libavutil/time.h>
#include <native_window/external_window.h>
#include <native_buffer/buffer_common.h>
#include <cstdlib>
}

namespace {

constexpr int64_t PROBE_TIMEOUT_US = 8 * 1000 * 1000;

std::string JsonEscape(const char *input) {
    std::string out;
    if (input == nullptr) {
        return out;
    }
    for (const char *p = input; *p != '\0'; ++p) {
        unsigned char c = static_cast<unsigned char>(*p);
        switch (c) {
            case '\"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8] = {0};
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::string DictValue(AVDictionary *dict, const char *key) {
    if (dict == nullptr) {
        return std::string();
    }
    AVDictionaryEntry *entry = av_dict_get(dict, key, nullptr, 0);
    if (entry == nullptr || entry->value == nullptr) {
        return std::string();
    }
    return std::string(entry->value);
}

const char *StreamTypeName(AVMediaType type) {
    switch (type) {
        case AVMEDIA_TYPE_VIDEO: return "video";
        case AVMEDIA_TYPE_AUDIO: return "audio";
        case AVMEDIA_TYPE_SUBTITLE: return "subtitle";
        default: return "other";
    }
}

bool IsHdr(const AVCodecParameters *par) {
    if (par == nullptr) {
        return false;
    }
    return par->color_trc == AVCOL_TRC_SMPTE2084 || par->color_trc == AVCOL_TRC_ARIB_STD_B67;
}

int InterruptCallback(void *opaque) {
    if (opaque == nullptr) {
        return 0;
    }
    int64_t deadline = *static_cast<int64_t *>(opaque);
    return av_gettime_relative() > deadline ? 1 : 0;
}

std::string DoProbe(const std::string &url) {
    avformat_network_init();
    AVFormatContext *fmt = avformat_alloc_context();
    if (fmt == nullptr) {
        avformat_network_deinit();
        return std::string();
    }
    int64_t deadline = av_gettime_relative() + PROBE_TIMEOUT_US;
    fmt->interrupt_callback.callback = InterruptCallback;
    fmt->interrupt_callback.opaque = &deadline;

    AVDictionary *options = nullptr;
    av_dict_set(&options, "timeout", "8000000", 0);
    av_dict_set(&options, "rw_timeout", "8000000", 0);
    int ret = avformat_open_input(&fmt, url.c_str(), nullptr, &options);
    av_dict_free(&options);
    if (ret < 0 || fmt == nullptr) {
        if (fmt != nullptr) {
            avformat_close_input(&fmt);
        }
        avformat_network_deinit();
        return std::string();
    }
    fmt->interrupt_callback.callback = InterruptCallback;
    fmt->interrupt_callback.opaque = &deadline;
    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        avformat_close_input(&fmt);
        avformat_network_deinit();
        return std::string();
    }

    std::string json = "[";
    bool first = true;
    for (unsigned int i = 0; i < fmt->nb_streams; ++i) {
        AVStream *stream = fmt->streams[i];
        if (stream == nullptr || stream->codecpar == nullptr) {
            continue;
        }
        AVCodecParameters *par = stream->codecpar;
        if (par->codec_type != AVMEDIA_TYPE_VIDEO && par->codec_type != AVMEDIA_TYPE_AUDIO &&
            par->codec_type != AVMEDIA_TYPE_SUBTITLE) {
            continue;
        }
        if (!first) {
            json += ",";
        }
        first = false;
        json += "{";
        json += "\"index\":" + std::to_string(stream->index);
        json += ",\"type\":\"" + std::string(StreamTypeName(par->codec_type)) + "\"";
        json += ",\"codec\":\"" + JsonEscape(avcodec_get_name(par->codec_id)) + "\"";
        json += ",\"language\":\"" + JsonEscape(DictValue(stream->metadata, "language").c_str()) + "\"";
        json += ",\"title\":\"" + JsonEscape(DictValue(stream->metadata, "title").c_str()) + "\"";
        if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
            json += ",\"channels\":" + std::to_string(par->ch_layout.nb_channels);
            json += ",\"sampleRate\":" + std::to_string(par->sample_rate);
        }
        if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
            json += ",\"width\":" + std::to_string(par->width);
            json += ",\"height\":" + std::to_string(par->height);
            json += std::string(",\"hdr\":") + (IsHdr(par) ? "true" : "false");
            // AVColorTransferCharacteristic：16=SMPTE2084(PQ/HDR10)，18=ARIB_STD_B67(HLG)
            json += ",\"colorTrc\":" + std::to_string(static_cast<int>(par->color_trc));
        }
        json += "}";
    }
    json += "]";

    long long durationMs = 0;
    if (fmt->duration > 0) {
        durationMs = fmt->duration * 1000LL / AV_TIME_BASE;
    }
    std::string result = "{\"durationMs\":" + std::to_string(durationMs) + ",\"streams\":" + json + "}";

    avformat_close_input(&fmt);
    avformat_network_deinit();
    return result;
}

struct ProbeContext {
    std::string url;
    std::string result;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

void ExecuteProbe(napi_env env, void *data) {
    auto *ctx = static_cast<ProbeContext *>(data);
    if (ctx != nullptr) {
        ctx->result = DoProbe(ctx->url);
    }
}

void CompleteProbe(napi_env env, napi_status status, void *data) {
    auto *ctx = static_cast<ProbeContext *>(data);
    if (ctx == nullptr) {
        return;
    }
    napi_value value = nullptr;
    napi_create_string_utf8(env, ctx->result.c_str(), ctx->result.size(), &value);
    if (ctx->deferred != nullptr) {
        napi_resolve_deferred(env, ctx->deferred, value);
    }
    if (ctx->work != nullptr) {
        napi_delete_async_work(env, ctx->work);
    }
    delete ctx;
}

napi_value ProbeTracksAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);
    char url[8192] = {0};
    size_t urlLen = 0;
    if (argc < 1 ||
        napi_get_value_string_utf8(env, argv[0], url, sizeof(url) - 1, &urlLen) != napi_ok ||
        urlLen == 0) {
        napi_value empty = nullptr;
        napi_create_string_utf8(env, "", 0, &empty);
        napi_resolve_deferred(env, deferred, empty);
        return promise;
    }

    auto *ctx = new ProbeContext();
    ctx->url = std::string(url, urlLen);
    ctx->deferred = deferred;
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "probeTracksAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ExecuteProbe, CompleteProbe, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

/**
 * 给 XComponent 的 OHNativeWindow 配置 HDR 输出：
 *  - hdrType=1：BT2020 + HLG
 *  - hdrType=2：BT2020 + PQ（HDR10）
 * 返回 0 表示成功，非 0 为错误码。
 */
napi_value ConfigureHdrWindow(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value result = nullptr;
    if (argc < 2) {
        napi_create_int32(env, -1, &result);
        return result;
    }
    char idText[64] = {0};
    size_t idLen = 0;
    if (napi_get_value_string_utf8(env, argv[0], idText, sizeof(idText) - 1, &idLen) != napi_ok ||
        idLen == 0) {
        napi_create_int32(env, -1, &result);
        return result;
    }
    int32_t hdrType = 0;
    napi_get_value_int32(env, argv[1], &hdrType);
    if (hdrType <= 0) {
        napi_create_int32(env, 0, &result);
        return result;
    }

    uint64_t surfaceId = static_cast<uint64_t>(strtoull(idText, nullptr, 10));
    OHNativeWindow *window = nullptr;
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
    if (ret != 0 || window == nullptr) {
        napi_create_int32(env, ret == 0 ? -2 : ret, &result);
        return result;
    }
    OH_NativeBuffer_ColorSpace colorSpace = (hdrType == 1)
        ? OH_COLORSPACE_BT2020_HLG_FULL : OH_COLORSPACE_BT2020_PQ_FULL;
    int32_t csRet = OH_NativeWindow_SetColorSpace(window, colorSpace);

    OH_NativeBuffer_MetadataType metaType = (hdrType == 1)
        ? OH_VIDEO_HDR_HLG : OH_VIDEO_HDR_HDR10;
    int32_t mdRet = OH_NativeWindow_SetMetadataValue(window, OH_HDR_METADATA_TYPE,
        static_cast<int32_t>(sizeof(metaType)),
        reinterpret_cast<uint8_t *>(&metaType));

    OH_NativeWindow_DestroyNativeWindow(window);
    // 高 16 位返回色彩空间结果，低 16 位返回元数据结果，便于日志定位
    int32_t combined = (csRet << 16) | (mdRet & 0xFFFF);
    napi_create_int32(env, combined, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"probeTracksAsync", nullptr, ProbeTracksAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"configureHdrWindow", nullptr, ConfigureHdrWindow, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

static napi_module ffprobeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ffprobe",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterFfprobeModule(void) {
    napi_module_register(&ffprobeModule);
}
