// Test-only import seam: production always imports the concrete high-level
// operation. This loader redirects only that one public boundary in a child.
export async function resolve(specifier, context, nextResolve) {
  if (specifier.endsWith("/fixed-debian-maintenance-host-operation.mjs") ||
      specifier === "./fixed-debian-maintenance-host-operation.mjs" ||
      specifier === "./lib/fixed-debian-maintenance-host-operation.mjs") {
    return {
      url: new URL("./fixed-host-operation.mjs", import.meta.url).href,
      shortCircuit: true,
    };
  }
  return nextResolve(specifier, context);
}
