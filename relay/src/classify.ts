// Server-side twin of hooks/status-hook.sh's event classification: cloud
// sandboxes can't run the local hook pipeline, so raw hook payloads are
// POSTed and interpreted here. Keep the two in sync.

export type HookAction =
  | { kind: "set"; state: "idle" | "working" | "attention" }
  | { kind: "delete" }
  | { kind: "agents"; delta: 1 | -1 }
  | { kind: "ignore" };

export const CLOUD_TTL_S = 30 * 60;
export const HOST_PRUNE_S = 24 * 60 * 60;

export function classify(payload: Record<string, unknown>): HookAction {
  switch (payload.hook_event_name) {
    case "SessionStart":
      return { kind: "set", state: "idle" };
    case "UserPromptSubmit":
    case "PostToolUse":
      return { kind: "set", state: "working" };
    case "PreToolUse":
      // AskUserQuestion never fires a permission Notification; only the
      // Pre event may upgrade — Post means the question was just answered.
      return payload.tool_name === "AskUserQuestion"
        ? { kind: "set", state: "attention" }
        : { kind: "set", state: "working" };
    case "Notification": {
      // The ~60s reminder just means "ready for your next prompt".
      const message = String(payload.message ?? "").toLowerCase();
      return message.includes("waiting for your input")
        ? { kind: "set", state: "idle" }
        : { kind: "set", state: "attention" };
    }
    case "Stop":
      return { kind: "set", state: "idle" };
    case "SessionEnd":
      return { kind: "delete" };
    case "SubagentStart":
      return { kind: "agents", delta: 1 };
    case "SubagentStop":
      return { kind: "agents", delta: -1 };
    default:
      return { kind: "ignore" };
  }
}

export function repoName(cwd: unknown): string | null {
  const parts = String(cwd ?? "").split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : null;
}

export function cloudExpired(receivedAt: number, now: number): boolean {
  return now - receivedAt > CLOUD_TTL_S;
}

export function hostExpired(receivedAt: number, now: number): boolean {
  return now - receivedAt > HOST_PRUNE_S;
}
