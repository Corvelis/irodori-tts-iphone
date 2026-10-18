#import "ReazonSpeechBridge.h"
#import <SpeechCpp/speech.h>
#include <atomic>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" int stackchan_speech_metal_check(char *, size_t);
extern "C" void stackchan_speech_asr_set_pause_cpu(int);

namespace {
void checkASR(speech_status status) {
    if (status == SPEECH_CANCELLED) throw std::runtime_error("音声認識を停止しました。");
    if (status < 0) throw std::runtime_error(std::string(speech_status_name(status)) + ": " + speech_last_error());
}
void failASR(NSError **error, const std::exception &exception) {
    if (error) *error = [NSError errorWithDomain:@"ReazonSpeechCpp" code:1
        userInfo:@{NSLocalizedDescriptionKey: @(exception.what())}];
}
double asrMs(double start) { return (NSProcessInfo.processInfo.systemUptime - start) * 1000; }
int asrProgress(double, void *opaque) { return static_cast<std::atomic<bool> *>(opaque)->load() ? 1 : 0; }
}

@implementation ReazonSpeechBridge {
    speech_model *_model;
    NSString *_path;
    NSDictionary *_validation;
    NSDictionary *_information;
    bool _defaultCPU, _gpuGreedy;
    std::atomic<bool> _cancelled;
}
- (instancetype)init { if ((self = [super init])) _cancelled.store(false); return self; }
- (void)dealloc { [self releaseModel]; }
- (void)resetCancellation { _cancelled.store(false); }
- (void)cancel { _cancelled.store(true); }
- (void)releaseModel { speech_model_free(_model); _model = nullptr; _path = nil; _information = nil; }
- (NSDictionary *)prepareModel:(NSString *)path preferGpuGreedy:(BOOL)preferGpuGreedy error:(NSError **)error {
    speech_model_info *info = nullptr;
    speech_load_params *params = nullptr;
    try {
        if (_model && [_path isEqualToString:path]) return _information;
        [self releaseModel];
        const double start = NSProcessInfo.processInfo.systemUptime;
        checkASR(speech_model_info_open(path.UTF8String, &info));
        const bool valid = speech_model_info_task(info) == SPEECH_TASK_RECOGNITION &&
            std::string(speech_model_info_architecture(info)) == "fastconformer" &&
            [@(speech_model_info_name(info)).lowercaseString containsString:@"reazon"];
        speech_model_info_free(info); info = nullptr;
        if (!valid) throw std::runtime_error("ReazonSpeech NeMo v2のspeech.cpp用GGUFが必要です。");
        if (!_validation) {
            char report[1024]{};
            if (stackchan_speech_metal_check(report, sizeof(report)) != 0)
                throw std::runtime_error(std::string("ASR Metal validation failed: ") + report);
            _validation = [NSJSONSerialization JSONObjectWithData:[@(report) dataUsingEncoding:NSUTF8StringEncoding]
                                                        options:0 error:nil];
            if (!_validation) throw std::runtime_error("Invalid ASR Metal validation report");
        }
        const bool tensor = [_validation[@"tensorApi"] boolValue];
        checkASR(speech_load_params_new(&params));
        checkASR(speech_load_params_set_device(params, tensor ? "MTL1" : "gpu"));
        checkASR(speech_load_params_set_warmup(params, 0));
        checkASR(speech_model_load(path.UTF8String, params, &_model));
        speech_load_params_free(params); params = nullptr;
        checkASR(speech_model_get_info(_model, &info));
        NSString *device = @(speech_model_info_device(info));
        NSString *weights = @(speech_model_info_weight_type(info));
        int decodeCPU = 0;
        checkASR(speech_model_info_option_default_bool(info, SPEECH_OPT_DECODE_ON_CPU, &decodeCPU));
        _defaultCPU = decodeCPU != 0;
        _gpuGreedy = tensor && preferGpuGreedy;
        speech_model_info_free(info); info = nullptr;
        if (![device hasPrefix:@"MTL"]) throw std::runtime_error("ASRをMetalで準備できませんでした。");
        _path = [path copy];
        _information = @{@"device": device, @"weightType": weights,
            @"metalKernel": tensor ? @"Metal 4 tensor" : @"Metal simdgroup", @"loadMs": @(asrMs(start))};
        return _information;
    } catch (const std::exception &e) {
        speech_load_params_free(params); speech_model_info_free(info);
        [self releaseModel]; failASR(error, e); return nil;
    }
}
- (NSDictionary *)transcribe:(NSData *)pcm16 decoding:(NSString *)decoding error:(NSError **)error {
    speech_request *request = nullptr;
    try {
        if (!_model) throw std::runtime_error("先に音声認識モデルを準備してください。");
        if (!pcm16.length || pcm16.length % 2 || pcm16.length > 16000 * 2 * 60)
            throw std::runtime_error("音声は16 kHz・モノラルPCM16で60秒以内にしてください。");
        if (![decoding isEqualToString:@"greedy"] && ![decoding isEqualToString:@"beam"])
            throw std::runtime_error("認識方式はbeamまたはgreedyを選んでください。");
        // Pad both ends with 900 ms of silence before recognition.
        const size_t padding = 14400, count = pcm16.length / 2;
        std::vector<float> samples(count + padding * 2, 0.f);
        const uint8_t *bytes = (const uint8_t *)pcm16.bytes;
        for (size_t i = 0; i < count; ++i)
            samples[i + padding] = (int16_t)((uint16_t)bytes[i*2] | ((uint16_t)bytes[i*2+1] << 8)) / 32768.f;
        checkASR(speech_request_new(_model, &request));
        checkASR(speech_request_set_audio(request, samples.data(), samples.size(), 16000));
        checkASR(speech_request_set_string(request, SPEECH_OPT_DECODING, decoding.UTF8String));
        const bool cpu = _defaultCPU && !(_gpuGreedy && [decoding isEqualToString:@"greedy"]);
        checkASR(speech_request_set_bool(request, SPEECH_OPT_DECODE_ON_CPU, cpu ? 1 : 0));
        stackchan_speech_asr_set_pause_cpu(1);
        checkASR(speech_request_set_progress(request, asrProgress, &_cancelled));
        const double start = NSProcessInfo.processInfo.systemUptime;
        checkASR(speech_transcribe(request));
        const double elapsed = asrMs(start);
        if (_cancelled.load()) throw std::runtime_error("音声認識を停止しました。");
        NSString *text = @(speech_result_text(speech_request_result(request)));
        NSDictionary *result = @{@"text": text, @"inferenceMs": @(elapsed),
            @"decodeOnCpu": @(cpu), @"metalKernel": _information[@"metalKernel"]};
        speech_request_free(request);
        return result;
    } catch (const std::exception &e) { speech_request_free(request); failASR(error, e); return nil; }
}
@end
