# PlusEMU installer

Set up a complete Habbo hotel on your own server with one command. The installer downloads, installs and connects:

- **PlusEMU**, the emulator (game server)
- **Volt**, the game client
- **Atom CMS**, the website and housekeeping
- **MariaDB**, **PHP** and a web server (**nginx** on Linux, **IIS** on Windows)
- The hotel files: furniture, clothes, badges and texts (about 470 MB)

Everything runs on your server. Cloudflare sits in front of it to provide HTTPS and to hide your server's IP address.

## Requirements

| | Linux | Windows |
|---|---|---|
| System | Debian 12/13 or Ubuntu 22.04/24.04/26.04 | Windows Server 2019/2022/2025 |
| Processor | 64-bit (x86_64 or arm64) | 64-bit |
| Free disk space | 10 GB | 15 GB on `C:` |
| Access | root (`sudo`) | PowerShell as Administrator |

You also need:

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

The installer asks five questions. Press Enter to accept a suggested answer:

1. Your hotel's domain, for example `myhotel.com`
2. The WebSocket address the game connects to. The default, `wss://myhotel.com/ws`, needs no extra Cloudflare setup.
3. The hotel name
4. The username for your admin account
5. The email for your admin account

After you confirm, the installer runs on its own in about 10 minutes.

## When it finishes

The installer generates passwords automatically and prints your initial admin login and database connection details, including the database password. On Windows it also prints the MariaDB root password. These passwords are saved before installation starts; the installer tells you where to retrieve them even if a later step fails. The final password summary is shown in the terminal, not written to the installer log or browser setup guide.

It also points you to a **setup guide**: a web page with step-by-step instructions for connecting your domain through Cloudflare, which takes about 5 minutes.

- **Linux:** open `http://<your server IP>/<token>/`. The installer prints the exact address. The token is random so that strangers can't find the page.
- **Windows:** the guide opens in your browser. A copy named *Hotel setup guide* is saved on your desktop.

The guide walks you through:

1. Adding your domain to Cloudflare
2. Pointing your domain's nameservers to Cloudflare
3. Adding the DNS records (proxied, orange cloud)
4. Setting SSL/TLS to **Full**, turning on Always Use HTTPS and checking that WebSockets are on
5. Opening your hotel and logging in

Once Cloudflare is active, your hotel is live at `https://myhotel.com`, and housekeeping is at `https://myhotel.com/housekeeping`.

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
   - nginx serves the site over HTTPS with a self-signed certificate that Cloudflare accepts in **Full** mode.
   - It restores visitors' real IPs from Cloudflare and passes the game's WebSocket through to the emulator.
   - The `ufw` firewall allows only SSH, HTTP and HTTPS. The database and the emulator stay private.
9. Writes your setup guide.

**Windows** (`install.ps1`) follows the same steps with Windows equivalents:

- IIS with URL Rewrite, the reverse proxy and WebSockets
- MariaDB 11.4
- The emulator as the `PlusEMU` Windows service
- Windows Firewall rules for the website

The pages the installer generates, such as the setup guide and the client configuration, come from the templates in [`templates/`](templates). When you run the installer through `curl | bash` or `irm | iex`, it downloads these templates from this repository's `main` branch, so a fix merged here reaches every new install.

## Files and everyday commands

| | Linux | Windows |
|---|---|---|
| Hotel files | `/var/www/hotel` | `C:\Hotel` |
| Saved answers and passwords | `/etc/plusemu/hotel.env` | `C:\ProgramData\PlusEMU\hotel.json` |
| Installer log | `/var/log/plusemu-install.log` | `C:\ProgramData\PlusEMU\install.log` |
| Restart the emulator | `sudo systemctl restart plusemu` | `Restart-Service PlusEMU` |
| Watch the emulator log | `sudo journalctl -u plusemu -f` | `Get-Content C:\Hotel\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait` |

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

## Unattended installs

To install without questions, set the answers in environment variables:

| Variable | Meaning |
|---|---|
| `PLUSEMU_DOMAIN` | Hotel domain (required) |
| `PLUSEMU_WS_URL` | WebSocket address (default `wss://<domain>/ws`) |
| `PLUSEMU_HOTEL_NAME` | Hotel name |
| `PLUSEMU_ADMIN_USER` | Admin username (default `admin`) |
| `PLUSEMU_ADMIN_EMAIL` | Admin email (default `admin@<domain>`) |
| `PLUSEMU_YES=1` | Skip the confirmation question |

```bash
curl -fsSL https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.sh \
  | sudo PLUSEMU_DOMAIN=myhotel.com PLUSEMU_YES=1 bash
```

Advanced overrides:

- `INSTALLER_REF` installs from another branch or tag of this repository.
- `EMULATOR_URL`, `CLIENT_URL`, `ASSET_PACK_URL`, `ATOM_REPO` and `ATOM_REF` change where the components come from.

## Troubleshooting

- **The installer stopped with an error:** read the log lines it printed, fix the cause, then run the command again. It continues where it stopped.
- **Atom reports that the password needs a symbol:** rerun the current installer. It replaces an invalid saved admin password while CMS setup is incomplete and saves the replacement before retrying. Completed installations keep their existing admin password; database passwords are reused.
- **Cloudflare errors 521, 522, 526, "too many redirects", or the client won't connect:** see *Something isn't working?* at the bottom of your setup guide.
- **Still stuck:** ask on DevBest and include the installer log.

## Licence

Licensed under the GNU General Public License, version 3 only (`GPL-3.0-only`). See [LICENSE](LICENSE).
