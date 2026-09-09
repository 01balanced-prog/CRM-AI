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

// Публичный ключ проекта — тот же, что лежит открыто в index.html. Шлюз Supabase
// требует в заголовке apikey зарегистрированный ключ проекта и отбивает любой
// самодельный JWT, не доходя до базы. Прав он не даёт никаких: роль решает
// заголовок Authorization, а без него это анонимный доступ, которому RLS
// не отдаёт ни строки.
const GATEWAY_KEY = env('CRM_GATEWAY_KEY', 'sb_publishable_AWo5r5fudoIWayLflnZOeQ_s5Db1q2C');
const NAME = 'balance-crm-readonly';
const VERSION = '1.0.0';
const PROTOCOL = '2025-06-18';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, mcp-protocol-version, mcp-session-id',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// --- Инструменты -----------------------------------------------------------

const LIMIT = { type: 'integer', minimum: 1, maximum: 1000, default: 100,
                description: 'Сколько строк вернуть, по умолчанию 100' };
const OFFSET = { type: 'integer', minimum: 0, default: 0,
                 description: 'Сколько строк пропустить. Следующая страница: offset = offset + limit' };
const FIELDS = { type: 'string',
                 description: 'Оставить только эти колонки, через запятую. По умолчанию все' };

const TOOLS = [
  {
    name: 'list_leads',
    description:
      'Лиды CRM целиком: заведение, ЛПР, статус сделки, уровень контакта (level), ' +
      'тариф, суммы внедрения и подписки, этапы оплаты и даты платежей, ' +
      'дата следующего шага, число касаний, заметка по лиду, дата заведения. ' +
      'Основной инструмент.',
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
        segment: { type: 'string', description: 'Сегмент: Суши, Пицца, Кафе и рестораны и так далее' },
        level: {
          type: 'string',
          enum: ['administrator', 'manager', 'owner'],
          description: 'Самый высокий уровень контакта по лиду',
        },
        since: { type: 'string', description: 'Заведён не раньше этой даты, например 2026-08-01' },
        order: { type: 'string', default: 'score.desc',
                 description: 'Сортировка: колонка.asc или колонка.desc' },
        fields: FIELDS,
        limit: LIMIT,
        offset: OFFSET,
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
    description:
      'Журнал касаний: звонки, переписки, системные записи о смене статуса и оплате. ' +
      'Кроме текста заметки отдаёт, с кем говорили (spoke_with), какое демо отправлено ' +
      '(demo), какой скрипт и какое возражение применялись (script_id, objection_id) ' +
      'и кто автор касания (author_id).',
    inputSchema: {
      type: 'object',
      properties: {
        lead_id: { type: 'string', description: 'Касания одного лида' },
        author_id: { type: 'string', description: 'Касания одного сотрудника' },
        channel: {
          type: 'string',
          enum: ['call', 'whatsapp', 'instagram', 'meeting', 'other', 'system'],
          description: 'Канал касания. system — записи, которые база пишет сама',
        },
        outcome: {
          type: 'string',
          enum: ['answered', 'no_answer', 'callback', 'refused', 'sent', 'other'],
          description: 'Исход касания',
        },
        spoke_with: {
          type: 'string',
          enum: ['administrator', 'manager', 'owner'],
          description: 'С кем говорили: администратор, управляющий, собственник',
        },
        with_dm: { type: 'boolean', description: 'Только разговоры с ЛПР' },
        since: { type: 'string', description: 'С этой даты, например 2026-09-01' },
        until: { type: 'string', description: 'По эту дату включительно' },
        fields: FIELDS,
        limit: LIMIT,
        offset: OFFSET,
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
        segment: { type: 'string', description: 'Сегмент' },
        fields: FIELDS,
        limit: LIMIT,
        offset: OFFSET,
      },
    },
  },
  {
    name: 'list_tariffs',
    description: 'Тарифы: единственный источник сумм внедрения и подписки.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'list_scripts',
    description:
      'Тексты, по которым работает менеджер: скрипты звонков (kind=script), ' +
      'ответы на возражения (kind=objection) и шаблоны сообщений в WhatsApp ' +
      '(kind=message). Отдаёт формулировки целиком. Связываются с касаниями ' +
      'через script_id и objection_id.',
    inputSchema: {
      type: 'object',
      properties: {
        kind: { type: 'string', enum: ['script', 'objection', 'message'],
                description: 'Скрипт, возражение или шаблон сообщения' },
        stage: {
          type: 'string',
          enum: ['first_call', 'gatekeeper', 'brief', 'after_proposal', 'closing', 'callback'],
          description: 'Этап разговора',
        },
        segment: { type: 'string', description: 'Сегмент, под который написан текст' },
        active_only: { type: 'boolean', default: true,
                       description: 'Только включённые. false — вместе с выключенными' },
        limit: LIMIT,
        offset: OFFSET,
      },
    },
  },
  {
    name: 'list_lessons',
    description:
      'Обучение: уроки с текстом и вопросами, плюс кто их сдал и с каким счётом.',
    inputSchema: {
      type: 'object',
      properties: {
        module: { type: 'string', enum: ['product', 'sales', 'crm'],
                  description: 'Модуль обучения' },
        with_progress: { type: 'boolean', default: true,
                         description: 'Добавить, кто какой урок сдал' },
        limit: LIMIT,
      },
    },
  },
  {
    name: 'list_team',
    description:
      'Отдел: сотрудники, их план и факт на сегодня — звонки, разговоры, разговоры ' +
      'с ЛПР, взятые лиды, брифы и КП за неделю, сделки и деньги за месяц. ' +
      'Плюс невыполненные приглашения.',
    inputSchema: {
      type: 'object',
      properties: {
        with_invites: { type: 'boolean', default: false,
                        description: 'Добавить приглашения в отдел' },
      },
    },
  },
  {
    name: 'list_kpi',
    description:
      'Показатели по сотрудникам за период: день (звонки, разговоры, разговоры с ЛПР, ' +
      'взятые лиды), неделя (брифы, КП), месяц (сделки, деньги). Для динамики ' +
      'и сравнения с планом из list_team.',
    inputSchema: {
      type: 'object',
      properties: {
        period: { type: 'string', enum: ['day', 'week', 'month'], default: 'day',
                  description: 'Разрез: по дням, неделям или месяцам' },
        profile_id: { type: 'string', description: 'Один сотрудник' },
        since: { type: 'string', description: 'С этой даты' },
        limit: LIMIT,
        offset: OFFSET,
      },
    },
  },
  {
    name: 'list_plans',
    description:
      'Нормы: план по умолчанию, ступени разгона новичка по неделям и персональные ' +
      'планы на месяц. То, с чем сравниваются показатели из list_kpi.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'list_custom_pricing',
    description:
      'Ручные цены: лиды, которым админ назначил сумму мимо прайса. Обычно список ' +
      'пуст — суммы считаются из тарифов триггером.',
    inputSchema: { type: 'object', properties: { limit: LIMIT } },
  },
  {
    name: 'list_coaching_notes',
    description: 'Замечания наставника к касаниям и лидам.',
    inputSchema: {
      type: 'object',
      properties: {
        to_id: { type: 'string', description: 'Замечания одному сотруднику' },
        lead_id: { type: 'string', description: 'Замечания по одному лиду' },
        since: { type: 'string', description: 'С этой даты' },
        limit: LIMIT,
        offset: OFFSET,
      },
    },
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

// Ключ вида sb_… шлюз понимает сам и роль по нему определяет тоже сам.
// Ключ-JWT (crm_readonly) идёт в Authorization, а шлюзу подаётся публичный ключ.
const authHeaders = (key: string) =>
  key.startsWith('sb_')
    ? { apikey: key }
    : { apikey: GATEWAY_KEY, Authorization: `Bearer ${key}` };

// Ответ 403 с кодом 42501 на чтение означает одно из двух: миграция не применена
// или права позже отобрали. Без подсказки это читается как поломка сервера.
const HINT = 'Нет прав на чтение. Выполнить в SQL Editor db/12_readonly.sql, ' +
             'затем db/17_readonly_full.sql — он открывает скрипты, уроки, планы, ' +
             'показатели и замечания наставника.';

async function crm(key: string, path: string, init: RequestInit = {}, count = false) {
  const r = await fetch(`${CRM_API}/${path}`, {
    ...init,
    headers: {
      ...authHeaders(key),
      'Content-Type': 'application/json',
      ...(count ? { Prefer: 'count=exact' } : {}),
      ...(init.headers ?? {}),
    },
  });
  const text = await r.text();
  let body: unknown = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }

  // PostgREST отдаёт общее число строк в Content-Range: «0-99/1543».
  // Без него по короткому ответу не понять, вся это выборка или первая страница.
  const total = Number((r.headers.get('content-range') ?? '').split('/')[1]);
  if (count && Number.isFinite(total) && Array.isArray(body)) {
    return { status: r.status, ok: r.ok, body: { всего: total, показано: body.length, строки: body } };
  }
  if (!r.ok && (init.method ?? 'GET') === 'GET') {
    const code = (body as any)?.code;
    if (code === '42501') {
      return { status: r.status, ok: false, body: { ...(body as object), подсказка: HINT } };
    }
    // 00_baseline.sql — схема, восстановленная по коду клиента, а не выгрузка:
    // часть объектов из него в живой базе так и не завели (custom_pricing
    // клиент не использует вовсе). Пустой ответ честнее ошибки: спрашивали
    // то, чего нет, а не упёрлись в права.
    if (code === 'PGRST205' || code === '42P01') {
      return { status: 200, ok: true,
               body: { всего: 0, показано: 0, строки: [],
                       примечание: 'Этого объекта в базе нет — в живой схеме он не заводился' } };
    }
  }
  return { status: r.status, ok: r.ok, body };
}

const clamp = (n: unknown, d: number, max = 1000) =>
  Math.min(max, Math.max(1, Number.isFinite(Number(n)) ? Number(n) : d));

const skip = (n: unknown) =>
  Math.max(0, Number.isFinite(Number(n)) ? Math.trunc(Number(n)) : 0);

const q = (params: Record<string, string | undefined>) =>
  Object.entries(params)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${k}=${encodeURIComponent(v as string)}`)
    .join('&');

// Общая часть каждого списка: сколько строк, с какой позиции, какие колонки.
const page = (args: Record<string, any>, fallback = '*') => ({
  select: typeof args.fields === 'string' && args.fields.trim() ? args.fields.trim() : fallback,
  limit: String(clamp(args.limit, 100)),
  offset: skip(args.offset) ? String(skip(args.offset)) : undefined,
});

// Диапазон дат по created_at. PostgREST принимает только одно значение на ключ,
// поэтому обе границы уходят в and(...).
const period = (since?: string, until?: string) =>
  since && until ? { and: `(created_at.gte.${since},created_at.lte.${until} 23:59:59)` }
  : since ? { created_at: `gte.${since}` }
  : until ? { created_at: `lte.${until} 23:59:59` }
  : {};

async function runTool(name: string, args: Record<string, any>, key: string) {
  switch (name) {
    case 'list_leads': {
      const status = args.status
        ? `eq.${args.status}`
        : args.open_only ? 'not.in.(won,lost)' : undefined;
      return crm(key, `v_leads?${q({
        ...page(args),
        status,
        segment: args.segment ? `eq.${args.segment}` : undefined,
        level: args.level ? `eq.${args.level}` : undefined,
        created_at: args.since ? `gte.${args.since}` : undefined,
        company_name: args.search ? `ilike.*${args.search}*` : undefined,
        order: typeof args.order === 'string' ? args.order : 'score.desc',
      })}`, {}, true);
    }
    case 'get_lead': {
      if (!args.id) throw new Error('Нужен id лида');
      return crm(key, `v_leads?${q({ id: `eq.${args.id}` })}`);
    }
    case 'list_activities':
      return crm(key, `activities?${q({
        ...page(args, 'id,lead_id,author_id,channel,outcome,spoke_with,with_dm,demo,' +
                      'comment,script_id,objection_id,status_from,status_to,created_at'),
        ...period(args.since, args.until),
        lead_id: args.lead_id ? `eq.${args.lead_id}` : undefined,
        author_id: args.author_id ? `eq.${args.author_id}` : undefined,
        channel: args.channel ? `eq.${args.channel}` : undefined,
        outcome: args.outcome ? `eq.${args.outcome}` : undefined,
        spoke_with: args.spoke_with ? `eq.${args.spoke_with}` : undefined,
        with_dm: args.with_dm === true ? 'is.true' : undefined,
        order: 'created_at.desc',
      })}`, {}, true);
    case 'list_companies':
      return crm(key, `companies?${q({
        ...page(args, 'id,name,segment,address,outlets_count,avg_check,' +
                      'has_online_order,has_own_app,instagram_url,gis_url,site_url,note'),
        name: args.search ? `ilike.*${args.search}*` : undefined,
        segment: args.segment ? `eq.${args.segment}` : undefined,
        order: 'name.asc',
      })}`, {}, true);
    case 'list_tariffs':
      return crm(key, 'tariffs?select=code,title,setup_amount,mrr_amount&order=sort_order.asc');
    case 'list_scripts':
      return crm(key, `scripts?${q({
        ...page(args, 'id,kind,stage,segment,title,body,sort_order,active,updated_at'),
        kind: args.kind ? `eq.${args.kind}` : undefined,
        stage: args.stage ? `eq.${args.stage}` : undefined,
        segment: args.segment ? `eq.${args.segment}` : undefined,
        active: args.active_only === false ? undefined : 'is.true',
        order: 'kind.asc,sort_order.asc',
      })}`, {}, true);
    case 'list_lessons': {
      const lessons = await crm(key, `lessons?${q({
        select: 'id,module,title,body,questions,due_week,sort_order,active',
        module: args.module ? `eq.${args.module}` : undefined,
        order: 'module.asc,sort_order.asc',
        limit: String(clamp(args.limit, 100)),
      })}`);
      if (!lessons.ok || args.with_progress === false) return lessons;
      const progress = await crm(key,
        'lesson_progress?select=profile_id,lesson_id,passed_at,score,total&order=passed_at.desc&limit=1000');
      return { status: 200, ok: true, body: { уроки: lessons.body, сдано: progress.body } };
    }
    case 'list_team': {
      const team = await crm(key,
        'v_team_today?select=*&order=name.asc');
      if (!team.ok || args.with_invites !== true) return team;
      const invites = await crm(key,
        'invites?select=email,name,role,created_at,used_at&order=created_at.desc&limit=100');
      return { status: 200, ok: true, body: { команда: team.body, приглашения: invites.body } };
    }
    case 'list_kpi': {
      const view = args.period === 'week' ? 'v_kpi_week'
                 : args.period === 'month' ? 'v_kpi_month'
                 : 'v_kpi_day';
      const col = view === 'v_kpi_day' ? 'day' : view === 'v_kpi_week' ? 'week_start' : 'month';
      return crm(key, `${view}?${q({
        select: '*',
        profile_id: args.profile_id ? `eq.${args.profile_id}` : undefined,
        [col]: args.since ? `gte.${args.since}` : undefined,
        order: `${col}.desc`,
        limit: String(clamp(args.limit, 100)),
        offset: skip(args.offset) ? String(skip(args.offset)) : undefined,
      })}`, {}, true);
    }
    case 'list_plans': {
      const [def, ramp, plans] = await Promise.all([
        crm(key, 'plan_defaults?select=*'),
        crm(key, 'ramp_steps?select=week,pct&order=week.asc'),
        crm(key, 'plans?select=*&order=month.desc&limit=200'),
      ]);
      const bad = [def, ramp, plans].find((r) => !r.ok);
      if (bad) return bad;
      return { status: 200, ok: true,
               body: { норма_по_умолчанию: def.body, разгон_по_неделям: ramp.body,
                       персональные_планы: plans.body } };
    }
    case 'list_custom_pricing':
      return crm(key, `custom_pricing?${q({
        select: 'lead_id,setup_amount,mrr_amount,set_by,created_at',
        order: 'created_at.desc',
        limit: String(clamp(args.limit, 100)),
      })}`, {}, true);
    case 'list_coaching_notes':
      return crm(key, `coaching_notes?${q({
        select: 'id,from_id,to_id,activity_id,lead_id,text,created_at,read_at',
        created_at: args.since ? `gte.${args.since}` : undefined,
        to_id: args.to_id ? `eq.${args.to_id}` : undefined,
        lead_id: args.lead_id ? `eq.${args.lead_id}` : undefined,
        order: 'created_at.desc',
        limit: String(clamp(args.limit, 100)),
        offset: skip(args.offset) ? String(skip(args.offset)) : undefined,
      })}`, {}, true);
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
