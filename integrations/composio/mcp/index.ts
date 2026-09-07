// ============================================================================
// Balance CRM · MCP-сервер только на чтение
//
// Показывает лидов наружу так, как их понимает Composio: свой коннектор
// в дашборде собирается из удалённого MCP-сервера, импорта OpenAPI там нет.
//
// Ставится Edge Function'ом в тот же проект Supabase, где и база. Своих прав
// у сервера нет ни одного: ключ приходит от Composio в заголовке Authorization
// и передаётся в PostgREST как есть. Что разрешено ключу — то и произойдёт.
// Ключ crm_readonly (db/12_readonly.sql) умеет только читать.
//
// Инструмент check_write_rejected пробует записать. Он обязан возвращать
// отказ 403 с кодом 42501 — это и есть доказательство, что ключ односторонний.
//
// Разворачивание — docs/composio-readonly.md. Папку supabase/ в репозитории
// не создавать: интеграция Supabase с GitHub начнёт применять миграции сама.
// ============================================================================

const env = (k: string, d: string) =>
  (globalThis as any).Deno?.env?.get(k) ?? (globalThis as any).process?.env?.[k] ?? d;

const CRM_API = env('CRM_API', 'https://wiokdxswbcmjdpalyrat.supabase.co/rest/v1');
const NAME = 'balance-crm-readonly';
const VERSION = '1.0.0';
const PROTOCOL = '2025-06-18';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, mcp-protocol-version, mcp-session-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// --- Инструменты -----------------------------------------------------------

const LIMIT = { type: 'integer', minimum: 1, maximum: 200, default: 50,
                description: 'Сколько строк вернуть, по умолчанию 50' };

const TOOLS = [
  {
    name: 'list_leads',
    description:
      'Лиды CRM со всеми полями и статусами: заведение, ЛПР, статус сделки, ' +
      'тариф, сумма внедрения и подписки, этапы оплаты, дата следующего шага, ' +
      'число касаний. Основной инструмент.',
    inputSchema: {
      type: 'object',
      properties: {
        status: {
          type: 'string',
          enum: ['new', 'no_answer', 'contacted', 'brief_done', 'proposal_sent',
                 'negotiation', 'won', 'lost'],
          description: 'Оставить только лидов в этом статусе',
        },
        open_only: { type: 'boolean', description: 'Только открытые сделки: без won и lost' },
        search: { type: 'string', description: 'Часть названия заведения' },
        order: { type: 'string', default: 'score.desc',
                 description: 'Сортировка: колонка.asc или колонка.desc' },
        limit: LIMIT,
      },
    },
  },
  {
    name: 'get_lead',
    description: 'Один лид целиком по идентификатору.',
    inputSchema: {
      type: 'object',
      required: ['id'],
      properties: { id: { type: 'string', description: 'Идентификатор лида (uuid)' } },
    },
  },
  {
    name: 'list_activities',
    description: 'Журнал касаний: звонки, переписки, системные записи о смене статуса и оплате.',
    inputSchema: {
      type: 'object',
      properties: {
        lead_id: { type: 'string', description: 'Касания одного лида' },
        since: { type: 'string', description: 'С этой даты, например 2026-09-01' },
        limit: LIMIT,
      },
    },
  },
  {
    name: 'list_companies',
    description: 'Заведения: название, сегмент, адрес, точки, средний чек, ссылки.',
    inputSchema: {
      type: 'object',
      properties: {
        search: { type: 'string', description: 'Часть названия' },
        limit: LIMIT,
      },
    },
  },
  {
    name: 'list_tariffs',
    description: 'Тарифы: единственный источник сумм внедрения и подписки.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'check_write_rejected',
    description:
      'Проверка односторонности доступа: пробует создать лид. Обязана вернуть ' +
      'отказ 403 с кодом 42501. Если запись когда-нибудь пройдёт, доступ ' +
      'нужно немедленно отозвать: revoke crm_readonly from authenticator.',
    inputSchema: { type: 'object', properties: {} },
  },
];

// --- Обращение к базе ------------------------------------------------------

const LEAD_FIELDS = [
  'id', 'company_name', 'segment', 'address', 'status', 'owner_name', 'tariff',
  'setup_amount', 'mrr_amount', 'stage1_amount', 'stage2_amount', 'stage3_amount',
  'paid_total', 'next_action_at', 'next_action', 'lost_reason',
  'dm_name', 'dm_position', 'dm_phone', 'primary_phone',
  'score', 'touch_count', 'last_touch_at',
].join(',');

async function crm(key: string, path: string, init: RequestInit = {}) {
  const r = await fetch(`${CRM_API}/${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });
  const text = await r.text();
  let body: unknown = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  return { status: r.status, ok: r.ok, body };
}

const clamp = (n: unknown, d: number) =>
  Math.min(200, Math.max(1, Number.isFinite(Number(n)) ? Number(n) : d));

const q = (params: Record<string, string | undefined>) =>
  Object.entries(params)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${k}=${encodeURIComponent(v as string)}`)
    .join('&');

async function runTool(name: string, args: Record<string, any>, key: string) {
  switch (name) {
    case 'list_leads': {
      const status = args.status
        ? `eq.${args.status}`
        : args.open_only ? 'not.in.(won,lost)' : undefined;
      const path = `v_leads?${q({
        select: LEAD_FIELDS,
        status,
        company_name: args.search ? `ilike.*${args.search}*` : undefined,
        order: typeof args.order === 'string' ? args.order : 'score.desc',
        limit: String(clamp(args.limit, 50)),
      })}`;
      return crm(key, path);
    }
    case 'get_lead': {
      if (!args.id) throw new Error('Нужен id лида');
      return crm(key, `v_leads?${q({ id: `eq.${args.id}` })}`);
    }
    case 'list_activities':
      return crm(key, `activities?${q({
        select: 'id,lead_id,channel,outcome,with_dm,comment,status_from,status_to,created_at',
        lead_id: args.lead_id ? `eq.${args.lead_id}` : undefined,
        created_at: args.since ? `gte.${args.since}` : undefined,
        order: 'created_at.desc',
        limit: String(clamp(args.limit, 50)),
      })}`);
    case 'list_companies':
      return crm(key, `companies?${q({
        select: 'id,name,segment,address,outlets_count,avg_check,has_online_order,has_own_app,instagram_url',
        name: args.search ? `ilike.*${args.search}*` : undefined,
        order: 'name.asc',
        limit: String(clamp(args.limit, 50)),
      })}`);
    case 'list_tariffs':
      return crm(key, 'tariffs?select=code,title,setup_amount,mrr_amount&order=sort_order.asc');
    case 'check_write_rejected': {
      const r = await crm(key, 'leads', {
        method: 'POST',
        body: JSON.stringify({ company_id: '00000000-0000-0000-0000-000000000000' }),
      });
      const passed = r.status === 403 || r.status === 401;
      return {
        status: r.status,
        ok: true,
        body: {
          проверка: 'попытка создать лид тем же ключом',
          код_ответа: r.status,
          ответ_базы: r.body,
          итог: passed
            ? 'запись отклонена, доступ только на чтение'
            : 'ЗАПИСЬ ПРОШЛА — немедленно отозвать: revoke crm_readonly from authenticator',
        },
      };
    }
    default:
      throw new Error(`Неизвестный инструмент: ${name}`);
  }
}

// --- Протокол MCP ----------------------------------------------------------

const rpc = (id: unknown, result: unknown) => ({ jsonrpc: '2.0', id, result });
const rpcError = (id: unknown, code: number, message: string) =>
  ({ jsonrpc: '2.0', id, error: { code, message } });

async function handleMessage(msg: any, key: string) {
  const { id, method, params } = msg ?? {};

  if (method === 'initialize') {
    return rpc(id, {
      protocolVersion: typeof params?.protocolVersion === 'string' ? params.protocolVersion : PROTOCOL,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: NAME, version: VERSION },
      instructions:
        'Лиды отдела продаж Balance, только чтение. Записать через этот сервер нельзя: ' +
        'ключ выпущен на роль базы без единого права на запись.',
    });
  }
  if (method === 'ping') return rpc(id, {});
  if (method === 'tools/list') return rpc(id, { tools: TOOLS });

  if (method === 'tools/call') {
    const name = params?.name;
    if (!key) return rpcError(id, -32602, 'Не передан ключ доступа к CRM в заголовке Authorization');
    try {
      const r = await runTool(name, params?.arguments ?? {}, key);
      return rpc(id, {
        content: [{ type: 'text', text: JSON.stringify(r.body, null, 2) }],
        isError: !r.ok,
      });
    } catch (e) {
      return rpc(id, {
        content: [{ type: 'text', text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      });
    }
  }

  if (typeof method === 'string' && method.startsWith('notifications/')) return null;
  return rpcError(id, -32601, `Метод не поддерживается: ${method}`);
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') {
    return new Response('Только POST', { status: 405, headers: { ...CORS, Allow: 'POST, OPTIONS' } });
  }

  const auth = req.headers.get('authorization') ?? '';
  const key = auth.replace(/^Bearer\s+/i, '').trim();

  let msg: unknown;
  try { msg = await req.json(); } catch {
    return json(rpcError(null, -32700, 'Тело запроса не разобрано'), 400, req);
  }

  // Клиент вправе прислать пачку сообщений
  if (Array.isArray(msg)) {
    const out = (await Promise.all(msg.map((m) => handleMessage(m, key)))).filter(Boolean);
    return out.length ? json(out, 200, req) : new Response(null, { status: 202, headers: CORS });
  }

  const res = await handleMessage(msg, key);
  return res ? json(res, 200, req) : new Response(null, { status: 202, headers: CORS });
}

// Streamable HTTP: если клиент просит поток, отвечаем событием, иначе просто JSON.
function json(body: unknown, status: number, req: Request): Response {
  const wantsStream = (req.headers.get('accept') ?? '').includes('text/event-stream');
  if (wantsStream) {
    return new Response(`event: message\ndata: ${JSON.stringify(body)}\n\n`, {
      status,
      headers: { ...CORS, 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' },
    });
  }
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

(globalThis as any).Deno?.serve?.(handler);
