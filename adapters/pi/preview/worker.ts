import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";

const OUTPUT_LIMIT = 10 * 1024 * 1024;
const KILL_GRACE_MS = 2_000;
const PI_EXECUTABLE = fileURLToPath(new URL(
  "./node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
  import.meta.url,
));

type StreamLike = EventEmitter;

interface ProcessLike extends EventEmitter {
  pid?: number;
  stdout: StreamLike | null;
  stderr: StreamLike | null;
}

export interface WorkerDependencies {
  executable: string;
  spawnProcess: (
    command: string,
    args: readonly string[],
    options: Record<string, unknown>,
  ) => ProcessLike;
  killProcess: (pid: number, signal: NodeJS.Signals) => void;
  killDelayMs: number;
  maxOutputBytes: number;
}

const defaultDependencies: WorkerDependencies = {
  executable: PI_EXECUTABLE,
  spawnProcess: (command, args, options) => spawn(command, args, options),
  killProcess: (pid, signal) => {
    if (process.platform === "win32") {
      process.kill(pid, signal);
    } else {
      process.kill(-pid, signal);
    }
  },
  killDelayMs: KILL_GRACE_MS,
  maxOutputBytes: OUTPUT_LIMIT,
};

export function workerArgs(
  promptPath: string,
  provider: string,
  model: string,
  effort: string,
  guardPath: string,
): string[] {
  return [
    "--mode", "json", "--print", "--no-session", "--no-extensions",
    "--no-skills", "--no-prompt-templates", "--no-themes", "--offline",
    "--extension", guardPath, "--tools", "read,grep,find,ls", "--provider", provider,
    "--model", model, "--thinking", effort, "--", "@" + promptPath,
  ];
}

function reasonText(signal: AbortSignal): string {
  return signal.reason instanceof Error ? signal.reason.message : "aborted";
}

/**
 * Run one fresh Pi worker. The optional dependency seam exists solely to make
 * the native process boundary deterministic in unit tests.
 */
export async function runWorker(
  args: string[],
  cwd: string,
  signal: AbortSignal,
  onSpawn: (workerId: string) => Promise<void>,
  dependencies: WorkerDependencies = defaultDependencies,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  if (signal.aborted) throw new Error("worker cancellation requested: " + reasonText(signal));

  const child = dependencies.spawnProcess(dependencies.executable, args, {
    cwd,
    detached: process.platform !== "win32",
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pid = child.pid;
  if (!Number.isSafeInteger(pid) || (pid as number) <= 0) {
    throw new Error("worker spawn did not return a native PID");
  }

  let stdout = "";
  let stderr = "";
  const stdoutDecoder = new StringDecoder("utf8");
  const stderrDecoder = new StringDecoder("utf8");
  let stdoutRemainder = "";
  let outputBytes = 0;
  let parseError: Error | undefined;
  let finalAssistant = false;
  let cancellation: string | undefined;
  let registrationError: string | undefined;
  let overflow = false;
  let closed = false;
  let exitCode: number | null = null;
  let exitSignal: NodeJS.Signals | null = null;
  let killTimer: NodeJS.Timeout | undefined;
  let confirmationTimer: NodeJS.Timeout | undefined;
  let resolveClose!: () => void;
  let rejectClose!: (error: Error) => void;
  const closeObserved = new Promise<void>((resolve, reject) => {
    resolveClose = resolve;
    rejectClose = reject;
  });

  const parseLine = (line: string): void => {
    if (!line.trim() || parseError) return;
    let event: unknown;
    try {
      event = JSON.parse(line);
    } catch {
      parseError = new Error("worker emitted malformed JSONL");
      return;
    }
    if (typeof event !== "object" || event === null) {
      parseError = new Error("worker emitted malformed JSONL event");
      return;
    }
    const value = event as Record<string, unknown>;
    const message = value.message;
    if (value.type === "message_end" && typeof message === "object" && message !== null) {
      const assistant = message as Record<string, unknown>;
      if (assistant.role === "assistant" && assistant.stopReason === "stop") finalAssistant = true;
    }
  };

  const consumeStdout = (text: string, final = false): void => {
    stdoutRemainder += text;
    const lines = stdoutRemainder.split("\n");
    const remainder = lines.pop() ?? "";
    stdoutRemainder = final ? "" : remainder;
    for (const line of lines) parseLine(line.endsWith("\r") ? line.slice(0, -1) : line);
    if (final && remainder) parseLine(remainder.endsWith("\r") ? remainder.slice(0, -1) : remainder);
  };

  const unconfirmed = (): void => {
    if (closed) return;
    rejectClose(new Error("worker has unconfirmed cancellation; native termination was not observed"));
  };

  const requestTermination = (why: string): void => {
    cancellation ??= why;
    try {
      dependencies.killProcess(pid as number, "SIGTERM");
    } catch {
      // Escalation below still gets an independent chance to terminate the group.
    }
    killTimer ??= setTimeout(() => {
      if (closed) return;
      try {
        dependencies.killProcess(pid as number, "SIGKILL");
      } catch {
        // The bounded confirmation timer reports that no close was observed.
      }
      confirmationTimer = setTimeout(unconfirmed, dependencies.killDelayMs);
    }, dependencies.killDelayMs);
  };

  const append = (target: "stdout" | "stderr", chunk: unknown): void => {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    outputBytes += buffer.byteLength;
    if (outputBytes > dependencies.maxOutputBytes) {
      overflow = true;
      requestTermination("worker exceeded 10 MiB output limit");
      return;
    }
    const text = (target === "stdout" ? stdoutDecoder : stderrDecoder).write(buffer);
    if (target === "stdout") {
      stdout += text;
      consumeStdout(text);
    } else {
      stderr += text;
    }
  };

  const onStdout = (chunk: unknown) => append("stdout", chunk);
  const onStderr = (chunk: unknown) => append("stderr", chunk);
  const onError = (error: Error) => {
    parseError ??= new Error("worker process error: " + error.message);
  };
  const onClose = (code: number | null, nativeSignal: NodeJS.Signals | null) => {
    closed = true;
    exitCode = code;
    exitSignal = nativeSignal;
    if (killTimer) clearTimeout(killTimer);
    if (confirmationTimer) clearTimeout(confirmationTimer);
    const stdoutTail = stdoutDecoder.end();
    const stderrTail = stderrDecoder.end();
    stdout += stdoutTail;
    stderr += stderrTail;
    consumeStdout(stdoutTail, true);
    resolveClose();
  };

  child.stdout?.on("data", onStdout);
  child.stderr?.on("data", onStderr);
  child.on("error", onError);
  child.on("close", onClose);
  const registered = Promise.resolve().then(() => onSpawn(String(pid))).catch((error: unknown) => {
    const detail = error instanceof Error ? error.message : String(error);
    registrationError = "worker PID registration failed: " + detail;
    requestTermination(registrationError);
  });
  const onAbort = () => requestTermination("worker cancellation requested: " + reasonText(signal));
  signal.addEventListener("abort", onAbort, { once: true });

  try {
    await registered;
    await closeObserved;
  } finally {
    signal.removeEventListener("abort", onAbort);
    child.stdout?.off("data", onStdout);
    child.stderr?.off("data", onStderr);
    child.off("error", onError);
    child.off("close", onClose);
    if (killTimer) clearTimeout(killTimer);
    if (confirmationTimer) clearTimeout(confirmationTimer);
  }

  if (overflow) throw new Error("worker exceeded 10 MiB output limit");
  if (registrationError) throw new Error(registrationError);
  if (cancellation) throw new Error(cancellation);
  if (parseError) throw parseError;
  if (exitCode !== 0) {
    const detail = stderr.trim() || (exitSignal ? "signal " + exitSignal : "no exit status");
    throw new Error(`worker exited with code ${String(exitCode)}: ${detail}`);
  }
  if (!finalAssistant) throw new Error("worker did not emit a successful final assistant result");
  return { exitCode, stdout, stderr } as { exitCode: number; stdout: string; stderr: string };
}
