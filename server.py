from http.server import HTTPServer, SimpleHTTPRequestHandler
import socket
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, simpledialog
import os
import sys
import webbrowser
import time
import json
import subprocess
import platform
import re
from datetime import datetime
from collections import defaultdict, Counter
import psutil  # Pour les stats réseau (à installer: pip install psutil)

class NetworkAdminGUI:
    def __init__(self):
        self.server = None
        self.ip = self.get_ip()
        self.current_directory = os.getcwd()
        self.auto_restart = True
        self.whitelist = set()
        self.blacklist = set()
        self.active_connections = {}
        self.connection_history = []
        self.traffic_stats = defaultdict(int)  # {ip: octets}
        self.alerts_enabled = True
        self.scan_results = []
        
        # Interface graphique
        self.root = tk.Tk()

        # Gestion du chemin (Python / Exe)
        if getattr(sys, 'frozen', False):
             base_path = sys._MEIPASS
        else:
             base_path = os.path.abspath(".")
        # Charger le PNG
        icon_path = os.path.join(base_path, "logo.png")
        icon_image = tk.PhotoImage(file=icon_path)

        # Appliquer l'icône
        self.root.iconphoto(True, icon_image)
        # IMPORTANT : garder une référence
        self.icon_image = icon_image
        self.root.title("🔧 AdminServeur Pro - Gestion Réseau Avancée ( Renard)")
        self.root.geometry("950x650")
        self.root.minsize(900, 600)
        
        # Style moderne
        style = ttk.Style()
        style.theme_use('clam')
        style.configure('TNotebook.Tab', padding=[12, 8], font=('Arial', 10, 'bold'))
        style.configure('TFrame', background='#f5f5f5')
        
        # Barre de statut en bas
        self.status_var = tk.StringVar(value="Prêt - Aucun serveur actif")
        status_bar = tk.Label(self.root, textvariable=self.status_var, 
                            bd=1, relief=tk.SUNKEN, anchor=tk.W, bg="#e0e0e0")
        status_bar.pack(side=tk.BOTTOM, fill=tk.X)
        
        # Titre principal
        tk.Label(self.root, text="🔧 AdminServeur Pro", 
                font=("Arial", 18, "bold"), fg="#2c3e50").pack(pady=10)
        
        # Notebook (onglets)
        notebook = ttk.Notebook(self.root)
        notebook.pack(fill="both", expand=True, padx=10, pady=5)
        
        # Onglet 1: Serveur
        self.tab_server = ttk.Frame(notebook)
        notebook.add(self.tab_server, text="🚀 Serveur HTTP")
        self.create_server_tab()
        
        # Onglet 2: Sécurité
        self.tab_security = ttk.Frame(notebook)
        notebook.add(self.tab_security, text="🛡️ Sécurité")
        self.create_security_tab()
        
        # Onglet 3: Réseau
        self.tab_network = ttk.Frame(notebook)
        notebook.add(self.tab_network, text="🌐 Réseau Local")
        self.create_network_tab()
        
        # Onglet 4: Statistiques
        self.tab_stats = ttk.Frame(notebook)
        notebook.add(self.tab_stats, text="📊 Statistiques")
        self.create_stats_tab()
        
        # Onglet 5: Alertes
        self.tab_alerts = ttk.Frame(notebook)
        notebook.add(self.tab_alerts, text="🔔 Alertes")
        self.create_alerts_tab()
        
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.update_status_bar()
        self.root.after(1000, self.update_realtime_stats)
        self.root.mainloop()
    
    # ==================== UTILITAIRES RÉSEAU ====================
    def get_ip(self):
        """Récupère l'adresse IP locale"""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except:
            return '127.0.0.1'
    
    def get_wifi_ssid(self):
        """Récupère le nom du réseau WiFi actuel"""
        try:
            system = platform.system()
            if system == "Windows":
                result = subprocess.check_output(['netsh', 'wlan', 'show', 'interfaces'], 
                                              encoding='utf-8', errors='ignore')
                match = re.search(r'SSID\s*:\s*(.+)', result)
                return match.group(1).strip() if match else "Câblé / Inconnu"
            elif system == "Darwin":  # macOS
                result = subprocess.check_output(['/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport', '-I'], 
                                              encoding='utf-8', errors='ignore')
                match = re.search(r' SSID: (.+)', result)
                return match.group(1).strip() if match else "Câblé / Inconnu"
            elif system == "Linux":
                result = subprocess.check_output(['iwgetid', '-r'], 
                                              encoding='utf-8', errors='ignore', stderr=subprocess.DEVNULL)
                return result.strip() or "Câblé / Inconnu"
        except:
            return "Non détecté"
    
    def scan_local_network(self):
        """Scan rapide du réseau local pour découvrir les machines"""
        self.log("🔍 Démarrage du scan réseau...")
        self.scan_results = []
        
        # Déterminer la plage IP du réseau local
        base_ip = ".".join(self.ip.split(".")[:3])
        threads = []
        
        def ping_host(ip):
            param = '-n' if platform.system().lower() == 'windows' else '-c'
            command = ['ping', param, '1', '-w', '500', ip]
            try:
                result = subprocess.run(command, stdout=subprocess.DEVNULL, 
                                      stderr=subprocess.DEVNULL, timeout=1)
                if result.returncode == 0:
                    try:
                        hostname = socket.gethostbyaddr(ip)[0]
                    except:
                        hostname = "Inconnu"
                    self.scan_results.append((ip, hostname))
                    self.log(f"✅ {ip} - {hostname}")
            except:
                pass
        
        # Scanner les 254 adresses possibles (exclure .0 et .255)
        for i in range(1, 255):
            if i == int(self.ip.split('.')[-1]):  # Skip self
                continue
            ip = f"{base_ip}.{i}"
            t = threading.Thread(target=ping_host, args=(ip,), daemon=True)
            t.start()
            threads.append(t)
            if len(threads) > 50:  # Limiter le nombre de threads simultanés
                for t in threads:
                    t.join()
                threads = []
        
        for t in threads:
            t.join()
        
        self.log(f"✅ Scan terminé : {len(self.scan_results)} machines détectées")
        self.update_network_table()
        return self.scan_results
    
    def get_network_interfaces(self):
        """Liste les interfaces réseau disponibles"""
        interfaces = []
        for iface, addrs in psutil.net_if_addrs().items():
            for addr in addrs:
                if addr.family == socket.AF_INET and not addr.address.startswith('127.'):
                    interfaces.append((iface, addr.address))
        return interfaces
    
    # ==================== ONGLET SERVEUR ====================
    def create_server_tab(self):
        main_frame = ttk.Frame(self.tab_server, padding=15)
        main_frame.pack(fill="both", expand=True)
        
        # PanedWindow horizontal
        paned = ttk.PanedWindow(main_frame, orient=tk.HORIZONTAL)
        paned.pack(fill="both", expand=True, pady=5)
        
        # Gauche: Configuration
        left_frame = ttk.LabelFrame(paned, text="⚙️ Configuration", padding=10)
        
        # Répertoire
        ttk.Label(left_frame, text="Dossier partagé :").grid(row=0, column=0, sticky="w", pady=5)
        dir_frame = ttk.Frame(left_frame)
        dir_frame.grid(row=1, column=0, columnspan=2, sticky="ew", pady=5)
        self.dir_entry = ttk.Entry(dir_frame, width=30)
        self.dir_entry.insert(0, self.current_directory)
        self.dir_entry.pack(side=tk.LEFT, fill="x", expand=True, padx=(0, 5))
        self.dir_entry.bind('<Return>', lambda e: self.restart_server_if_running())
        ttk.Button(dir_frame, text="📁 Choisir", command=self.browse_directory, width=10).pack(side=tk.LEFT)
        ttk.Button(dir_frame, text="🔄 Actuel", command=self.use_current_directory, width=10).pack(side=tk.LEFT, padx=(5, 0))
        
        # Options
        self.auto_restart_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(left_frame, text="🔄 Redémarrer auto au changement", 
                       variable=self.auto_restart_var).grid(row=2, column=0, columnspan=2, sticky="w", pady=5)
        
        # Port
        ttk.Label(left_frame, text="Port :").grid(row=3, column=0, sticky="w", pady=5)
        self.port_entry = ttk.Entry(left_frame, width=10)
        self.port_entry.insert(0, "8000")
        self.port_entry.grid(row=3, column=1, sticky="w", pady=5)
        
        # IP & WiFi
        ttk.Label(left_frame, text="📡 IP Locale :").grid(row=4, column=0, sticky="w", pady=5)
        self.ip_label = ttk.Label(left_frame, text=self.ip, foreground="#2196F3", font=("Arial", 10, "bold"))
        self.ip_label.grid(row=4, column=1, sticky="w", pady=5)
        
        ttk.Label(left_frame, text="📶 WiFi :").grid(row=5, column=0, sticky="w", pady=5)
        self.wifi_label = ttk.Label(left_frame, text=self.get_wifi_ssid(), foreground="#4CAF50", font=("Arial", 10))
        self.wifi_label.grid(row=5, column=1, sticky="w", pady=5)
        
        # Boutons contrôle
        btn_frame = ttk.Frame(left_frame)
        btn_frame.grid(row=6, column=0, columnspan=2, pady=15, sticky="ew")
        self.start_btn = ttk.Button(btn_frame, text="▶️ Démarrer Serveur", 
                                   command=self.start_server, style="Start.TButton")
        self.start_btn.pack(side=tk.LEFT, fill="x", expand=True, padx=2)
        self.stop_btn = ttk.Button(btn_frame, text="⏹️ Arrêter Serveur", 
                                  command=self.stop_server, state=tk.DISABLED, style="Stop.TButton")
        self.stop_btn.pack(side=tk.LEFT, fill="x", expand=True, padx=2)
        
        # URL d'accès
        ttk.Label(left_frame, text="🔗 URL d'accès :", font=("Arial", 10, "bold")).grid(row=7, column=0, columnspan=2, sticky="w", pady=(10,5))
        self.url_label = ttk.Label(left_frame, text="http://...", foreground="#2196F3", wraplength=280)
        self.url_label.grid(row=8, column=0, columnspan=2, sticky="w", pady=5)
        
        # Droite: Logs
        right_frame = ttk.LabelFrame(paned, text="📡 Journal des connexions", padding=10)
        
        # Barre de recherche logs
        search_frame = ttk.Frame(right_frame)
        search_frame.pack(fill="x", pady=(0, 5))
        ttk.Label(search_frame, text="🔍 Filtrer :").pack(side=tk.LEFT)
        self.log_filter = ttk.Entry(search_frame, width=20)
        self.log_filter.pack(side=tk.LEFT, padx=5)
        self.log_filter.bind('<KeyRelease>', self.filter_logs)
        
        # Zone de logs
        log_container = ttk.Frame(right_frame)
        log_container.pack(fill="both", expand=True)
        self.log_text = tk.Text(log_container, height=20, width=50, font=("Courier", 9), 
                               bg="#f8f8f8", fg="#333")
        self.log_text.pack(side=tk.LEFT, fill="both", expand=True)
        log_scroll = ttk.Scrollbar(log_container, command=self.log_text.yview)
        log_scroll.pack(side=tk.RIGHT, fill="y")
        self.log_text.config(yscrollcommand=log_scroll.set)
        
        # Boutons rapides
        quick_btns = ttk.Frame(right_frame)
        quick_btns.pack(fill="x", pady=5)
        ttk.Button(quick_btns, text="🗑️ Effacer", command=self.clear_logs, width=12).pack(side=tk.LEFT, padx=2)
        ttk.Button(quick_btns, text="💾 Sauvegarder", command=self.save_logs, width=12).pack(side=tk.LEFT, padx=2)
        ttk.Button(quick_btns, text="🌐 Ouvrir", command=self.open_in_browser, width=12).pack(side=tk.LEFT, padx=2)
        
        paned.add(left_frame, weight=1)
        paned.add(right_frame, weight=2)
        
        # Style des boutons
        style = ttk.Style()
        style.configure("Start.TButton", background="#4CAF50", foreground="white", font=("Arial", 10, "bold"))
        style.configure("Stop.TButton", background="#f44336", foreground="white", font=("Arial", 10, "bold"))
    
    # ==================== ONGLET SÉCURITÉ ====================
    def create_security_tab(self):
        main_frame = ttk.Frame(self.tab_security, padding=15)
        main_frame.pack(fill="both", expand=True)
        
        # Whitelist/Blacklist
        list_frame = ttk.LabelFrame(main_frame, text="🛡️ Contrôle d'accès", padding=10)
        list_frame.pack(fill="x", pady=5)
        
        # Whitelist
        wl_frame = ttk.Frame(list_frame)
        wl_frame.pack(fill="x", pady=5)
        ttk.Label(wl_frame, text="✅ IPs autorisées (Whitelist) :").pack(anchor="w")
        self.wl_entry = ttk.Entry(wl_frame, width=30)
        self.wl_entry.pack(side=tk.LEFT, padx=5)
        ttk.Button(wl_frame, text="Ajouter", command=self.add_whitelist).pack(side=tk.LEFT)
        
        self.wl_listbox = tk.Listbox(list_frame, height=4, width=50, font=("Arial", 9))
        self.wl_listbox.pack(fill="x", pady=5)
        ttk.Button(list_frame, text="❌ Supprimer sélection", 
                  command=lambda: self.remove_from_list(self.wl_listbox, self.whitelist)).pack(anchor="w")
        
        # Blacklist
        bl_frame = ttk.Frame(list_frame)
        bl_frame.pack(fill="x", pady=5)
        ttk.Label(bl_frame, text="❌ IPs bloquées (Blacklist) :").pack(anchor="w")
        self.bl_entry = ttk.Entry(bl_frame, width=30)
        self.bl_entry.pack(side=tk.LEFT, padx=5)
        ttk.Button(bl_frame, text="Ajouter", command=self.add_blacklist).pack(side=tk.LEFT)
        
        self.bl_listbox = tk.Listbox(list_frame, height=4, width=50, font=("Arial", 9))
        self.bl_listbox.pack(fill="x", pady=5)
        ttk.Button(list_frame, text="❌ Supprimer sélection", 
                  command=lambda: self.remove_from_list(self.bl_listbox, self.blacklist)).pack(anchor="w")
        
        # Mode de sécurité
        mode_frame = ttk.Frame(main_frame)
        mode_frame.pack(fill="x", pady=10)
        self.security_mode = tk.StringVar(value="open")
        ttk.Radiobutton(mode_frame, text="🔓 Ouvert (tout le monde)", 
                       variable=self.security_mode, value="open").pack(side=tk.LEFT, padx=10)
        ttk.Radiobutton(mode_frame, text="✅ Whitelist uniquement", 
                       variable=self.security_mode, value="whitelist").pack(side=tk.LEFT, padx=10)
        ttk.Radiobutton(mode_frame, text="❌ Bloquer blacklist", 
                       variable=self.security_mode, value="blacklist").pack(side=tk.LEFT, padx=10)
        
        # Connexions actives
        conn_frame = ttk.LabelFrame(main_frame, text="👥 Connexions actives", padding=10)
        conn_frame.pack(fill="both", expand=True, pady=5)
        
        self.conn_tree = ttk.Treeview(conn_frame, columns=("ip", "time", "files"), show="headings", height=8)
        self.conn_tree.heading("ip", text="Adresse IP")
        self.conn_tree.heading("time", text="Connecté depuis")
        self.conn_tree.heading("files", text="Fichiers accédés")
        self.conn_tree.column("ip", width=150)
        self.conn_tree.column("time", width=150)
        self.conn_tree.column("files", width=200)
        self.conn_tree.pack(fill="both", expand=True, pady=5)
        
        btn_frame = ttk.Frame(conn_frame)
        btn_frame.pack(fill="x", pady=5)
        ttk.Button(btn_frame, text="🔄 Rafraîchir", command=self.update_active_connections).pack(side=tk.LEFT, padx=5)
        ttk.Button(btn_frame, text="❌ Bloquer sélection", command=self.block_selected_ip).pack(side=tk.LEFT, padx=5)
        ttk.Button(btn_frame, text="⚠️ Déconnecter", command=self.disconnect_selected).pack(side=tk.LEFT, padx=5)
    
    # ==================== ONGLET RÉSEAU ====================
    def create_network_tab(self):
        main_frame = ttk.Frame(self.tab_network, padding=15)
        main_frame.pack(fill="both", expand=True)
        
        # Informations réseau
        info_frame = ttk.LabelFrame(main_frame, text="📡 Informations réseau", padding=10)
        info_frame.pack(fill="x", pady=5)
        
        grid = ttk.Frame(info_frame)
        grid.pack(fill="x")
        
        ttk.Label(grid, text="IP Publique :", font=("Arial", 10, "bold")).grid(row=0, column=0, sticky="w", pady=3)
        self.public_ip_label = ttk.Label(grid, text="Chargement...", foreground="#2196F3")
        self.public_ip_label.grid(row=0, column=1, sticky="w", pady=3)
        
        ttk.Label(grid, text="WiFi actuel :", font=("Arial", 10, "bold")).grid(row=1, column=0, sticky="w", pady=3)
        self.ssid_label = ttk.Label(grid, text=self.get_wifi_ssid(), foreground="#4CAF50")
        self.ssid_label.grid(row=1, column=1, sticky="w", pady=3)
        
        ttk.Label(grid, text="Interfaces :", font=("Arial", 10, "bold")).grid(row=2, column=0, sticky="w", pady=3)
        interfaces = self.get_network_interfaces()
        iface_text = ", ".join([f"{name}({ip})" for name, ip in interfaces[:3]]) if interfaces else "Aucune"
        ttk.Label(grid, text=iface_text, wraplength=400).grid(row=2, column=1, sticky="w", pady=3)
        
        ttk.Button(info_frame, text="🔄 Actualiser", command=self.refresh_network_info).pack(anchor="e", pady=5)
        
        # Scan réseau
        scan_frame = ttk.LabelFrame(main_frame, text="🔍 Découverte réseau", padding=10)
        scan_frame.pack(fill="both", expand=True, pady=10)
        
        btn_scan = ttk.Button(scan_frame, text="🚀 Scanner le réseau local", 
                            command=self.start_network_scan, style="Scan.TButton")
        btn_scan.pack(fill="x", pady=5)
        
        # Résultats du scan
        self.scan_tree = ttk.Treeview(scan_frame, columns=("ip", "hostname"), show="headings", height=10)
        self.scan_tree.heading("ip", text="Adresse IP")
        self.scan_tree.heading("hostname", text="Nom d'hôte")
        self.scan_tree.column("ip", width=150)
        self.scan_tree.column("hostname", width=250)
        self.scan_tree.pack(fill="both", expand=True, pady=5)
        
        style = ttk.Style()
        style.configure("Scan.TButton", background="#FF9800", foreground="white", font=("Arial", 10, "bold"))
    
    # ==================== ONGLET STATISTIQUES ====================
    def create_stats_tab(self):
        main_frame = ttk.Frame(self.tab_stats, padding=15)
        main_frame.pack(fill="both", expand=True)
        
        # Statistiques en temps réel
        stats_frame = ttk.LabelFrame(main_frame, text="📈 Statistiques en temps réel", padding=10)
        stats_frame.pack(fill="x", pady=5)
        
        grid = ttk.Frame(stats_frame)
        grid.pack(fill="x")
        
        self.users_count = ttk.Label(grid, text="👥 Utilisateurs : 0", font=("Arial", 12, "bold"), foreground="#2196F3")
        self.users_count.grid(row=0, column=0, padx=15, pady=5)
        
        self.traffic_count = ttk.Label(grid, text="📦 Trafic : 0 Octets", font=("Arial", 12, "bold"), foreground="#4CAF50")
        self.traffic_count.grid(row=0, column=1, padx=15, pady=5)
        
        self.files_count = ttk.Label(grid, text="📁 Fichiers servis : 0", font=("Arial", 12, "bold"), foreground="#FF9800")
        self.files_count.grid(row=0, column=2, padx=15, pady=5)
        
        # Historique des connexions
        history_frame = ttk.LabelFrame(main_frame, text="📋 Historique des connexions", padding=10)
        history_frame.pack(fill="both", expand=True, pady=10)
        
        self.history_tree = ttk.Treeview(history_frame, columns=("time", "ip", "file", "status"), show="headings", height=12)
        self.history_tree.heading("time", text="Heure")
        self.history_tree.heading("ip", text="IP")
        self.history_tree.heading("file", text="Fichier")
        self.history_tree.heading("status", text="Statut")
        self.history_tree.column("time", width=120)
        self.history_tree.column("ip", width=120)
        self.history_tree.column("file", width=200)
        self.history_tree.column("status", width=80)
        self.history_tree.pack(fill="both", expand=True, pady=5)
        
        scroll = ttk.Scrollbar(history_frame, orient="vertical", command=self.history_tree.yview)
        scroll.pack(side=tk.RIGHT, fill="y")
        self.history_tree.config(yscrollcommand=scroll.set)
    
    # ==================== ONGLET ALERTES ====================
    def create_alerts_tab(self):
        main_frame = ttk.Frame(self.tab_alerts, padding=15)
        main_frame.pack(fill="both", expand=True)
        
        # Configuration des alertes
        config_frame = ttk.LabelFrame(main_frame, text="🔔 Configuration des alertes", padding=10)
        config_frame.pack(fill="x", pady=5)
        
        self.alerts_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(config_frame, text="✅ Activer les alertes", variable=self.alerts_var).pack(anchor="w", pady=5)
        
        ttk.Label(config_frame, text="Déclencher une alerte quand :").pack(anchor="w", pady=(5,0))
        self.alert_new_ip = tk.BooleanVar(value=True)
        ttk.Checkbutton(config_frame, text="Nouvelle IP se connecte", variable=self.alert_new_ip).pack(anchor="w")
        self.alert_blocked = tk.BooleanVar(value=True)
        ttk.Checkbutton(config_frame, text="Tentative d'accès bloquée", variable=self.alert_blocked).pack(anchor="w")
        
        # Journal des alertes
        alert_frame = ttk.LabelFrame(main_frame, text="🚨 Journal des alertes", padding=10)
        alert_frame.pack(fill="both", expand=True, pady=10)
        
        self.alert_text = tk.Text(alert_frame, height=15, width=70, font=("Courier", 9), 
                                bg="#fff3e0", fg="#e65100", wrap=tk.WORD)
        self.alert_text.pack(fill="both", expand=True, pady=5)
        self.alert_text.insert(tk.END, "ℹ️ Aucune alerte pour le moment\n")
        
        btn_frame = ttk.Frame(alert_frame)
        btn_frame.pack(fill="x", pady=5)
        ttk.Button(btn_frame, text="🗑️ Effacer", command=lambda: self.alert_text.delete(1.0, tk.END)).pack(side=tk.LEFT, padx=5)
        ttk.Button(btn_frame, text="🔊 Tester alerte", command=self.test_alert).pack(side=tk.LEFT, padx=5)
    
    # ==================== FONCTIONS SERVEUR ====================
    def browse_directory(self):
        directory = filedialog.askdirectory(title="Sélectionnez le répertoire à partager")
        if directory:
            self.dir_entry.delete(0, tk.END)
            self.dir_entry.insert(0, directory)
            self.log(f"📁 Dossier sélectionné : {directory}")
            if self.auto_restart_var.get() and self.server:
                self.log("🔄 Redémarrage automatique...")
                self.root.after(100, self.restart_server)
    
    def use_current_directory(self):
        current = os.getcwd()
        self.dir_entry.delete(0, tk.END)
        self.dir_entry.insert(0, current)
        self.log(f"📁 Dossier courant : {current}")
        if self.auto_restart_var.get() and self.server:
            self.log("🔄 Redémarrage automatique...")
            self.root.after(100, self.restart_server)
    
    def restart_server_if_running(self):
        if self.server and self.auto_restart_var.get():
            self.log("🔄 Redémarrage automatique (entrée clavier)...")
            self.root.after(100, self.restart_server)
    
    def start_server(self):
        try:
            port = int(self.port_entry.get())
            directory = self.dir_entry.get()
            
            if not os.path.isdir(directory):
                messagebox.showerror("Erreur", f"Dossier introuvable :\n{directory}")
                return
            if not (1 <= port <= 65535):
                messagebox.showerror("Erreur", "Port invalide (1-65535)")
                return
            
            # Handler sécurisé avec logging avancé
            class SecureHandler(SimpleHTTPRequestHandler):
                def __init__(handler_self, *args, **kwargs):
                    kwargs['directory'] = directory
                    super().__init__(*args, **kwargs)
                
                def check_access(handler_self, client_ip):
                    """Vérifie si l'IP a le droit d'accéder"""
                    gui = handler_self.server.gui
                    
                    # Bloquer blacklist
                    if client_ip in gui.blacklist:
                        gui.add_alert(f"⚠️ ACCÈS BLOQUÉ (blacklist) : {client_ip}")
                        return False
                    
                    # Mode whitelist
                    if gui.security_mode.get() == "whitelist" and gui.whitelist:
                        if client_ip not in gui.whitelist:
                            gui.add_alert(f"⚠️ ACCÈS REFUSÉ (non whitelisté) : {client_ip}")
                            return False
                    
                    return True
                
                def log_request(handler_self, code='-', size='-'):
                    client_ip = handler_self.client_address[0]
                    path = handler_self.path
                    
                    # Vérifier l'accès AVANT de servir le fichier
                    if not handler_self.check_access(client_ip):
                        handler_self.send_error(403, "Accès refusé par l'administrateur")
                        handler_self.server.gui.log(f"❌ {client_ip} - ACCÈS REFUSÉ {path}")
                        return
                    
                    # Suivre la connexion active
                    gui = handler_self.server.gui
                    if client_ip not in gui.active_connections:
                        gui.active_connections[client_ip] = {
                            'start': time.time(),
                            'files': [],
                            'last_seen': time.time()
                        }
                        # Nouvelle connexion = alerte
                        if gui.alerts_var.get() and gui.alert_new_ip.get():
                            gui.add_alert(f"✅ NOUVELLE CONNEXION : {client_ip} a accédé à {path}")
                    
                    # Mettre à jour les stats
                    gui.active_connections[client_ip]['last_seen'] = time.time()
                    if path not in gui.active_connections[client_ip]['files']:
                        gui.active_connections[client_ip]['files'].append(path)
                    
                    # Journaliser
                    super().log_request(code, size)
                    gui.log(f"✅ {client_ip} - {code} {path}")
                    
                    # Ajouter à l'historique
                    gui.connection_history.append({
                        'time': datetime.now().strftime("%H:%M:%S"),
                        'ip': client_ip,
                        'file': path,
                        'status': str(code)
                    })
                    
                    # Mettre à jour les stats de trafic (estimation)
                    if size != '-':
                        gui.traffic_stats[client_ip] += int(size)
            
            # Démarrer le serveur
            self.server = HTTPServer(('0.0.0.0', port), SecureHandler)
            self.server.gui = self
            
            thread = threading.Thread(target=self.server.serve_forever, daemon=True)
            thread.start()
            
            # Interface
            self.start_btn.config(state=tk.DISABLED)
            self.stop_btn.config(state=tk.NORMAL)
            url_local = f"http://localhost:{port}"
            url_network = f"http://{self.ip}:{port}"
            self.url_label.config(text=f"📍 Local : {url_local}\n🌐 Réseau : {url_network}")
            
            # Logs
            self.log("="*60)
            self.log(f"✅ SERVEUR DÉMARRÉ - Mode : {self.security_mode.get().upper()}")
            self.log(f"📁 Dossier : {directory}")
            self.log(f"🔌 Port : {port}")
            self.log(f"📡 IP : {self.ip} | WiFi : {self.get_wifi_ssid()}")
            self.log(f"🌐 URL réseau : {url_network}")
            self.log("="*60)
            
            # Ouvrir navigateur
            try:
                webbrowser.open(url_local)
            except:
                pass
            
            self.update_status_bar("✅ Serveur ACTIF - " + url_network)
            
        except PermissionError:
            messagebox.showerror("Erreur", "Permission refusée. Exécutez en tant qu'administrateur ou changez de port.")
            self.log("❌ Erreur: Permission refusée")
        except OSError as e:
            if "10013" in str(e):
                messagebox.showerror("Erreur Pare-feu", 
                    "Le port est bloqué par le pare-feu.\n\nSolutions :\n• Changer de port (8080, 9000)\n• Ouvrir le port dans le pare-feu\n• Exécuter en admin")
            else:
                messagebox.showerror("Erreur", f"{e}")
            self.log(f"❌ Erreur: {e}")
        except Exception as e:
            messagebox.showerror("Erreur", f"Erreur inattendue : {e}")
            self.log(f"❌ Erreur: {e}")
    
    def stop_server(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
            self.start_btn.config(state=tk.NORMAL)
            self.stop_btn.config(state=tk.DISABLED)
            self.url_label.config(text="⏹️ Serveur arrêté")
            self.log("="*60)
            self.log("⏹️ SERVEUR ARRÊTÉ")
            self.log("="*60)
            self.update_status_bar("⏹️ Serveur arrêté")
    
    def restart_server(self):
        self.stop_server()
        self.root.after(800, self.start_server)
    
    # ==================== FONCTIONS SÉCURITÉ ====================
    def add_whitelist(self):
        ip = self.wl_entry.get().strip()
        if ip and ip not in self.whitelist:
            self.whitelist.add(ip)
            self.wl_listbox.insert(tk.END, ip)
            self.wl_entry.delete(0, tk.END)
            self.log(f"✅ IP ajoutée à la whitelist : {ip}")
    
    def add_blacklist(self):
        ip = self.bl_entry.get().strip()
        if ip and ip not in self.blacklist:
            self.blacklist.add(ip)
            self.bl_listbox.insert(tk.END, ip)
            self.bl_entry.delete(0, tk.END)
            self.log(f"❌ IP ajoutée à la blacklist : {ip}")
            # Déconnecter si connecté
            if ip in self.active_connections:
                self.add_alert(f"🔌 Déconnexion forcée : {ip} (ajouté à blacklist)")
    
    def remove_from_list(self, listbox, ip_set):
        sel = listbox.curselection()
        if sel:
            ip = listbox.get(sel[0])
            ip_set.discard(ip)
            listbox.delete(sel[0])
            self.log(f"🗑️ IP retirée : {ip}")
    
    def block_selected_ip(self):
        sel = self.conn_tree.selection()
        if sel:
            ip = self.conn_tree.item(sel[0])['values'][0]
            self.blacklist.add(ip)
            self.bl_listbox.insert(tk.END, ip)
            self.add_alert(f"🛡️ IP bloquée : {ip}")
            self.log(f"🛡️ {ip} ajouté à la blacklist")
    
    def disconnect_selected(self):
        sel = self.conn_tree.selection()
        if sel:
            ip = self.conn_tree.item(sel[0])['values'][0]
            self.active_connections.pop(ip, None)
            self.update_active_connections()
            self.log(f"🔌 {ip} déconnecté manuellement")
    
    def update_active_connections(self):
        # Nettoyer les connexions inactives (>5 min)
        now = time.time()
        to_remove = [ip for ip, data in self.active_connections.items() 
                    if now - data['last_seen'] > 300]
        for ip in to_remove:
            del self.active_connections[ip]
        
        # Mettre à jour l'interface
        self.conn_tree.delete(*self.conn_tree.get_children())
        for ip, data in self.active_connections.items():
            duration = int(time.time() - data['start'])
            files = ", ".join(data['files'][:3]) + ("..." if len(data['files']) > 3 else "")
            self.conn_tree.insert("", "end", values=(
                ip,
                f"{duration//60}m {duration%60}s",
                files or "Aucun"
            ))
    
    # ==================== FONCTIONS RÉSEAU ====================
    def refresh_network_info(self):
        self.ip = self.get_ip()
        self.ip_label.config(text=self.ip)
        ssid = self.get_wifi_ssid()
        self.ssid_label.config(text=ssid)
        self.wifi_label.config(text=ssid)
        self.log(f"✅ Infos réseau actualisées - WiFi: {ssid}")
        
        # Mettre à jour l'URL si serveur actif
        if self.server:
            port = int(self.port_entry.get())
            self.url_label.config(text=f"📍 Local : http://localhost:{port}\n🌐 Réseau : http://{self.ip}:{port}")
    
    def start_network_scan(self):
        self.log("🔍 Lancement du scan réseau (peut prendre 15-30s)...")
        threading.Thread(target=self.scan_local_network, daemon=True).start()
    
    def update_network_table(self):
        self.scan_tree.delete(*self.scan_tree.get_children())
        for ip, hostname in self.scan_results:
            self.scan_tree.insert("", "end", values=(ip, hostname))
    
    # ==================== FONCTIONS STATISTIQUES ====================
    def update_realtime_stats(self):
        if self.server:
            # Utilisateurs actifs
            active_users = len([ip for ip, data in self.active_connections.items() 
                              if time.time() - data['last_seen'] < 60])
            self.users_count.config(text=f"👥 Utilisateurs actifs : {active_users}")
            
            # Trafic total
            total_traffic = sum(self.traffic_stats.values())
            if total_traffic > 1024*1024:
                traffic_str = f"{total_traffic/(1024*1024):.2f} Mo"
            elif total_traffic > 1024:
                traffic_str = f"{total_traffic/1024:.2f} Ko"
            else:
                traffic_str = f"{total_traffic} Octets"
            self.traffic_count.config(text=f"📦 Trafic total : {traffic_str}")
            
            # Fichiers servis
            files_served = len(self.connection_history)
            self.files_count.config(text=f"📁 Fichiers servis : {files_served}")
            
            # Historique
            if self.connection_history:
                self.history_tree.delete(*self.history_tree.get_children())
                for entry in reversed(self.connection_history[-50:]):  # Dernières 50
                    self.history_tree.insert("", "end", values=(
                        entry['time'],
                        entry['ip'],
                        entry['file'][:30] + "..." if len(entry['file']) > 30 else entry['file'],
                        entry['status']
                    ))
        
        # Rafraîchir toutes les 2 secondes
        self.root.after(2000, self.update_realtime_stats)
    
    # ==================== FONCTIONS ALERTES ====================
    def add_alert(self, message):
        if self.alerts_var.get():
            timestamp = datetime.now().strftime("%H:%M:%S")
            self.alert_text.insert(tk.END, f"[{timestamp}] {message}\n")
            self.alert_text.see(tk.END)
            self.alert_text.tag_add("alert", "end-2l", "end-1c")
            self.alert_text.tag_config("alert", foreground="#e65100", font=("Courier", 9, "bold"))
            
            # Notification système (optionnel)
            try:
                if platform.system() == "Windows":
                    import win10toast
                    toaster = win10toast.ToastNotifier()
                    toaster.show_toast("AdminServeur Pro", message[:50], duration=5)
            except:
                pass
    
    def test_alert(self):
        self.add_alert("🔔 Test d'alerte - Système de notification opérationnel !")
    
    # ==================== UTILITAIRES ====================
    def open_explorer(self):
        directory = self.dir_entry.get()
        if os.path.isdir(directory):
            try:
                if sys.platform == "win32":
                    os.startfile(directory)
                elif sys.platform == "darwin":
                    subprocess.Popen(['open', directory])
                else:
                    subprocess.Popen(['xdg-open', directory])
                self.log(f"📂 Explorateur ouvert : {directory}")
            except Exception as e:
                messagebox.showerror("Erreur", f"Impossible d'ouvrir l'explorateur : {e}")
        else:
            messagebox.showerror("Erreur", f"Dossier introuvable :\n{directory}")
    
    def open_in_browser(self):
        if self.server:
            port = int(self.port_entry.get())
            url = f"http://localhost:{port}"
            webbrowser.open(url)
            self.log(f"🌐 Navigateur ouvert : {url}")
        else:
            messagebox.showinfo("Info", "Démarrer le serveur d'abord")
    
    def log(self, message):
        timestamp = time.strftime("%H:%M:%S")
        self.log_text.insert(tk.END, f"[{timestamp}] {message}\n")
        self.log_text.see(tk.END)
        self.root.update_idletasks()
    
    def filter_logs(self, event=None):
        filter_text = self.log_filter.get().lower()
        content = self.log_text.get(1.0, tk.END)
        lines = content.split('\n')
        self.log_text.delete(1.0, tk.END)
        for line in lines:
            if filter_text in line.lower() or not filter_text:
                self.log_text.insert(tk.END, line + '\n')
    
    def clear_logs(self):
        self.log_text.delete(1.0, tk.END)
        self.log("🗑️ Logs effacés")
    
    def save_logs(self):
        filename = f"adminserveur_logs_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
        try:
            with open(filename, 'w', encoding='utf-8') as f:
                f.write(self.log_text.get(1.0, tk.END))
            messagebox.showinfo("Sauvegarde", f"Logs sauvegardés dans :\n{filename}")
            self.log(f"💾 Logs sauvegardés : {filename}")
        except Exception as e:
            messagebox.showerror("Erreur", f"Impossible de sauvegarder : {e}")
    
    def update_status_bar(self, message=None):
        if message:
            self.status_var.set(message)
        else:
            if self.server:
                port = self.port_entry.get()
                self.status_var.set(f"✅ Serveur ACTIF - http://{self.ip}:{port} | Utilisateurs: {len(self.active_connections)}")
            else:
                self.status_var.set("⏹️ Serveur arrêté")
    
    def on_close(self):
        if messagebox.askyesno("Quitter", "Arrêter le serveur et quitter ?"):
            self.stop_server()
            self.root.destroy()

if __name__ == "__main__":
    # Vérifier les dépendances
    try:
        import psutil
    except ImportError:
        print("⚠️  Psutil non installé. Installation requise :")
        print("   pip install psutil")
        if messagebox.askyesno("Installer", "Voulez-vous installer psutil maintenant ?"):
            import subprocess
            subprocess.check_call([sys.executable, "-m", "pip", "install", "psutil"])
            print("✅ Psutil installé. Relancez le programme.")
        else:
            print("❌ Psutil requis pour les fonctionnalités réseau avancées.")
        sys.exit(1)
    
    try:
        NetworkAdminGUI()
    except Exception as e:
        messagebox.showerror("Erreur critique", f"Erreur : {e}\n\nDétails :\n{str(e)}")
        import traceback
        traceback.print_exc()
        input("Appuyez sur Entrée pour quitter...")