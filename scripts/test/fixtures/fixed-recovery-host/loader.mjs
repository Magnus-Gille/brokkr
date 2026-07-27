// Test-only import seam: production always imports the concrete fixed host.
// This loader redirects exactly that one module in a child Node process.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "./fixed-bounded-recovery-host.mjs" &&
    context.parentURL.endsWith("/scripts/lib/bounded-recovery-dispatch.mjs")) {
    return { url: new URL("./fixed-recovery-host.mjs", import.meta.url).href, shortCircuit: true };
  }
  if (specifier === "./lib/fixed-debian-maintenance-host-dependencies.mjs" &&
    context.parentURL.endsWith("/scripts/debian-maintenance-host-adapter.mjs")) {
    return { url: new URL("./fixed-host-adapter-dependencies.mjs", import.meta.url).href, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
