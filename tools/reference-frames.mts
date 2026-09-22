/**
 * Renders the CanvasKit reference frame for every demo document,
 * so the Metal backend can be differenced against the renderer everyone
 * already trusts — the same comparison `renderers.md` reports for WebGL.
 *
 * One directory per case under `packages/ios/.reference/`:
 *
 *   document.json     the document, as the core will parse it
 *   meta.json         tick, output size, render scale, font/image manifests
 *   reference.rgba    unpremultiplied RGBA8, row-major, `width * height * 4`
 *   reference.png     the same pixels, for eyes
 *   fonts/<id>        font bytes the document carries (`_fallback` is `*`)
 *   images/<id>       encoded image bytes, by asset id
 *
 * Run from packages/animation-engine, which owns the CanvasKit dependency:
 *   npx tsx ../ios/tools/reference-frames.mts [--width 480] [--ticks 3]
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { loadCanvasKitNode } from "../../animation-engine/src/renderer/loader";
import { drawAnimationFrame } from "../../animation-engine/src/renderer/render";
import { RendererResourceContext } from "../../animation-engine/src/renderer/resources";
import { compileRenderPlan } from "../../animation-engine/src/render-plan";
import { isClayzoBundle, readClayzoBundle } from "../../animation-engine/src/bundle";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..", "..");
const outRoot = join(here, "..", ".reference");

const args = process.argv.slice(2);
const option = (name: string, fallback: number): number => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? Number(args[index + 1]) : fallback;
};
const maxWidth = option("width", 480);
const tickCount = option("ticks", 3);
const only = args.find((value) => !value.startsWith("--") && Number.isNaN(Number(value)));

async function loadAssetBytes(asset: any, bundleLoader: any): Promise<Uint8Array | undefined> {
  if (asset === undefined) return undefined;
  if (bundleLoader !== undefined) {
    const bytes = await bundleLoader(asset);
    if (bytes instanceof Uint8Array) return bytes;
  }
  const uri: string | undefined = asset.uri;
  if (typeof uri === "string" && uri.startsWith("data:")) {
    const comma = uri.indexOf(",");
    if (comma > 0) return new Uint8Array(Buffer.from(uri.slice(comma + 1), "base64"));
  }
  return undefined;
}

async function main(): Promise<void> {
  const canvasKit = await loadCanvasKitNode();
  const fallbackPath = join(repoRoot, "packages", "animation-engine", "fonts", "Manrope-wght.ttf");
  const fallbackBytes = existsSync(fallbackPath) ? new Uint8Array(readFileSync(fallbackPath)) : undefined;

  const documents: { name: string; document: any; bundleLoader?: any }[] = [];
  for (const directory of [join(repoRoot, "apps", "studio", "public", "demo")]) {
    if (!existsSync(directory)) continue;
    for (const file of readdirSync(directory).sort()) {
      if (!/\.(json|clayzo)$/.test(file) || file.endsWith(".states.json")) continue;
      const bytes = new Uint8Array(readFileSync(join(directory, file)));
      const bundle = isClayzoBundle(bytes) ? await readClayzoBundle(bytes) : undefined;
      const document = bundle ? bundle.document : JSON.parse(new TextDecoder().decode(bytes));
      if (document?.compositions === undefined) continue;
      const name = `${basename(directory)}-${file.replace(/\.(json|clayzo)$/, "")}`;
      if (only !== undefined && !name.includes(only)) continue;
      documents.push({ name, document, bundleLoader: bundle?.imageAssetLoader });
    }
  }

  for (const { name, document, bundleLoader } of documents) {
    const duration = Number(document.timing?.durationTicks ?? 1);
    const ticks = Array.from({ length: tickCount }, (_, index) =>
      Math.trunc((duration * (index + 1)) / (tickCount + 1)),
    );
    for (const tick of ticks) {
      const caseName = `${name}@${tick}`;
      const out = join(outRoot, caseName);
      rmSync(out, { recursive: true, force: true });
      mkdirSync(join(out, "fonts"), { recursive: true });
      mkdirSync(join(out, "images"), { recursive: true });

      const plan = compileRenderPlan(document, tick);
      const width = Math.min(maxWidth, plan.width);
      const height = Math.round((width / plan.width) * plan.height);
      const scale = width / plan.width;

      const fonts: Record<string, string> = {};
      const images: Record<string, string> = {};
      for (const [assetId, asset] of Object.entries<any>(document.assets ?? {})) {
        const bytes = await loadAssetBytes(asset, bundleLoader);
        if (bytes === undefined) continue;
        if (asset?.type === "font") {
          writeFileSync(join(out, "fonts", assetId), bytes);
          fonts[assetId] = assetId;
        } else if (asset?.type === "image") {
          writeFileSync(join(out, "images", assetId), bytes);
          images[assetId] = assetId;
        }
      }
      if (fallbackBytes) {
        writeFileSync(join(out, "fonts", "_fallback"), fallbackBytes);
        fonts["*"] = "_fallback";
      }

      const surface = canvasKit.MakeSurface(width, height)!;
      const context = new RendererResourceContext();
      const started = performance.now();
      await drawAnimationFrame(document, tick, {
        canvasKit,
        surface,
        resourceContext: context,
        resolution: { type: "exact", width, height },
        background: { type: "solid" },
        imageAssetLoader: (asset: any) => loadAssetBytes(asset, bundleLoader),
        fontAssetLoader: (asset: any) => loadAssetBytes(asset, bundleLoader),
        familyFontLoader: () => fallbackBytes,
        // The static-picture cache drops a clip group nested inside another
        // (renderer-coverage's clip-b renders as nothing with it on, and as
        // the expected pill with it off). The reference has to be what the
        // renderer means, not what that cache loses.
        acceleration: { staticPictures: false },
      } as never);
      const elapsed = performance.now() - started;
      const snapshot = surface.makeImageSnapshot();
      const pixels = snapshot.readPixels(0, 0, {
        alphaType: canvasKit.AlphaType.Unpremul,
        colorType: canvasKit.ColorType.RGBA_8888,
        colorSpace: canvasKit.ColorSpace.SRGB,
        width,
        height,
      }) as Uint8Array;
      writeFileSync(join(out, "reference.rgba"), pixels);
      writeFileSync(join(out, "reference.png"), snapshot.encodeToBytes(canvasKit.ImageFormat.PNG, 100)!);
      snapshot.delete();
      surface.delete();
      context.dispose?.();

      writeFileSync(join(out, "document.json"), JSON.stringify(document));
      writeFileSync(
        join(out, "meta.json"),
        JSON.stringify({ name, tick, width, height, scale, fonts, images, effects: plan.nodes ? undefined : undefined }, null, 2),
      );
      console.log(`  ${caseName.padEnd(48)} ${width}x${height}  ${elapsed.toFixed(0)} ms`);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
