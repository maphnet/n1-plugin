import { closeSync, openSync, readSync, realpathSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";
import type { ExtensionAPI, ToolCallEvent } from "@earendil-works/pi-coding-agent";

const READ_TOOLS = new Set(["read", "grep", "find", "ls"]);
const DENIAL = { block: true, reason: "N1 reviewer tool unavailable" } as const;

function contains(root: string, candidate: string): boolean {
  const value = relative(root, candidate);
  return value === "" || (!value.startsWith("..") && !isAbsolute(value));
}

function eventPath(event: ToolCallEvent): string | undefined {
  if (event.toolName === "read") {
    return typeof event.input.path === "string" ? event.input.path : undefined;
  }
  if (event.toolName === "grep" || event.toolName === "find" || event.toolName === "ls") {
    const value = event.input.path;
    return value === undefined ? "." : (typeof value === "string" ? value : undefined);
  }
  return undefined;
}

export function createWorkerGuard(sourceRoot: string, inputFiles: string[]) {
  const source = realpathSync(sourceRoot);
  const inputs = new Set(inputFiles.map((path) => realpathSync(path)));
  return function workerGuard(pi: ExtensionAPI): void {
    pi.on("tool_call", (event) => {
      if (!READ_TOOLS.has(event.toolName)) return DENIAL;
      const requested = eventPath(event);
      if (requested === undefined) return DENIAL;
      try {
        const target = realpathSync(resolve(source, requested));
        if (contains(source, target) || inputs.has(target)) return undefined;
      } catch {
        // Missing paths and broken links are outside the proven read boundary.
      }
      return DENIAL;
    });
  };
}

export function allowedInputsFromArgs(args: string[]): string[] {
  const promptArgument = args.find((value) => value.startsWith("@/") && value.length > 2);
  if (!promptArgument) return [];
  const prompt = realpathSync(promptArgument.slice(1));
  const descriptor = openSync(prompt, "r");
  let firstLine = "";
  try {
    const buffer = Buffer.alloc(64 * 1024);
    const length = readSync(descriptor, buffer, 0, buffer.length, 0);
    firstLine = buffer.subarray(0, length).toString("utf8").split(/\r?\n/, 1)[0];
  } finally {
    closeSync(descriptor);
  }
  if (!firstLine.startsWith("N1_ALLOWED_PATHS=")) return [prompt];
  try {
    const parsed = JSON.parse(firstLine.slice("N1_ALLOWED_PATHS=".length));
    if (!Array.isArray(parsed) || parsed.some((value) => typeof value !== "string" || !isAbsolute(value))) return [prompt];
    return [prompt, ...parsed];
  } catch {
    return [prompt];
  }
}

export default createWorkerGuard(process.cwd(), allowedInputsFromArgs(process.argv));
