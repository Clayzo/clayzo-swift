import Foundation

/// SkSL for every built-in runtime effect, keyed by effect kind. Copied from
/// the CanvasKit renderer's `effects.ts` verbatim — the same source runs on
/// every backend, so a change there is a change here.
let builtinEffectSources: [String: String] = [
  "dithering": #"""
uniform shader inputImage;
uniform float amount;
uniform float levels;
uniform float scale;
uniform float2 focus;
uniform float focusRadius;
uniform float focusScale;
uniform float focusAmount;
float bayer4(float2 p, float cell) {
  float x = mod(floor(p.x / max(cell, 1.0)), 4.0);
  float y = mod(floor(p.y / max(cell, 1.0)), 4.0);
  if (y < 1.0) {
    if (x < 1.0) return 0.0 / 16.0;
    if (x < 2.0) return 8.0 / 16.0;
    if (x < 3.0) return 2.0 / 16.0;
    return 10.0 / 16.0;
  }
  if (y < 2.0) {
    if (x < 1.0) return 12.0 / 16.0;
    if (x < 2.0) return 4.0 / 16.0;
    if (x < 3.0) return 14.0 / 16.0;
    return 6.0 / 16.0;
  }
  if (y < 3.0) {
    if (x < 1.0) return 3.0 / 16.0;
    if (x < 2.0) return 11.0 / 16.0;
    if (x < 3.0) return 1.0 / 16.0;
    return 9.0 / 16.0;
  }
  if (x < 1.0) return 15.0 / 16.0;
  if (x < 2.0) return 7.0 / 16.0;
  if (x < 3.0) return 13.0 / 16.0;
  return 5.0 / 16.0;
}
half4 main(float2 p) {
  half4 source = inputImage.eval(p);
  float count = max(2.0, levels);
  // A radius of zero leaves the field perfectly uniform, so a document that
  // never sets a focus dithers exactly as it did before this existed.
  float falloff = focusRadius <= 0.0
    ? 0.0
    : 1.0 - smoothstep(0.0, 1.0, clamp(distance(p, focus) / focusRadius, 0.0, 1.0));
  // Quantised: a continuously varying cell size beats the Bayer grid against
  // itself and the falloff reads as moire rings. Whole-pixel steps turn the
  // same ramp into concentric bands of resolution, which is the intent.
  float cell = max(1.0, floor(scale * mix(1.0, focusScale, falloff) + 0.5));
  float localAmount = clamp(amount + focusAmount * falloff, 0.0, 1.0);
  float threshold = bayer4(p, cell) - 0.5;
  float3 changed = floor(clamp(float3(source.rgb) + threshold * localAmount, 0.0, 1.0) * (count - 1.0) + 0.5) / (count - 1.0);
  return half4(changed, source.a);
}
"""#,
  "duotone": #"""
uniform shader inputImage;
uniform float4 shadowColor;
uniform float4 highlightColor;
uniform float threshold;
uniform float contrast;
half4 main(float2 p) {
  half4 source = inputImage.eval(p);
  float luminance = dot(float3(source.rgb), float3(0.2126, 0.7152, 0.0722));
  float mixValue = clamp((luminance - threshold) * contrast + 0.5, 0.0, 1.0);
  float4 mapped = mix(shadowColor, highlightColor, mixValue);
  return half4(mapped.rgb, source.a * mapped.a);
}
"""#,
  "pixelation": #"""
uniform shader inputImage;
uniform float cellSize;
half4 main(float2 p) {
  float size = max(1.0, cellSize);
  float2 samplePoint = floor(p / size) * size + float2(size * 0.5);
  return inputImage.eval(samplePoint);
}
"""#,
  "mesh-gradient": #"""
uniform shader inputImage;
uniform float2 point0;
uniform float2 point1;
uniform float2 point2;
uniform float2 point3;
uniform float4 color0;
uniform float4 color1;
uniform float4 color2;
uniform float4 color3;
uniform float time;
uniform float phase;
float weight(float2 p, float2 center) {
  float distanceSquared = dot(p - center, p - center);
  return 1.0 / max(1.0, distanceSquared);
}
half4 main(float2 p) {
  half4 source = inputImage.eval(p);
  float2 wave = float2(sin(time + phase), cos(time * 0.73 + phase)) * 8.0;
  float w0 = weight(p, point0 + wave);
  float w1 = weight(p, point1 + float2(-wave.y, wave.x));
  float w2 = weight(p, point2 - wave);
  float w3 = weight(p, point3 + float2(wave.y, -wave.x));
  float total = w0 + w1 + w2 + w3;
  float4 field = (color0 * w0 + color1 * w1 + color2 * w2 + color3 * w3) / total;
  return half4(field.rgb, source.a * field.a);
}
"""#,
  "refraction": #"""
uniform shader inputImage;
uniform shader backdropImage;
uniform float2 center;
uniform float strength;
uniform float radius;
uniform float chromatic;
uniform float noiseScale;
uniform float time;
uniform float2 origin;
half4 main(float2 p) {
  half4 maskSample = inputImage.eval(p);
  float2 globalP = p + origin;
  float2 delta = globalP - center;
  float distanceValue = length(delta);
  float falloff = clamp(1.0 - distanceValue / max(radius, 1.0), 0.0, 1.0);
  float2 direction = distanceValue > 0.001 ? delta / distanceValue : float2(0.0);
  float noise = sin((globalP.x + time * 17.0) * noiseScale) * cos((globalP.y - time * 11.0) * noiseScale);
  float2 displacement = direction * strength * falloff * falloff + float2(noise) * strength * 0.08;
  half4 base = backdropImage.eval(p + displacement);
  half red = backdropImage.eval(p + displacement * (1.0 + chromatic)).r;
  half blue = backdropImage.eval(p + displacement * (1.0 - chromatic)).b;
  return half4(half3(red, base.g, blue) * maskSample.a, maskSample.a);
}
"""#,
  "glass": #"""
uniform shader inputImage;
uniform shader backdropImage;
uniform float blurRadius;
uniform float4 tint;
uniform float refractionStrength;
uniform float chromatic;
uniform float fresnel;
uniform float roughness;
uniform float ior;
uniform float thickness;
uniform float specular;
uniform float time;
uniform float deviceScale;
uniform float2 origin;
float2 maskGradient(float2 p, float span) {
  return float2(
    inputImage.eval(p + float2(span, 0.0)).a - inputImage.eval(p - float2(span, 0.0)).a,
    inputImage.eval(p + float2(0.0, span)).a - inputImage.eval(p - float2(0.0, span)).a
  );
}
half4 main(float2 p) {
  half4 maskSample = inputImage.eval(p);
  // The edge detector reads the mask at one, eight and eighteen *composition*
  // units, converted to device pixels here and floored at three quarters of a
  // texel because nothing useful is sampled below one. Writing the multipliers
  // in device pixels instead — which is what `sampleStep * 8.0` did — made the
  // wide taps grow relative to the artwork as the render shrank: at a tenth
  // scale they reached two hundred composition units across, which finds no
  // edge at all and smears alpha over the whole panel. That is a glass card
  // with its rim missing and a haze in its place.
  //
  // At scale 1 every term below is what it was.
  float unit = max(0.75, deviceScale);
  float2 alphaGradient =
    maskGradient(p, unit) * 0.42 +
    maskGradient(p, max(unit, 8.0 * deviceScale)) * 0.38 +
    maskGradient(p, max(unit, 18.0 * deviceScale)) * 0.20;
  float3 normal = normalize(float3(-alphaGradient * max(0.01, thickness), 1.0));
  float eta = 1.0 / max(1.001, ior);
  float bend = (1.0 - eta) * max(0.0, thickness);
  float2 globalP = p + origin;
  float noise = sin((globalP.x + time * 4.0) * 0.022) * cos((globalP.y - time * 3.0) * 0.019);
  float2 displacement =
    normal.xy * refractionStrength * bend +
    float2(noise, -noise) * refractionStrength * roughness * 0.04;
  float stepSize = max(0.5, blurRadius * mix(0.18, 0.72, roughness));
  half4 blurred = half4(0.0);
  blurred += backdropImage.eval(p + displacement) * 0.20;
  blurred += backdropImage.eval(p + displacement + float2(stepSize, 0.0)) * 0.10;
  blurred += backdropImage.eval(p + displacement - float2(stepSize, 0.0)) * 0.10;
  blurred += backdropImage.eval(p + displacement + float2(0.0, stepSize)) * 0.10;
  blurred += backdropImage.eval(p + displacement - float2(0.0, stepSize)) * 0.10;
  blurred += backdropImage.eval(p + displacement + float2(stepSize, stepSize)) * 0.075;
  blurred += backdropImage.eval(p + displacement + float2(-stepSize, stepSize)) * 0.075;
  blurred += backdropImage.eval(p + displacement + float2(stepSize, -stepSize)) * 0.075;
  blurred += backdropImage.eval(p + displacement - float2(stepSize, stepSize)) * 0.075;
  float outerStep = stepSize * 1.8;
  blurred += backdropImage.eval(p + displacement + float2(outerStep, 0.0)) * 0.025;
  blurred += backdropImage.eval(p + displacement - float2(outerStep, 0.0)) * 0.025;
  blurred += backdropImage.eval(p + displacement + float2(0.0, outerStep)) * 0.025;
  blurred += backdropImage.eval(p + displacement - float2(0.0, outerStep)) * 0.025;
  half red = backdropImage.eval(p + displacement * (1.0 + chromatic)).r;
  half blue = backdropImage.eval(p + displacement * (1.0 - chromatic)).b;
  blurred.r = red;
  blurred.b = blue;
  // Normalised by the spacing the gradient was actually measured over, not by
  // the device scale. The two agree at scale 1; below it the taps stop
  // shrinking — they cannot go under a texel — so scaling by `deviceScale`
  // divided the rim's brightness by the very factor that stopped applying.
  half edge = clamp(length(alphaGradient) / unit, 0.0, 1.0);
  float3 viewDirection = float3(0.0, 0.0, 1.0);
  float3 lightDirection = normalize(float3(-0.35, -0.45, 0.82));
  float fresnelTerm =
    0.04 + (1.0 - 0.04) * pow(1.0 - max(0.0, dot(normal, viewDirection)), 5.0);
  float highlight = pow(
    max(0.0, dot(normal, lightDirection)),
    mix(64.0, 8.0, roughness)
  ) * specular;
  // Composite the pane over the backdrop rather than returning the mask's
  // alpha outright. Where the backdrop is opaque the two are the same
  // expression: the backdrop sample is premultiplied, so this reduces to the
  // old mix and an alpha of one. Where it is empty they are not: returning the
  // mask's alpha there composited a fully opaque pane whose colour came from a
  // backdrop that was not present, which is a black slab. A pane over nothing
  // should be nearly clear, carrying only its own tint and highlights.
  half3 lit = half3(tint.rgb) * half(tint.a)
    + half3(edge * fresnel + fresnelTerm * fresnel + highlight);
  half3 colored = blurred.rgb * (1.0 - half(tint.a)) + lit;
  half pane = clamp(
    half(tint.a) + half(edge * fresnel + fresnelTerm * fresnel + highlight),
    0.0,
    1.0
  );
  half covered = blurred.a + pane * (1.0 - blurred.a);
  return half4(colored * maskSample.a, covered * maskSample.a);
}
"""#,
]
