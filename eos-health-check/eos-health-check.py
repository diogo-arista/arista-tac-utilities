#!/usr/bin/env python3

# #############################################################################
# Arista EOS Health Check Script
#
# Version: 1.2.3
# Author: Gemini AI
#
# Objective:
# This script performs a comprehensive health check on an Arista EOS device.
# It is designed to be standalone with zero dependencies on external libraries,
# relying solely on standard Python 3 and native EOS tools.
#
# Changelog:
# v1.2.3 - Enhanced BGP summary parsing to intelligently report on states like
#          'Missing Router ID' and 'No neighbors configured'.
#        - Improved coloring for non-established BGP peer states.
# v1.2.2 - Corrected agent crash and PCI check commands and parsers.
# v1.2.1 - Fixed filesystem parsing logic to correctly identify mount points.
# v1.2.0 - Added color-coded terminal output for improved readability.
# v1.1.0 - Refactored data collection and fixed duplicate '| json' bug.
#
# #############################################################################

import json
import subprocess
import os
import sys
import datetime
import getpass
import re
import socket
import base64
import urllib.request
import urllib.error
import ssl
import textwrap
import logging

# --- Global Configuration ---
SCRIPT_VERSION = "1.2.3"
LOG_DIR_LOCAL = "/mnt/flash/"
ARISTA_FTP = "ftp.arista.com"

# --- ANSI Color Codes ---
class Colors:
    """A class to hold ANSI color codes for terminal output."""
    if sys.stdout.isatty():
        HEADER = '\033[95m'
        TITLE = '\033[94m'
        OKGREEN = '\033[92m'
        WARNING = '\033[93m'
        FAIL = '\033[91m'
        RESET = '\033[0m'
        BOLD = '\033[1m'
    else:
        # Disable colors if not a TTY
        HEADER = TITLE = OKGREEN = WARNING = FAIL = RESET = BOLD = ""

# --- Logging Setup ---
log = logging.getLogger(__name__)


# #############################################################################
#  Command Execution Logic
# #############################################################################

class CommandExecutor:
    """Handles command execution for local (on-box) or remote scenarios."""

    def __init__(self):
        self.mode = 'local'
        self.eapi_url = ''
        self.ssh_user = ''
        self.ssh_host = ''
        self.auth_header = ''
        self.eapi_usable = False
        self.hostname = self._get_local_hostname()

        if not os.path.exists('/usr/bin/FastCli'):
            self.mode = 'remote'
            print(f"--- {Colors.BOLD}Remote Execution Mode Detected{Colors.RESET} ---")
            if not self._setup_remote_connection():
                sys.exit(f"{Colors.FAIL}Failed to establish a remote connection. Exiting.{Colors.RESET}")
        else:
            print(f"--- {Colors.BOLD}Local Execution Mode Detected on {self.hostname}{Colors.RESET} ---")


    def _get_local_hostname(self):
        """Gets hostname when running locally."""
        try:
            result = subprocess.run(
                ['FastCli', '-p', '15', '-c', 'show hostname | json'],
                capture_output=True, text=True, check=True
            )
            return json.loads(result.stdout).get('hostname', 'arista')
        except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
            return socket.gethostname()

    def _setup_remote_connection(self):
        """Prompts for and configures remote connection details (eAPI/SSH)."""
        host = input("Enter switch IP address or hostname: ")
        user = input("Enter username: ")
        password = getpass.getpass("Enter password: ")

        self.ssh_host = host
        self.ssh_user = user
        self.eapi_url = f"https://{host}/command-api"
        auth_string = f"{user}:{password}"
        self.auth_header = f"Basic {base64.b64encode(auth_string.encode()).decode()}"

        print(f"Attempting to connect to {host} via eAPI...")
        try:
            ctx = ssl._create_unverified_context()
            test_cmd = self._build_eapi_request(['show version'])
            req = urllib.request.Request(self.eapi_url, test_cmd, headers={'Authorization': self.auth_header})
            urllib.request.urlopen(req, context=ctx, timeout=10)
            self.eapi_usable = True
            print(f"{Colors.OKGREEN}eAPI connection successful.{Colors.RESET}")
            data = self.run_command('show hostname')
            self.hostname = data.get('hostname', host)
            return True
        except (urllib.error.URLError, socket.timeout, ValueError) as e:
            print(f"{Colors.WARNING}eAPI connection failed: {e}{Colors.RESET}")
            print(f"{Colors.WARNING}Falling back to SSH. NOTE: Requires pre-configured key-based authentication.{Colors.RESET}")
            if self._check_ssh_path():
                data = self.run_command('show hostname')
                if data:
                    self.hostname = data.get('hostname', host)
                else:
                    self.hostname = host
                return True
            else:
                print(f"{Colors.FAIL}SSH client not found in path. Cannot proceed with remote execution.{Colors.RESET}")
                return False

    def _check_ssh_path(self):
        """Checks if the 'ssh' executable is in the system's PATH."""
        for path in os.environ["PATH"].split(os.pathsep):
            if os.path.isfile(os.path.join(path, "ssh")):
                return True
        return False

    def _build_eapi_request(self, cmds):
        """Constructs a JSON-RPC request body."""
        return json.dumps({
            "jsonrpc": "2.0",
            "method": "runCmds",
            "params": {"version": 1, "cmds": cmds, "format": "json"},
            "id": "gemini-health-check"
        }).encode('utf-8')

    def run_command(self, command, use_json=True):
        """Executes a command using the appropriate method."""
        if "| json" in command:
            use_json = False

        log.debug(f"Running command: {command} (JSON: {use_json})")
        full_command = f"{command} {'| json' if use_json else ''}"

        try:
            if self.mode == 'local':
                result = subprocess.run(
                    ['FastCli', '-p', '15', '-c', full_command],
                    capture_output=True, text=True, check=True, timeout=60
                )
                output = result.stdout
            elif self.eapi_usable:
                ctx = ssl._create_unverified_context()
                req_body = self._build_eapi_request([command])
                req = urllib.request.Request(self.eapi_url, req_body, headers={'Authorization': self.auth_header})
                with urllib.request.urlopen(req, context=ctx, timeout=60) as response:
                    eapi_output = json.loads(response.read().decode())
                    if 'error' in eapi_output:
                        raise ValueError(f"eAPI error: {eapi_output['error']['message']}")
                    output = json.dumps(eapi_output['result'][0]) if use_json else eapi_output['result'][0]['output']
            else:
                ssh_command = ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
                               f"{self.ssh_user}@{self.ssh_host}", full_command]
                result = subprocess.run(
                    ssh_command, capture_output=True, text=True, check=True, timeout=60
                )
                output = result.stdout

            return json.loads(output) if use_json else output
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
                json.JSONDecodeError, urllib.error.URLError, ValueError) as e:
            log.error(f"Failed to execute '{full_command}': {e}")
            return None


# #############################################################################
#  Health Check & Data Collection Tasks (PARSERS ONLY)
# #############################################################################

def parse_system_summary(data):
    """Parses basic system information from raw data."""
    if not data:
        return {"error": "Could not retrieve version information."}
    
    mem_total_kb = data.get('memTotal', 0)
    mem_free_kb = data.get('memFree', 0)
    
    return {
        "model": data.get('modelName', 'N/A'),
        "serial": data.get('serialNumber', 'N/A'),
        "version": data.get('version', 'N/A'),
        "uptime": data.get('uptime', 0),
        "mem_total_gb": f"{mem_total_kb / 1024 / 1024:.2f}",
        "mem_free_gb": f"{mem_free_kb / 1024 / 1024:.2f}",
        "mem_used_percent": f"{(1 - mem_free_kb / mem_total_kb) * 100:.2f}" if mem_total_kb > 0 else "0.00"
    }

def parse_cpu_status(output):
    """Parses text output for CPU utilization and top processes."""
    if not output:
        return {"error": "Could not retrieve CPU process information."}
        
    summary = {"utilization": "N/A", "top_processes": []}
    cpu_match = re.search(r"%Cpu\(s\):\s+([\d\.]+) us", output)
    if cpu_match:
        summary["utilization"] = cpu_match.group(1)

    lines = output.splitlines()
    try:
        header_index = next(i for i, line in enumerate(lines) if "PID" in line and "USER" in line)
        process_lines = lines[header_index + 1 : header_index + 6]
        for line in process_lines:
            parts = line.split()
            if len(parts) >= 12:
                summary["top_processes"].append({
                    "pid": parts[0], "user": parts[1], "cpu": parts[8],
                    "mem": parts[9], "command": parts[11]
                })
    except (StopIteration, IndexError):
        log.warning("Could not parse top processes table.")
        
    return summary

def parse_filesystem_usage(output):
    """Parses 'df -h' for key filesystem utilization."""
    if not output:
         return {"error": "Could not retrieve filesystem usage."}

    desired_mounts = ["/mnt/flash", "/var/log", "/var/core"]
    usage_data = {}

    for line in output.strip().splitlines()[1:]:
        parts = line.split()
        if not parts:
            continue
        
        mount_point = parts[-1]
        if mount_point in desired_mounts:
            if len(parts) >= 5:
                usage_data[mount_point] = {
                    "fs_device": " ".join(parts[:-5]), "size": parts[-5],
                    "used": parts[-4], "avail": parts[-3], "use%": parts[-2]
                }
    return usage_data

def parse_system_errors(core_output, agent_output, syslog_output, pci_output):
    """Parses outputs for core dumps, agent crashes, and critical syslogs."""
    errors = {
        "core_dumps": "No core files found.",
        "agent_crashes": "No agent crashes found.",
        "syslog_criticals": [],
        "pci_errors": "No PCI errors found."
    }

    if core_output and "total 0" not in core_output and len(core_output.splitlines()) > 1:
        errors["core_dumps"] = f"Core files found:\n{core_output}"

    # Agent Crashes (TEXT PARSING)
    if agent_output and agent_output.strip():
        crash_count = len([line for line in agent_output.strip().splitlines() if line.strip()])
        errors["agent_crashes"] = f"Found {crash_count} agent crash report(s)."

    if syslog_output:
        errors["syslog_criticals"] = syslog_output.strip().splitlines()

    # PCI Errors (PARSING 'show pci | json')
    pci_error_list = []
    if pci_output and 'pciIds' in pci_output:
        for pci_id, device_details in pci_output['pciIds'].items():
            corr_err = device_details.get('correctableErrors', 0)
            non_fatal_err = device_details.get('nonFatalErrors', 0)
            fatal_err = device_details.get('fatalErrors', 0)

            if corr_err > 0 or non_fatal_err > 0 or fatal_err > 0:
                device_name = device_details.get('name', pci_id)
                error_string = (
                    f"Device {device_name}: "
                    f"Correctable={corr_err}, NonFatal={non_fatal_err}, Fatal={fatal_err}"
                )
                pci_error_list.append(error_string)
    if pci_error_list:
        errors["pci_errors"] = "\n".join(pci_error_list)
        
    return errors

def parse_feature_health(bgp_data, mlag_data, vxlan_data):
    """Parses health of key features like BGP, MLAG, and VXLAN."""
    health = {
        "bgp": "BGP not configured or no summary available.",
        "mlag": "MLAG not configured.",
        "vxlan": "No VXLAN VNI information found."
    }

    # BGP Parsing (Enhanced Logic)
    if bgp_data and 'vrfs' in bgp_data:
        vrf_default = bgp_data['vrfs'].get('default')

        if not vrf_default:
            pass # Keep default message: BGP not configured
        elif "Missing Router ID" in vrf_default.get('reason', ''):
            health["bgp"] = f"{Colors.FAIL}BGP is disabled (Missing Router ID){Colors.RESET}"
        elif not vrf_default.get('peers'):
            router_id = vrf_default.get('routerId', 'N/A')
            health["bgp"] = f"{Colors.WARNING}BGP is enabled (Router ID: {router_id}) but has no configured neighbors.{Colors.RESET}"
        else:
            peers_down = []
            total_peers = 0
            for peer, details in vrf_default.get('peers', {}).items():
                total_peers += 1
                peer_state = details.get('peerState')
                if peer_state != 'Established':
                    transient_states = ['Active', 'Connect', 'OpenSent', 'OpenConfirm']
                    state_color = Colors.WARNING if peer_state in transient_states else Colors.FAIL
                    peers_down.append(f"Peer {peer} is in state {state_color}{peer_state or 'Unknown'}{Colors.RESET}")
            
            peers_up = total_peers - len(peers_down)
            summary_color = Colors.OKGREEN if peers_up == total_peers else Colors.FAIL
            health["bgp"] = f"{summary_color}{peers_up}/{total_peers} peers established.{Colors.RESET}"
            if peers_down:
                 health["bgp"] += "\n  " + "\n  ".join(peers_down)
    
    # MLAG Parsing
    if mlag_data and mlag_data.get('state') != 'disabled':
        state = mlag_data.get('state', 'N/A')
        color = Colors.OKGREEN if state == 'active' else Colors.FAIL
        status = [f"State: {color}{state}{Colors.RESET}"]
        status.append(f"Negotiation Status: {mlag_data.get('negStatus', 'N/A')}")
        status.append(f"Peer Link: {mlag_data.get('peerLink', 'N/A')}")
        status.append(f"Local Interface: {mlag_data.get('localInterface', 'N/A')}")
        health["mlag"] = ", ".join(status)
        
    # VXLAN Parsing
    if vxlan_data and 'vnis' in vxlan_data:
        health["vxlan"] = f"Found {len(vxlan_data['vnis'])} VNI(s)."
        
    return health

def parse_interface_health(err_data, disc_data):
    """Summarizes interfaces with errors or discards."""
    health = {"errors": [], "discards": [], "link_flaps": []}

    if err_data and 'interfaceErrorCounters' in err_data:
        for iface, counters in err_data['interfaceErrorCounters'].items():
            if counters.get('inErrors', 0) > 0 or counters.get('outErrors', 0) > 0:
                health["errors"].append(f"{iface}: In={counters['inErrors']}, Out={counters['outErrors']}")
            if counters.get('linkStatusChanges', 0) > 10: # Threshold for "flapping"
                health["link_flaps"].append(f"{iface}: {counters['linkStatusChanges']} flaps")
    if disc_data and 'interfaceDiscardCounters' in disc_data:
        for iface, counters in disc_data['interfaceDiscardCounters'].items():
            if counters.get('inDiscards', 0) > 0 or counters.get('outDiscards', 0) > 0:
                 health["discards"].append(f"{iface}: In={counters['inDiscards']}, Out={counters['outDiscards']}")
                 
    return health

def parse_management_health(cvp_data, stp_data):
    """Parses CVP/CVaaS connectivity and STP status."""
    health = {
        "cvp": f"{Colors.WARNING}TerminAttr agent not configured.{Colors.RESET}",
        "stp": "No STP information found."
    }

    if cvp_data:
        for line in cvp_data.splitlines():
            if "server" in line:
                health["cvp"] = f"{Colors.OKGREEN}{line.strip()}{Colors.RESET}"
                break
    if stp_data and 'spanningTreeInstances' in stp_data:
        stp_summary = []
        for instance, details in stp_data['spanningTreeInstances'].items():
            if details.get('rootBridge'):
                root_port = details.get('rootPort', 'N/A')
                stp_summary.append(f"Instance {instance}: Root Port={root_port}")
        health["stp"] = "\n  ".join(stp_summary) if stp_summary else "No active STP instances found."
    
    return health

def parse_lldp_neighbors(lldp_data):
    """Summarizes LLDP neighbors from raw data."""
    neighbors = []
    if lldp_data and 'lldpNeighbors' in lldp_data:
        for n in lldp_data['lldpNeighbors']:
            neighbors.append({
                "local_port": n['port'],
                "neighbor_device": n.get('neighborDevice', 'N/A'),
                "neighbor_port": n.get('neighborPort', 'N/A')
            })
    return neighbors


# #############################################################################
#  Output and Reporting
# #############################################################################

def color_by_threshold(value_str, warn, crit):
    """Colors a string based on numeric thresholds."""
    try:
        numeric_val = float(re.sub(r'[^0-9.]', '', value_str))
        if numeric_val >= crit:
            return f"{Colors.FAIL}{value_str}{Colors.RESET}"
        if numeric_val >= warn:
            return f"{Colors.WARNING}{value_str}{Colors.RESET}"
        return f"{Colors.OKGREEN}{value_str}{Colors.RESET}"
    except (ValueError, TypeError):
        return value_str

def format_summary_report(data):
    """Creates a clean, human-readable summary report string."""
    report = []
    
    def title(text):
        report.append(f"\n{Colors.HEADER}{Colors.BOLD}{'='*80}")
        report.append(f" {text}")
        report.append(f"{'='*80}{Colors.RESET}")

    def section(text):
        report.append(f"\n{Colors.TITLE}{Colors.BOLD}{'-'*30}")
        report.append(f" {text}")
        report.append(f"{'-'*30}{Colors.RESET}")
        
    def add(key, value):
        report.append(f"{key:<25}: {value}")

    title(f"Arista EOS Health Check Report for {data['hostname']}")
    add("Timestamp (UTC)", datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S"))
    add("Script Version", SCRIPT_VERSION)

    section("System Summary")
    s = data['system']
    if 'error' in s: add("Error", f"{Colors.FAIL}{s['error']}{Colors.RESET}")
    else:
        add("Model", s['model'])
        add("Serial Number", s['serial'])
        add("EOS Version", s['version'])
        add("Total Memory (GB)", s['mem_total_gb'])
        add("Memory Used (%)", color_by_threshold(s['mem_used_percent'], 75, 90))

    section("CPU Status")
    c = data['cpu']
    if 'error' in c: add("Error", f"{Colors.FAIL}{c['error']}{Colors.RESET}")
    else:
        add("CPU Utilization (user %)", color_by_threshold(c['utilization'], 75, 90))
        if c['top_processes']:
            report.append("\nTop 5 Processes:")
            report.append(f"{Colors.BOLD}{'PID':<8} {'USER':<10} {'%CPU':<6} {'%MEM':<6} {'COMMAND'}{Colors.RESET}")
            for p in c['top_processes']:
                report.append(f"{p['pid']:<8} {p['user']:<10} {p['cpu']:<6} {p['mem']:<6} {p['command']}")

    section("Filesystem Utilization")
    f = data['filesystem']
    if 'error' in f:
        add("Error", f"{Colors.FAIL}{f['error']}{Colors.RESET}")
    elif not f:
        add("Monitored mounts", f"{Colors.WARNING}Not found (/mnt/flash, /var/log, /var/core){Colors.RESET}")
    else:
        report.append(f"{Colors.BOLD}{'Mount Point':<15} {'Size':<8} {'Used':<8} {'Avail':<8} {'Use%':<6}{Colors.RESET}")
        for mount_point, u in sorted(f.items()):
            use_percent_colored = color_by_threshold(u['use%'], 75, 90)
            report.append(f"{mount_point:<15} {u['size']:<8} {u['used']:<8} {u['avail']:<8} {use_percent_colored}")

    section("System Stability & Errors")
    e = data['errors']
    add("Core Dumps", f"{Colors.FAIL}{e['core_dumps'].splitlines()[0]}{Colors.RESET}" if "found" in e['core_dumps'] else f"{Colors.OKGREEN}{e['core_dumps']}{Colors.RESET}")
    add("Agent Crashes", f"{Colors.FAIL}{e['agent_crashes']}{Colors.RESET}" if "found" in e['agent_crashes'] else f"{Colors.OKGREEN}{e['agent_crashes']}{Colors.RESET}")
    add("PCI Errors", f"{Colors.FAIL}{e['pci_errors']}{Colors.RESET}" if "found" not in e['pci_errors'] else f"{Colors.OKGREEN}{e['pci_errors']}{Colors.RESET}")
    if e['syslog_criticals']:
        report.append(f"\n{Colors.FAIL}Critical Syslog Entries Found:{Colors.RESET}")
        report.extend([f"  - {line}" for line in e['syslog_criticals'][:10]])
        if len(e['syslog_criticals']) > 10: report.append(f"  ... and {len(e['syslog_criticals']) - 10} more.")
    else:
        add("Critical Syslog", f"{Colors.OKGREEN}No critical error/fail/crit messages found.{Colors.RESET}")
        
    section("Feature Health")
    feat = data['features']
    bgp_status = feat['bgp']
    if '\n' in bgp_status:
        lines = bgp_status.splitlines()
        add("BGP Status", lines[0])
        for line in lines[1:]:
            report.append(f"{'':25}  {line}")
    else:
        add("BGP Status", bgp_status)
    add("MLAG Status", feat['mlag'])
    add("VXLAN Status", feat['vxlan'])

    section("Interface Health")
    i = data['interfaces']
    err_count_color = Colors.FAIL if i['errors'] else Colors.OKGREEN
    disc_count_color = Colors.WARNING if i['discards'] else Colors.OKGREEN
    flap_count_color = Colors.WARNING if i['link_flaps'] else Colors.OKGREEN
    add("Interfaces with Errors", f"{err_count_color}{len(i['errors'])}{Colors.RESET}")
    if i['errors']: report.extend([f"{Colors.FAIL}  - {line}{Colors.RESET}" for line in i['errors']])
    add("Interfaces with Discards", f"{disc_count_color}{len(i['discards'])}{Colors.RESET}")
    if i['discards']: report.extend([f"{Colors.WARNING}  - {line}{Colors.RESET}" for line in i['discards']])
    add("Interfaces with High Flaps", f"{flap_count_color}{len(i['link_flaps'])}{Colors.RESET}")
    if i['link_flaps']: report.extend([f"{Colors.WARNING}  - {line}{Colors.RESET}" for line in i['link_flaps']])
    
    section("Management & Connectivity")
    m = data['management']
    add("CVP/CVaaS Status", m['cvp'])
    add("STP Root Summary", "\n  " + m['stp'] if "\n" in m['stp'] else m['stp'])

    section("LLDP Neighbors")
    l = data['lldp']
    if l:
        report.append(f"{Colors.BOLD}{'Local Port':<20} {'Neighbor Device':<30} {'Neighbor Port'}{Colors.RESET}")
        for n in l:
            report.append(f"{n['local_port']:<20} {n['neighbor_device']:<30} {n['neighbor_port']}")
    else:
        report.append("No LLDP neighbors found.")
        
    report.append(f"\n{Colors.HEADER}{Colors.BOLD}{'='*80}{Colors.RESET}")
    report.append(f"{Colors.BOLD}--- End of Report ---{Colors.RESET}")
    return "\n".join(report)

def save_log_file(hostname, report, raw_data):
    """Saves the detailed log file, stripping color codes first."""
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
    filename = f"{hostname}_health-check_{timestamp}.log"
    log_path = LOG_DIR_LOCAL if os.path.exists(LOG_DIR_LOCAL) else "."
    full_path = os.path.join(log_path, filename)

    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    clean_report = ansi_escape.sub('', report)

    try:
        with open(full_path, 'w') as f:
            f.write("="*25 + " SUMMARY REPORT " + "="*25 + "\n")
            f.write(clean_report)
            f.write("\n\n" + "="*25 + " RAW COMMAND OUTPUT " + "="*25 + "\n\n")
            json.dump(raw_data, f, indent=2)
        print(f"\n{Colors.OKGREEN}[+]{Colors.RESET} Successfully saved log file to: {Colors.BOLD}{full_path}{Colors.RESET}")
        return full_path
    except IOError as e:
        print(f"\n{Colors.FAIL}[-]{Colors.RESET} Error: Could not save log file to {full_path}: {e}")
        return None

# #############################################################################
#  Interactive Menu
# #############################################################################

def display_menu(report, log_file_path):
    """Displays the post-run interactive menu."""
    while True:
        print(f"\n{Colors.TITLE}{Colors.BOLD}--- Options Menu ---{Colors.RESET}")
        print(f"{Colors.BOLD}1.{Colors.RESET} Display summary report again")
        print(f"{Colors.BOLD}2.{Colors.RESET} Send log file to a remote server (via SCP)")
        print(f"{Colors.BOLD}3.{Colors.RESET} Upload log file to Arista Support (via FTP)")
        print(f"{Colors.BOLD}4.{Colors.RESET} Exit")
        choice = input("Enter your choice [1-4]: ")

        if choice == '1': print(report)
        elif choice == '2': handle_scp_upload(log_file_path)
        elif choice == '3': handle_arista_ftp_upload(log_file_path)
        elif choice == '4':
            print("Exiting.")
            break
        else:
            print(f"{Colors.WARNING}Invalid choice, please try again.{Colors.RESET}")

def handle_scp_upload(log_file_path):
    """Handles uploading the file via SCP."""
    print(f"\n{Colors.TITLE}{Colors.BOLD}--- SCP File Upload ---{Colors.RESET}")
    if not log_file_path:
        print(f"{Colors.WARNING}No log file to upload.{Colors.RESET}")
        return
    try:
        remote_path = input("Enter remote path (e.g., user@host:/path/to/dir/): ")
        if not remote_path:
            print("Upload cancelled.")
            return
        print(f"Uploading {log_file_path} to {remote_path}...")
        subprocess.run(['scp', log_file_path, remote_path], check=True)
        print(f"{Colors.OKGREEN}Upload successful.{Colors.RESET}")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"{Colors.FAIL}SCP failed. Ensure 'scp' is in your PATH and you have permissions. Error: {e}{Colors.RESET}")

def handle_arista_ftp_upload(log_file_path):
    """Provides instructions to upload the file to Arista FTP."""
    print(f"\n{Colors.TITLE}{Colors.BOLD}--- Arista Support FTP Upload ---{Colors.RESET}")
    if not log_file_path:
        print(f"{Colors.WARNING}No log file to upload.{Colors.RESET}")
        return
    case_number = input("Enter your Arista Support case number (e.g., 123456): ")
    if not case_number.isdigit():
        print(f"{Colors.WARNING}Invalid case number. Upload cancelled.{Colors.RESET}")
        return
    
    log_filename = os.path.basename(log_file_path)
    remote_filename = f"{case_number}.{log_filename}"
    
    print("\nPlease use a standard FTP client to upload the log file.")
    print("Due to security limitations, this script cannot automate the FTP password prompt.")
    print(f"\n{Colors.BOLD}--- FTP Instructions ---{Colors.RESET}")
    print(f"1. Open a terminal or command prompt.")
    print(f"2. Run the command: {Colors.BOLD}ftp {ARISTA_FTP}{Colors.RESET}")
    print(f"3. Login with username {Colors.BOLD}anonymous{Colors.RESET} and your email as the password.")
    print(f"4. Change to the incoming directory: {Colors.BOLD}cd incoming{Colors.RESET}")
    print(f"5. Upload the file: {Colors.BOLD}put {log_file_path} {remote_filename}{Colors.RESET}")
    print(f"6. Exit the FTP client: {Colors.BOLD}quit{Colors.RESET}")

# #############################################################################
#  Main Execution Block
# #############################################################################

def main():
    """Main function to orchestrate the health check."""
    banner = f"""
{Colors.HEADER}{Colors.BOLD}================================================================================
                    Arista EOS Health Check Script
                        Version {SCRIPT_VERSION}
================================================================================{Colors.RESET}"""
    print(banner)

    try:
        executor = CommandExecutor()
        all_commands = {
            "show version": True, "show hostname": True, "show processes top once": False,
            "bash df -h": False, "bash ls -l /var/core": False, "show agent logs crash": False,
            'show logging | grep -E "error|fail|crit|emerg|alert"': False,
            "show pci": True, "show ip bgp summary": True, "show mlag": True,
            "show vxlan vni": True, "show interfaces counters errors": True,
            "show interfaces counters discards": True, "show run | grep TerminAttr": False,
            "show spanning-tree root detail": True, "show lldp neighbors": True
        }
        
        raw_data = {}
        print(f"\n{Colors.OKGREEN}[+]{Colors.RESET} {Colors.BOLD}Starting data collection...{Colors.RESET}")
        for cmd, is_json in all_commands.items():
            print(f"  - Executing: {cmd}")
            key = cmd.split(" | ")[0]
            raw_data[key] = executor.run_command(cmd, use_json=is_json)
        print(f"{Colors.OKGREEN}[+]{Colors.RESET} {Colors.BOLD}Data collection complete.{Colors.RESET}")

        print(f"\n{Colors.OKGREEN}[+]{Colors.RESET} {Colors.BOLD}Analyzing collected data...{Colors.RESET}")
        health_data = {
            'system': parse_system_summary(raw_data['show version']),
            'cpu': parse_cpu_status(raw_data['show processes top once']),
            'filesystem': parse_filesystem_usage(raw_data['bash df -h']),
            'errors': parse_system_errors(
                raw_data['bash ls -l /var/core'], raw_data['show agent logs crash'],
                raw_data['show logging'], raw_data['show pci']),
            'features': parse_feature_health(
                raw_data['show ip bgp summary'], raw_data['show mlag'], raw_data['show vxlan vni']),
            'interfaces': parse_interface_health(
                raw_data['show interfaces counters errors'], raw_data['show interfaces counters discards']),
            'management': parse_management_health(
                raw_data['show run'], raw_data['show spanning-tree root detail']),
            'lldp': parse_lldp_neighbors(raw_data['show lldp neighbors']),
            'hostname': executor.hostname
        }

        print(f"\n{Colors.OKGREEN}[+]{Colors.RESET} {Colors.BOLD}Generating report...{Colors.RESET}")
        summary_report = format_summary_report(health_data)
        
        print(summary_report)

        log_file = save_log_file(executor.hostname, summary_report, raw_data)

        display_menu(summary_report, log_file)

    except KeyboardInterrupt:
        print(f"\n\n{Colors.WARNING}Script interrupted by user. Exiting.{Colors.RESET}")
        sys.exit(1)
    except Exception as e:
        print(f"\n\n{Colors.FAIL}An unexpected error occurred: {e}{Colors.RESET}")
        log.exception("Caught unhandled exception in main()")
        sys.exit(1)

if __name__ == "__main__":
    main()
