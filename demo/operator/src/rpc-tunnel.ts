import { spawn, type ChildProcess } from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Reaches a node whose RPC only listens on localhost (or whose reverse proxy does not
 * publish the domain routes) through an ssh port-forward, from inside the operator's own
 * process: `ssh -N -L <localPort>:<remote> <user>@<host>`. Meant for a key the node
 * restricts to port forwarding (`restrict,port-forwarding,permitopen="127.0.0.1:8080"`).
 * The child is restarted whenever it exits.
 */
export interface TunnelConfig {
  host: string;
  /** sshd port. Default 22. */
  port?: number;
  user: string;
  /** Private key material (OpenSSH PEM). Written to a 0600 file under the temp dir. */
  privateKey?: string;
  /** Path to an existing private key file; used when `privateKey` is not given. */
  keyFile?: string;
  /** `known_hosts` line(s) pinning the node's host key. Without it host keys are accepted on first use. */
  knownHosts?: string;
  /** Forward target as seen from the node. Default `127.0.0.1:8080`. */
  remote?: string;
  /** Local port to listen on. Default 18080. */
  localPort?: number;
  log?: (line: string) => void;
}

export interface Tunnel {
  /** The local URL the forward answers on. */
  url: string;
  stop(): void;
}

function portOpen(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port });
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
}

export async function startTunnel(config: TunnelConfig): Promise<Tunnel> {
  const log = config.log ?? ((line) => console.log(line));
  const localPort = config.localPort ?? 18080;
  const remote = config.remote ?? "127.0.0.1:8080";
  const dir = join(tmpdir(), `rpc-tunnel-${process.pid}`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  let keyFile = config.keyFile;
  if (config.privateKey) {
    keyFile = join(dir, "key");
    writeFileSync(keyFile, config.privateKey.endsWith("\n") ? config.privateKey : `${config.privateKey}\n`, { mode: 0o600 });
    chmodSync(keyFile, 0o600);
  }
  const knownHostsFile = join(dir, "known_hosts");
  writeFileSync(knownHostsFile, config.knownHosts ? `${config.knownHosts}\n` : "", { mode: 0o600 });

  const args = [
    "-N",
    "-o", "BatchMode=yes",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-o", `UserKnownHostsFile=${knownHostsFile}`,
    "-o", `StrictHostKeyChecking=${config.knownHosts ? "yes" : "accept-new"}`,
    "-p", String(config.port ?? 22),
    "-L", `127.0.0.1:${localPort}:${remote}`,
  ];
  if (keyFile) args.push("-i", keyFile, "-o", "IdentitiesOnly=yes");
  args.push(`${config.user}@${config.host}`);

  let child: ChildProcess | null = null;
  let stopped = false;
  const launch = () => {
    if (stopped) return;
    child = spawn("ssh", args, { stdio: ["ignore", "ignore", "pipe"] });
    child.stderr?.on("data", (data: Buffer) => log(`rpc tunnel: ${data.toString().trim()}`));
    child.once("exit", (code) => {
      child = null;
      if (stopped) return;
      log(`rpc tunnel: ssh exited (${code}), reconnecting in 5 s`);
      setTimeout(launch, 5_000);
    });
  };
  launch();

  const deadline = Date.now() + 30_000;
  while (!(await portOpen(localPort))) {
    if (Date.now() > deadline) throw new Error(`rpc tunnel: port ${localPort} did not open within 30 s`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  log(`rpc tunnel: ${config.user}@${config.host}:${config.port ?? 22} -> ${remote} on http://127.0.0.1:${localPort}`);
  return {
    url: `http://127.0.0.1:${localPort}`,
    stop() {
      stopped = true;
      child?.kill();
    },
  };
}
