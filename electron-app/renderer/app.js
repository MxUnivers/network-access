/* ---------- STATE ---------- */
const state = {
  activePanel: "welcome",
  powershellPath: null,
  projectPath: "",
  currentProcess: null,
  architectureFile: null,
};

/* ---------- DOM REFS ---------- */
const $ = (id) => document.getElementById(id);
const $$ = (sel) => document.querySelectorAll(sel);

/* ---------- UTILITIES ---------- */
function esc(s) {
  const div = document.createElement("div");
  div.textContent = s == null ? "" : String(s);
  return div.innerHTML;
}

function stamp() {
  const d = new Date();
  return d.getFullYear()
    + String(d.getMonth() + 1).padStart(2, "0")
    + String(d.getDate()).padStart(2, "0") + "_"
    + String(d.getHours()).padStart(2, "0")
    + String(d.getMinutes()).padStart(2, "0")
    + String(d.getSeconds()).padStart(2, "0");
}

/* ---------- PANELS ---------- */
function showPanel(name) {
  if (state.activePanel === name) return;
  $$(".panel").forEach((p) => p.classList.remove("active"));
  const el = $(`panel-${name}`);
  if (el) el.classList.add("active");
  $$(".nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.action === name));
  state.activePanel = name;
}

/* ---------- CONSOLE ---------- */
function consoleClear() {
  $("consoleOutput").innerHTML = "";
}

function consoleWrite(text, cls) {
  const out = $("consoleOutput");
  const d = document.createElement("div");
  d.className = "line" + (cls ? " " + cls : "");
  d.textContent = text;
  out.appendChild(d);
  out.scrollTop = out.scrollHeight;
}

function consoleSetStatus(text, cls) {
  const el = $("consoleStatus");
  el.textContent = text;
  el.className = "console-status" + (cls ? " " + cls : "");
}

/* ---------- POWERSHELL ---------- */
async function checkPowerShell() {
  const r = await window.api.powershellCheck();
  const el = $("psStatus");
  if (r.found) {
    el.textContent = "PS7: OK";
    el.className = "ps-status ok";
    state.powershellPath = r.path;
  } else {
    el.textContent = "PS7: Introuvable";
    el.className = "ps-status err";
    state.powershellPath = null;
  }
  return r.found;
}

async function runScript(scriptName, args, opts) {
  if (!state.powershellPath) {
    consoleWrite("ERREUR: PowerShell 7 introuvable. Verifiez l'installation.", "err");
    return null;
  }
  showPanel("console");
  consoleClear();
  consoleSetStatus("Execution en cours...", "running");
  $("consoleTitle").textContent = opts && opts.title || "Execution";
  $("consoleStopBtn").disabled = false;

  consoleWrite("> " + scriptName + (args ? " " + args.join(" ") : ""), "muted");
  consoleWrite("");

  window.api.onPowerShellLine((line) => {
    const lower = line.toLowerCase();
    let cls = "";
    if (lower.includes("error") || lower.includes("erreur")) cls = "err";
    else if (lower.includes("succ") || lower.includes("ok") || lower.includes("reussi")) cls = "ok";
    else if (lower.includes("attention") || lower.includes("warning")) cls = "warn";
    else if (lower.includes("info") || lower.includes("info")) cls = "info";
    consoleWrite(line, cls);
  });

  const result = await window.api.powershellExec(scriptName, args || []);

  $("consoleStopBtn").disabled = true;

  if (result.error) {
    consoleWrite("");
    consoleWrite("ERREUR: " + result.error, "err");
    consoleSetStatus("Erreur", "error");
    return null;
  }

  consoleWrite("");
  consoleWrite("--- Termine (code: " + result.code + ") ---", "muted");

  if (result.code === 0) {
    consoleSetStatus("Termine avec succes", "done");
  } else {
    consoleSetStatus("Termine avec erreur (code " + result.code + ")", "error");
  }

  return result;
}

/* ---------- ACTIONS ---------- */
async function testConnection() {
  await runScript("Test-SPOConnection.ps1", [], { title: "Test de connexion SharePoint" });
}

async function getArchitecture() {
  await runScript("Get-SPOArchitecture.ps1", [], { title: "Recuperation de l'architecture" });
  refreshArchitectureList();
}

async function applyPermissions() {
  await runScript("Set-SPOFolderPermissions.ps1", [], { title: "Application des permissions" });
}

async function openArchitectureFile() {
  const path = await window.api.selectFile([{ name: "Architecture JSON", extensions: ["json"] }]);
  if (!path) return;
  state.architectureFile = path;
  showPanel("visualizer");
  loadVisualizer(path);
}

async function openConfigFile() {
  const path = await window.api.selectFile([{ name: "JSON", extensions: ["json"] }]);
  if (!path) return;
  const content = await window.api.readFile(path);
  if (content && content.error) {
    consoleWrite("Erreur lecture: " + content.error, "err");
    return;
  }
  showPanel("console");
  consoleClear();
  consoleWrite("Fichier de config charge: " + path, "info");
  try {
    const data = JSON.parse(content);
    consoleWrite("Config valide: " + (data.Site && data.Site.Titre || "Inconnu"), "ok");
    consoleWrite("Bibliotheques: " + (data.Bibliotheques ? data.Bibliotheques.length : 0), "muted");
    consoleWrite("Groupes connus: " + (data.GroupesConnus ? data.GroupesConnus.length : 0), "muted");
  } catch (e) {
    consoleWrite("JSON invalide: " + e.message, "err");
  }
}

async function openVisualizer() {
  const list = await window.api.listArchitectures();
  if (list.length === 0) {
    const direct = await window.api.selectFile([{ name: "Architecture JSON", extensions: ["json"] }]);
    if (!direct) return;
    state.architectureFile = direct;
    showPanel("visualizer");
    loadVisualizer(direct);
    return;
  }
  showPanel("visualizer");
  refreshArchitectureList();
}

/* ---------- VISUALIZER ---------- */
async function refreshArchitectureList() {
  const listEl = $("vizFileList");
  const list = await window.api.listArchitectures();
  const configs = await window.api.listConfigs();

  const all = [...list, ...configs];
  if (all.length === 0) {
    listEl.innerHTML = '<div class="viz-empty">Aucun fichier trouve. Lancez d\'abord "Recuperer architecture".</div>';
    return;
  }

  listEl.innerHTML = all.map((p) => {
    const name = p.split(/[\\/]/).pop();
    const active = p === state.architectureFile ? " active" : "";
    return `<div class="viz-file-item${active}" data-path="${esc(p)}">${esc(name)}<br><span style="font-size:10px;color:var(--muted)">${esc(p)}</span></div>`;
  }).join("");

  listEl.querySelectorAll(".viz-file-item").forEach((el) => {
    el.addEventListener("click", () => {
      state.architectureFile = el.dataset.path;
      listEl.querySelectorAll(".viz-file-item").forEach((e) => e.classList.remove("active"));
      el.classList.add("active");
      loadVisualizer(el.dataset.path);
    });
  });
}

async function loadVisualizer(filePath) {
  const frame = $("vizFrame");
  const content = await window.api.readFile(filePath);
  if (!content || content.error) {
    consoleWrite("Erreur chargement: " + (content && content.error), "err");
    frame.src = "about:blank";
    return;
  }

  const html = `<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font:14px/1.5 -apple-system,"Segoe UI",sans-serif;color:#1f2328;background:#fff;padding:16px}
  h1{font-size:18px;margin:0 0 4px}
  .sub{color:#656d76;font-size:13px;word-break:break-word}
  .summary{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:12px 0}
  .summary-item{border:1px solid #d0d7de;border-radius:8px;padding:8px;background:#f6f8fa}
  .summary-item b{font-size:20px;display:block}
  .summary-item span{font-size:11px;color:#656d76;text-transform:uppercase}
  .lib-title{font-size:16px;color:#0969da;margin:12px 0 4px;border-bottom:1px solid #d0d7de;padding-bottom:4px}
  .tree-root{margin-left:0}
  .folder-line{display:flex;align-items:center;gap:6px;padding:5px 8px;border-radius:6px;cursor:pointer;font-size:13px;border-bottom:1px solid #f0f0f0}
  .folder-line:hover{background:#f6f8fa}
  .folder-line .caret{width:18px;text-align:center;color:#999;flex:0 0 auto;transition:transform .15s}
  .folder-line .caret.open{transform:rotate(90deg)}
  .folder-line .name{font-weight:600}
  .folder-line .meta{color:#999;font-size:11px;margin-left:6px}
  .folder-children{padding-left:24px;display:none}
  .folder-children.open{display:block}
  .file-line{padding:3px 8px;font-size:12px;color:#656d76;border-bottom:1px solid #f6f8fa}
  .perm-badge{font-size:11px;border:1px solid #d0d7de;border-radius:999px;padding:1px 6px;margin:0 2px;display:inline-block}
  .perm-count{color:#0969da;font-size:12px;cursor:pointer}
  .perm-count:hover{text-decoration:underline}
  .perm-popup{display:none;background:#f6f8fa;border:1px solid #d0d7de;border-radius:6px;padding:6px 10px;margin:4px 0 4px 20px;font-size:12px}
  .perm-popup.open{display:block}
  .gp-label{color:#1a7f37}.gp-user{color:#bf3989}.gp-spg{color:#8250df}
</style></head><body>
<div id="root"></div>
<script>
const D = ${content};
function esc(s){return String(s==null?"":s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
function permHtml(p){var t=p.Type||"";return "<span class='perm-badge "+(t==="SecurityGroup"?"gp-label":t==="User"?"gp-user":t==="SharePointGroup"?"gp-spg":"")+"'>"+esc(p.Principal||"")+" ("+esc((p.Roles||[]).join(","))+")</span>"}
function renderFolder(node,depth){
  if(!node||!node.Name)return"";
  var name=esc(node.Name),perms=(node.Permissions||[]),files=(node.Fichiers||[]),subs=(node.Dossiers||[]);
  var inherits=node.HeritageRompu===false,hasPerms=perms.length>0,hasFiles=files.length>0,hasSubs=subs.length>0;
  var hasChildren=hasSubs||hasFiles;
  var h="<div class='folder' data-depth='"+depth+"'>";
  h+="<div class='folder-line' onclick='toggle(this)'>";
  h+="<span class='caret"+(depth<1?" open":"")+"'>"+(hasChildren?">":"")+"</span>";
  h+="<span class='name'>[D] "+name+"</span>";
  if(node.ModifiePar) h+="<span class='meta'>- "+esc(node.ModifiePar)+"</span>";
  if(!hasPerms&&!inherits)h+="<span class='meta'>(aucun droit explicite)</span>";
  else if(inherits)h+="<span class='meta'>(heritage conserve)</span>";
  h+="</div>";
  if(hasPerms){
    h+="<div class='perm-popup"+(depth<1?" open":"")+"'>"+perms.map(permHtml).join(" ")+"</div>";
  }
  if(hasChildren){
    h+="<div class='folder-children"+(depth<1?" open":"")+"'>";
    files.forEach(function(f){h+="<div class='file-line'>[F] "+esc(f.Name)+(f.Modifie?" <span class='meta'>("+esc(f.Modifie)+")</span>":"")+"</div>"});
    subs.forEach(function(s){h+=renderFolder(s,depth+1)});
    h+="</div>";
  }
  return h+"</div>";
}
function toggle(el){
  var parent=el.closest(".folder");
  if(!parent)return;
  var caret=parent.querySelector(".caret");
  var children=parent.querySelector(".folder-children");
  var perms=parent.querySelector(".perm-popup");
  if(caret)caret.classList.toggle("open");
  if(children)children.classList.toggle("open");
  if(perms&&!children)perms.classList.toggle("open");
}
var root=document.getElementById("root");
var html="<h1>"+esc(D.Site&&D.Site.Titre||"Architecture")+"</h1><div class='sub'>"+esc(D.Site&&D.Site.Url||"")+(D.Site&&D.Site.CaptureLe?" - Capture le "+esc(D.Site.CaptureLe):"")+"</div>";
var groups=D.GroupesConnus;
if(groups&&groups.length){
  html+="<h2 style='margin-top:14px;font-size:15px'>Groupes connus</h2><div style='display:flex;gap:6px;flex-wrap:wrap;margin:6px 0 12px'>"+groups.map(function(g){return"<span style='border:1px solid #d0d7de;border-radius:999px;padding:2px 10px;font-size:12px;background:#f6f8fa'>"+esc(g.Principal||g.Name||g)+"</span>"}).join("")+"</div>";
}
var td=0,tf=0,tp=0;
(function count(n){td++;(n.Fichiers||[]).forEach(function(f){tf++});(n.Permissions||[]).forEach(function(p){tp++});(n.Dossiers||[]).forEach(count)});
(D.Bibliotheques||[]).forEach(function(l){(l.Dossiers||[]).forEach(count)});
html+="<div class='summary'><div class='summary-item'><b>"+td+"</b><span>Dossiers</span></div><div class='summary-item'><b>"+tf+"</b><span>Fichiers</span></div><div class='summary-item'><b>"+tp+"</b><span>Permissions</span></div></div>";
(D.Bibliotheques||[]).forEach(function(l){
  html+="<h2 class='lib-title'>[B] "+esc(l.Name||l.Title||"Documents")+"</h2><div class='tree-root'>";
  (l.Dossiers||[]).forEach(function(f){html+=renderFolder(f,0)});
  html+="</div>";
});
html+="<div class='sub' style='margin-top:16px'>"+td+" dossier(s), "+tf+" fichier(s), "+tp+" permission(s) explicite(s)</div>";
root.innerHTML=html;
<\/script></body></html>`;

  frame.srcdoc = html;
}

/* ---------- SETTINGS ---------- */
async function openSettings() {
  showPanel("settings");
  $("settingsProjectPath").textContent = state.projectPath;

  const ps = await window.api.powershellCheck();
  $("settingsPsPath").textContent = ps.found ? ps.path : "Introuvable";

  const configs = await window.api.listConfigs();
  const sel = $("settingsDefaultConfig");
  sel.innerHTML = '<option value="">-- Aucun --</option>' + configs.map((c) => {
    const name = c.split(/[\\/]/).pop();
    return `<option value="${esc(c)}">${esc(name)}</option>`;
  }).join("");

  $("settingsOutputDir").value = state.projectPath + "\\architectures";
}

/* ---------- EVENT BINDINGS ---------- */
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-action]");
  if (!btn) return;
  const action = btn.dataset.action;
  switch (action) {
    case "test-connection": testConnection(); break;
    case "get-architecture": getArchitecture(); break;
    case "open-architecture": openArchitectureFile(); break;
    case "open-config": openConfigFile(); break;
    case "apply-permissions": applyPermissions(); break;
    case "visualizer": openVisualizer(); break;
    case "settings": openSettings(); break;
  }
});

$("consoleClearBtn").addEventListener("click", consoleClear);
$("consoleStopBtn").addEventListener("click", () => {
  $("consoleStopBtn").disabled = true;
  consoleWrite("[Arret demande par l'utilisateur]", "warn");
});

$("vizLoadBtn").addEventListener("click", openArchitectureFile);
$("vizRefreshBtn").addEventListener("click", refreshArchitectureList);

$("settingsBrowseBtn").addEventListener("click", async () => {
  const dir = await window.api.selectFolder();
  if (dir) $("settingsOutputDir").value = dir;
});

/* Menu events */
window.api.onMenuOpenArchitecture(() => openArchitectureFile());
window.api.onMenuOpenConfig(() => openConfigFile());
window.api.onMenuTestConnection(() => testConnection());
window.api.onMenuGetArchitecture(() => getArchitecture());
window.api.onMenuApplyPermissions(() => applyPermissions());

/* ---------- INIT ---------- */
(async function init() {
  state.projectPath = await window.api.getAppPath();
  await checkPowerShell();
})();
