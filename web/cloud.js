/* =====================================================================
   cloud.js — connects the construction tracker to Supabase
   - The app still reads and writes localStorage as before (works offline too)
   - This file pulls data from Supabase into localStorage before the app starts,
     and sends every change the app writes up to Supabase (one row per project)
   - Login, user management, and passwords go through Supabase Auth
   ===================================================================== */
(function () {
  'use strict';
  var cfg = window.HWPROG_CONFIG || {};
  var LS = window.localStorage;
  var KEY = 'hwprog_v1', KEY_SESSION = 'hwprog_session', KEY_PEOPLE = 'hwprog_people',
      KEY_LOG = 'hwprog_log', KEY_USERS = 'hwprog_users', KEY_OUTBOX = 'hwprog_outbox',
      FLAGS = { dstAdded: true, dstV2: true, dstV3: true, dstV4: true, dstV5: true };

  var cloud = window.hwCloud = { enabled: false };
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey || !window.supabase || !window.supabase.createClient) {
    if (cfg.supabaseUrl) console.warn('[cloud] could not load the Supabase library — running in local mode');
    window.__cloudReady = Promise.resolve();
    return;
  }

  var sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, storageKey: 'hwprog-auth' }
  });
  cloud.enabled = true;
  cloud.client = sb;
  var DOMAIN = cfg.loginDomain || 'hw5.local';
  cloud.emailOf = function (u) { u = String(u || '').trim().toLowerCase(); return u.indexOf('@') >= 0 ? u : (u + '@' + DOMAIN); };

  /* ---------- helpers ---------- */
  var rawSet = Storage.prototype.setItem, rawRemove = Storage.prototype.removeItem;
  function lsSet(k, v) { try { rawSet.call(LS, k, v); } catch (e) {} }
  function lsGet(k) { try { return LS.getItem(k); } catch (e) { return null; } }
  function lsDel(k) { try { rawRemove.call(LS, k); } catch (e) {} }
  function parse(s, d) { try { var v = JSON.parse(s); return v == null ? d : v; } catch (e) { return d; } }
  /* JSON with sorted keys — Postgres jsonb reorders keys, so comparing data needs a stable form */
  function stable(v) {
    if (Array.isArray(v)) return '[' + v.map(stable).join(',') + ']';
    if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(function (k) { return JSON.stringify(k) + ':' + stable(v[k]); }).join(',') + '}';
    return JSON.stringify(v === undefined ? null : v);
  }
  function emit(name, detail) { try { window.dispatchEvent(new CustomEvent(name, { detail: detail })); } catch (e) {} }
  function errText(e) { return (e && (e.message || e.error_description || e.msg)) || String(e || ''); }

  /* ---------- status badge ---------- */
  var badgeEl = null, badgeT = null;
  function badge(text, tone, sticky) {
    if (!document.body) return;
    if (!badgeEl || !document.body.contains(badgeEl)) {
      badgeEl = document.createElement('div');
      badgeEl.className = 'noprint';
      badgeEl.style.cssText = 'position:fixed;left:50%;bottom:14px;transform:translateX(-50%);z-index:20000;padding:7px 15px;border-radius:999px;font:600 12.5px/1.3 "IBM Plex Sans Thai",sans-serif;box-shadow:0 2px 10px rgba(0,0,0,.18);pointer-events:none;transition:opacity .25s;max-width:90vw;text-align:center';
      document.body.appendChild(badgeEl);
    }
    var c = tone === 'err' ? ['#fdecea', '#8f1d12'] : tone === 'warn' ? ['#fdf3e0', '#8a5a00'] : ['#e8f6ed', '#1b7a4b'];
    badgeEl.style.background = c[0]; badgeEl.style.color = c[1];
    badgeEl.textContent = text; badgeEl.style.opacity = '1';
    clearTimeout(badgeT);
    if (!sticky) badgeT = setTimeout(function () { if (badgeEl) badgeEl.style.opacity = '0'; }, 2200);
  }
  cloud.badge = badge;

  /* ---------- state ---------- */
  var known = {};          // id -> stable(data) as last seen on the server
  var user = null, profile = null;
  var outbox = parse(lsGet(KEY_OUTBOX), {}); // id -> data | null (delete) not yet sent
  var lastLogT = 0;

  function sessionObj() {
    return profile ? { u: profile.username, role: profile.role, name: profile.name || profile.username, id: profile.id } : null;
  }
  function writeSession() {
    var s = sessionObj();
    if (s) lsSet(KEY_SESSION, JSON.stringify(s)); else lsDel(KEY_SESSION);
  }
  cloud.session = sessionObj;
  cloud.canWrite = function () { return !!profile && ['admin', 'clerk', 'field'].indexOf(profile.role) >= 0; };

  async function loadProfile() {
    var r = await sb.auth.getSession();
    user = (r.data && r.data.session && r.data.session.user) || null;
    profile = null;
    if (user) {
      var q = await sb.from('profiles').select('id,username,name,role').eq('id', user.id).maybeSingle();
      if (q.error) throw q.error;
      profile = q.data || null;
    }
    writeSession();
  }

  async function pullProjects() {
    var q = await sb.from('projects').select('id,data');
    if (q.error) throw q.error;
    var list = [];
    known = {};
    (q.data || []).forEach(function (row) {
      if (!row || !row.data) return;
      var d = row.data; d.id = row.id;
      known[row.id] = stable(d);
      list.push(d);
    });
    /* local edits not sent yet (made offline) — apply on top */
    Object.keys(outbox).forEach(function (id) {
      var ix = list.findIndex(function (p) { return p.id === id; });
      if (outbox[id] === null) { if (ix >= 0) list.splice(ix, 1); }
      else if (ix >= 0) list[ix] = outbox[id]; else list.push(outbox[id]);
    });
    lsSet(KEY, JSON.stringify(Object.assign({ projects: list }, FLAGS)));
  }

  async function pullExtras() {
    if (!user) return;
    var kv = await sb.from('app_kv').select('value').eq('key', 'people').maybeSingle();
    if (!kv.error && kv.data && Array.isArray(kv.data.value)) lsSet(KEY_PEOPLE, JSON.stringify(kv.data.value));
    var lg = await sb.from('edit_log').select('t,who,what').order('t', { ascending: false }).limit(40);
    if (!lg.error && lg.data) {
      var arr = lg.data.map(function (x) { return { t: Date.parse(x.t), who: x.who, what: x.what }; });
      lastLogT = arr.length ? arr[0].t : 0;
      lsSet(KEY_LOG, JSON.stringify(arr));
    }
  }

  /* ---------- push changes (debounced) ---------- */
  var pushT = null, pushing = false, again = false, deniedShown = false;
  function saveOutbox() { if (Object.keys(outbox).length) lsSet(KEY_OUTBOX, JSON.stringify(outbox)); else lsDel(KEY_OUTBOX); }

  function queueFromLocal(json) {
    var d = parse(json, null);
    if (!d || !Array.isArray(d.projects)) return;
    var seen = {};
    d.projects.forEach(function (p) {
      if (!p || !p.id || p.isDraftNew) return;
      seen[p.id] = 1;
      var s = stable(p);
      if (known[p.id] !== s) outbox[p.id] = p; else delete outbox[p.id];
    });
    Object.keys(known).forEach(function (id) { if (!seen[id]) outbox[id] = null; });
    saveOutbox();
    schedulePush();
  }
  function schedulePush() { clearTimeout(pushT); pushT = setTimeout(flush, 500); }

  async function flush() {
    if (pushing) { again = true; return; }
    var ids = Object.keys(outbox);
    if (!ids.length) return;
    if (!cloud.canWrite()) {
      if (!deniedShown) { badge('ยังไม่ได้เข้าสู่ระบบด้วยบัญชีที่แก้ไขได้ — การแก้ไขนี้ไม่ถูกบันทึกขึ้นเซิร์ฟเวอร์', 'warn'); deniedShown = true; }
      outbox = {}; saveOutbox(); return;
    }
    if (navigator.onLine === false) { badge('ออฟไลน์ — จะส่งข้อมูลเมื่อกลับมาออนไลน์', 'warn', true); return; }
    pushing = true;
    badge('กำลังบันทึกขึ้นเซิร์ฟเวอร์…', 'ok', true);
    var failed = null;
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i], data = outbox[id];
      if (!(id in outbox)) continue;
      try {
        var r = data === null
          ? await sb.from('projects').delete().eq('id', id)
          : await sb.from('projects').upsert({ id: id, data: data });
        if (r.error) throw r.error;
        if (outbox[id] === data) delete outbox[id];
        if (data === null) delete known[id]; else known[id] = stable(data);
      } catch (e) { failed = e; break; }
    }
    saveOutbox();
    pushing = false;
    if (failed) {
      var m = errText(failed);
      if (/row-level security|permission|42501/i.test(m)) { outbox = {}; saveOutbox(); badge('บันทึกไม่สำเร็จ: บัญชีนี้ไม่มีสิทธิ์แก้ไข', 'err'); }
      else badge('บันทึกไม่สำเร็จ — จะลองใหม่อัตโนมัติ (' + m + ')', 'err', true), setTimeout(flush, 8000);
      return;
    }
    badge('บันทึกขึ้นเซิร์ฟเวอร์แล้ว', 'ok');
    if (again) { again = false; schedulePush(); }
  }
  window.addEventListener('online', function () { if (Object.keys(outbox).length) flush(); });

  var peopleT = null;
  function pushPeople(json) {
    clearTimeout(peopleT);
    peopleT = setTimeout(async function () {
      if (!cloud.canWrite()) return;
      var r = await sb.from('app_kv').upsert({ key: 'people', value: parse(json, []) });
      if (r.error) badge('บันทึกรายชื่อบุคคลไม่สำเร็จ: ' + errText(r.error), 'err');
    }, 600);
  }
  function pushLog(json) {
    if (!cloud.canWrite()) return;
    var arr = parse(json, []);
    var fresh = arr.filter(function (x) { return x && x.t > lastLogT; });
    if (!fresh.length) return;
    lastLogT = Math.max.apply(null, fresh.map(function (x) { return x.t; }));
    sb.from('edit_log').insert(fresh.map(function (x) { return { t: new Date(x.t).toISOString(), who: x.who || '', what: x.what || '' }; }))
      .then(function (r) { if (r.error) console.warn('[cloud] log', r.error); });
  }

  /* intercept the app's localStorage writes */
  Storage.prototype.setItem = function (k, v) {
    rawSet.call(this, k, v);
    if (this !== LS) return;
    if (k === KEY) queueFromLocal(v);
    else if (k === KEY_PEOPLE) pushPeople(v);
    else if (k === KEY_LOG) pushLog(v);
  };

  /* ---------- realtime: changes from other devices ---------- */
  function applyRemote(id, data) {
    var cur = parse(lsGet(KEY), { projects: [] });
    var list = Array.isArray(cur.projects) ? cur.projects : [];
    var ix = list.findIndex(function (p) { return p && p.id === id; });
    if (data === null) { delete known[id]; if (ix >= 0) list.splice(ix, 1); else return; }
    else {
      data.id = id;
      var s = stable(data);
      if (known[id] === s && ix >= 0) return;          // our own change echoed back
      if (outbox[id] !== undefined) return;             // still editing locally — keep local
      known[id] = s;
      if (ix >= 0) list[ix] = data; else list.push(data);
    }
    lsSet(KEY, JSON.stringify(Object.assign({}, cur, { projects: list }, FLAGS)));
    emit('hwprog-remote');
  }
  function subscribe() {
    try {
      sb.channel('projects-live')
        .on('postgres_changes', { event: '*', schema: 'public', table: 'projects' }, function (pl) {
          if (pl.eventType === 'DELETE') applyRemote(pl.old && pl.old.id, null);
          else if (pl.new && pl.new.id) applyRemote(pl.new.id, pl.new.data);
        })
        .subscribe();
    } catch (e) { console.warn('[cloud] realtime', e); }
  }

  /* ---------- auth API used by the app ---------- */
  cloud.signIn = async function (username, password) {
    var r = await sb.auth.signInWithPassword({ email: cloud.emailOf(username), password: String(password || '') });
    if (r.error) throw r.error;
    await loadProfile();
    if (!profile) { await sb.auth.signOut(); throw new Error('ไม่พบโปรไฟล์ผู้ใช้'); }
    await pullExtras();
    deniedShown = false;
    return sessionObj();
  };
  cloud.signOut = async function () {
    user = null; profile = null; writeSession();
    try { await sb.auth.signOut(); } catch (e) {}
  };
  cloud.listUsers = async function () {
    var r = await sb.from('profiles').select('id,username,name,role').order('username');
    if (r.error) throw r.error;
    var arr = (r.data || []).map(function (x) { return { u: x.username, name: x.name, role: x.role, id: x.id }; });
    lsSet(KEY_USERS, JSON.stringify(arr));
    return arr;
  };
  cloud.createUser = async function (username, password, name, role) {
    /* separate client that doesn't store a session — creating a user doesn't sign the admin out */
    var tmp = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey,
      { auth: { persistSession: false, autoRefreshToken: false, storageKey: 'hwprog-tmp' } });
    var r = await tmp.auth.signUp({ email: cloud.emailOf(username), password: password,
      options: { data: { username: String(username).trim().toLowerCase(), name: name || username } } });
    if (r.error) throw r.error;
    var id = r.data && r.data.user && r.data.user.id;
    if (!id) throw new Error('สร้างผู้ใช้ไม่สำเร็จ');
    if (r.data.user.identities && r.data.user.identities.length === 0) throw new Error('username นี้มีอยู่แล้ว');
    if (!r.data.session) console.warn('[cloud] new user has no session — check that "Confirm email" is turned off');
    try { await tmp.auth.signOut(); } catch (e) {}
    var u = await sb.from('profiles').update({ role: role, name: name || username }).eq('id', id);
    if (u.error) throw u.error;
    return cloud.listUsers();
  };
  cloud.updateUser = async function (id, fields) {
    var r = await sb.from('profiles').update(fields).eq('id', id);
    if (r.error) throw r.error;
  };
  cloud.setPassword = async function (id, pw) {
    if (profile && id === profile.id) {
      var r1 = await sb.auth.updateUser({ password: pw });
      if (r1.error) throw r1.error; return;
    }
    var r = await sb.rpc('admin_set_password', { target: id, new_password: pw });
    if (r.error) throw r.error;
  };
  cloud.deleteUser = async function (id) {
    var r = await sb.rpc('admin_delete_user', { target: id });
    if (r.error) throw r.error;
    return cloud.listUsers();
  };
  cloud.errText = errText;

  sb.auth.onAuthStateChange(function (ev) {
    if (ev === 'SIGNED_OUT' && profile) { profile = null; user = null; writeSession(); emit('hwprog-auth'); }
  });

  /* ---------- startup: pull data before the app renders ---------- */
  window.__cloudReady = (async function () {
    try {
      await loadProfile();
      if (Object.keys(outbox).length && cloud.canWrite()) await flush();
      await pullProjects();
      await pullExtras();
      cloud.online = true;
    } catch (e) {
      cloud.online = false;
      console.warn('[cloud] offline / error:', e);
      /* no cache yet → show empty, not the demo data (so demo data doesn't get uploaded by mistake) */
      if (!lsGet(KEY)) lsSet(KEY, JSON.stringify(Object.assign({ projects: [] }, FLAGS)));
      var cached = parse(lsGet(KEY), { projects: [] });
      (cached.projects || []).forEach(function (p) { if (p && p.id && outbox[p.id] === undefined) known[p.id] = stable(p); });
      setTimeout(function () { badge('เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ — แสดงข้อมูลที่บันทึกไว้ในเครื่อง', 'warn', true); }, 1500);
    }
    subscribe();
  })();
})();
