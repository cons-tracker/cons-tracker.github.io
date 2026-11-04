/* Supabase connection settings
   Find them in Supabase Dashboard → Project Settings → API (or "Connect")
   - supabaseUrl      : Project URL, e.g. https://abcd1234.supabase.co
   - supabaseAnonKey  : the anon / publishable key (safe to put in the browser; data is protected by RLS)
   Never put the service_role / secret key here.
   If both fields are empty, the app runs in local mode (data stays only in this browser) */
window.HWPROG_CONFIG = {
  supabaseUrl: 'https://gzhtycobzbybifkobnuw.supabase.co',
  supabaseAnonKey: 'sb_publishable_2W7ol8Ij71YxsYS-Vsdzkg_NKxs3cs5',
  loginDomain: 'hw5.local'   /* username "somchai" → somchai@hw5.local in Supabase Auth */
};
