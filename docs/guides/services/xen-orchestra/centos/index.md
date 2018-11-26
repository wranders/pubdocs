# Xen Orchestra - CentOS

## Installation

### Dependencies

#### Node & Yarn

Add the repositories for [Node.js](https://nodejs.org/) and [Yarn](https://yarnpkg.com/):

```shell
curl -sL https://rpm.nodesource.com/setup_8.x | sudo -E bash -
```

```shell
curl -sL https://dl.yarnpkg.com/rpm/yarn.repo | sudo tee /etc/yum.repos.d/yarn.repo
```

Update the new repositories and install any outstanding updates:

```shell
sudo yum update -y
```

Install build tools and Xen Orchestra prerequisites:

!!! Note
    The `Development Tools` group is needed to build [Redis](https://redis.io/). This can be skipped if Redis is already installed. Not everything in the group is required, but it's easier to install what is required this way.

```shell
sudo yum groupinstall -y "Development Tools"
```

```shell
sudo yum install -y libpng-devel yarn
```

#### Redis

CentOS repositories are several major versions behind, so build Redis from the sources.

Download and unpack the latest stable sources:

```shell
curl -sL http://download.redis.io/redis-stable.tar.gz -o redis-stable.tar.gz
```

```shell
tar xzf redis-stable.tar.gz
```

```shell
cd redis-stable
```

Compile and install:

```shell
make
```

```shell
sudo make install
```

Create the configuration directory and copy the default configuration file:

```shell
sudo mkdir /etc/redis
```

```shell
sudo cp redis.conf /etc/redis
```

Open `/etc/redis/redis.conf` for editing and change the `supervised` and `dir` settings:

```diff
-- supervised no
++ supervised systemd

-- dir ./
++ dir /var/lib/redis
```

Create a user for Redis:

```shell
sudo adduser -Mr -s /sbin/nologin redis
```

Create the directory specified in the `dir` setting of the configuration file and give permissions to the new `redis` user:

```shell
sudo mkdir /var/lib/redis
```

```shell
sudo chown redis:redis /var/lib/redis
```

```shell
sudo chmod 770 /var/lib/redis
```

Create [/etc/systemd/system/redis.service](#redisservice).

Enable autostart and start the new Redis service:

```shell
sudo systemctl daemon-reload
```

```shell
sudo systemctl enable --now redis
```

### Application

Create a user for Xen Orchestra:

!!! Note
    A user directory is created for this user so Yarn has a writable persistent cache location.

!!! Error ""
    Never run Xen Orchestra, or any web service as `root`.

```shell
sudo adduser -mr -s /sbin/nologin xo
```

Copy the `master` branch from Github:

```shell
sudo git clone -b master http://github.com/vatesfr/xen-orchestra /opt/xen-orchestra
```

Change into the new application directory and change the ownership of all files to the new non-root user (`xo`):

```shell
cd /opt/xen-orchestra
```

```shell
sudo chown -R xo:xo .
```

Compile and build the application using Yarn:

```shell
sudo -u xo yarn
```

```shell
sudo -u xo yarn build
```

Create a data directory for the `xo-server` component and give ownership to the current user:

```shell
sudo mkdir /var/lib/xo-server
```

```shell
sudo chown -R xo:xo /var/lib/xo-server
```

Change into the `xo-server` component directory:

```shell
cd packages/xo-server
```

Copy the sample configuration file to the active configuration file:

!!! Note
        The configuration file must be named `.xo-server.yaml`.

```shell
sudo -u xo cp sample.config.yaml .xo-server.yaml
```

Open `.xo-server.yaml` for editing as the `xo` user and enter the path for the `xo-web` component.

```diff
   http:
     mounts:
--     #'/': '/path/to/xo-web/dist/'
++     '/': '../xo-web/dist/'
```

Allow `node` to listen on privileged ports:

!!! Note
        This is only required if Xen Orchestra will be accessed on a privileged port (less than 1000).

```shell
sudo setcap cap_net_bind_service=+ep $(which node)
```

```shell
sudo firewall-cmd --permanent --zone=public --add-port=80/tcp
```

```shell
sudo firewall-cmd --reload
```

Create [/etc/systemd/system/xo.service](#xoservice).

Enable autostart and start the new Xen Orchestra service:

```shell
sudo systemctl daemon-reload
```

```shell
sudo systemctl enable --now xo
```

### Updating

Stop the Xen Orchestra service:

```shell
sudo systemctl stop xo
```

Change into the Xen Orchestra parent directory:

```shell
cd /opt/xen-orchestra
```

Pull the latest sources from Github:

```shell
sudo -u xo git pull --ff-only
```

Compile and build the updated sources with Yarn:

```shell
sudo -u xo yarn
```

```shell
sudo -u xo yarn build
```

Start the updated Xen Orchestra service:

```shell
sudo systemctl start xo
```

## Configuration

### systemd

#### redis.service

```shell
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always

[Install]
WantedBy=multi-user.target
```

#### xo.service

```shell
[Unit]
Description=Xen Orchestra Xen Server Web Manager
After=network-online.target

[Service]
User=xo
Group=xo
WorkingDirectory=/opt/xen-orchestra/packages/xo-server
ExecStart=/usr/bin/yarn start
Restart=always

[Install]
WantedBy=multi-user.target
```

### SELinux

!!! ToDo
    Create confined contexts for the application and user.