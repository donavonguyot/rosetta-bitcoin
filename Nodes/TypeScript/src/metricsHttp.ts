import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

import type { Settings } from "./config/settings.js";
import type { NativeNodeState } from "./runtime/nodeState.js";
import { prometheusExpositionFormat } from "./metrics.js";

const CONTENT_TYPE_PROM = "text/plain; charset=utf-8; version=0.0.4";

export interface MetricsServerHandle {
  server: Server;
  close(): Promise<void>;
}

function writePlainResponse(
  res: ServerResponse,
  statusCode: number,
  statusMessage: string,
  body: string,
  contentType = "text/plain; charset=utf-8",
): void {
  const bodyBytes = Buffer.from(body, "utf-8");
  res.writeHead(statusCode, statusMessage, {
    "Content-Type": contentType,
    "Content-Length": String(bodyBytes.length),
    Connection: "close",
  });
  res.end(bodyBytes);
}

export function serveMetricsHttpRequest(
  req: IncomingMessage,
  res: ServerResponse,
  tracker: NativeNodeState,
  settings: Settings,
): void {
  const path = (req.url ?? "").split("?", 1)[0] ?? "";

  if (req.method !== "GET") {
    writePlainResponse(res, 405, "Method Not Allowed", "Method Not Allowed");
    return;
  }
  if (path !== "/metrics") {
    writePlainResponse(res, 404, "Not Found", "Not Found");
    return;
  }

  const body = prometheusExpositionFormat(tracker, { chain: settings.chain });
  writePlainResponse(res, 200, "OK", body, CONTENT_TYPE_PROM);
}

export function createMetricsHttpServer(
  tracker: NativeNodeState,
  settings: Settings,
): Server {
  return createServer((req, res) => {
    serveMetricsHttpRequest(req, res, tracker, settings);
  });
}

export function startMetricsServer(
  settings: Settings,
  tracker: NativeNodeState,
): MetricsServerHandle | null {
  if (settings.metricsHttpPort <= 0) {
    return null;
  }

  const bindHost = settings.metricsHttpBind.trim() || "127.0.0.1";
  const server = createMetricsHttpServer(tracker, settings);

  server.listen(settings.metricsHttpPort, bindHost, () => {
    const address = server.address();
    const ports =
      typeof address === "object" && address !== null ? [address.port] : [settings.metricsHttpPort];
    tracker.logEvent(
      "node",
      `Metrics HTTP listening (${bindHost} ports=${ports.join(",")})`,
      "info",
      {
        ports,
        bind_host: bindHost,
        configured_port: settings.metricsHttpPort,
      },
    );
  });

  return {
    server,
    close() {
      return new Promise((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      });
    },
  };
}
