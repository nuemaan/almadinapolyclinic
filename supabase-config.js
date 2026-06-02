// Shared Supabase client for Al Madina Polyclinic.
// The anon key is SAFE to expose publicly — it only grants what the database's
// Row-Level Security policies allow (read the public queue board + call the
// take_token / queue_status / get_lab_by_code functions). All real patient
// data stays locked to logged-in staff.
(function () {
  const SUPABASE_URL = 'https://lkgzbiulaoialezogizu.supabase.co';
  const SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxrZ3piaXVsYW9pYWxlem9naXp1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMjM2OTksImV4cCI6MjA5NTg5OTY5OX0.r7FaiK6YzRnZWp5OWx9n_soYUQsQghFWINh7TX-H6AE';

  if (!window.supabase || !window.supabase.createClient) {
    console.error('Supabase JS library not loaded before supabase-config.js');
    return;
  }
  // Patient-facing pages set window.SUPABASE_ANON_ONLY = true so they never
  // inherit (or persist) a staff login that might be in this browser — their
  // calls always run as the anon role, isolated by a separate storage key.
  const anonOnly = !!window.SUPABASE_ANON_ONLY;
  window.supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: anonOnly
      ? { persistSession: false, autoRefreshToken: false, storageKey: 'sb-almadina-anon' }
      : { persistSession: true, autoRefreshToken: true },
  });
  window.SUPABASE_URL = SUPABASE_URL;
})();
