const { app, BrowserWindow, ipcMain, dialog, Menu } = require("electron");
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");

let mainWindow;

function findPowerShell() {
  const candidates = [
    "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
    (process.env.ProgramW6432 || "") + "\\PowerShell\\7\\pwsh.exe",
    (process.env["ProgramFiles(x86)"] || "") + "\\PowerShell\\7\\pwsh.exe",
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  const which = process.env.PATH.split(";").map(p => path.join(p, "pwsh.exe")).find(p => fs.existsSync(p));
  if (which) return which;
  const store = process.env.LOCALAPPDATA + "\\Microsoft\\WindowsApps\\pwsh.exe";
  return fs.existsSync(store) ? store : null;
}

function getProjectRoot() {
  if (app.isPackaged) {
    return path.resolve(process.resourcesPath, "..");
  }
  return path.resolve(__dirname, "..");
}

function getScriptPath(name) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "scripts", name);
  }
  return path.join(getProjectRoot(), name);
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 900,
    minHeight: 600,
    title: "Gestionnaire Droits SharePoint",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, "renderer", "index.html"));
  mainWindow.setMenu(Menu.buildFromTemplate([{
    label: "Fichier",
    submenu: [
      { label: "Ouvrir architecture...", click: () => mainWindow.webContents.send("menu-open-architecture") },
      { label: "Ouvrir config droits...", click: () => mainWindow.webContents.send("menu-open-config") },
      { type: "separator" },
      { role: "quit", label: "Quitter" }
    ]
  }, {
    label: "Outils",
    submenu: [
      { label: "Tester connexion", click: () => mainWindow.webContents.send("menu-test-connection") },
      { label: "Recuperer architecture", click: () => mainWindow.webContents.send("menu-get-architecture") },
      { label: "Appliquer permissions", click: () => mainWindow.webContents.send("menu-apply-permissions") },
    ]
  }, {
    label: "Aide",
    submenu: [
      { label: "A propos", click: () => mainWindow.webContents.send("menu-about") },
      { role: "toggleDevTools", label: "Console developpeur" }
    ]
  }]));
}

ipcMain.handle("get-app-path", () => getProjectRoot());

ipcMain.handle("select-file", async (_, filters) => {
  const r = await dialog.showOpenDialog(mainWindow, {
    properties: ["openFile"],
    filters: filters || [{ name: "JSON", extensions: ["json"] }],
  });
  if (r.canceled) return null;
  return r.filePaths[0];
});

ipcMain.handle("select-folder", async () => {
  const r = await dialog.showOpenDialog(mainWindow, {
    properties: ["openDirectory"],
  });
  if (r.canceled) return null;
  return r.filePaths[0];
});

ipcMain.handle("select-save-path", async (_, opts) => {
  const r = await dialog.showSaveDialog(mainWindow, {
    defaultPath: opts && opts.defaultPath,
    filters: opts && opts.filters || [{ name: "JSON", extensions: ["json"] }],
  });
  if (r.canceled) return null;
  return r.filePath;
});

ipcMain.handle("read-file", async (_, filePath) => {
  try {
    return fs.readFileSync(filePath, "utf-8");
  } catch (e) {
    return { error: e.message };
  }
});

ipcMain.handle("write-file", async (_, filePath, content) => {
  try {
    fs.writeFileSync(filePath, content, "utf-8");
    return { success: true };
  } catch (e) {
    return { error: e.message };
  }
});

ipcMain.handle("list-architectures", async () => {
  const root = getProjectRoot();
  const archDirs = [
    path.join(root, "architectures"),
    path.join(root, "resultats"),
  ];
  const results = [];
  for (const archDir of archDirs) {
    if (!fs.existsSync(archDir)) continue;
    const walk = (dir, depth) => {
      if (depth > 3) return;
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.isDirectory()) {
          walk(path.join(dir, entry.name), depth + 1);
        } else if (entry.name.endsWith(".json")) {
          results.push(path.join(dir, entry.name));
        }
      }
    };
    walk(archDir, 0);
  }
  return results;
});

ipcMain.handle("list-configs", async () => {
  const root = getProjectRoot();
  const configs = [];
  for (const f of fs.readdirSync(root)) {
    if (f.startsWith("PermissionsConfig") && f.endsWith(".json")) {
      configs.push(path.join(root, f));
    }
  }
  return configs;
});

ipcMain.handle("powershell-check", async () => {
  const pwsh = findPowerShell();
  return { found: !!pwsh, path: pwsh || "" };
});

ipcMain.handle("powershell-exec", async (_, scriptName, args) => {
  const pwsh = findPowerShell();
  if (!pwsh) return { error: "PowerShell 7 introuvable" };

  const scriptPath = getScriptPath(scriptName);
  if (!fs.existsSync(scriptPath)) return { error: "Script introuvable: " + scriptName };

  return new Promise((resolve) => {
    const proc = spawn(pwsh, [
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", scriptPath,
      ...(args || [])
    ], {
      cwd: getProjectRoot(),
      windowsHide: true,
    });

    let stdout = "";
    let stderr = "";
    const lines = [];

    proc.stdout.on("data", (data) => {
      const text = data.toString("utf-8");
      stdout += text;
      const lns = text.split("\n").filter(Boolean);
      for (const ln of lns) {
        lines.push(ln.replace(/\r$/, ""));
        if (mainWindow && !mainWindow.isDestroyed()) {
          mainWindow.webContents.send("powershell-line", ln.replace(/\r$/, ""));
        }
      }
    });

    proc.stderr.on("data", (data) => {
      stderr += data.toString("utf-8");
    });

    proc.on("close", (code) => {
      resolve({ code, stdout, stderr, lines });
    });

    proc.on("error", (err) => {
      resolve({ error: err.message });
    });
  });
});

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
