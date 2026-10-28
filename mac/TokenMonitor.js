// ---------------------------------------------------------------
//  Token Monitor for Mac
//  A small always-on-top window that shows how many tokens are being
//  used, and what for.
//   - Claude Code: read from Claude Code's own log files on this Mac.
//   - Other sources (OpenAI, Claude API, or any service with a usage
//     link): added with the "+ Add source" button.
//  It only READS. It never changes anything.
//
//  Runs with tools built into every Mac (JavaScript for Automation).
//  Start it with "Start Token Monitor.command".
// ---------------------------------------------------------------

// --- Settings you can change ---
var WARN_AT         = 120000; // pop-up when a Claude Code session re-reads this many tokens per message
var REFRESH_SECONDS = 5;      // how often the window updates
var SOURCE_MINUTES  = 5;      // how often to ask the other sources for fresh numbers
// --------------------------------

ObjC.import('Cocoa');
ObjC.import('WebKit');

var KEYCHAIN_SERVICE = 'ClaudeTokenMonitor';

// ==== PURE LOGIC START (no Mac-specific calls in this section) ====

var WRAP_UP = [
    "We're moving to a fresh session to save tokens. Write a short hand-off note (under 250 words) that I can paste into a new Claude Code session. Include:",
    '1. What we\'re building and which folder/files matter',
    '2. What we finished',
    '3. Decisions we made, and why',
    '4. Anything broken or half-done',
    '5. The exact next step',
    "Write it as instructions to a new Claude, not to me. Don't change any files."
].join('\n');

var TYPE_LABELS = { openai: 'OpenAI', anthropic: 'Claude API', custom: 'Custom' };

function fmt(n) {
    n = Number(n) || 0;
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
    return String(Math.round(n));
}

function pad2(n) { return (n < 10 ? '0' : '') + n; }
function dayKey(d) { return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()); }
function clockText(d, withSeconds) {
    var h = d.getHours(), m = d.getMinutes(), s = d.getSeconds();
    var ap = h >= 12 ? 'PM' : 'AM';
    h = h % 12; if (h === 0) h = 12;
    return h + ':' + pad2(m) + (withSeconds ? ':' + pad2(s) : '') + ' ' + ap;
}

function newState() {
    return {
        pos: 0, seen: {}, input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
        context: 0, messages: 0, cwd: '', days: {}, tools: {}, toolNames: {},
        warned: false, firstTs: null, lastTs: null, rewarm: 0, rewarmCount: 0
    };
}

// Reads Claude Code log lines and adds them to a session's totals.
function processLines(st, text) {
    var lines = text.split('\n');
    for (var li = 0; li < lines.length; li++) {
        var line = lines[li].trim();
        if (!line) continue;
        var e;
        try { e = JSON.parse(line); } catch (err) { continue; }
        if (!e || typeof e !== 'object') continue;
        if (e.cwd) st.cwd = String(e.cwd);
        var msg = e.message;
        if (!msg || typeof msg !== 'object') continue;
        var content = msg.content;

        if (e.type === 'assistant') {
            if (Array.isArray(content)) {
                for (var i = 0; i < content.length; i++) {
                    var b = content[i];
                    if (b && b.type === 'tool_use') st.toolNames[String(b.id)] = String(b.name);
                }
            }
            var u = msg.usage;
            if (!u || typeof u !== 'object') continue;
            var key = msg.id + '|' + e.requestId;
            if (st.seen[key]) continue;          // same reply logged twice; count once
            st.seen[key] = 1;

            var inp = Number(u.input_tokens) || 0;
            var out = Number(u.output_tokens) || 0;
            var cr = Number(u.cache_read_input_tokens) || 0;
            var cw = Number(u.cache_creation_input_tokens) || 0;
            st.input += inp; st.output += out; st.cacheRead += cr; st.cacheWrite += cw;
            st.messages++;
            st.context = inp + cr + cw;

            var ts = e.timestamp ? new Date(e.timestamp) : null;
            if (ts && !isNaN(ts.getTime())) {
                if (!st.firstTs) st.firstTs = ts;
                // Came back after a long break: Claude has to re-save the whole chat again
                if (st.lastTs && (ts - st.lastTs) / 60000 > 60 && cw > 20000) {
                    st.rewarm += cw; st.rewarmCount++;
                }
                st.lastTs = ts;
                var dk = dayKey(ts);
                st.days[dk] = (st.days[dk] || 0) + inp + out + cr + cw;
            }
        }
        else if (e.type === 'user' && Array.isArray(content)) {
            for (var j = 0; j < content.length; j++) {
                var r = content[j];
                if (!r || r.type !== 'tool_result') continue;
                var name = st.toolNames[String(r.tool_use_id)] || 'Other tool';
                var c = r.content, chars = 0;
                if (typeof c === 'string') chars = c.length;
                else if (Array.isArray(c)) {
                    for (var k = 0; k < c.length; k++) {
                        var x = c[k];
                        if (!x) continue;
                        if (x.text) chars += String(x.text).length;
                        else if (x.type === 'image') chars += 6000;
                    }
                }
                st.tools[name] = (st.tools[name] || 0) + Math.floor(chars / 4);   // rough: ~4 characters per token
            }
        }
    }
}

// Turns tool names into plain words.
function friendly(name) {
    if (/davinci/i.test(name)) return 'DaVinci Resolve';
    if (/chrome/i.test(name)) return 'Chrome';
    if (name.indexOf('mcp__') === 0) return name.split('__')[1] || name;
    var map = {
        Read: 'Reading files', NotebookRead: 'Reading files',
        Bash: 'Running commands', PowerShell: 'Running commands', BashOutput: 'Running commands',
        Grep: 'Searching files', Glob: 'Searching files', LS: 'Searching files',
        Edit: 'Editing files', Write: 'Editing files', MultiEdit: 'Editing files', NotebookEdit: 'Editing files',
        WebFetch: 'Web lookups', WebSearch: 'Web lookups',
        Task: 'Helper agents', Agent: 'Helper agents'
    };
    return map[name] || name;
}

function sortedEntries(obj) {
    return Object.keys(obj).map(function (k) { return { key: k, value: obj[k] }; })
        .sort(function (a, b) { return b.value - a.value; });
}

function row(label, value, frac, color, hint) {
    return { kind: 'row', label: label, value: value, frac: Math.max(0, Math.min(1, frac || 0)), color: color, hint: hint || '' };
}
function note(text, color) { return { kind: 'note', text: text, color: color }; }
function head(text) { return { kind: 'head', text: text }; }

// Looks at how the session is going and gives plain-English advice.
function getTips(st, ctx, agg) {
    var tips = [], fresh = false;
    var spanH = (st.firstTs && st.lastTs) ? (st.lastTs - st.firstTs) / 3600000 : 0;
    var days = Object.keys(st.days).length;

    if (ctx >= 100000) {
        tips.push(note('This chat is long (' + fmt(ctx) + ' re-read every message). Finish your current step, then move to a new session.', '#F87171'));
        fresh = true;
    } else if (ctx >= 60000) {
        tips.push(note('Getting long. Plan to start a new session once this task is done.', '#FBBF24'));
    }
    // Common mistake: one session used for days, for everything
    if (days >= 2 || spanH >= 12) {
        var label = days >= 2 ? days + ' days' : Math.round(spanH) + ' hours';
        tips.push(note('This session has been running for ' + label + '. Use one session per task, not one per app.', '#F87171'));
        if (ctx >= 40000) fresh = true;
    }
    if (st.rewarmCount >= 1) {
        tips.push(note('You came back after a break ' + st.rewarmCount + ' time(s). Each time, Claude had to re-save the whole chat (' + fmt(st.rewarm) + ' so far). After a long break, start fresh instead.', '#FBBF24'));
    }
    if (st.messages >= 150) {
        tips.push(note(st.messages + ' replies in one session. Smaller sessions stay cheaper.', '#FBBF24'));
    }
    var toolTotal = 0;
    Object.keys(agg).forEach(function (k) { toolTotal += agg[k]; });
    var top = sortedEntries(agg)[0];
    if (top && top.value > 30000 && top.value / Math.max(1, toolTotal) > 0.4) {
        tips.push(note("'" + top.key + "' added the most (" + fmt(top.value) + '). Point Claude at specific files or smaller pieces instead of whole folders.', '#FBBF24'));
    }
    if (fresh) {
        tips.push(note("Easy switch: click the button below, paste it here, then paste Claude's answer into a new session. (Or type /compact to shrink this one.)", '#D6D3CF'));
    }
    if (tips.length === 0) tips.push(note('Looking good. Keep one session per task.', '#4ADE80'));
    return { tips: tips, fresh: fresh };
}

// Builds everything the window shows about Claude Code.
// files: { path: state }, cur: { path, mtimeMs } of the newest session, now: Date
function buildClaudeModel(files, cur, now) {
    var m = { found: false };
    if (!cur || !files[cur.path]) {
        m.project = 'No Claude Code sessions found on this Mac yet';
        m.tips = [note('Start a Claude Code session and it will show up here.', '#8A8783')];
        return m;
    }
    var st = files[cur.path];
    m.found = true;
    var proj = st.cwd ? st.cwd.replace(/[\\\/]+$/, '').split(/[\\\/]/).pop() : 'Session';
    var idle = (now - cur.mtimeMs) / 60000 > 30;
    m.projName = proj;
    m.idle = idle;
    m.project = 'Claude Code: ' + proj + '  -  ' + (idle ? 'last session (idle)' : 'active now');

    var ctx = st.context;
    var limit = ctx > 200000 ? 1000000 : 200000;
    var frac = ctx / limit;
    m.ctx = ctx;
    m.ctxText = fmt(ctx);
    m.ctxFrac = Math.min(1, frac);
    var col, msg;
    if (ctx < 50000) { col = '#4ADE80'; msg = 'Light - fine to keep going'; }
    else if (ctx < 120000) { col = '#FBBF24'; msg = 'Getting bigger - each message costs a bit more'; }
    else { col = '#F87171'; msg = 'Heavy - starting a fresh session would be cheaper'; }
    m.color = col;
    m.status = msg + '  (' + Math.round(frac * 100) + '% full)';

    var total = st.input + st.output + st.cacheRead + st.cacheWrite;
    var den = Math.max(1, total);
    m.sessionHeader = 'THIS SESSION SO FAR  -  ' + fmt(total) + ' total, ' + st.messages + ' replies';
    m.breakdown = [
        row('Re-reading the chat so far', fmt(st.cacheRead), st.cacheRead / den, '#60A5FA', 'Claude looks back over everything said so far before each reply. This is the cheap kind (about 1/10th the price).'),
        row('Saving the chat for re-reading', fmt(st.cacheWrite), st.cacheWrite / den, '#A78BFA', 'New parts of the chat get stored so Claude can re-read them cheaply later.'),
        row('Your new messages & results', fmt(st.input), st.input / den, '#F472B6', 'Fresh things sent to Claude that it had not seen before.'),
        row("Claude's replies", fmt(st.output), st.output / den, '#FB923C', 'What Claude wrote back, including its thinking and tool requests. The priciest kind per token.')
    ];

    var agg = {};
    Object.keys(st.tools).forEach(function (k) { var f = friendly(k); agg[f] = (agg[f] || 0) + st.tools[k]; });
    var top = sortedEntries(agg).slice(0, 5);
    if (top.length === 0) m.tools = [note('No tools used yet', '#8A8783')];
    else {
        var maxT = Math.max(1, top[0].value);
        m.tools = top.map(function (t) { return row(t.key, fmt(t.value), t.value / maxT, '#34D399', 'How much text this tool handed back to Claude (a rough guess).'); });
    }

    var today = dayKey(now), todayTotal = 0, todaySessions = 0;
    Object.keys(files).forEach(function (p) {
        var d = files[p].days[today];
        if (d) { todayTotal += d; todaySessions++; }
    });
    m.today = 'Claude Code today: ' + fmt(todayTotal) + ' tokens across ' + todaySessions + ' session(s)';

    var t = getTips(st, ctx, agg);
    m.tips = t.tips;
    m.fresh = t.fresh;
    m.longRunning = Object.keys(st.days).length >= 2 && t.fresh;
    m.days = Object.keys(st.days).length;
    return m;
}

// Builds the "other sources" part of the window.
function buildSourcesItems(results) {
    var items = [];
    results.forEach(function (d) {
        items.push(head(d.name + '  -  ' + fmt(d.total) + ' tokens today'));
        if (!d.ok) { items.push(note(d.error, '#FBBF24')); return; }
        if (d.type === 'custom') return;
        if (d.total <= 0 && d.audioSeconds <= 0) { items.push(note('No usage yet today.', '#8A8783')); return; }
        var den = Math.max(1, d.total);
        items.push(row('New text sent in', fmt(d.fresh), d.fresh / den, '#F472B6', 'Text sent in that the service had not seen recently.'));
        items.push(row('Re-used text (cheaper)', fmt(d.cached), d.cached / den, '#60A5FA', 'Text the service had seen moments ago, like the same instructions every time. Charged at a discount.'));
        if (d.cacheWrite > 0) items.push(row('Saved for re-use', fmt(d.cacheWrite), d.cacheWrite / den, '#A78BFA', 'Text stored so it can be re-used cheaply later.'));
        items.push(row('Replies', fmt(d.output), d.output / den, '#FB923C', 'What the AI wrote back. The priciest kind per token.'));
        if (d.type === 'openai') {
            var apps = sortedEntries(d.projects);
            if (apps.length > 1) {
                items.push(note('By app:', '#8A8783'));
                var maxA = Math.max(1, apps[0].value);
                apps.slice(0, 4).forEach(function (a) { items.push(row(a.key, fmt(a.value), a.value / maxA, '#22D3EE', 'Tokens used by this OpenAI project today.')); });
            } else if (apps.length === 1) {
                items.push(note('Your apps share one OpenAI project, so they show up together. Give each app its own project in OpenAI to see them separately.', '#8A8783'));
            }
        }
        var models = sortedEntries(d.models).slice(0, 3);
        if (models.length) items.push(note('Models: ' + models.map(function (x) { return x.key + ' ' + fmt(x.value); }).join('  |  '), '#8A8783'));
        var bits = [];
        if (d.requests > 0) bits.push(Number(d.requests).toLocaleString('en-US') + ' requests');
        if (d.audioSeconds > 0) bits.push((d.audioSeconds / 60).toFixed(1) + ' min of speech-to-text');
        if (bits.length) items.push(note(bits.join('  |  '), '#D6D3CF'));
        if (d.costOk) items.push(note('Bill this month so far: $' + Number(d.costMonth).toFixed(2) + '  (can lag a few hours)', '#D6D3CF'));
    });
    return items;
}

// Adds up every number found at a path like "data[].results[].output_tokens"
function sumPath(obj, path) {
    var cur = [obj];
    path.trim().split('.').forEach(function (part) {
        var iter = /\[\]$/.test(part);
        var name = part.replace(/\[\]$/, '');
        var next = [];
        cur.forEach(function (c) {
            if (c === null || c === undefined) return;
            var v = name ? c[name] : c;
            if (iter) { if (Array.isArray(v)) v.forEach(function (x) { next.push(x); }); else if (v !== undefined) next.push(v); }
            else next.push(v);
        });
        cur = next;
    });
    var sum = 0;
    cur.forEach(function (c) { var n = Number(c); if (!isNaN(n)) sum += n; });
    return sum;
}

function friendlyError(m) {
    m = String(m || '');
    if (/HTTP (401|403)/.test(m)) return 'The key was not accepted. Check it is the right kind of key (usually an Admin key).';
    if (/HTTP 404/.test(m)) return 'That address was not found (404). Check the usage link.';
    if (/offline|could not be found|hostname|not connected/i.test(m)) return 'No internet connection right now.';
    if (/timed out/i.test(m)) return 'The service took too long to answer.';
    return m;
}

// ==== PURE LOGIC END ====

// ================= Small Mac helpers =================

var sa = Application.currentApplication();
sa.includeStandardAdditions = true;

function sh(cmd) { return sa.doShellScript(cmd, { alteringLineEndings: false }); }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

var HOME = $.NSHomeDirectory().js;
var ROOT = HOME + '/.claude/projects';
var APP_DIR = HOME + '/Library/Application Support/ClaudeTokenMonitor';
var SRC_FILE = APP_DIR + '/sources.json';
var OUT_FILE = APP_DIR + '/sources-result.json';
var LOG_FILE = APP_DIR + '/sources-log.txt';
var UI_LOG = APP_DIR + '/window-log.txt';

function ensureDir() {
    $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(APP_DIR), true, $(), null);
}
function readText(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(path), 4, null);
    return (s && !s.isNil()) ? s.js : null;
}
function writeText(path, text) {
    $(text).writeToFileAtomicallyEncodingError($(path), true, 4, null);
}
function readJson(path, fallback) {
    var t = readText(path);
    if (t === null) return fallback;
    try { return JSON.parse(t); } catch (e) { return fallback; }
}
function uiLog(m) {
    try {
        var old = readText(UI_LOG) || '';
        if (old.length > 20000) old = old.slice(-10000);
        writeText(UI_LOG, old + clockText(new Date(), true) + '  ' + m + '\n');
    } catch (e) {}
}

function keychainSet(id, key) {
    sh('security add-generic-password -U -s ' + q(KEYCHAIN_SERVICE) + ' -a ' + q(id) + ' -w ' + q(key));
}
function keychainGet(id) {
    try { return sh('security find-generic-password -s ' + q(KEYCHAIN_SERVICE) + ' -a ' + q(id) + ' -w').replace(/\s+$/, ''); }
    catch (e) { return ''; }
}
function keychainDelete(id) {
    try { sh('security delete-generic-password -s ' + q(KEYCHAIN_SERVICE) + ' -a ' + q(id) + ' >/dev/null 2>&1'); } catch (e) {}
}

// ================= Background check of other sources =================
// Runs as a separate copy of this script so the window never freezes.

function httpGet(url, headers) {
    var nsurl = $.NSURL.URLWithString($(url));
    if (!nsurl || nsurl.isNil()) throw new Error("That link isn't a valid web address.");
    var req = $.NSMutableURLRequest.requestWithURLCachePolicyTimeoutInterval(nsurl, 1, 30);
    Object.keys(headers || {}).forEach(function (k) { req.setValueForHTTPHeaderField($(headers[k]), $(k)); });
    var resp = Ref(), err = Ref();
    var data = $.NSURLConnection.sendSynchronousRequestReturningResponseError(req, resp, err);
    if (!data || data.isNil()) {
        var e = err[0];
        var msg = (e && typeof e.isNil === 'function' && !e.isNil()) ? e.localizedDescription.js : 'No answer came back.';
        throw new Error(msg);
    }
    var code = resp[0] ? Number(resp[0].statusCode) : 0;
    var bodyNs = $.NSString.alloc.initWithDataEncoding(data, 4);
    var body = (bodyNs && !bodyNs.isNil()) ? bodyNs.js : '';
    if (code >= 400) throw new Error('HTTP ' + code + ': ' + body.slice(0, 200));
    return JSON.parse(body);
}

function runFetch(runId) {
    var logLines = [];
    function log(m) { logLines.push(clockText(new Date(), true) + '  ' + m); writeText(LOG_FILE, logLines.join('\n') + '\n'); }
    log('Check started ' + new Date().toString());

    var sources = readJson(SRC_FILE, []);
    var now = new Date();
    var mid = new Date(now.getTime()); mid.setHours(0, 0, 0, 0);
    var month = new Date(mid.getTime()); month.setDate(1);
    var iso = function (d) { return d.toISOString().replace(/\.\d{3}Z$/, 'Z'); };
    var midU = Math.floor(mid.getTime() / 1000), monthU = Math.floor(month.getTime() / 1000), nowU = Math.floor(now.getTime() / 1000);
    var midIso = iso(mid), monthIso = iso(month), nowIso = iso(now);
    function add(table, k, v) { table[k] = (table[k] || 0) + v; }

    function getOpenAI(s, key, o) {
        var h = { Authorization: 'Bearer ' + key };
        var base = 'https://api.openai.com/v1/organization';
        var names = {};
        try {
            log('  getting project names');
            var pr = httpGet(base + '/projects?limit=100&include_archived=true', h);
            (pr.data || []).forEach(function (p) { names[String(p.id)] = String(p.name); });
        } catch (e) { log('  project names failed: ' + e.message); }

        var url = base + '/usage/completions?start_time=' + midU + '&bucket_width=1h&limit=24&group_by=model&group_by=project_id';
        var page = null, n = 0;
        do {
            var u = url + (page ? '&page=' + encodeURIComponent(page) : '');
            log('  getting token usage (page ' + (n + 1) + ')');
            var r = httpGet(u, h);
            (r.data || []).forEach(function (b) {
                (b.results || []).forEach(function (x) {
                    var inp = Number(x.input_tokens) || 0, ca = Number(x.input_cached_tokens) || 0, ot = Number(x.output_tokens) || 0;
                    o.fresh += Math.max(0, inp - ca); o.cached += ca; o.output += ot;
                    o.requests += Number(x.num_model_requests) || 0;
                    add(o.models, x.model ? String(x.model) : 'unknown model', inp + ot);
                    var pj = x.project_id ? String(x.project_id) : '';
                    add(o.projects, pj ? (names[pj] || pj) : 'Default project', inp + ot);
                });
            });
            page = (r.has_more && r.next_page) ? String(r.next_page) : null;
            n++;
        } while (page && n < 10);

        try {
            log('  getting speech-to-text usage');
            var a = httpGet(base + '/usage/audio_transcriptions?start_time=' + midU + '&bucket_width=1h&limit=24', h);
            (a.data || []).forEach(function (b) { (b.results || []).forEach(function (x) { o.audioSeconds += Number(x.seconds) || 0; }); });
        } catch (e) { log('  speech-to-text failed: ' + e.message); }

        try {
            log("  getting this month's bill");
            var c = httpGet(base + '/costs?start_time=' + monthU + '&bucket_width=1d&limit=31', h);
            (c.data || []).forEach(function (b) { (b.results || []).forEach(function (x) { o.costMonth += Number(x.amount && x.amount.value) || 0; }); });
            o.costOk = true;
        } catch (e) { log('  bill failed: ' + e.message); }

        o.total = o.fresh + o.cached + o.output;
    }

    function getAnthropic(s, key, o) {
        var h = { 'x-api-key': key, 'anthropic-version': '2023-06-01' };
        var url = 'https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=' + encodeURIComponent(midIso) + '&bucket_width=1h&limit=24&group_by%5B%5D=model';
        var page = null, n = 0;
        do {
            var u = url + (page ? '&page=' + encodeURIComponent(page) : '');
            log('  getting token usage (page ' + (n + 1) + ')');
            var r = httpGet(u, h);
            (r.data || []).forEach(function (b) {
                (b.results || []).forEach(function (x) {
                    var f = Number(x.uncached_input_tokens) || 0, c = Number(x.cache_read_input_tokens) || 0;
                    var cc = x.cache_creation || {};
                    var w = (Number(cc.ephemeral_5m_input_tokens) || 0) + (Number(cc.ephemeral_1h_input_tokens) || 0);
                    var ot = Number(x.output_tokens) || 0;
                    o.fresh += f; o.cached += c; o.cacheWrite += w; o.output += ot;
                    add(o.models, x.model ? String(x.model) : 'unknown model', f + c + w + ot);
                });
            });
            page = (r.has_more && r.next_page) ? String(r.next_page) : null;
            n++;
        } while (page && n < 10);
        o.total = o.fresh + o.cached + o.cacheWrite + o.output;
    }

    function getCustom(s, key, o) {
        var u = String(s.url || '')
            .split('{today_unix}').join(String(midU)).split('{today_iso}').join(midIso)
            .split('{month_unix}').join(String(monthU)).split('{month_iso}').join(monthIso)
            .split('{now_unix}').join(String(nowU)).split('{now_iso}').join(nowIso);
        var h = {};
        if (key) h[s.header || 'Authorization'] = (s.prefix || '') + key;
        log('  calling ' + u.replace(/\?.*$/, '?...'));
        var r = httpGet(u, h);
        var tot = 0;
        String(s.fields || '').split(',').forEach(function (p) { if (p.trim()) tot += sumPath(r, p); });
        o.total = tot;
    }

    var results = [];
    sources.forEach(function (s) {
        var o = { name: s.name, type: s.type, ok: false, error: '', fresh: 0, cached: 0, cacheWrite: 0, output: 0, total: 0,
                  requests: 0, audioSeconds: 0, costMonth: 0, costOk: false, models: {}, projects: {}, at: Date.now() };
        try {
            log('Checking ' + s.name + ' (' + s.type + ')');
            var key = s.hasKey ? keychainGet(s.id) : '';
            if (s.type !== 'custom' && !key) throw new Error('No key found in your Keychain for this source. Remove it and add it again.');
            if (s.type === 'openai') getOpenAI(s, key, o);
            else if (s.type === 'anthropic') getAnthropic(s, key, o);
            else getCustom(s, key, o);
            o.ok = true;
            log('  done: ' + o.total + ' tokens today');
        } catch (e) {
            log('  FAILED: ' + e.message);
            o.error = friendlyError(e.message);
        }
        results.push(o);
    });
    writeText(OUT_FILE, JSON.stringify({ runId: runId, at: Date.now(), results: results }));
    log('Check finished');
}

// ================= The window =================

var files = {};
var sources = [];
var srcJob = null, srcData = null, srcError = null, srcLast = 0, srcAt = 0;
var wrapCopiedAt = 0;
var busy = false;
var panel = null, web = null, lastHeight = 0;
var PANEL_W = 300;
var SCRIPT_PATH = '';

function loadSources() {
    var s = readJson(SRC_FILE, []);
    sources = Array.isArray(s) ? s : [];
}
function saveSources() { ensureDir(); writeText(SRC_FILE, JSON.stringify(sources, null, 2)); }

function restartSources() {
    srcData = null; srcError = null; srcLast = 0; srcJob = null;
}

function updateSources() {
    if (srcJob) {
        var out = readJson(OUT_FILE, null);
        if (out && out.runId === srcJob.runId) {
            srcData = out.results || [];
            srcAt = out.at;
            srcError = srcData.length ? null : 'No answer came back.';
            srcJob = null;
        } else if (Date.now() - srcJob.started > 90000) {
            srcJob = null;
            srcError = 'It took too long to answer (over 90 seconds). Click Sources, then Open log, to see where it got stuck.';
        }
    }
    if (sources.length > 0 && !srcJob && Date.now() - srcLast >= SOURCE_MINUTES * 60000) {
        srcLast = Date.now();
        var runId = 'run-' + Date.now();
        srcJob = { runId: runId, started: Date.now() };
        try {
            sh('nohup /usr/bin/osascript -l JavaScript ' + q(SCRIPT_PATH) + ' --fetch ' + q(runId) + ' >/dev/null 2>&1 &');
        } catch (e) {
            srcJob = null; srcError = 'Could not start the check: ' + e.message;
        }
    }
}

function sourcesModel() {
    var m = { count: sources.length, button: sources.length ? 'Sources' : '+ Add source', items: [], foot: '' };
    m.list = sources.map(function (s) { return { id: s.id, name: s.name, typeLabel: TYPE_LABELS[s.type] || s.type }; });
    if (sources.length === 0) {
        m.items = [note('Add OpenAI, the Claude API, or any service with a usage link to see its tokens here.', '#8A8783')];
        return m;
    }
    if (!srcData) {
        if (srcError) m.items = [note("Couldn't check: " + srcError, '#FBBF24')];
        else if (srcJob) m.items = [note('Checking ' + sources.length + ' source(s)... ' + Math.round((Date.now() - srcJob.started) / 1000) + 's', '#8A8783')];
        else m.items = [note('Waiting to check...', '#8A8783')];
        return m;
    }
    m.items = buildSourcesItems(srcData);
    var foot = 'Checked at ' + clockText(new Date(srcAt), false) + ', every ' + SOURCE_MINUTES + ' min';
    if (srcJob) foot += '  -  checking again now...';
    if (srcError) foot += '  -  last check failed: ' + srcError;
    m.items.push(note(foot, '#6B6864'));
    return m;
}

function scanClaude() {
    var list = [];
    try {
        var out = sh('[ -d ' + q(ROOT) + " ] && find " + q(ROOT) + " -type f -name '*.jsonl' -exec stat -f '%m|%z|%N' {} + 2>/dev/null; true");
        out.split('\n').forEach(function (line) {
            if (!line) return;
            var a = line.indexOf('|'), b = line.indexOf('|', a + 1);
            if (a < 0 || b < 0) return;
            list.push({ mtimeMs: Number(line.slice(0, a)) * 1000, size: Number(line.slice(a + 1, b)), path: line.slice(b + 1) });
        });
    } catch (e) { uiLog('scan failed: ' + e); }
    return list;
}

function readNew(path, pos) {
    var fh = $.NSFileHandle.fileHandleForReadingAtPath($(path));
    if (!fh || fh.isNil()) return null;
    fh.seekToFileOffset(pos);
    var data = fh.readDataToEndOfFile;
    fh.closeFile;
    if (!data || data.isNil() || Number(data.length) === 0) return null;
    var ns = $.NSString.alloc.initWithDataEncoding(data, 4);
    if (!ns || ns.isNil()) return null;          // line still being written; try again next time
    var s = ns.js;
    var last = s.lastIndexOf('\n');
    if (last < 0) return null;
    var chunk = s.slice(0, last + 1);
    return { text: chunk, bytes: Number($(chunk).lengthOfBytesUsingEncoding(4)) };
}

function updateFile(f) {
    var st = files[f.path];
    if (!st || f.size < st.pos) { st = newState(); files[f.path] = st; }
    if (f.size === st.pos) return;
    var r = readNew(f.path, st.pos);
    if (!r) return;
    st.pos += r.bytes;
    processLines(st, r.text);
}

function updateClaude(now) {
    var all = scanClaude();
    var cutoff = now.getTime() - 2 * 86400000;
    all.forEach(function (f) { if (f.mtimeMs > cutoff) { try { updateFile(f); } catch (e) { uiLog('read failed: ' + e); } } });
    var cur = null;
    all.forEach(function (f) {
        if (f.path.indexOf('/subagents/') >= 0) return;
        if (!cur || f.mtimeMs > cur.mtimeMs) cur = f;
    });
    if (cur && !files[cur.path]) { try { updateFile(cur); } catch (e) {} }
    return { model: buildClaudeModel(files, cur, now), state: cur ? files[cur.path] : null };
}

function evalJS(js) {
    if (web) web.evaluateJavaScriptCompletionHandler($(js), function (result, error) {});
}
function toPageJson(obj) {
    return JSON.stringify(obj).split(String.fromCharCode(0x2028)).join('\\u2028').split(String.fromCharCode(0x2029)).join('\\u2029');
}

function copyText(t) {
    var pb = $.NSPasteboard.generalPasteboard;
    pb.clearContents;
    pb.setStringForType($(t), $('public.utf8-plain-text'));
}
function clipboardText() {
    var s = $.NSPasteboard.generalPasteboard.stringForType($('public.utf8-plain-text'));
    return (s && !s.isNil()) ? s.js : '';
}

function maybePopup(st, cm) {
    if (!cm.found || cm.idle || st.warned) return;
    if (!(cm.ctx >= WARN_AT || cm.longRunning)) return;
    st.warned = true;
    var why = cm.ctx >= WARN_AT
        ? 'is now re-reading about ' + fmt(cm.ctx) + ' tokens with every message.'
        : 'has been running for ' + cm.days + ' days and keeps getting more expensive.';
    var a = $.NSAlert.alloc.init;
    a.setMessageText($('Time for a fresh session'));
    a.setInformativeText($("Your '" + cm.projName + "' session " + why +
        '\n\nTo save tokens, move to a new session without losing your progress:\n\n' +
        '1. Click "Copy wrap-up prompt".\n2. Paste it into THIS session and send it.\n3. Copy Claude\'s answer.\n4. Start a new session, paste it in, and carry on.'));
    a.addButtonWithTitle($('Copy wrap-up prompt'));
    a.addButtonWithTitle($('Not now'));
    $.NSApplication.sharedApplication.activateIgnoringOtherApps(true);
    var r = Number(a.runModal);
    if (r === 1000) { copyText(WRAP_UP); wrapCopiedAt = Date.now(); }
}

function tick(fromTimer) {
    if (busy) return;
    busy = true;
    try {
        var now = new Date();
        try { updateSources(); } catch (e) { uiLog('sources: ' + e); }
        var c = updateClaude(now);
        var model = {
            claude: c.model,
            wrapCopied: Date.now() - wrapCopiedAt < 10000,
            sources: sourcesModel(),
            updated: 'Updated ' + clockText(now, true)
        };
        evalJS('render(' + toPageJson(model) + ')');
        // Pop-ups only from the regular timer, never while the page is talking to us
        if (fromTimer && c.state) maybePopup(c.state, c.model);
    } catch (e) {
        uiLog('tick failed: ' + e);
        evalJS('showError(' + toPageJson("Couldn't update: " + e) + ')');
    } finally { busy = false; }
}

function resizeTo(h) {
    if (!panel) return;
    h = Math.ceil(h);
    var screen = panel.screen;
    if (!screen || screen.isNil()) screen = $.NSScreen.mainScreen;
    var maxH = Number(screen.visibleFrame.size.height) - 60;
    if (h > maxH) h = maxH;
    if (Math.abs(h - lastHeight) < 2) return;
    lastHeight = h;
    var f = panel.frame;
    var top = Number(f.origin.y) + Number(f.size.height);
    var fr = panel.frameRectForContentRect($.NSMakeRect(0, 0, PANEL_W, h));
    var fh = Number(fr.size.height);
    panel.setFrameDisplay($.NSMakeRect(Number(f.origin.x), top - fh, Number(f.size.width), fh), true);
}

function onMessage(s) {
    var m;
    try { m = JSON.parse(s); } catch (e) { return; }
    try {
        if (m.type === 'ready') { tick(); }
        else if (m.type === 'height') { resizeTo(m.h); }
        else if (m.type === 'copyWrap') { copyText(WRAP_UP); wrapCopiedAt = Date.now(); tick(); }
        else if (m.type === 'paste') { evalJS('setField(' + toPageJson(m.field) + ',' + toPageJson(clipboardText()) + ')'); }
        else if (m.type === 'openLog') {
            try { sh('[ -f ' + q(LOG_FILE) + ' ] && open -e ' + q(LOG_FILE)); }
            catch (e) { evalJS('formResult(' + toPageJson('No log yet. It appears after the first check.') + ', true)'); }
        }
        else if (m.type === 'addSource') {
            var id = 'src-' + Date.now();
            var src = { id: id, type: m.srcType, name: m.name, hasKey: !!m.key,
                        url: m.url || '', header: m.header || '', prefix: m.prefix || '', fields: m.fields || '' };
            try {
                if (m.key) keychainSet(id, m.key);
            } catch (e) {
                evalJS('formResult(' + toPageJson("Couldn't save the key in your Keychain: " + e.message) + ', true)');
                return;
            }
            sources.push(src);
            saveSources();
            restartSources();
            evalJS('formResult(' + toPageJson("Added '" + m.name + "'. It will show in the window within a few seconds.") + ', false)');
            tick();
        }
        else if (m.type === 'removeSource') {
            sources = sources.filter(function (x) {
                if (x.id === m.id) { keychainDelete(x.id); return false; }
                return true;
            });
            saveSources();
            restartSources();
            tick();
        }
    } catch (e) { uiLog('message failed: ' + e); }
}

// ---------- The page shown inside the window ----------
var PAGE = [
'<!doctype html><html><head><meta charset="utf-8"><style>',
':root{color-scheme:dark}*{box-sizing:border-box}',
'html,body{margin:0;background:#1F1E1C}',
'body{padding:4px 14px 14px;font:12px -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;color:#D6D3CF;-webkit-user-select:none;cursor:default}',
'.muted{color:#8A8783}.dim{color:#6B6864}',
'.hdr{font-size:10px;font-weight:600;letter-spacing:.04em;color:#8A8783;margin-top:12px}',
'.row{margin-top:6px}.row .t{display:flex;justify-content:space-between;gap:10px}',
'.row .l{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.row .v{color:#fff;font-weight:600;white-space:nowrap}',
'.track{height:4px;border-radius:2px;background:rgba(255,255,255,.13);margin-top:3px}.fill{height:100%;border-radius:2px;min-width:2px}',
'.big{font-size:28px;font-weight:700;color:#fff;line-height:1.15;margin-top:6px}',
'.ctx{height:8px;border-radius:4px;background:rgba(255,255,255,.2);margin:8px 0 4px}.ctx>div{height:100%;border-radius:4px;min-width:3px}',
'.note{margin-top:5px;font-size:11px;line-height:1.35}',
'.head{margin-top:9px;font-weight:600;color:#E8E6E3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
'hr{border:0;height:1px;background:rgba(255,255,255,.13);margin:12px 0 10px}',
'button{font:inherit}',
'.link{background:none;border:0;color:#60A5FA;font-size:11px;cursor:pointer;padding:0}',
'.btn{width:100%;margin-top:8px;padding:6px;border-radius:6px;border:1px solid #60A5FA;background:#2E3A4F;color:#fff;font-size:12px;cursor:pointer}',
'.bar{display:flex;justify-content:space-between;align-items:center;gap:8px}',
'#project{font-size:11px;color:#8A8783;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
'label{display:block;font-size:11px;color:#A8A5A0;margin-top:9px;margin-bottom:3px}',
'input,select{width:100%;font:12px -apple-system,sans-serif;color:#fff;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.18);border-radius:5px;padding:5px 6px;-webkit-user-select:text}',
'.inrow{display:flex;gap:6px}.inrow input{flex:1}.paste{flex:none;font-size:11px;color:#fff;background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.18);border-radius:5px;padding:0 8px;cursor:pointer}',
'.title{font-weight:600;color:#E8E6E3;font-size:13px}',
'#dlg{display:none}',
'</style></head><body>',
'<div id="main">',
'  <div class="bar"><div id="project">Loading...</div><button class="link" id="smallBtn" title="Show less / show more">Less</button></div>',
'  <div class="big" id="ctx">...</div>',
'  <div class="muted" style="font-size:11px">tokens Claude re-reads with every message</div>',
'  <div class="ctx"><div id="ctxFill"></div></div>',
'  <div class="note" id="status"></div>',
'  <div id="details">',
'    <div class="hdr">TIPS TO SAVE TOKENS</div>',
'    <div id="tips"></div>',
'    <button class="btn" id="wrapBtn" style="display:none" title="Copies a prompt that asks Claude to write a hand-off note, so you can carry your progress into a new session.">Copy wrap-up prompt</button>',
'    <div id="claudeMore">',
'      <hr>',
'      <div class="hdr" id="sessHdr" style="margin-top:0">THIS SESSION SO FAR</div>',
'      <div id="breakdown"></div>',
'      <div class="hdr">WHAT THE TOOLS ADDED (rough guess)</div>',
'      <div id="tools"></div>',
'      <div class="note" id="today" style="margin-top:10px"></div>',
'    </div>',
'    <hr>',
'    <div class="bar"><div class="hdr" style="margin:0">OTHER SOURCES - TODAY</div><button class="link" id="srcBtn">+ Add source</button></div>',
'    <div id="sources"></div>',
'    <div class="note dim" id="foot" style="margin-top:10px;font-size:10px"></div>',
'  </div>',
'</div>',
'<div id="dlg">',
'  <div class="bar" style="margin-top:6px"><div class="title">Your sources</div><button class="link" id="dlgClose">Done</button></div>',
'  <div id="srcList"></div>',
'  <hr>',
'  <div class="title">Add a new source</div>',
'  <label>Type</label>',
'  <select id="fType"><option value="openai">OpenAI</option><option value="anthropic">Claude API (Anthropic)</option><option value="custom">Custom (any service with a usage link)</option></select>',
'  <div class="note muted" id="fHelp"></div>',
'  <label>Name (what to call it in the window)</label><input id="fName" value="OpenAI">',
'  <label id="fKeyLbl">Admin key</label><div class="inrow"><input id="fKey" type="password"><button class="paste" data-field="fKey">Paste</button></div>',
'  <div id="fCustom" style="display:none">',
'    <label>Usage link (URL)</label><div class="inrow"><input id="fUrl"><button class="paste" data-field="fUrl">Paste</button></div>',
'    <label>The key goes in this header</label><input id="fHeader" value="Authorization">',
'    <label>Put this in front of the key (keep the space)</label><input id="fPrefix" value="Bearer ">',
'    <label>Where the token numbers are in the answer</label><input id="fFields" placeholder="data[].total_tokens">',
'    <div class="note dim">Add several with commas. In the link you can use {today_unix}, {today_iso}, {month_unix} or {month_iso} for the start of today or this month.</div>',
'  </div>',
'  <div class="note" id="fMsg"></div>',
'  <div class="bar" style="margin-top:12px"><button class="link" id="openLog">Open log</button><button class="btn" id="addBtn" style="width:auto;margin:0;padding:5px 14px">Add source</button></div>',
'</div>',
'<script>',
'function post(o){try{window.webkit.messageHandlers.tm.postMessage(JSON.stringify(o));}catch(e){}}',
'function el(id){return document.getElementById(id);}',
'function esc(s){return String(s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;"}[c];});}',
'function itemHtml(it){',
'  if(it.kind==="row"){return \'<div class="row" title="\'+esc(it.hint)+\'"><div class="t"><span class="l">\'+esc(it.label)+\'</span><span class="v">\'+esc(it.value)+\'</span></div><div class="track"><div class="fill" style="width:\'+Math.max(1,it.frac*100)+\'%;background:\'+it.color+\'"></div></div></div>\';}',
'  if(it.kind==="head"){return \'<div class="head">\'+esc(it.text)+\'</div>\';}',
'  return \'<div class="note" style="color:\'+it.color+\'">\'+esc(it.text)+\'</div>\';',
'}',
'function list(items){return (items||[]).map(itemHtml).join("");}',
'var small=false,inDlg=false,last=null;',
'function sendHeight(){setTimeout(function(){var v=inDlg?el("dlg"):el("main");post({type:"height",h:Math.ceil(v.getBoundingClientRect().bottom)+14});},0);}',
'function render(m){',
'  last=m;var c=m.claude;',
'  el("project").textContent=c.project;',
'  el("ctx").textContent=c.found?c.ctxText:"-";',
'  el("ctxFill").style.width=(c.found?Math.max(1,c.ctxFrac*100):0)+"%";',
'  el("ctxFill").style.background=c.color||"#4ADE80";',
'  el("status").textContent=c.found?c.status:"";',
'  el("status").style.color=c.color||"#8A8783";',
'  el("tips").innerHTML=list(c.tips);',
'  var wb=el("wrapBtn");wb.style.display=c.fresh?"block":"none";',
'  wb.textContent=m.wrapCopied?"Copied! Now paste it into the old session":"Copy wrap-up prompt";',
'  el("claudeMore").style.display=c.found?"block":"none";',
'  if(c.found){el("sessHdr").textContent=c.sessionHeader;el("breakdown").innerHTML=list(c.breakdown);el("tools").innerHTML=list(c.tools);el("today").textContent=c.today;}',
'  el("srcBtn").textContent=m.sources.button;',
'  el("sources").innerHTML=list(m.sources.items);',
'  el("foot").textContent=m.updated;',
'  renderList();',
'  sendHeight();',
'}',
'function showError(t){el("foot").textContent=t;}',
'function renderList(){',
'  if(!last)return;var l=last.sources.list;',
'  el("srcList").innerHTML=l.length?l.map(function(s){return \'<div class="bar" style="margin-top:7px"><span>\'+esc(s.name)+\' <span class="muted">(\'+esc(s.typeLabel)+\')</span></span><button class="link rm" data-id="\'+esc(s.id)+\'">Remove</button></div>\';}).join(""):\'<div class="note muted">None yet.</div>\';',
'  Array.prototype.forEach.call(document.querySelectorAll(".rm"),function(b){b.onclick=function(){post({type:"removeSource",id:b.getAttribute("data-id")});};});',
'}',
'var HELP={openai:"Needs an OpenAI Admin key (starts with sk-admin-). Make one at platform.openai.com/settings/organization/admin-keys.",',
'  anthropic:"Needs a Claude Admin key (starts with sk-ant-admin). Make one in the Claude Console under Settings > Admin keys. Only works for organization accounts.",',
'  custom:"For any service that has a usage link. You need the link, where the key goes, and where the token number is in the answer. Ask Claude to help you fill these in for a specific service."};',
'var DEFNAME={openai:"OpenAI",anthropic:"Claude API",custom:"My service"};',
'function onType(){var t=el("fType").value;el("fHelp").textContent=HELP[t];el("fCustom").style.display=t==="custom"?"block":"none";',
'  el("fKeyLbl").textContent=t==="custom"?"Key (leave empty if the link needs none)":"Admin key";',
'  var n=el("fName").value;if(!n||n==="OpenAI"||n==="Claude API"||n==="My service")el("fName").value=DEFNAME[t];el("fMsg").textContent="";sendHeight();}',
'function setField(id,v){el(id).value=v;}',
'function formResult(t,isErr){var m=el("fMsg");m.textContent=t;m.style.color=isErr?"#FBBF24":"#4ADE80";if(!isErr){el("fKey").value="";el("fUrl").value="";el("fFields").value="";}sendHeight();}',
'function showDlg(on){inDlg=on;el("dlg").style.display=on?"block":"none";el("main").style.display=on?"none":"block";if(on){onType();renderList();}sendHeight();}',
'el("srcBtn").onclick=function(){showDlg(true);};',
'el("dlgClose").onclick=function(){showDlg(false);};',
'el("fType").onchange=onType;',
'el("wrapBtn").onclick=function(){post({type:"copyWrap"});};',
'el("openLog").onclick=function(){post({type:"openLog"});};',
'el("smallBtn").onclick=function(){small=!small;el("details").style.display=small?"none":"block";el("smallBtn").textContent=small?"More":"Less";sendHeight();};',
'Array.prototype.forEach.call(document.querySelectorAll(".paste"),function(b){b.onclick=function(){post({type:"paste",field:b.getAttribute("data-field")});};});',
'el("addBtn").onclick=function(){',
'  var t=el("fType").value,name=el("fName").value.trim(),key=el("fKey").value.trim();',
'  if(!name)return formResult("Please give it a name.",true);',
'  if(t!=="custom"&&!key)return formResult("Please paste the key.",true);',
'  if(t==="custom"){if(!el("fUrl").value.trim())return formResult("Please add the usage link.",true);if(!el("fFields").value.trim())return formResult("Please say where the token numbers are.",true);}',
'  post({type:"addSource",srcType:t,name:name,key:key,url:el("fUrl").value.trim(),header:el("fHeader").value.trim(),prefix:el("fPrefix").value,fields:el("fFields").value.trim()});',
'};',
'post({type:"ready"});',
'</script></body></html>'
].join('\n');

// ---------- Objective-C glue ----------
ObjC.registerSubclass({
    name: 'TMBridge',
    methods: {
        'userContentController:didReceiveScriptMessage:': {
            types: ['void', ['id', 'id']],
            implementation: function (ucc, message) {
                try { onMessage(ObjC.unwrap(message.body)); } catch (e) { uiLog('bridge: ' + e); }
            }
        }
    }
});
ObjC.registerSubclass({
    name: 'TMTicker',
    methods: {
        'tick:': { types: ['void', ['id']], implementation: function (t) { tick(true); } }
    }
});
ObjC.registerSubclass({
    name: 'TMWindowDelegate',
    methods: {
        'windowWillClose:': {
            types: ['void', ['id']],
            implementation: function (n) { $.NSApplication.sharedApplication.terminate($()); }
        }
    }
});

var bridge, ticker, winDelegate, timer;

function startWindow() {
    ensureDir();
    loadSources();
    var app = $.NSApplication.sharedApplication;
    app.setActivationPolicy(1);   // no Dock icon

    var screen = $.NSScreen.mainScreen;
    var vf = screen.visibleFrame;
    var h = 420;
    var x = Number(vf.origin.x) + Number(vf.size.width) - PANEL_W - 20;
    var y = Number(vf.origin.y) + Number(vf.size.height) - h - 20;

    // Titled (1) + closable (2) + utility (16) + HUD dark style (8192)
    panel = $.NSPanel.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(x, y, PANEL_W, h), 1 | 2 | 16 | 8192, 2, false);
    panel.setTitle($('Token Monitor'));
    panel.setFloatingPanel(true);
    panel.setLevel(3);            // stay on top of normal windows
    panel.setHidesOnDeactivate(false);
    panel.setReleasedWhenClosed(false);
    panel.setCollectionBehavior(1 | 256);   // show on every desktop, and next to full-screen apps

    winDelegate = $.TMWindowDelegate.alloc.init;
    panel.setDelegate(winDelegate);

    bridge = $.TMBridge.alloc.init;
    var config = $.WKWebViewConfiguration.alloc.init;
    config.userContentController.addScriptMessageHandlerName(bridge, $('tm'));
    web = $.WKWebView.alloc.initWithFrameConfiguration($.NSMakeRect(0, 0, PANEL_W, h), config);
    try { web.setValueForKey($.NSNumber.numberWithBool(false), $('drawsBackground')); } catch (e) {}
    web.setAutoresizingMask(2 | 16);   // stretch with the window
    panel.setContentView(web);
    web.loadHTMLStringBaseURL($(PAGE), $());

    lastHeight = h;
    app.activateIgnoringOtherApps(true);
    panel.makeKeyAndOrderFront($());
    panel.orderFrontRegardless;

    ticker = $.TMTicker.alloc.init;
    timer = $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(REFRESH_SECONDS, ticker, 'tick:', $(), true);

    app.run;
}

function scriptPath() {
    var args = ObjC.deepUnwrap($.NSProcessInfo.processInfo.arguments) || [];
    for (var i = args.length - 1; i >= 0; i--) {
        if (/\.js$/i.test(args[i])) {
            var p = args[i];
            if (p.charAt(0) !== '/') p = $.NSFileManager.defaultManager.currentDirectoryPath.js + '/' + p;
            return p;
        }
    }
    return '';
}

function run(argv) {
    argv = argv || [];
    if (argv[0] === '--fetch') {
        ensureDir();
        runFetch(argv[1] || '');
        return;
    }
    SCRIPT_PATH = scriptPath();
    try {
        startWindow();
    } catch (e) {
        uiLog('start failed: ' + e);
        sa.displayDialog("Token Monitor couldn't start:\n\n" + e, { buttons: ['OK'], defaultButton: 'OK', withIcon: 'caution' });
    }
}
