#include <flutter/runtime_effect.glsl>

// Mono-glitch slice-tear filter for the Sonnet (商籁) stage
// (sonnetGlitchFilter.ts): the frame is cut into 14 coarse bands
// and 58 fine bands; a band is displaced when a hash of its index
// passes a threshold (coarse 0.58 → shift ×0.1 of the width, fine
// 0.88 → ×0.037), and torn bands get a ×0.42 brightness cut.
// There is no RGB dispersion: the frame is monochrome during the
// glitch (the blueprint uses a single-channel displacement).

uniform vec2 uSize; // set by the engine to the bound texture size
uniform float uAmount; // 0..1 glitch progress within the boundary
uniform float uSeed; // deterministic seed for the boundary
uniform sampler2D uTexture;

out vec4 fragColor;

float hash1(float n) {
  return fract(sin(n) * 43758.5453123);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  float offset = 0.0;
  float brightness = 1.0;

  float coarseBand = floor(uv.y * 14.0);
  float coarseRandom = hash1(uSeed + coarseBand * 0.173);
  if (coarseRandom > 0.58) {
    float direction = hash1(coarseBand * 7.13) > 0.5 ? 1.0 : -1.0;
    offset += direction * (0.03 + hash1(coarseBand * 1.7) * 0.07);
  }

  float fineBand = floor(uv.y * 58.0);
  float fineRandom = hash1(uSeed + fineBand * 0.311);
  if (fineRandom > 0.88) {
    float direction = hash1(fineBand * 5.19) > 0.5 ? 1.0 : -1.0;
    offset += direction * (0.01 + hash1(fineBand * 2.3) * 0.027);
  }

  float tearRandom = hash1(uSeed + floor(uv.y * 14.0) * 0.913);
  if (tearRandom > 0.58) {
    brightness = 0.58;
  }

  vec2 sampleUv = vec2(uv.x + offset * uAmount, uv.y);
  vec4 color = texture(uTexture, sampleUv);
  float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));
  vec4 grayColor = vec4(vec3(gray), color.a);
  vec4 mixed = mix(color, grayColor, uAmount);
  fragColor = vec4(mixed.rgb * brightness, mixed.a);
}
