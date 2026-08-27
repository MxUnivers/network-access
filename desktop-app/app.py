"""
SPO Permissions - Gestionnaire multi-sites

Interface graphique pour piloter les scripts PowerShell existants:
- Get-SPOArchitecture.ps1
- Set-SPOFolderPermissions.ps1

Chaque onglet represente un site SharePoint independant avec sa propre
configuration, son fichier importe et sa console.
"""
import json
import os
import queue
import re
import socket
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
import urllib.error
import urllib.request
import webbrowser
from shutil import which
from tkinter import filedialog, messagebox, scrolledtext, simpledialog, ttk

APP_TITLE = "SPO Permissions - Console multi-sites"
MAX_TABS = 10

INLINE_PATTERN = re.compile(r"(\*\*[^*]+\*\*|\*[^*]+\*|`[^`\n]+`|\[[^\]]+\]\([^)]+\))")

ASSISTANT_DEFAULTS = {
    "Endpoint": "https://api.deepseek.com/v1/chat/completions",
    "Model": "deepseek-chat",
    "ApiKey": "",
}

ASSISTANT_SYSTEM_PROMPT = (
    "Tu es \"l'Assistant SPO\", le support integre de l'outil de bureau SPO Permissions, qui gere "
    "les droits d'acces sur les bibliotheques et dossiers SharePoint Online.\n"
    "REGLES DE BASE :\n"
    "- Reponds TOUJOURS en francais, de facon simple et pedagogique : l'utilisateur n'est pas un expert SharePoint.\n"
    "- Ne revele JAMAIS ton modele, ton fournisseur d'API, ni aucun detail technique interne. Tu es simplement \"l'Assistant SPO\".\n"
    "- Reponds en 3 a 10 lignes, avec un ton rassurant. Termine parfois par une question pour faire avancer l'utilisateur.\n"
    "PERIMETRE STRICT (regle la plus importante, a respecter dans TOUTES tes reponses) :\n"
    "- Tu reponds UNIQUEMENT sur ce que fait cet outil, ce que font reellement ses scripts et ses fichiers de configuration "
    "(voir FICHE TECHNIQUE ci-dessous), et sur la gestion des permissions SharePoint telle que l'outil la realise.\n"
    "- Ne decris JAMAIS une fonctionnalite que l'outil ne possede pas : base-toi exclusivement sur le code, les scripts et les fichiers du projet.\n"
    "- Quand on te transmet le contenu d'un fichier (JSON d'architecture, configuration, journal), base-toi sur CE contenu precis, comme le visualiseur "
    "HTML de l'outil qui n'affiche que ce que contient le fichier.\n"
    "- Si la question est hors sujet (autre logiciel, sujet general, code etranger a l'outil, discussion sans rapport), refuse poliment et recentre "
    "la discussion sur l'outil : rappelle ce que l'outil sait faire et propose la question utile correspondante.\n"
    "FICHE TECHNIQUE DE L'OUTIL (ce que le code fait reellement) :\n"
    "- L'outil = une application de bureau (console multi-onglets, un onglet par site SharePoint) qui pilote des scripts PowerShell, "
    "avec un fichier de configuration JSON par operation.\n"
    "- Connexion 100% automatique (sans fenetre) : App Registration Entra ID + certificat (empreinte OU fichier .pfx/.cer), via Microsoft Graph et PnP.PowerShell 7.\n"
    "- Script principal Set-SPOFolderPermissions.ps1 : pour chaque dossier de la configuration, il verifie le principal (groupe Entra ID, puis groupe "
    "SharePoint, puis utilisateur Entra ID), puis applique 3 types d'action : 'Role' (accorder un role), 'Access: Deny' (masquer le dossier a un groupe), "
    "'ResetPermissions: true' (dossier prive, remis a zero).\n"
    "- Attribution des droits en 3 phases : detection de l'heritage -> rupture d'heritage si besoin (en COPIANT les droits du parent, la navigation est "
    "conservee) -> application du role. En cas d'echec (AccessDenied/403), l'outil verifie le statut de l'heritage, le rompt et REESSAIE automatiquement "
    "avant de declarer un echec.\n"
    "- Roles reconnus (en francais ou en anglais, traduits automatiquement) : Controle total, Modification, Collaboration, Lecture, Creation, Affichage seul, etc.\n"
    "- Script Get-SPOArchitecture.ps1 : exporte l'arborescence du site (dossiers + permissions actuelles) en JSON pour etre modifie puis reimporte.\n"
    "- Script Test-SPOConnection.ps1 : test en lecture seule (authentification, groupes, dossiers) sans rien modifier.\n"
    "- Journal et bilan : chaque execution ecrit un journal dans Logs\\ et affiche un bilan final (X reussites / Y echecs) avec un code de retour "
    "(0 = OK, 2 = echecs partiels, 1 = blocage).\n"
    "- Le fichier de configuration contient : section Auth (TenantId, ClientId, certificat), SiteUrl, puis la liste Permissions avec Library, "
    "FolderPath, Assignments (GroupName + Role ou Access).\n"
    "TON DOUBLE ROLE :\n"
    "1) SUPPORT UTILISATEUR : tu reponds aux questions sur la gestion des droits SharePoint faite par l'outil : heritage des permissions, "
    "rupture d'heritage, roles (Lecture, Modification, Controle total...), masquage de dossiers, acces specifiques, navigation, fichier de configuration JSON.\n"
    "2) EXPLICATION DES OPERATIONS : quand on te transmet le contexte d'une session (journal d'execution de l'outil), tu expliques ce qui s'est passe, "
    "tu confirmes les succes et tu diagnostiques les echecs, en t'appuyant uniquement sur le comportement reel du code.\n"
    "SOIS PROACTIF : si l'utilisateur signale un probleme d'acces (ex. \"je ne peux pas modifier un sous-dossier\"), explique aussitot "
    "la cause la plus probable (conflit d'heritage : le parent est en Lecture, le sous-dossier demande Modification, il faut rompre "
    "l'heritage) et propose la solution immediate.\n"
    "REGLE HEREDITAIRE DE L'OUTIL : pour donner un droit plus eleve que le parent (ex. Modification sur un sous-dossier dont le parent "
    "est en Lecture), l'outil rompt automatiquement l'heritage sur le sous-dossier EN COPIANT les droits du parent (la Lecture est "
    "conservee : la navigation reste possible), puis applique le droit de Modification uniquement sur le sous-dossier. Le parent n'est "
    "jamais modifie.\n"
    "Ton objectif : donner des reponses claires, rassurantes et utiles, toujours dans le perimetre de l'outil."
)

if getattr(sys, "frozen", False):
    BUNDLE_DIR = sys._MEIPASS
    APP_DIR = os.path.dirname(sys.executable)
else:
    BUNDLE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    APP_DIR = os.path.dirname(os.path.abspath(__file__))

GET_ARCH_SCRIPT = os.path.join(BUNDLE_DIR, "Get-SPOArchitecture.ps1")
APPLY_PERMS_SCRIPT = os.path.join(BUNDLE_DIR, "Set-SPOFolderPermissions.ps1")
SETTINGS_FILE = os.path.join(APP_DIR, "spo_gestionnaire_settings.json")
ICON_FILE = os.path.join(BUNDLE_DIR, "icon.ico")


def check_internet(timeout=4):
    try:
        socket.create_connection(("login.microsoftonline.com", 443), timeout=timeout).close()
        return True
    except OSError:
        return False

PWSH_CANDIDATES = [
    r"C:\Program Files\PowerShell\7\pwsh.exe",
    os.path.expandvars(r"%ProgramW6432%\PowerShell\7\pwsh.exe"),
    os.path.expandvars(r"%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"),
    os.path.expandvars(r"%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"),
]

NO_WINDOW = subprocess.CREATE_NO_WINDOW if hasattr(subprocess, "CREATE_NO_WINDOW") else 0


def find_pwsh():
    for candidate in PWSH_CANDIDATES:
        if candidate and os.path.exists(candidate):
            return candidate
    return which("pwsh.exe") or which("pwsh")


class SiteTab(ttk.Frame):
    def __init__(self, app, index, initial=None):
        super().__init__(app.notebook, style="Panel.TFrame")
        self.app = app
        self.index = index
        self.initial = initial or {}
        self.output_queue = queue.Queue()
        self.running = False
        self.selected_import_path = ""
        self.process = None

        self.var_name = tk.StringVar(value=self.initial.get("Name") or f"Site {index}")
        self.var_tenant = tk.StringVar(value=self.initial.get("TenantId", ""))
        self.var_client = tk.StringVar(value=self.initial.get("ClientId", ""))
        self.var_thumb = tk.StringVar(value=self.initial.get("CertificateThumbprint", ""))
        self.var_siteurl = tk.StringVar(value=self.initial.get("SiteUrl", ""))
        self.var_certfile = tk.StringVar(value=self.initial.get("CertificatePath", ""))
        self.var_certpass = tk.StringVar()
        self.var_depth = tk.StringVar(value=self.initial.get("Depth", "Illimitee"))
        self.selected_import_file = tk.StringVar(value="Aucun fichier selectionne.")

        self._build_ui()
        self._bind_title_updates()

    def _build_ui(self):
        self.columnconfigure(0, weight=0)
        self.columnconfigure(1, weight=1)
        self.rowconfigure(1, weight=1)

        hero = tk.Frame(self, bg="#07111f", highlightthickness=1, highlightbackground="#20324d")
        hero.grid(row=0, column=0, columnspan=2, sticky="ew", padx=12, pady=(12, 8))
        hero.columnconfigure(0, weight=1)

        tk.Label(
            hero,
            text="SESSION SITE",
            bg="#07111f",
            fg="#75e6ff",
            font=("Segoe UI", 9, "bold"),
        ).grid(row=0, column=0, sticky="w", padx=14, pady=(10, 0))
        tk.Entry(
            hero,
            textvariable=self.var_name,
            bg="#0c1728",
            fg="#f4f8ff",
            insertbackground="#75e6ff",
            relief="flat",
            font=("Segoe UI", 14, "bold"),
        ).grid(row=1, column=0, sticky="we", padx=14, pady=(0, 8))
        self.state_label = tk.Label(
            hero,
            text="PRET",
            bg="#07111f",
            fg="#5cf2a7",
            font=("Segoe UI", 12, "bold"),
        )
        self.state_label.grid(row=0, column=1, rowspan=2, sticky="e", padx=14, pady=12)

        left_wrapper = tk.Frame(self, bg="#050a13")
        left_wrapper.grid(row=1, column=0, sticky="ns", padx=(12, 8), pady=(0, 12))

        self._left_canvas = tk.Canvas(left_wrapper, bg="#050a13", highlightthickness=0, width=340)
        left_scroll = ttk.Scrollbar(left_wrapper, orient="vertical", command=self._left_canvas.yview)
        self._left_canvas.configure(yscrollcommand=left_scroll.set)
        self._left_canvas.pack(side="left", fill="y")
        left_scroll.pack(side="left", fill="y")

        left = ttk.Frame(self._left_canvas, style="Panel.TFrame")
        self._left_window = self._left_canvas.create_window((0, 0), window=left, anchor="nw")

        def _on_left_configure(_event):
            self._left_canvas.configure(scrollregion=self._left_canvas.bbox("all"))

        def _on_left_wheel(event):
            self._left_canvas.yview_scroll(int(-event.delta / 120), "units")

        def _on_left_enter(_event):
            self._left_canvas.bind_all("<MouseWheel>", _on_left_wheel)

        def _on_left_leave(_event):
            self._left_canvas.unbind_all("<MouseWheel>")

        left.bind("<Configure>", _on_left_configure)
        self._left_canvas.bind("<Enter>", _on_left_enter)
        self._left_canvas.bind("<Leave>", _on_left_leave)
        left.bind("<Enter>", _on_left_enter)
        left.bind("<Leave>", _on_left_leave)
        self._left_canvas.itemconfigure(self._left_window, width=340)

        actions = ttk.LabelFrame(left, text="Actions", style="Card.TLabelframe")
        actions.pack(fill="x", pady=(0, 8))
        ttk.Button(actions, text="Recuperer architecture", command=self.on_fetch_architecture, style="Primary.TButton").pack(fill="x", padx=10, pady=(10, 5))

        depth_row = ttk.Frame(actions, style="Card.TFrame")
        depth_row.pack(fill="x", padx=10, pady=(0, 5))
        ttk.Label(depth_row, text="Profondeur", style="Muted.TLabel").pack(side="left")
        ttk.Combobox(
            depth_row,
            textvariable=self.var_depth,
            state="readonly",
            width=12,
            values=["Illimitee", "Niveau 1", "Niveau 2", "Niveau 3"],
        ).pack(side="right")

        self.btn_apply = ttk.Button(actions, text="Appliquer permissions", command=self.on_apply_permissions, state="disabled", style="Danger.TButton")
        self.btn_apply.pack(fill="x", padx=10, pady=(0, 8))

        ttk.Separator(actions, orient="horizontal").pack(fill="x", padx=10, pady=4)
        ttk.Button(actions, text="Importer JSON modifie", command=self.on_import_file, style="Tool.TButton").pack(fill="x", padx=10, pady=(4, 2))
        ttk.Label(actions, textvariable=self.selected_import_file, wraplength=260, style="Muted.TLabel").pack(fill="x", padx=10, pady=(0, 8))

        auth = ttk.LabelFrame(left, text="Connexion", style="Card.TLabelframe")
        auth.pack(fill="x", pady=(0, 8))
        self._pair_field(auth, "Tenant ID", self.var_tenant, "Client ID", self.var_client)
        self._pair_field(auth, "URL SharePoint", self.var_siteurl, "Thumbprint certificat", self.var_thumb)

        cert_row = ttk.Frame(auth, style="Card.TFrame")
        cert_row.pack(fill="x", padx=10, pady=(0, 4))
        cert_row.columnconfigure(0, weight=1)
        ttk.Label(cert_row, text="Certificat (.pfx ou .cer)", style="Muted.TLabel").grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Entry(cert_row, textvariable=self.var_certfile, style="Dark.TEntry").grid(row=1, column=0, sticky="we", padx=(0, 4))
        ttk.Button(cert_row, text="Choisir", command=self._on_browse_certfile, style="Tool.TButton").grid(row=1, column=1)

        pass_row = ttk.Frame(auth, style="Card.TFrame")
        pass_row.pack(fill="x", padx=10, pady=(0, 8))
        ttk.Label(pass_row, text="Mot de passe certificat", style="Muted.TLabel").pack(anchor="w")
        ttk.Entry(pass_row, textvariable=self.var_certpass, show="*", style="Dark.TEntry").pack(fill="x")

        utilities = ttk.LabelFrame(left, text="Onglet", style="Card.TLabelframe")
        utilities.pack(fill="x")
        util_row = ttk.Frame(utilities, style="Card.TFrame")
        util_row.pack(fill="x", padx=10, pady=8)
        ttk.Button(util_row, text="Enregistrer", command=self.app.save_settings, style="Tool.TButton").pack(side="left", fill="x", expand=True, padx=(0, 3))
        ttk.Button(util_row, text="Dupliquer", command=lambda: self.app.duplicate_tab(self), style="Tool.TButton").pack(side="left", fill="x", expand=True, padx=3)
        ttk.Button(util_row, text="Fermer", command=lambda: self.app.close_tab(self), style="Tool.TButton").pack(side="left", fill="x", expand=True, padx=(3, 0))
        ttk.Button(utilities, text="Copier parametres vers un autre onglet", command=lambda: self.app.copy_settings(self), style="Tool.TButton").pack(fill="x", padx=10, pady=(0, 8))

        right = ttk.LabelFrame(self, text="Console de session", style="Card.TLabelframe")
        right.grid(row=1, column=1, sticky="nsew", padx=(0, 12), pady=(0, 12))
        right.rowconfigure(0, weight=1)
        right.columnconfigure(0, weight=1)

        self.console = scrolledtext.ScrolledText(
            right,
            wrap="word",
            state="disabled",
            bg="#050a13",
            fg="#e7f3ff",
            insertbackground="#75e6ff",
            relief="flat",
            font=("Cascadia Mono", 10),
        )
        self.console.grid(row=0, column=0, sticky="nsew", padx=8, pady=8)
        self.progress = ttk.Progressbar(right, mode="indeterminate", style="TProgressbar")
        self.progress.grid(row=1, column=0, sticky="ew", padx=8, pady=(0, 4))
        self.progress.grid_remove()
        self.progress_label = tk.Label(right, text="Operation en cours...", bg="#0b1424", fg="#75e6ff", font=("Segoe UI", 9, "bold"))
        self.progress_label.grid(row=2, column=0, sticky="w", padx=8, pady=(0, 8))
        self.progress_label.grid_remove()
        self.console.tag_configure("ERROR", foreground="#ff5c7a")
        self.console.tag_configure("SUCCESS", foreground="#5cf2a7")
        self.console.tag_configure("WARN", foreground="#ffd166")
        self.console.tag_configure("INFO", foreground="#75e6ff")
        self._log("Nouvel onglet pret. Renseignez le site puis lancez une action.\n", "INFO")

    def _pair_field(self, parent, label1, var1, label2, var2):
        row = ttk.Frame(parent, style="Card.TFrame")
        row.pack(fill="x", padx=10, pady=(0, 4))
        row.columnconfigure(0, weight=1)
        row.columnconfigure(1, weight=1)
        ttk.Label(row, text=label1, style="Muted.TLabel").grid(row=0, column=0, sticky="w", padx=(0, 4))
        ttk.Entry(row, textvariable=var1, style="Dark.TEntry").grid(row=1, column=0, sticky="we", padx=(0, 4))
        ttk.Label(row, text=label2, style="Muted.TLabel").grid(row=0, column=1, sticky="w")
        ttk.Entry(row, textvariable=var2, style="Dark.TEntry").grid(row=1, column=1, sticky="we")

    def _bind_title_updates(self):
        def on_change(*_):
            self.app.refresh_tab_title(self)

        self.var_name.trace_add("write", on_change)
        self.var_siteurl.trace_add("write", on_change)

    def _on_browse_certfile(self):
        path = filedialog.askopenfilename(
            title="Choisir le fichier certificat",
            filetypes=[("Certificat", "*.pfx *.cer"), ("Tous les fichiers", "*.*")],
        )
        if path:
            self.var_certfile.set(path)

    def to_settings(self):
        return {
            "Name": self.var_name.get().strip() or f"Site {self.index}",
            "TenantId": self.var_tenant.get().strip(),
            "ClientId": self.var_client.get().strip(),
            "CertificateThumbprint": self.var_thumb.get().strip(),
            "SiteUrl": self.var_siteurl.get().strip(),
            "CertificatePath": self.var_certfile.get().strip(),
            "Depth": self.var_depth.get().strip() or "Illimitee",
        }

    def _set_running(self, running):
        self.running = running
        self.state_label.configure(text="EN COURS" if running else "PRET", fg="#ffd166" if running else "#5cf2a7")
        if running:
            self.btn_apply.configure(state="disabled")
            self.progress_label.configure(text="Operation en cours...")
            self.progress.grid()
            self.progress_label.grid()
            self.progress.start(12)
        else:
            self.progress.stop()
            self.progress.grid_remove()
            self.progress_label.grid_remove()
            if self.selected_import_path:
                self.btn_apply.configure(state="normal")
        self.app.refresh_tab_title(self)

    def _build_auth_dict(self):
        cert_file = self.var_certfile.get().strip()
        if cert_file:
            return {
                "TenantId": self.var_tenant.get().strip(),
                "ClientId": self.var_client.get().strip(),
                "CertificateThumbprint": "",
                "CertificatePath": cert_file,
                "CertificatePassword": self.var_certpass.get(),
            }
        return {
            "TenantId": self.var_tenant.get().strip(),
            "ClientId": self.var_client.get().strip(),
            "CertificateThumbprint": self.var_thumb.get().strip(),
            "CertificatePath": "",
            "CertificatePassword": "",
        }

    def _validate_auth(self):
        if not self.var_tenant.get().strip() or not self.var_client.get().strip():
            messagebox.showwarning("Parametres manquants", "Renseignez Tenant ID et Client ID.")
            return False
        if not self.var_thumb.get().strip() and not self.var_certfile.get().strip():
            messagebox.showwarning("Certificat manquant", "Renseignez soit le thumbprint, soit un fichier certificat.")
            return False
        if not self.var_siteurl.get().strip():
            messagebox.showwarning("Site manquant", "Renseignez l'URL du site SharePoint.")
            return False
        return True

    def _log(self, text, tag=None):
        self.console.configure(state="normal")
        self.console.insert("end", text, tag) if tag else self.console.insert("end", text)
        self.console.see("end")
        self.console.configure(state="disabled")

    def _extract_bilan(self):
        text = self.console.get("1.0", "end")
        last = ""
        for line in text.splitlines():
            if "BILAN" in line:
                last = line.strip()
        return last

    def on_fetch_architecture(self):
        if self.running or not self._validate_auth():
            return
        out_dir = filedialog.askdirectory(title="Choisir le dossier ou enregistrer l'architecture")
        if out_dir:
            self._run_get_architecture(out_dir)

    def on_import_file(self):
        path = filedialog.askopenfilename(
            title="Choisir le fichier JSON d'architecture modifiee",
            filetypes=[("Fichiers JSON", "*.json")],
        )
        if path:
            self.selected_import_path = path
            self.selected_import_file.set(os.path.basename(path))
            if not self.running:
                self.btn_apply.configure(state="normal")

    def on_apply_permissions(self):
        if self.running or not self._validate_auth():
            return
        if not self.selected_import_path or not os.path.exists(self.selected_import_path):
            messagebox.showwarning("Fichier manquant", "Importez d'abord un JSON d'architecture modifiee.")
            return
        recheck = messagebox.askyesno(
            "Architecture a jour ?",
            "L'architecture SharePoint peut avoir change depuis le dernier export.\n\n"
            "Voulez-vous recuperer l'architecture a jour avant d'appliquer les permissions ?\n"
            "(Recommande - l'export remplacera le fichier actuel)",
        )
        if recheck:
            out_dir = filedialog.askdirectory(title="Choisir le dossier ou enregistrer l'architecture a jour")
            if out_dir:
                self._log("Application mise en attente : recuperation de l'architecture d'abord.\n", "WARN")
                self._run_get_architecture(out_dir)
            return
        confirmed = messagebox.askyesno(
            "Confirmer l'application",
            "Appliquer les modifications de permissions du fichier:\n\n"
            f"{os.path.basename(self.selected_import_path)}\n\n"
            f"sur le site:\n{self.var_siteurl.get().strip()}\n\n"
            "Cette action modifie reellement SharePoint.",
            icon="warning",
        )
        if confirmed:
            self._run_apply_permissions(self.selected_import_path)
        else:
            self._log("Application annulee par l'utilisateur.\n", "WARN")

    def _run_get_architecture(self, out_dir):
        pwsh = find_pwsh()
        if not pwsh:
            messagebox.showerror("PowerShell 7 introuvable", "Installez PowerShell 7 puis reessayez.")
            return
        if not os.path.exists(GET_ARCH_SCRIPT):
            messagebox.showerror("Script introuvable", f"Fichier manquant : {GET_ARCH_SCRIPT}")
            return

        tmp_config = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
        json.dump({"Auth": self._build_auth_dict(), "SiteUrl": self.var_siteurl.get().strip()}, tmp_config, ensure_ascii=False, indent=2)
        tmp_config.close()

        args = [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", GET_ARCH_SCRIPT, "-ConfigFile", tmp_config.name, "-OutputDir", out_dir]
        depth_choice = self.var_depth.get()
        if depth_choice != "Illimitee":
            args += ["-NiveauMax", depth_choice.replace("Niveau ", "").strip()]

        self._log(f"\n=== Recuperation ({depth_choice}) -> {out_dir} ===\n", "SUCCESS")
        self._start_process(args, cleanup=[tmp_config.name])

    def _run_apply_permissions(self, source_path):
        pwsh = find_pwsh()
        if not pwsh:
            messagebox.showerror("PowerShell 7 introuvable", "Installez PowerShell 7 puis reessayez.")
            return
        if not os.path.exists(APPLY_PERMS_SCRIPT):
            messagebox.showerror("Script introuvable", f"Fichier manquant : {APPLY_PERMS_SCRIPT}")
            return

        try:
            with open(source_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception as exc:
            messagebox.showerror("Fichier invalide", f"Impossible de lire le JSON : {exc}")
            return

        data["Auth"] = self._build_auth_dict()
        data["SiteUrl"] = self.var_siteurl.get().strip()

        tmp_config = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(data, tmp_config, ensure_ascii=False, indent=2)
        tmp_config.close()

        args = [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", APPLY_PERMS_SCRIPT, "-ConfigFile", tmp_config.name]
        self._log(f"\n=== Application depuis {os.path.basename(source_path)} ===\n", "SUCCESS")
        self._start_process(args, cleanup=[tmp_config.name])

    def _start_process(self, args, cleanup=None):
        others = [t for t in self.app.tabs if t is not self and t.running]
        if others:
            names = ", ".join(t.var_name.get().strip() or f"Site {t.index}" for t in others)
            if not messagebox.askyesno(
                "Autre operation en cours",
                f"Une operation tourne deja sur : {names}\n\n"
                "Lancer cette operation en parallele quand meme ?",
            ):
                self._log("Operation annulee : une autre operation est deja en cours ailleurs.\n", "WARN")
                return

        if not check_internet():
            if not messagebox.askyesno(
                "Connexion internet",
                "Aucune connexion internet detectee.\n\n"
                "Verifiez votre connexion puis reessayez. Continuer quand meme ?",
                icon="warning",
            ):
                self._log("Operation annulee : pas de connexion internet.\n", "ERROR")
                return

        self._set_running(True)

        def worker():
            try:
                self.process = subprocess.Popen(
                    args,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    creationflags=NO_WINDOW,
                )
                for line in self.process.stdout:
                    self.output_queue.put(("line", line))
                self.process.wait()
                self.output_queue.put(("done", self.process.returncode))
            except Exception as exc:
                self.output_queue.put(("error", str(exc)))
            finally:
                self.process = None
                for path in cleanup or []:
                    try:
                        os.unlink(path)
                    except OSError:
                        pass

        threading.Thread(target=worker, daemon=True).start()

    def poll_queue(self):
        try:
            while True:
                kind, payload = self.output_queue.get_nowait()
                if kind == "line":
                    tag = None
                    if "[ERROR]" in payload or "ECHEC" in payload:
                        tag = "ERROR"
                    elif "[SUCCESS]" in payload or "BILAN" in payload:
                        tag = "SUCCESS"
                    elif "[WARN]" in payload:
                        tag = "WARN"
                    self._log(payload, tag)
                elif kind == "done":
                    self._log(f"\n--- Termine (code retour {payload}) ---\n\n", "SUCCESS" if payload == 0 else "ERROR")
                    self._set_running(False)
                    bilan = self._extract_bilan()
                    name = self.var_name.get().strip() or f"Site {self.index}"
                    summary = f"Operation terminee sur \"{name}\" (code retour {payload})."
                    if bilan:
                        summary += f"\n{bilan}"
                    if payload == 0:
                        summary += "\nToutes les attributions ont reussi."
                    elif payload == 2:
                        summary += "\nDes echecs ont ete enregistres : consultez le journal de session pour le detail. Rappel : les conflits d'heritage sont geres automatiquement (rupture + nouvel essai) ; un echec restant vient souvent des droits de l'application ou d'un principal introuvable."
                    else:
                        summary += "\nL'operation a echoue."
                    self.app.assistant_status(summary, success=(payload == 0))
                elif kind == "error":
                    self._log(f"\nErreur : {payload}\n", "ERROR")
                    self._set_running(False)
        except queue.Empty:
            pass


class AssistantClient:
    """Client HTTP minimal vers une API de chat compatible OpenAI."""

    def __init__(self, endpoint, api_key, model):
        self.endpoint = endpoint
        self.api_key = api_key
        self.model = model

    def ask(self, messages, timeout=120):
        body = {
            "model": self.model,
            "messages": messages,
            "temperature": 0.4,
            "max_tokens": 800,
        }
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.api_key}",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
        choices = payload.get("choices") or []
        if not choices:
            raise RuntimeError("Reponse de l'API vide (structure inattendue).")
        return choices[0]["message"]["content"].strip()


class AssistantConfigDialog(tk.Toplevel):
    """Configuration de l'assistant IA (reservee a l'administrateur)."""

    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("Assistant IA - Configuration (administrateur)")
        self.geometry("560x300")
        self.resizable(False, False)
        self.configure(bg="#0b1424")
        self.transient(app)
        self.grab_set()

        self.var_endpoint = tk.StringVar(value=app.assistant_cfg.get("Endpoint", ""))
        self.var_model = tk.StringVar(value=app.assistant_cfg.get("Model", ""))
        self.var_key = tk.StringVar(value=app.assistant_cfg.get("ApiKey", ""))

        tk.Label(self, text="Configuration de l'assistant IA", bg="#0b1424", fg="#75e6ff", font=("Segoe UI", 13, "bold")).pack(anchor="w", padx=16, pady=(14, 4))
        tk.Label(self, text="Reserve a l'administrateur. L'API doit etre compatible OpenAI (chat/completions).", bg="#0b1424", fg="#91a6c4", font=("Segoe UI", 9)).pack(anchor="w", padx=16, pady=(0, 10))

        tk.Label(self, text="Adresse de l'API", bg="#0b1424", fg="#e7f3ff").pack(anchor="w", padx=16, pady=(6, 2))
        ttk.Entry(self, textvariable=self.var_endpoint, style="Dark.TEntry").pack(fill="x", padx=16)
        tk.Label(self, text="Modele", bg="#0b1424", fg="#e7f3ff").pack(anchor="w", padx=16, pady=(6, 2))
        ttk.Entry(self, textvariable=self.var_model, style="Dark.TEntry").pack(fill="x", padx=16)
        tk.Label(self, text="Cle API", bg="#0b1424", fg="#e7f3ff").pack(anchor="w", padx=16, pady=(6, 2))
        ttk.Entry(self, textvariable=self.var_key, show="*", style="Dark.TEntry").pack(fill="x", padx=16)

        btn_row = tk.Frame(self, bg="#0b1424")
        btn_row.pack(fill="x", padx=16, pady=14)
        ttk.Button(btn_row, text="Enregistrer", command=self._save, style="Primary.TButton").pack(side="right", padx=(6, 0))
        ttk.Button(btn_row, text="Annuler", command=self.destroy, style="Tool.TButton").pack(side="right")

    def _save(self):
        self.app.assistant_cfg.update({
            "Endpoint": self.var_endpoint.get().strip(),
            "Model": self.var_model.get().strip(),
            "ApiKey": self.var_key.get().strip(),
        })
        self.app.save_settings()
        self.destroy()


class AssistantWindow(tk.Toplevel):
    """Fenetre de chat avec l'assistant de support (droits SharePoint)."""

    LABELS = {"user": "Vous", "assistant": "Assistant SPO", "status": "Systeme", "error": "Erreur"}

    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("Assistant SPO - Support & droits d'acces")
        self.geometry("640x680")
        self.minsize(460, 420)
        self.configure(bg="#050a13")
        self.transient(app)
        self.var_context = tk.BooleanVar(value=True)
        self.var_entry = tk.StringVar()
        self.queue = queue.Queue()
        self.history = []
        self.busy = False
        self.link_ranges = []
        self._build_ui()
        self._append(
            "assistant",
            "Bonjour ! Je suis l'Assistant SPO. Posez-moi vos questions sur les droits d'acces "
            "(heritage, rupture d'heritage, roles Lecture / Modification...), ou lancez une operation "
            "et je vous en expliquerai le resultat.",
        )
        self.after(100, self._poll_queue)

    def _build_ui(self):
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)

        header = tk.Frame(self, bg="#07111f", highlightthickness=1, highlightbackground="#20324d")
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(0, weight=1)
        tk.Label(header, text="ASSISTANT SPO", bg="#07111f", fg="#75e6ff", font=("Segoe UI", 12, "bold")).grid(row=0, column=0, sticky="w", padx=14, pady=10)
        ttk.Button(header, text="Config IA", command=self._open_config, style="Tool.TButton").grid(row=0, column=1, sticky="e", padx=(0, 8))
        self.status_label = tk.Label(header, text="pret", bg="#07111f", fg="#5cf2a7", font=("Segoe UI", 10, "bold"))
        self.status_label.grid(row=0, column=2, sticky="e", padx=(0, 14))

        self.chat = scrolledtext.ScrolledText(
            self,
            wrap="word",
            state="disabled",
            bg="#050a13",
            fg="#e7f3ff",
            insertbackground="#75e6ff",
            relief="flat",
            font=("Segoe UI", 10),
        )
        self.chat.grid(row=1, column=0, sticky="nsew", padx=12, pady=(10, 6))
        for tag, color in (("user", "#75e6ff"), ("assistant", "#5cf2a7"), ("status", "#ffd166"), ("error", "#ff5c7a")):
            self.chat.tag_configure(tag, foreground=color)
        for tag, color, size in (("h1", "#75e6ff", 14), ("h2", "#75e6ff", 12), ("h3", "#75e6ff", 11)):
            self.chat.tag_configure(tag, font=("Segoe UI", size, "bold"), foreground=color, spacing1=6)
        self.chat.tag_configure("bold", font=("Segoe UI", 10, "bold"))
        self.chat.tag_configure("italic", font=("Segoe UI", 10, "italic"))
        self.chat.tag_configure("code", background="#0b1424", foreground="#ffd166", font=("Cascadia Mono", 9))
        self.chat.tag_configure("codeblock", background="#0b1424", foreground="#d0e8ff", font=("Cascadia Mono", 9), lmargin1=12, lmargin2=12, rmargin=12, spacing1=2)
        self.chat.tag_configure("quote", foreground="#91a6c4", font=("Segoe UI", 10, "italic"))
        self.chat.tag_configure("bullet", foreground="#75e6ff")
        self.chat.tag_configure("link", foreground="#75e6ff", underline=True)
        self.chat.tag_configure("hr", foreground="#223655")
        self.chat.tag_bind("link", "<Button-1>", self._on_link_click)
        self.chat.tag_bind("link", "<Enter>", lambda _e: self.chat.configure(cursor="hand2"))
        self.chat.tag_bind("link", "<Leave>", lambda _e: self.chat.configure(cursor=""))

        hints = tk.Frame(self, bg="#050a13")
        hints.grid(row=2, column=0, sticky="ew", padx=12)
        for text in ("Pourquoi acces refuse ?", "C'est quoi la rupture d'heritage ?", "Mon dossier est masque, que faire ?"):
            ttk.Button(hints, text=text, style="Tool.TButton", command=lambda t=text: self._quick_question(t)).pack(side="left", padx=(0, 4))

        entry_row = tk.Frame(self, bg="#050a13")
        entry_row.grid(row=3, column=0, sticky="ew", padx=12, pady=(8, 12))
        entry_row.columnconfigure(0, weight=1)
        ttk.Checkbutton(entry_row, text="Contexte session", variable=self.var_context, style="Tool.TCheckbutton").grid(row=0, column=1, sticky="w", padx=(0, 6))
        self.entry = ttk.Entry(entry_row, textvariable=self.var_entry, style="Dark.TEntry")
        self.entry.grid(row=0, column=0, sticky="we")
        self.entry.bind("<Return>", lambda _e: self.on_send())
        ttk.Button(entry_row, text="Envoyer", command=self.on_send, style="Primary.TButton").grid(row=0, column=2, sticky="e", padx=(6, 0))

    def _quick_question(self, text):
        self.var_entry.set(text)
        self.on_send()

    def _open_config(self):
        AssistantConfigDialog(self.app)

    def on_send(self):
        if self.busy:
            return
        text = self.var_entry.get().strip()
        if not text:
            return
        self.var_entry.set("")
        if not self.app.assistant_cfg.get("ApiKey"):
            self._append("status", "L'assistant n'est pas configure : cliquez sur 'Config IA' puis entrez la cle API.")
            self._open_config()
            return
        self._append("user", text)
        messages = [{"role": "system", "content": ASSISTANT_SYSTEM_PROMPT}]
        if self.var_context.get():
            context = self.app.session_context()
            if context:
                messages.append({"role": "user", "content": "CONTEXTE DE SESSION (journal recent de l'outil) :\n" + context})
        self.history.append({"role": "user", "content": text})
        messages.extend(self.history[-12:])
        self.busy = True
        self.status_label.configure(text="en reflexion...", fg="#ffd166")
        threading.Thread(target=self._worker, args=(dict(self.app.assistant_cfg), messages), daemon=True).start()

    def _worker(self, cfg, messages):
        try:
            client = AssistantClient(cfg.get("Endpoint"), cfg.get("ApiKey"), cfg.get("Model"))
            answer = client.ask(messages)
            self.queue.put(("answer", answer))
        except urllib.error.HTTPError as exc:
            try:
                detail = exc.read().decode("utf-8", errors="replace")[:300]
            except Exception:
                detail = ""
            self.queue.put(("error", f"HTTP {exc.code} : {detail or exc.reason}"))
        except Exception as exc:
            self.queue.put(("error", str(exc)))

    def _poll_queue(self):
        try:
            while True:
                kind, payload = self.queue.get_nowait()
                if kind == "answer":
                    self._append("assistant", payload)
                    self.history.append({"role": "assistant", "content": payload})
                else:
                    self._append("error", "Impossible de contacter l'assistant : " + payload)
                self.busy = False
                self.status_label.configure(text="pret", fg="#5cf2a7")
        except queue.Empty:
            pass
        self.after(100, self._poll_queue)

    def _append(self, kind, text):
        if kind == "assistant":
            self._insert_markdown(text)
            return
        self.chat.configure(state="normal")
        prefix = self.LABELS.get(kind, kind)
        self.chat.insert("end", f"\n{prefix} :\n", kind)
        self.chat.insert("end", text + "\n\n")
        self.chat.see("end")
        self.chat.configure(state="disabled")

    def _insert_markdown(self, text):
        """Affiche la reponse de l'assistant avec une visualisation Markdown."""
        self.chat.configure(state="normal")
        self.chat.insert("end", "\nAssistant SPO :\n", "assistant")
        in_code = False
        for raw_line in text.replace("\r", "").split("\n"):
            line = raw_line.rstrip()
            stripped = line.strip()
            if not stripped:
                self.chat.insert("end", "\n")
                continue
            if stripped.startswith("```") or stripped.startswith("~~~"):
                in_code = not in_code
                continue
            if in_code:
                self.chat.insert("end", line, "codeblock")
                self.chat.insert("end", "\n")
                continue
            if stripped.startswith("#"):
                level = 0
                while level < len(stripped) and stripped[level] == "#":
                    level += 1
                if 1 <= level <= 6 and (level == len(stripped) or stripped[level] == " "):
                    self.chat.insert("end", stripped.lstrip("#").strip(), f"h{min(level, 3)}")
                    self.chat.insert("end", "\n")
                    continue
            if re.match(r"^\s*>\s", line):
                self.chat.insert("end", re.sub(r"^\s*>\s?", "", line), "quote")
                self.chat.insert("end", "\n")
                continue
            if re.match(r"^\s*([-*+])\s+\S", line):
                self.chat.insert("end", "  \u2022  ", "bullet")
                self._insert_inline(re.sub(r"^\s*[-*+]\s+", "", line))
                self.chat.insert("end", "\n")
                continue
            if re.match(r"^\s*\d+[.)]\s+\S", line):
                num = re.match(r"^\s*(\d+[.)])", line).group(1)
                self.chat.insert("end", f"  {num}  ", "bullet")
                self._insert_inline(re.sub(r"^\s*\d+[.)]\s+", "", line))
                self.chat.insert("end", "\n")
                continue
            if re.match(r"^\s*-{3,}\s*$", line):
                self.chat.insert("end", "\u2500" * 40 + "\n", "hr")
                continue
            if re.match(r"^\s*\|.*\|\s*$", line):
                self.chat.insert("end", line, "codeblock")
                self.chat.insert("end", "\n")
                continue
            self._insert_inline(line)
            self.chat.insert("end", "\n")
        self.chat.see("end")
        self.chat.configure(state="disabled")

    def _insert_inline(self, line):
        pos = 0
        for match in INLINE_PATTERN.finditer(line):
            before = line[pos:match.start()]
            if before:
                self.chat.insert("end", before)
            token = match.group(0)
            if token.startswith("**") and token.endswith("**") and len(token) > 4:
                self.chat.insert("end", token[2:-2], "bold")
            elif token.startswith("`") and token.endswith("`") and len(token) > 2:
                self.chat.insert("end", token[1:-1], "code")
            elif token.startswith("[") and "](" in token:
                try:
                    label, url = token[1:-1].split("](", 1)
                    url = url.rstrip(")")
                    if url.startswith(("http://", "https://")):
                        start = float(self.chat.index("end"))
                        self.chat.insert("end", label, "link")
                        end = float(self.chat.index("end"))
                        self.link_ranges.append((start, end, url))
                    else:
                        self.chat.insert("end", label)
                except ValueError:
                    self.chat.insert("end", token)
            else:
                self.chat.insert("end", token[1:-1], "italic")
            pos = match.end()
        if pos < len(line):
            self.chat.insert("end", line[pos:])

    def _on_link_click(self, _event):
        try:
            idx = float(self.chat.index(tk.CURRENT))
        except (tk.TclError, ValueError):
            return
        for start, end, url in self.link_ranges:
            if start <= idx < end and url.startswith(("http://", "https://")):
                webbrowser.open(url)
                break

    def notify_status(self, summary):
        try:
            if not self.winfo_exists():
                return
        except tk.TclError:
            return
        self._append("status", summary)
        self.history.append({"role": "system", "content": "STATUT SESSION : " + summary})


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("1280x720")
        self.minsize(900, 560)
        self.configure(bg="#050a13")
        if os.path.exists(ICON_FILE):
            try:
                self.iconbitmap(ICON_FILE)
            except Exception:
                pass
        self.tabs = []
        self.assistant_cfg = dict(ASSISTANT_DEFAULTS)
        self.assistant_window = None
        self._build_theme()
        self._build_shell()
        self._load_settings()
        if not self.tabs:
            self.add_tab()
        self.after(80, self._poll_all_tabs)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(120, lambda: self.state("zoomed"))

    def _build_theme(self):
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Panel.TFrame", background="#050a13")
        style.configure("Card.TFrame", background="#0b1424")
        style.configure("Card.TLabelframe", background="#0b1424", foreground="#e7f3ff", bordercolor="#223655", relief="solid")
        style.configure("Card.TLabelframe.Label", background="#0b1424", foreground="#75e6ff", font=("Segoe UI", 10, "bold"))
        style.configure("Muted.TLabel", background="#0b1424", foreground="#91a6c4")
        style.configure("Dark.TEntry", fieldbackground="#07111f", foreground="#f4f8ff", bordercolor="#223655")
        style.configure(
            "Primary.TButton",
            background="#1565ff",
            foreground="#ffffff",
            bordercolor="#3d8bff",
            lightcolor="#1565ff",
            darkcolor="#0b3fb3",
            padding=(8, 5),
            font=("Segoe UI", 9, "bold"),
        )
        style.map(
            "Primary.TButton",
            background=[("disabled", "#33415e"), ("pressed", "#0b47c9"), ("active", "#2b7cff")],
            foreground=[("disabled", "#9fb2cc"), ("pressed", "#ffffff"), ("active", "#ffffff")],
        )
        style.configure(
            "Danger.TButton",
            background="#ff3b6b",
            foreground="#ffffff",
            bordercolor="#ff6b90",
            lightcolor="#ff3b6b",
            darkcolor="#b0143c",
            padding=(8, 5),
            font=("Segoe UI", 9, "bold"),
        )
        style.map(
            "Danger.TButton",
            background=[("disabled", "#4a2a35"), ("pressed", "#d61e4e"), ("active", "#ff5c7a")],
            foreground=[("disabled", "#e0a8b5"), ("pressed", "#ffffff"), ("active", "#ffffff")],
        )
        style.configure("Tool.TButton", background="#101d31", foreground="#e7f3ff", padding=(7, 4))
        style.map("Tool.TButton", background=[("active", "#172840")])
        style.configure("Tool.TCheckbutton", background="#050a13", foreground="#91a6c4")
        style.configure("TNotebook", background="#050a13", borderwidth=0)
        style.configure("TNotebook.Tab", background="#0b1424", foreground="#91a6c4", padding=(16, 9), font=("Segoe UI", 10, "bold"))
        style.map("TNotebook.Tab", background=[("selected", "#132746")], foreground=[("selected", "#ffffff")])
        style.configure("TProgressbar", background="#1565ff", troughcolor="#0b1424", bordercolor="#223655", lightcolor="#1565ff", darkcolor="#0b1424")

    def _build_shell(self):
        shell = tk.Frame(self, bg="#050a13")
        shell.pack(fill="both", expand=True)

        header = tk.Frame(shell, bg="#050a13")
        header.pack(fill="x", padx=14, pady=(14, 8))
        header.columnconfigure(0, weight=1)

        tk.Label(header, text="SPO PERMISSIONS // MULTI-SITES", bg="#050a13", fg="#f4f8ff", font=("Segoe UI", 18, "bold")).grid(row=0, column=0, sticky="w")
        self.counter_label = tk.Label(header, text="0 / 10 onglets", bg="#050a13", fg="#75e6ff", font=("Segoe UI", 10, "bold"))
        self.counter_label.grid(row=1, column=0, sticky="w", pady=(2, 0))

        toolbar = tk.Frame(header, bg="#050a13")
        toolbar.grid(row=0, column=1, rowspan=2, sticky="e")
        ttk.Button(toolbar, text="+ Nouvel onglet", command=self.add_tab, style="Primary.TButton").pack(side="left", padx=4)
        ttk.Button(toolbar, text="Dupliquer", command=self.duplicate_current_tab, style="Tool.TButton").pack(side="left", padx=4)
        ttk.Button(toolbar, text="Fermer", command=self.close_current_tab, style="Tool.TButton").pack(side="left", padx=4)
        ttk.Button(toolbar, text="Enregistrer", command=self.save_settings, style="Tool.TButton").pack(side="left", padx=4)
        ttk.Button(toolbar, text="Assistant SPO", command=self.open_assistant, style="Primary.TButton").pack(side="left", padx=4)

        self.notebook = ttk.Notebook(shell)
        self.notebook.pack(fill="both", expand=True, padx=14, pady=(0, 14))

    def add_tab(self, initial=None):
        if len(self.tabs) >= MAX_TABS:
            messagebox.showinfo("Limite atteinte", f"Vous pouvez ouvrir au maximum {MAX_TABS} onglets.")
            return None
        tab = SiteTab(self, len(self.tabs) + 1, initial=initial)
        self.tabs.append(tab)
        self.notebook.add(tab, text=self._tab_title(tab))
        self.notebook.select(tab)
        self._refresh_counter()
        return tab

    def duplicate_current_tab(self):
        current = self.current_tab()
        if current:
            self.duplicate_tab(current)

    def duplicate_tab(self, tab):
        data = tab.to_settings()
        data["Name"] = f"{data['Name']} copie"
        self.add_tab(data)

    def close_current_tab(self):
        tab = self.current_tab()
        if tab:
            self.close_tab(tab)

    def close_tab(self, tab):
        if len(self.tabs) <= 1:
            messagebox.showinfo("Onglet requis", "Gardez au moins un onglet ouvert.")
            return
        name = tab.var_name.get().strip() or f"Site {tab.index}"
        if tab.running:
            if not messagebox.askyesno(
                "Operation en cours",
                f"Une operation tourne encore dans l'onglet \"{name}\".\n\n"
                "Fermer cet onglet quand meme ? (le processus continuera en arriere-plan)",
                icon="warning",
            ):
                return
        elif not messagebox.askyesno("Fermer l'onglet", f"Fermer l'onglet \"{name}\" ?"):
            return
        self.notebook.forget(tab)
        self.tabs.remove(tab)
        tab.destroy()
        for idx, item in enumerate(self.tabs, start=1):
            item.index = idx
            self.refresh_tab_title(item)
        self._refresh_counter()

    def copy_settings(self, tab):
        others = [t for t in self.tabs if t is not tab]
        if not others:
            messagebox.showinfo("Copie impossible", "Aucun autre onglet disponible.")
            return
        label = "\n".join(f"  {t.index}. {t.var_name.get().strip() or f'Site {t.index}'}" for t in others)
        answer = simpledialog.askstring(
            "Copier les parametres de connexion",
            f"Onglets disponibles :\n{label}\n\n"
            "Saisissez le numero ou le nom de l'onglet cible :",
            parent=self,
        )
        if not answer:
            return
        key = answer.strip().lower()
        target = next(
            (t for t in others if key == str(t.index) or key == (t.var_name.get().strip().lower())),
            None,
        )
        if not target:
            messagebox.showwarning("Onglet introuvable", "Aucun onglet ne correspond a votre saisie.")
            return
        for attr in ("var_tenant", "var_client", "var_thumb", "var_siteurl", "var_certfile", "var_certpass", "var_depth"):
            getattr(target, attr).set(getattr(tab, attr).get())
        target._log(f"Parametres de connexion copies depuis \"{tab.var_name.get().strip() or f'Site {tab.index}'}\".\n", "SUCCESS")
        self.refresh_tab_title(target)

    def current_tab(self):
        selected = self.notebook.select()
        if not selected:
            return None
        widget = self.nametowidget(selected)
        return widget if isinstance(widget, SiteTab) else None

    def open_assistant(self):
        window = self.assistant_window
        if window is not None:
            try:
                if window.winfo_exists():
                    window.lift()
                    window.focus_force()
                    return
            except tk.TclError:
                pass
        self.assistant_window = AssistantWindow(self)

    def session_context(self, max_chars=6000):
        tab = self.current_tab()
        if tab is None:
            return None
        try:
            text = tab.console.get("1.0", "end").strip()
        except Exception:
            return None
        return text[-max_chars:] if text else None

    def assistant_status(self, summary, success=True):
        window = self.assistant_window
        if window is None:
            return
        try:
            if window.winfo_exists():
                window.notify_status(summary)
        except tk.TclError:
            pass

    def refresh_tab_title(self, tab):
        if tab in self.tabs:
            self.notebook.tab(tab, text=self._tab_title(tab))
            self._refresh_counter()

    def _tab_title(self, tab):
        title = tab.var_name.get().strip()
        if not title:
            site = tab.var_siteurl.get().rstrip("/").split("/")[-1]
            title = site or f"Site {tab.index}"
        if len(title) > 22:
            title = title[:20] + "\u2026"
        status = " \u25cf" if tab.running else ""
        return f"{tab.index}. {title}{status}"

    def _refresh_counter(self):
        active = sum(1 for tab in self.tabs if tab.running)
        self.counter_label.configure(text=f"{len(self.tabs)} / {MAX_TABS} onglets - {active} actif(s)")

    def _load_settings(self):
        if not os.path.exists(SETTINGS_FILE):
            return
        try:
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            return

        if isinstance(data, dict) and isinstance(data.get("Tabs"), list):
            for tab_data in data["Tabs"][:MAX_TABS]:
                self.add_tab(tab_data)
            active = min(max(int(data.get("ActiveTab", 0)), 0), max(len(self.tabs) - 1, 0))
            if self.tabs:
                self.notebook.select(self.tabs[active])
            return

        if isinstance(data, dict):
            self.add_tab({
                "Name": "Site principal",
                "TenantId": data.get("TenantId", ""),
                "ClientId": data.get("ClientId", ""),
                "CertificateThumbprint": data.get("CertificateThumbprint", ""),
                "SiteUrl": data.get("SiteUrl", ""),
                "CertificatePath": data.get("CertificatePath", ""),
                "Depth": "Illimitee",
            })

        if isinstance(data.get("Assistant"), dict):
            for key in ASSISTANT_DEFAULTS:
                value = data["Assistant"].get(key)
                if value:
                    self.assistant_cfg[key] = value

    def save_settings(self):
        active_index = 0
        current = self.current_tab()
        if current in self.tabs:
            active_index = self.tabs.index(current)
        data = {"Version": 2, "ActiveTab": active_index, "Tabs": [tab.to_settings() for tab in self.tabs], "Assistant": dict(self.assistant_cfg)}
        try:
            with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            if current:
                current._log("Parametres multi-sites enregistres.\n", "SUCCESS")
        except Exception as exc:
            messagebox.showerror("Erreur", f"Impossible d'enregistrer les parametres : {exc}")

    def _poll_all_tabs(self):
        for tab in list(self.tabs):
            tab.poll_queue()
        self._refresh_counter()
        self.after(80, self._poll_all_tabs)

    def _on_close(self):
        running = [t for t in self.tabs if t.running]
        if running:
            names = ", ".join(t.var_name.get().strip() or f"Site {t.index}" for t in running)
            if not messagebox.askyesno(
                "Operations en cours",
                f"Operation(s) encore active(s) sur : {names}\n\n"
                "Fermer l'application quand meme ? (les processus continueront en arriere-plan)",
                icon="warning",
            ):
                return
        self.save_settings()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()