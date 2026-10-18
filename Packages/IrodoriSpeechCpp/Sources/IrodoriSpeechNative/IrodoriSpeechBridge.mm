#import "IrodoriSpeechBridge.h"
#import <SpeechCpp/speech.h>
#import <SpeechCpp/SpeechCppBuild.h>
#include <algorithm>
#include <cstdio>
#include <atomic>
#include <cmath>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" int stackchan_speech_tts_metal_check(char *, size_t);
extern "C" void stackchan_speech_tts_set_decoder_window(int);
extern "C" int stackchan_speech_tts_stats(char *, size_t);

namespace {
void check(speech_status status) {
    if (status < 0) throw std::runtime_error(std::string(speech_status_name(status)) + ": " + speech_last_error());
}
void fail(NSError **error, const std::exception &exception) {
    if (error) *error = [NSError errorWithDomain:@"IrodoriSpeechCpp" code:1
        userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
}
double ms(double start) { return (NSProcessInfo.processInfo.systemUptime - start) * 1000; }
struct Sink {
    std::vector<int16_t> pcm;
    std::atomic<bool> *cancelled;
    double start, first = -1;
    void (^onPcm)(NSData *);
    bool invalid = false;
};
int audio(const float *samples, size_t count, void *opaque) {
    auto &sink = *static_cast<Sink *>(opaque);
    if (sink.cancelled->load()) return 1;
    if (sink.first < 0) sink.first = ms(sink.start);
    const size_t offset = sink.pcm.size();
    sink.pcm.resize(offset + count);
    for (size_t i = 0; i < count; ++i) {
        if (!std::isfinite(samples[i])) { sink.invalid = true; return 1; }
        sink.pcm[offset + i] = (int16_t)std::lrint(std::clamp(samples[i], -1.f, 1.f) * 32767.f);
    }
    if (sink.onPcm) sink.onPcm([NSData dataWithBytes:sink.pcm.data()+offset length:count*2]);
    return 0;
}
int progress(double, void *opaque) { return static_cast<std::atomic<bool> *>(opaque)->load() ? 1 : 0; }
}

@implementation IrodoriSpeechBridge {
    speech_model *_model;
    NSString *_path;
    NSString *_reference;
    NSString *_voice;
    bool _tensor;
    NSDictionary *_validation;
    NSDictionary *_information;
    std::atomic<bool> _cancelled;
    NSUInteger _voiceIndex;
}
- (instancetype)init { if ((self = [super init])) _cancelled.store(false); return self; }
- (void)dealloc { [self releaseModel]; }
- (void)resetCancellation { _cancelled.store(false); }
- (void)cancel { _cancelled.store(true); }
- (void)releaseModel {
    speech_model_free(_model); _model = nullptr;
    _path = nil; _reference = nil; _voice = @"none"; _information = nil; _voiceIndex = 0;
}
- (NSDictionary *)prepareModel:(NSString *)path metal4:(BOOL)metal4 error:(NSError **)error {
    try {
        const double started = NSProcessInfo.processInfo.systemUptime;
        bool tensor = false;
        if (metal4) {
            if (!_validation) {
                char report[1024]{};
                if (stackchan_speech_tts_metal_check(report, sizeof(report)) != 0)
                    throw std::runtime_error(std::string("Metal validation failed: ") + report);
                _validation = [NSJSONSerialization JSONObjectWithData:[@(report) dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0 error:nil];
                if (!_validation) throw std::runtime_error("Invalid Metal validation report");
            }
            tensor = [_validation[@"tensorApi"] boolValue];
        }
        if (_model && [_path isEqualToString:path] && _tensor == tensor) return _information;
        [self releaseModel];
        speech_model_info *info = nullptr;
        check(speech_model_info_open(path.UTF8String, &info));
        bool supported = std::string(speech_model_info_architecture(info)) == "irodori-tts" &&
            std::string(speech_model_info_finetune(info)) == "MF" &&
            std::string(speech_model_info_version(info)) == "v4.1" && speech_model_info_sample_rate(info) == 48000;
        speech_model_info_free(info);
        if (!supported) throw std::runtime_error("Irodori v4.1 Small MF GGUF is required");
        speech_load_params *params = nullptr;
        check(speech_load_params_new(&params));
        try {
            check(speech_load_params_set_device(params, tensor ? "MTL1" : "gpu"));
            check(speech_model_load(path.UTF8String, params, &_model));
        } catch (...) { speech_load_params_free(params); throw; }
        speech_load_params_free(params);
        check(speech_model_get_info(_model, &info));
        NSString *device = @(speech_model_info_device(info));
        speech_model_info_free(info);
        if (![device hasPrefix:@"MTL"]) throw std::runtime_error("Metal is required");
        _path = [path copy]; _tensor = tensor;
        _information = @{@"device": device, @"metalKernel": tensor ? @"Metal 4 tensor" : @"Metal simdgroup",
            @"runtimeVersion": @(speech_version()), @"runtimeRevision": @STACKCHAN_SPEECH_REVISION,
            @"ggmlRevision": @STACKCHAN_SPEECH_GGML_REVISION, @"loadMs": @(ms(started))};
        return _information;
    } catch (const std::exception &e) { [self releaseModel]; fail(error, e); return nil; }
}
- (BOOL)registerReference:(NSString *)path error:(NSError **)error {
    try {
        if (!_model) throw std::runtime_error("Prepare a model first");
        if (!path.length) { _voice = @"none"; _reference = nil; return YES; }
        if ([_reference isEqualToString:path]) return YES;
        // The sample uses immutable UUID filenames for reference recordings.
        NSString *name = [NSString stringWithFormat:@"reference_%lu", (unsigned long)++_voiceIndex];
        check(speech_voice_add(_model, name.UTF8String, path.UTF8String));
        _voice = name; _reference = [path copy];
        return YES;
    } catch (const std::exception &e) { fail(error, e); return NO; }
}
- (NSDictionary *)synthesize:(NSString *)text caption:(NSString *)caption seed:(uint32_t)seed onPcm:(void (^)(NSData *))onPcm error:(NSError **)error {
    speech_request *request = nullptr;
    try {
        if (!_model) throw std::runtime_error("Prepare a model first");
        check(speech_request_new(_model, &request));
        check(speech_request_set_text(request, text.UTF8String));
        check(speech_request_set_string(request, SPEECH_OPT_VOICE, (_voice ?: @"none").UTF8String));
        check(speech_request_set_string(request, SPEECH_OPT_INSTRUCTIONS, caption.UTF8String));
        check(speech_request_set_int(request, SPEECH_OPT_SEED, seed));
        check(speech_request_set_int(request, SPEECH_OPT_STEPS, 4));
        check(speech_request_set_progress(request, progress, &_cancelled));
        stackchan_speech_tts_set_decoder_window(_tensor ? 128 : 0);
        Sink sink{{}, &_cancelled, NSProcessInfo.processInfo.systemUptime, -1, onPcm};
        const speech_status status = speech_synthesize(request, audio, &sink);
        if (status == SPEECH_CANCELLED) throw std::runtime_error("Synthesis cancelled");
        check(status);
        if (sink.invalid || sink.pcm.empty()) throw std::runtime_error("No valid audio returned");
        char report[1024]{};
        NSDictionary *stages = @{};
        if (stackchan_speech_tts_stats(report, sizeof(report)) == 0)
            stages = [NSJSONSerialization JSONObjectWithData:[@(report) dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0 error:nil] ?: @{};
        NSMutableDictionary *metrics = [stages mutableCopy];
        metrics[@"generationSeed"] = @(speech_result_seed(speech_request_result(request)));
        NSDictionary *result = @{@"pcm16": [NSData dataWithBytes:sink.pcm.data() length:sink.pcm.size()*2],
            @"firstPcmMs": @(sink.first), @"synthesisMs": @(ms(sink.start)), @"metrics": metrics};
        speech_request_free(request);
        return result;
    } catch (const std::exception &e) { speech_request_free(request); fail(error, e); return nil; }
}
@end
