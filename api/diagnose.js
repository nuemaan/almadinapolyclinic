// Al Madina Polyclinic — AI clinical-assistant endpoint (Vercel serverless).
//
// Reads the consult details and returns a SUGGESTED diagnosis + weight-based
// treatment for the doctor to review. The Anthropic API key lives only here as a
// Vercel env var (ANTHROPIC_API_KEY) — never in the browser. The call is gated to
// logged-in staff: the request must carry a valid Supabase access token.
//
// Required Vercel env vars:
//   ANTHROPIC_API_KEY   — your Anthropic API key (sk-ant-...)
// Optional:
//   ANTHROPIC_MODEL     — defaults to claude-opus-4-8 (cost lever; can set
//                         claude-sonnet-4-6 or claude-haiku-4-5)
//   SUPABASE_URL        — defaults to the clinic project
//   SUPABASE_ANON_KEY   — defaults to the clinic anon key (public)

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lkgzbiulaoialezogizu.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxrZ3piaXVsYW9pYWxlem9naXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjM2OTksImV4cCI6MjA5NTg5OTY5OX0.r7FaiK6YzRnZWp5OWx9n_soYUQsQghFWINh7TX-H6AE';
const MODEL = process.env.ANTHROPIC_MODEL || 'claude-opus-4-8';

const SYSTEM_PROMPT = `You are a clinical decision-support assistant for a busy pediatric & general polyclinic in Kashmir, India (Al Madina Polyclinic). A qualified doctor uses you while seeing a patient. You read the case details the doctor enters and propose the MOST LIKELY diagnosis and a practical, weight-based treatment plan.

Rules:
- You ASSIST; the treating doctor makes every final decision. Be concise and practical, not a textbook.
- Dose everything by weight where a weight is given (e.g. "Cefixime 8 mg/kg/day divided BD"). If no weight is given, give the usual mg/kg/dose and say weight is needed to finalise.
- Prefer drugs and formulations commonly available in India (syrups/drops for young children). Use generic names; a brand in brackets is optional.
- Always include a short antipyretic/supportive line when there is fever, and clear red-flag/referral advice.
- If the information is insufficient to be confident, say so in "advice" and suggest what to check — do not invent findings.
- Keep it safe: avoid contraindicated combos, flag drug allergies if mentioned, and never recommend anything you are unsure is appropriate for the age.
- Output ONLY the JSON object that matches the provided schema. No prose outside it.`;

const SCHEMA = {
  type: 'object',
  properties: {
    diagnosis: { type: 'string', description: 'The single most likely diagnosis.' },
    differentials: { type: 'array', items: { type: 'string' }, description: 'Other possibilities to consider.' },
    investigations: { type: 'array', items: { type: 'string' }, description: 'Tests that would help, if any.' },
    treatment: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          medicine: { type: 'string' },
          dose: { type: 'string', description: 'Weight-based where possible, e.g. "5 mg/kg/dose".' },
          route: { type: 'string' },
          frequency: { type: 'string' },
          duration: { type: 'string' }
        },
        required: ['medicine', 'dose'],
        additionalProperties: false
      }
    },
    advice: { type: 'string', description: 'Supportive care, follow-up, and what to check if unsure.' },
    red_flags: { type: 'array', items: { type: 'string' }, description: 'Warning signs that need urgent review/referral.' }
  },
  required: ['diagnosis', 'treatment', 'advice'],
  additionalProperties: false
};

async function verifyStaff(token) {
  if (!token) return false;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY },
    });
    return r.ok;
  } catch { return false; }
}

function buildCase(b) {
  const ageBits = [];
  if (b.age_years)  ageBits.push(`${b.age_years} years`);
  if (b.age_months) ageBits.push(`${b.age_months} months`);
  if (b.age_days)   ageBits.push(`${b.age_days} days`);
  const lines = [];
  lines.push(`Age: ${ageBits.join(' ') || 'not given'}`);
  if (b.gender)      lines.push(`Sex: ${b.gender}`);
  if (b.weight)      lines.push(`Weight: ${b.weight} kg`);
  if (b.temperature) lines.push(`Temperature: ${b.temperature} °F`);
  if (b.complaint)   lines.push(`Complaint: ${b.complaint}`);
  const exam = [];
  if (b.exam_general) exam.push(`General: ${b.exam_general}`);
  if (b.exam_chest)   exam.push(`Chest: ${b.exam_chest}`);
  if (b.exam_abdomen) exam.push(`Abdomen: ${b.exam_abdomen}`);
  if (b.exam_cvs)     exam.push(`CVS: ${b.exam_cvs}`);
  if (b.exam_other)   exam.push(`Other: ${b.exam_other}`);
  if (exam.length)    lines.push(`Examination — ${exam.join('; ')}`);
  if (b.investigations) lines.push(`Investigations/results: ${b.investigations}`);
  if (b.notes)        lines.push(`Notes: ${b.notes}`);
  return lines.join('\n');
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) { res.status(503).json({ error: 'AI is not configured yet. Ask the admin to set ANTHROPIC_API_KEY.' }); return; }

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!(await verifyStaff(token))) { res.status(401).json({ error: 'Not authorized — please sign in to the console.' }); return; }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  body = body || {};
  const caseText = buildCase(body);
  if (!body.complaint && !body.investigations) {
    res.status(400).json({ error: 'Enter at least a complaint or an investigation result first.' });
    return;
  }

  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1024,
        system: [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
        output_config: { format: { type: 'json_schema', schema: SCHEMA } },
        messages: [{ role: 'user', content: `Patient case:\n${caseText}` }],
      }),
    });
    const data = await r.json();
    if (!r.ok) {
      res.status(502).json({ error: data?.error?.message || 'AI request failed.' });
      return;
    }
    const textBlock = (data.content || []).find((b) => b.type === 'text');
    let suggestion;
    try { suggestion = JSON.parse(textBlock ? textBlock.text : '{}'); }
    catch { res.status(502).json({ error: 'Could not read the AI response.' }); return; }
    res.status(200).json({ suggestion, model: data.model });
  } catch (e) {
    res.status(502).json({ error: 'Could not reach the AI service. Try again.' });
  }
};
