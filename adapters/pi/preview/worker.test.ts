import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import registerReview, { defaultCli, runReview, type ReviewDependencies } from "./extensions/review.ts";
import { allowedInputsFromArgs, createWorkerGuard } from "./extensions/worker-guard.ts";
import { runWorker, workerArgs, type WorkerDependencies } from "./worker.ts";

class FakeProcess extends EventEmitter {
  readonly stdout = new EventEmitter();
  readonly stderr = new EventEmitter();
  readonly pid = 4321;
}

function successLine(text = '{"findings":[]}'): string {
  return JSON.stringify({
    type: "message_end",
    message: {
      role: "assistant",
      content: [{ type: "text", text }],
      stopReason: "stop",
    },
  }) + "\n";
}

function workerOutput(output: object, role: string): string {
  return JSON.stringify({
    type: "message_end",
    message: {
      role: "assistant",
      provider: "parent-provider",
      model: "parent-model",
      providerThinkingLevel: "high",
      usage: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, cost: { total: 0 } },
      content: [{ type: "text", text: JSON.stringify(output) }],
      stopReason: "stop",
      timestamp: 1,
      api: "test",
    },
    testRole: role,
  }) + "\n";
}

function request(role: string) {
  return {
    schemaVersion: 1,
    runId: "run-1",
    requestId: role + "-request",
    host: "pi",
    role,
    cwd: "/scratch/source",
    inputs: role === "review-verifier"
      ? [{ name: "claims", path: "/scratch/claims", required: true }]
      : [
          { name: "diff", path: "/scratch/diff", required: true },
          { name: "requirements", path: "/scratch/requirements", required: true },
          { name: "conventions", path: "/scratch/conventions", required: true },
        ],
    revision: { repository: "owner/repo", baseSha: "a".repeat(40), headSha: "b".repeat(40) },
    modelPolicy: { mode: "inherit", provider: null, model: null, effort: null },
    requiredCapabilities: ["isolatedContext", "lifecycleControl", "readSearchEnforced"],
    timeoutSeconds: 10,
  };
}

function reviewContext() {
  const notices: string[] = [];
  return {
    notices,
    ctx: {
      model: { provider: "parent-provider", id: "parent-model" },
      thinkingLevel: "high",
      modelRegistry: {
        find: (provider: string, model: string) => provider === "parent-provider" && model === "parent-model" ? {} : undefined,
      },
      ui: { notify: (message: string) => { notices.push(message); } },
    },
  };
}

function reviewCli(events?: Array<Record<string, any>>) {
  const results: string[] = [];
  return async (args: string[]) => {
    const command = args[0];
    if (command === "prepare") {
      return { runId: "run-1", status: "reviewing", actions: [
        { kind: "spawn", request: request("code-reviewer") },
        { kind: "spawn", request: request("security-reviewer") },
      ] };
    }
    if (command === "event") {
      const event = JSON.parse(args[args.indexOf("--event-json") + 1]);
      events?.push(event);
      if (event.kind === "result") {
        results.push(event.result.role);
        if (results.length === 2) {
          return { runId: "run-1", status: "verifying", actions: [{ kind: "spawn", request: request("review-verifier") }] };
        }
        if (event.result.role === "review-verifier") {
          return { runId: "run-1", status: "completed", actions: [{ kind: "report" }] };
        }
      }
      return { runId: "run-1", status: "reviewing", actions: [] };
    }
    if (command === "report") return { runId: "run-1", status: "completed", report: "review report" };
    throw new Error("unexpected CLI command " + command);
  };
}

function harness(start: (child: FakeProcess) => void, overrides: Partial<WorkerDependencies> = {}) {
  const child = new FakeProcess();
  let spawnOptions: Record<string, unknown> | undefined;
  const dependencies: WorkerDependencies = {
    executable: "/trusted/pi",
    spawnProcess(_command, _args, options) {
      spawnOptions = options;
      queueMicrotask(() => start(child));
      return child;
    },
    killProcess: () => {},
    killDelayMs: 5,
    maxOutputBytes: 10 * 1024 * 1024,
    ...overrides,
  };
  return { child, dependencies, getSpawnOptions: () => spawnOptions };
}

test("workers disable discovered extensions and mutation tools", () => {
  const args = workerArgs("/scratch/prompt.md", "provider", "model", "high", "/trusted/guard.ts");
  assert.ok(args.includes("--no-extensions"));
  assert.ok(args.includes("--no-session"));
  assert.equal(args[args.indexOf("--tools") + 1], "read,grep,find,ls");
  assert.ok(!args.includes("--continue"));
  assert.ok(!args.includes("--resume"));
});

test("shell metacharacters remain inert model arguments", () => {
  const args = workerArgs("/scratch/prompt.md", "provider", "x;touch sentinel", "high", "/trusted/guard.ts");
  assert.equal(args[args.indexOf("--model") + 1], "x;touch sentinel");
});

test("fragmented JSONL yields a successful final assistant result after PID registration", async () => {
  let releaseRegistration!: () => void;
  const registered = new Promise<void>((resolve) => { releaseRegistration = resolve; });
  const events: string[] = [];
  const { child, dependencies, getSpawnOptions } = harness((process) => {
    process.stdout.emit("data", Buffer.from('{"type":"tool_execution_end","result":{"content":[{"type":"text","text":"not the result"}]}}\n{"type":"message_'));
    process.stdout.emit("data", Buffer.from('end","message":{"role":"assistant","content":[{"type":"text","text":"{\\"findings\\":[]}"}],"stopReason":"stop"}}\n'));
    process.emit("close", 0, null);
  });

  const pending = runWorker(["--model", "safe"], "/source", new AbortController().signal, async (workerId) => {
    events.push("registered:" + workerId);
    await registered;
  }, dependencies).then((result) => {
    events.push("delivered");
    return result;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(events, ["registered:4321"]);
  releaseRegistration();
  const result = await pending;
  assert.equal(result.exitCode, 0);
  assert.match(result.stdout, /not the result/);
  assert.deepEqual(events, ["registered:4321", "delivered"]);
  assert.equal(getSpawnOptions()?.shell, false);
  assert.equal(getSpawnOptions()?.cwd, "/source");
  assert.equal(getSpawnOptions()?.detached, true);
  assert.equal(child.listenerCount("close"), 0);
});

test("incremental parser preserves split UTF-8 and accepts a final line without newline", async () => {
  const output = successLine('{"findings":[],"note":"café"}').trimEnd();
  const bytes = Buffer.from(output);
  const split = bytes.indexOf(Buffer.from("é")) + 1;
  const { dependencies } = harness((child) => {
    child.stdout.emit("data", bytes.subarray(0, split));
    child.stdout.emit("data", bytes.subarray(split));
    child.emit("close", 0, null);
  });
  const result = await runWorker([], "/source", new AbortController().signal, async () => {}, dependencies);
  assert.equal(result.stdout, output);
});

test("nonzero exit fails even with a final assistant result", async () => {
  const { dependencies } = harness((child) => {
    child.stdout.emit("data", successLine());
    child.stderr.emit("data", "provider failed");
    child.emit("close", 7, null);
  });
  await assert.rejects(
    runWorker([], "/source", new AbortController().signal, async () => {}, dependencies),
    /worker exited with code 7: provider failed/,
  );
});

test("malformed or incomplete JSONL fails closed", async () => {
  for (const output of ['{"type": nope}\n', '{"type":"agent_end"}\n']) {
    const { dependencies } = harness((child) => {
      child.stdout.emit("data", output);
      child.emit("close", 0, null);
    });
    await assert.rejects(
      runWorker([], "/source", new AbortController().signal, async () => {}, dependencies),
      /(?:malformed JSONL|successful final assistant result)/,
    );
  }
});

test("output overflow terminates the process and remains incomplete", async () => {
  const signals: NodeJS.Signals[] = [];
  const { dependencies } = harness((child) => {
    child.stdout.emit("data", "12345");
    child.emit("close", 0, null);
  }, {
    maxOutputBytes: 4,
    killProcess: (_pid, signal) => { signals.push(signal); },
  });
  await assert.rejects(
    runWorker([], "/source", new AbortController().signal, async () => {}, dependencies),
    /10 MiB output limit/,
  );
  assert.deepEqual(signals, ["SIGTERM"]);
});

test("abort escalates from SIGTERM to SIGKILL and waits for close", async () => {
  const signals: NodeJS.Signals[] = [];
  const controller = new AbortController();
  const { child, dependencies } = harness(() => {}, {
    killProcess: (_pid, signal) => {
      signals.push(signal);
      if (signal === "SIGKILL") queueMicrotask(() => child.emit("close", null, "SIGKILL"));
    },
  });
  const pending = runWorker([], "/source", controller.signal, async () => {}, dependencies);
  controller.abort(new Error("deadline exceeded"));
  await assert.rejects(pending, /worker cancellation requested: deadline exceeded/);
  assert.deepEqual(signals, ["SIGTERM", "SIGKILL"]);
});

test("PID registration failure terminates and joins the worker before rejection", async () => {
  let closed = false;
  const { child, dependencies } = harness(() => {}, {
    killProcess: (_pid, signal) => {
      if (signal === "SIGTERM") queueMicrotask(() => {
        closed = true;
        child.emit("close", null, "SIGTERM");
      });
    },
  });
  await assert.rejects(
    runWorker([], "/source", new AbortController().signal, async () => { throw new Error("store unavailable"); }, dependencies),
    /worker PID registration failed: store unavailable/,
  );
  assert.equal(closed, true);
});

test("unobserved termination is reported as unconfirmed cancellation", async () => {
  const controller = new AbortController();
  const { dependencies } = harness(() => {}, {
    killProcess: () => { throw new Error("ESRCH"); },
  });
  const pending = runWorker([], "/source", controller.signal, async () => {}, dependencies);
  controller.abort();
  await assert.rejects(pending, /unconfirmed cancellation/);
});

test("worker guard accepts Pi 0.85.1 read/search payload paths only inside role roots", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "n1-pi-guard-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const source = join(root, "source");
  const input = join(root, "inputs", "diff");
  mkdirSync(source);
  mkdirSync(join(root, "inputs"));
  writeFileSync(join(source, "app.ts"), "safe\n");
  writeFileSync(input, "diff\n");
  symlinkSync(root, join(source, "escape"));
  let handler!: (event: Record<string, unknown>) => unknown;
  createWorkerGuard(source, [input])({
    on(name: string, value: typeof handler) {
      assert.equal(name, "tool_call");
      handler = value;
    },
  } as never);

  for (const event of [
    { type: "tool_call", toolCallId: "1", toolName: "read", input: { path: "app.ts", offset: 1, limit: 20 } },
    { type: "tool_call", toolCallId: "2", toolName: "read", input: { path: input } },
    { type: "tool_call", toolCallId: "3", toolName: "grep", input: { pattern: "safe", path: ".", literal: true } },
    { type: "tool_call", toolCallId: "4", toolName: "find", input: { pattern: "*.ts", path: source } },
    { type: "tool_call", toolCallId: "5", toolName: "ls", input: {} },
  ]) {
    assert.equal(await handler(event), undefined);
  }
  for (const event of [
    { type: "tool_call", toolCallId: "6", toolName: "bash", input: { command: "pwd" } },
    { type: "tool_call", toolCallId: "7", toolName: "read", input: { path: join(root, "secret") } },
    { type: "tool_call", toolCallId: "8", toolName: "grep", input: { pattern: "x", path: "escape" } },
    { type: "tool_call", toolCallId: "9", toolName: "read", input: { file_path: "app.ts" } },
  ]) {
    assert.deepEqual(await handler(event), { block: true, reason: "N1 reviewer tool unavailable" });
  }
});

test("worker guard derives controller-declared role input files from the trusted prompt", () => {
  const root = mkdtempSync(join(tmpdir(), "n1-pi-prompt-"));
  try {
    const prompt = join(root, "prompt.md");
    const inputs = [join(root, "diff"), join(root, "requirements")];
    writeFileSync(prompt, "N1_ALLOWED_PATHS=" + JSON.stringify(inputs) + "\n\nuntrusted body");
    assert.deepEqual(allowedInputsFromArgs(["pi", "--", "@" + prompt]), [prompt, ...inputs]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("Pi extension registers the advisory review command", () => {
  let registration: { name: string; description: string } | undefined;
  registerReview({
    registerCommand(name: string, options: { description: string }) {
      registration = { name, description: options.description };
    },
    on() {},
  } as never);
  assert.deepEqual(registration, {
    name: "n1-review-runtime",
    description: "Read-only N1 advisory PR review runtime",
  });
});

test("default bridge resolves repository-local N1 state from the Pi session cwd", async (t) => {
  const fixture = mkdtempSync(join(tmpdir(), "n1-pi-bridge-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  const checkout = join(fixture, "checkout");
  const home = join(checkout, ".n1");
  const runId = "12345678-1234-4234-8234-123456789abc";
  const run = join(home, "scratch", "reviews", runId);
  mkdirSync(join(run, "requests"), { recursive: true });
  mkdirSync(join(run, "results"));
  writeFileSync(join(home, "config.json"), "{}\n");
  const git = await import("node:child_process");
  git.execFileSync("git", ["init", "--quiet", checkout]);
  git.execFileSync("git", ["-C", checkout, "config", "n1.home", ".n1"]);
  writeFileSync(join(run, "state.json"), JSON.stringify({
    runId,
    status: "completed",
    reason: null,
    prNumber: 1,
    prTitle: "Fixture",
    findings: [],
    dispositions: [],
    cancellationUnconfirmed: [],
    revision: { repository: "owner/repo", baseSha: "a".repeat(40), headSha: "b".repeat(40) },
    workers: Object.fromEntries(["code-reviewer", "security-reviewer", "review-verifier"].map((role) => [role, {
      status: "completed",
      result: { evidence: { effectiveModel: "provider/model", effectiveModelReason: null, tokenUsage: null } },
    }])),
  }));

  const result = await defaultCli(["report", "--run", runId], checkout);
  assert.equal(result.runId, runId);
  assert.match(result.report, /Assessment: approve/);
  assert.match(readFileSync(join(run, "report.md"), "utf8"), /Assessment: approve/);
});

test("default event handoff stays inside its controller-owned run tree", async (t) => {
  const fixture = mkdtempSync(join(tmpdir(), "n1-pi-event-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  const checkout = join(fixture, "checkout");
  const home = join(checkout, ".n1");
  const runId = "22345678-1234-4234-8234-123456789abc";
  const run = join(home, "scratch", "reviews", runId);
  mkdirSync(run, { recursive: true });
  writeFileSync(join(home, "config.json"), "{}\n");
  const git = await import("node:child_process");
  git.execFileSync("git", ["init", "--quiet", checkout]);
  git.execFileSync("git", ["-C", checkout, "config", "n1.home", ".n1"]);
  const event = JSON.stringify({ eventId: "pi-event-2", runId, kind: "cancel", reason: "fixture" });

  await assert.rejects(defaultCli(
    ["event", "--run", runId, "--event-json", event],
    checkout,
    run,
  ), /run has no state/);
  const eventDirectory = join(run, "events");
  assert.equal(existsSync(eventDirectory), true);
  const files = readdirSync(eventDirectory);
  assert.equal(files.length, 1);
  assert.equal(readFileSync(join(eventDirectory, files[0]), "utf8"), event);
});

test("unverified pre-prepare qualification does not depend on OS temporary storage", async (t) => {
  const fixture = mkdtempSync(join(tmpdir(), "n1-pi-qualification-"));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));
  mkdirSync(join(fixture, ".n1"));
  writeFileSync(join(fixture, ".n1", "config.json"), "{}\n");
  const previous = process.env.TMPDIR;
  process.env.TMPDIR = join(fixture, "missing-temp-root");
  t.after(() => {
    if (previous === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = previous;
  });
  await assert.rejects(
    defaultCli(["prepare", "--target", "owner/repo#123"], fixture),
    /lacks available native evidence/i,
  );
});

test("controller starts both reviewers with inherited model values and joins before verifier", async () => {
  const calls: Array<{ role: string; args: string[]; signal: AbortSignal; release: () => void }> = [];
  const dependencies: ReviewDependencies = {
    cli: reviewCli(),
    guardPath: "/trusted/worker-guard.ts",
    makePrompt: async (value) => "/scratch/" + value.role + ".md",
    runWorker: async (args, _cwd, signal, onSpawn) => {
      const role = args.at(-1)!.slice("@/scratch/".length, -".md".length);
      await onSpawn(role + "-pid");
      await new Promise<void>((resolve) => calls.push({ role, args, signal, release: resolve }));
      const output = role === "review-verifier" ? { dispositions: [] } : { findings: [] };
      return { exitCode: 0, stdout: workerOutput(output, role), stderr: "" };
    },
  };
  const { ctx, notices } = reviewContext();
  const pending = runReview("owner/repo#123", ctx as never, dependencies);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(calls.map((call) => call.role), ["code-reviewer", "security-reviewer"]);
  for (const call of calls) {
    assert.equal(call.args[call.args.indexOf("--provider") + 1], "parent-provider");
    assert.equal(call.args[call.args.indexOf("--model") + 1], "parent-model");
    assert.equal(call.args[call.args.indexOf("--thinking") + 1], "high");
  }
  calls[0].release();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.length, 2);
  calls[1].release();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls[2].role, "review-verifier");
  calls[2].release();
  await pending;
  assert.deepEqual(notices, ["review report"]);
});

test("serialized successful reviewer and verifier envelopes pass the shared contract", async () => {
  const events: Array<Record<string, any>> = [];
  const dependencies: ReviewDependencies = {
    cli: reviewCli(events),
    guardPath: "/trusted/worker-guard.ts",
    makePrompt: async (value) => "/scratch/" + value.role + ".md",
    runWorker: async (args, _cwd, _signal, onSpawn) => {
      const role = args.at(-1)!.slice("@/scratch/".length, -".md".length);
      await onSpawn(role + "-pid");
      const output = role === "review-verifier" ? { dispositions: [] } : { findings: [] };
      return { exitCode: 0, stdout: workerOutput(output, role), stderr: "" };
    },
  };
  const { ctx } = reviewContext();
  await runReview("owner/repo#123", ctx as never, dependencies);

  const results = events.filter((event) => event.kind === "result").map((event) => event.result);
  assert.equal(results.length, 3);
  for (const result of results) {
    const contractRequest = request(result.role);
    const serialized = JSON.stringify({ request: contractRequest, result });
    const validated = spawnSync("python3", ["-c", [
      "import json, sys",
      "from lib.runtime_review.contract import validate_result",
      "value = json.load(sys.stdin)",
      "validate_result(value['request'], value['result'])",
    ].join("; ")], {
      cwd: new URL("../../../", import.meta.url),
      input: serialized,
      encoding: "utf8",
    });
    assert.equal(validated.status, 0, validated.stderr);
    assert.equal(JSON.parse(serialized).result.error, null);
  }
});

test("first reviewer failure immediately aborts its sibling and never starts verifier", async () => {
  let siblingSignal: AbortSignal | undefined;
  let started = 0;
  const events: Array<Record<string, any>> = [];
  const dependencies: ReviewDependencies = {
    cli: reviewCli(events),
    guardPath: "/trusted/worker-guard.ts",
    makePrompt: async (value) => "/scratch/" + value.role + ".md",
    runWorker: async (args, _cwd, signal, onSpawn) => {
      const role = args.at(-1)!.slice("@/scratch/".length, -".md".length);
      started += 1;
      await onSpawn(role + "-pid");
      if (role === "code-reviewer") throw new Error("reviewer failed");
      siblingSignal = signal;
      if (signal.aborted) throw new Error("sibling aborted");
      await new Promise<void>((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("sibling aborted")), { once: true }));
      throw new Error("unreachable");
    },
  };
  const { ctx } = reviewContext();
  await assert.rejects(runReview("owner/repo#123", ctx as never, dependencies), /reviewer failed/);
  assert.equal(started, 2);
  assert.equal(siblingSignal?.aborted, true);
  assert.deepEqual(
    events.filter((event) => event.kind === "result").map((event) => event.result.status).sort(),
    ["cancelled", "failed"],
  );
});

test("controller fails before prepare when parent model inheritance is unavailable", async () => {
  const { ctx } = reviewContext();
  (ctx as { model?: unknown }).model = undefined;
  let called = false;
  await assert.rejects(runReview("owner/repo#123", ctx as never, {
    cli: async () => { called = true; return {}; },
    guardPath: "/trusted/worker-guard.ts",
    makePrompt: async () => "/scratch/prompt.md",
    runWorker: async () => { throw new Error("unreachable"); },
  }), /explicit parent provider, model, and effort/);
  assert.equal(called, false);
});

test("controller rejects an effective model that differs from captured inheritance", async () => {
  const dependencies: ReviewDependencies = {
    cli: reviewCli(),
    guardPath: "/trusted/worker-guard.ts",
    makePrompt: async (value) => "/scratch/" + value.role + ".md",
    runWorker: async (_args, _cwd, _signal, onSpawn) => {
      await onSpawn(String(Math.random()).replace(".", "pid"));
      return {
        exitCode: 0,
        stdout: workerOutput({ findings: [] }, "reviewer").replace('"model":"parent-model"', '"model":"different-model"'),
        stderr: "",
      };
    },
  };
  const { ctx } = reviewContext();
  await assert.rejects(runReview("owner/repo#123", ctx as never, dependencies), /effective model differs from captured parent model/);
});
