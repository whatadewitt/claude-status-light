import { describe, it, expect } from "vitest";
import {
  classify,
  repoName,
  cloudExpired,
  hostExpired,
  CLOUD_TTL_S,
  HOST_PRUNE_S,
} from "../src/classify";

describe("classify", () => {
  it("SessionStart → idle", () => {
    expect(classify({ hook_event_name: "SessionStart" })).toEqual({ kind: "set", state: "idle" });
  });

  it("UserPromptSubmit and PostToolUse → working", () => {
    expect(classify({ hook_event_name: "UserPromptSubmit" })).toEqual({ kind: "set", state: "working" });
    expect(classify({ hook_event_name: "PostToolUse", tool_name: "AskUserQuestion" })).toEqual({
      kind: "set",
      state: "working",
    });
  });

  it("PreToolUse → working, except AskUserQuestion → attention", () => {
    expect(classify({ hook_event_name: "PreToolUse", tool_name: "Bash" })).toEqual({ kind: "set", state: "working" });
    expect(classify({ hook_event_name: "PreToolUse", tool_name: "AskUserQuestion" })).toEqual({
      kind: "set",
      state: "attention",
    });
  });

  it("Notification → attention, except the ~60s idle reminder → idle", () => {
    expect(classify({ hook_event_name: "Notification", message: "Claude needs your permission to use Bash" })).toEqual(
      { kind: "set", state: "attention" },
    );
    expect(classify({ hook_event_name: "Notification", message: "Claude is waiting for your input" })).toEqual({
      kind: "set",
      state: "idle",
    });
  });

  it("Stop → idle, SessionEnd → delete", () => {
    expect(classify({ hook_event_name: "Stop" })).toEqual({ kind: "set", state: "idle" });
    expect(classify({ hook_event_name: "SessionEnd" })).toEqual({ kind: "delete" });
  });

  it("Subagent events adjust the count", () => {
    expect(classify({ hook_event_name: "SubagentStart" })).toEqual({ kind: "agents", delta: 1 });
    expect(classify({ hook_event_name: "SubagentStop" })).toEqual({ kind: "agents", delta: -1 });
  });

  it("unknown events are ignored", () => {
    expect(classify({ hook_event_name: "SomethingNew" })).toEqual({ kind: "ignore" });
    expect(classify({})).toEqual({ kind: "ignore" });
  });
});

describe("repoName", () => {
  it("takes the last path component", () => {
    expect(repoName("/home/user/work/my-repo")).toBe("my-repo");
    expect(repoName("/home/user/work/my-repo/")).toBe("my-repo");
  });

  it("returns null when there is nothing usable", () => {
    expect(repoName(undefined)).toBeNull();
    expect(repoName("")).toBeNull();
    expect(repoName("/")).toBeNull();
  });
});

describe("expiry", () => {
  it("cloud sessions expire after the TTL", () => {
    expect(cloudExpired(1000, 1000 + CLOUD_TTL_S)).toBe(false);
    expect(cloudExpired(1000, 1000 + CLOUD_TTL_S + 1)).toBe(true);
  });

  it("host records are pruned after a day", () => {
    expect(hostExpired(1000, 1000 + HOST_PRUNE_S)).toBe(false);
    expect(hostExpired(1000, 1000 + HOST_PRUNE_S + 1)).toBe(true);
  });
});
