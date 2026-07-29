const fs = require("fs");
const path = require("path");

const electronDist = path.resolve(__dirname, "..", "node_modules", "electron", "dist");
const out = path.resolve(__dirname, "..", "dist", "GestionnaireSP");
const appDir = path.resolve(out, "resources", "app");

// clean
if (fs.existsSync(out)) fs.rmSync(out, { recursive: true });

// electron binaries
const files = [
  "electron.exe", "d3dcompiler_47.dll", "ffmpeg.dll", "libEGL.dll",
  "libGLESv2.dll", "vk_swiftshader.dll", "vulkan-1.dll",
  "icudtl.dat", "resources.pak", "snapshot_blob.bin", "v8_context_snapshot.bin",
  "chrome_100_percent.pak", "chrome_200_percent.pak",
  "LICENSE", "LICENSES.chromium.html",
];

fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(appDir, { recursive: true });

for (const f of files) {
  const src = path.join(electronDist, f);
  if (fs.existsSync(src)) fs.copyFileSync(src, path.join(out, f));
}

// locales
const locales = path.join(electronDist, "locales");
if (fs.existsSync(locales)) {
  fs.cpSync(locales, path.join(out, "locales"), { recursive: true });
}

// default resources
const resources = path.join(electronDist, "resources");
if (fs.existsSync(resources)) {
  fs.cpSync(resources, path.join(out, "resources"), { recursive: true });
}

// app files
const appFiles = ["main.js", "preload.js", "package.json"];
const appRenderDir = path.resolve(__dirname, "..", "renderer");

for (const f of appFiles) {
  fs.copyFileSync(path.resolve(__dirname, "..", f), path.join(appDir, f));
}
fs.cpSync(appRenderDir, path.join(appDir, "renderer"), { recursive: true });

// icon
const iconSrc = path.resolve(__dirname, "..", "..", "logo.png");
if (fs.existsSync(iconSrc)) fs.copyFileSync(iconSrc, path.join(out, "logo.png"));

console.log("Build created at:", out);
console.log("Size:", fs.statSync(path.join(out, "GestionnaireSP.exe")).size, "bytes");
