const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("api", {
  getAppPath: () => ipcRenderer.invoke("get-app-path"),

  selectFile: (filters) => ipcRenderer.invoke("select-file", filters),
  selectFolder: () => ipcRenderer.invoke("select-folder"),
  selectSavePath: (opts) => ipcRenderer.invoke("select-save-path", opts),

  readFile: (p) => ipcRenderer.invoke("read-file", p),
  writeFile: (p, c) => ipcRenderer.invoke("write-file", p, c),

  listArchitectures: () => ipcRenderer.invoke("list-architectures"),
  listConfigs: () => ipcRenderer.invoke("list-configs"),

  powershellCheck: () => ipcRenderer.invoke("powershell-check"),
  powershellExec: (script, args) => ipcRenderer.invoke("powershell-exec", script, args),

  onPowerShellLine: (cb) => {
    ipcRenderer.on("powershell-line", (_, line) => cb(line));
  },
  onMenuOpenArchitecture: (cb) => ipcRenderer.on("menu-open-architecture", () => cb()),
  onMenuOpenConfig: (cb) => ipcRenderer.on("menu-open-config", () => cb()),
  onMenuTestConnection: (cb) => ipcRenderer.on("menu-test-connection", () => cb()),
  onMenuGetArchitecture: (cb) => ipcRenderer.on("menu-get-architecture", () => cb()),
  onMenuApplyPermissions: (cb) => ipcRenderer.on("menu-apply-permissions", () => cb()),
});
