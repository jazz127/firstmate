import type * as Pi from "@earendil-works/pi-coding-agent";
import type { StowWorker } from "./fm-precompact-stow.ts";

export function createPiStowWorker(sdk: typeof Pi): StowWorker {
  return async (request, ctx, signal) => {
    if (!ctx.model || signal.aborted) throw new Error("stow session unavailable");
    const { provider, id } = ctx.model;
    const runtime = await sdk.ModelRuntime.create();
    const config = ctx.modelRegistry.getRegisteredProviderConfig(provider);
    if (config) {
      runtime.registerProvider(provider, config);
      await runtime.refresh({ providers: [provider], allowNetwork: false });
    }
    const model = runtime.getModel(provider, id);
    if (!model) throw new Error(`stow model unavailable: ${provider}/${id}`);
    const agentDir = sdk.getAgentDir();
    const settingsManager = sdk.SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
    const loader = new sdk.DefaultResourceLoader({
      cwd: request.home,
      agentDir,
      settingsManager,
      noExtensions: true,
      noSkills: true,
      noPromptTemplates: true,
      noThemes: true,
      noContextFiles: true,
      systemPrompt: request.role,
    });
    await loader.reload();
    if (signal.aborted) throw new Error("stow deadline expired");
    const bash = sdk.createBashToolDefinition(request.home, {
      spawnHook: (context) => ({
        ...context,
        env: { ...context.env, FM_HOME: request.home, FM_PRECOMPACT_STOW_ACTIVE: "1", NO_MISTAKES_GATE: "1" },
      }),
    });
    const { session } = await sdk.createAgentSession({
      cwd: request.home,
      agentDir,
      model,
      modelRuntime: runtime,
      resourceLoader: loader,
      sessionManager: sdk.SessionManager.inMemory(request.home),
      settingsManager,
      tools: ["read", "edit", "write", "bash"],
      customTools: [bash as unknown as Pi.ToolDefinition],
    });
    const abort = (): void => { session.dispose(); };
    signal.addEventListener("abort", abort, { once: true });
    try {
      if (signal.aborted) throw new Error("stow deadline expired");
      await session.prompt(request.prompt);
      const assistant = [...session.messages].reverse().find((message) => message.role === "assistant");
      if (assistant && "stopReason" in assistant && (assistant.stopReason === "error" || assistant.stopReason === "aborted")) {
        throw new Error("errorMessage" in assistant ? String(assistant.errorMessage) : "stow provider failed");
      }
      return JSON.stringify(session.messages);
    } finally {
      signal.removeEventListener("abort", abort);
      session.dispose();
    }
  };
}
