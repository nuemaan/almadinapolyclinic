// Al Madina Polyclinic — AI clinical-assistant endpoint (Vercel serverless).
//
// Uses Google Gemini's FREE API tier. Reads the consult details and returns a
// SUGGESTED diagnosis + weight-based treatment for the doctor to review. Only
// de-identified clinical facts are sent (NO patient name or phone). The API key
// lives only here as a Vercel env var — never in the browser. The call is gated
// to logged-in staff (must carry a valid Supabase access token).
//
// Required Vercel env var:
//   GEMINI_API_KEY   — free key from https://aistudio.google.com/apikey
// Optional:
//   GEMINI_MODEL     — defaults to gemini-2.0-flash (free, fast)
//   SUPABASE_URL / SUPABASE_ANON_KEY — default to the clinic project (public)

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://lkgzbiulaoialezogizu.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxrZ3piaXVsYW9pYWxlem9naXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjM2OTksImV4cCI6MjA5NTg5OTY5OX0.r7FaiK6YzRnZWp5OWx9n_soYUQsQghFWINh7TX-H6AE';
const MODEL = process.env.GEMINI_MODEL || 'gemini-2.5-flash';

const SYSTEM_PROMPT = `You are a clinical decision-support assistant for a busy pediatric & general polyclinic in Kashmir, India (Al Madina Polyclinic). A qualified doctor uses you while seeing a patient. You read the case details the doctor enters and propose the MOST LIKELY diagnosis and a practical, weight-based treatment plan.

Rules:
- You ASSIST; the treating doctor makes every final decision. Be concise and practical, not a textbook.
- Dose everything by weight where a weight is given (e.g. "Cefixime 8 mg/kg/day divided BD"). If no weight is given, give the usual mg/kg/dose and say weight is needed to finalise.
- Prefer drugs and formulations commonly available in India (syrups/drops for young children). Use generic names; a brand in brackets is optional.
- Always include a short antipyretic/supportive line when there is fever, and clear red-flag/referral advice.
- If the information is insufficient to be confident, say so in "advice" and suggest what to check — do not invent findings.
- Keep it safe: avoid contraindicated combos, flag drug allergies if mentioned, and never recommend anything you are unsure is appropriate for the age.
- Output ONLY the JSON object that matches the provided schema.`;

// Gemini responseSchema (OpenAPI-style, uppercase types).
const SCHEMA = {
  type: 'OBJECT',
  properties: {
    diagnosis: { type: 'STRING' },
    differentials: { type: 'ARRAY', items: { type: 'STRING' } },
    investigations: { type: 'ARRAY', items: { type: 'STRING' } },
    treatment: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          medicine: { type: 'STRING' },
          dose: { type: 'STRING' },
          route: { type: 'STRING' },
          frequency: { type: 'STRING' },
          duration: { type: 'STRING' },
        },
        required: ['medicine', 'dose'],
      },
    },
    advice: { type: 'STRING' },
    red_flags: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['diagnosis', 'treatment', 'advice'],
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

const SAFETY = ['HARM_CATEGORY_HARASSMENT', 'HARM_CATEGORY_HATE_SPEECH', 'HARM_CATEGORY_SEXUALLY_EXPLICIT', 'HARM_CATEGORY_DANGEROUS_CONTENT']
  .map((category) => ({ category, threshold: 'BLOCK_NONE' }));

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) { res.status(503).json({ error: 'AI is not configured yet. Ask the admin to set GEMINI_API_KEY.' }); return; }

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!(await verifyStaff(token))) { res.status(401).json({ error: 'Not authorized — please sign in to the console.' }); return; }

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  body = body || {};
  if (!body.complaint && !body.investigations) {
    res.status(400).json({ error: 'Enter at least a complaint or an investigation result first.' });
    return;
  }
  const caseText = buildCase(body);

  try {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${encodeURIComponent(apiKey)}`;
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents: [{ role: 'user', parts: [{ text: `Patient case:\n${caseText}` }] }],
        safetySettings: SAFETY,
        generationConfig: {
          responseMimeType: 'application/json',
          responseSchema: SCHEMA,
          temperature: 0.2,
          maxOutputTokens: 2048,
          // 2.5-flash is a "thinking" model — disable thinking so the output
          // budget produces the JSON (otherwise it spends it all reasoning).
          thinkingConfig: { thinkingBudget: 0 },
        },
      }),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      res.status(502).json({ error: (data && data.error && data.error.message) || 'AI request failed.' });
      return;
    }
    const cand = (data.candidates || [])[0];
    const text = cand && cand.content && cand.content.parts && cand.content.parts[0] && cand.content.parts[0].text;
    if (!text) { res.status(502).json({ error: 'The AI could not produce a suggestion for this case. Try adding more detail.' }); return; }
    let suggestion;
    try { suggestion = JSON.parse(text); }
    catch { res.status(502).json({ error: 'Could not read the AI response.' }); return; }
    res.status(200).json({ suggestion, model: MODEL });
  } catch (e) {
    res.status(502).json({ error: 'Could not reach the AI service. Try again.' });
  }
};
