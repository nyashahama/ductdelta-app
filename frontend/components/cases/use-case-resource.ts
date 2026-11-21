import { useEffect, useRef, useState } from "react";
import { api, reportError } from "../../lib/api";

type Resource<T> =
  | { kind: "loading" }
  | { kind: "ready"; data: T }
  | { kind: "error"; message: string };

export function useCaseResource<T>(path: string, expire: () => void) {
  const [version, setVersion] = useState(0);
  const [result, setResult] = useState<{ path: string; version: number; resource: Resource<T> } | null>(null);
  const expireRef = useRef(expire);

  useEffect(() => { expireRef.current = expire; }, [expire]);
  useEffect(() => {
    const request = new AbortController();
    void api<T>(path, { signal: request.signal }).then((data) => {
      if (!request.signal.aborted) setResult({ path, version, resource: { kind: "ready", data } });
    }).catch((error: unknown) => {
      if (!request.signal.aborted) {
        const message = reportError(error, expireRef.current);
        if (message) setResult({ path, version, resource: { kind: "error", message } });
      }
    });
    return () => request.abort();
  }, [path, version]);

  const resource: Resource<T> = result?.path === path && result.version === version
    ? result.resource : { kind: "loading" };
  return { resource, reload: () => setVersion((value) => value + 1) };
}

export function useActiveComponent() {
  const active = useRef(false);
  useEffect(() => {
    active.current = true;
    return () => { active.current = false; };
  }, []);
  return active;
}
