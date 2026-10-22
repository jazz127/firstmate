// Native pre-compaction transport only; the shell entrypoint owns eligibility,
// persistence, serialization, and its deadline. No provider message is emitted.
import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
type Context = {
  sessionManager: {
    getSessionId(): string;
    getSessionFile(): string | undefined;
    getBranch(): unknown[];
  };
  model?: { provider: string; id: string };
};
type Adapter = {
  on(event: "session_before_compact", handler: (event: { reason?: string }, ctx: Context) => Promise<void>): unknown;
};

export function registerPrecompactStow(adapter: Adapter): void {
  adapter.on("session_before_compact", async (event, ctx) => {
    if (process.env.FM_PRECOMPACT_STOW_ACTIVE === "1" || process.env.NO_MISTAKES_GATE) return;
    try {
      const transcript = ctx.sessionManager.getSessionFile();
      if (!transcript || !ctx.model) return;
      const payload = JSON.stringify({
        hook_event_name: "PreCompact",
        session_id: ctx.sessionManager.getSessionId(),
        transcript_path: transcript,
        trigger: event.reason === "manual" ? "manual" : "auto",
        branch_entries: ctx.sessionManager.getBranch(),
        provider: ctx.model.provider,
        model: ctx.model.id,
      });
      await new Promise<void>((done) => {
        const child = spawn(`${root}/bin/fm-precompact-stow.sh`, ["--harness", "pi"], {
          cwd: root,
          env: process.env,
          stdio: ["pipe", "ignore", "ignore"],
        });
        // The shell has the whole-pass deadline; this is transport insurance.
        const timer = setTimeout(() => { child.kill("SIGTERM"); done(); }, 75000);
        const finish = (): void => { clearTimeout(timer); done(); };
        child.once("error", finish);
        child.once("close", finish);
        child.stdin.on("error", () => {});
        child.stdin.end(payload);
      });
    } catch {
      // Never cancel or replace native compaction on a stow failure.
    }
  });
}
