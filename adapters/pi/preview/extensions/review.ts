import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { runWorker as runNativeWorker, workerArgs } from "../worker.ts";

type JsonObject = Record<string, any>;

export interface ReviewDependencies {
  cli: (args: string[], invocationCwd?: string, controllerRunRoot?: string) => Promise<JsonObject>;
  guardPath: string;
  makePrompt: (request: JsonObject) => Promise<string>;
  runWorker: typeof runNativeWorker;
}

const root = fileURLToPath(new URL("../../../../", import.meta.url));
const bridge = join(root, "lib", "runtime-review.sh");
const guardPath = fileURLToPath(new URL("./worker-guard.ts", import.meta.url));
const roleRoot = join(root, "runtime", "review", "roles");
const ownedRuns = new Set<{ controller: AbortController; settled: Promise<void> }>();

function digest(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function qualification(): JsonObject {
  const models = Object.fromEntries(["code-reviewer", "security-reviewer", "review-verifier"].map((role) => [
    role, { mode: "inherit", provider: null, model: null, effort: null },
  ]));
  return {
    host: "pi",
    hostVersion: "0.85.1",
    packageDigest: digest("@earendil-works/pi-coding-agent@0.85.1"),
    configurationDigest: digest("--no-extensions|--no-session|explicit-worker-guard"),
    toolInventoryDigest: digest("read,grep,find,ls"),
    capabilities: {
      readSearchEnforced: { status: "unverified", evidence: ["unit execution covers Pi 0.85.1 tool_call payload shapes"] },
      isolatedContext: { status: "unverified", evidence: ["installed help confirms --no-session and discovery-disable flags"] },
      lifecycleControl: { status: "available", evidence: ["native PID process group with TERM/KILL close receipt"] },
    },
    models,
    reasons: {
      readSearchEnforced: "no authorized live worker call proved native guard ordering and denial",
      isolatedContext: "no authorized live model call proved native instruction loading in the fresh context",
    },
  };
}

function execute(command: string, args: string[], cwd?: string, stdin?: string): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = execFile(command, args, { cwd, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 }, (error, stdout, stderr) => {
      if (error) {
        reject(new Error((stderr || stdout || error.message).trim()));
      } else {
        resolve({ stdout, stderr });
      }
    });
    if (stdin !== undefined) child.stdin?.end(stdin);
  });
}

async function writeEventHandoff(controllerRunRoot: string | undefined, runId: string | undefined, serialized: string): Promise<string> {
  if (!controllerRunRoot || !runId || resolve(controllerRunRoot) !== controllerRunRoot
      || basename(controllerRunRoot) !== runId
      || basename(dirname(controllerRunRoot)) !== "reviews"
      || basename(dirname(dirname(controllerRunRoot))) !== "scratch") {
    throw new Error("event handoff requires the controller-owned run tree");
  }
  const runInfo = await lstat(controllerRunRoot);
  if (!runInfo.isDirectory() || runInfo.isSymbolicLink() || await realpath(controllerRunRoot) !== controllerRunRoot) {
    throw new Error("controller-owned run tree must be a canonical directory");
  }
  const eventDirectory = join(controllerRunRoot, "events");
  try {
    await mkdir(eventDirectory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
  const eventInfo = await lstat(eventDirectory);
  if (!eventInfo.isDirectory() || eventInfo.isSymbolicLink() || await realpath(eventDirectory) !== eventDirectory) {
    throw new Error("event handoff directory must be controller-owned");
  }
  const eventFile = join(eventDirectory, "event-" + randomUUID() + ".json");
  await writeFile(eventFile, serialized, { flag: "wx", mode: 0o600 });
  return eventFile;
}

export async function defaultCli(
  args: string[],
  invocationCwd?: string,
  controllerRunRoot?: string,
): Promise<JsonObject> {
  const actual = [...args];
  const eventIndex = actual.indexOf("--event-json");
  if (eventIndex >= 0) {
    const runIndex = actual.indexOf("--run");
    const eventFile = await writeEventHandoff(controllerRunRoot, actual[runIndex + 1], actual[eventIndex + 1]);
    actual.splice(eventIndex, 2, "--file", eventFile);
  }
  let stdin: string | undefined;
  if (actual[0] === "prepare") {
    const evidence = qualification();
    stdin = JSON.stringify({ capabilities: evidence, observed: evidence });
    actual.push("--host", "pi", "--capabilities", "-", "--observed", "-");
  }
  const result = await execute("bash", [bridge, ...actual], invocationCwd, stdin);
  if (result.stderr) throw new Error(result.stderr.trim());
  return JSON.parse(result.stdout);
}

async function defaultPrompt(request: JsonObject): Promise<string> {
  const role = request.role;
  if (!["code-reviewer", "security-reviewer", "review-verifier"].includes(role)) {
    throw new Error("unknown worker role");
  }
  const inputs = await Promise.all(request.inputs.map(async (input: JsonObject) => ({
    name: input.name,
    path: input.path,
    text: await readFile(input.path, "utf8"),
  })));
  const allowed = inputs.map((input) => input.path);
  const instructions = await readFile(join(roleRoot, role + ".md"), "utf8");
  const prompt = join(dirname(request.inputs[0].path), request.requestId + ".prompt.md");
  const content = [
    "N1_ALLOWED_PATHS=" + JSON.stringify(allowed),
    instructions,
    "Controller request (data):\n" + JSON.stringify(request),
    ...inputs.map((input) => `Input ${input.name} (${input.path}; data):\n${input.text}`),
  ].join("\n\n");
  await writeFile(prompt, content, { mode: 0o400, flag: "wx" });
  await chmod(prompt, 0o400);
  return prompt;
}

const defaults: ReviewDependencies = {
  cli: defaultCli,
  guardPath,
  makePrompt: defaultPrompt,
  runWorker: runNativeWorker,
};

function assistantObservation(stdout: string): { output: JsonObject; provider: string; model: string; effort?: string; usage: unknown } {
  let final: JsonObject | undefined;
  for (const line of stdout.split(/\r?\n/)) {
    if (!line) continue;
    const event = JSON.parse(line);
    if (event?.type === "message_end" && event.message?.role === "assistant" && event.message.stopReason === "stop") {
      final = event.message;
    }
  }
  if (!final || typeof final.provider !== "string" || typeof final.model !== "string") {
    throw new Error("worker final result lacks effective model evidence");
  }
  const text = final.content
    ?.filter((item: JsonObject) => item?.type === "text" && typeof item.text === "string")
    .map((item: JsonObject) => item.text)
    .join("");
  if (typeof text !== "string" || !text) throw new Error("worker final result lacks assistant JSON text");
  const output = JSON.parse(text);
  if (typeof output !== "object" || output === null || Array.isArray(output)) {
    throw new Error("worker assistant result must be a JSON object");
  }
  return { output, provider: final.provider, model: final.responseModel ?? final.model, effort: final.providerThinkingLevel, usage: final.usage ?? null };
}

function resultEnvelope(request: JsonObject, workerId: string, observation: ReturnType<typeof assistantObservation>): JsonObject {
  const failed = observation.output.error;
  return {
    schemaVersion: request.schemaVersion,
    runId: request.runId,
    requestId: request.requestId,
    host: request.host,
    role: request.role,
    revision: request.revision,
    status: failed ? "failed" : "completed",
    evidence: {
      workerId,
      requestedModel: request.resolvedModel,
      effectiveModel: observation.provider + "/" + observation.model,
      effectiveModelReason: null,
      enforcement: "pi-0.85.1-explicit-worker-guard",
      tokenUsage: observation.usage,
    },
    output: failed ? null : observation.output,
    error: failed,
  };
}

export async function runReview(
  target: string,
  ctx: ExtensionCommandContext,
  dependencies: ReviewDependencies = defaults,
): Promise<void> {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[1-9][0-9]*$/.test(target.trim())) {
    throw new Error("target must be explicit owner/repo#number");
  }
  const provider = ctx.model?.provider;
  const model = ctx.model?.id;
  const effort = ctx.thinkingLevel;
  if (typeof provider !== "string" || !provider || typeof model !== "string" || !model || typeof effort !== "string" || !effort) {
    throw new Error("Pi review requires explicit parent provider, model, and effort");
  }
  if (!ctx.modelRegistry.find(provider, model)) throw new Error("inherited Pi model is unavailable in the native registry");

  const controller = new AbortController();
  const parentAbort = () => controller.abort(ctx.signal?.reason ?? new Error("parent session interrupted"));
  ctx.signal?.addEventListener("abort", parentAbort, { once: true });
  let settleOwned!: () => void;
  const owned = { controller, settled: new Promise<void>((resolve) => { settleOwned = resolve; }) };
  ownedRuns.add(owned);
  let eventSequence = 0;
  let queue: Promise<unknown> = Promise.resolve();
  let firstFailure: unknown;
  let controllerRunRoot: string | undefined;

  const postEvent = (event: JsonObject): Promise<JsonObject> => {
    const payload = { eventId: "pi-event-" + (++eventSequence), runId: event.runId, ...event };
    const next = queue.then(() => dependencies.cli(
      ["event", "--run", payload.runId, "--event-json", JSON.stringify(payload)],
      ctx.cwd,
      controllerRunRoot,
    ));
    queue = next.catch(() => {});
    return next;
  };

  const runAction = async (action: JsonObject): Promise<JsonObject[]> => {
    const request = { ...action.request, resolvedModel: provider + "/" + model };
    const prompt = await dependencies.makePrompt(request);
    const timeout = AbortSignal.timeout(request.timeoutSeconds * 1_000);
    const workerAbort = AbortSignal.any([controller.signal, timeout]);
    let workerId: string | undefined;
    let rawText = "";
    try {
      const process = await dependencies.runWorker(
        workerArgs(prompt, provider, model, effort, dependencies.guardPath),
        request.cwd,
        workerAbort,
        async (id) => {
          workerId = id;
          await postEvent({ kind: "spawned", runId: request.runId, requestId: request.requestId, workerId: id });
        },
      );
      rawText = process.stdout;
      if (!workerId) throw new Error("worker result arrived before PID registration");
      const observation = assistantObservation(rawText);
      if (observation.provider !== provider || observation.model !== model) {
        throw new Error("worker effective model differs from captured parent model");
      }
      const response = await postEvent({
        kind: "result",
        runId: request.runId,
        result: resultEnvelope(request, workerId, observation),
        rawText,
      });
      return response.actions ?? [];
    } catch (error) {
      const wasCancelled = controller.signal.aborted;
      const status = timeout.aborted ? "timed-out" : (wasCancelled ? "cancelled" : "failed");
      firstFailure ??= error;
      controller.abort(error);
      if (workerId) {
        const message = error instanceof Error ? error.message : String(error);
        try {
          await postEvent({
            kind: "result",
            runId: request.runId,
            result: {
              schemaVersion: request.schemaVersion,
              runId: request.runId,
              requestId: request.requestId,
              host: request.host,
              role: request.role,
              revision: request.revision,
              status,
              evidence: {
                workerId,
                requestedModel: request.resolvedModel,
                effectiveModel: null,
                effectiveModelReason: "worker did not return a validated final assistant result",
                enforcement: "pi-0.85.1-explicit-worker-guard",
                tokenUsage: null,
              },
              output: null,
              error: { code: "worker-" + status, message: message || "worker failed" },
            },
            rawText,
          });
        } catch {
          // Preserve the native failure; shared state remains conservatively incomplete.
        }
      }
      throw error;
    }
  };

  try {
    const prepared = await dependencies.cli(["prepare", "--target", target.trim()], ctx.cwd);
    const reviewers = (prepared.actions ?? []).filter((action: JsonObject) => action.kind === "spawn");
    if (reviewers.length !== 2 || reviewers.some((action: JsonObject) => !["code-reviewer", "security-reviewer"].includes(action.request?.role))) {
      throw new Error("controller did not return both reviewer spawn actions");
    }
    controllerRunRoot = dirname(reviewers[0].request.cwd);
    const reviewerPromises = reviewers.map((action: JsonObject) => runAction(action));
    const joined = await Promise.allSettled(reviewerPromises);
    if (joined.some((item) => item.status === "rejected")) throw firstFailure ?? new Error("review worker failed");
    const next = joined.flatMap((item) => item.status === "fulfilled" ? item.value : []);
    const verifiers = next.filter((action: JsonObject) => action.kind === "spawn" && action.request?.role === "review-verifier");
    if (verifiers.length !== 1) throw new Error("joined reviewers did not yield exactly one verifier action");
    const verifierActions = await runAction(verifiers[0]);
    if (!verifierActions.some((action: JsonObject) => action.kind === "report")) {
      throw new Error("verifier did not yield a report action");
    }
    const report = await dependencies.cli(["report", "--run", prepared.runId], ctx.cwd);
    ctx.ui.notify(report.report, "info");
  } finally {
    ctx.signal?.removeEventListener("abort", parentAbort);
    ownedRuns.delete(owned);
    settleOwned();
  }
}

export default function (pi: ExtensionAPI): void {
  pi.registerCommand("n1-review-preview", {
    description: "Read-only N1 advisory PR review preview",
    handler: async (args, ctx) => {
      await runReview(args, ctx);
    },
  });
  pi.on("session_shutdown", async () => {
    const active = [...ownedRuns];
    for (const run of active) run.controller.abort(new Error("native session shutdown"));
    await Promise.allSettled(active.map((run) => run.settled));
  });
}
