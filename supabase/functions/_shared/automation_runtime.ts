export interface RuntimeNode {
  id: string;
  kind: string;
  config: Record<string, string>;
}
export interface RuntimeGraph {
  schema: number;
  nodes: RuntimeNode[];
  edges: { from: string; port: string; to: string }[];
}
export type RuntimeValue = string | number | boolean | null | RuntimeValue[] | { [key: string]: RuntimeValue };
export interface RuntimeState {
  flow_id: string;
  version: number;
  node_id: string;
  variables: Record<string, RuntimeValue>;
  status: "running" | "waiting" | "human" | "completed" | "error";
  steps: number;
}
export interface RuntimeEffects {
  save(state: RuntimeState): Promise<void>;
  send(text: string, step: number): Promise<void>;
  api(resourceId: string, query: Record<string, string | number | boolean | null>, body: RuntimeValue, step: number): Promise<RuntimeValue>;
}

function valueAt(value: RuntimeValue, path: string): RuntimeValue {
  for (const part of path.split(".")) {
    if (["__proto__", "prototype", "constructor"].includes(part) ||
      value === null || typeof value !== "object" || !Object.hasOwn(value, part)) {
      throw new Error(`Variable no disponible: ${path}`);
    }
    if (Array.isArray(value)) {
      if (!/^(0|[1-9][0-9]*)$/.test(part)) throw new Error(`Variable no disponible: ${path}`);
      value = value[Number(part)];
    } else value = value[part];
  }
  return value;
}

export function render(text: string, variables: Record<string, RuntimeValue>): string {
  return text.replace(/\{\{([a-zA-Z][a-zA-Z0-9_.]*)\}\}/g, (_, key: string) => {
    const value = valueAt(variables, key);
    return typeof value === "string" ? value : JSON.stringify(value);
  });
}

function payload(raw: string | undefined, variables: Record<string, RuntimeValue>): Record<string, RuntimeValue> {
  const parsed: unknown = JSON.parse(raw?.trim() || "{}");
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Los parámetros API deben ser un objeto JSON");
  }
  function resolve(value: unknown): RuntimeValue {
    if (typeof value === "string") return render(value, variables);
    if (Array.isArray(value)) return value.map(resolve);
    if (value && typeof value === "object") {
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolve(v)]));
    }
    if (value === null || typeof value === "number" || typeof value === "boolean") return value;
    throw new Error("Valor JSON no compatible");
  }
  return resolve(parsed) as Record<string, RuntimeValue>;
}

export async function executeFlow(
  graph: RuntimeGraph, state: RuntimeState, input: string | null, effects: RuntimeEffects,
) {
  if (graph.schema !== 1 || graph.nodes.length > 60 || graph.edges.length > 180) {
    throw new Error("Formato de flujo no compatible");
  }
  const node = () => {
    const n = graph.nodes.find((n) => n.id === state.node_id);
    if (!n) throw new Error("Bloque no disponible");
    return n;
  };
  const next = (port: string) => {
    const matches = graph.edges.filter((e) => e.from === state.node_id && e.port === port);
    if (matches.length !== 1) throw new Error(`Salida no configurada: ${port}`);
    state.node_id = matches[0].to;
  };
  if (["human", "error", "completed"].includes(state.status)) return;
  if (state.status === "waiting") {
    if (input === null) return;
    const n = node();
    if (!["question", "options"].includes(n.kind)) throw new Error("Espera de respuesta no válida");
    const text = input.trim();
    const options = (n.config.options ?? "").split("|").map((v) => v.trim()).filter(Boolean);
    const choice = n.kind === "options"
      ? options.find((v, i) => v.toLocaleLowerCase() === text.toLocaleLowerCase() || String(i + 1) === text)
      : text;
    if (!choice) {
      if (++state.steps > 1000) throw new Error("La sesión alcanzó el límite de 1000 pasos");
      await effects.save(state);
      await effects.send(`Selecciona una opción:\n${options.map((v, i) => `${i + 1}. ${v}`).join("\n")}`, state.steps);
      await effects.save(state);
      return;
    }
    state.variables[n.config.variable] = choice;
    state.status = "running";
    next(n.kind === "options" ? choice : "Siguiente");
    await effects.save(state);
  }
  for (let count = 0; count < 30; count++) {
    if (++state.steps > 1000) throw new Error("La sesión alcanzó el límite de 1000 pasos");
    const n = node();
    switch (n.kind) {
      case "start":
        next("Siguiente");
        break;
      case "text":
      case "question":
      case "options": {
        let text = render(n.config.text ?? "", state.variables);
        if (n.kind === "options") {
          text += `\n${(n.config.options ?? "").split("|").map((s, i) => `${i + 1}. ${s.trim()}`).join("\n")}`;
        }
        if (!text.trim() || text.length > 4096) throw new Error("Mensaje vacío o demasiado largo");
        await effects.save(state);
        await effects.send(text, state.steps);
        if (n.kind === "text") next("Siguiente");
        else {
          state.status = "waiting";
          await effects.save(state);
          return;
        }
        break;
      }
      case "condition": {
        const key = n.config.variable;
        if (!Object.hasOwn(state.variables, key)) throw new Error(`Variable no disponible: ${key}`);
        const value = state.variables[key];
        next(String(value).trim().toLocaleLowerCase() === n.config.equals?.trim().toLocaleLowerCase() ? "Sí" : "No");
        break;
      }
      case "api": {
        if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(n.config.resource_id ?? "")) {
          throw new Error("Selecciona un recurso API real antes de activar el flujo");
        }
        const variable = n.config.result_variable || "api_result";
        if (!/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/.test(variable)) throw new Error("Variable de resultado no válida");
        const path = n.config.result_path?.trim();
        if (path && !/^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)*$/.test(path)) {
          throw new Error("Ruta de resultado no válida");
        }
        const parameters = payload(n.config.query, state.variables);
        const query: Record<string, string | number | boolean | null> = {};
        for (const [key, value] of Object.entries(parameters)) {
          if (value !== null && typeof value === "object") throw new Error("La consulta API solo admite valores simples");
          query[key] = value;
        }
        const body = payload(n.config.body, state.variables);
        await effects.save(state);
        // The adapter routes explicit rejections to Error; ambiguous writes throw and pause.
        const result = await effects.api(n.config.resource_id, query, body, state.steps);
        const rejected = result !== null && typeof result === "object" && !Array.isArray(result) && result.ok === false;
        state.variables[variable] = path && !rejected ? valueAt(result, path) : result;
        next(rejected ? "Error" : "Éxito");
        break;
      }
      case "review":
      case "handoff":
        state.status = "human";
        await effects.save(state);
        return;
      case "end":
        state.status = "completed";
        await effects.save(state);
        return;
      default:
        throw new Error(`Bloque no compatible: ${n.kind}`);
    }
    await effects.save(state);
  }
  throw new Error("El flujo alcanzó 30 pasos sin esperar una respuesta; revisa sus ciclos");
}
