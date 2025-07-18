\# up\_ports.sh



A lightweight, shell-based utility for FreeBSD that:



\- Updates the system ports tree via Git

\- Checks installed packages for known vulnerabilities using `pkg audit`

\- Verifies if newer versions of vulnerable packages are available in the current ports tree



---



\## 🔖 Version



\*\*v1.0\*\*



---



\## 📦 Requirements



\- FreeBSD 13.0 or later (tested up to FreeBSD 15-CURRENT)

\- Ports tree initialized via Git (`/usr/ports`)

\- Tools:

&nbsp; - `git`

&nbsp; - `make`

&nbsp; - `pkg`



---



\## 🚀 Features



\- Fully shell-scripted, no external dependencies

\- Does \*\*not\*\* rely on `make index` (slow)

\- Uses real-time `make -V PKGNAME` comparison from the ports Makefile

\- Safe to use in production or cron jobs

\- Clearly logs:

&nbsp; - Installed version

&nbsp; - Version available in ports

&nbsp; - Status: up-to-date or update available



---



\## 🛠 Usage



1\. Clone or copy the script into your system:

&nbsp;  ```sh

&nbsp;  mkdir -p /usr/local/scripts

&nbsp;  fetch https://github.com/kmansur/Scripts/tree/main/FreeBSD/up\_ports.sh -o /usr/local/scripts/up\_ports.sh

&nbsp;  chmod +x /usr/local/scripts/up\_ports.sh

