# PlusEMU installer

Set up a complete Habbo hotel on your own server with one command. The installer downloads, installs and connects:

- **PlusEMU**, the emulator (game server)
- **Volt**, the game client
- **Atom CMS**, the website and housekeeping
- **MariaDB**, **PHP** and a web server (**nginx** on Linux, **IIS** on Windows)
- The hotel files: furniture, clothes, badges and texts (about 550 MB)

Everything runs on your server. Cloudflare sits in front of it to provide HTTPS and to hide your server's IP address.

To try PlusEMU or to work on it on your own PC, use a [local install](#local-install) instead. It needs no domain and no Cloudflare.

## Requirements

| | Linux | Windows |
|---|---|---|
| System | Debian 12/13 or Ubuntu 22.04/24.04/26.04 | Windows Server 2019/2022/2025 (Windows 10/11 for a [local install](#local-install)) |
| Processor | 64-bit (x86_64 or arm64) | 64-bit |
| Free disk space | 10 GB | 15 GB on `C:` |
| Access | root (`sudo`) | PowerShell as Administrator |

You also need (not for a [local install](#local-install)):

- A domain name, for example `myhotel.com`
- A free [Cloudflare](https://dash.cloudflare.com) account

Start from a fresh server. The installer configures the web server, the database and the firewall for the hotel.

## Install

**Linux**, as root or with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo bash
```

**Windows**: open PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
```

The installer asks these questions. Press Enter to accept a suggested answer:

1. Your hotel's domain, for example `myhotel.com`
2. The WebSocket address the game connects to. The default, `wss://myhotel.com/ws`, needs no extra Cloudflare setup.
3. The hotel name
4. The username for your admin account
5. The email for your admin account
6. A Discord webhook URL for health alerts (optional, press Enter to skip). See [Health check and Discord alerts](#health-check-and-discord-alerts).
7. Only with the advanced guide on Linux: whether to install CrowdSec (default no). See [CrowdSec](#crowdsec-advanced-guide-linux).

After you confirm, the installer runs on its own in about 10 minutes. A [local install](#local-install) asks only questions 3 to 5.

## Local install

A local install puts the whole hotel on your own PC, to try PlusEMU or to develop on it. The hotel runs at `http://localhost`, and only this PC can open it. **It is not for a public hotel:** it has no HTTPS, no Cloudflare and no server protection.

**Linux** (Debian 12/13 or Ubuntu 22.04/24.04/26.04, desktop editions too), as root or with `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo env PLUSEMU_LOCAL=1 bash
```

With a downloaded script: `sudo bash install.sh --local`.

**Windows 10 or 11** (Windows Server works too): open PowerShell as Administrator and run:

```powershell
$env:PLUSEMU_LOCAL = '1'
irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
Remove-Item Env:\PLUSEMU_LOCAL
```

With a downloaded script: `.\install.ps1 -Local`.

The installer asks three questions. Press Enter to accept the suggested answer: the hotel name (`PlusEMU`), the admin username (`admin`) and the admin email (`admin@localhost.test`).

Before it installs anything, it checks the ports the hotel needs: 80 (website), 3306 (MariaDB), 2096 (game), 8080 (emulator API) and 30001 (RCON). When another program uses one of them, the installer names the port and the program, stops and keeps no settings. Stop that program, for example another web server or database, and run the installer again. The hotel's own programs may use these ports, so a rerun works.

What a local install sets up:

- The website at `http://localhost`, housekeeping at `http://localhost/housekeeping`, and the game connection at `ws://localhost/ws` on the same web server. Every web address the installer writes into the website and client settings is `http://localhost`. The emulator talks to MariaDB and the website on `127.0.0.1`, as on a server.
- nginx (Linux) listens on `127.0.0.1` and `[::1]` port 80 only. The IIS site (Windows) is bound to `127.0.0.1` and `[::1]` with the name `localhost` only, and your other IIS sites stay.
- On Windows 10 and 11, IIS comes from the optional Windows features.
- The emulator, the website and MariaDB, which start with the PC.
- Log rotation for the hotel's own logs, the [nightly backup](#nightly-backups) at 04:00 (it runs when the PC is on) and the [health check](#health-check-and-discord-alerts) every 5 minutes, without Discord, the certificate check and the Cloudflare check.
- `plusemu-update`, which works the same as on a server.
- A short guide for this PC instead of the Cloudflare guide. Linux prints its address, `http://localhost/<token>/`. Windows opens it in your browser and saves *Hotel setup guide* on your desktop. The guide explains how to log in, open housekeeping, start, stop and update the hotel, see the logs and find the backups, and how to move to a server.

What a local install does not do, so your PC stays as it is:

- No HTTPS, no HSTS and no Cloudflare: no certificate, no Cloudflare API token step and no Cloudflare address list. HSTS on `localhost` would make the browser use HTTPS for every other project on your PC.
- No firewall changes. Linux does not install or turn on `ufw`. Windows adds no firewall rules.
- On Linux: no SSH changes, no fail2ban, no automatic security updates or restarts, no network (`sysctl`) settings, no system journal limits and no CrowdSec.
- On Windows: no account lockout policy, no Windows Update policy and no change to the header timeout of Windows' web stack.
- No per-visitor request limits, in the web server or in the emulator (`Nitro.MaxConnectionsPerIp` and `LoginThrottle.MaxFailuresPerIp` are set to 0). Every local visitor is `127.0.0.1`, so the limits would only block your own logins and test clients.
- Your own Node.js stays as it is. The installer unpacks Node.js 22 into `/opt/plusemu-node` (Linux) or `C:\ProgramData\PlusEMU\node` (Windows) and uses it only while it runs.

What it does install: nginx, MariaDB and PHP 8.5 on Linux (PHP 8.5 becomes the default `php` command), and IIS, MariaDB, PHP in `C:\PHP`, Git and Composer on Windows. It turns off nginx's own welcome page on Linux and IIS's own *Default Web Site* on Windows, because they answer on every address. A default site that you changed stays. Other nginx sites that listen on port 80 for every address no longer answer on `localhost`, because the hotel takes `127.0.0.1` and `::1`; the installer names them.

The choice is saved with your settings, so reruns and `plusemu-update` keep it. The installer does not turn a local install into a server install, or a server install into a local one. It says so and changes nothing.

**Move to a server later:** run the normal [install](#install) on your server, without `--local` or `-Local`. This makes a new hotel. To keep your users, rooms and furniture, copy `database.sql.gz` from a [nightly backup](#nightly-backups) on your PC to the server. On a Linux server, run this in the folder with the file:

```bash
sudo systemctl stop plusemu
gunzip -c database.sql.gz | sudo mariadb plus
sudo systemctl start plusemu
```

Then run the installer on the server once more. It writes the server's own addresses into the website settings. Your accounts keep the passwords they had on your PC.

### Choose the setup guide

The **simple** guide is the default. The **advanced** guide includes a manual checklist for administrator access, firewall rules and maintenance. Both contain the full Cloudflare certificate generation and server import steps.

A [local install](#local-install) has its own short guide and no guide choice.

**This selects instructions only. Selecting this guide does not change SSH, RDP, firewall, updates or backups.** Both guides get the same server protection, described in [How it works](#how-it-works). The one extra is a question in the advanced guide on Linux: whether to install [CrowdSec](#crowdsec-advanced-guide-linux). It is off unless you answer yes.

For downloaded scripts, use `sudo bash install.sh --guide-mode advanced` on Linux or `.\install.ps1 -GuideMode advanced` in Administrator PowerShell. Use `simple` instead to choose the simple guide.

For the one-command installation, set the choice on the process running the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo env PLUSEMU_GUIDE_MODE=advanced bash
```

```powershell
$env:PLUSEMU_GUIDE_MODE = 'advanced'
irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
Remove-Item Env:\PLUSEMU_GUIDE_MODE
```

The choice is saved with your existing installation settings and reused on reruns. An explicit script argument takes precedence over the environment variable; either overrides the saved choice. Older installations without a saved guide choice use simple. Rerunning the installer regenerates the guide with the selected instructions while keeping your saved credentials.

## When it finishes

The installer generates passwords automatically and prints your initial admin login and database connection details, including the database password. On Windows it also prints the MariaDB root password. These passwords are saved before installation starts; the installer tells you where to retrieve them even if a later step fails. The final password summary is shown in the terminal, not written to the installer log or browser setup guide.

It also shows you a **setup guide** with instructions for connecting your domain through Cloudflare and installing an origin certificate. A [local install](#local-install) gets a short guide for your PC instead. The guide includes commands for your server's operating system and contains no passwords or private keys.

- **Linux:** open `http://<your server IP>/<token>/`. The installer prints the exact address. The token is random so that strangers can't find the page.
- **Windows:** the guide opens in your browser. A copy named *Hotel setup guide* is saved on your desktop.

The guide walks you through:

1. Adding your domain to Cloudflare
2. Pointing your domain's nameservers to Cloudflare
3. Connecting Cloudflare automatically with an API token (see below). This does steps 4 to 6 for you, plus extra protection.
4. Adding the DNS records (proxied, orange cloud)
5. Generating a private key and certificate-signing request (CSR) on your server, requesting a Cloudflare Origin CA certificate, and importing the signed certificate into nginx or IIS
6. Setting SSL/TLS to **Full (strict)** after installing the certificate, turning on Always Use HTTPS, and checking that WebSockets are on
7. Opening your hotel and logging in

### Connect Cloudflare automatically

The last step of the installer, *Connecting your hotel to Cloudflare*, shows the guide first and points you to its section *Connect Cloudflare automatically*. Then it asks: *Paste your Cloudflare API token, or press Enter to skip and follow the manual steps in the guide.* Your domain must already be in Cloudflare with Cloudflare's nameservers (guide steps 1 and 2).

Create the token in Cloudflare under **My Profile → API Tokens → Create Token → Create Custom Token**. Give it these permissions, for your hotel's zone only (**Zone Resources: Include → Specific zone → your domain**):

| | | |
|---|---|---|
| Zone | Zone | Read |
| Zone | DNS | Edit |
| Zone | SSL and Certificates | Edit |
| Zone | Zone Settings | Edit |
| Zone | Zone WAF | Edit |
| Zone | Bot Management | Edit |

The installer hides the token while you paste it. It uses the token only while it runs and never writes it to a file, the log or the guide. You can delete the token in Cloudflare afterwards. With the token, the installer:

1. Checks the token and finds your domain in Cloudflare. When the domain is missing, it says so and lets you try again or skip.
2. Adds or updates proxied **A** records for `@`, `www` and the game address, pointing to this server's IPv4 address. It changes no other records and adds no **AAAA** records.
3. Creates a private key and a certificate request on the server (`openssl` on Linux, `certreq` on Windows) and gets a Cloudflare **Origin CA** certificate for `myhotel.com` and `*.myhotel.com`, valid for 15 years. The private key never leaves the server. The installer checks the certificate before it replaces the temporary one. Linux installs it in `/etc/ssl/plusemu` and reloads nginx; when `nginx -t` fails, the previous certificate comes back. Windows adds Cloudflare's Origin CA root certificate to the machine's trusted root certificates, because `certreq` accepts a certificate only from a trusted root, and puts the certificate on the hotel's HTTPS bindings in IIS. When a valid origin certificate is already installed, a rerun keeps it.
4. Turns on **Full (strict)** (only after the certificate is installed), **Always Use HTTPS**, TLS 1.2 or newer, **WebSockets**, **Browser Integrity Check**, security level **medium** and **Bot Fight Mode**. When *I'm Under Attack* mode is on, it stays on.
5. Adds one rate limiting rule, the one the Free plan allows: 10 requests per 10 seconds per visitor to `/login`, `/register`, `/forgot-password`, `/reset-password/*`, `/two-factor-challenge` and `/housekeeping/login`, then a 10 second block. The Free plan can match only the path, so opening these pages counts too, not only sending the forms.
6. Adds two custom rules: requests to the game connection whose `Origin` is not `https://myhotel.com` are blocked, and visitors to `/housekeeping` get a managed challenge.
7. Saves `CLOUDFLARE_SETUP=done` (Linux) or `CloudflareSetup` (Windows) and the certificate's expiry date in the saved settings, and rewrites the guide: a green box at the top lists what was set up and what to check, and the manual steps fold away under *If you need to do this by hand*.

It stops at the first step that fails, names that step, the permission the token lacks and Cloudflare's own error message, and the guide shows the reason at the top. A failed or skipped step never removes a working certificate. The installer finds its own records and rules by name, so running it again updates them instead of adding copies. When the setup is done, a rerun asks only *Press Enter to keep it, or paste a token to run it again*. For an unattended install, set `PLUSEMU_CLOUDFLARE_TOKEN`; without it, `PLUSEMU_YES=1` skips this step. A game address on another domain than the hotel's is left to the manual steps.

The installer starts with a temporary self-signed certificate. Complete the certificate steps before selecting **Full (strict)**. Keep the DNS records proxied with the orange cloud. Cloudflare Origin CA certificates protect the connection from Cloudflare to your server and are not trusted directly by browsers. The private key stays on your server. Paste only the CSR into Cloudflare.

Once Cloudflare is active and the certificate is installed, your hotel is live at `https://myhotel.com`, and housekeeping is at `https://myhotel.com/housekeeping`.

## How it works

Every step is logged. If a step fails, the installer shows the last lines of the log and stops. Fix the problem and run the same command again: the installer reuses your earlier answers and skips the steps that already finished.

**Linux** (`install.sh`):

1. Installs the system packages: nginx, MariaDB and PHP 8.5. Adds 4 GB of swap on servers with less than 2.5 GB of memory.
2. Installs Node.js 22 and Composer, which the website needs.
3. Downloads the latest PlusEMU and Volt releases, plus the Atom CMS version that matches the emulator's database.
4. Creates the `plus` database and imports the PlusEMU schema.
5. Downloads the hotel files.
6. Starts the emulator as the `plusemu` systemd service.
7. Installs the Atom CMS website and creates your admin account.
8. Configures nginx and the firewall:
   - nginx starts with a temporary self-signed HTTPS certificate. The Cloudflare step or the setup guide replaces it with a Cloudflare Origin CA certificate for **Full (strict)**.
   - It restores visitors' real IPs from Cloudflare and passes the game's WebSocket through to the emulator. The game connection carries the visitor's address in the `X-Real-IP` and `X-Forwarded-For` headers, because the emulator sees nginx as the peer.
   - It limits each visitor: 5 login, registration or password reset attempts per minute (plus a burst of 5), 30 housekeeping pages per minute (plus a burst of 20), 50 open requests and 20 game connections (many players can share one address, for example at a school). Over the limit, nginx answers 429. The game client and the hotel files have no limits.
   - It drops slow connections after 10 seconds and sends the `Strict-Transport-Security` and `Permissions-Policy` headers. `Strict-Transport-Security` covers the hotel domain only, not its subdomains.
   - The `ufw` firewall allows only SSH, HTTP and HTTPS. The database and the emulator stay private.
   - HTTPS is accepted only from Cloudflare's addresses, so nobody can go around Cloudflare to reach the hotel. HTTP stays open for the setup guide and the redirects, but nginx answers the hotel's own names only for Cloudflare and this server. `plusemu-cloudflare-ips` downloads Cloudflare's address lists every Sunday at 03:00 and updates the firewall and nginx. When a download fails, it changes nothing. If the download fails during a new install, HTTPS stays open to every address until the next successful run, and the installer says so.
9. Secures the server:
   - `fail2ban` bans an address for 1 hour after 5 failed SSH logins in 10 minutes. When CrowdSec runs, CrowdSec bans SSH attackers instead and fail2ban is off (see [CrowdSec](#crowdsec-advanced-guide-linux)).
   - Security updates from Debian or Ubuntu install every day at 05:00 server time with `unattended-upgrades`. The server restarts right after, but only when an update needs it. Unused packages are removed. The emulator, the client, the website and PHP are not touched: update them with `plusemu-update` and the PHP script below.
   - Network settings in `/etc/sysctl.d/90-plusemu.conf` turn on SYN cookies and raise the queues for new connections, so a flood of connections does not stop the server.
   - Installer, update, backup and Cloudflare address logs and the website log rotate daily and are kept for 14 days. The emulator logs to the system journal, which keeps 14 days and at most 1 GB.
   - A nightly backup runs at 04:00 (see [Nightly backups](#nightly-backups)).
   - A health check runs every 5 minutes (see [Health check and Discord alerts](#health-check-and-discord-alerts)).
   - SSH lets root log in with a key only. SSH password login goes off only when your login uses an SSH key (this session, or the account that ran `sudo` has a key in `~/.ssh/authorized_keys`). Otherwise password login stays on, and the installer says so. The settings are in `/etc/ssh/sshd_config.d/10-plusemu.conf`.
10. Writes your setup guide.
11. Connects your hotel to Cloudflare when you paste an API token (see [Connect Cloudflare automatically](#connect-cloudflare-automatically)).

**Windows** (`install.ps1`) follows the same steps with Windows equivalents:

- IIS with URL Rewrite, the reverse proxy and WebSockets. The game connection carries the visitor's address in the `X-Real-IP` header (from Cloudflare's `CF-Connecting-IP`), and the reverse proxy adds `X-Forwarded-For` without the port. On Windows 10 and 11, IIS comes from the optional Windows features.
- MariaDB 11.4
- The emulator as the `PlusEMU` Windows service
- Windows Firewall rules for the website: HTTP and HTTPS are accepted only from Cloudflare's addresses, so nobody can go around Cloudflare to reach the hotel. Windows needs no open HTTP port, because the setup guide is a file on the desktop. The *PlusEMU Cloudflare addresses* task updates the addresses every Sunday at 03:00. When a download fails, it changes nothing. If the download fails during a new install, the website stays open to every address until the next successful run, and the installer says so. The installer turns off the *World Wide Web Services* rules that IIS adds, because they let every address in. A rule that you add yourself for ports 80 or 443 also lets every address in.
- An account lockout policy: an account locks for 10 minutes after 10 wrong passwords in 10 minutes, the default of new Windows versions. A lower limit would let an attacker keep the built-in Administrator locked out. RDP and SSH are not opened or changed.
- The *PlusEMU log cleanup* task removes emulator, website and IIS logs older than 14 days, every day at 03:30. Windows has SYN flood protection built in and has no settings for it, so the installer changes nothing there.
- The *PlusEMU nightly backup* task makes the nightly backup at 04:00 (see [Nightly backups](#nightly-backups)).
- The *PlusEMU health check* task checks the hotel every 5 minutes (see [Health check and Discord alerts](#health-check-and-discord-alerts)).
- No CrowdSec: the Windows installer does not install it (see [CrowdSec](#crowdsec-advanced-guide-linux)).
- Windows Update installs updates every day at 05:00 and restarts the server only when an update needs it. Windows has no security-only updates, so all quality updates install. Driver updates are left out. The installer sets these Windows Update policies under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`: `NoAutoUpdate=0`, `AUOptions=4`, `ScheduledInstallDay=0`, `ScheduledInstallTime=5`, `AlwaysAutoRebootAtScheduledTime=1` and `AlwaysAutoRebootAtScheduledTimeMinutes=15`, plus `ExcludeWUDriversInQualityUpdate=1` one level up. A domain Group Policy can replace them.
- IIS Dynamic IP Restrictions: each visitor gets at most 50 open requests and 1500 requests in 10 seconds, read from the address Cloudflare forwards. Over the limit, IIS answers 403. IIS cannot limit single pages, so the login limits come from Atom CMS itself (5 attempts per minute). Uploads are limited to 20 MB, and request headers must arrive within 10 seconds.
- The `Strict-Transport-Security` header (for the hotel domain only, not its subdomains) and the `Permissions-Policy` header
- The setup guide, then the Cloudflare step (see [Connect Cloudflare automatically](#connect-cloudflare-automatically))

The pages the installer generates, such as the setup guide and the client configuration, come from the templates in [`templates/`](templates). When you run the installer through `curl | bash` or `irm | iex`, it downloads these templates from this repository's `main` branch, so a fix merged here reaches every new install.

## Files and everyday commands

| | Linux | Windows |
|---|---|---|
| Hotel files | `/var/www/hotel` | `C:\Hotel` |
| Saved answers and passwords | `/etc/plusemu/hotel.env` | `C:\ProgramData\PlusEMU\hotel.json` |
| Installer log | `/var/log/plusemu-install.log` | `C:\ProgramData\PlusEMU\install.log` |
| Installed versions | `/etc/plusemu/versions.env` | `C:\ProgramData\PlusEMU\versions.json` |
| Update log | `/var/log/plusemu-update.log` | `C:\ProgramData\PlusEMU\update.log` |
| Update backups | `/var/backups/plusemu` | `C:\ProgramData\PlusEMU\backups` |
| Nightly backups | `/var/backups/plusemu/nightly` | `C:\ProgramData\PlusEMU\backups\nightly` |
| Backup log | `/var/log/plusemu-backup.log` | `C:\ProgramData\PlusEMU\backup.log` |
| Make a backup now | `sudo plusemu-backup` | `Start-ScheduledTask 'PlusEMU nightly backup'` |
| Health check log | `/var/log/plusemu-health.log` | `C:\ProgramData\PlusEMU\health.log` |
| Check the hotel now | `sudo plusemu-health` | `& C:\ProgramData\PlusEMU\plusemu-health.ps1` |
| Cloudflare address log | `/var/log/plusemu-cloudflare-ips.log` | `C:\ProgramData\PlusEMU\cloudflare-ips.log` |
| Refresh Cloudflare's addresses now | `sudo plusemu-cloudflare-ips` | `Start-ScheduledTask 'PlusEMU Cloudflare addresses'` |
| Restart the emulator | `sudo systemctl restart plusemu` | `Restart-Service PlusEMU` |
| Watch the emulator log | `sudo journalctl -u plusemu -f` | `Get-Content C:\Hotel\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait` |
| Setup guide | `/var/www/hotel/setup-guide/index.html`, at `http://<server IP>/<token>/` (local install: `http://localhost/<token>/`) | `C:\Hotel\setup-guide\index.html` and *Hotel setup guide* on the desktop |
| Node.js of a local install | `/opt/plusemu-node` | `C:\ProgramData\PlusEMU\node` |

A [local install](#local-install) has no Cloudflare address log and no Cloudflare refresh command.

Only root (Linux) or Administrators (Windows) can read the file with passwords.

### Retrieve passwords and connect to MariaDB

On Linux, run `sudo cat /etc/plusemu/hotel.env`. `ADMIN_PASSWORD` is the initial website password and `DB_PASSWORD` is the database password. On Windows, run `Get-Content C:\ProgramData\PlusEMU\hotel.json` in an Administrator PowerShell; the fields are `AdminPassword`, `DbPassword` and `DbRootPassword`.

Use host `127.0.0.1`, port `3306`, database `plus`, username `hotel` and the database password. From the server:

```bash
mariadb --host=127.0.0.1 --port=3306 --user=hotel --password plus
```

Enter the database password at the prompt. On Windows, use `mariadb.exe` from your MariaDB installation's `bin` folder. For a desktop database client, connect through an SSH tunnel to the server with destination `127.0.0.1:3306`; use your server's SSH address, not the Cloudflare-proxied hotel domain. Keep port 3306 private.

Linux database root uses local socket authentication (`sudo mariadb`); no root password is generated. Windows database root uses the saved `DbRootPassword`.

Change your initial admin password after logging in. The saved file still contains the initial value. Keep the file and terminal password summary private, and remove credentials before sharing logs or screenshots.

## Nightly backups

Every night at 04:00 server time, the installer's backup saves what a download cannot bring back. It keeps the newest 7 backups, each in its own folder named by its time (UTC):

- `database.sql.gz`: the whole `plus` database.
- `hotel.tar.gz`: the emulator's `Config` folder, the client's `configuration` folder, the website's `.env` file and uploads (`cms/storage/app`), and the hotel's texts (`hotel-files/gamedata`).
- `settings.tar.gz`: the saved answers, passwords and versions. On Linux also the HTTPS certificate in `/etc/ssl/plusemu`. On Windows the certificate stays in the Windows certificate store; export it yourself if you need a copy.

The backup leaves out what the installer or `plusemu-update` downloads again: the emulator and client programs and the stock hotel files. Furniture, clothes or badges that you added to `hotel-files` yourself are not in the backup, so keep your own copy of them. When an update is running, the backup waits for it. When the disk has less than 2 GB free plus the size of the database, it makes no backup and writes the reason in the backup log. The update backups (newest 3) stay separate.

These backups are on the same server, so they cannot recover a lost server. Copy them to another place now and then.

To restore the database of a backup on Linux (the hotel loses every change made since then):

```bash
sudo systemctl stop plusemu
gunzip -c /var/backups/plusemu/nightly/<time>/database.sql.gz | sudo mariadb plus
sudo systemctl start plusemu
```

To get files back, unpack the file you need from `hotel.tar.gz`, for example `sudo tar -xzf /var/backups/plusemu/nightly/<time>/hotel.tar.gz -C /var/www/hotel emulator/Config`.

## Health check and Discord alerts

Every 5 minutes, the health check looks at your hotel (Linux: cron runs `/usr/local/sbin/plusemu-health`; Windows: the *PlusEMU health check* task runs `C:\ProgramData\PlusEMU\plusemu-health.ps1`). It checks that:

- The emulator service runs, and the game port 2096 and the emulator API port 8080 answer on `127.0.0.1`.
- The web server (nginx or IIS) runs, and the website answers on this server.
- MariaDB answers.
- The disk with the hotel has more than 2 GB free.
- The newest nightly backup is younger than 36 hours. A new hotel has no backup before its first night, so this check waits for it.
- The HTTPS certificate is valid for more than 30 more days (Linux: `/etc/ssl/plusemu/cert.pem`; Windows: the hotel's HTTPS binding). Not on a [local install](#local-install).
- The last Cloudflare address refresh worked and is younger than 8 days. Not on a local install.

Each run writes its result to the health log (see [Files and everyday commands](#files-and-everyday-commands)). Run it by hand at any time with `sudo plusemu-health` on Linux, or `& C:\ProgramData\PlusEMU\plusemu-health.ps1` in Administrator PowerShell on Windows. The installer also runs it once at the end. While an update, a nightly backup or the installer runs, the check skips its run, because they stop or restart services on purpose.

A local install has no Discord alerts; the result is in the health log only. With a Discord webhook, you get one message when a check starts failing and one when it works again. The message says what failed in plain words and gives the command to look at it. You get no message while nothing changes. When Discord does not take a message, the next run tries again. Messages contain no passwords or tokens. To make a webhook in Discord, open your server's **Server Settings → Integrations → Webhooks → New Webhook**, choose the channel and click **Copy Webhook URL**. When you add a webhook, the installer sends one message so you see that alerts work. If that message fails, the installer says why and goes on.

The webhook is saved with your other settings (`DISCORD_WEBHOOK` in `/etc/plusemu/hotel.env` or `DiscordWebhook` in `C:\ProgramData\PlusEMU\hotel.json`), which only root or Administrators can read. It is never written to the installer log. Reruns keep it. To change it, run the installer again with the new URL; use `off` to turn alerts off:

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo env PLUSEMU_DISCORD_WEBHOOK=https://discord.com/api/webhooks/... bash
```

```powershell
$env:PLUSEMU_DISCORD_WEBHOOK = 'https://discord.com/api/webhooks/...'
irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
Remove-Item Env:\PLUSEMU_DISCORD_WEBHOOK
```

## CrowdSec (advanced guide, Linux)

With the advanced guide, the Linux installer asks: *Install CrowdSec to detect and block attackers (shared blocklist)?* The answer is saved, and reruns keep it. For an unattended install, set `PLUSEMU_CROWDSEC=1`. The simple guide never installs CrowdSec.

[CrowdSec](https://www.crowdsec.net/) reads your server's logs and finds attack patterns, such as password guessing on SSH or scans for known website weaknesses. It bans the addresses that attack you. It also shares the attacks it sees and uses a blocklist of known bad addresses that other CrowdSec users report. The installer:

- Installs CrowdSec from CrowdSec's own package repository, with the `crowdsecurity/sshd`, `crowdsecurity/nginx`, `crowdsecurity/base-http-scenarios` and `crowdsecurity/http-cve` collections. It reads the nginx access and error logs and the SSH journal.
- Installs two bouncers, the programs that apply a ban: `crowdsec-firewall-bouncer-iptables` blocks banned addresses at the firewall (for example SSH), and `crowdsec-nginx-bouncer` blocks banned visitors on the website. The website bouncer uses the visitor's real address, which nginx restores from Cloudflare. Ubuntu 22.04's nginx has no Lua module, so there CrowdSec bans at the firewall only, and the installer says so.
- Never bans Cloudflare's addresses or this server. A ban on a Cloudflare address would cut off real players, so a whitelist (`/etc/crowdsec/parsers/s02-enrich/plusemu-whitelist.yaml`) lists `127.0.0.1` and Cloudflare's ranges. `plusemu-cloudflare-ips` updates it every week.
- Moves CrowdSec's local API to `127.0.0.1:8085`, because the emulator uses port 8080.
- Turns fail2ban off while CrowdSec and its firewall bouncer run, so one tool owns SSH bans and one command unbans an address. When CrowdSec does not install or start, fail2ban stays on.

Everyday commands:

```bash
sudo cscli decisions list                   # see who is banned and why
sudo cscli decisions delete --ip 192.0.2.7  # unban an address
sudo cscli alerts list                      # see the attacks CrowdSec found
```

Optional: see your server in the free [CrowdSec console](https://app.crowdsec.net/). Sign up, copy the enrollment command from the engines page and run it on your server (`sudo cscli console enroll <key>`). Accept the server in the console, then run `sudo systemctl restart crowdsec`.

To stop managing CrowdSec, run the installer again with `PLUSEMU_CROWDSEC=0`. fail2ban comes back on. CrowdSec stays installed until you remove it: `sudo apt purge crowdsec crowdsec-firewall-bouncer-iptables crowdsec-nginx-bouncer`.

**Windows:** the Windows installer does not install CrowdSec. CrowdSec reads the visitor's address from the web server log, and IIS logs the address that connects to it, which is always Cloudflare's. CrowdSec on Windows would ban Cloudflare instead of attackers, or with Cloudflare on its whitelist, it could never ban a website visitor.

## One-command updates

Hotels set up with this installer update the emulator, the client and the hotel files in place, on Linux and on Windows.

**Linux, first time only:**
```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh | sudo bash -s -- update
```

**Linux, after that:**
```bash
sudo plusemu-update
```

**Windows (PowerShell as Administrator), first time only:**
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1))) -Update
```

**Windows, after that:**
```powershell
plusemu-update
```

**What it does**
- Downloads and checks the new releases before touching anything.
- Backs up the database, emulator, client and hotel files to `/var/backups/plusemu/` or `C:\ProgramData\PlusEMU\backups\` (newest 3 kept).
- Installs the new versions and runs the database migrations.
- Installs the newest hotel files pack (furniture, clothing, effects, badges, texts, icons, sounds, about 550 MB) whenever it changed, so the hotel never misses stock content. Files you added to `hotel-files` stay. The emulator's clothing data (`Config/figuredata.xml`) is replaced by the release's one that matches the pack.
- Keeps your `Config/` and `configuration/` files and anything you added. New settings are added, your own values stay.
- Restores the backup automatically if any step fails.

**Options** (Linux `--check`, Windows `-Check`, and so on)
- `check`: show available updates, change nothing.
- `yes`: update without the "Update now?" question.
- `rollback`: restore the last backup. The database goes back too, so progress since then is lost.
- `assets`: hotel files only, without stopping the emulator. Adds every stock file the hotel lacks and leaves the files it already has as they are. Only the `gamedata` index (clothing, effects, products, texts) is replaced; the previous one is kept in the backups folder as `gamedata-<version>`. Run the full update afterwards when new clothing does not show: the emulator's clothing data comes with it.

`--with-assets` is still accepted and does nothing: the hotel files are part of every update now.

### Examples
```bash
# Only check what is new, change nothing
sudo plusemu-update --check

# Update without the "Update now?" question
sudo plusemu-update --yes

# Add the stock hotel files the hotel lacks, without downtime
sudo plusemu-update --assets

# Undo the last update (the database goes back too)
sudo plusemu-update --rollback
```

```powershell
plusemu-update -Check
plusemu-update -Yes
plusemu-update -Assets
plusemu-update -Rollback
```

Log: `/var/log/plusemu-update.log` or `C:\ProgramData\PlusEMU\update.log`. Post it here if something breaks (no passwords).

Running the installer again also refreshes the hotel files when a newer pack exists, and keeps everything else as it is.

### The hotel files pack

Both installers download `hotel-files.tar.gz` from the rolling [`hotel-files` release](https://github.com/plus-emulator/plusemu-installer/releases/tag/hotel-files). The pack is built from the `plusemu-assets` bucket by [`tools/hotel-files.py`](tools/hotel-files.py) and published by the [Hotel files workflow](.github/workflows/hotel-files.yml) (every Monday, or by hand through "Run workflow"). The workflow needs a `CLOUDFLARE_API_TOKEN` repository secret with read access to the bucket.

The pack holds everything the installed client loads from `/hotel-files/`: `assets/` (furniture, figure, effect and pet libraries as `.hab`, images, sounds), `c_images/`, `gamedata/`, `images/`, `sounds/` and `habbicons/`. It leaves out the client build (that comes with the Volt release), CMS screenshots, the `.nitro` copies of the libraries (the client loads `.hab`) and stray editor files. The first 12 characters of the pack's SHA-256 are the version the installers record and compare.

To see what the bucket has that the published pack lacks:

```bash
CLOUDFLARE_API_TOKEN=... python3 -I tools/hotel-files.py check
```

To build and publish by hand:

```bash
CLOUDFLARE_API_TOKEN=... python3 -I tools/hotel-files.py build --out dist
gh release upload hotel-files dist/hotel-files.tar.gz dist/SHA256SUMS --clobber
```

Hotels with their own files can point `ASSET_PACK_URL` at another `hotel-files.tar.gz`; a `SHA256SUMS` file next to it is checked when it exists.

## Keep PHP patched

PHP ships security fixes as patch releases (for example 8.5.11 to 8.5.12). These scripts
update PHP to the newest patch release of the version you already run. They work on any
hotel, also ones not made by this installer. They never move you to a newer PHP version
(8.2 stays 8.2), because that needs a check of the website code first.

Debian or Ubuntu with php-fpm:

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/php-update.sh | sudo bash
```

Windows Server with IIS (PowerShell as Administrator):

```powershell
irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/php-update.ps1 | iex
```

What they do:

- Read the newest release of your PHP version from php.net.
- Linux: upgrade the `php8.x-*` packages and restart `php8.x-fpm`. When your Linux packages are
  behind php.net, the script adds the Sury (Debian) or Ondřej (Ubuntu) PHP packages, the same
  ones `install.sh` uses. If php.net released today and the packages are not built yet, the
  script says so; run it again later.
- Windows: download the matching build from windows.php.net (same thread safety, compiler and
  bitness), check its SHA256, keep a backup copy of the PHP folder, stop IIS, unpack the new
  files over the old ones (`php.ini` is kept), start IIS and check the version. On an error the
  backup is put back.
- PHP 8.1 or older gets no security fixes any more. The scripts stop and tell you to update to
  PHP 8.2 or newer by hand.

Only report, change nothing: `sudo bash php-update.sh --check` or `powershell -File php-update.ps1 -Check`.

## Unattended installs

To install without questions, set the answers in environment variables:

| Variable | Meaning |
|---|---|
| `PLUSEMU_LOCAL=1` | [Local install](#local-install) on this PC at `http://localhost` (the same as `--local` or `-Local`). `PLUSEMU_LOCAL=0` asks for a server install. A saved install keeps its choice. |
| `PLUSEMU_DOMAIN` | Hotel domain (required, except for a local install) |
| `PLUSEMU_WS_URL` | WebSocket address (default `wss://<domain>/ws`) |
| `PLUSEMU_HOTEL_NAME` | Hotel name |
| `PLUSEMU_ADMIN_USER` | Admin username (default `admin`) |
| `PLUSEMU_ADMIN_EMAIL` | Admin email (default `admin@<domain>`, or `admin@localhost.test` for a local install) |
| `PLUSEMU_YES=1` | Skip the confirmation question |
| `PLUSEMU_CLOUDFLARE_TOKEN` | Cloudflare API token for [Connect Cloudflare automatically](#connect-cloudflare-automatically). It is used once and never saved. Without it, `PLUSEMU_YES=1` skips that step. |

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh \
  | sudo PLUSEMU_DOMAIN=myhotel.com PLUSEMU_YES=1 bash
```

Advanced overrides:

- `INSTALLER_REF` installs from another branch or tag of this repository.
- `EMULATOR_URL`, `CLIENT_URL`, `ASSET_PACK_URL`, `ATOM_REPO` and `ATOM_REF` change where the components come from. A custom emulator or client URL is saved as version `custom`.

## Troubleshooting

- **The installer stopped with an error:** read the log lines it printed, fix the cause, then run the command again. It continues where it stopped.
- **Atom reports that the password needs a symbol:** rerun the current installer. It replaces an invalid saved admin password while CMS setup is incomplete and saves the replacement before retrying. Completed installations keep their existing admin password; database passwords are reused.
- **Cloudflare errors 521, 522, 526, "too many redirects", or the client won't connect:** see *Something isn't working?* at the bottom of your setup guide.
- **Local install: "The hotel needs ports that another program uses":** the message names the port and the program. Stop that program, for example with `sudo systemctl stop apache2` on Linux, or in *Services* on Windows, then run the installer again.
- **Local install: "cannot turn it into a server install" (or "into a local install"):** an install keeps its choice. Use the server installer on a server, and the local installer on another PC.
- **Still stuck:** ask on DevBest and include the installer log.

## Licence

Licensed under the GNU General Public License, version 3 only (`GPL-3.0-only`). See [LICENSE](LICENSE).
