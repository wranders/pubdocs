# Xen-Orchestra

This guide is written using the following versions:

* [CentOS](https://www.centos.org/) 8.0.1905 (Core)
* [Xen-Orchestra](https://xen-orchestra.com/) 5.54.0
* [Node.js](https://nodejs.org/) 10.16.3
* [Yarn](https://yarnpkg.com/) 1.12.1
* [Nginx](https://www.nginx.com/) 1.14.1
* [Redis](https://redis.io/) 5.0.3

Certain considerations with configuration have been taken to satisfy my environment and requirements. Most notably:

1. [XCP-ng](https://xcp-ng.org/) servers use certificates from my internal certificate authority (CA), so for Node.js to use the system's roots or provided roots without allowing "Unauthorized Certificates", it must run in an unprivileged state.
    * Non-root user
    * Non-system user
    * No Linux Capablities (ie. `cap_net_bind_service`), so no binding to ports <1024
2. Nginx will terminate SSL and proxy traffic to Xen-Orchestra to satisfy the non-root requirement
3. Nginx will automatically redirect HTTP traffic to HTTPS
4. NFS remotes are used for backup services, so the Xen-Orchestra user is granted `NOPASSWD` access in `sudoers` to the `mount` and `umount` commands.
    * A [systemd](https://freedesktop.org/wiki/Software/systemd/) drop-in is used to define a RuntimeDirectory where Xen-Orchestra mounts NFS remotes

---

## Repositories

The only third-party repository that is required is Yarn's.

```sh
curl -sL https://dl.yarnpkg.com/rpm/yarn.repo | sudo tee /etc/yum.repos.d/yarn.repo
```

## Dependencies

Update repositories and upgrade any outdated packages:

```sh
sudo dnf update -y
```

Install dependencies. `G++` is required to compile some parts of Xen-Orchestra.

```sh
sudo dnf install -y nodejs yarn nginx redis git gcc-c++ nfs-utils
```

!!! Info
    The official ["From the Sources"](https://xen-orchestra.com/docs/from_the_sources.html) documentation says to use Node.js 8, but the System `AppStream` repository contains v10. I've encountered no issues with the newer version. Besides, v8 is [EOL as of 1 January 2020](https://nodejs.org/en/about/releases/) and no longer recieving any updates.

## Redis

Set Redis to start on boot and start:

```sh
sudo systemctl enable --now redis.service
```

Verify Redis is running:

```sh
redis-cli ping
```

If Redis is running, `PONG` should be printed to the console.

## Application

Create the application user:

```sh
sudo adduser -m -U \
-c "Xen-Orchestra User" \
-s /sbin/nologin xo
```

!!! Error "Critical"
    Do **NOT** run Xen-Orchestra as the `root` user.

!!! Info
    The `-m` flag creates a home directory (`/home/xo`) so `yarn` can create its cache.

!!! Info
    Creating the `xo` user as a system user (`-r` flag) will prevent the use of system or provided root certificates.

Clone the Xen-Orchestra repository master branch to `/opt/`:

```sh
sudo git clone -b master https://github.com/vatesfr/xen-orchestra /opt/xen-orchestra
```

Set the `xo` user as the owner of the repository directory:

```sh
sudo chown -R xo:xo /opt/xen-orchestra
```

!!! Info
    `yarn` commands are run with the `--cwd` flag and directory location so that they can be run from any directory.

Gather Yarn dependencies and build the application. This will take a while:

```sh
sudo -u xo yarn --cwd /opt/xen-orchestra && \
sudo -u xo yarn --cwd /opt/xen-orchestra build
```

Create the configuration and data directories:

```sh
sudo mkdir /etc/xo-server /var/lib/xo-server
```

Set ownership of the data directory to the `xo` user:

```sh
sudo chown xo:xo /var/lib/xo-server
```

### Configuration

Create `/etc/xo-server/config.toml`:

```sh
[http]

[[http.listen]]
hostname = '127.0.0.1'
port = 8080

[http.mounts]

[http.proxies]

[redis]

[remoteOptions]
useSudo = true
```

### systemd and sudoers

Create the systemd unit file:

```sh
echo "[Unit]
Description=Xen-Orchestra - Xen Server Web Manager
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
User=xo
Group=xo
Environment=NODE_OPTIONS=--use-openssl-ca
Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-bundle.crt
ExecStart=/opt/xen-orchestra/packages/xo-server/bin/xo-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/xo.service >/dev/null
```

To allow the mount of NFS remotes, a few things need to be done.

Create a directory for the service unit drop-ins:

```sh
sudo mkdir /etc/systemc/system/xo.service.d
```

Create the service unit drop-in:

```sh
echo "[Service]
RuntimeDirectory=xo-server
RuntimeDirectoryMode=0750" | \
sudo tee /etc/systemd/system/xo.service.d/nfs.conf >/dev/null
```

To mount the NFS remotes, the `xo` user needs `NOPASSWD` `sudo` access to the `mount` and `umount` commands. Create a sudoers file containing these permissions:

```sh
echo -e "xo\tALL=(root)\tNOPASSWD:$(which mount),$(which umount)" | \
sudo tee /etc/sudoers.d/xo
```

!!! Danger "Warning"
    Do **NOT** edit `/etc/sudoers` directly, or without `visudo`. If an error is made, `sudo` will be broken and the `root` user will be needed to correct it.

!!! Info
    A file is made in `/etc/sudoers.d` instead of adding a line to `/etc/sudoers` because updates can cause the `/etc/sudoers` file to be reset.

!!! Warning
    If the server is domain-joined with `realmd` and `sssd`, and file domains are enabled (`enable_files_domain = True`) in `sssd.conf`, the `implicit_file` domain would have to be added to the `xo` username:

    ```sh
    xo@implicit_domain    ALL=(root)    NOPASSWD: /usr/bin/mount, /usr/bin/umount
    ```

Update the systemd database:

```sh
sudo systemctl daemon-reload
```

Set Xen-Orchestra to start on boot and start now:

```sh
sudo systemctl enable --now xo.service
```

Make sure the application is responding:

```sh
curl -I 127.0.0.1:8080
```

`HTTP/1.1 302 Found` should be the response if Xen-Orchestra is running.

## Nginx

Move the default Nginx configuration since it's easier to replace than edit:

```sh
sudo mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf/orig
```

Recreate `/etc/nginx/nginx.conf` with the following contents:

```sh
user nginx;
pid /run/nginx.pid;
worker_processes auto;

include /usr/share/nginx/modules/*.conf;

events {
    multi_accept on;
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    error_log   /var/log/nginx/error.log warn;

    sendfile            on;
    tcp_nopush          on;
    server_tokens       off;
    log_not_found       off;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
}
```

This configuration is essentially the default configuration without the default `server` blocks and a few adjustments.

Create the server configuration at `/etc/nginx/conf.d/xo.conf` with the following contents.

```sh hl_lines="3 9 39"
server {
    listen      80;
    server_name xo.example.local;
    return      301     https://$host$request_uri;
}

server {
    listen      443 ssl http2;
    server_name xo.example.local;

    ssl_certificate     /etc/ssl/private/xo/cert.pem;
    ssl_certificate_key /etc/ssl/private/xo/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    add_header  X-Frame-Options             "SAMEORIGIN"                                                    always;
    add_header  X-XSS-Protection            "1; mode=block"                                                 always;
    add_header  X-Content-Type-Options      "nosniff"                                                       always;
    add_header  Referrer-Policy             "no-referrer-when-downgrade"                                    always;
    add_header  Content-Security-Policy     "default-src 'self' http: https: data: blob: 'unsafe-inline'"   always;
    add_header  Strict-Transport-Security   "max-age=31536000"                                              always;

    location / {
        proxy_http_version      1.1;
        proxy_cache_bypass      $http_upgrade;
        proxy_set_header        Upgrade                 $http_upgrade;
        proxy_set_header        Connection              "upgrade";
        proxy_set_header        Host                    $host;
        proxy_set_header        X-Real-IP               $remote_addr;
        proxy_set_header        X-Forwarded-For         $proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto       $scheme;
        proxy_set_header        X-Forwarded-Host        $host;
        proxy_set_header        X-Forwarded-Port        $server_port;

        proxy_pass      http://127.0.0.1:8080/;

        proxy_read_timeout 1800;

        client_max_body_size 4G;
    }
}
```

!!! Info
    Ensure the `server_name` property reflects the domain name that Xen-Orchestra will be accessed by.

!!! Info
    If the "Virtual Machine Import" feature will be used, the `client_max_body_size` property may need to be adjusted depending on the size of your VM backup files. If a file is larger than what is defined here, Nginx will respond with a `client intended to send too large body` error.

Ensure SSL files are in the correct locations:

|                       |                                   |
|-                      |-                                  |
| Private Key           | `/etc/ssl/private/xo/key.pem`     |
| Public Certificate    | `/etc/ssl/private/xo/cert.pem`    |

If you don't already have a certificate and want to use a self-signed one, see [here](../../self-signed-certificate-with-root/) for how to create an installable self-signed certificate.

Test the configuration:

```sh
sudo nginx -t
```

Restart Nginx:

```sh
sudo systemctl restart nginx.service
```

Allow HTTP (port `80`) and HTTPS (port `443`) through the firewall:

```sh
sudo firewall-cmd --permanent --zone=public --add-service=http
```

```sh
sudo firewall-cmd --permanent --zone=public --add-service=https
```

Reload the firewall with the new rules:

```sh
sudo firewall-cmd --reload
```

### SELinux

If SELinux is enforcing (and it should be), allow Nginx to connect and proxy with the following rules:

```sh
sudo setsebool -P httpd_can_network_connect 1
```

```sh
sudo setsebool -P httpd_can_network_relay 1
```

## Connect

In your browser, navigate to the URL or IP address of the server.

Default credentials are:

|           |                   |
|-          |-                  |
| Username  | admin@admin.net   |
| Password  | admin             |

---

## Plugins

Several plugins are included in the Xen-Orchestra repository, but must be "enabled".

### auth-github

This plugin can be configured to allow users to login using Github Single Sign-On (SSO).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-github \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-google

This plugin can be configured to allow users to login using Google Single Sign-On (SSO).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-google \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-ldap

This plugin can be configured to allow users to login using the Lightweight Directory Access Protocol (LDAP) (including Microsoft&reg; Active Directory&trade;).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-ldap \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-saml

This plugin can be configured to allow users to login using Security Assertion Markup Language (SAML).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-saml \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### backup-reports

This plugin can be configured to deliver Backup task reports to specified users through E-Mail or eXtensible Messaging and Presence Protocol (XMPP).

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

!!! Note
    XMPP reports require the [transport-xmpp](#transport-xmpp) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-backup-reports \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### load-balancer

This plugin can be configured to assign balance Virtual Machines between servers in a pool based on performance, density, or configurable CPU or memory thresholds.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-load-balancer \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### perf-alert

This plugin can be configured to notify specified users when a host or Virtual Machine reaches a specifed CPU or memory utilization threshold. Notifications for Storage Repository usage is also configurable.

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-perf-alert \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### sdn-controller

This plugin can be enabled to control OpenVSwitch virtual networks. Can be configured with a TLS certificate and key to encrypt network traffic.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-sdn-controller \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-email

This plugin can be configured to use an SMTP service to send E-Mail.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-email \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-icinga2

This plugin can be configured to send notifications to an [Icinga 2](https://icinga.com/docs/icinga2/latest/) server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-icinga2 \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-nagios

This plugin can be configured to send notifications to a [Nagios](https://www.nagios.org/) server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-nagios \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-slack

This plugin can be configured to send notifications to a [Slack](https://slack.com/) channel.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-slack \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-xmpp

This plugin can be configured to send notifications to an [XMPP](https://xmpp.org/) server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-xmpp \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### usage-report

This plugin can be configured to send usage reports to specified users on monthly, weekly, or daily intervals.

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-usage-report \
/opt/xen-orchestra/packages/xo-server/node_modules/
```

### web-hooks

This plugin can be configured to send web hook messages on specifed events to a receiving endpoint.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-web-hooks \
/opt/xen-orchestra/packages/xo-server/node_modules/
```
