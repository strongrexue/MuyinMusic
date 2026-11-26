/*
 * PanghuMusic iOS —— 均衡器 biquad 级联。
 *
 * 为什么不用 BASS_FX：
 *   Android 端用 BASS_FX 的 BASS_BFX_BQF 实现均衡器，但 un4seen 并未提供
 *   BASS_FX 的 iOS 包。这里用 BASS 的自定义 DSP（BASS_ChannelSetDSP）自己实现
 *   同等语义的 biquad 级联，参数（滤波器类型 / 频率 / 增益 / Q）与 Dart 侧
 *   BassEqualizerBand 一一对应，因此 lib/ 不需要任何改动。
 *
 * 系数采用 RBJ Audio EQ Cookbook 公式，与 BASS_FX 的 BQF 实现同源。
 */

#ifndef PANGHU_BIQUAD_H
#define PANGHU_BIQUAD_H

#ifdef __cplusplus
extern "C" {
#endif

/* 与 Dart 侧 BassBiquadFilter 枚举顺序保持一致。 */
typedef enum {
    PANGHU_FILTER_PEAKING = 0,
    PANGHU_FILTER_LOW_SHELF = 1,
    PANGHU_FILTER_HIGH_SHELF = 2,
    PANGHU_FILTER_LOW_PASS = 3,
    PANGHU_FILTER_HIGH_PASS = 4
} PanghuFilterType;

typedef struct {
    int type;         /* PanghuFilterType */
    double frequencyHz;
    double gainDb;
    double q;
} PanghuBiquadBand;

typedef struct PanghuBiquadChain PanghuBiquadChain;

/* 至少能容纳 Dart 侧允许的 32 段。 */
#define PANGHU_MAX_BIQUAD_BANDS 32

PanghuBiquadChain *panghu_biquad_chain_create(double sampleRate);
void panghu_biquad_chain_destroy(PanghuBiquadChain *chain);

/*
 * 线程安全：可从任意线程调用。新配置先暂存，由音频线程在下一个 DSP 回调里
 * 生效，避免在音频线程做浮点运算以外的重活。
 */
void panghu_biquad_chain_configure(PanghuBiquadChain *chain,
                                    double inputGainDb,
                                    double outputGainDb,
                                    const PanghuBiquadBand *bands,
                                    int bandCount);

/* 清空滤波器历史，用于 seek / 换曲后避免残留尾音。 */
void panghu_biquad_chain_reset(PanghuBiquadChain *chain);

/* 就地处理交错（interleaved）float32 采样。 */
void panghu_biquad_chain_process(PanghuBiquadChain *chain,
                                  float *buffer,
                                  unsigned long frames,
                                  unsigned int channels);

#ifdef __cplusplus
}
#endif

#endif /* PANGHU_BIQUAD_H */
