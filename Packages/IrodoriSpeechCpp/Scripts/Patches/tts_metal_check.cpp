// Check partial Metal 4 tiles and broadcast batches used by Irodori's F16 model.
#include "backend.h"
#include "ggml.h"
#include "ggml-backend.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>

extern "C" bool stackchan_ggml_metal_has_tensor(ggml_backend_dev_t);

extern "C" __attribute__((visibility("default")))
int stackchan_speech_tts_metal_check(char *report, size_t capacity) {
    try {
        std::unique_ptr<ggml_backend, decltype(&ggml_backend_free)> gpu(
            init_backend("MTL1"), ggml_backend_free);
        const bool tensor = stackchan_ggml_metal_has_tensor(ggml_backend_get_device(gpu.get()));
        int cases = 0;
        double max_error = 0;
        if (tensor) {
            for (ggml_type type : {GGML_TYPE_F32, GGML_TYPE_F16}) {
                for (int m : {64, 192, 1024}) {
                    for (int n : {1, 12, 65, 132, 255, 576}) {
                        constexpr int k = 64, batch = 2;
                        ggml_init_params params{ggml_tensor_overhead() * 8 + ggml_graph_overhead(), nullptr, true};
                        std::unique_ptr<ggml_context, decltype(&ggml_free)> ctx(ggml_init(params), ggml_free);
                        auto *a = ggml_new_tensor_2d(ctx.get(), type, k, m);
                        auto *b = ggml_new_tensor_3d(ctx.get(), GGML_TYPE_F32, k, n, batch);
                        auto *c = ggml_mul_mat(ctx.get(), a, b);
                        auto *guard = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_F32, m * 128);
                        auto *graph = ggml_new_graph(ctx.get());
                        ggml_build_forward_expand(graph, c);
                        std::unique_ptr<ggml_backend_buffer, decltype(&ggml_backend_buffer_free)> buffer(
                            ggml_backend_alloc_ctx_tensors(ctx.get(), gpu.get()), ggml_backend_buffer_free);
                        if (!buffer || (char *)guard->data != (char *)c->data + ggml_nbytes(c))
                            throw std::runtime_error("TTS matrix-check sentinel allocation failed");
                        std::vector<float> av(k * m), bv(k * n * batch), dequant(k * m), sentinel(m * 128, 12345.0f);
                        for (size_t i = 0; i < av.size(); ++i) av[i] = ((int)(i % 31) - 15) / 32.0f;
                        for (size_t i = 0; i < bv.size(); ++i) bv[i] = ((int)(i % 23) - 11) / 32.0f;
                        std::vector<unsigned char> weights(ggml_nbytes(a));
                        if (type == GGML_TYPE_F32) {
                            std::memcpy(weights.data(), av.data(), weights.size());
                            dequant = av;
                        } else {
                            ggml_quantize_chunk(type, av.data(), weights.data(), 0, m, k, nullptr);
                            ggml_get_type_traits(type)->to_float(weights.data(), dequant.data(), k * m);
                        }
                        ggml_backend_tensor_set(a, weights.data(), 0, weights.size());
                        ggml_backend_tensor_set(b, bv.data(), 0, ggml_nbytes(b));
                        ggml_backend_tensor_set(guard, sentinel.data(), 0, ggml_nbytes(guard));
                        if (ggml_backend_graph_compute(gpu.get(), graph) != GGML_STATUS_SUCCESS)
                            throw std::runtime_error("TTS matrix-check compute failed");
                        ggml_backend_synchronize(gpu.get());
                        std::vector<float> result(m * n * batch), observed(sentinel.size());
                        ggml_backend_tensor_get(c, result.data(), 0, ggml_nbytes(c));
                        ggml_backend_tensor_get(guard, observed.data(), 0, ggml_nbytes(guard));
                        if (observed != sentinel)
                            throw std::runtime_error("TTS Metal matrix product wrote beyond its output");
                        for (int col = 0; col < n * batch; ++col) {
                            for (int row = 0; row < m; ++row) {
                                double expected = 0;
                                for (int j = 0; j < k; ++j)
                                    expected += dequant[row * k + j] * bv[col * k + j];
                                const float value = result[col * m + row];
                                const double error = std::abs(value - expected);
                                if (!std::isfinite(value) || error > 0.02 + std::abs(expected) * 0.002)
                                    throw std::runtime_error("TTS Metal matrix product differs from its CPU reference");
                                max_error = std::max(max_error, error);
                            }
                        }
                        ++cases;
                    }
                }
            }
        }
        std::snprintf(report, capacity,
            "{\"tensorApi\":%s,\"matrixCases\":%d,\"maxAbsError\":%.9g,\"sentinelIntact\":true}",
            tensor ? "true" : "false", cases, max_error);
        return 0;
    } catch (const std::exception &e) {
        std::snprintf(report, capacity, "%s", e.what());
        return -1;
    }
}
