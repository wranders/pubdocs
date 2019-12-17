# Xen-Orchestra - CentOS 7

This guide was written using the following versions:

* CentOS 7.7.1908
* Xen-Orchestra 5.53

This guide will set up Xen-Orchestra on CentOS 7 with a self-signed TLS certificate.

## Repositories

Node.js 8:

```sh
curl -sL https://rpm.nodesource.com/setup_8.x | sudo -E bash -
```

Yarn:

```shell
curl -sL https://dl.yarnpkg.com/rpm/yarn.repo | sudo tee /etc/yum.repos.d/yarn.repo
```

Extra Packages:

```sh
sudo yum install -y epel-release
```

## Dependencies

Update the newly installed repositories and upgrade any outdated packages:

```sh
sudo yum update -y
```

Install Node.js, Yarn, Redis, and Git:

```sh
sudo yum install -y nodejs yarn redis git
```

## Redis

Set Redis to start on boot and start:

```sh
sudo systemctl enable --now redis.service
```

Verify Redis is running:

```sh
redis-cli ping
```

```sh
PONG
```

## Application

Create a user for Xen-Orchestra:

```sh
sudo adduser -mr -s /sbin/nologin xo
```

!!! Error "Critical"
        Do not run Xen-Orchestra as the `root` user.

!!! Info
        The `-m` flag creates a home directory for the `xo` user so `yarn` can create its cache.

### Clone and Build

Clone the Xen-Orchestra repository to the `/opt/` directory:

```sh
sudo git clone -b master https://github.com/vatesfr/xen-orchestra /opt/xen-orchestra
```

Set the `xo` user as the owner of the repository directory:

```sh
sudo chown -R xo:xo /opt/xen-orchestra
```

!!! Info
        `yarn` commands are run with the `--cwd` so that they can be run from any working directory. This can be omitted if the PWD is `/opt/xen-orchestra` or the directory Xen-Orchestra was cloned to.

Gather Yarn dependencies and build the application. This will take a while:

```sh
sudo -u xo yarn --cwd /opt/xen-orchestra && \
sudo -u xo yarn --cwd /opt/xen-orchestra build
```

Create the configuration and data directories:

```sh
sudo mkdir /etc/xo-server /var/lib/xo-server
```

Copy the sample configuration file to the configuration directory:

```sh
sudo cp /opt/xen-orchestra/packages/xo-server/sample.config.toml /etc/xo-server/config.toml
```

Set ownership of the data directory to the `xo` user:

```sh
sudo chown xo:xo /var/lib/xo-server
```

### HTTP

Allow Node.js to bind to privileged ports:

```sh
sudo setcap cap_net_bind_service=+ep $(which node)
```

Allow HTTP (port 80) access through the firewall:

```sh
sudo firewall-cmd --permanent --zone=public --add-service=http
```

### HTTPS

Enable HTTP -> HTTPS redirection:

```sh
sudo sed -i 's/# redirectToHttps = true/redirectToHttps = true/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- # redirectToHttps = true
    ++ redirectToHttps = true
    ```

Enable `SameSite` and `Secure` cookies:

```sh
sudo sed -i 's/#sameSite = true/sameSite = true/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- #sameSite = true
    ++ sameSite = true
    ```

```sh
sudo sed -i 's/#secure = true/secure = true/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- #secure = true
    ++ secure = true
    ```

Enable the second HTTP listener for HTTPS (port 443):

```sh
sudo sed -i 's/# \[\[http.listen\]\]/\[\[http.listen\]\]/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- # [[http.listen]]
    ++ [[http.listen]]
    ```

```sh
sudo sed -i 's/# port = 443/port = 443/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- # port = 443
    ++ port = 443
    ```

Set the file paths for the TLS key and certificate:

```sh
sudo sed -i "s/# key = '.\/key.pem'/key = '\/etc\/ssl\/private\/xo\/key.pem'/g" /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- # key = './key.pem'
    ++ key = '/etc/ssl/private/xo/key.pem'
    ```

```sh
sudo sed -i "s/# cert = '.\/certificate.pem'/cert = '\/etc\/ssl\/private\/xo\/certificate.pem'/g" /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- # cert = './certificate.pem'
    ++ cert = '/etc/ssl/private/xo/certificate.pem'
    ```

??? summary "`/etc/xo-server/config.toml`"
    ```toml
    [http]
    redirectToHttps = true

    [http.cookies]
    sameSite = true
    secure = true

    [[http.listen]]
    port = 80

    [[http.listen]]
    port = 443
    cert = '/etc/ssl/private/xo/certificate.pem'
    key = '/etc/ssl/private/xo/key.pem'
    ```

Create the directory for the TLS key and certificates:

```sh
sudo mkdir -p /etc/ssl/private/xo
```

Set the `xo` user as the owner of this directory:

```sh
sudo chown xo:xo /etc/ssl/private/xo
```

Set this directory so that no one but the `xo` user can access it:

```sh
sudo chmod 700 /etc/ssl/private/xo
```

!!! Info "Existing certificates"
    Existing TLS certificate can be used instead of self-signed.

    To avoid further edits to the configuration file, preserve the file names and locations used in this self-signed example:

        Certificate:    `/etc/ssl/private/xo/certificate.pem`
        Key:            `/etc/ssl/private/xo/key.pem`

    The following `req.conf` file and `openssl` command can be skipped in this case.

Using your prefered text editor, create `/etc/ssl/private/xo/req.conf`:

```sh hl_lines="15 19 20"
[req]
default_bits        = 2048
default_md          = sha256
distinguished_name  = dn_req
x509_extensions     = v3_req
prompt              = no

[v3_req]
keyUsage            = digitalSignature, keyEncipherment
extendedKeyUsage    = serverAuth
basicConstraints    = critical, CA:FALSE, pathlen:0
subjectAltName      = @alt_names

[dn_req]
CN  = xo.example.local
OU  = Xen-Orchestra

[alt_names]
DNS.1   = xo.example.local
IP.1    = 192.168.0.10
```

!!! Info
        Set the domain name/FQDN (DNS) and the IP address of the server running Xen-Orchestra in the `alt_names` section and the Common Name (CN) in the `dn_req` section. Some browsers disable the use of self-signed certificates without valid Subject Alternative Names.

Generate the key and certificate:

```sh
sudo -u xo openssl req -x509 \
-nodes  -days 730 \
-keyout /etc/ssl/private/xo/key.pem \
-out    /etc/ssl/private/xo/certificate.pem \
-config /etc/ssl/private/xo/req.conf
```

Allow HTTPS (port 443) access through the firewall:

```sh
sudo firewall-cmd --permanent --zone=public --add-service=https
```

Reload the firewall:

```sh
sudo firewall-cmd --reload
```

### systemd

Create the `systemd` unit file:

```sh
echo -e "[Unit]\n\
Description=Xen-Orchestra - Xen Server Web Manager\n\
After=network.target\n\
After=network-online.target\n\
Wants=network-online.target\n\n\
[Service]\n\
User=xo\n\
Group=xo\n\
WorkingDirectory=/opt/xen-orchestra/packages/xo-server\n\
ExecStart=/usr/bin/yarn start\n\
Restart=always\n\
RestartSec=10\n\n\
[Install]\n\
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/xo.service
```

??? summary "`/etc/systemd/system/xo.service`"
    ```sh
    [Unit]
    Description=Xen-Orchestra - Xen Server Web Manager
    After=network.target
    After=network-online.target
    Wants=network-online.target

    [Service]
    User=xo
    Group=xo
    WorkingDirectory=/opt/xen-orchestra/packages/xo-server
    ExecStart=/usr/bin/yarn start
    Restart=always
    RestartSec=10
    
    [Install]
    WantedBy=multi-user.target
    ```

Update the `systemd` database:

```sh
sudo systemctl daemon-reload
```

Set Xen-Orchestra to start on boot and start:

```sh
sudo systemctl enable --now xo.service
```

In your browser, navigate to the URL or IP address of the server.

Default credentials are:

|           |                   |
|-          |-                  |
| Username  | admin@admin.net   |
| Password  | admin             |

## NFS Mounts

If Xen-Orchestra will mount to NFS remotes, some additional configuration is needed.

NFS mounts are created in `/run/xo-server` by default, so Xen-Orchestra needs that runtime directory.

Stop Xen-Orchestra:

```sh
sudo systemctl stop xo
```

Create a directory for service drop-ins:

```sh
sudo mkdir /etc/systemd/system/xo.service.d
```

Create the service drop-in that sets the runtime directory and that directory's permissions mode:

```sh
echo -e "[Service]\n\
RuntimeDirectory=xo-server\n\
RuntimeDirectoryMode=0750" | sudo tee /etc/systemd/system/xo.service.d/nfs.conf
```

??? summary "`/etc/systemd/system/xo.service.d/nfs.conf`"
    ```sh
    [Service]
    RuntimeDirectory=xo-server
    RuntimeDirectoryMode=0750
    ```

Update the `systemd` database to include the new drop-in:

```sh
sudo systemctl daemon-reload
```

Install `nfs-utils`:

```sh
sudo yum install -y nfs-utils
```

Modify the Xen-Orchestra configuration to use `sudo`. This is required for Xen-Orchestra to run the `mount` and `unmount` commands.

```sh
sudo sed -i 's/#useSudo = false/useSudo = true/g' /etc/xo-server/config.toml
```

??? quote "Diff"
    ```diff
    -- #useSudo = false
    ++ useSudo = true
    ```

??? summary "`/etc/xo-server/config.toml`"
    ```toml
    [remoteOptions]
    useSudo = true
    ```

Add the `xo` user to the `sudoers` file to allow no-password access to the `mount` and `unmount` commands:

```sh
echo -e "xo\tALL=(root)\tNOPASSWD: /bin/mount, /bin/umount" | sudo tee --append /etc/sudoers
```

??? summary "`/etc/sudoers`"
    ```sh
    xo  ALL=(root)  NOPASSWD: /bin/mount, /bin/umount
    ```

Start Xen-Orchestra:

```sh
sudo systemctl start xo
```

## Plugins

Several plugins are included in the Xen-Orchestra repository, but must be "enabled".

### auth-github

This plugin can be configured to allow users to login using Github Single Sign-On (SSO).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-github /opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-google

This plugin can be configured to allow users to login using Google Single Sign-On (SSO).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-google /opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-ldap

This plugin can be configured to allow users to login using the Lightweight Directory Access Protocol (LDAP).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-ldap /opt/xen-orchestra/packages/xo-server/node_modules/
```

### auth-saml

This plugin can be configured to allow users to login using Security Assertion Markup Language (SAML).

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-auth-saml /opt/xen-orchestra/packages/xo-server/node_modules/
```

### backup-reports

This plugin can be configured to deliver Backup task reports to specified users through E-Mail or eXtensible Messaging and Presence Protocol (XMPP).

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

!!! Note
    XMPP reports require the [transport-xmpp](#transport-xmpp) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-backup-reports /opt/xen-orchestra/packages/xo-server/node_modules/
```

### load-balancer

This plugin can be configured to assign balance Virtual Machines between servers in a pool based on performance, density, or configurable CPU or memory thresholds.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-load-balancer /opt/xen-orchestra/packages/xo-server/node_modules/
```

### perf-alert

This plugin can be configured to notify specified users when a host or Virtual Machine reaches a specifed CPU or memory utilization threshold. Notifications for Storage Repository usage is also configurable.

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-perf-alert /opt/xen-orchestra/packages/xo-server/node_modules/
```

### sdn-controller

This plugin can be enabled to control OpenVSwitch virtual networks. Can be configured with a TLS certificate and key to encrypt network traffic.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-sdn-controller /opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-email

This plugin can be configured to use an SMTP service to send E-Mail.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-email /opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-icinga2

This plugin can be configured to send notifications to an [Icinga 2](https://icinga.com/docs/icinga2/latest/) server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-icinga2 /opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-nagios

This plugin can be configured to send notifications to a [Nagios](https://www.nagios.org/) server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-nagios /opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-slack

This plugin can be configured to send notifications to a [Slack](https://slack.com/) channel.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-slack /opt/xen-orchestra/packages/xo-server/node_modules/
```

### transport-xmpp

This plugin can be configured to send notifications to an XMPP server.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-transport-xmpp /opt/xen-orchestra/packages/xo-server/node_modules/
```

### usage-report

This plugin can be configured to send usage reports to specified users on monthly, weekly, or daily intervals.

!!! Note
    E-Mail reports require the [transport-email](#transport-email) plugin

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-usage-report /opt/xen-orchestra/packages/xo-server/node_modules/
```

### web-hooks

This plugin can be configured to send web hook messages on specifed events to a receiving endpoint.

Create a symbolic link from the plugin's directory to the `xo-server` `node_modules` directory. Plugin is enabled on restart.

```sh
sudo -u xo ln -s /opt/xen-orchestra/packages/xo-server-web-hooks /opt/xen-orchestra/packages/xo-server/node_modules/
```
